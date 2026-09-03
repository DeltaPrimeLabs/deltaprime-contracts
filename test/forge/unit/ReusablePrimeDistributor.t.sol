// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {ReusablePrimeDistributor} from "../../../contracts/ReusablePrimeDistributor.sol";
import {MockRtknToPrimeConverter}  from "../../../contracts/mock/MockRtknToPrimeConverter.sol";
import {TestERC20}                 from "../helpers/TestERC20.sol";

/**
 * @title  ReusablePrimeDistributorTest
 * @notice Suite 3.8B — cache/round/distribute lifecycle, lifetime cap.
 *
 * Contract facts (all pins reference contracts/ReusablePrimeDistributor.sol):
 *
 * Constructor (lines 65-80):
 *   - require(_primeToken    != address(0),  "Invalid PRIME token address")
 *   - require(_rTKNConverter != address(0),  "Invalid rTKNConverter address")
 *   - require(_distributionCap > 0,          "Cap must be > 0")
 *   - require(_initialDistributed <= _distributionCap, "initialDistributed > cap")
 *
 * cacheUsers (lines 91-120):
 *   - onlyOwner; reverts "Users already cached" once usersCached==true
 *   - Pages through converter.users[] using cachingIndex as cursor
 *   - Only adds users whose previewFuturePrimeAmountBasedOnPledgedAmountForUser > 0
 *   - Sets usersCached=true + emits UsersCached when cachingIndex >= totalUsers
 *
 * startRound (lines 132-151):
 *   - onlyOwner
 *   - Requires usersCached; requires !roundInProgress; requires paidSoFar < cap
 *   - roundAmount = min(primeToken.balanceOf(address(this)), remaining_cap)
 *   - paidSoFar   = initialDistributed + totalPrimeDistributed
 *   - Reverts "Cap reached" when paidSoFar >= distributionCap
 *
 * distribute (lines 157-189):
 *   - onlyOwner + nonReentrant
 *   - amount per user = (roundPrimeAmount * userShare[user]) / totalShares  (line 172)
 *   - Skips users with skippedUsers[user]==true
 *   - On final batch: roundInProgress=false; emits RoundCompleted with leftover dust
 *   - No per-call cap check — cap is fully enforced at startRound by clipping roundAmount
 *
 * emergencyWithdraw (lines 212-225):
 *   - onlyOwner + nonReentrant; resets roundInProgress if active; sweeps full balance
 *   - Acts as the rescue/sweep function (no separate rescueToken exists in this contract)
 *
 * MockRtknToPrimeConverter (contracts/mock/MockRtknToPrimeConverter.sol):
 *   CONVERSION_RATIO = 0.808015513897867e18 = 808015513897867000
 *   previewFuturePrimeAmountBasedOnPledgedAmountForUser(user) = pledged * CONVERSION_RATIO / 1e18
 *
 * Fixture share arithmetic (pledge amounts chosen so fractions are exact integers):
 *   alice pledge = 1e18 → share = 808015513897867000     (= S)
 *   bob   pledge = 2e18 → share = 1616031027795734000    (= 2S)
 *   carol pledge = 2e18 → share = 1616031027795734000    (= 2S)
 *   totalShares          = 4040077569489335000            (= 5S)
 *   ⇒ alice gets 1/5, bob 2/5, carol 2/5 of any round amount divisible by 5.
 *   For roundAmount = 500e18: alice=100e18, bob=200e18, carol=200e18 (exact, zero dust).
 *   For roundAmount = 11e18+1: alice=2.2e18(floor), bob=4.4e18(floor), carol=4.4e18(floor)
 *                              total paid = 11e18, dust = 1 wei.
 */
