// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

// ══════════════════════════════════════════════════════════════════════════════
// Handler
// ══════════════════════════════════════════════════════════════════════════════

/**
 * @title  PoolHandler
 * @notice Bounded-action handler for Pool invariant testing.
 *
 *         Five actors (alice..eve) deposit, borrow, repay, and transfer pool
 *         tokens.  accrueTime() warps time ≤30 d per call.  Every action is
 *         wrapped in snapshotIndexes() which records the deposit / borrow index
 *         values *before* the action; the invariant suite then verifies they
 *         never decrease *after* the action.
 *
 *         Ghost variables exposed as public state so the invariant contract can
 *         read them without delegatecall.
 */
contract PoolHandler is Test {
    // ─── fixture ──────────────────────────────────────────────────────────────
    Pool        public pool;
    TestERC20   public usdc;
    LinearIndex public depositIdx;
    LinearIndex public borrowIdx;

    // ─── actors ───────────────────────────────────────────────────────────────
    address[5] public actors;

    // ─── ghost vars ───────────────────────────────────────────────────────────
    /// @dev Deposit index captured at the START of the last handler call.
    uint256 public ghost_prevDepositIdx = 1e18;
    /// @dev Borrow index captured at the START of the last handler call.
    uint256 public ghost_prevBorrowIdx  = 1e18;
    /// @dev Cumulative principal deposited (pre-interest).
    uint256 public ghost_sumDeposited;
    /// @dev Cumulative principal borrowed (pre-interest).
    uint256 public ghost_sumBorrowed;

    // ─── bounds ───────────────────────────────────────────────────────────────
    /// Max deposit per call: 1 million USDC (1e12 raw 6-dec units).
    uint256 constant MAX_DEPOSIT = 1e12;
    /// Max time warp per accrueTime() call.
    uint256 constant MAX_WARP    = 30 days;

    constructor(
        Pool _pool,
        TestERC20 _usdc,
        LinearIndex _depositIdx,
        LinearIndex _borrowIdx
    ) {
        pool       = _pool;
        usdc       = _usdc;
        depositIdx = _depositIdx;
        borrowIdx  = _borrowIdx;

        actors[0] = makeAddr("h_alice");
        actors[1] = makeAddr("h_bob");
        actors[2] = makeAddr("h_carol");
        actors[3] = makeAddr("h_dave");
        actors[4] = makeAddr("h_eve");
    }

    // ─── helpers ──────────────────────────────────────────────────────────────

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, 4)];
    }

    /**
     * @dev Capture index values BEFORE each action so invariant_indexesMonotonic
     *      can compare them with the values AFTER the action.
     */
    modifier snapshotIndexes() {
        ghost_prevDepositIdx = depositIdx.getIndex();
        ghost_prevBorrowIdx  = borrowIdx.getIndex();
        _;
    }

    // ─── actions ──────────────────────────────────────────────────────────────

    function deposit(uint256 actorSeed, uint256 amt) external snapshotIndexes {
        address actor = _actor(actorSeed);
        amt = bound(amt, 1, MAX_DEPOSIT);

        usdc.mint(actor, amt);
        vm.startPrank(actor);
        usdc.approve(address(pool), amt);
        pool.deposit(amt);
        vm.stopPrank();

        ghost_sumDeposited += amt;
    }

    function borrow(uint256 actorSeed, uint256 amt) external snapshotIndexes {
        address actor = _actor(actorSeed);

        uint256 ts = pool.totalSupply();
        if (ts == 0) return;

        uint256 tb      = pool.totalBorrowed();
        uint256 maxUtil = pool.getMaxPoolUtilisationForBorrowing(); // 0.925e18

        // Compute headroom to the 92.5 % utilisation ceiling.
        uint256 ceiling = ts * maxUtil / 1e18;
        if (ceiling <= tb) return;
        uint256 maxByUtil = ceiling - tb;

        // Also bounded by cash in the pool.
        uint256 cash = usdc.balanceOf(address(pool));
        uint256 maxBorrowable = maxByUtil < cash ? maxByUtil : cash;

        // Leave 1 unit headroom to avoid triggering the exact-boundary revert.
        if (maxBorrowable <= 1) return;
        maxBorrowable -= 1;

        amt = bound(amt, 1, maxBorrowable);

        vm.prank(actor);
        // try/catch absorbs rare off-by-one reverts at the utilisation boundary.
        try pool.borrow(amt) {
            ghost_sumBorrowed += amt;
        } catch { /* MaxPoolUtilisationBreached or InsufficientPoolFunds — skip */ }
    }

    function repay(uint256 actorSeed) external snapshotIndexes {
        address actor = _actor(actorSeed);
        uint256 owed = pool.getBorrowed(actor);
        if (owed == 0) return;

        // Mint the exact interest-adjusted owed amount so repay succeeds.
        usdc.mint(actor, owed);
        vm.startPrank(actor);
        usdc.approve(address(pool), owed);
        pool.repay(owed);
        vm.stopPrank();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amt)
        external
        snapshotIndexes
    {
        address from = _actor(fromSeed);
        address to   = _actor(bound(toSeed, 0, 4));
        if (from == to) return;

        uint256 bal = pool.balanceOf(from);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);

        vm.prank(from);
        // Locked-balance or withdrawal-intent conflicts cause reverts; skip.
        try pool.transfer(to, amt) {} catch {}
    }

    /// @dev Warp forward by [1, 30 days].  Does NOT trigger any pool interaction,
    ///      so interest accrues "in the air" until the next action.
    function accrueTime(uint256 secs) external snapshotIndexes {
        secs = bound(secs, 1, MAX_WARP);
        vm.warp(block.timestamp + secs);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Invariant test contract
// ══════════════════════════════════════════════════════════════════════════════

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 32
contract PoolInvariantTest is Test {
    Pool        internal pool;
    TestERC20   internal usdc;
    LinearIndex internal depositIdx;
    LinearIndex internal borrowIdx;
    PoolHandler internal handler;

    function setUp() public {
        vm.warp(1_750_000_000);

        usdc      = new TestERC20("USD Coin", "USDC", 6);
        pool      = new Pool();
        depositIdx = new LinearIndex();
        borrowIdx  = new LinearIndex();

        // LinearIndex.initialize(owner): owner is the pool — it's the only one
        // allowed to call setRate / updateUser (onlyOwner).
        depositIdx.initialize(address(pool));
        borrowIdx.initialize(address(pool));

        pool.initialize(
            IRatesCalculator(address(new WavaxVariableUtilisationRatesCalculator())),
            IBorrowersRegistry(address(new OpenBorrowersRegistry())),
            IIndex(address(depositIdx)),
            IIndex(address(borrowIdx)),
            payable(address(usdc)),
            IPoolRewarder(address(0)),
            0 // totalSupplyCap = 0 → uncapped
        );

        handler = new PoolHandler(pool, usdc, depositIdx, borrowIdx);
        targetContract(address(handler));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant 1 — totalBorrowed <= totalSupply
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Outstanding loans never exceed total deposits (including accrued interest).
     *
     * Proof sketch (linear rates):
     *   Let S = totalSupply_0, B = totalBorrowed_0, util = B/S.
     *   Interest accrued over dt:
     *     dBorrow  = B * r_b * dt
     *     dSupply  = S * r_d * dt = S * (B/S) * r_b * dt = B * r_b * dt
     *   Both sides grow by the same amount, so the gap S − B is preserved.
     *   Since the 92.5 % utilisation cap enforces B ≤ 0.925 * S at any borrow,
     *   totalBorrowed ≤ totalSupply always holds.
     *
     *   Tolerance: +1 wei covers truncation from index integer division.
     */
    function invariant_borrowedNeverExceedsDeposits() public {
        uint256 tb = pool.totalBorrowed();
        uint256 ts = pool.totalSupply();
        assertLe(tb, ts + 1, "INV1: totalBorrowed > totalSupply (+1 epsilon)");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant 2 — pool solvency: cash + loans >= totalSupply
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pool always holds enough cash + outstanding loans to cover all deposits.
     *
     * At any moment: token balance of pool + totalBorrowed >= totalSupply.
     *
     * Derivation:
     *   cash = total deposited_raw − total borrowed_raw  (ERC20 movements)
     *   totalSupply = deposited_raw * depositIndexFactor
     *   totalBorrowed = borrowed_raw * borrowIndexFactor
     *
     *   cash + totalBorrowed
     *     = (deposited_raw − borrowed_raw) + borrowed_raw * borrowIndexFactor
     *     = deposited_raw + borrowed_raw * (borrowIndexFactor − 1)
     *
     *   totalSupply = deposited_raw * depositIndexFactor
     *     = deposited_raw * (1 + r_d * t)
     *
     *   At 50 % util, r_d = 0.5 * r_b, so:
     *     cash + totalBorrowed = deposited_raw + borrowed_raw * r_b * t
     *                          = deposited_raw * (1 + util * r_b * t)
     *                          = totalSupply   (equality, up to spread ≈ 0)
     *
     *   For util < 1 the surplus from the tiny spread only grows; inequality holds.
     *   Tolerance: +5 wei for multi-party index-division rounding.
     */
    function invariant_solvencyOfPool() public {
        uint256 cash = IERC20(pool.tokenAddress()).balanceOf(address(pool));
        uint256 tb   = pool.totalBorrowed();
        uint256 ts   = pool.totalSupply();
        assertGe(cash + tb + 5, ts, "INV2: cash + totalBorrowed < totalSupply (insolvency)");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant 3 — deposit and borrow indexes are monotonically non-decreasing
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Neither the deposit index nor the borrow index ever decreases.
     *
     * The handler's snapshotIndexes modifier saves both index values BEFORE each
     * action (into ghost_prevDepositIdx / ghost_prevBorrowIdx).  Foundry calls
     * the invariant functions AFTER the action returns, so comparing the current
     * index with the ghost verifies that the action itself did not decrease it.
     *
     * Why this holds:
     *   LinearIndex.setRate() calls updateIndex() first, which snapshots
     *   current getIndex() into the stored `index`.  Then getIndex() == index
     *   at dt=0, so the floor immediately after setRate equals the old ceiling.
     *   Time can only increase getIndex() further (rate >= 0).
     */
    function invariant_indexesMonotonic() public {
        assertGe(
            depositIdx.getIndex(),
            handler.ghost_prevDepositIdx(),
            "INV3: deposit index decreased"
        );
        assertGe(
            borrowIdx.getIndex(),
            handler.ghost_prevBorrowIdx(),
            "INV3: borrow index decreased"
        );
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Invariant 4 — sum of actor balances <= totalSupply + actor_count * 5
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice The sum of all five actor pool-token balances never materially
     *         exceeds totalSupply.
     *
     * totalSupply = depositIndex.getIndexedValue(_deposited[pool], pool).
     * Each actor balance = depositIndex.getIndexedValue(_deposited[actor], actor).
     *
     * When users interact at different timestamps they get different prevIndex
     * denominators.  Integer division in getIndexedValue can make individual
     * balances round up or down by 1 wei; across 5 actors the cumulative error
     * is bounded by actorCount (5) wei.  We use 25 wei tolerance (5 actors × 5 wei).
     */
    function invariant_totalSupplyEqualsSumOfBalances() public {
        uint256 sumBal;
        for (uint i; i < 5; i++) {
            sumBal += pool.balanceOf(handler.actors(i));
        }
        uint256 ts = pool.totalSupply();
        // Sum of individual balances must not materially exceed totalSupply.
        assertLe(sumBal, ts + 25, "INV4: sum(actor balances) > totalSupply + 25 wei");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Fuzz test A — first depositor always receives 1:1 shares
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice On a fresh pool, any positive deposit amount yields exactly that
     *         many pool tokens (prevIndex == currentIndex at deposit time → 1:1).
     *
     * Behavior pin: Pool.depositOnBehalf calls _mint(of, amount) then
     *   _accumulateDepositInterest sets prevIndex[t] = getIndex() for the user.
     *   On a brand-new pool getIndex() == BASE_RATE == 1e18 throughout (no
     *   borrowing yet), so getIndexedValue(amount, user) == amount.
     */
    function testFuzz_depositAmountsConserveShares(uint96 rawAmt) public {
        uint256 amt = bound(uint256(rawAmt), 1, 1e12);

        address alice = makeAddr("fuzz_alice");
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(pool), amt);
        pool.deposit(amt);
        vm.stopPrank();

        assertEq(pool.balanceOf(alice), amt, "first deposit: shares != principal");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Fuzz test B — full repay leaves exactly zero residual debt
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice After repaying pool.getBorrowed(borrower) in full, getBorrowed == 0.
     *
     * Behavior pin: pool.repay() calls _accumulateBorrowingInterest first, which
     *   sets borrowed[msg.sender] = getBorrowed(msg.sender) and then calls
     *   borrowIndex.updateUser(msg.sender) so that getBorrowed() now returns the
     *   same raw value.  Repaying that exact value zeroes borrowed[msg.sender],
     *   and getBorrowed(msg.sender) returns 0 with no 1-wei dust.
     */
    function testFuzz_borrowRepayLeavesNoResidualDebt(uint96 rawAmt) public {
        // Seed liquidity.
        address lender  = makeAddr("fuzz_lender");
        uint256 liquidity = 500_000 * 1e6; // 500 k USDC
        usdc.mint(lender, liquidity);
        vm.startPrank(lender);
        usdc.approve(address(pool), liquidity);
        pool.deposit(liquidity);
        vm.stopPrank();

        // Borrow at most 90 % of pool to stay clear of the 92.5 % cap.
        uint256 maxBorrow = liquidity * 90 / 100;
        uint256 amt = bound(uint256(rawAmt), 1, maxBorrow);

        address bob = makeAddr("fuzz_bob");
        vm.prank(bob);
        pool.borrow(amt);

        // Warp up to 365 days to accrue interest.
        uint256 warpSecs = bound(uint256(rawAmt), 0, 365 days);
        vm.warp(block.timestamp + warpSecs);

        uint256 owed = pool.getBorrowed(bob);
        assertGt(owed, 0, "sanity: owed > 0 after borrow");

        usdc.mint(bob, owed); // cover accrued interest
        vm.startPrank(bob);
        usdc.approve(address(pool), owed);
        pool.repay(owed);
        vm.stopPrank();

        assertEq(pool.getBorrowed(bob), 0, "residual debt after full repay (expected 0)");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Fuzz test C — deposit-rate gain <= borrow-rate cost (spread invariant)
    // ──────────────────────────────────────────────────────────────────────────

    /**
     * @notice Over any time period, depositors collectively earn no more interest
     *         than borrowers pay.
     *
     * At 50 % utilisation: r_d = r_b × 0.5 × (1 − spread ≈ 0).
     * Depositor gain = depositAmt × r_d × t.
     * Borrower interest = borrowAmt × r_b × t = 0.5×depositAmt × r_b × t.
     * With r_d = 0.5 × r_b: depositor gain == borrower interest (within 1 wei rounding).
     */
    function testFuzz_depositorsNeverEarnMoreThanBorrowersPay(uint24 warpSecs) public {
        uint256 depositAmt  = 100_000 * 1e6;
        uint256 borrowAmt   =  50_000 * 1e6; // 50 % utilisation

        address lender   = makeAddr("fuzz_spread_lender");
        address borrower = makeAddr("fuzz_spread_borrower");

        usdc.mint(lender, depositAmt);
        vm.startPrank(lender);
        usdc.approve(address(pool), depositAmt);
        pool.deposit(depositAmt);
        vm.stopPrank();

        vm.prank(borrower);
        pool.borrow(borrowAmt);

        vm.warp(block.timestamp + uint256(warpSecs));

        uint256 depositorGain    = pool.balanceOf(lender) - depositAmt;
        uint256 borrowerInterest = pool.getBorrowed(borrower) - borrowAmt;

        // Spread invariant: depositor gain <= borrower interest + 1 wei rounding.
        assertLe(
            depositorGain,
            borrowerInterest + 1,
            "depositor gained more than borrower paid"
        );
    }
}
