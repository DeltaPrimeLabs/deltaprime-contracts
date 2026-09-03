// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {PrimeLeverageFacet} from "../../../contracts/facets/PrimeLeverageFacet.sol";
import {LeverageTierLib} from "../../../contracts/lib/LeverageTierLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";

/**
 * Prime-debt liquidation e2e (PrimeLeverageFacet.shouldLiquidatePrimeDebt /
 * liquidatePrimeDebt) — the PREMIUM-tier safety net that seizes staked PRIME when a
 * PREMIUM account's accrued PRIME debt outgrows its stake.
 *
 * This path was previously untested despite carrying the CRITICAL-01 audit fix
 * (unit mismatch in shouldLiquidatePrimeDebt's weekly-accrual buffer).
 *
 * Trigger arithmetic (LeverageTierLib.getCurrentPrimeDebt):
 *   accruedPrimeDebt = borrowedValueUSD * primeDebtRatio * timeElapsed
 *                       / (100 * 365 days * 1e18)
 *   shouldLiquidatePrimeDebt() ⇔ recordedPrimeDebt > weeklyAccrual + stakedPrime
 *
 * Setup tuned so the stake is small and accrual is fast, giving a deterministic trigger:
 *   - PREMIUM staking ratio = 0.01 PRIME / $100 of max-borrowable
 *       requiredStake = (totalCollateral $3000 × 10) × 0.01e18 / (100 × 1e18) = 3 PRIME
 *   - PREMIUM debt ratio = 100 PRIME / $100 borrowed / year (fast accrual for testing)
 *   - borrow $1 000 → ~1 000 PRIME/yr accrual ⇒ stake (3) overtaken within ~8 days;
 *     a 60-day warp clears the threshold with wide margin.
 */
