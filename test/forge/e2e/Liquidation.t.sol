// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";

/**
 * Liquidation e2e — the protocol's most safety-critical flow, exercised end-to-end
 * against a real diamond (SmartLoanDiamondProxy) cut with the production
 * SmartLoanLiquidationFacet.
 *
 * Standard arrangement (per setUp): 100 AVAX @ $30 collateral, 2 000 USDC debt.
 *
 * Health-ratio mechanics (BASIC tier, DEBT_COVERAGE = 0.833…):
 *   HR = thresholdWeightedValue * 1e18 / debt (USD 18-dec)
 *   thresholdWeightedValue = (avaxBal * avaxPrice * coverage + usdcBal * usdcPrice * coverage)
 *
 *   After borrow the loan holds 100 wAVAX + 2 000 USDC:
 *     At AVAX = $30:  HR ≈ 2.08e18  (solvent)
 *     At AVAX = $3:   HR ≈ 0.96e18  (insolvent) ← crash price used in tests
 *   Insolvency threshold: avaxPrice * 83.33 + 1666.67 < 2000 → avaxPrice < $4.
 *
 * Coverage matrix (vs SmartLoanLiquidationFacet.sol + PrimeAccountModifiers.sol):
 *   Happy path ............. testFullLiquidationAfterPriceDrop
 *   Snapshot lifecycle ..... testSnapshotExpiresAfter15Minutes,
 *                            testSnapshotOnSolventAccountReverts,
 *                            testDoubleSnapshotReverts,
 *                            testSnapshotReArmsAfterExpiry,
 *                            testGetHealthRatioSnapshotRecorded
 *   clearInsolvencySnapshot. testClearSnapshotAfterRecovery,
 *                            testClearSnapshotWithoutSnapshotReverts,
 *                            testClearSnapshotWhileStillInsolventReverts
 *   Access control ......... testNonWhitelistedCannotSnapshot,
 *                            testNonWhitelistedCannotLiquidate,
 *                            testNonWhitelistedCannotClearSnapshot,
 *                            testDelistedLiquidatorCannotSnapshot
 *   liquidate() guards ..... testLiquidateWithoutSnapshotReverts,
 *                            testNormalLiquidateUnderwaterReverts,
 *                            testLiquidationProceedsDespitePriceRecovery (anti-grief)
 *   Emergency mode ......... testEmergencyLiquidationClearsInsolventAccount,
 *                            testEmergencyLiquidationRevertsWhenValueRemains
 *   Fee distribution ....... testFeeSplitOneThirdTwoThirds (token branch),
 *                            testFeeDistributionNativeBranch,
 *                            testGetLiquidationFeePercentBasicDefault
 *   notInLiquidation lock .. testBorrowBlockedDuringLiquidation
 *
 * Prime-debt liquidation (PrimeLeverageFacet) is covered in PrimeDebtLiquidation.t.sol.
 * Live-diamond fork liquidation is covered under test/forge/fork/.
 */
