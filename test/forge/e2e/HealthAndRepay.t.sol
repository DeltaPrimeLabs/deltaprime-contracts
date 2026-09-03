// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SolvencyFacetProd} from "../../../contracts/facets/SolvencyFacetProd.sol";
import {WithdrawalIntentFacet} from "../../../contracts/facets/WithdrawalIntentFacet.sol";

/**
 * @title HealthAndRepay e2e — SP4.1
 *
 * Covers health-ratio mechanics, repay accounting, withdrawal-intent lifecycle under debt,
 * getFullLoanStatus coherence, and price sensitivity. All solvency paths are wrapped
 * with the mock RedStone oracle payload (RedstoneLib.wrap).
 *
 * Health-ratio arithmetic (for reference, derivation in test comments):
 *   HR = thresholdWeightedValue * 1e18 / debt      (when debt > 0)
 *   HR = type(uint256).max                          (when debt == 0)
 *
 *   Fixture: AVAX $30, USDC $1, DEBT_COVERAGE = 5/6 ≈ 0.833333…e18
 *
 *   With 100 AVAX funded:
 *     AVAX_TWV = 30e8 * 100e18 * COVERAGE / 10^26 ≈ 2500e18   (USD, 18-dec)
 *
 *   Debt from X USDC borrowed:
 *     debt_USD = X * 1e8 * 1e10 / 1e6 = X * 1e12            (USD, 18-dec)
 *
 *   USDC collateral (loan holds borrowed USDC):
 *     USDC_TWV = 1e8 * X * COVERAGE / (1e6 * 1e8) = X * COVERAGE / 1e6
 *
 *   Solvency boundary (HR = 1e18 exactly):
 *     AVAX_TWV + X * COVERAGE / 1e6 = X * 1e12
 *     2500e18  = X * (1e12 - COVERAGE / 1e8)
 *     X        ≈ 15000e6   (15 000 USDC, 6-decimal amount)
 */