contract PrimeDebtLiquidationTest is DeltaPrimeFixture {
    // PREMIUM staking ratio (per $100 of max-borrowable) → 3 PRIME staked for this loan.
    uint256 internal constant PREMIUM_STAKING_RATIO = 0.01e18;
    // PREMIUM PRIME-debt ratio (per $100 borrowed per year) — high, so accrual is testably fast.
    uint256 internal constant PREMIUM_DEBT_RATIO = 100e18;
    // Stake produced by the above for 100 AVAX @ $30 (max-borrowable = $30 000).
    uint256 internal constant EXPECTED_STAKE = 3e18;

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Mirror of PrimeAccountModifiers.OnlyWhitelistedLiquidators (same name+args ⇒ same selector).
    error OnlyWhitelistedLiquidators();

    address internal borrower;
    address internal loan;

    function setUp() public override {
        super.setUp();

        // PREMIUM tier ratios (BASIC stays 0 — no PRIME requirement in BASIC).
        tokenManager.setTieredPrimeStakingRatio(LeverageTierLib.LeverageTier.PREMIUM, PREMIUM_STAKING_RATIO);
        tokenManager.setTieredPrimeDebtRatio(LeverageTierLib.LeverageTier.PREMIUM, PREMIUM_DEBT_RATIO);

        // Fund the USDC lending pool.
        address lender = makeAddr("lender");
        usdc.mint(lender, 2_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 2_000_000e6);
        usdcPool.deposit(2_000_000e6);
        vm.stopPrank();

        // Cut PrimeLeverageFacet selectors (pause → cut → unpause).
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new PrimeLeverageFacet()),
            IDiamondCut.FacetCutAction.Add,
            _primeLeverageSelectors()
        );
        IDiamondCut(address(beacon)).diamondCut(cuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();

        // Create a PREMIUM loan with $1 000 of debt.
        (borrower, loan) = _createLoanFor("premiumBorrower");
        _fundAvax(borrower, loan, 100e18);
        prime.mint(loan, 50e18); // ample PRIME for the 3-PRIME stake + later liquidation transfer

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector),
            _feeds(),
            _prices()
        );
        assertEq(PrimeLeverageFacet(loan).getPrimeStakedAmount(), EXPECTED_STAKE, "stake must be 3 PRIME");
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.PREMIUM),
            "tier must be PREMIUM after activation"
        );

        _borrowUsdc(1_000e6); // $1 000 of USD debt accrues PRIME debt over time
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // shouldLiquidatePrimeDebt trigger
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Right after activation, accrued PRIME debt ≈ 0 ⇒ liquidation not triggered.
    function testShouldNotLiquidateImmediately() public {
        assertFalse(_shouldLiquidate(), "PRIME liquidation must not trigger before debt accrues");
    }

    /**
     * After a 60-day warp the accrued PRIME debt overtakes (stake + one-week buffer),
     * so shouldLiquidatePrimeDebt returns true. This is the boundary the CRITICAL-01 fix
     * governs (recordedPrimeDebt > weeklyAccrual + stakedPrime).
     */
    function testShouldLiquidateAfterAccrual() public {
        vm.warp(block.timestamp + 60 days);
        assertTrue(_shouldLiquidate(), "PRIME liquidation must trigger once debt exceeds stake + weekly buffer");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // liquidatePrimeDebt
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * Happy path: once triggered, a whitelisted liquidator seizes the staked PRIME.
     *   - liquidatedAmount = min(primeDebt, stakedPrime) = stakedPrime (3 PRIME)
     *   - 50% burned, 50% to treasury (PrimeLeverageFacet:323-328)
     *   - staked PRIME drops to 0
     *   - remaining debt still exceeds remaining stake (0) ⇒ tier forced back to BASIC (330-337)
     */
    function testLiquidatePrimeDebtSeizesStakeAndDowngrades() public {
        vm.warp(block.timestamp + 60 days);

        uint256 burnBefore = prime.balanceOf(BURN_ADDRESS);
        uint256 treasuryBefore = prime.balanceOf(DeploymentChainConfig.FEES_TREASURY);

        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(PrimeLeverageFacet.liquidatePrimeDebt.selector),
            _feeds(),
            _prices()
        );

        // Stake fully seized.
        assertEq(PrimeLeverageFacet(loan).getPrimeStakedAmount(), 0, "staked PRIME must be fully seized");

        // 50/50 burn:treasury split of the 3-PRIME stake.
        uint256 burned = prime.balanceOf(BURN_ADDRESS) - burnBefore;
        uint256 toTreasury = prime.balanceOf(DeploymentChainConfig.FEES_TREASURY) - treasuryBefore;
        assertEq(burned, EXPECTED_STAKE / 2, "half the seized PRIME must be burned");
        assertEq(toTreasury, EXPECTED_STAKE - EXPECTED_STAKE / 2, "the other half must go to treasury");

        // Remaining PRIME debt (large) exceeds remaining stake (0) ⇒ forced downgrade to BASIC.
        assertEq(
            uint8(PrimeLeverageFacet(loan).getLeverageTier()),
            uint8(LeverageTierLib.LeverageTier.BASIC),
            "tier must be forced to BASIC when remaining stake can't cover remaining debt"
        );
    }

    /**
     * liquidatePrimeDebt reverts when the trigger condition is not met.
     * PINNED (PrimeLeverageFacet.liquidatePrimeDebt:303): "Prime liquidation not triggered".
     */
    function testLiquidatePrimeDebtRevertsWhenNotTriggered() public {
        // No warp — accrued PRIME debt is ~0, well below stake + weekly buffer.
        vm.prank(liquidator);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(PrimeLeverageFacet.liquidatePrimeDebt.selector),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "liquidatePrimeDebt must revert when not triggered");
        assertTrue(_revertContains(ret, "Prime liquidation not triggered"), "expected trigger guard");
    }

    /**
     * Only whitelisted liquidators may call liquidatePrimeDebt. The onlyWhitelistedLiquidators
     * modifier is outermost, so a non-whitelisted caller reverts before the trigger check.
     */
    function testNonWhitelistedCannotLiquidatePrimeDebt() public {
        vm.warp(block.timestamp + 60 days); // even with the trigger satisfiable, access gate fires first

        address rando = makeAddr("rando");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(PrimeLeverageFacet.liquidatePrimeDebt.selector),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "non-whitelisted must not liquidate PRIME debt");
        assertTrue(ret.length >= 4 && bytes4(ret) == OnlyWhitelistedLiquidators.selector, "expected OnlyWhitelistedLiquidators");
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev shouldLiquidatePrimeDebt is non-view (folds accrual) — call wrapped, decode the bool.
    function _shouldLiquidate() internal returns (bool) {
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(PrimeLeverageFacet.shouldLiquidatePrimeDebt.selector),
            _feeds(),
            _prices()
        );
        assertTrue(ok, "shouldLiquidatePrimeDebt call must succeed");
        return abi.decode(ret, (bool));
    }

    function _borrowUsdc(uint256 amount) internal {
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), amount),
            _feeds(),
            _prices()
        );
    }

    function _primeLeverageSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = PrimeLeverageFacet.stakePrimeAndActivatePremium.selector;
        s[1] = PrimeLeverageFacet.getLeverageTier.selector;
        s[2] = PrimeLeverageFacet.getPrimeStakedAmount.selector;
        s[3] = PrimeLeverageFacet.getLeverageTierFullInfo.selector;
        s[4] = PrimeLeverageFacet.shouldLiquidatePrimeDebt.selector;
        s[5] = PrimeLeverageFacet.liquidatePrimeDebt.selector;
    }
}
