// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {WithdrawalIntentFacet} from "../../../contracts/facets/WithdrawalIntentFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";

/**
 * Liquidator cancel of withdrawal intents during liquidation (supersedes PR #77).
 *
 * cancelWithdrawalIntent is gated by onlyWhitelistedLiquidatorsAndInsolvencySnapshotOrOwner:
 * a whitelisted liquidator may cancel a Prime Account's withdrawal intents ONLY while a valid
 * (non-expired, <15min) insolvency snapshot is active — freeing intent-locked collateral so it
 * isn't artificially withheld from liquidation — while the owner may cancel any time. This pins
 * that behavior and its access boundaries (the feature already exists on main, more tightly than
 * PR #77's proposed `onlyOwnerOrLiquidation`).
 */
contract WithdrawalIntentLiquidatorCancelTest is DeltaPrimeFixture {
    uint256 internal constant CRASH_PRICE = 3e8;   // $3 AVAX -> HR < 1 (insolvent)
    uint256 internal constant INTENT_AMOUNT = 10e18; // 10 AVAX locked behind an intent

    address internal loan;
    address internal borrower;

    function setUp() public override {
        super.setUp();

        // Fund the USDC pool so the loan can borrow.
        address lender = makeAddr("lender");
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();

        // 100 AVAX collateral, borrow 2,000 USDC (healthy at $30).
        (borrower, loan) = _createLoanFor("borrower");
        _fundAvax(borrower, loan, 100e18);
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(2000e6)),
            _feeds(),
            _prices()
        );

        // Owner locks 10 AVAX behind a withdrawal intent (no oracle payload needed).
        vm.prank(borrower);
        WithdrawalIntentFacet(loan).createWithdrawalIntent(NATIVE_SYMBOL, INTENT_AMOUNT);
        assertEq(
            WithdrawalIntentFacet(loan).getTotalIntentAmount(NATIVE_SYMBOL),
            INTENT_AMOUNT,
            "setup: intent should lock 10 AVAX"
        );
    }

    /// Snapshot insolvency as the whitelisted liquidator at the crash price.
    function _snapshotAsLiquidator() internal {
        vm.prank(liquidator);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SmartLoanLiquidationFacet.snapshotInsolvency.selector),
            _feeds(),
            _pricesWithAvax(CRASH_PRICE)
        );
    }

    function _rawCancel(address caller) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = loan.call(
            abi.encodeWithSelector(WithdrawalIntentFacet.cancelWithdrawalIntent.selector, NATIVE_SYMBOL, uint256(0))
        );
    }

    /// Whitelisted liquidator cancels during a valid snapshot -> intent removed, collateral freed.
    function testLiquidatorCancelsIntentDuringActiveSnapshot() public {
        _snapshotAsLiquidator();
        assertGt(SmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "snapshot must be recorded");

        uint256 availBefore = WithdrawalIntentFacet(loan).getAvailableBalance(NATIVE_SYMBOL);
        vm.prank(liquidator);
        WithdrawalIntentFacet(loan).cancelWithdrawalIntent(NATIVE_SYMBOL, 0);

        assertEq(WithdrawalIntentFacet(loan).getTotalIntentAmount(NATIVE_SYMBOL), 0, "intent must be cancelled");
        assertEq(
            WithdrawalIntentFacet(loan).getAvailableBalance(NATIVE_SYMBOL),
            availBefore + INTENT_AMOUNT,
            "freed collateral must become available"
        );
    }

    /// Without an active snapshot a whitelisted liquidator cannot cancel.
    function testLiquidatorCannotCancelWithoutSnapshot() public {
        (bool ok, bytes memory ret) = _rawCancel(liquidator);
        assertFalse(ok, "no snapshot -> liquidator cancel must revert");
        assertTrue(_revertContains(ret, "No insolvency snapshot"), "expected no-snapshot revert");
    }

    /// Once the 15-minute snapshot window lapses, the liquidator can no longer cancel.
    function testLiquidatorCannotCancelAfterSnapshotExpiry() public {
        _snapshotAsLiquidator();
        vm.warp(block.timestamp + 16 minutes); // past INSOLVENCY_SNAPSHOT_VALIDITY (15 min)
        (bool ok, bytes memory ret) = _rawCancel(liquidator);
        assertFalse(ok, "expired snapshot -> liquidator cancel must revert");
        assertTrue(_revertContains(ret, "expired"), "expected snapshot-expired revert");
    }

    /// A caller that is neither the owner nor a whitelisted liquidator cannot cancel.
    function testNonOwnerNonLiquidatorCannotCancel() public {
        _snapshotAsLiquidator();
        (bool ok, bytes memory ret) = _rawCancel(makeAddr("stranger"));
        assertFalse(ok, "stranger cancel must revert");
        assertTrue(_revertContains(ret, "Must be contract owner"), "expected owner-gate revert");
    }

    /// The owner may cancel at any time, with no snapshot required.
    function testOwnerCancelsIntentWithoutSnapshot() public {
        vm.prank(borrower);
        WithdrawalIntentFacet(loan).cancelWithdrawalIntent(NATIVE_SYMBOL, 0);
        assertEq(WithdrawalIntentFacet(loan).getTotalIntentAmount(NATIVE_SYMBOL), 0, "owner cancel must remove intent");
    }
}