contract LiquidationTest is DeltaPrimeFixture {
    // Crash price that guarantees insolvency: avaxPrice < $4 triggers HR < 1e18.
    uint256 internal constant CRASH_PRICE = 3e8; // $3 AVAX (8-decimal oracle format)

    // Mirror of PrimeAccountModifiers.OnlyWhitelistedLiquidators — same name+args ⇒ same
    // 4-byte selector, so we can assert the custom-error revert without importing the
    // abstract modifier contract.
    error OnlyWhitelistedLiquidators();

    address internal loan;
    address internal borrower;

    function setUp() public override {
        super.setUp();

        // Pre-fund the USDC pool.
        address lender = makeAddr("lender");
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();

        // Arrange: create loan, fund with 100 AVAX, borrow 2 000 USDC at $30.
        (borrower, loan) = _createLoanFor("borrower");
        _fundAvax(borrower, loan, 100e18); // 100 AVAX @ $30 = $3 000 collateral
        vm.warp(block.timestamp + 1);      // noBorrowInTheSameBlock timestamp guard
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(2000e6)),
            _feeds(),
            _prices()
        ); // HR ≈ 2.08e18 at $30 — healthy

        // ADAPTATION: the mock WAVAX (contracts/mock/WAVAX.sol) has the standard
        // src==msg.sender allowance-skip guard commented out (lines 73-74), so
        // transferFrom(src=loan, dst=STABILITY_POOL, amount) called from within
        // _distributeLiquidationFee requires allowance[loan][loan] >= amount.
        // Real on-chain wAVAX/WETH does not require self-approval for transfer().
        vm.prank(loan);
        wavax.approve(loan, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Local helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Snapshot insolvency as the whitelisted liquidator at the given price set.
    function _snapshot(uint256[] memory prices) internal {
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            prices
        );
    }

    /// @dev Wrapped getDebt() at the given price set.
    function _debtAt(uint256[] memory prices) internal returns (uint256) {
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan, abi.encodeWithSignature("getDebt()"), _feeds(), prices
        );
        assertTrue(ok, "getDebt() must succeed");
        return abi.decode(ret, (uint256));
    }

    /// @dev Move all of the loan's wAVAX and USDC to a graveyard address (simulates an
    ///      account so underwater it can no longer self-repay — needed for emergency mode).
    function _stripLoanAssets(bool keepWavax) internal {
        address graveyard = makeAddr("graveyard");
        if (!keepWavax) {
            uint256 wbal = wavax.balanceOf(loan);
            if (wbal > 0) {
                vm.prank(loan);
                wavax.transfer(graveyard, wbal);
            }
        }
        uint256 ubal = usdc.balanceOf(loan);
        if (ubal > 0) {
            vm.prank(loan);
            usdc.transfer(graveyard, ubal);
        }
    }

    function _revertSelectorIs(bytes memory ret, bytes4 sel) internal pure returns (bool) {
        return ret.length >= 4 && bytes4(ret) == sel;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Happy path
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Full liquidation after AVAX price crashes from $30 → $3.
     *   1. Post-liquidation getDebt() == 0
     *   2. STABILITY_POOL received wAVAX (fee distribution executed)
     */
    function testFullLiquidationAfterPriceDrop() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        assertGt(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must be recorded");

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );

        assertEq(_debtAt(_pricesWithAvax(CRASH_PRICE)), 0, "debt must be fully repaid");
        assertGt(
            wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL),
            0,
            "STABILITY_POOL must receive wAVAX liquidation bonus"
        );
        // Snapshot cleared post-liquidation.
        assertEq(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must clear after liquidate");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Snapshot lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice After 15 minutes the snapshot window expires and liquidate() reverts.
    function testSnapshotExpiresAfter15Minutes() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.warp(block.timestamp + 16 minutes);

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "must revert after snapshot expiry");
        // PINNED (SmartLoanLiquidationFacet.liquidate:160).
        assertTrue(_revertContains(ret, "Insolvency snapshot expired"), "expected expiry guard");
    }

    /**
     * snapshotInsolvency on a healthy account reverts.
     * PINNED (SmartLoanLiquidationFacet.snapshotInsolvency:109): require(hr < 1e18, "Account is solvent").
     */
    function testSnapshotOnSolventAccountReverts() public {
        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            _prices() // $30 → HR ≈ 2.08e18, solvent
        );
        assertFalse(ok, "snapshot on solvent account must revert");
        assertTrue(_revertContains(ret, "Account is solvent"), "expected solvency guard");
    }

    /**
     * A second snapshot inside the validity window reverts.
     * PINNED (SmartLoanLiquidationFacet.snapshotInsolvency:106):
     *   require(lastInsolventTimestamp == 0 || reArmingExpired, "Account is already being liquidated").
     */
    function testDoubleSnapshotReverts() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.warp(block.timestamp + 1 minutes); // still inside the 15-minute window
        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "second snapshot within window must revert");
        assertTrue(_revertContains(ret, "Account is already being liquidated"), "expected double-snapshot guard");
    }

    /**
     * Snapshot re-arm after expiry (audit fix M02 / fix/insolvency-snapshot-rearm-window).
     *
     * Once a snapshot's 15-minute window lapses without a liquidation, a whitelisted
     * liquidator MUST be able to take a fresh snapshot (reArmingExpired branch,
     * SmartLoanLiquidationFacet.snapshotInsolvency:104-106). Without the fix the second
     * snapshot would revert "Account is already being liquidated", permanently deadlocking
     * liquidation of an account that stayed insolvent. This is the deliberate divergence
     * from degen-prime (which has no expiry); regression-guarding it here is the whole point.
     */
    function testSnapshotReArmsAfterExpiry() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        uint256 firstTs = SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp();
        assertEq(firstTs, block.timestamp, "first snapshot timestamp");

        // Window lapses with the account still insolvent and un-liquidated.
        vm.warp(block.timestamp + 16 minutes);

        // Re-arm: a fresh snapshot must succeed and overwrite the timestamp.
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        uint256 secondTs = SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp();
        assertEq(secondTs, block.timestamp, "re-armed snapshot timestamp must be the new block time");
        assertGt(secondTs, firstTs, "re-arm must advance the snapshot timestamp");

        // And the re-armed snapshot is actionable: liquidation proceeds on it.
        // Cushion the loan's USDC for the borrow interest accrued over the 16-min warp,
        // so _repayAllDebts (balance >= getBorrowed) can fully repay (HealthAndRepay pattern).
        usdc.mint(loan, 10e6);
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertEq(_debtAt(_pricesWithAvax(CRASH_PRICE)), 0, "debt cleared via re-armed snapshot");
    }

    /**
     * getHealthRatioSnapshot returns the HR captured at snapshot time (0 < hr < 1e18).
     * PINNED (SmartLoanLiquidationFacet.snapshotInsolvency:112): ls.healthRatioSnapshot = hr.
     */
    function testGetHealthRatioSnapshotRecorded() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        uint256 hrSnap = SmartLoanLiquidationFacet(loan).getHealthRatioSnapshot();
        assertGt(hrSnap, 0, "recorded HR must be > 0");
        assertLt(hrSnap, 1e18, "recorded HR must be < 1e18 (insolvent)");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // clearInsolvencySnapshot
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * If the account recovers above water, a liquidator can clear the snapshot,
     * unblocking the owner. Requires the account to be solvent (remainsSolvent post-check).
     */
    function testClearSnapshotAfterRecovery() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        assertGt(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot taken");

        // Price recovers to $30 — account solvent again.
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.clearInsolvencySnapshot.selector),
            _feeds(),
            _prices()
        );
        assertEq(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must be cleared");
        assertEq(SmartLoanLiquidationFacet(loan).getHealthRatioSnapshot(), 0, "HR snapshot must be cleared");
    }

    /**
     * Clearing with no active snapshot reverts.
     * PINNED (clearInsolvencySnapshot:129): require(lastInsolventTimestamp > 0, "No insolvency snapshot to clear").
     */
    function testClearSnapshotWithoutSnapshotReverts() public {
        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.clearInsolvencySnapshot.selector),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "clear without snapshot must revert");
        assertTrue(_revertContains(ret, "No insolvency snapshot to clear"), "expected no-snapshot guard");
    }

    /**
     * Cannot clear while the account is still insolvent (remainsSolvent post-check).
     * The snapshot must remain intact after the revert so liquidation can still proceed.
     * PINNED (PrimeAccountModifiers.remainsSolvent): "The action may cause an account to become insolvent".
     */
    function testClearSnapshotWhileStillInsolventReverts() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.clearInsolvencySnapshot.selector),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE) // still insolvent
        );
        assertFalse(ok, "clear while insolvent must revert");
        assertTrue(_revertContains(ret, "insolvent"), "expected remainsSolvent guard");
        // The revert must roll back the snapshot deletion — it is still live.
        assertGt(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must survive failed clear");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Access control
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice A non-whitelisted address cannot call snapshotInsolvency.
    function testNonWhitelistedCannotSnapshot() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "non-whitelisted must not snapshot");
        assertTrue(_revertSelectorIs(ret, OnlyWhitelistedLiquidators.selector), "expected OnlyWhitelistedLiquidators");
    }

    /// @notice A non-whitelisted address cannot call liquidate (even with a valid snapshot taken by a real liquidator).
    function testNonWhitelistedCannotLiquidate() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        address rando = makeAddr("rando");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "non-whitelisted must not liquidate");
        assertTrue(_revertSelectorIs(ret, OnlyWhitelistedLiquidators.selector), "expected OnlyWhitelistedLiquidators");
    }

    /// @notice A non-whitelisted address cannot clear a snapshot.
    function testNonWhitelistedCannotClearSnapshot() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        address rando = makeAddr("rando");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.clearInsolvencySnapshot.selector),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "non-whitelisted must not clear");
        assertTrue(_revertSelectorIs(ret, OnlyWhitelistedLiquidators.selector), "expected OnlyWhitelistedLiquidators");
    }

    /**
     * A delisted liquidator loses snapshot rights.
     * Exercises delistLiquidators (owner-only) + the onlyWhitelistedLiquidators gate.
     */
    function testDelistedLiquidatorCannotSnapshot() public {
        // Fixture (address(this)) is the diamond owner; delist on the beacon.
        address[] memory toDelist = new address[](1);
        toDelist[0] = liquidator;
        SmartLoanLiquidationFacet(address(beacon)).delistLiquidators(toDelist);
        // The canonical whitelist lives in the beacon's diamond storage (the
        // onlyWhitelistedLiquidators modifier reads getDiamondAddress() == beacon),
        // so the view must be queried there — the per-loan proxy storage is empty.
        assertFalse(
            SmartLoanLiquidationFacet(address(beacon)).isLiquidatorWhitelisted(liquidator),
            "liquidator must be delisted"
        );

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "delisted liquidator must not snapshot");
        assertTrue(_revertSelectorIs(ret, OnlyWhitelistedLiquidators.selector), "expected OnlyWhitelistedLiquidators");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // liquidate() guards
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * liquidate without a prior snapshot reverts.
     * PINNED (liquidate:155): "No insolvency snapshot - call snapshotInsolvency first".
     */
    function testLiquidateWithoutSnapshotReverts() public {
        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "liquidate without snapshot must revert");
        assertTrue(_revertContains(ret, "No insolvency snapshot"), "expected no-snapshot guard");
    }

    /**
     * Normal-mode liquidate on an account that cannot self-repay reverts hard.
     * After stripping the loan's USDC, _repayAllDebts hits
     *   require(balance >= debtAmount, "Insufficient token balance to repay debt")
     * (SmartLoanLiquidationFacet:218). This is the case that MUST be handled via emergency mode.
     */
    function testNormalLiquidateUnderwaterReverts() public {
        _stripLoanAssets(true); // remove USDC, keep wAVAX → cannot repay USDC debt
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "normal liquidate must revert when account cannot self-repay");
        assertTrue(_revertContains(ret, "Insufficient token balance to repay debt"), "expected repay-balance guard");
    }

    /**
     * ANTI-GRIEF INVARIANT (SmartLoanLiquidationFacet.liquidate:156-160):
     * The snapshot itself is the proof of insolvency. Once a whitelisted liquidator has
     * taken it, liquidation proceeds within the window REGARDLESS of a subsequent price
     * recovery — liquidate() deliberately does NOT re-check _isSolvent(). Otherwise an
     * attacker could pump the price for a single block to block a legitimate liquidation.
     *
     * Here: snapshot at $3 (insolvent), then liquidate at $30 (recovered, solvent) inside
     * the window — must still succeed and clear the debt.
     */
    function testLiquidationProceedsDespitePriceRecovery() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.warp(block.timestamp + 1 minutes); // still inside window
        usdc.mint(loan, 10e6); // cushion borrow interest accrued over the warp
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _prices() // $30 — fully recovered, account is solvent at this price
        );
        assertEq(_debtAt(_prices()), 0, "debt must be cleared even though price recovered");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Emergency mode
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Emergency liquidation of a fully-underwater account.
     * Strip ALL assets so the account holds nothing but debt. liquidate(true):
     *   - _repayAllDebtsPartial repays what it can (here: nothing)
     *   - require(totalValue <= DUST_THRESHOLD_USD) passes (totalValue == 0)
     *   - no fee distribution
     *   - snapshot cleared, Liquidated emitted; bad debt remains (socialized to the pool).
     */
    function testEmergencyLiquidationClearsInsolventAccount() public {
        _stripLoanAssets(false); // remove BOTH wAVAX and USDC → totalValue 0, debt remains
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        uint256 debtBefore = _debtAt(_pricesWithAvax(CRASH_PRICE));
        assertGt(debtBefore, 0, "account must still owe debt going into emergency liquidation");

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, true),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );

        // Snapshot cleared; no fee was distributed (emergency mode pays no bonus).
        assertEq(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must clear");
        assertEq(wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL), 0, "no fee in emergency mode (stability)");
        assertEq(wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY), 0, "no fee in emergency mode (treasury)");
    }

    /**
     * Emergency liquidation reverts if the account still holds value above dust.
     * Keep 100 wAVAX (≈ $300 at $3) but strip USDC: partial repay clears nothing, and
     *   require(totalValue <= DUST_THRESHOLD_USD) fails.
     * PINNED (liquidate:166): "Emergency liquidation requires total account value to be 0".
     */
    function testEmergencyLiquidationRevertsWhenValueRemains() public {
        _stripLoanAssets(true); // keep wAVAX, remove USDC
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, true),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
        assertFalse(ok, "emergency liquidate must revert while value remains");
        assertTrue(
            _revertContains(ret, "Emergency liquidation requires total account value to be 0"),
            "expected dust-threshold guard"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Fee distribution detail
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * The liquidation bonus is split 1/3 to STABILITY_POOL, 2/3 to FEES_TREASURY
     * (_distributeLiquidationFee:294-302). After a normal liquidation the debt USDC has
     * been fully repaid (balance 0, skipped by the fee loop), so the only fee asset is
     * wAVAX — making the split directly assertable.
     *   stability = T/3 ; treasury = T - T/3  ⇒  treasury - 2*stability == T mod 3 ∈ {0,1,2}
     */
    function testFeeSplitOneThirdTwoThirds() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );

        uint256 stability = wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL);
        uint256 treasury = wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY);
        assertGt(stability, 0, "stability pool must receive a share");
        assertGt(treasury, 0, "treasury must receive a share");
        // treasury is the 2/3 share, stability the 1/3 share.
        assertGe(treasury, 2 * stability, "treasury share must be >= 2x stability share");
        assertLe(treasury - 2 * stability, 2, "treasury must equal 2x stability within integer rounding");
    }

    /**
     * The native-token branch of _distributeLiquidationFee (lines 267-279) fires when the
     * loan holds raw native balance. Seed the loan with native AVAX, then liquidate: both
     * STABILITY_POOL and FEES_TREASURY must receive native via safeTransferETH.
     */
    function testFeeDistributionNativeBranch() public {
        vm.deal(loan, 30e18); // raw native balance on the Prime Account

        _snapshot(_pricesWithAvax(CRASH_PRICE));
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );

        assertGt(DeploymentChainConfig.STABILITY_POOL.balance, 0, "stability pool must receive native fee");
        assertGt(DeploymentChainConfig.FEES_TREASURY.balance, 0, "treasury must receive native fee");
        // Native split is also 1/3 : 2/3.
        assertGe(
            DeploymentChainConfig.FEES_TREASURY.balance,
            2 * DeploymentChainConfig.STABILITY_POOL.balance,
            "native treasury share must be >= 2x stability share"
        );
    }

    /**
     * getLiquidationFeePercent defaults to the BASIC tier fee (14% = 140) for a fresh
     * account whose leverage tier has not been promoted to PREMIUM.
     * PINNED (SmartLoanLiquidationFacet:30,48): LIQUIDATION_FEE_PERCENT_BASIC = 140.
     */
    function testGetLiquidationFeePercentBasicDefault() public {
        assertEq(SmartLoanLiquidationFacet(loan).getLiquidationFeePercent(), 140, "BASIC tier fee must be 140");
        // Whitelist view sanity — queried on the beacon (the canonical whitelist store).
        assertTrue(
            SmartLoanLiquidationFacet(address(beacon)).isLiquidatorWhitelisted(liquidator),
            "liquidator whitelisted"
        );
        assertFalse(
            SmartLoanLiquidationFacet(address(beacon)).isLiquidatorWhitelisted(makeAddr("notLiq")),
            "random address not whitelisted"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // notInLiquidation lockout
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * While a live snapshot exists, owner-side actions guarded by notInLiquidation are
     * blocked. Borrow has [onlyOwner, remainsSolvent, noBorrowInTheSameBlock,
     * nonReentrant, notInLiquidation]; notInLiquidation is innermost so its post-check
     * fires first. Even at the recovered $30 price (where remainsSolvent would pass),
     * the borrow reverts.
     * PINNED (PrimeAccountModifiers.notInLiquidation:131): "Account is being liquidated".
     */
    function testBorrowBlockedDuringLiquidation() public {
        _snapshot(_pricesWithAvax(CRASH_PRICE));

        vm.warp(block.timestamp + 1); // satisfy noBorrowInTheSameBlock, stay inside window
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(1e6)),
            _feeds(),
            _prices() // $30 — solvent, so only notInLiquidation can block it
        );
        assertFalse(ok, "borrow must be blocked while a snapshot is live");
        assertTrue(_revertContains(ret, "Account is being liquidated"), "expected notInLiquidation guard");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DPSC-413 — zero residual value must not panic
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * When debt repayment consumes the account's entire value, `liquidate(false)` reaches
     * the fee step with `currentTotalValue == 0`. `Math.min(fee, 0)` makes the numerator 0
     * too, so the unguarded `actualLiquidationFee * 1e18 / currentTotalValue` is a literal
     * 0/0 — Panic(0x12) — and the whole liquidation reverts even though the debt was fully
     * repaid. There is no residual to take a fee from, so the correct behaviour is to skip
     * distribution and complete.
     *
     * Arrangement: strip the loan's wAVAX, then set its USDC balance to exactly its debt,
     * so `_repayAllDebts` clears the debt and leaves nothing behind.
     */
    function testLiquidateWithZeroResidualValueCompletes() public {
        // 1. Remove all wAVAX — USDC becomes the account's only asset.
        address graveyard = makeAddr("dpsc413-graveyard");
        uint256 wbal = wavax.balanceOf(loan);
        vm.prank(loan);
        wavax.transfer(graveyard, wbal);

        // 2. Set the USDC balance to exactly the outstanding debt, so repayment lands on
        //    zero on both legs. Read the debt in the same block we liquidate in.
        uint256 usdcDebt = usdcPool.getBorrowed(loan);
        deal(address(usdc), loan, usdcDebt);
        assertEq(usdc.balanceOf(loan), usdcDebt, "arrangement: balance == debt exactly");

        // 3. Collateral is 2 000 USDC against 2 000 USDC of debt: TWV = 0.8333 * 2 000 <
        //    2 000, so the account is insolvent and can be snapshotted.
        uint256[] memory prices = _prices();
        _snapshot(prices);

        // 4. Standard (non-emergency) liquidation must complete rather than panic.
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            prices
        );

        // 5. Debt cleared, nothing left to take a fee from, snapshot released.
        assertEq(_debtAt(prices), 0, "debt must be fully repaid");
        assertEq(usdc.balanceOf(loan), 0, "no residual USDC");
        assertEq(
            SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(),
            0,
            "snapshot must be cleared on success"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DPSC-532 — the liquidation fee is pinned to the snapshotted leverage tier
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev First slot of PrimeLeverageStorage (LeverageTierLib.LeverageTier leverageTier).
    bytes32 internal constant PRIME_LEVERAGE_SLOT =
        keccak256("diamond.standard.prime.leverage.storage");

    /**
     * Part 2 of the fix. `snapshotInsolvency` captures the tier and `liquidate` reads the
     * fee from that capture, so a tier change inside the window cannot move the fee.
     *
     * The tier is flipped here by writing diamond storage directly rather than through
     * `stakePrimeAndActivatePremium` — that entry point is now blocked by
     * `notInLiquidation` (part 1, pinned separately in LeverageTiers.t.sol). Writing the
     * slot proves the fee is snapshot-derived independently of which entry points exist.
     */
    function testLiquidationFeeUsesSnapshottedTierNotLiveTier() public {
        uint256[] memory prices = _pricesWithAvax(CRASH_PRICE);

        // Snapshot while BASIC — the fee owed is the BASIC rate.
        _snapshot(prices);
        assertEq(
            SmartLoanLiquidationFacet(loan).getLiquidationFeePercent(),
            140, // LIQUIDATION_FEE_PERCENT_BASIC
            "arrangement: account is BASIC at snapshot time"
        );

        uint256 stabilityBefore = wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL);
        uint256 treasuryBefore  = wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY);

        // Flip the live tier to PREMIUM mid-window.
        vm.store(loan, PRIME_LEVERAGE_SLOT, bytes32(uint256(1)));
        assertEq(
            SmartLoanLiquidationFacet(loan).getLiquidationFeePercent(),
            70, // LIQUIDATION_FEE_PERCENT_PREMIUM
            "arrangement: live tier now reads PREMIUM"
        );

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            prices
        );

        uint256 collected =
            (wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL) - stabilityBefore) +
            (wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY) - treasuryBefore);
        assertGt(collected, 0, "fee must have been distributed");

        // Re-run the same liquidation with the tier left at BASIC throughout; the fee must
        // be identical, i.e. the mid-window flip changed nothing.
        uint256 collectedWithFlip = collected;
        _rerunLiquidationWithoutTierFlip(prices);
        assertEq(
            _lastCollected,
            collectedWithFlip,
            "fee must be identical whether or not the tier was flipped mid-window"
        );
    }

    uint256 internal _lastCollected;

    /// @dev Rebuilds the setUp arrangement in a fresh loan and liquidates it without
    ///      touching the tier, recording the fee collected.
    function _rerunLiquidationWithoutTierFlip(uint256[] memory prices) internal {
        (address borrower2, address loan2) = _createLoanFor("borrower2");
        _fundAvax(borrower2, loan2, 100e18);
        vm.warp(block.timestamp + 1);
        vm.prank(borrower2);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan2,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(2000e6)),
            _feeds(),
            _prices()
        );
        vm.prank(loan2);
        wavax.approve(loan2, type(uint256).max);

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm, loan2,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(), prices
        );

        uint256 sBefore = wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL);
        uint256 tBefore = wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY);
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm, loan2,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(), prices
        );
        _lastCollected =
            (wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL) - sBefore) + (wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY) - tBefore);
    }

    /**
     * Migration behaviour for the pinned tier, and the reason the field is a plain enum
     * rather than an offset encoding.
     *
     * `leverageTierSnapshot` is a slot append, so a snapshot that was already live when the
     * facet cut landed reads 0 — which is BASIC, the HIGHER fee. That is the conservative
     * direction and it is deliberate: encoding "not recorded" separately and falling back to
     * the live tier would reintroduce the live-tier read this snapshot exists to remove, on
     * any path that ever zeroes the slot (and two paths delete it). The cost is that a PREMIUM
     * account with an in-flight snapshot is charged 140 bps instead of 70 for the remainder of
     * a 15-minute window — an over-charge to that user, never an under-charge to the protocol.
     */
    function testUnsetTierSnapshotChargesBasicNeverTheLiveTier() public {
        uint256[] memory prices = _pricesWithAvax(CRASH_PRICE);
        _snapshot(prices);

        bytes32 snapSlot = bytes32(uint256(keccak256("diamond.standard.liquidation.snapshot.storage")) + 4);

        // Simulate a snapshot written by the pre-upgrade facet, and set the live tier to
        // PREMIUM so a live-tier read would be visible as a halved fee.
        vm.store(loan, snapSlot, bytes32(uint256(0)));
        vm.store(loan, PRIME_LEVERAGE_SLOT, bytes32(uint256(1)));
        assertEq(
            SmartLoanLiquidationFacet(loan).getLiquidationFeePercent(),
            70, // LIQUIDATION_FEE_PERCENT_PREMIUM
            "arrangement: live tier reads PREMIUM"
        );

        uint256 stabilityBefore = wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL);
        uint256 treasuryBefore  = wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY);

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.liquidate.selector, false),
            _feeds(),
            prices
        );

        uint256 collected =
            (wavax.balanceOf(DeploymentChainConfig.STABILITY_POOL) - stabilityBefore) +
            (wavax.balanceOf(DeploymentChainConfig.FEES_TREASURY) - treasuryBefore);

        // An unset snapshot must charge BASIC, i.e. the same as a control liquidation with no
        // tier flip at all — not the halved PREMIUM fee the live tier would have given.
        _rerunLiquidationWithoutTierFlip(prices);
        assertApproxEqRel(
            collected,
            _lastCollected,
            1e12, // 0.0001%
            "unset snapshot must charge BASIC, never follow the live tier"
        );
    }
}
