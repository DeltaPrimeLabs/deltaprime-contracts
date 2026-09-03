// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {Pool} from "../../../contracts/Pool.sol";
import {LinearIndex} from "../../../contracts/LinearIndex.sol";
import {WavaxVariableUtilisationRatesCalculator} from
    "../../../contracts/deployment/avalanche/WavaxVariableUtilisationRatesCalculator.sol";
import {OpenBorrowersRegistry} from "../../../contracts/mock/OpenBorrowersRegistry.sol";
import {TestERC20} from "../helpers/TestERC20.sol";
import {IRatesCalculator} from "../../../contracts/interfaces/IRatesCalculator.sol";
import {IBorrowersRegistry} from "../../../contracts/interfaces/IBorrowersRegistry.sol";
import {IIndex} from "../../../contracts/interfaces/IIndex.sol";
import {IPoolRewarder} from "../../../contracts/interfaces/IPoolRewarder.sol";

/**
 * @title  PoolErc20Test
 * @notice Suite 3.6 — Pool ERC20 share-token semantics: transfers, allowances,
 *         intent interactions.
 *
 * Fixture: Pool + TestERC20(6) + OpenBorrowersRegistry + real WAVAX calculator
 *          + 2× LinearIndex (owned by pool). Mirrors PoolCoreTest._freshPool().
 *
 * Key Pool ERC20 behavior pins (all from contracts/Pool.sol):
 *
 *   transfer()     :506-338  — checks zero-address, pool-address, then
 *                              isWithdrawalAmountAvailable (intent-aware). Calls
 *                              _accumulateDepositInterest for both sender and
 *                              recipient, THEN adjusts _deposited. Does NOT call
 *                              _updateRates. Does NOT have infinite-allowance logic.
 *
 *   transferFrom() :374-405  — same checks as transfer(); allowance always
 *                              decremented (line 387), including type(uint256).max.
 *
 *   isWithdrawalAmountAvailable / getNotLockedBalance :454-456 / :92-107
 *                            — available = balance − lockedBalance − intentAmount.
 *                              Transfer is BLOCKED (InsufficientAvailableBalance)
 *                              when amount > available, even when no explicit lock.
 *
 * Errors used in tests (Pool.sol:984-1045):
 *   TransferToZeroAddress   — recipient == address(0)
 *   TransferToPoolAddress   — recipient == address(this) [the pool]
 *   InsufficientAllowance   — transferFrom with insufficient allowance
 *   InsufficientAvailableBalance — transfer amount > notLockedBalance
 */
