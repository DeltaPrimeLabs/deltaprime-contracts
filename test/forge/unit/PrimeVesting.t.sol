// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {PrimeVesting} from "../../../contracts/PrimeVesting.sol";
import {TestERC20} from "../helpers/TestERC20.sol";

/**
 * @title  PrimeVestingTest
 * @notice Suite 3.8A — cliff/linear vesting, claim rights, multi-participant.
 *
 * Contract facts (all pins reference contracts/PrimeVesting.sol):
 *
 * Constructor (lines 100-113):
 *   - Reverts InvalidStartTime() if startTime_ < block.timestamp (strictly less-than)
 *   - Reverts InvalidAddress() if primeToken_ == address(0)
 *
 * initializeVesting (lines 115-160):
 *   - onlyOwner
 *   - Reverts AlreadyInitialized() when vestingInitialized == true;
 *     vestingInitialized is set ONLY when isLastBatch == true (line 157-159),
 *     so partial-batch calls (isLastBatch=false) do not lock the gate.
 *   - Reverts InvalidVestingPeriod() if vestingPeriod == 0 (line 134-136)
 *   - Reverts InvalidAddress() for zero-address user (line 131-133)
 *   - UserExists guard (line 140): checks totalAmount != 0, so a participant
 *     added with totalAmount=0 CAN be re-added (the slot is overwritten).
 *   - Zero totalAmount does NOT revert — only vestingPeriod is validated (line 134).
 *
 * sendTokensToVesting (lines 184-199):
 *   - onlyOwner + nonReentrant
 *   - Reverts NotInitialized() if !vestingInitialized
 *   - Reverts VestingAlreadyStarted() if block.timestamp >= startTime (INCLUSIVE, line 194)
 *   - Pulls totalAmount from owner via safeTransferFrom (line 198)
 *
 * _claimable formula (lines 226-247):
 *   cliffEnd = startTime + cliffPeriod
 *   if (cliffEnd >= block.timestamp) → return 0    (INCLUSIVE: at exactly cliffEnd, still 0)
 *   duration = min(block.timestamp - cliffEnd, vestingPeriod)
 *   return (totalAmount * duration) / vestingPeriod - claimed
 *
 * _claimFor (lines 203-224):
 *   - Reverts Unauthorized()  if user != claimant && grantClaimRightTo != claimant
 *   - Reverts NothingToClaim() if _claimable(user) == 0
 *   - amount = Math.min(passed_amount, claimableAmount) — caller-passed amount is capped
 *   - Tokens transfer to USER address (not claimant) regardless of who calls (line 222)
 */