contract ReusablePrimeDistributorTest is Test {
    // ─── fixture ──────────────────────────────────────────────────────────────
    TestERC20                  internal prime;
    MockRtknToPrimeConverter   internal converter;
    ReusablePrimeDistributor   internal dist;

    // ─── actors ───────────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;
    address internal carol;

    // ─── constants ────────────────────────────────────────────────────────────
    uint256 constant CAP      = 10_000e18;
    uint256 constant INIT_DIST = 0;

    // ══════════════════════════════════════════════════════════════════════════
    // setUp — deploys core fixture; does NOT cache users (tests control that).
    // ══════════════════════════════════════════════════════════════════════════
    function setUp() public {
        vm.warp(1_750_000_000);
        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");

        prime     = new TestERC20("PRIME", "PRIME", 18);
        converter = new MockRtknToPrimeConverter();

        // Add users to the converter (pledge amounts chosen for exact share ratios — see header).
        converter.addUser(alice, 1e18); // share = 1S = 808015513897867000
        converter.addUser(bob,   2e18); // share = 2S
        converter.addUser(carol, 2e18); // share = 2S

        dist = new ReusablePrimeDistributor(
            address(prime),
            address(converter),
            CAP,
            INIT_DIST
        );
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    /// Cache all users from the converter in one shot.
    function _cacheAllUsers() internal {
        dist.cacheUsers(10); // 10 >> 3 total users
    }

    /// Mint `amount` PRIME directly into the distributor and call startRound().
    function _mintAndStartRound(uint256 amount) internal {
        prime.mint(address(dist), amount);
        dist.startRound();
    }

    /// Call distribute with a batch large enough to process all users.
    function _distributeAll() internal {
        dist.distribute(100); // 100 >> 3 cached users
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — constructor wires all fields correctly
    //
    // Pin: ReusablePrimeDistributor.sol:76-79
    // ══════════════════════════════════════════════════════════════════════════
    function test_constructor_wiresFieldsCorrectly() public {
        assertEq(address(dist.primeToken()),    address(prime),     "primeToken wired");
        assertEq(address(dist.rTKNConverter()), address(converter), "converter wired");
        assertEq(dist.distributionCap(),        CAP,                "cap stored");
        assertEq(dist.initialDistributed(),     INIT_DIST,          "initialDistributed stored");
        assertEq(dist.usersCached(),            false,              "not cached yet");
        assertEq(dist.roundInProgress(),        false,              "no round yet");
        assertEq(dist.totalShares(),            0,                  "no shares yet");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — cacheUsers pages correctly; batchSize=1 processes one user at a time
    //
    // Pin: ReusablePrimeDistributor.sol:96-114
    //   cachingIndex advances by min(batchSize, remaining) each call.
    // ══════════════════════════════════════════════════════════════════════════
    function test_cacheUsers_pagesCorrectly() public {
        // Page 1: process alice (index 0)
        dist.cacheUsers(1);
        assertEq(dist.cachingIndex(), 1,     "after batch 1: cursor at 1");
        assertEq(dist.usersCached(), false,  "not complete yet");
        assertEq(dist.getTotalCachedUsers(), 1, "one user cached");

        // Page 2: process bob (index 1)
        dist.cacheUsers(1);
        assertEq(dist.cachingIndex(), 2,     "after batch 2: cursor at 2");
        assertEq(dist.usersCached(), false,  "not complete yet");

        // Page 3: process carol (index 2) — finalizes caching
        dist.cacheUsers(1);
        assertEq(dist.cachingIndex(), 3,     "after batch 3: cursor at 3");
        assertEq(dist.usersCached(), true,   "fully cached");
        assertEq(dist.getTotalCachedUsers(), 3, "all 3 cached");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — cacheUsers: completion flag set and shares totaled after all batches
    //
    // After full caching: usersCached=true, totalShares = 5S (see fixture header).
    // ══════════════════════════════════════════════════════════════════════════
    function test_cacheUsers_completionFlagSetAfterFull() public {
        _cacheAllUsers();

        assertEq(dist.usersCached(), true, "usersCached set to true");

        // totalShares must equal sum of all three share values.
        uint256 expectedShares = dist.userShare(alice) + dist.userShare(bob) + dist.userShare(carol);
        assertEq(dist.totalShares(), expectedShares, "totalShares = sum of individual shares");
        assertGt(dist.totalShares(), 0,              "totalShares > 0");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — cacheUsers: calling after usersCached==true reverts "Users already cached"
    //
    // Pin: ReusablePrimeDistributor.sol:92
    //   require(!usersCached, "Users already cached");
    // ══════════════════════════════════════════════════════════════════════════
    function test_cacheUsers_doubleCacheBehavior() public {
        _cacheAllUsers(); // sets usersCached = true
        assertEq(dist.usersCached(), true);

        vm.expectRevert("Users already cached");
        dist.cacheUsers(10); // reverts on second call
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — startRound: reverts if users not yet cached
    //
    // Pin: ReusablePrimeDistributor.sol:133
    //   require(usersCached, "Users not cached yet");
    // ══════════════════════════════════════════════════════════════════════════
    function test_startRound_requiresCachedUsers() public {
        prime.mint(address(dist), 100e18);
        vm.expectRevert("Users not cached yet");
        dist.startRound();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — startRound: reverts if no PRIME balance in the distributor
    //
    // Pin: ReusablePrimeDistributor.sol:140-141
    //   uint256 balance = primeToken.balanceOf(address(this));
    //   require(balance > 0, "No PRIME to distribute");
    // ══════════════════════════════════════════════════════════════════════════
    function test_startRound_requiresPRIMEBalance() public {
        _cacheAllUsers();
        // No PRIME minted to distributor
        vm.expectRevert("No PRIME to distribute");
        dist.startRound();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — startRound: roundAmount = min(balance, remaining_cap)
    //
    // Pin: ReusablePrimeDistributor.sol:143
    //   uint256 roundAmount = balance < remaining ? balance : remaining;
    //
    // When balance <= remaining: roundAmount = balance (full balance used).
    // When balance >  remaining: roundAmount = remaining (clipped).
    // ══════════════════════════════════════════════════════════════════════════
    function test_startRound_roundAmountAccounting() public {
        _cacheAllUsers();

        // Case 1: balance < remaining → roundAmount = balance
        uint256 balance = 500e18;
        prime.mint(address(dist), balance);
        dist.startRound();
        assertEq(dist.roundPrimeAmount(), balance, "balance < cap: roundAmount = balance");
        assertEq(dist.roundInProgress(), true,     "round started");

        // Finish this round before starting another
        _distributeAll();
        assertEq(dist.roundInProgress(), false, "round complete");

        // Case 2: balance > remaining cap → roundAmount = remaining (clipped)
        // paidSoFar = initialDistributed(0) + totalPrimeDistributed(~500e18) = ~500e18
        // remaining  = 10_000e18 - ~500e18 = ~9500e18
        // Send 11_000e18 (> remaining): must clip to remaining.
        uint256 remaining = dist.getRemainingDistributable();
        prime.mint(address(dist), 11_000e18);
        dist.startRound();
        assertEq(dist.roundPrimeAmount(), remaining, "balance > remaining: clipped to remaining");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — startRound: reverts "Round already in progress" while round is live
    //
    // Pin: ReusablePrimeDistributor.sol:134
    //   require(!roundInProgress, "Round already in progress");
    // ══════════════════════════════════════════════════════════════════════════
    function test_startRound_whileRoundInProgress_reverts() public {
        _cacheAllUsers();
        _mintAndStartRound(100e18);
        assertEq(dist.roundInProgress(), true);

        // Second startRound before distribute is called
        prime.mint(address(dist), 50e18); // extra balance doesn't help
        vm.expectRevert("Round already in progress");
        dist.startRound();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 9 — distribute: pays pro-rata by cached shares
    //
    // With 500e18 round and 1:2:2 share ratio (alice:bob:carol):
    //   alice = 500e18 * 1/5 = 100e18  (exact, see fixture header)
    //   bob   = 500e18 * 2/5 = 200e18
    //   carol = 500e18 * 2/5 = 200e18
    //
    // Pin: ReusablePrimeDistributor.sol:172
    //   amount = (roundPrimeAmount * userShare[user]) / totalShares
    // ══════════════════════════════════════════════════════════════════════════
    function test_distribute_paysProRataByShares() public {
        _cacheAllUsers();
        _mintAndStartRound(500e18);
        _distributeAll();

        assertEq(prime.balanceOf(alice), 100e18, "alice: 1/5 of round");
        assertEq(prime.balanceOf(bob),   200e18, "bob:   2/5 of round");
        assertEq(prime.balanceOf(carol), 200e18, "carol: 2/5 of round");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 10 — distribute: partial batch advances cursor; round stays live
    //
    // Pin: ReusablePrimeDistributor.sol:161-165 — endIndex clamped to userCount
    //      ReusablePrimeDistributor.sol:183-188 — roundInProgress cleared only
    //      when currentDistributionIndex >= userCount
    // ══════════════════════════════════════════════════════════════════════════
    function test_distribute_partialBatchAdvancesCursor() public {
        _cacheAllUsers();
        _mintAndStartRound(500e18);

        // Batch of 1: process only alice (index 0)
        dist.distribute(1);
        assertEq(dist.currentDistributionIndex(), 1,    "cursor at 1 after first batch");
        assertEq(dist.roundInProgress(),          true, "round still live");

        // Batch of 1: process bob (index 1)
        dist.distribute(1);
        assertEq(dist.currentDistributionIndex(), 2,    "cursor at 2");
        assertEq(dist.roundInProgress(),          true, "still live");

        // Final batch of 1: process carol (index 2) — completes round
        dist.distribute(1);
        assertEq(dist.currentDistributionIndex(), 3,     "cursor at 3 (all processed)");
        assertEq(dist.roundInProgress(),          false, "round complete after final batch");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 11 — distribute: final batch flips roundInProgress to false
    //
    // Pin: ReusablePrimeDistributor.sol:184-188
    //   if (currentDistributionIndex >= userCount) {
    //     roundInProgress = false;
    //     emit RoundCompleted(...)
    //   }
    // ══════════════════════════════════════════════════════════════════════════
    function test_distribute_finalBatchFlipsRoundInProgressFalse() public {
        _cacheAllUsers();
        _mintAndStartRound(500e18);
        assertEq(dist.roundInProgress(), true, "round live before distribute");

        // Single call with batchSize > userCount finishes in one shot
        _distributeAll();
        assertEq(dist.roundInProgress(), false, "roundInProgress=false after final batch");
        assertEq(dist.currentRound(),    1,     "round counter incremented");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 12 — distribute: dust (rounding remainder) stays in the contract
    //
    // With roundAmount = 11e18+1 and 1:2:2 share ratio:
    //   alice: (11e18+1) * 1/5 = 2_200_000_000_000_000_000  (floor, remainder 1)
    //   bob:   (11e18+1) * 2/5 = 4_400_000_000_000_000_000  (floor, remainder 2 → 0 after div)
    //   carol: same as bob
    //   total paid = 11_000_000_000_000_000_000
    //   dust       = 11_000_000_000_000_000_001 - 11_000_000_000_000_000_000 = 1 wei
    //
    // Pin: ReusablePrimeDistributor.sol:186
    //   uint256 dust = primeToken.balanceOf(address(this));  — emitted, NOT swept automatically
    // ══════════════════════════════════════════════════════════════════════════
    function test_distribute_dustHandling() public {
        _cacheAllUsers();

        uint256 roundAmount = 11e18 + 1; // NOT divisible by 5 → produces 1 wei dust
        _mintAndStartRound(roundAmount);

        // Capture the RoundCompleted event to verify dust value.
        vm.recordLogs();
        _distributeAll();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the RoundCompleted event: keccak256("RoundCompleted(uint256,uint256,uint256)")
        bytes32 sig = keccak256("RoundCompleted(uint256,uint256,uint256)");
        uint256 emittedDust;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) {
                ( , emittedDust) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }

        // Dust remains in the contract and matches the emitted value.
        uint256 contractDust = prime.balanceOf(address(dist));
        assertGt(contractDust, 0,           "dust > 0 (rounding remainder stays in contract)");
        assertEq(contractDust, emittedDust, "event dust matches actual balance");
        assertEq(contractDust, 1,           "exactly 1 wei dust for this round amount");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 13 — lifetimeCap: startRound clips roundAmount to remaining headroom
    //
    // Setup: initialDistributed = 9_800e18, distributionCap = 10_000e18.
    //   remaining = 200e18; send 500e18 PRIME (exceeds remaining).
    //   startRound() clips roundAmount to 200e18 (not 500e18).
    //   The excess 300e18 stays in the contract as sweepable dust.
    //
    // Pin: ReusablePrimeDistributor.sol:136-143
    // ══════════════════════════════════════════════════════════════════════════
    function test_lifetimeCap_stopsDistributionWhenCapReached() public {
        // Fresh distributor with initialDistributed already consuming most of the cap.
        ReusablePrimeDistributor d2 = new ReusablePrimeDistributor(
            address(prime),
            address(converter),
            10_000e18,
            9_800e18  // initialDistributed: 9800 already paid out by prior contracts
        );
        d2.cacheUsers(10); // cache all users

        uint256 remaining = d2.getRemainingDistributable(); // = 200e18
        assertEq(remaining, 200e18, "remaining headroom = 200e18");

        // Send 500e18 — 300e18 more than the cap allows.
        prime.mint(address(d2), 500e18);
        d2.startRound();

        // roundPrimeAmount must be clipped to remaining (200e18), not full balance (500e18).
        assertEq(d2.roundPrimeAmount(), 200e18, "round clipped to remaining cap");
        assertEq(d2.roundInProgress(),  true,   "round started");

        // Distribute — only 200e18 is paid out; 300e18 excess stays as dust.
        d2.distribute(100);
        assertEq(d2.roundInProgress(), false, "round complete");
        assertGe(prime.balanceOf(address(d2)), 300e18 - 10, "excess PRIME stays in contract (minus rounding)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 14 — lifetimeCap: startRound reverts "Cap reached" when cap is exhausted
    //
    // After a round that uses up the full remaining cap, paidSoFar == distributionCap.
    // The next startRound() reverts with "Cap reached".
    //
    // Uses a 1-user converter so integer division is exact (no dust shortfall).
    //
    // Pin: ReusablePrimeDistributor.sol:136-137
    //   require(paidSoFar < distributionCap, "Cap reached");
    // ══════════════════════════════════════════════════════════════════════════
    function test_lifetimeCap_revertsWhenCapExceeded() public {
        // 1-user converter to avoid rounding leaving totalPrimeDistributed < cap.
        MockRtknToPrimeConverter singleConverter = new MockRtknToPrimeConverter();
        singleConverter.addUser(alice, 1e18); // sole user gets 100% of each round

        uint256 cap = 1_000e18;
        ReusablePrimeDistributor d3 = new ReusablePrimeDistributor(
            address(prime),
            address(singleConverter),
            cap,
            0
        );
        d3.cacheUsers(10);

        // Round 1: send full cap — clipped to cap (min(1000e18, 1000e18) = 1000e18)
        prime.mint(address(d3), cap);
        d3.startRound();
        assertEq(d3.roundPrimeAmount(), cap, "round = full cap");

        // Distribute: sole user gets entire cap (exact: cap * S / S = cap)
        d3.distribute(10);
        assertEq(prime.balanceOf(alice), cap,   "sole user received full cap");
        assertEq(d3.totalPrimeDistributed(), cap, "totalPrimeDistributed = cap");

        // paidSoFar = 0 + cap = cap = distributionCap → next startRound must fail
        prime.mint(address(d3), 1e18); // send more PRIME — doesn't matter
        vm.expectRevert("Cap reached");
        d3.startRound();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 15 — onlyOwner: admin functions revert for non-owner callers
    //
    // Covers: cacheUsers, startRound, distribute, setUserSkipped, emergencyWithdraw.
    // OZ Ownable reverts "Ownable: caller is not the owner".
    // ══════════════════════════════════════════════════════════════════════════
    function test_onlyOwner_adminFunctions_revert() public {
        vm.startPrank(alice); // alice is not owner

        vm.expectRevert("Ownable: caller is not the owner");
        dist.cacheUsers(10);

        vm.expectRevert("Ownable: caller is not the owner");
        dist.startRound();

        vm.expectRevert("Ownable: caller is not the owner");
        dist.distribute(10);

        vm.expectRevert("Ownable: caller is not the owner");
        dist.setUserSkipped(bob, true);

        vm.expectRevert("Ownable: caller is not the owner");
        dist.emergencyWithdraw(address(prime), alice);

        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 16 — emergencyWithdraw (rescue function): sweeps balance, resets round
    //
    // No separate rescueToken function exists in this contract — emergencyWithdraw
    // is the sole sweep mechanism (confirmed by reading the full source).
    //
    // Pin: ReusablePrimeDistributor.sol:212-225
    //   - If roundInProgress: resets to false (line 215-217)
    //   - Sweeps full ERC20 balance to recipient
    // ══════════════════════════════════════════════════════════════════════════
    function test_rescueToken_emergencyWithdrawSweepsBalance() public {
        _cacheAllUsers();
        _mintAndStartRound(100e18);

        assertEq(dist.roundInProgress(), true, "round in progress before rescue");
        uint256 balBefore = prime.balanceOf(address(bob)); // recipient for this test

        // emergencyWithdraw resets round AND sweeps PRIME to bob
        dist.emergencyWithdraw(address(prime), bob);

        assertEq(dist.roundInProgress(), false,   "roundInProgress reset to false");
        assertGt(prime.balanceOf(bob), balBefore, "bob received swept PRIME");
        assertEq(prime.balanceOf(address(dist)), 0, "distributor PRIME balance = 0 after sweep");
    }
}
