// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";

/**
 * Wrapped borrow e2e — proves that:
 *   1. A borrow call succeeds when the RedStone payload is appended to calldata
 *      (ProxyConnector re-appends payload to the nested solvency delegate-call).
 *   2. An over-borrow that would leave the account insolvent is rejected by the
 *      `remainsSolvent` guard inside AssetsOperationsFacet.borrow.
 */
contract BorrowTest is DeltaPrimeFixture {
    function setUp() public override {
        super.setUp();
        // Pre-fund the USDC pool so borrowing actually works.
        address lender = makeAddr("lender");
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();
    }

    /// @notice Happy path: 100 AVAX @ $30 = $3 000 capacity; borrow $1 000 USDC → solvent.
    function testBorrowAgainstAvaxCollateral() public {
        (address borrower, address loan) = _createLoanFor("borrower");
        _fundAvax(borrower, loan, 100e18);
        // noBorrowInTheSameBlock compares block.timestamp, so advance one second.
        vm.warp(block.timestamp + 1);

        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(1000e6)),
            _feeds(),
            _prices()
        );

        // Loan holds the borrowed USDC.
        assertEq(usdc.balanceOf(loan), 1000e6, "loan must hold borrowed USDC");

        // getDebt() also requires an oracle payload.
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSignature("getDebt()"),
            _feeds(),
            _prices()
        );
        assertTrue(ok, "getDebt() must succeed");
        assertGt(abi.decode(ret, (uint256)), 0, "USD-denominated debt must be non-zero");
    }

    /// @notice Negative path: attempting to borrow 900 000 USDC against 100 AVAX
    ///         triggers the remainsSolvent guard.
    function testOverBorrowRevertsInsolvent() public {
        (address borrower, address loan) = _createLoanFor("borrower");
        _fundAvax(borrower, loan, 100e18);
        vm.warp(block.timestamp + 1);

        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(900_000e6)),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "over-borrow must revert");
        assertTrue(_revertContains(ret, "insolvent"), "expected remainsSolvent guard");
    }
}
