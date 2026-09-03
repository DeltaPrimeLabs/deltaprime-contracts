// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {LinearIndex} from "../../../contracts/LinearIndex.sol";

/**
 * @title  LinearIndexTest
 * @notice Suite 3.4 — LinearIndex time-based accrual, rate boundaries, auth.
 *
 * LinearIndex mechanics (contracts/LinearIndex.sol):
 *   getLinearFactor(period) = rate * period * 1e9 / SECONDS_IN_YEAR + 1e27  (line 101)
 *   getIndex()              = index * getLinearFactor(period) / 1e27          (line 71)
 *   setRate()   → updateIndex() first, then sets rate                         (line 44)
 *   updateUser()→ records block.timestamp and current getIndex() in prevIndex  (line 58)
 *   getIndexedValue(value, user) = value * getIndex() / prevIndex[userTime]   (line 87)
 *
 * The index is LINEAR within each rate segment; compounding happens at each
 * setRate() call because updateIndex() snapshots the accrued index.
 *
 * SECONDS_IN_YEAR = 365 days = 31_536_000 s (LinearIndex.sol:16)
 * BASE_RATE       = 1e18                    (LinearIndex.sol:17)
 */
contract LinearIndexTest is Test {
    LinearIndex internal idx;

    // owner = this test contract (initialize(address(0)) → __Ownable_init → owner=caller)
    address internal alice = makeAddr("alice");

    uint256 constant SECONDS_IN_YEAR = 365 days;

    function setUp() public {
        vm.warp(1_750_000_000);
        idx = new LinearIndex();
        // Pass address(0) so that the test contract remains owner.
        idx.initialize(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — initialize sets index to 1e18 and getIndex() returns 1e18
    //          immediately (period == 0).
    //
    // Pin: LinearIndex.sol:28-30
    //   index = BASE_RATE (= 1e18)
    //   indexUpdateTime = block.timestamp
    //   getIndex: period=0 → returns index directly (line 72-74)
    // ══════════════════════════════════════════════════════════════════════════
    function test_initialize_setsIndexOneRay() public {
        assertEq(idx.index(), 1e18,            "stored index = 1e18 at init");
        assertEq(idx.getIndex(), 1e18,         "getIndex() = 1e18 immediately after init");
        assertEq(idx.indexUpdateTime(), block.timestamp, "indexUpdateTime = now");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — second initialize() reverts with OZ initializer guard.
    //
    // Pin: OZ Initializable (node_modules/@openzeppelin/contracts-upgradeable):
    //   "Initializable: contract is already initialized"
    // ══════════════════════════════════════════════════════════════════════════
    function test_secondInitialize_reverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        idx.initialize(address(0));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — setRate and updateUser are onlyOwner.
    //
    // Pin: LinearIndex.sol:44 modifier onlyOwner on setRate()
    //      LinearIndex.sol:57 modifier onlyOwner on updateUser()
    //   OZ Ownable revert: "Ownable: caller is not the owner"
    // ══════════════════════════════════════════════════════════════════════════
    function test_setRate_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        idx.setRate(5e16);

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        idx.updateUser(alice);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — getIndex() after 365 days at 5% rate = exactly 1.05e18 (linear).
    //
    // Derivation (LinearIndex.sol:101):
    //   linearFactor = rate * period * 1e9 / SECONDS_IN_YEAR + 1e27
    //   = 5e16 * 31_536_000 * 1e9 / 31_536_000 + 1e27
    //   = 5e25 + 1e27 = 1.05e27
    //   getIndex = 1e18 * 1.05e27 / 1e27 = 1.05e18  (exact, no truncation)
    // ══════════════════════════════════════════════════════════════════════════
    function test_getIndex_365days_5pct_exact() public {
        idx.setRate(5e16); // 5% APR
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        assertEq(idx.getIndex(), 1.05e18, "5% linear x 1yr = 1.05e18 exactly");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — rate change mid-period: compounding at segment boundaries.
    //
    // Scenario: 5% for 6 months then 10% for 6 months.
    // After 6mo at 5%:   setRate(10%) triggers updateIndex():
    //   linearFactor = 5e16 * (365d/2) * 1e9 / 365d + 1e27 = 2.5e25 + 1e27 = 1.025e27
    //   index        = 1e18 * 1.025e27 / 1e27 = 1.025e18  (exact)
    //
    // After another 6mo at 10%:
    //   linearFactor = 10e16 * (365d/2) * 1e9 / 365d + 1e27 = 5e25 + 1e27 = 1.05e27
    //   getIndex = 1.025e18 * 1.05e27 / 1e27 = 1.07625e18  (exact)
    //
    // This is linear compounding at segment boundaries (not continuous compound).
    // ══════════════════════════════════════════════════════════════════════════
    function test_rateChangeMidPeriod_compoundsAtBoundary() public {
        uint256 sixMonths = SECONDS_IN_YEAR / 2; // 15_768_000 s

        idx.setRate(5e16);
        vm.warp(block.timestamp + sixMonths);

        // setRate(10%) triggers updateIndex() first → crystallises 5% half-year growth.
        idx.setRate(10e16);
        assertEq(idx.index(), 1.025e18, "after 6mo@5%: crystallised index = 1.025e18");

        vm.warp(block.timestamp + sixMonths);
        assertEq(idx.getIndex(), 1.07625e18, "after 6mo@10% on top: index = 1.07625e18");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — getIndexedValue round-trip after accrual.
    //
    // updateUser sets prevIndex[t0] = getIndex() at t0.
    // After period dt, getIndexedValue(value, user) = value * getIndex(t1) / getIndex(t0).
    //
    // At 5% for 1 year:   value * 1.05e18 / 1e18 = value * 1.05
    // At 10% for 1 year:  value * 1.1e18  / 1e18 = value * 1.1
    //
    // If user has never been updated, prevUserIndex = getIndex() → ratio = 1 (no growth).
    // ══════════════════════════════════════════════════════════════════════════
    function test_getIndexedValue_roundTrip_afterAccrual() public {
        uint256 principal = 1000e18;

        // Record alice's baseline.
        idx.setRate(5e16);
        idx.updateUser(alice); // prevIndex[t0] = 1e18

        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        // getIndex() = 1.05e18; prevIndex[t0] = 1e18
        uint256 indexed_ = idx.getIndexedValue(principal, alice);
        assertEq(indexed_, 1050e18, "5% x 1yr: value grows from 1000 to 1050");

        // User never registered → prevUserIndex = current getIndex → ratio 1.
        address stranger = makeAddr("stranger");
        assertEq(idx.getIndexedValue(principal, stranger), principal, "unregistered user: no growth");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — zero-rate period does not change the index.
    //
    // Pin: LinearIndex.sol:101
    //   getLinearFactor(period) = 0 * period * 1e9 / SECONDS_IN_YEAR + 1e27 = 1e27
    //   getIndex = index * 1e27 / 1e27 = index (unchanged).
    // ══════════════════════════════════════════════════════════════════════════
    function test_zeroRate_indexDoesNotChange() public {
        // rate defaults to 0 after initialize (uint256 zero-init).
        uint256 indexBefore = idx.getIndex(); // = 1e18
        assertEq(idx.rate(), 0, "rate is 0 after initialize");

        vm.warp(block.timestamp + SECONDS_IN_YEAR);
        assertEq(idx.getIndex(), indexBefore, "zero rate: index unchanged after 1yr");

        // Explicitly set rate to 0 and verify again.
        idx.setRate(5e16);
        idx.setRate(0);
        vm.warp(block.timestamp + SECONDS_IN_YEAR);
        uint256 indexSnapshot = idx.index(); // crystallised after setRate(0) call
        assertEq(idx.getIndex(), indexSnapshot, "rate=0: index stays at crystallised value");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — updateUser with no rate does not corrupt future accrual.
    //
    // If prevIndex[t] is recorded while rate=0, the index is still 1e18.
    // After a later setRate(R), getIndexedValue grows proportionally from t.
    // ══════════════════════════════════════════════════════════════════════════
    function test_updateUser_zeroRate_thenAccrue() public {
        // At t0: rate=0, record alice.
        idx.updateUser(alice); // prevIndex[t0] = 1e18

        // Warp half-year with no rate change → getIndex still 1e18.
        vm.warp(block.timestamp + SECONDS_IN_YEAR / 2);

        // Set 10% rate (crystallises index = 1e18).
        idx.setRate(10e16);

        // Warp one more year.
        vm.warp(block.timestamp + SECONDS_IN_YEAR);

        // getIndex = 1e18 * (10e16 * 365d * 1e9 / 365d + 1e27) / 1e27
        //          = 1e18 * 1.1e27 / 1e27 = 1.1e18
        assertEq(idx.getIndex(), 1.1e18, "getIndex after 1yr@10% from 1e18 base = 1.1e18");

        // alice's prevIndex = 1e18 (recorded at t0 when index=1e18).
        // getIndexedValue = principal * 1.1e18 / 1e18 = 1.1 * principal.
        uint256 principal = 500e18;
        assertEq(idx.getIndexedValue(principal, alice), 550e18, "alice grows from t0 baseline");
    }
}
