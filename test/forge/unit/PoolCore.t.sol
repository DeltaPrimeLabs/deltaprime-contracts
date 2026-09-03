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
 * @title  PoolCoreTest
 * @notice Self-contained suite testing Pool deposit/borrow/repay mechanics, interest
 *         accrual, utilisation breakpoints, and accounting invariants.
 *
 *         Fixture: plain Pool + TestERC20(USDC,6) + 2× LinearIndex (owned by pool)
 *         + WavaxVariableUtilisationRatesCalculator (real piecewise-linear curve) +
 *         OpenBorrowersRegistry (canBorrow=true for everyone).
 *
 *         Does NOT touch DeltaPrimeFixture — fully isolated pool-level tests.
 */
contract PoolCoreTest is Test {
    // ─── fixture ──────────────────────────────────────────────────────────────
    Pool internal pool;
    TestERC20 internal usdc;
    WavaxVariableUtilisationRatesCalculator internal ratesCalc;
    OpenBorrowersRegistry internal registry;
    LinearIndex internal depositIdx;
    LinearIndex internal borrowIdx;

    // ─── actors ───────────────────────────────────────────────────────────────
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;

    // ─── constants ────────────────────────────────────────────────────────────
    uint256 constant D6 = 1e6; // USDC has 6 decimals

    function setUp() public {
        vm.warp(1_750_000_000);

        alice = makeAddr("alice");
        bob   = makeAddr("bob");
        carol = makeAddr("carol");
        dave  = makeAddr("dave");

        usdc      = new TestERC20("USD Coin", "USDC", 6);
        ratesCalc = new WavaxVariableUtilisationRatesCalculator();
        registry  = new OpenBorrowersRegistry();
        pool      = new Pool();
        depositIdx = new LinearIndex();
        borrowIdx  = new LinearIndex();

        // Indices must be owned by the pool — pool.initialize() calls
        // _updateRates() which calls depositIndex.setRate() (onlyOwner on LinearIndex).
        // LinearIndex.initialize: __Ownable_init (owner = caller = this) then
        // transferOwnership(pool) — pattern mirrors DeltaPrimeFixture._deployPool.
        depositIdx.initialize(address(pool));
        borrowIdx.initialize(address(pool));

        // Pool.initialize: __Ownable_init → owner = this (test contract).
        pool.initialize(
            IRatesCalculator(address(ratesCalc)),
            IBorrowersRegistry(address(registry)),
            IIndex(address(depositIdx)),
            IIndex(address(borrowIdx)),
            payable(address(usdc)),
            IPoolRewarder(address(0)),
            0 // totalSupplyCap = 0 → uncapped
        );
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    /// Mint USDC to user and grant unlimited pool approval.
    function _fund(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(pool), type(uint256).max);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — first deposit is 1:1; second depositor after interest accrual
    //          receives a fair share (balance proportional to deposited value,
    //          not diluted by prior interest).
    // ══════════════════════════════════════════════════════════════════════════
    function test_firstDepositOneToOne_secondDepositorFairShare() public {
        // Alice deposits 100k USDC — initial pool, expect 1:1 share credit.
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        assertEq(pool.balanceOf(alice), 100_000 * D6, "first depositor: 1:1");

        // Bob borrows 50k → 50% utilisation, deposit rate kicks in.
        _fund(bob, 0);
        vm.prank(bob);
        pool.borrow(50_000 * D6);

        // Warp 30 days so interest accrues.
        vm.warp(block.timestamp + 30 days);

        // Carol deposits 100k after interest has accrued.
        _fund(carol, 100_000 * D6);
        vm.prank(carol);
        pool.deposit(100_000 * D6);

        // Carol's userUpdateTime is set to now, prevIndex[now] = current index.
        // getIndexedValue(100k, carol) = 100k * currentIndex / currentIndex = 100k.
        assertEq(pool.balanceOf(carol), 100_000 * D6, "second depositor: 1:1 at deposit time");

        // Alice earned interest — her balance is strictly greater than principal.
        assertGt(pool.balanceOf(alice), 100_000 * D6, "first depositor: interest accrued");

        // Fair-share check: carol gets 100k / (alice_balance + carol_balance) of total.
        // Equivalently, carol.balanceOf / (alice.balanceOf + carol.balanceOf) ==
        // 100k / (alice.balanceOf + 100k) within 1 ppm relative tolerance.
        uint256 aliceBal = pool.balanceOf(alice);
        uint256 carolBal = pool.balanceOf(carol);
        uint256 totalBal = aliceBal + carolBal;

        // Cross-multiply to avoid division: carol/total == 100k/(alice+100k)
        // ⇒ carol*(alice+100k) == 100k*total  (within 1e-6 relative = 1 unit in 1e6)
        uint256 lhs = carolBal * (aliceBal + 100_000 * D6);
        uint256 rhs = 100_000 * D6 * totalBal;
        uint256 tol = rhs / 1_000_000; // 1 ppm of rhs
        assertApproxEqAbs(lhs, rhs, tol == 0 ? 1 : tol, "fair-share ratio within 1ppm");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — deposit transfers underlying into the pool;
    //          zero-amount deposit reverts with ZeroDepositAmount.
    //
    // Behavior pin: Pool.sol:421 — `if(_amount == 0) revert ZeroDepositAmount()`
    // ══════════════════════════════════════════════════════════════════════════
    function test_depositTransfersUnderlying_zeroReverts() public {
        // Zero deposit — Pool.sol:421
        vm.expectRevert(Pool.ZeroDepositAmount.selector);
        vm.prank(alice);
        pool.deposit(0);

        // Non-zero deposit moves underlying tokens into the pool.
        uint256 amt = 5_000 * D6;
        _fund(alice, amt);
        uint256 poolBefore = usdc.balanceOf(address(pool));

        vm.prank(alice);
        pool.deposit(amt);

        assertEq(usdc.balanceOf(address(pool)), poolBefore + amt, "USDC transferred to pool");
        assertEq(pool.balanceOf(alice), amt, "shares minted 1:1");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — borrow moves funds + getBorrowed tracks; full repay clears debt.
    // ══════════════════════════════════════════════════════════════════════════
    function test_borrowTracksBorrowed_repayClears() public {
        // Deposit first (canBorrow modifier: totalSupply==0 → InsufficientPoolFunds).
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        uint256 borrowAmt = 40_000 * D6;
        uint256 poolBefore = usdc.balanceOf(address(pool));
        uint256 bobBefore  = usdc.balanceOf(bob);

        // Bob borrows — OpenBorrowersRegistry.canBorrow returns true for anyone.
        vm.prank(bob);
        pool.borrow(borrowAmt);

        assertEq(usdc.balanceOf(address(pool)), poolBefore - borrowAmt, "pool USDC decreased");
        assertEq(usdc.balanceOf(bob),           bobBefore  + borrowAmt, "bob received USDC");
        assertEq(pool.getBorrowed(bob),          borrowAmt,             "getBorrowed tracks principal");

        // Warp 10 days — interest accrues.
        vm.warp(block.timestamp + 10 days);

        uint256 owed = pool.getBorrowed(bob);
        assertGt(owed, borrowAmt, "borrower owes interest after warp");

        // Full repay: _accumulateBorrowingInterest updates borrowed[bob] = getBorrowed(bob),
        // then checks amount <= borrowed[bob].  Fund bob with extra for interest.
        usdc.mint(bob, owed - borrowAmt); // top-up for interest portion
        vm.startPrank(bob);
        usdc.approve(address(pool), owed);
        pool.repay(owed);
        vm.stopPrank();

        assertEq(pool.getBorrowed(bob), 0, "debt cleared after full repay");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — interest accrual over 365 days; spread invariant:
    //          depositors' total gains ≤ borrowers' total interest paid.
    //
    // At 50% util: borrow_rate = 0.025 APR, deposit_rate ≈ 0.0125 APR (linear).
    // Total borrow interest = 50k * 0.025 = 1250 USDC.
    // Total deposit gain    = 100k * 0.0125 = 1250 USDC.
    // (Spread 1e-12 makes deposit gain infinitesimally less, but rounds equal at
    //  6-decimal precision.)
    // ══════════════════════════════════════════════════════════════════════════
    function test_interestAccrual_spreadInvariant() public {
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        vm.prank(bob);
        pool.borrow(50_000 * D6); // 50% util; rates update via _updateRates()

        vm.warp(block.timestamp + 365 days);

        uint256 borrowerOwes = pool.getBorrowed(bob); // interest-adjusted
        assertGt(borrowerOwes, 50_000 * D6, "borrower owes more than principal");

        uint256 aliceBalance = pool.balanceOf(alice); // interest-adjusted via depositIdx
        assertGt(aliceBalance, 100_000 * D6, "depositor balance grew");

        // Spread invariant: deposit interest gained <= borrow interest paid.
        // LinearIndex is additive (not compound), so borrower interest = 50k * rate * 1yr.
        // Deposit gain = 100k * depositRate * 1yr = 100k * (borrowRate * (1-spread) * util).
        uint256 depositorGain = aliceBalance - 100_000 * D6;
        uint256 borrowerInterest = borrowerOwes - 50_000 * D6;

        assertLe(depositorGain, borrowerInterest + 1, "depositor gains <= borrower interest (+ 1 wei rounding)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — higher utilisation yields strictly higher borrow rate.
    //
    // WavaxVariableUtilisationRatesCalculator breakpoints:
    //   ≤60% util → SLOPE_1 * util  (0.05 * util)
    //   ≤80% util → SLOPE_2 * util - OFFSET_2  (0.20*util - 0.09)
    //   ≤90% util → SLOPE_3 * util - OFFSET_3  (0.50*util - 0.33)
    //   ≤100%     → SLOPE_4 * util - OFFSET_4  (29.8*util - 26.7)
    //
    // Compare 50% (segment 1) vs 85% (segment 3) over same 30-day window.
    // ══════════════════════════════════════════════════════════════════════════
    function test_utilizationBreakpoints_higherRateAtHigherUtil() public {
        // Both pools are set up and funded BEFORE the time warp so that both
        // accumulate interest over the same 30-day window.

        // ── scenario A: 50% util ─────────────────────────────────────────────
        Pool poolA = _freshPool();
        TestERC20 usdcA = TestERC20(address(poolA.tokenAddress()));

        address lenderA   = makeAddr("lenderA");
        address borrowerA = makeAddr("borrowerA");

        usdcA.mint(lenderA, 100_000 * D6);
        vm.prank(lenderA);
        usdcA.approve(address(poolA), type(uint256).max);
        vm.prank(lenderA);
        poolA.deposit(100_000 * D6);
        vm.prank(borrowerA);
        poolA.borrow(50_000 * D6); // 50% util — SLOPE_1 segment (<=60%)

        // ── scenario B: 85% util ─────────────────────────────────────────────
        Pool poolB = _freshPool();
        TestERC20 usdcB = TestERC20(address(poolB.tokenAddress()));

        address lenderB   = makeAddr("lenderB");
        address borrowerB = makeAddr("borrowerB");

        usdcB.mint(lenderB, 100_000 * D6);
        vm.prank(lenderB);
        usdcB.approve(address(poolB), type(uint256).max);
        vm.prank(lenderB);
        poolB.deposit(100_000 * D6);
        vm.prank(borrowerB);
        poolB.borrow(85_000 * D6); // 85% util — SLOPE_3 segment (>80%, <=90%)

        // Both pools started at the same block.timestamp; warp 30 days now.
        vm.warp(block.timestamp + 30 days);

        uint256 interestA = poolA.getBorrowed(borrowerA) - 50_000 * D6;
        uint256 interestB = poolB.getBorrowed(borrowerB) - 85_000 * D6;

        // Per-unit rate comparison — cross-multiply to avoid division:
        //   interestA/50k  vs  interestB/85k  →  interestB*50k > interestA*85k
        assertGt(interestB * 50_000, interestA * 85_000, "85% util accrues faster per unit than 50%");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — borrowing beyond the 92.5% max utilisation cap reverts.
    //
    // Behavior pin: Pool.sol:872 canBorrow modifier (post-hook):
    //   if((totalBorrowed() * 1e18) / totalSupply() > getMaxPoolUtilisationForBorrowing())
    //       revert MaxPoolUtilisationBreached();
    // getMaxPoolUtilisationForBorrowing() == 0.925e18  (Pool.sol:746)
    // ══════════════════════════════════════════════════════════════════════════
    function test_borrowBeyondMaxUtil_reverts() public {
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        // 93% util → (93_000e6 * 1e18) / 100_000e6 = 0.93e18 > 0.925e18 → revert
        vm.expectRevert(Pool.MaxPoolUtilisationBreached.selector);
        vm.prank(bob);
        pool.borrow(93_000 * D6);

        // 92.5% util boundary: exactly 0.925e18 → NOT > 0.925e18 → succeeds.
        // (92_500e6 * 1e18) / 100_000e6 = 0.925e18  — equal, not greater.
        vm.prank(bob);
        pool.borrow(92_500 * D6); // must not revert
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — repaying more than borrowed reverts.
    //
    // Behavior pin: Pool.sol:618
    //   if(amount > borrowed[msg.sender]) revert RepayingMoreThanWasBorrowed();
    // Note: _accumulateBorrowingInterest is called first, so borrowed[msg.sender]
    // is up-to-date before the check.
    // ══════════════════════════════════════════════════════════════════════════
    function test_repayMoreThanOwed_reverts() public {
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        vm.prank(bob);
        pool.borrow(50_000 * D6);

        // Immediately (same block): borrowed[bob] == 50_000e6.
        // Repaying 50_001e6 exceeds that — must revert.
        usdc.mint(bob, 1);
        vm.startPrank(bob);
        usdc.approve(address(pool), 50_001 * D6);
        vm.expectRevert(Pool.RepayingMoreThanWasBorrowed.selector);
        pool.repay(50_001 * D6);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — totalSupply() == sum of all depositor balances after 3 deposits.
    //
    // Proof: _deposited[pool] is updated at each deposit via _accumulateDepositInterest
    // to (old_pool_balance + new_deposit). Since all three deposit in the same block,
    // prevIndex[t0] is identical for all users and the pool.  At any later time t:
    //   totalSupply = _deposited[pool] * I(t)/I(t0)
    //               = (sum _deposited[user_i]) * I(t)/I(t0)
    //               = sum balanceOf(user_i)
    // Exact equality holds when same prevIndex; tolerance 5 wei covers truncation.
    // ══════════════════════════════════════════════════════════════════════════
    function test_totalSupplyConservation_threeDpositors() public {
        // All three deposit in the same block to share the same prevIndex[t0].
        _fund(alice, 100_000 * D6);
        _fund(bob,   200_000 * D6);
        _fund(carol, 300_000 * D6);

        vm.prank(alice); pool.deposit(100_000 * D6);
        vm.prank(bob);   pool.deposit(200_000 * D6);
        vm.prank(carol); pool.deposit(300_000 * D6);

        // Dave borrows 300k → 50% util → non-zero interest rate.
        vm.prank(dave);
        pool.borrow(300_000 * D6);

        // Warp 30 days — interest accrues but no interactions reset prevIndex.
        vm.warp(block.timestamp + 30 days);

        uint256 sumBalances = pool.balanceOf(alice) + pool.balanceOf(bob) + pool.balanceOf(carol);
        uint256 supply = pool.totalSupply();

        // totalSupply() = balanceOf(address(this)); both use the same index arithmetic.
        assertApproxEqAbs(supply, sumBalances, 5, "totalSupply == sum of depositor balances (within 5 wei)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 9 — direct token transfer (donation) to pool does NOT mint shares
    //          and does not corrupt accounting.
    //
    // The pool uses _deposited[user] for share tracking, not raw ERC20 balance.
    // A direct transfer increases pool USDC balance (and thus borrowable liquidity)
    // but leaves _deposited[address(this)] (= totalSupply) unchanged.
    // ══════════════════════════════════════════════════════════════════════════
    function test_donationAttack_doesNotMintShares() public {
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        uint256 aliceBalBefore = pool.balanceOf(alice);
        uint256 supplyBefore   = pool.totalSupply();

        // Dave donates 50k USDC directly to the pool (no deposit()).
        usdc.mint(dave, 50_000 * D6);
        vm.prank(dave);
        usdc.transfer(address(pool), 50_000 * D6);

        // Alice's balance and totalSupply must be unchanged.
        assertEq(pool.balanceOf(alice), aliceBalBefore, "donation does not dilute existing depositor");
        assertEq(pool.totalSupply(),    supplyBefore,   "totalSupply unaffected by donation");

        // Raw ERC20 balance of pool IS higher — the donation sits as surplus.
        assertEq(usdc.balanceOf(address(pool)), 150_000 * D6, "pool USDC balance includes donation");

        // Carol deposits after donation — still gets 1:1 shares.
        _fund(carol, 100_000 * D6);
        vm.prank(carol);
        pool.deposit(100_000 * D6);
        assertEq(pool.balanceOf(carol), 100_000 * D6, "post-donation deposit still 1:1");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 10 — second call to initialize() reverts (OZ initializer guard).
    //
    // Behavior pin: OZ Initializable v4.4.1 (node_modules):
    //   "Initializable: contract is already initialized"  (Initializable.sol:120)
    // ══════════════════════════════════════════════════════════════════════════
    function test_secondInitialize_reverts() public {
        vm.expectRevert("Initializable: contract is already initialized");
        pool.initialize(
            IRatesCalculator(address(ratesCalc)),
            IBorrowersRegistry(address(registry)),
            IIndex(address(depositIdx)),
            IIndex(address(borrowIdx)),
            payable(address(usdc)),
            IPoolRewarder(address(0)),
            0
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Internal — deploy a fresh isolated pool (own token, indices, registry)
    // without a supply cap, used for rate-comparison scenarios.
    // ══════════════════════════════════════════════════════════════════════════
    function _freshPool() internal returns (Pool p) {
        TestERC20 tok = new TestERC20("USD Coin", "USDC", 6);
        LinearIndex di = new LinearIndex();
        LinearIndex bi = new LinearIndex();
        p = new Pool();
        di.initialize(address(p));
        bi.initialize(address(p));
        p.initialize(
            IRatesCalculator(address(new WavaxVariableUtilisationRatesCalculator())),
            IBorrowersRegistry(address(new OpenBorrowersRegistry())),
            IIndex(address(di)),
            IIndex(address(bi)),
            payable(address(tok)),
            IPoolRewarder(address(0)),
            0
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DPSC-502 — aggregate/individual debt-conservation drift must not brick repay
    //
    // `_accumulateBorrowingInterest` re-derives BOTH borrowed[user] and
    // borrowed[address(this)] through LinearIndex.getIndexedValue (floor division) on
    // every borrow/repay by ANY account. The aggregate's index checkpoint therefore
    // advances on every pool operation while a passive borrower's stays stale, and
    // compounded truncation leaves the aggregate strictly below that borrower's own
    // debt. `Pool.repay` guards the user leg but not the aggregate leg, so repaying a
    // dominant borrower's full debt underflows — which is exactly what
    // SmartLoanLiquidationFacet._repayAllDebts does, blocking liquidation entirely.
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Opens the drift: alice borrows and goes passive, bob churns hourly.
    function _openConservationGap(uint256 cycles) internal {
        _fund(dave, 1_000_000 * D6);
        vm.prank(dave);
        pool.deposit(1_000_000 * D6);

        // Dominant borrower — borrows once, never touches the pool again.
        vm.prank(alice);
        pool.borrow(10_000 * D6);

        // Churner — hourly borrow/repay cycles re-floor the aggregate each time.
        _fund(bob, 10_000 * D6);
        for (uint256 i; i < cycles; ++i) {
            vm.warp(block.timestamp + 1 hours);
            vm.prank(bob);
            pool.borrow(1 * D6);
            vm.warp(block.timestamp + 1 hours);
            // Read first: an inner view call would consume the prank.
            uint256 bobDebt = pool.getBorrowed(bob);
            vm.prank(bob);
            pool.repay(bobDebt);
        }
    }

    function test_dpsc502_aggregateDriftsBelowDominantBorrower() public {
        _openConservationGap(60);

        uint256 aliceDebt = pool.getBorrowed(alice);
        uint256 aggregate = pool.totalBorrowed();

        // Bob is square, so the aggregate should equal alice's debt exactly — it does not.
        assertEq(pool.getBorrowed(bob), 0, "churner must be fully repaid");
        assertGt(aliceDebt, aggregate, "aggregate must have drifted below the dominant borrower");
        assertLt(aliceDebt - aggregate, 1000, "drift is wei-scale, not economically material");
    }

    function test_dpsc502_fullDebtRepayDoesNotUnderflow() public {
        _openConservationGap(60);

        uint256 aliceDebt = pool.getBorrowed(alice);
        assertGt(aliceDebt, pool.totalBorrowed(), "arrangement: gap must be open");

        // This is the call SmartLoanLiquidationFacet._repayAllDebts makes. Without the
        // clamp in Pool.repay it panics with 0x11 (arithmetic underflow) on the aggregate
        // decrement and the liquidation reverts.
        _fund(alice, aliceDebt);
        vm.prank(alice);
        pool.repay(aliceDebt);

        assertEq(pool.getBorrowed(alice), 0, "borrower debt cleared");
        assertEq(pool.totalBorrowed(), 0, "aggregate clamped to zero, not underflowed");
    }

    function test_dpsc502_clampOnlyAbsorbsDrift_normalRepayUnaffected() public {
        // With no drift open, a partial repay must still decrement the aggregate by the
        // full amount — the clamp must not silently swallow real repayments.
        _fund(dave, 100_000 * D6);
        vm.prank(dave);
        pool.deposit(100_000 * D6);

        vm.prank(alice);
        pool.borrow(10_000 * D6);
        vm.prank(bob);
        pool.borrow(10_000 * D6);

        uint256 aggregateBefore = pool.totalBorrowed();
        _fund(alice, 10_000 * D6);
        vm.prank(alice);
        pool.repay(4_000 * D6);

        assertEq(
            pool.totalBorrowed(),
            aggregateBefore - 4_000 * D6,
            "aggregate must fall by the full repaid amount"
        );
        assertEq(pool.getBorrowed(alice), 6_000 * D6, "borrower leg unchanged in behaviour");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DPSC-517 — the pool must never be a transfer party
    //
    // totalSupply() == balanceOf(address(this)), so _deposited[address(this)] is the
    // supply accumulator. _accumulateDepositInterest mints into _deposited[user] and
    // then refreshes _deposited[address(this)] from the index — two different slots for
    // a real depositor, ONE slot when user == address(this), applying the growth factor
    // twice and minting supply that nothing backs. transferFrom(address(pool), x, 0)
    // reached it with no approval, no capital and no role.
    // ══════════════════════════════════════════════════════════════════════════

    error TransferFromPoolAddress();

    /// @dev Puts the pool in the state the attack needs: real deposits, live borrowing,
    ///      and index growth accrued since the pool's own checkpoint.
    function _poolWithAccruedInterest() internal {
        _fund(alice, 100_000 * D6);
        vm.prank(alice);
        pool.deposit(100_000 * D6);

        vm.prank(bob);
        pool.borrow(50_000 * D6);

        vm.warp(block.timestamp + 30 days);
    }

    function test_dpsc517_transferFromPoolAddressReverts() public {
        _poolWithAccruedInterest();

        // No approval is set and none is needed for amount 0 — the sender guard is what
        // must reject this.
        vm.prank(carol);
        vm.expectRevert(TransferFromPoolAddress.selector);
        pool.transferFrom(address(pool), carol, 0);
    }

    function test_dpsc517_totalSupplyUnchangedByAttack() public {
        _poolWithAccruedInterest();

        uint256 supplyBefore = pool.totalSupply();
        uint256 aliceBefore  = pool.balanceOf(alice);

        // Ten attempts, spaced out so index growth accrues between them — each one would
        // have squared the growth factor into the accumulator.
        for (uint256 i; i < 10; ++i) {
            vm.warp(block.timestamp + 7 days);
            vm.prank(carol);
            vm.expectRevert(TransferFromPoolAddress.selector);
            pool.transferFrom(address(pool), carol, 0);
        }

        // Supply still tracks real deposits: it grew only by the interest alice earned.
        uint256 supplyGrowth = pool.totalSupply() - supplyBefore;
        uint256 aliceGrowth  = pool.balanceOf(alice) - aliceBefore;
        assertApproxEqAbs(supplyGrowth, aliceGrowth, 10, "supply must track real depositor growth");
        assertGe(pool.balanceOf(alice), pool.totalSupply() - 10, "no phantom supply beyond real balances");
    }

    function test_dpsc517_nonZeroTransferFromPoolWasAlreadyImpossible() public {
        // Pins the argument that the guard rejects nothing that ever worked: the pool
        // never calls approve on itself, so a non-zero transferFrom from the pool already
        // failed the allowance check. It now fails on the sender guard instead — either
        // way it reverts, and no legitimate flow is affected.
        _poolWithAccruedInterest();

        vm.prank(carol);
        vm.expectRevert();
        pool.transferFrom(address(pool), carol, 1);

        assertEq(pool.allowance(address(pool), carol), 0, "pool never grants an allowance");
    }

    function test_dpsc517_ordinaryTransferFromStillWorks() public {
        _poolWithAccruedInterest();

        vm.prank(alice);
        pool.approve(bob, 1_000 * D6);

        uint256 carolBefore = pool.balanceOf(carol);
        vm.prank(bob);
        pool.transferFrom(alice, carol, 1_000 * D6);

        assertEq(pool.balanceOf(carol) - carolBefore, 1_000 * D6, "normal transferFrom unaffected");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // DPSC-517 (audit INFO-01 / LOW-01) — the accrual helper itself refuses the pool
    //
    // The shipped DPSC-517 tests assert the entry-point guard; they cannot observe the
    // D -> D*g -> D*g^2 arithmetic, because with the guard in place the attack never runs.
    // These two pin the invariant at the layer where the defect lived, so they survive a
    // future refactor of the transfer guards.
    // ══════════════════════════════════════════════════════════════════════════

    function test_dpsc517_helperRefusesPoolAddress() public {
        PoolAccrualHarness harness = _deployHarness();

        // A real depositor accrues normally.
        usdc.mint(alice, 10_000 * D6);
        vm.prank(alice);
        usdc.approve(address(harness), type(uint256).max);
        vm.prank(alice);
        harness.deposit(10_000 * D6);
        vm.warp(block.timestamp + 30 days);
        harness.exposedAccumulateDepositInterest(alice); // must not revert

        // The pool itself is refused, so the double-write can no longer be reached at all.
        vm.expectRevert("Cannot accrue interest for the pool itself");
        harness.exposedAccumulateDepositInterest(address(harness));
    }

    function test_dpsc517_supplyTracksRealBalancesAcrossAccrual() public {
        PoolAccrualHarness harness = _deployHarness();

        address[3] memory depositors = [alice, bob, carol];
        for (uint256 i; i < depositors.length; ++i) {
            usdc.mint(depositors[i], 50_000 * D6);
            vm.prank(depositors[i]);
            usdc.approve(address(harness), type(uint256).max);
            vm.prank(depositors[i]);
            harness.deposit(50_000 * D6);
        }
        vm.prank(dave);
        harness.borrow(75_000 * D6);

        // Repeated accrual over time must never mint supply beyond what depositors hold.
        for (uint256 round; round < 6; ++round) {
            vm.warp(block.timestamp + 20 days);
            for (uint256 i; i < depositors.length; ++i) {
                harness.exposedAccumulateDepositInterest(depositors[i]);
            }

            uint256 sumOfBalances;
            for (uint256 i; i < depositors.length; ++i) {
                sumOfBalances += harness.balanceOf(depositors[i]);
            }
            // Rounding may leave supply a few wei under the sum; it must never exceed it.
            assertLe(harness.totalSupply(), sumOfBalances + 10, "no phantom supply");
            assertGe(harness.totalSupply() + 10, sumOfBalances, "supply must track real balances");
        }
    }

    function _deployHarness() internal returns (PoolAccrualHarness harness) {
        harness = new PoolAccrualHarness();
        LinearIndex dIdx = new LinearIndex();
        LinearIndex bIdx = new LinearIndex();
        dIdx.initialize(address(harness));
        bIdx.initialize(address(harness));
        harness.initialize(
            IRatesCalculator(address(ratesCalc)),
            IBorrowersRegistry(address(registry)),
            IIndex(address(dIdx)),
            IIndex(address(bIdx)),
            payable(address(usdc)),
            IPoolRewarder(address(0)),
            0
        );
    }
}

/// @dev Exposes the internal accrual helper so the DPSC-517 invariant can be tested at the
///      layer where the defect lived, independently of the transferFrom entry-point guard.
contract PoolAccrualHarness is Pool {
    function exposedAccumulateDepositInterest(address user) external {
        _accumulateDepositInterest(user);
    }
}
