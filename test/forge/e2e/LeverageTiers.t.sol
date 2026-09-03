// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {PrimeLeverageFacet} from "../../../contracts/facets/PrimeLeverageFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";
import {LeverageTierLib} from "../../../contracts/lib/LeverageTierLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SolvencyFacetProd} from "../../../contracts/facets/SolvencyFacetProd.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";

/**
 * @title LeverageTiersTest — SP4.5
 *
 * Pins the BASIC/PREMIUM leverage-tier mechanics end-to-end:
 *   borrowing capacity differences, PRIME staking requirement,
 *   staking-ratio boundary arithmetic, downgrade-without-solvency-check,
 *   and view-function correctness.
 *
 * PrimeLeverageFacet API found (PrimeLeverageFacet.sol):
 *   depositPrime(uint256)                    — fund loan with PRIME (onlyOwner, remainsSolvent)
 *   stakePrimeAndActivatePremium()           — stake required PRIME + switch to PREMIUM (onlyOwner, nonReentrant, NO remainsSolvent)
 *   deactivatePremiumTier(bool withdrawStake)— repay PRIME debt + switch to BASIC   (onlyOwner, nonReentrant, NO remainsSolvent)
 *   getPrimeStakedAmount() view              — PRIME tokens marked as staked in DiamondStorageLib
 *   unstakePrime(uint256)                    — reduce staked PRIME if requirements still met (onlyOwner, nonReentrant)
 *   updatePrimeDebt()                        — snapshot PRIME debt to storage
 *   repayPrimeDebt(uint256)                  — burn 50% / treasury 50% from PRIME balance (onlyOwner)
 *   getRequiredPrimeStake(tier, usdValue) view
 *   getLeverageTier() view                   — reads DiamondStorageLib (no oracle needed)
 *   getLeverageTierFullInfo() view           — returns (tier, stakedPrime, recordedDebt)
 *   shouldLiquidatePrimeDebt() nonview       — updates snapshot; returns bool
 *   liquidatePrimeDebt()                     — emergency liquidation (onlyWhitelistedLiquidators)
 *
 * Selector additions (on-demand, pause→cut→unpause):
 *   stakePrimeAndActivatePremium, deactivatePremiumTier, getLeverageTier,
 *   getPrimeStakedAmount, getLeverageTierFullInfo, getRequiredPrimeStake
 *   — none of these conflict with the base fixture's cut selectors.
 *
 * DIFFERENTIATED tier setup (overrides fixture's uniform DEBT_COVERAGE for both tiers):
 *   BASIC_COVERAGE  = 0.5e18   → max USDC ≈ 3 000 with 100 AVAX at $30
 *   PREMIUM_COVERAGE = DEBT_COVERAGE = 0.833…e18 → max USDC ≈ 15 000 (inherited from fixture)
 *
 * MATRIX RULE: no literal addresses; uses DeploymentChainConfig.NATIVE_ADDRESS,
 * NATIVE_SYMBOL (fixture constant), and fixture members (usdc, prime, tokenManager).
 * Native symbol is chain-agnostic — passes under both "test" (AVAX) and "arbitrum" (ETH) configs.
 *
 * ORACLE WRAPPING: stakePrimeAndActivatePremium and deactivatePremiumTier both call
 * _getTotalValue() and/or _getDebt() via ProxyConnector.proxyDelegateCalldata, which
 * re-appends the oracle payload from the outer calldata. Any outer call reaching these
 * internal helpers must be wrapped with RedstoneLib.wrap/wrapExpectSuccess.
 *
 * Seven tests:
 *   1. testDefaultTierIsBasic                           — tier=BASIC at creation; safe borrow succeeds
 *   2. testBasicCapacityRevertsOverLimit                — borrow just over BASIC limit reverts insolvent
 *   3. testPremiumExpandsBorrowCapacity                 — activate PREMIUM; borrow over BASIC succeeds
 *   4. testPremiumActivationRevertsWithoutSufficientPrime — stake check boundary (PINNED sol:118)
 *   5. testPrimeStakingBoundaryMath                     — exact 1500 PRIME boundary (LeverageTierLib.sol:71)
 *   6. testDowngradeBlockedWhenItWouldCauseInsolvency   — remainsSolvent blocks the downgrade; succeeds after deleveraging
 *   7. testGetLeverageTierReflectsAllSwitches           — view reflects BASIC→PREMIUM→BASIC
 */
