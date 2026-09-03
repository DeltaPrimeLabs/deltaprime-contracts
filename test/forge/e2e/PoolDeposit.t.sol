// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {Pool} from "../../../contracts/Pool.sol";

contract PoolDepositTest is DeltaPrimeFixture {
    function testLenderDepositsUsdc() public {
        address lender = makeAddr("lender");
        usdc.mint(lender, 100_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 50_000e6);
        usdcPool.deposit(50_000e6);
        vm.stopPrank();
        assertEq(usdcPool.balanceOf(lender), 50_000e6);
        assertEq(usdc.balanceOf(address(usdcPool)), 50_000e6);
    }

    function testPoolBorrowGatedByRegistry() public {
        address rando = makeAddr("rando");
        vm.prank(rando);
        // canBorrow gate: only registered Prime Accounts (via factory registry) may borrow;
        // pinned to the exact error so a future modifier reordering can't green this vacuously
        vm.expectRevert(Pool.NotAuthorizedToBorrow.selector);
        usdcPool.borrow(1e6);
    }
}