contract PrimeVestingTest is Test {
    // ─── fixture ──────────────────────────────────────────────────────────────
    TestERC20    internal prime;
    PrimeVesting internal vesting;

    // ─── actors ───────────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;
    address internal carol;

    // startTime is set 1 day ahead so setUp is always before vesting begins
    uint256 internal startTime;

    // ══════════════════════════════════════════════════════════════════════════
    // setUp
    // ══════════════════════════════════════════════════════════════════════════
    function setUp() public {
        vm.warp(1_750_000_000);
        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");

        prime     = new TestERC20("PRIME", "PRIME", 18);
        startTime = block.timestamp + 1 days;
        // Test contract is owner (OZ Ownable assigns msg.sender).
        vesting   = new PrimeVesting(address(prime), startTime);
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    /// Build a VestingInfo with grantClaimRightTo defaulting to address(0).
    function _info(
        uint32  cliff,
        uint32  period,
        uint256 amount
    ) internal pure returns (PrimeVesting.VestingInfo memory) {
        return PrimeVesting.VestingInfo({
            cliffPeriod:      cliff,
            vestingPeriod:    period,
            grantClaimRightTo: address(0),
            totalAmount:      amount
        });
    }

    /// Build a VestingInfo with an explicit grantClaimRightTo.
    function _infoWithGrant(
        uint32  cliff,
        uint32  period,
        uint256 amount,
        address grantee
    ) internal pure returns (PrimeVesting.VestingInfo memory) {
        return PrimeVesting.VestingInfo({
            cliffPeriod:      cliff,
            vestingPeriod:    period,
            grantClaimRightTo: grantee,
            totalAmount:      amount
        });
    }

    /// Initialize a single user and close the batch (isLastBatch=true).
    function _initSingle(
        address user,
        uint32  cliff,
        uint32  period,
        uint256 amount
    ) internal {
        address[] memory users_ = new address[](1);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](1);
        users_[0] = user;
        infos_[0] = _info(cliff, period, amount);
        vesting.initializeVesting(users_, infos_, true);
    }

    /// Mint totalAmount to this contract (owner), approve, then pull into vesting.
    function _fund(uint256 amount) internal {
        prime.mint(address(this), amount);
        prime.approve(address(vesting), amount);
        vesting.sendTokensToVesting();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — constructor: startTime in the past reverts InvalidStartTime
    //
    // Pin: PrimeVesting.sol:104-106
    //   if (startTime_ < block.timestamp) { revert InvalidStartTime(); }
    //   Strictly-less-than: block.timestamp itself is NOT in the past.
    // ══════════════════════════════════════════════════════════════════════════
    function test_constructor_startTimeInPast_reverts() public {
        vm.expectRevert(PrimeVesting.InvalidStartTime.selector);
        // block.timestamp - 1 is strictly in the past
        new PrimeVesting(address(prime), block.timestamp - 1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — constructor: zero primeToken address reverts InvalidAddress
    //
    // Pin: PrimeVesting.sol:107-109
    //   if (primeToken_ == address(0)) { revert InvalidAddress(); }
    // ══════════════════════════════════════════════════════════════════════════
    function test_constructor_zeroToken_reverts() public {
        vm.expectRevert(PrimeVesting.InvalidAddress.selector);
        new PrimeVesting(address(0), block.timestamp + 1 days);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — initializeVesting: non-owner call reverts
    //
    // Pin: PrimeVesting.sol:119 — modifier onlyOwner
    //   OZ Ownable reverts "Ownable: caller is not the owner"
    // ══════════════════════════════════════════════════════════════════════════
    function test_initializeVesting_onlyOwner_reverts() public {
        address[] memory users_ = new address[](0);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](0);

        vm.prank(alice); // alice is not owner
        vm.expectRevert("Ownable: caller is not the owner");
        vesting.initializeVesting(users_, infos_, false);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — initializeVesting: calling after isLastBatch=true reverts AlreadyInitialized
    //
    // Pin: PrimeVesting.sol:120-122 — guard on vestingInitialized
    //      PrimeVesting.sol:157-159 — vestingInitialized set only when isLastBatch==true
    //
    // A call with isLastBatch=false does not finalize, so subsequent partial batches
    // are allowed. Only after isLastBatch=true does AlreadyInitialized trigger.
    // ══════════════════════════════════════════════════════════════════════════
    function test_initializeVesting_doubleInit_reverts() public {
        // Partial batch (isLastBatch=false) — vestingInitialized stays false.
        address[] memory users1 = new address[](1);
        PrimeVesting.VestingInfo[] memory infos1 = new PrimeVesting.VestingInfo[](1);
        users1[0] = alice;
        infos1[0] = _info(0, 30 days, 100e18);
        vesting.initializeVesting(users1, infos1, false); // no revert, not finalized

        // Final batch — sets vestingInitialized = true.
        address[] memory users2 = new address[](1);
        PrimeVesting.VestingInfo[] memory infos2 = new PrimeVesting.VestingInfo[](1);
        users2[0] = bob;
        infos2[0] = _info(0, 30 days, 200e18);
        vesting.initializeVesting(users2, infos2, true); // finalizes
        assertEq(vesting.vestingInitialized(), true, "vestingInitialized set");

        // Any further call — even with empty arrays — reverts.
        address[] memory empty = new address[](0);
        PrimeVesting.VestingInfo[] memory emptyI = new PrimeVesting.VestingInfo[](0);
        vm.expectRevert(PrimeVesting.AlreadyInitialized.selector);
        vesting.initializeVesting(empty, emptyI, false);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — initializeVesting: zero totalAmount does NOT revert;
    //          the UserExists guard (line 140) checks `totalAmount != 0`, so
    //          a zero-amount user can be re-added and their slot overwritten.
    //
    // Pin: PrimeVesting.sol:134-136 — only vestingPeriod is checked, not totalAmount
    //      PrimeVesting.sol:140     — UserExists: if(userInfo.info.totalAmount != 0)
    //      PrimeVesting.sol:229-231 — _claimable: if totalAmount==0, return 0
    // ══════════════════════════════════════════════════════════════════════════
    function test_initializeVesting_zeroAmount_participant_succeeds() public {
        address[] memory users_ = new address[](1);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](1);
        users_[0] = alice;
        infos_[0] = _info(0, 30 days, 0); // zero totalAmount — vestingPeriod is valid

        // Must NOT revert — only vestingPeriod is validated at line 134.
        vesting.initializeVesting(users_, infos_, false);

        (PrimeVesting.VestingInfo memory stored, ) = vesting.userInfos(alice);
        assertEq(stored.totalAmount, 0, "zero-amount stored without revert");

        // Re-adding alice with totalAmount=0 again does NOT revert (UserExists
        // guard checks != 0, so 0-amount slot is not protected, line 140).
        vesting.initializeVesting(users_, infos_, false); // slot silently overwritten

        // Finalize with a real participant so vestingInitialized=true.
        users_[0] = bob;
        infos_[0] = _info(0, 30 days, 50e18);
        vesting.initializeVesting(users_, infos_, true);

        // Alice cannot claim: _claimable returns 0 when totalAmount==0 (line 229).
        vm.warp(startTime + 1);
        assertEq(vesting.claimable(alice), 0, "zero-amount user: permanently uncollectable");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — sendTokensToVesting: requires ERC20 approve, transfers totalAmount
    //
    // sendTokensToVesting calls safeTransferFrom(owner(), address(this), totalAmount)
    // Pin: PrimeVesting.sol:198
    // ══════════════════════════════════════════════════════════════════════════
    function test_sendTokensToVesting_requiresApproveAndTransfers() public {
        uint256 amount = 1000e18;
        _initSingle(alice, 0, 30 days, amount);

        prime.mint(address(this), amount); // mint to owner (test contract)
        prime.approve(address(vesting), amount);
        vesting.sendTokensToVesting();

        assertEq(prime.balanceOf(address(vesting)), amount, "vesting holds full PRIME");
        assertEq(prime.balanceOf(address(this)),    0,      "owner balance fully drained");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — sendTokensToVesting: reverts VestingAlreadyStarted at or after startTime
    //
    // Pin: PrimeVesting.sol:194-196
    //   if(block.timestamp >= startTime){ revert VestingAlreadyStarted(); }
    //   Inclusive: at block.timestamp == startTime the revert fires.
    // ══════════════════════════════════════════════════════════════════════════
    function test_sendTokensToVesting_afterStartTime_reverts() public {
        _initSingle(alice, 0, 30 days, 100e18);
        prime.mint(address(this), 100e18);
        prime.approve(address(vesting), 100e18);

        // Warp to exactly startTime — inclusive boundary triggers revert.
        vm.warp(startTime);
        vm.expectRevert(PrimeVesting.VestingAlreadyStarted.selector);
        vesting.sendTokensToVesting();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — claim: nothing claimable before cliff AND at exactly cliffEnd
    //
    // Pin: PrimeVesting.sol:233-236
    //   cliffEnd = startTime + cliffPeriod
    //   if (cliffEnd >= block.timestamp) { return 0; }
    //   INCLUSIVE: at block.timestamp == cliffEnd, _claimable returns 0 → NothingToClaim.
    // ══════════════════════════════════════════════════════════════════════════
    function test_claim_beforeCliff_reverts() public {
        uint256 amount = 100e18;
        uint32 cliff   = 7 days;
        uint32 period  = 30 days;

        _initSingle(alice, cliff, period, amount);
        _fund(amount);

        uint256 cliffEnd = startTime + cliff;

        // Before cliff: deep in lockup.
        vm.warp(startTime + 1);
        assertEq(vesting.claimable(alice), 0, "during cliff: claimable=0");

        // AT exactly cliffEnd: condition cliffEnd >= block.timestamp is TRUE → still 0.
        vm.warp(cliffEnd);
        assertEq(vesting.claimable(alice), 0, "at cliffEnd (inclusive): claimable=0");

        vm.prank(alice);
        vm.expectRevert(PrimeVesting.NothingToClaim.selector);
        vesting.claim(); // _claimable=0 → NothingToClaim (line 212)
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 9 — claim: at cliffEnd + 1 second, exactly 1 second of vesting unlocked
    //
    // Derived from formula (PrimeVesting.sol:238-246):
    //   cliffEnd  = startTime + cliffPeriod
    //   At t = cliffEnd + 1:
    //     duration  = min(1, vestingPeriod) = 1  (vestingPeriod >> 1)
    //     claimable = (totalAmount * 1) / vestingPeriod
    // ══════════════════════════════════════════════════════════════════════════
    function test_claim_atExactlyStartPlusCliff_behavior() public {
        uint256 amount = 100e18;
        uint32 cliff   = 7 days;
        uint32 period  = 30 days; // 2_592_000 seconds

        _initSingle(alice, cliff, period, amount);
        _fund(amount);

        // One second past the cliff end — FIRST second of vesting.
        vm.warp(startTime + cliff + 1);
        uint256 expected = amount * 1 / uint256(period); // = 100e18 / 2_592_000
        assertEq(vesting.claimable(alice), expected, "1s past cliff: 1s of vesting unlocked");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 10 — claim: mid-vesting proportionality — exact formula, no tolerance
    //
    // Uses period=100 seconds, amount=100e18 for integer-exact arithmetic:
    //   At cliffEnd + 50: duration=50, claimable = 100e18*50/100 = 50e18  (exact)
    //   At cliffEnd + 100: duration=100, claimable = 100e18 (full — minus prior claimed)
    //
    // Pin: PrimeVesting.sol:238-246 — integer division floors; chosen numbers eliminate truncation.
    // ══════════════════════════════════════════════════════════════════════════
    function test_claim_midVesting_exactlyProportional() public {
        uint256 amount = 100e18;
        uint32  cliff  = 0;   // no cliff: cliffEnd = startTime
        uint32  period = 100; // 100 seconds → clean 1% per second

        _initSingle(alice, cliff, period, amount);
        _fund(amount);

        // 50% through: block.timestamp = startTime + 50
        // cliffEnd = startTime; condition startTime >= startTime+50 is FALSE.
        // duration = min(50, 100) = 50
        vm.warp(startTime + 50);
        assertEq(vesting.claimable(alice), 50e18, "50% elapsed: 50e18 claimable");

        // Full vesting elapsed: block.timestamp = startTime + 100
        // duration = min(100, 100) = 100
        vm.warp(startTime + 100);
        assertEq(vesting.claimable(alice), 100e18, "100% elapsed: full amount claimable");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 11 — claim: after vesting fully elapsed, entire remainder is claimable
    //
    // After vestingPeriod seconds past cliffEnd:
    //   duration = min(vestingPeriod + N, vestingPeriod) = vestingPeriod
    //   claimable = totalAmount * vestingPeriod / vestingPeriod - claimed = totalAmount
    // ══════════════════════════════════════════════════════════════════════════
    function test_claim_afterVestingEnd_fullRemainder() public {
        uint256 amount = 500e18;
        uint32  cliff  = 0;
        uint32  period = 100;

        _initSingle(alice, cliff, period, amount);
        _fund(amount);

        // Warp well past vesting end (startTime + 200, double the period).
        vm.warp(startTime + 200);

        uint256 balanceBefore = prime.balanceOf(alice);
        vm.prank(alice);
        vesting.claim();

        assertEq(prime.balanceOf(alice) - balanceBefore, amount, "full amount received after vesting end");
        assertEq(vesting.claimable(alice), 0, "nothing left after full claim");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 12 — claim: double-claim only delivers the delta since last claim
    //
    // First claim at 50% → 50e18 taken.
    // Second claim at 100% → claimable = 100e18 - 50e18 = 50e18 (the formula subtracts .claimed)
    //
    // Pin: PrimeVesting.sol:245-246 — `(totalAmount * duration) / vestingPeriod - claimed`
    // ══════════════════════════════════════════════════════════════════════════
    function test_claim_doubleClaim_onlyDelta() public {
        uint256 amount = 100e18;
        uint32  cliff  = 0;
        uint32  period = 100;

        _initSingle(alice, cliff, period, amount);
        _fund(amount);

        // First claim at 50 seconds (50%)
        vm.warp(startTime + 50);
        vm.prank(alice);
        vesting.claim();
        assertEq(prime.balanceOf(alice), 50e18, "first claim: 50e18");

        // Second claim at full vesting (100 seconds)
        vm.warp(startTime + 100);
        assertEq(vesting.claimable(alice), 50e18, "claimable after first claim = remaining 50%");
        vm.prank(alice);
        vesting.claim();
        assertEq(prime.balanceOf(alice), 100e18, "total received = full amount after both claims");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 13 — claimFor: granted address succeeds; tokens go to USER, not claimant
    //
    // Pin: PrimeVesting.sol:206 — grantClaimRightTo check
    //      PrimeVesting.sol:222 — `primeToken.safeTransfer(user, amount)` → always to user
    // ══════════════════════════════════════════════════════════════════════════
    function test_claimOnBehalf_grantedAddress_succeeds() public {
        uint256 amount = 100e18;
        uint32  cliff  = 0;
        uint32  period = 100;

        // alice's vesting with carol as the authorized claimant
        address[] memory users_ = new address[](1);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](1);
        users_[0] = alice;
        infos_[0] = _infoWithGrant(cliff, period, amount, carol); // carol can claim for alice
        vesting.initializeVesting(users_, infos_, true);
        _fund(amount);

        vm.warp(startTime + 100); // full vesting elapsed

        uint256 aliceBefore = prime.balanceOf(alice);
        uint256 carolBefore = prime.balanceOf(carol);

        vm.prank(carol); // carol is the authorized claimant
        vesting.claimFor(alice);

        // Tokens go to ALICE, not carol (pin: line 222 safeTransfer(user, amount))
        assertEq(prime.balanceOf(alice) - aliceBefore, amount, "alice received tokens");
        assertEq(prime.balanceOf(carol), carolBefore,          "carol balance unchanged");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 14 — claimFor: arbitrary address (not grantClaimRightTo) reverts Unauthorized
    //
    // Pin: PrimeVesting.sol:206-208
    //   if (user != claimant && userInfo.info.grantClaimRightTo != claimant) {
    //     revert Unauthorized();
    //   }
    // ══════════════════════════════════════════════════════════════════════════
    function test_claimOnBehalf_arbitraryAddress_reverts() public {
        uint256 amount = 100e18;

        // alice's vesting with carol as authorized claimant, NOT bob
        address[] memory users_ = new address[](1);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](1);
        users_[0] = alice;
        infos_[0] = _infoWithGrant(0, 100, amount, carol);
        vesting.initializeVesting(users_, infos_, true);
        _fund(amount);

        vm.warp(startTime + 50); // some vesting elapsed

        vm.prank(bob); // bob is NOT grantClaimRightTo and NOT alice
        vm.expectRevert(PrimeVesting.Unauthorized.selector);
        vesting.claimFor(alice);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 15 — multiple participants with different cliffs vest independently
    //
    // alice: cliff=0,  period=100, amount=100e18
    // bob:   cliff=50, period=100, amount=200e18  (cliffEnd = startTime + 50)
    //
    // At startTime + 50:
    //   alice: duration = min(50, 100) = 50; claimable = 100e18 * 50 / 100 = 50e18
    //   bob:   cliffEnd = startTime+50; cliffEnd >= block.timestamp → TRUE → 0
    //
    // At startTime + 51:
    //   alice: duration = 51; claimable = 100e18 * 51 / 100 = 51e18
    //   bob:   cliffEnd = startTime+50 < startTime+51; duration=1; claimable = 200e18*1/100 = 2e18
    // ══════════════════════════════════════════════════════════════════════════
    function test_multipleParticipants_differentCliffs_independentVesting() public {
        uint256 aliceAmount = 100e18;
        uint256 bobAmount   = 200e18;

        address[] memory users_ = new address[](2);
        PrimeVesting.VestingInfo[] memory infos_ = new PrimeVesting.VestingInfo[](2);
        users_[0] = alice;
        infos_[0] = _info(0,  100, aliceAmount); // no cliff
        users_[1] = bob;
        infos_[1] = _info(50, 100, bobAmount);   // 50-second cliff
        vesting.initializeVesting(users_, infos_, true);
        _fund(aliceAmount + bobAmount);

        // ── at startTime + 50 ─────────────────────────────────────────────────
        // alice has 50 seconds of vesting; bob is STILL in cliff (cliffEnd inclusive = 0)
        vm.warp(startTime + 50);
        assertEq(vesting.claimable(alice), 50e18, "alice at t=50: 50% unlocked");
        assertEq(vesting.claimable(bob),   0,     "bob at t=50: at cliffEnd (inclusive), still 0");

        // ── at startTime + 51 ─────────────────────────────────────────────────
        // alice: 51/100 unlocked = 51e18
        // bob:   1 second past cliff; duration=1; 200e18*1/100 = 2e18
        vm.warp(startTime + 51);
        assertEq(vesting.claimable(alice), 51e18, "alice at t=51: 51e18");
        assertEq(vesting.claimable(bob),   2e18,  "bob at t=51: 1s past cliff = 2e18");

        // Each claims independently — no cross-contamination of .claimed counters.
        vm.prank(alice); vesting.claim();
        vm.prank(bob);   vesting.claim();
        assertEq(prime.balanceOf(alice), 51e18, "alice receives 51e18");
        assertEq(prime.balanceOf(bob),   2e18,  "bob receives 2e18");
    }
}
