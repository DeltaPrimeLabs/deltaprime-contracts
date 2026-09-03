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
 * @title  PoolWithdrawalIntentsTest
 * @notice Self-contained suite testing Pool's withdrawal-intent lifecycle:
 *         24-hour wait window, 48-hour validity (expires at +72h), event emission,
 *         multi-intent consumption, cancellation, and withdrawInstant restriction.
 *
 *         Fixture: same pattern as PoolCoreTest — plain Pool + TestERC20(USDC,6)
 *         + 2× LinearIndex (owned by pool) + WavaxVariableUtilisationRatesCalculator
 *         + OpenBorrowersRegistry.
 *
 *         Intent timing (Pool.sol:271–278):
 *           actionableAt = block.timestamp + 24 hours
 *           expiresAt    = actionableAt   + 48 hours  (= create + 72 hours)
 *           Valid window: [actionableAt, expiresAt]
 */
contract PoolWithdrawalIntentsTest is Test {
    // Re-declare Pool events so they can be used in vm.expectEmit / emit.
    // Signatures must match Pool.sol exactly for topic-hash comparison to work.
    event WithdrawalIntentCreated(address indexed user, uint256 amount, uint256 actionableAt, uint256 expiresAt);
    event WithdrawalIntentCancelled(address indexed user, uint256 amount, uint256 timestamp);

    // ─── fixture ──────────────────────────────────────────────────────────────
    Pool internal pool;
    TestERC20 internal usdc;

    // ─── actors ───────────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;

    // ─── constants ────────────────────────────────────────────────────────────
    uint256 constant D6 = 1e6;
    uint256 constant WAIT = 24 hours;     // Pool.sol:271
    uint256 constant TTL  = 48 hours;     // Pool.sol:272 — validity after actionableAt

    function setUp() public {
        vm.warp(1_750_000_000);

        alice = makeAddr("alice");
        bob   = makeAddr("bob");

        usdc = new TestERC20("USD Coin", "USDC", 6);
        WavaxVariableUtilisationRatesCalculator ratesCalc = new WavaxVariableUtilisationRatesCalculator();
        OpenBorrowersRegistry registry = new OpenBorrowersRegistry();
        pool = new Pool();
        LinearIndex di = new LinearIndex();
        LinearIndex bi = new LinearIndex();

        // Indices owned by pool (pool.initialize calls _updateRates → setRate onlyOwner).
        di.initialize(address(pool));
        bi.initialize(address(pool));

        pool.initialize(
            IRatesCalculator(address(ratesCalc)),
            IBorrowersRegistry(address(registry)),
            IIndex(address(di)),
            IIndex(address(bi)),
            payable(address(usdc)),
            IPoolRewarder(address(0)),
            0
        );

        // Give alice a deposit so intents can be created.
        usdc.mint(alice, 1_000_000 * D6);
        vm.prank(alice);
        usdc.approve(address(pool), type(uint256).max);
        vm.prank(alice);
        pool.deposit(1_000_000 * D6);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Helper: create an intent and return its creation timestamp.
    // ──────────────────────────────────────────────────────────────────────────
    function _createIntent(address user, uint256 amount) internal returns (uint256 createdAt) {
        createdAt = block.timestamp;
        vm.prank(user);
        pool.createWithdrawalIntent(amount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — createWithdrawalIntent emits event and stores correct state.
    // ══════════════════════════════════════════════════════════════════════════
    function test_createIntent_eventAndState() public {
        uint256 amt = 100_000 * D6;
        uint256 expectedActionable = block.timestamp + WAIT;
        uint256 expectedExpires    = expectedActionable + TTL;

        // Expect event emission (Pool.sol:282).
        vm.expectEmit(true, false, false, true, address(pool));
        emit WithdrawalIntentCreated(alice, amt, expectedActionable, expectedExpires);

        vm.prank(alice);
        pool.createWithdrawalIntent(amt);

        // Verify storage via getUserIntents.
        Pool.IntentInfo[] memory infos = pool.getUserIntents(alice);
        assertEq(infos.length, 1,                  "one intent recorded");
        assertEq(infos[0].amount,      amt,         "amount stored");
        assertEq(infos[0].actionableAt, expectedActionable, "actionableAt = now + 24h");
        assertEq(infos[0].expiresAt,   expectedExpires,    "expiresAt = actionableAt + 48h");
        assertTrue(infos[0].isPending,  "isPending immediately after creation");
        assertFalse(infos[0].isActionable, "not actionable before 24h");
        assertFalse(infos[0].isExpired,    "not expired immediately");

        // getTotalIntentAmount also reflects the new intent.
        assertEq(pool.getTotalIntentAmount(alice), amt, "getTotalIntentAmount tracks intent");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — withdraw before the 24-hour maturity reverts.
    //
    // Behavior pin: Pool.sol:488 (validateWithdrawalIntents):
    //   require(block.timestamp >= intent.actionableAt, "Withdrawal intent not matured")
    // ══════════════════════════════════════════════════════════════════════════
    function test_withdrawBeforeMaturity_reverts() public {
        uint256 amt = 100_000 * D6;
        vm.prank(alice);
        pool.createWithdrawalIntent(amt);

        // Warp to 1 second before actionableAt.
        vm.warp(block.timestamp + WAIT - 1);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        vm.expectRevert("Withdrawal intent not matured");
        vm.prank(alice);
        pool.withdraw(amt, indices);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — withdraw in the valid window [actionableAt, expiresAt] succeeds.
    //          Shares are burned; underlying USDC is returned to caller.
    // ══════════════════════════════════════════════════════════════════════════
    function test_withdrawInWindow_succeeds() public {
        uint256 amt = 100_000 * D6;
        vm.prank(alice);
        pool.createWithdrawalIntent(amt);

        // Warp to exactly actionableAt (lower bound of window).
        vm.warp(block.timestamp + WAIT);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceSharesBefore = pool.balanceOf(alice);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        vm.prank(alice);
        pool.withdraw(amt, indices);

        // USDC transferred to alice.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + amt, "USDC returned to alice");

        // Shares burned.
        assertEq(pool.balanceOf(alice), aliceSharesBefore - amt, "shares burned");

        // Intent consumed — array now empty.
        assertEq(pool.getUserIntents(alice).length, 0, "intent removed after withdrawal");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — withdraw after the 48-hour validity window (> expiresAt) reverts.
    //
    // Behavior pin: Pool.sol:489 (validateWithdrawalIntents):
    //   require(block.timestamp <= intent.expiresAt, "Withdrawal intent expired")
    // ══════════════════════════════════════════════════════════════════════════
    function test_withdrawAfterExpiry_reverts() public {
        uint256 amt = 100_000 * D6;
        vm.prank(alice);
        pool.createWithdrawalIntent(amt);

        // Warp to 1 second AFTER expiresAt (= create + 72h + 1s).
        vm.warp(block.timestamp + WAIT + TTL + 1);

        uint256[] memory indices = new uint256[](1);
        indices[0] = 0;

        // NOTE: _removeExpiredIntents is called by createWithdrawalIntent but NOT by
        // withdraw itself.  The intent is still in storage (not auto-cleaned on
        // withdraw); validateWithdrawalIntents checks the timestamp and reverts.
        // Pool.sol:489: "Withdrawal intent expired"
        vm.expectRevert("Withdrawal intent expired");
        vm.prank(alice);
        pool.withdraw(amt, indices);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — cancelWithdrawalIntent removes the intent and emits event.
    //
    // Pool.sol:286–301: swap-and-pop removal; emits WithdrawalIntentCancelled.
    // Boundary: invalid index reverts with "Invalid intent index" (Pool.sol:289).
    // ══════════════════════════════════════════════════════════════════════════
    function test_cancelIntent() public {
        uint256 amt = 200_000 * D6;
        vm.prank(alice);
        pool.createWithdrawalIntent(amt);

        assertEq(pool.getUserIntents(alice).length, 1, "pre-cancel: 1 intent");

        // Cancel it — expect event.
        vm.expectEmit(true, false, false, false, address(pool));
        emit WithdrawalIntentCancelled(alice, amt, block.timestamp);

        vm.prank(alice);
        pool.cancelWithdrawalIntent(0);

        assertEq(pool.getUserIntents(alice).length, 0, "post-cancel: 0 intents");

        // Invalid index reverts — Pool.sol:289
        vm.expectRevert("Invalid intent index");
        vm.prank(alice);
        pool.cancelWithdrawalIntent(0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — multiple intents; partial consumption via intentIndices array.
    //
    // Setup: 3 intents — [100k, 200k, 300k] at indices [0, 1, 2].
    // Withdraw using indices [0, 2] (totalIntentAmount = 400k).
    // Removal order (highest-to-lowest): remove index 2 (300k, swap-and-pop since
    //   it's the last element → array [100k, 200k]), then remove index 0 (100k,
    //   swap with index 1 (200k) → array [200k]).
    // Result: 1 intent remains — the 200k one, now at index 0.
    // ══════════════════════════════════════════════════════════════════════════
    function test_multipleIntents_partialConsumption() public {
        vm.prank(alice); pool.createWithdrawalIntent(100_000 * D6);
        vm.prank(alice); pool.createWithdrawalIntent(200_000 * D6);
        vm.prank(alice); pool.createWithdrawalIntent(300_000 * D6);

        assertEq(pool.getUserIntents(alice).length, 3, "3 intents created");

        // Warp past 24h.
        vm.warp(block.timestamp + WAIT + 1);

        uint256[] memory indices = new uint256[](2);
        indices[0] = 0;
        indices[1] = 2;

        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 withdrawAmt = 400_000 * D6; // 100k + 300k

        vm.prank(alice);
        pool.withdraw(withdrawAmt, indices);

        // 400k USDC received.
        assertEq(usdc.balanceOf(alice), aliceBefore + withdrawAmt, "400k withdrawn");

        // Only the 200k intent remains (at index 0 after swap-and-pop).
        Pool.IntentInfo[] memory remaining = pool.getUserIntents(alice);
        assertEq(remaining.length, 1, "one intent remains");
        assertEq(remaining[0].amount, 200_000 * D6, "remaining intent is the 200k one");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — createWithdrawalIntent with amount > balance reverts.
    //
    // Behavior pin: Pool.sol:267–269
    //   uint256 availableBalance = getNotLockedBalance(msg.sender, 0);
    //   if(amount > availableBalance) revert InsufficientAvailableBalance(...);
    // ══════════════════════════════════════════════════════════════════════════
    function test_intentAmountExceedsBalance_reverts() public {
        // Alice's balance = 1_000_000e6. Create an intent for 1 unit more than that.
        // Pool.sol:267-269: revert InsufficientAvailableBalance(amount, availableBalance)
        // Uses full ABI encoding because the error carries parameters.
        uint256 overAmount = 1_000_001 * D6;
        uint256 available  = 1_000_000 * D6; // alice's exact balance (deposited same block)
        vm.expectRevert(abi.encodeWithSelector(
            Pool.InsufficientAvailableBalance.selector,
            overAmount,
            available
        ));
        vm.prank(alice);
        pool.createWithdrawalIntent(overAmount);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — withdrawInstant is restricted to the DEPOSIT_SWAP contract.
    //
    // Behavior pin: Pool.sol:515–516
    //   address DEPOSIT_SWAP_CONTRACT = getDepositSwapAddress();
    //   require(msg.sender == DEPOSIT_SWAP_CONTRACT);   // bare require — no string
    //
    // A bare require(false) without a message reverts with empty revert data (0 bytes).
    // vm.expectRevert() (no args) matches any revert, including empty data.
    //
    // getDepositSwapAddress() returns the hardcoded address
    // 0x70deaA9C41cd696D22a075FD6994F498b56AC55b (Pool.sol:507).  Any other
    // caller — including alice — hits the bare require and gets an empty revert.
    // ══════════════════════════════════════════════════════════════════════════
    function test_withdrawInstant_restrictedToDepositSwap() public {
        // Pool.sol:516: bare require(msg.sender == DEPOSIT_SWAP_CONTRACT); — empty revert
        vm.expectRevert();
        vm.prank(alice);
        pool.withdrawInstant(100_000 * D6);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 9 — interest accrued during the intent wait period is credited.
    //
    // After deposit, bob borrows (creating non-zero deposit rate).  Alice creates
    // an intent for her full principal.  After 25h (past actionableAt), alice
    // withdraws.  She receives her principal (the intent amount); the accrued
    // interest remains in her pool balance (not burned).
    // Total value recovered = received_USDC + remaining_shares ≥ deposited.
    // ══════════════════════════════════════════════════════════════════════════
    function test_interestCreditedOnIntentWithdrawal() public {
        uint256 principal = 1_000_000 * D6;
        // alice already deposited principal in setUp(); pool holds 1M USDC.

        // Bob borrows 300k → 30% util → non-zero deposit rate kicks in.
        // Pool retains 700k USDC — more than enough for alice's 500k intent.
        vm.prank(bob);
        pool.borrow(300_000 * D6);

        // Alice creates intent for 500k (half her balance).
        uint256 intentAmt = 500_000 * D6;
        vm.prank(alice);
        pool.createWithdrawalIntent(intentAmt);

        // Warp 25 hours: past actionableAt (24h), within expiresAt (72h).
        vm.warp(block.timestamp + 25 hours);

        // Snapshot alice's accrued pool balance BEFORE withdrawal.
        // balanceOf uses the index ratio → includes interest earned during 25h.
        uint256 aliceSharesBefore = pool.balanceOf(alice); // > principal
        uint256 aliceUsdcBefore   = usdc.balanceOf(alice);

        uint256[] memory idxArr = new uint256[](1);
        idxArr[0] = 0;

        vm.prank(alice);
        pool.withdraw(intentAmt, idxArr);

        uint256 received        = usdc.balanceOf(alice) - aliceUsdcBefore;
        uint256 remainingShares = pool.balanceOf(alice);

        // She received exactly the intent amount.
        assertEq(received, intentAmt, "received == intent amount");

        // _accumulateDepositInterest was called during withdraw, crediting interest
        // to alice's _deposited before burning.  Remaining shares reflect it:
        //   remainingShares = aliceSharesBefore - intentAmt
        assertEq(remainingShares, aliceSharesBefore - intentAmt, "remaining = accrued_balance - withdrawn");

        // Interest accrued during the 25h wait is preserved in remaining shares.
        assertGt(aliceSharesBefore, principal, "balance grew with interest during wait");

        // Total value (USDC received + remaining shares) > original deposit.
        assertGe(received + remainingShares, principal, "received + remaining >= deposited");
    }
}