contract HealthAndRepayTest is DeltaPrimeFixture {

    // ─── Constants ──────────────────────────────────────────────────────────

    // Integer-arithmetic note: COVERAGE = 833333333333333333 = 5/6·1e18 - 1.
    // AVAX_TWV = 2499999999999999999000 (< 2500e18 by 1000 units due to truncation).
    // At 15000e6 USDC: TWV = 14999999999999999994000, Debt = 15000e18
    //   → HR = 999999999999999999 = 1e18 - 1 → insolvent by one unit.
    // Actual safe boundary is ~14999e6. Tests use conservative values:
    //   SAFE_BORROW  = 14900e6 → HR ≈ 1.0011e18 (safely solvent)
    //   OVER_BORROW  = 15001e6 → HR < 1e18      (insolvent)
    uint256 internal constant SAFE_BORROW   = 14_900e6;
    uint256 internal constant OVER_BORROW   = 15_001e6;

    // ─── setUp ──────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();
        // Fund USDC pool with 2M USDC to support high-leverage test borrows.
        address lender = makeAddr("lender");
        usdc.mint(lender, 2_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 2_000_000e6);
        usdcPool.deposit(2_000_000e6);
        vm.stopPrank();
    }

    // ─── Internal helpers ───────────────────────────────────────────────────

    /// @dev Wrapped getHealthRatio at canonical prices ($30 AVAX).
    function _hr(address loan) internal returns (uint256) {
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(SolvencyFacetProd.getHealthRatio.selector),
            _feeds(), _prices()
        );
        assertTrue(ok, "getHealthRatio failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev Wrapped getHealthRatio with a custom AVAX price.
    function _hrAtAvax(address loan, uint256 avaxPrice8) internal returns (uint256) {
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(SolvencyFacetProd.getHealthRatio.selector),
            _feeds(), _pricesWithAvax(avaxPrice8)
        );
        assertTrue(ok, "getHealthRatio failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev Wrapped getDebt at canonical prices.
    function _debt(address loan) internal returns (uint256) {
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(SolvencyFacetProd.getDebt.selector),
            _feeds(), _prices()
        );
        assertTrue(ok, "getDebt failed");
        return abi.decode(ret, (uint256));
    }

    /// @dev Warp 1 s then borrow USDC as the loan owner.
    function _borrowUsdc(address borrower, address loan, uint256 amount) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), amount),
            _feeds(), _prices()
        );
    }

    // ─── Test 1: getHealthRatio sanity ladder ────────────────────────────────

    /**
     * No debt → HR = type(uint256).max (PINNED from SolvencyFacetProd.getHealthRatio:
     *   "if (debt == 0) { return type(uint256).max; }").
     * More debt → strictly lower HR.
     */
    function testHealthRatioLadder() public {
        // Loan A: 100 AVAX, no debt
        (address borrowerA, address loanA) = _createLoanFor("loanA");
        _fundAvax(borrowerA, loanA, 100e18);
        uint256 hrNoDebt = _hr(loanA);
        assertEq(hrNoDebt, type(uint256).max, "no-debt HR must be type(uint256).max");

        // Loan B: 100 AVAX, 1 000 USDC debt
        (address borrowerB, address loanB) = _createLoanFor("loanB");
        _fundAvax(borrowerB, loanB, 100e18);
        _borrowUsdc(borrowerB, loanB, 1_000e6);
        uint256 hr1k = _hr(loanB);

        // Loan C: 100 AVAX, 5 000 USDC debt
        (address borrowerC, address loanC) = _createLoanFor("loanC");
        _fundAvax(borrowerC, loanC, 100e18);
        _borrowUsdc(borrowerC, loanC, 5_000e6);
        uint256 hr5k = _hr(loanC);

        assertGt(hr1k,  1e18, "1 000 USDC borrow must remain solvent");
        assertGt(hr5k,  1e18, "5 000 USDC borrow must remain solvent");
        assertGt(hr1k,  hr5k, "higher debt must produce lower HR");
    }

    // ─── Test 2: HR ≈ 1e18 solvency boundary ────────────────────────────────

    /**
     * SAFE_BORROW (14900 USDC) → HR ≈ 1.0011e18 → solvent, borrow succeeds.
     * OVER_BORROW (15001 USDC) → HR < 1e18       → remainsSolvent reverts.
     *
     * PINNED revert: "The action may cause an account to become insolvent"
     * (PrimeAccountModifiers.remainsSolvent: require(_isSolvent(), ...)).
     *
     * PINNED: isSolvent() := getHealthRatio() >= 1e18.
     *   See constant block above for full integer-arithmetic derivation of why
     *   the boundary is at ~14999e6 (not the 15000e6 the continuous formula predicts).
     */
    function testSolvencyBoundaryBorrowSucceeds() public {
        (address borrower, address loan) = _createLoanFor("boundaryAt");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, SAFE_BORROW); // HR ≈ 1.0011e18 — must not revert
        uint256 hr = _hr(loan);
        assertGe(hr, 1e18, "safe-borrow HR must satisfy isSolvent");
    }

    function testSolvencyBoundaryOverReverts() public {
        (address borrower, address loan) = _createLoanFor("boundaryOver");
        _fundAvax(borrower, loan, 100e18);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), OVER_BORROW),
            _feeds(), _prices()
        );
        assertFalse(ok, "over-boundary borrow must revert");
        // PINNED: PrimeAccountModifiers.remainsSolvent post-check
        assertTrue(_revertContains(ret, "insolvent"), "expected remainsSolvent guard");
    }

    // ─── Test 3: partial repay decreases debt ────────────────────────────────

    /**
     * repay() modifiers: noBorrowInTheSameBlock, nonReentrant, notInLiquidation.
     * Auth: when solvent, enforces owner (DiamondStorageLib.enforceIsContractOwner).
     * Repay draws from the loan's own token balance (pool.repay uses approved allowance).
     * Oracle data required because repay() calls _isSolvent() via proxyDelegateCalldata
     * (DiamondSolvencyMethodsAccess._isSolvent → ProxyConnector re-appends calldata).
     */
    function testRepayPartialDecreasesDebt() public {
        (address borrower, address loan) = _createLoanFor("repayPartial");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 1_000e6);

        uint256 debtBefore = _debt(loan);
        assertGt(debtBefore, 0, "must have debt before repay");

        // Advance timestamp so repay is not in the same block as the borrow.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.repay.selector, bytes32("USDC"), uint256(400e6)),
            _feeds(), _prices()
        );

        uint256 debtAfter = _debt(loan);
        assertLt(debtAfter, debtBefore, "partial repay must reduce debt");
    }

    // ─── Test 4: repay more than debt → capped, not reverted ─────────────────

    /**
     * PINNED (AssetsOperationsFacet.repay lines 288, 297-298):
     *
     *   Guard (fires first):
     *     if (_getAvailableBalance(_asset) < _amount) revert InsufficientBalance();
     *
     *   Cap (only reached when amount <= available balance):
     *     _amount = Math.min(_amount, _getAvailableBalance(_asset));   // → available
     *     _amount = Math.min(_amount, pool.getBorrowed(address(this)));// → min(avail, debt)
     *
     * To reach the cap path, the loan must hold MORE than it borrowed.
     * Setup: borrow 500 USDC, then fund 600 more USDC → loan holds 1100 USDC, debt = 500.
     * Repay 1100: availableBalance = 1100 ≥ 1100 (guard passes); cap = min(1100, 500) = 500.
     * Result: debt = 0, loan holds 600 USDC. No revert.
     */
    function testRepayMoreThanDebtIsCapped() public {
        (address borrower, address loan) = _createLoanFor("repayCap");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 500e6);

        // Fund 600 more USDC directly so the loan holds 1100 but only owes 500.
        vm.warp(block.timestamp + 1);
        usdc.mint(borrower, 600e6);
        vm.startPrank(borrower);
        usdc.approve(loan, 600e6);
        AssetsOperationsFacet(loan).fund(bytes32("USDC"), 600e6);
        vm.stopPrank();

        // Warp again so repay is not in the same block as fund.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.repay.selector, bytes32("USDC"), uint256(1_100e6)),
            _feeds(), _prices()
        );

        // Debt cleared (capped at getBorrowed = 500); loan retains 600 USDC excess.
        uint256 debtAfter = _debt(loan);
        assertEq(debtAfter, 0, "debt must be zero after capped over-repay");
        assertEq(usdc.balanceOf(loan), 600e6, "excess 600 USDC must remain in loan");
    }

    // ─── Test 5a: withdrawal intent — solvent execution succeeds ─────────────

    /**
     * Withdraw AVAX (not the borrowed asset) so that:
     *   canRepayDebtFully: USDC balance (1 000) >= USDC debt (1 000) ✓
     *   remainsSolvent: HR after removal of 10 AVAX is comfortably > 1e18 ✓
     *
     * createWithdrawalIntent modifiers: onlyOwner, nonReentrant, notInLiquidation
     *   — does NOT check solvency.
     * executeWithdrawalIntent has canRepayDebtFully + remainsSolvent (both post-check).
     *
     * PINNED intent timings (WithdrawalIntentFacet.createWithdrawalIntent):
     *   actionableAt = block.timestamp + 24 hours
     *   expiresAt    = actionableAt + 48 hours
     */
    function testWithdrawalIntentSolventExecution() public {
        (address borrower, address loan) = _createLoanFor("wiSolvent");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 1_000e6);
        // loan holds: 100 AVAX (WAVAX) + 1 000 USDC; debt = 1 000 USDC
        // ADAPTATION: canRepayDebtFully is a post-check that fires AFTER executeWithdrawalIntent
        // removes 10 AVAX. It checks USDC balance >= USDC debt. After 24 h of interest accrual
        // the debt is marginally above 1 000e6; mint 1e6 extra USDC directly into the loan as
        // a buffer so balance stays comfortably above debt throughout the test.
        usdc.mint(loan, 1e6); // interest cushion — no effect on solvency logic

        // Create AVAX withdrawal intent for 10 AVAX. No oracle needed.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        WithdrawalIntentFacet(loan).createWithdrawalIntent(NATIVE_SYMBOL, 10e18);

        // Mature the intent (>= 24 h).
        vm.warp(block.timestamp + 24 hours + 1);

        // ADAPTATION: mock WAVAX has src==msg.sender allowance-skip guard commented out
        // (contracts/mock/WAVAX.sol:71-74). executeWithdrawalIntent calls
        // address(wavax).safeTransfer(borrower, amount), which routes through
        // transferFrom(src=loan, dst=borrower) with msg.sender=loan. Without self-approval
        // this requires allowance[loan][loan] >= amount.
        vm.prank(loan);
        wavax.approve(loan, type(uint256).max);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        // Execute — loan transfers 10 AVAX to borrower; remainsSolvent passes.
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(
                WithdrawalIntentFacet.executeWithdrawalIntent.selector,
                NATIVE_SYMBOL,
                indices
            ),
            _feeds(), _prices()
        );

        // Loan's WAVAX balance must have decreased by 10 AVAX.
        uint256 loanAvax = wavax.balanceOf(loan);
        assertEq(loanAvax, 90e18, "loan must hold 90 AVAX after 10 withdrawn via intent");
    }

    // ─── Test 5b: withdrawal intent — breaks solvency → reverts ─────────────

    /**
     * Withdraw 90 of 100 AVAX after a near-boundary USDC borrow (14 900 USDC).
     * Post-execution state: 10 AVAX + 14 900 USDC; debt = 14 900 USDC.
     *   AVAX_TWV = 30 * 10 * COVERAGE * 1e18 ≈  250e18
     *   USDC_TWV = 1  * 14900 * COVERAGE * 1e18 ≈ 12 417e18
     *   Total TWV ≈ 12 667e18; Debt = 14 900e18; HR ≈ 0.85e18 < 1 → insolvent.
     *
     * Modifier execution order (innermost-first post):
     *   notInLiquidation → remainsSolvent → canRepayDebtFully
     *
     * PINNED revert from remainsSolvent (fires before canRepayDebtFully):
     *   "The action may cause an account to become insolvent"
     */
    function testWithdrawalIntentBreaksSolvencyReverts() public {
        (address borrower, address loan) = _createLoanFor("wiInsolvent");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 14_900e6);
        // HR after borrow ≈ 14916.67e18 / 14900e18 ≈ 1.001e18 (solvent)

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        // Intent for 90 AVAX — does NOT check solvency at intent creation.
        WithdrawalIntentFacet(loan).createWithdrawalIntent(NATIVE_SYMBOL, 90e18);

        vm.warp(block.timestamp + 24 hours + 1);

        // ADAPTATION (same as solvent case): mock WAVAX needs loan self-approval
        // so the safeTransfer inside executeWithdrawalIntent body can succeed.
        // The transfer completes; remainsSolvent post-check then fires and reverts the tx.
        vm.prank(loan);
        wavax.approve(loan, type(uint256).max);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(
                WithdrawalIntentFacet.executeWithdrawalIntent.selector,
                NATIVE_SYMBOL,
                indices
            ),
            _feeds(), _prices()
        );
        assertFalse(ok, "solvency-breaking intent execution must revert");
        // PINNED: remainsSolvent post-check (fires before canRepayDebtFully)
        assertTrue(_revertContains(ret, "insolvent"), "expected remainsSolvent guard");
    }

    // ─── Test 6: getFullLoanStatus coherence ─────────────────────────────────

    /**
     * PINNED return shape (SolvencyFacetProd.getFullLoanStatus):
     *   uint256[5] = [getTotalValue(), getDebt(), getThresholdWeightedValue(),
     *                 getHealthRatio(), isSolvent() ? 1 : 0]
     *
     * Invariants checked:
     *   result[3] == result[2] * 1e18 / result[1]   (HR definition, when debt > 0)
     *   result[4] == 1 iff result[3] >= 1e18         (isSolvent flag)
     *   result[0] >= result[1]                        (totalValue >= debt, must be solvent)
     */
    function testGetFullLoanStatusCoherence() public {
        (address borrower, address loan) = _createLoanFor("statusLoan");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 2_000e6);

        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(SolvencyFacetProd.getFullLoanStatus.selector),
            _feeds(), _prices()
        );
        assertTrue(ok, "getFullLoanStatus must succeed");
        uint256[5] memory s = abi.decode(ret, (uint256[5]));

        uint256 totalValue = s[0];
        uint256 debt       = s[1];
        uint256 twv        = s[2];
        uint256 hr         = s[3];
        uint256 solventFlag = s[4];

        assertGt(totalValue, 0,   "totalValue must be > 0");
        assertGt(debt,       0,   "debt must be > 0 after borrow");
        assertGt(twv,        0,   "TWV must be > 0");

        // HR definition (integer division) — matches SolvencyFacetProd.getHealthRatio()
        assertEq(hr, twv * 1e18 / debt, "HR must equal TWV*1e18/debt");

        // isSolvent flag consistency
        uint256 expectedFlag = hr >= 1e18 ? 1 : 0;
        assertEq(solventFlag, expectedFlag, "isSolvent flag must match HR >= 1e18");
        assertEq(solventFlag, 1, "account must be solvent");

        // totalValue must cover debt (otherwise solvent flag would be wrong here)
        assertGe(totalValue, debt, "totalValue must be >= debt when solvent");
    }

    // ─── Test 7: price sensitivity ────────────────────────────────────────────

    /**
     * Same position (100 AVAX + 2 000 USDC debt), two oracle payloads:
     *   AVAX $30 → HR ≈ 2.08e18
     *   AVAX $20 → HR ≈ 1.67e18
     * Both > 1e18 (solvent at either price); the higher AVAX price yields the higher HR.
     *
     * Derivation:
     *   USDC_TWV(2000) ≈ 1666.67e18 (fixed regardless of AVAX price)
     *   AVAX_TWV at $30 = 2500e18, at $20 = 1666.67e18
     *   Debt = 2000e18
     *   HR($30) = (2500 + 1666.67) / 2000 ≈ 2.08
     *   HR($20) = (1666.67 + 1666.67) / 2000 ≈ 1.67
     */
    function testHealthRatioScalesWithAvaxPrice() public {
        (address borrower, address loan) = _createLoanFor("priceSensitive");
        _fundAvax(borrower, loan, 100e18);
        _borrowUsdc(borrower, loan, 2_000e6);

        uint256 hrAt30 = _hrAtAvax(loan, 30e8);
        uint256 hrAt20 = _hrAtAvax(loan, 20e8);

        assertGt(hrAt30, 1e18, "HR at $30 must be solvent");
        assertGt(hrAt20, 1e18, "HR at $20 must be solvent");
        assertGt(hrAt30, hrAt20, "lower AVAX price must yield lower HR");
    }
}