contract LeverageTiersTest is DeltaPrimeFixture {

    // ─── Tier coverage constants ─────────────────────────────────────────────
    // BASIC_COVERAGE = 0.5e18 (< 5× LTV ceiling).
    // PREMIUM_COVERAGE uses the fixture's DEBT_COVERAGE (≈ 5/6 · 1e18 ≈ 0.833…e18).
    // Both are well within setTieredDebtCoverage's per-tier limits:
    //   BASIC max  = 0.833333…e18 (enforced by TokenManager, line 476)
    //   PREMIUM max = 0.909090…e18 (enforced by TokenManager, line 482)
    uint256 private constant BASIC_COVERAGE_OVERRIDE = 0.5e18;

    // PRIME staking/debt ratios for PREMIUM tier (matches integration test intent):
    //   5 PRIME tokens per $100 borrowed (staking ratio, TokenManager.setTieredPrimeStakingRatio)
    //   2 PRIME tokens per $100 borrowed per year (debt ratio, TokenManager.setTieredPrimeDebtRatio)
    uint256 private constant PRIME_STAKING_RATIO = 5e18;
    uint256 private constant PRIME_DEBT_RATIO    = 2e18;

    // ─── Borrow boundaries (100 AVAX @ $30, BASIC_COVERAGE = 0.5e18) ───────
    //
    // Integer boundary derivation:
    //   AVAX_TWV = 30e8 × 100e18 × 0.5e18 / 1e26 = 1500e18   (18-dec USD)
    //   USDC_TWV(X_atoms) = 1e8 × X × 0.5e18 / (1e6 × 1e8) = X × 0.5e12
    //   Debt(X_atoms) = X × 1e12      (1 USDC = $1, 6-dec amount → 18-dec USD)
    //   Solvency: AVAX_TWV + USDC_TWV ≥ Debt
    //             1500e18 + X × 0.5e12 ≥ X × 1e12
    //             1500e18 ≥ X × 0.5e12
    //             X ≤ 3 000e6          (boundary = 3 000 USDC atoms)
    //   At X = 3000e6: HR = 3000e18 / 3000e18 = 1e18 (solvent, just at boundary)
    //   At X = 3001e6: HR = 3000.5e18 / 3001e18 < 1e18 (insolvent)
    uint256 internal constant SAFE_BORROW_BASIC = 2_999e6;   // HR > 1e18
    uint256 internal constant OVER_BORROW_BASIC = 3_001e6;   // HR < 1e18, > 3000e18 boundary

    // ─── Required PRIME stake for 100 AVAX at $30, no debt ──────────────────
    //   totalCollateral = _getTotalValue() - _getDebt() = $3000e18 - 0 = $3000e18
    //   maxBorrowable = totalCollateral × 10 = $30 000e18
    //   requiredStake = $30 000e18 × 5e18 / (100 × 1e18) = 1 500e18   [LeverageTierLib.sol:71]
    uint256 internal constant REQUIRED_PRIME_STAKE = 1_500e18;

    // ─── setUp ───────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp();

        // Override tiered debt coverage so BASIC and PREMIUM are distinguishable.
        // super.setUp() sets BOTH tiers to DEBT_COVERAGE (0.833…e18) for all three tokens.
        // We override BASIC to 0.5e18 for NATIVE and USDC; PRIME coverage is left at 0
        // here and for PREMIUM (PRIME is staked collateral, not debt collateral; it is
        // not in ownedAssets when minted directly, so its coverage value doesn't affect
        // TWV in tests, but we set it explicitly for semantic correctness).
        tokenManager.setTieredDebtCoverage(
            LeverageTierLib.LeverageTier.BASIC, DeploymentChainConfig.NATIVE_ADDRESS, BASIC_COVERAGE_OVERRIDE
        );
        tokenManager.setTieredDebtCoverage(
            LeverageTierLib.LeverageTier.BASIC, address(usdc), BASIC_COVERAGE_OVERRIDE
        );
        // PREMIUM retains DEBT_COVERAGE (≈ 0.833…e18) from super.setUp().
        // PRIME: set to 0 for both tiers (not counted as debt-covered collateral).
        tokenManager.setTieredDebtCoverage(
            LeverageTierLib.LeverageTier.BASIC, address(prime), 0
        );
        tokenManager.setTieredDebtCoverage(
            LeverageTierLib.LeverageTier.PREMIUM, address(prime), 0
        );

        // Staking ratio: 5 PRIME tokens required per $100 of max borrowable value (PREMIUM only).
        // BASIC staking ratio stays 0 (unset), so BASIC requires no PRIME stake.
        tokenManager.setTieredPrimeStakingRatio(LeverageTierLib.LeverageTier.PREMIUM, PRIME_STAKING_RATIO);

        // Debt accrual: 2 PRIME tokens per $100 borrowed per year in PREMIUM tier.
        // Required so deactivatePremiumTier can repay non-zero PRIME debt in tests 6 and 7.
        tokenManager.setTieredPrimeDebtRatio(LeverageTierLib.LeverageTier.PREMIUM, PRIME_DEBT_RATIO);

        // Fund the USDC lending pool so borrow() calls have liquidity.
        address lender = makeAddr("lender");
        usdc.mint(lender, 2_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 2_000_000e6);
        usdcPool.deposit(2_000_000e6);
        vm.stopPrank();

        // ── On-demand: cut PrimeLeverageFacet selectors into the beacon ──
        // Only selectors exercised by the tests below. None overlap with the base
        // fixture's selector set (loupe / view / assetsOps / liquidation / solvency /
        // withdrawalIntent). Pattern: pause → cut → unpause (beacon unpaused after super.setUp()).
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new PrimeLeverageFacet()),
            IDiamondCut.FacetCutAction.Add,
            _primeLeverageSelectors()
        );
        IDiamondCut(address(beacon)).diamondCut(cuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();
    }

    // ─── Test 1: Default tier is BASIC ───────────────────────────────────────

    /**
     * A freshly-created loan has no tier explicitly stored (DiamondStorageLib default
     * for the LeverageTier enum = 0 = BASIC). getLeverageTier() reflects this without
     * an oracle payload (pure storage read).
     *
     * With BASIC_COVERAGE = 0.5e18 and 100 AVAX at $30:
     *   SAFE_BORROW_BASIC = 2999e6 USDC → HR > 1e18 → borrow succeeds.
     *
     * PINNED: DiamondStorageLib.getPrimeLeverageTier() returns BASIC (= 0) by default
     *         (LeverageTier enum zero-initialises to BASIC in DiamondStorageLib storage).
     */
    function testDefaultTierIsBasic() public {
        (address borrower, address loan) = _createLoanFor("tierDefault");
        _fundAvax(borrower, loan, 100e18);

        // getLeverageTier is a view reading DiamondStorageLib — no oracle needed.
        LeverageTierLib.LeverageTier tier = PrimeLeverageFacet(loan).getLeverageTier();
        assertEq(uint8(tier), uint8(LeverageTierLib.LeverageTier.BASIC), "default tier must be BASIC");

        // Safe borrow within BASIC capacity must succeed.
        _borrowUsdc(borrower, loan, SAFE_BORROW_BASIC);
        assertEq(usdc.balanceOf(loan), SAFE_BORROW_BASIC, "loan must hold borrowed USDC");
    }

    // ─── Test 2: Over-BASIC borrow reverts insolvent ─────────────────────────

    /**
     * OVER_BORROW_BASIC = 3001e6 USDC exceeds the BASIC solvency boundary (3000e6).
     * The remainsSolvent post-check in AssetsOperationsFacet.borrow fires.
     *
     * Solvency arithmetic at 3001e6 USDC with BASIC_COVERAGE = 0.5e18:
     *   AVAX_TWV  = 1500e18
     *   USDC_TWV  = 3001e6 × 0.5e18 / 1e6 ≈ 1500.5e18
     *   Debt      = 3001e18
     *   HR        = 3000.5e18 × 1e18 / 3001e18 ≈ 0.9998e18 < 1e18 → insolvent
     *
     * PINNED (PrimeAccountModifiers.remainsSolvent):
     *   "The action may cause an account to become insolvent"
     */
    function testBasicCapacityRevertsOverLimit() public {
        (address borrower, address loan) = _createLoanFor("basicOverLimit");
        _fundAvax(borrower, loan, 100e18);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), OVER_BORROW_BASIC),
            _feeds(), _prices()
        );
        assertFalse(ok, "borrow over BASIC capacity must revert");
        assertTrue(_revertContains(ret, "insolvent"), "expected remainsSolvent guard");
    }

    // ─── Test 3: PREMIUM tier expands borrow capacity ────────────────────────

    /**
     * Activating PREMIUM (DEBT_COVERAGE ≈ 0.833…e18) allows borrowing beyond the
     * BASIC limit (3000 USDC) while remaining solvent.
     *
     * Setup:
     *   Mint 1500e18 PRIME directly to the loan (= REQUIRED_PRIME_STAKE).
     *   stakePrimeAndActivatePremium() computes requiredMaxStake = 1500e18 and stakes it.
     *   After activation, getLeverageTier() = PREMIUM.
     *   Borrow OVER_BORROW_BASIC (3001 USDC) → now within PREMIUM capacity → succeeds.
     *
     * Oracle wrapping note: stakePrimeAndActivatePremium calls _getTotalValue() and
     * _getDebt() (both via ProxyConnector) → outer call must be wrapped.
     *
     * PINNED (PrimeLeverageFacet.sol:50–58): activatePremium sets tier and snapshots PRIME debt.
     */
    function testPremiumExpandsBorrowCapacity() public {
        (address borrower, address loan) = _createLoanFor("premiumBorrower");
        _fundAvax(borrower, loan, 100e18);

        // Mint exactly the required PRIME stake into the loan.
        // Direct mint bypasses depositPrime() (which would require oracle wrapping) and
        // does NOT add PRIME to ownedAssets, so _getTotalValue() stays at $3000e18 (AVAX only).
        prime.mint(loan, REQUIRED_PRIME_STAKE);

        // Activate PREMIUM — must be wrapped because it calls _getTotalValue() + _getDebt().
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );

        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "tier must be PREMIUM after stakePrimeAndActivatePremium"
        );

        // Borrow OVER_BORROW_BASIC (3001 USDC): above BASIC limit, within PREMIUM capacity.
        // PREMIUM TWV at 3001 USDC: AVAX_TWV ≈ 2500e18 + USDC_TWV ≈ 2500.83e18 > Debt 3001e18 → solvent.
        _borrowUsdc(borrower, loan, OVER_BORROW_BASIC);
        assertEq(usdc.balanceOf(loan), OVER_BORROW_BASIC, "loan must hold USDC borrowed in PREMIUM tier");
    }

    // ─── Test 4: PREMIUM without sufficient PRIME stake reverts ──────────────

    /**
     * stakePrimeAndActivatePremium computes requiredMaxStake = 1500e18 (for 100 AVAX at $30,
     * no debt, staking ratio = 5e18). If the loan holds 1500e18 - 1 wei of PRIME,
     * the internal stakePrime() check fires.
     *
     * PINNED (PrimeLeverageFacet.sol:118 — private stakePrime):
     *   require(_getAvailableBalance("PRIME") >= amount, "Insufficient PRIME balance")
     *
     * _getAvailableBalance("PRIME") = WithdrawalIntentFacet.getAvailableBalance("PRIME")
     *                               = prime.balanceOf(loan) - getTotalIntentAmount("PRIME")
     *                               = (REQUIRED_PRIME_STAKE - 1) - 0   <  REQUIRED_PRIME_STAKE
     * → reverts ✓
     */
    function testPremiumActivationRevertsWithoutSufficientPrime() public {
        (address borrower, address loan) = _createLoanFor("premiumInsufficient");
        _fundAvax(borrower, loan, 100e18);

        // One wei short of the 1500e18 required stake.
        prime.mint(loan, REQUIRED_PRIME_STAKE - 1);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );
        assertFalse(ok, "activation with insufficient PRIME must revert");
        // PINNED: PrimeLeverageFacet.sol:118 private stakePrime()
        assertTrue(_revertContains(ret, "Insufficient PRIME balance"), "expected insufficient PRIME revert");
    }

    // ─── Test 5: PRIME staking ratio math — exact boundary ───────────────────

    /**
     * LeverageTierLib.sol:71 (via getRequiredPrimeStake):
     *   requiredStake = maxBorrowableValue × primeStakingRatio / (100 × 1e18)
     *
     * Parameters:
     *   maxBorrowableValue = totalCollateral × 10
     *                      = ($3000e18 AVAX) × 10 = $30 000e18
     *   primeStakingRatio  = 5e18
     *   requiredStake      = $30 000e18 × 5e18 / (100 × 1e18) = 1 500e18
     *
     * Case A (OK):   balance = 1500e18           → _getAvailableBalance ≥ required → succeeds
     * Case B (FAIL): balance = 1500e18 − 1 wei   → _getAvailableBalance < required → reverts
     *
     * PINNED revert: PrimeLeverageFacet.sol:118 "Insufficient PRIME balance"
     */
    function testPrimeStakingBoundaryMath() public {
        // Case A: exact required stake → succeeds.
        (address borrowerA, address loanA) = _createLoanFor("stakeBoundaryOK");
        _fundAvax(borrowerA, loanA, 100e18);
        prime.mint(loanA, REQUIRED_PRIME_STAKE); // exactly 1500e18

        vm.warp(block.timestamp + 1);
        vm.prank(borrowerA);
        RedstoneLib.wrapExpectSuccess(
            vm, loanA,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );
        // Verify the staked amount equals the required stake.
        assertEq(
            PrimeLeverageFacet(loanA).getPrimeStakedAmount(),
            REQUIRED_PRIME_STAKE,
            "staked amount must equal required stake at exact boundary"
        );
        assertEq(
            uint8(PrimeLeverageFacet(loanA).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "Case A: tier must be PREMIUM at exact stake boundary"
        );

        // Case B: one wei short → reverts.
        (address borrowerB, address loanB) = _createLoanFor("stakeBoundaryFail");
        _fundAvax(borrowerB, loanB, 100e18);
        prime.mint(loanB, REQUIRED_PRIME_STAKE - 1); // 1 wei short

        vm.warp(block.timestamp + 1);
        vm.prank(borrowerB);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loanB,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );
        assertFalse(ok, "one wei short of required stake must revert");
        // PINNED: PrimeLeverageFacet.sol:118
        assertTrue(_revertContains(ret, "Insufficient PRIME balance"), "expected boundary revert one wei short");
        // Verify tier was NOT changed on failure (still BASIC).
        assertEq(
            uint8(PrimeLeverageFacet(loanB).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "Case B: tier must remain BASIC after failed activation"
        );
    }

    // ─── Test 6: Downgrade to BASIC while USD debt exceeds BASIC capacity ────

    /**
     * deactivatePremiumTier(bool) carries remainsSolvent (audit LOW-02, added 2026-08-25).
     * PINNED (PrimeLeverageFacet.sol):
     *   function deactivatePremiumTier(bool) external onlyOwner nonReentrant remainsSolvent notInLiquidation
     *
     * This test previously pinned the OPPOSITE behaviour, under the name
     * testDowngradeAllowedWithoutSolvencyCheck: the downgrade was permitted even when it
     * left the account insolvent. That was a behaviour record, not a design endorsement --
     * the downgrade drops tieredDebtCoverage from PREMIUM (0.833e18 here) to BASIC (0.5e18)
     * across every asset while repayPrimeDebt settles only the PRIME staking debt, so a
     * leveraged owner could cross the liquidation threshold in a single call. It is now
     * blocked; the owner must deleverage first.
     *
     * Insolvency arithmetic that the guard now catches (100 AVAX at $30, 5000 USDC debt):
     *   AVAX_TWV  = 30 x 100 x 0.5e18 = 1500e18
     *   USDC_TWV  = 5000e6 x 0.5e18 / 1e6 = 2500e18
     *   Total TWV = 4000e18  <  Debt 5000e18  ->  HR = 0.8e18 < 1e18 -> insolvent
     *
     * The second half proves the guard is not a blanket ban: once the debt is inside BASIC
     * capacity the same downgrade succeeds.
     */
    function testDowngradeBlockedWhenItWouldCauseInsolvency() public {
        (address borrower, address loan) = _createLoanFor("downgradeBorrower");
        _fundAvax(borrower, loan, 100e18);
        // Mint 2000e18 PRIME: 1500e18 for required stake + buffer for PRIME debt repayment.
        prime.mint(loan, 2_000e18);

        // Activate PREMIUM.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );

        // Borrow 5000 USDC: exceeds BASIC limit (~3000), within PREMIUM limit (~15000).
        _borrowUsdc(borrower, loan, 5_000e6);

        // Advance 1 day so PRIME debt accrues > 0 (required by repayPrimeDebt inside deactivate).
        vm.warp(block.timestamp + 1 days);

        // The downgrade would leave the account insolvent, so it must now revert.
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.deactivatePremiumTier.selector, false),
            _feeds(), _prices()
        );
        assertFalse(ok, "downgrade into insolvency must revert");
        assertTrue(
            _revertContains(ret, "The action may cause an account to become insolvent"),
            "expected remainsSolvent guard"
        );

        // Tier is unchanged, and the account is still solvent under PREMIUM coverage.
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "tier must remain PREMIUM after the blocked downgrade"
        );

        // Deleverage to inside BASIC capacity, then the same downgrade succeeds.
        usdc.mint(borrower, 3_000e6);
        vm.prank(borrower);
        usdc.approve(loan, type(uint256).max);
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.repay.selector, bytes32("USDC"), uint256(3_000e6)),
            _feeds(), _prices()
        );

        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.deactivatePremiumTier.selector, false),
            _feeds(), _prices()
        );
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "downgrade must succeed once the account is solvent under BASIC coverage"
        );
    }

    // ─── Test 7: getLeverageTier view reflects all switches ──────────────────

    /**
     * Pins that getLeverageTier() (a pure storage read, no oracle) correctly returns
     * the current tier at every state transition:
     *   initial → BASIC
     *   after stakePrimeAndActivatePremium → PREMIUM
     *   after deactivatePremiumTier → BASIC
     *
     * getLeverageTierFullInfo() is also checked to confirm it mirrors getLeverageTier()
     * and reports the staked PRIME amount correctly.
     *
     * Note: deactivatePremiumTier calls repayPrimeDebt internally, which requires
     * currentPrimeDebt > 0 ("Amount must be > 0"). To ensure non-zero debt, we borrow
     * 1000 USDC and advance 1 day before deactivating (accrued ≈ 0.055e18 PRIME).
     * After deactivation, the account remains solvent (BASIC TWV ≈ 2000e18 > Debt 1000e18).
     */
    function testGetLeverageTierReflectsAllSwitches() public {
        (address borrower, address loan) = _createLoanFor("tierViewReflector");
        _fundAvax(borrower, loan, 100e18);
        prime.mint(loan, 2_000e18); // stake (1500e18) + repayment buffer

        // ── State 1: initial → BASIC ──
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "initial tier must be BASIC"
        );

        // ── Activate PREMIUM ──
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), _prices()
        );

        // ── State 2: PREMIUM ──
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "tier must be PREMIUM after activation"
        );
        // getLeverageTierFullInfo() must agree.
        (LeverageTierLib.LeverageTier infoTier, uint256 stakedPrime,) = PrimeLeverageFacet(loan).getLeverageTierFullInfo();
        assertEq(uint8(infoTier), uint8(LeverageTierLib.LeverageTier.PREMIUM), "fullInfo.currentTier must be PREMIUM");
        assertEq(stakedPrime, REQUIRED_PRIME_STAKE, "fullInfo.stakedPrime must equal required stake");

        // Borrow 1000 USDC so PRIME debt accrues when we advance time.
        _borrowUsdc(borrower, loan, 1_000e6);

        // Advance 1 day: PRIME debt ≈ $1000 × 2 / (100 × 365) ≈ 0.0548e18 > 0 ✓
        vm.warp(block.timestamp + 1 days);

        // ── Deactivate back to BASIC ──
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.deactivatePremiumTier.selector, false),
            _feeds(), _prices()
        );

        // ── State 3: BASIC ──
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "tier must return to BASIC after deactivation"
        );
        (LeverageTierLib.LeverageTier infoTier2,,) = PrimeLeverageFacet(loan).getLeverageTierFullInfo();
        assertEq(uint8(infoTier2), uint8(LeverageTierLib.LeverageTier.BASIC), "fullInfo.currentTier must be BASIC after deactivation");

        // Account remains solvent after downgrade with only 1000 USDC debt:
        //   AVAX_TWV  = 30 × 100 × 0.5e18 = 1500e18
        //   USDC_TWV  = 1000e6 × 0.5e18 / 1e6 = 500e18
        //   Total TWV = 2000e18  >  Debt 1000e18  →  HR = 2e18 > 1e18 → solvent
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(SolvencyFacetProd.getHealthRatio.selector),
            _feeds(), _prices()
        );
        assertTrue(ok, "getHealthRatio must succeed");
        uint256 hr = abi.decode(ret, (uint256));
        assertGt(hr, 1e18, "account must remain solvent after downgrade with 1000 USDC debt");
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    // PrimeLeverageFacet selectors cut on-demand in setUp().
    // Only selectors exercised by the tests above — follows the add-on-demand rule.
    // Selector source: PrimeLeverageFacet.sol public/external function signatures.
    function _primeLeverageSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PrimeLeverageFacet.stakePrimeAndActivatePremium.selector;
        s[1] = PrimeLeverageFacet.deactivatePremiumTier.selector;
        s[2] = PrimeLeverageFacet.getLeverageTier.selector;
        s[3] = PrimeLeverageFacet.getPrimeStakedAmount.selector;
        s[4] = PrimeLeverageFacet.getLeverageTierFullInfo.selector;
        s[5] = PrimeLeverageFacet.getRequiredPrimeStake.selector;
    }

    // Advance one second then borrow `amount` USDC as the loan owner.
    function _borrowUsdc(address borrower, address loan, uint256 amount) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), amount),
            _feeds(), _prices()
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DPSC-532 — tier activation is blocked inside the liquidation window
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * `stakePrimeAndActivatePremium` now carries `notInLiquidation`. Without it a BASIC
     * owner could flip to PREMIUM after a liquidator had snapshotted the account and halve
     * the liquidation fee (140 -> 70 bps of initial debt), diverting the difference from
     * the stability pool and treasury. The stake required at the insolvency boundary is a
     * small fraction of the fee avoided, so the trade was heavily in the owner's favour.
     *
     * The guard is window-aware, so it restricts the owner during a live liquidation rather
     * than locking them out of the tier: once the snapshot expires the call works again.
     */
    function testTierActivationBlockedDuringLiquidationWindow() public {
        (address borrower, address loan) = _createLoanFor("tierFlipper");
        _fundAvax(borrower, loan, 100e18); // $3 000 at $30

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(2000e6)),
            _feeds(), _prices()
        );

        // Enough PRIME for any required stake at the crash price.
        prime.mint(loan, 100_000e18);

        // AVAX $30 -> $3 makes the account insolvent; liquidator snapshots it.
        uint256[] memory crash = _pricesWithAvax(3e8);
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(), crash
        );

        // The flip must be refused while the snapshot is live.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), crash
        );
        assertFalse(ok, "tier activation must be blocked while a snapshot is live");
        assertTrue(_revertContains(ret, "Account is being liquidated"), "expected notInLiquidation guard");
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "tier must be unchanged"
        );

        // After the window lapses the owner regains the tier controls.
        vm.warp(block.timestamp + 15 minutes);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(), crash
        );
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "tier activation must work again once the window expires"
        );
    }
}