contract PoolErc20Test is Test {
    // ─── fixture ──────────────────────────────────────────────────────────────
    Pool       internal pool;
    TestERC20  internal token;

    // ─── actors ───────────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;     // borrower only

    // ─── constants ────────────────────────────────────────────────────────────
    uint256 constant D6 = 1e6;

    // ──────────────────────────────────────────────────────────────────────────

    function setUp() public {
        vm.warp(1_750_000_000);

        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");
        dave  = makeAddr("dave");

        token = new TestERC20("Test Token", "TT", 6);
        pool  = new Pool();

        LinearIndex depositIdx = new LinearIndex();
        LinearIndex borrowIdx  = new LinearIndex();

        depositIdx.initialize(address(pool));
        borrowIdx.initialize(address(pool));

        pool.initialize(
            IRatesCalculator(address(new WavaxVariableUtilisationRatesCalculator())),
            IBorrowersRegistry(address(new OpenBorrowersRegistry())),
            IIndex(address(depositIdx)),
            IIndex(address(borrowIdx)),
            payable(address(token)),
            IPoolRewarder(address(0)),
            0 // no supply cap
        );
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _fund(address user, uint256 amount) internal {
        token.mint(user, amount);
        vm.prank(user);
        token.approve(address(pool), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal {
        _fund(user, amount);
        vm.prank(user);
        pool.deposit(amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — transfer moves balance AND future interest accrues proportionally.
    //
    // Mechanics:
    //   transfer() calls _accumulateDepositInterest(sender) then
    //   _accumulateDepositInterest(recipient), crystallising interest for both
    //   and resetting their prevIndex to the current index timestamp.
    //   After transfer, both parties accrue at the same per-unit rate.
    //
    // Scenario:
    //   alice deposits 100k, dave borrows 50k (50% util → rate > 0).
    //   Warp 365d → alice accrues interest.
    //   alice transfers 50k to bob.
    //   After _accumulateDepositInterest:
    //     alice._deposited = balanceOf(alice) [crystallised]
    //     bob._deposited   = 0
    //   After adjustments: alice._deposited -= 50k, bob._deposited = 50k.
    //   Both prevIndex set to current time and index.
    //   Warp another 365d → alice and bob both accrue from the same prevIndex.
    //   Their balance growth ratio = their deposited ratio = (aliceDep-50k) / 50k.
    // ══════════════════════════════════════════════════════════════════════════
    function test_transfer_movesBalance_and_accruesProportionally() public {
        _deposit(alice, 100_000 * D6);
        vm.prank(dave);
        pool.borrow(50_000 * D6); // 50% util

        // Warp so alice accrues interest.
        vm.warp(block.timestamp + 365 days);

        uint256 aliceBalBefore = pool.balanceOf(alice);
        assertGt(aliceBalBefore, 100_000 * D6, "alice should have accrued interest");

        // alice transfers 50k to bob (bob has 0 deposits).
        vm.prank(alice);
        pool.transfer(bob, 50_000 * D6);

        // After transfer, both prevIndex are identical (crystallised at transfer time).
        uint256 aliceDepositedAfter = pool.balanceOf(alice); // ≈ aliceBalBefore - 50k
        uint256 bobDepositedAfter   = pool.balanceOf(bob);   // = 50k
        assertApproxEqAbs(aliceDepositedAfter, aliceBalBefore - 50_000 * D6, 2,
            "alice balance decreased by exactly the transferred amount");
        assertEq(bobDepositedAfter, 50_000 * D6, "bob received exactly 50k shares");

        // Warp more — both parties accrue at same rate from same prevIndex.
        vm.warp(block.timestamp + 365 days);

        uint256 aliceGain = pool.balanceOf(alice) - aliceDepositedAfter;
        uint256 bobGain   = pool.balanceOf(bob)   - bobDepositedAfter;

        // Gains proportional to deposits: aliceGain/aliceDep == bobGain/bobDep
        // Cross-multiply: aliceGain * bobDep == bobGain * aliceDep (within 2 wei rounding)
        uint256 lhs = aliceGain * bobDepositedAfter;
        uint256 rhs = bobGain   * aliceDepositedAfter;
        assertApproxEqAbs(lhs, rhs, 2 * bobDepositedAfter, "gains proportional to deposits");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — transfer more than available balance reverts.
    //
    // Pin: Pool.sol:310-312
    //   if(!isWithdrawalAmountAvailable(msg.sender, amount, 0)){
    //     revert InsufficientAvailableBalance(amount, getNotLockedBalance(msg.sender, 0));
    //   }
    // With no locks and no intents: notLockedBalance = balanceOf(user).
    // ══════════════════════════════════════════════════════════════════════════
    function test_transfer_exceedingBalance_reverts() public {
        _deposit(alice, 10_000 * D6);

        // Exactly 1 unit over balance — no interest (no borrows → rate=0 → balance unchanged).
        uint256 balance = pool.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.InsufficientAvailableBalance.selector,
                balance + 1,
                balance
            )
        );
        pool.transfer(bob, balance + 1);

        // Transferring exactly balance succeeds.
        vm.prank(alice);
        pool.transfer(bob, balance);
        assertEq(pool.balanceOf(alice), 0, "alice fully transferred");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — approve / transferFrom round-trip; allowance is always decremented.
    //
    // Pin: Pool.sol:365-372 approve()
    //      Pool.sol:374-405 transferFrom()
    //      Pool.sol:375 — revert InsufficientAllowance if allowance < amount
    //      Pool.sol:387 — _allowed[sender][msg.sender] -= amount  (always decremented,
    //                     including when allowance is type(uint256).max — there is
    //                     NO infinite-allowance special case in this implementation)
    // ══════════════════════════════════════════════════════════════════════════
    function test_approve_transferFrom_allowanceDecrement() public {
        _deposit(alice, 50_000 * D6);

        // alice approves bob to spend 30k.
        vm.prank(alice);
        pool.approve(bob, 30_000 * D6);
        assertEq(pool.allowance(alice, bob), 30_000 * D6, "allowance set");

        // bob transfers 10k from alice to carol.
        vm.prank(bob);
        pool.transferFrom(alice, carol, 10_000 * D6);
        assertEq(pool.allowance(alice, bob), 20_000 * D6, "allowance decremented by 10k");
        assertEq(pool.balanceOf(carol), 10_000 * D6, "carol received tokens");

        // Exceed remaining allowance → InsufficientAllowance.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.InsufficientAllowance.selector,
                25_000 * D6,   // requested
                20_000 * D6    // current allowance
            )
        );
        pool.transferFrom(alice, carol, 25_000 * D6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — type(uint256).max allowance is NOT special-cased; it is decremented.
    //
    // Pin: Pool.sol:387
    //   _allowed[sender][msg.sender] -= amount;
    // Unlike the canonical ERC20 pattern, Pool has no infinite-allowance optimisation.
    // ══════════════════════════════════════════════════════════════════════════
    function test_maxAllowance_isDecremented() public {
        _deposit(alice, 20_000 * D6);

        vm.prank(alice);
        pool.approve(bob, type(uint256).max);
        assertEq(pool.allowance(alice, bob), type(uint256).max, "max allowance set");

        vm.prank(bob);
        pool.transferFrom(alice, carol, 5_000 * D6);

        // Allowance is decremented, NOT left at max.
        assertEq(pool.allowance(alice, bob), type(uint256).max - 5_000 * D6, "max allowance IS decremented");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — transfer to zero address reverts; transfer to pool address reverts.
    //
    // Pin: Pool.sol:308-309
    //   if(recipient == address(0))    revert TransferToZeroAddress();
    //   if(recipient == address(this)) revert TransferToPoolAddress();
    //
    // Transfer to self (sender == recipient, not pool) is NOT blocked — succeeds
    // (no such check in Pool.sol transfer()). Net balance effect: interest
    // crystallises but shares stay with alice.
    // ══════════════════════════════════════════════════════════════════════════
    function test_transfer_zeroAddress_and_poolAddress_reverts() public {
        _deposit(alice, 10_000 * D6);

        vm.prank(alice);
        vm.expectRevert(Pool.TransferToZeroAddress.selector);
        pool.transfer(address(0), 1_000 * D6);

        vm.prank(alice);
        vm.expectRevert(Pool.TransferToPoolAddress.selector);
        pool.transfer(address(pool), 1_000 * D6);

        // Transfer to self — succeeds (no sender==recipient guard in Pool.sol).
        uint256 balBefore = pool.balanceOf(alice);
        vm.prank(alice);
        pool.transfer(alice, 5_000 * D6); // must not revert
        // Net balance is unchanged (crystallises interest but no real movement).
        assertApproxEqAbs(pool.balanceOf(alice), balBefore, 1, "self-transfer: balance unchanged");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — totalSupply == Σ balances for 3 depositors after transfer + accrual.
    //
    // All three deposit in the same block → prevIndex[t0]=1e18 for all.
    // Dave borrows → non-zero deposit rate.
    // Warp → interest accrues.
    // alice transfers 50k to bob → both get _accumulateDepositInterest; their
    //   prevIndex advances to t_transfer. carol's prevIndex stays at t0.
    //
    // totalSupply   = pool._deposited * I_now / prevIndex[pool_time]
    // Σ balances:
    //   alice + bob terms cancel: (A+B) * I_now/I_transfer
    //   carol term: 100k * I_now / I_t0
    //   pool accounting: correctly tracks the split
    //
    // In integer arithmetic there may be ≤ 5 wei rounding (same tolerance as PoolCoreTest).
    // ══════════════════════════════════════════════════════════════════════════
    function test_totalSupply_equalsSum_afterTransferAndAccrual() public {
        // All three deposit in same block.
        _deposit(alice, 100_000 * D6);
        _deposit(bob,   100_000 * D6);
        _deposit(carol,  50_000 * D6);

        // Dave borrows 100k from 250k pool → 40% util → non-zero rate.
        vm.prank(dave);
        pool.borrow(100_000 * D6);

        // Warp half a year — interest accrues.
        vm.warp(block.timestamp + 180 days);

        // alice transfers 50k to bob.
        vm.prank(alice);
        pool.transfer(bob, 50_000 * D6);

        // Warp another 180d.
        vm.warp(block.timestamp + 180 days);

        uint256 sumBal = pool.balanceOf(alice)
                       + pool.balanceOf(bob)
                       + pool.balanceOf(carol);

        assertApproxEqAbs(pool.totalSupply(), sumBal, 5,
            "totalSupply == sum of depositor balances within 5 wei");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — withdrawal intent BLOCKS transfer when intent + transfer > balance.
    //
    // createWithdrawalIntent reserves part of the balance. The transfer function
    // checks isWithdrawalAmountAvailable which subtracts totalIntentAmount:
    //
    // Pin: Pool.sol:310-312
    //   if(!isWithdrawalAmountAvailable(msg.sender, amount, 0))
    //     revert InsufficientAvailableBalance(amount, getNotLockedBalance(msg.sender, 0));
    //
    // Pin: Pool.sol:92-107 getNotLockedBalance
    //   notLockedBalance = balance - lockedBalance - totalIntentAmount
    //
    // The transfer itself is BLOCKED — it reverts before any state changes.
    // The intent is NOT broken; only the excessive transfer is rejected.
    // ══════════════════════════════════════════════════════════════════════════
    function test_withdrawalIntent_blocksExcessiveTransfer() public {
        _deposit(alice, 100_000 * D6);

        // alice registers intent for 80k (actionableAt = now + 24h).
        vm.prank(alice);
        pool.createWithdrawalIntent(80_000 * D6);

        // Available for transfer: 100k - 80k = 20k.
        assertEq(pool.getNotLockedBalance(alice, 0), 20_000 * D6, "only 20k available");

        // Attempting 30k transfer exceeds notLockedBalance → InsufficientAvailableBalance.
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Pool.InsufficientAvailableBalance.selector,
                30_000 * D6,
                20_000 * D6
            )
        );
        pool.transfer(bob, 30_000 * D6);

        // Intent is still intact.
        Pool.IntentInfo[] memory intents = pool.getUserIntents(alice);
        assertEq(intents.length, 1, "intent still present after blocked transfer");
        assertEq(intents[0].amount, 80_000 * D6, "intent amount unchanged");

        // Transferring within the available 20k succeeds.
        vm.prank(alice);
        pool.transfer(bob, 20_000 * D6);
        assertEq(pool.balanceOf(bob), 20_000 * D6, "20k transferred successfully");

        // Alice's remaining available is now 0 (80k intent locks remaining 80k balance).
        assertEq(pool.getNotLockedBalance(alice, 0), 0, "alice has no free balance remaining");
    }
}
