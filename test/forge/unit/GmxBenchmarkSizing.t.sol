// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DiamondStorageLib} from "../../../contracts/lib/DiamondStorageLib.sol";
import {GmxV2FeesHelper} from "../../../contracts/lib/GmxV2FeesHelper.sol";
import {TestERC20} from "../helpers/TestERC20.sol";

/**
 * @dev Exposes the internal first-benchmark sizing so it can be tested without a live GM
 *      market. `_addToBenchmarkFromFunding` only touches diamond storage and the market
 *      token's balanceOf, so a bare harness reaches it faithfully.
 */
contract BenchmarkSizingHarness is GmxV2FeesHelper {
    function addFromFunding(address gmMarket, GmxPositionDetails memory d, uint256 fundedGmAmount) external {
        _addToBenchmarkFromFunding(gmMarket, d, fundedGmAmount);
    }
    function read(address gmMarket) external view returns (DiamondStorageLib.GmxPositionBenchmark memory) {
        return DiamondStorageLib.getGmxPositionBenchmark(gmMarket);
    }
}

/**
 * @title  GmxBenchmarkSizingTest
 * @notice The first benchmark written for a GM market is a cost basis, and it must cover the
 *         WHOLE position rather than only the amount that came through fund(). GM market tokens
 *         are ordinary ERC20s, so a position can arrive by direct transfer, which creates no
 *         benchmark. Sizing the basis from the funded amount alone leaves that balance
 *         untracked, and `_calculateFeeData` — which compares the live balance against the
 *         recorded underlying — then reads it as appreciation and charges the 10% performance
 *         fee on principal.
 */
contract GmxBenchmarkSizingTest is Test {
    BenchmarkSizingHarness internal h;
    TestERC20 internal gm;
    TestERC20 internal longToken;
    TestERC20 internal shortToken;

    uint256 constant GM_PRICE = 2e8; // $2.00, 8-decimal oracle format

    function setUp() public {
        h = new BenchmarkSizingHarness();
        gm = new TestERC20("GM Market", "GM", 18);
        longToken = new TestERC20("Wrapped ETH", "WETH", 18);
        shortToken = new TestERC20("USD Coin", "USDC", 6);
        vm.warp(1_750_000_000);
    }

    function _details(uint256 longAmt, uint256 shortAmt)
        internal view returns (GmxV2FeesHelper.GmxPositionDetails memory d)
    {
        d = GmxV2FeesHelper.GmxPositionDetails({
            underlyingLongTokenAmount: longAmt,
            underlyingShortTokenAmount: shortAmt,
            gmTokenPriceUsd: GM_PRICE,
            longTokenPriceUsd: 3_000e8,
            shortTokenPriceUsd: 1e8,
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: address(longToken),
            shortTokenAddress: address(shortToken)
        });
    }

    /// Ordinary case: the funded amount IS the whole position, so nothing is scaled.
    function test_firstBenchmarkMatchesFundedAmountWhenNothingUntracked() public {
        gm.mint(address(h), 100e18);
        h.addFromFunding(address(gm), _details(1e18, 200e6), 100e18);

        DiamondStorageLib.GmxPositionBenchmark memory b = h.read(address(gm));
        assertTrue(b.exists, "benchmark must exist");
        assertEq(b.benchmarkValueUsd, 100e18 * GM_PRICE / 1e8, "basis covers the funded amount");
        assertEq(b.underlyingLongTokenAmount, 1e18, "long leg unscaled");
        assertEq(b.underlyingShortTokenAmount, 200e6, "short leg unscaled");
    }

    /// The case the fix exists for: 300 GM arrived by direct transfer before a 100 GM fund().
    /// The basis must cover all 400, with the legs scaled by the same 4x, or the untracked 300
    /// would read as pure gain.
    function test_firstBenchmarkCoversUntrackedBalance() public {
        gm.mint(address(h), 400e18);          // 300 untracked + 100 funded
        h.addFromFunding(address(gm), _details(1e18, 200e6), 100e18);

        DiamondStorageLib.GmxPositionBenchmark memory b = h.read(address(gm));
        assertEq(b.benchmarkValueUsd, 400e18 * GM_PRICE / 1e8, "basis must cover the whole position");
        assertEq(b.underlyingLongTokenAmount, 4e18, "long leg scaled 4x");
        assertEq(b.underlyingShortTokenAmount, 800e6, "short leg scaled 4x");

        // The invariant that matters: no part of the balance reads as appreciation.
        uint256 positionValueUsd = gm.balanceOf(address(h)) * GM_PRICE / 1e8;
        assertEq(b.benchmarkValueUsd, positionValueUsd, "zero phantom performance at creation");
    }

    /// A zero-amount fund must not write a zero-cost-basis benchmark over a real position —
    /// that would be the same defect in its most extreme form, since the fee math reads the
    /// underlying legs and zero legs make the whole holding look like appreciation.
    function test_zeroFundedAmountDoesNotCreateAZeroBasisOverARealPosition() public {
        gm.mint(address(h), 500e18);          // entirely untracked
        h.addFromFunding(address(gm), _details(0, 0), 0);

        DiamondStorageLib.GmxPositionBenchmark memory b = h.read(address(gm));
        assertFalse(b.exists, "a zero fund must not write a benchmark at all");

        // Leaving it absent is the safe state: _sweepFees early-returns on !exists, so the
        // untracked position cannot be read as appreciation. A zero-legged benchmark would be
        // the opposite — _calculateFeeData derives the basis from the legs, so zero legs make
        // the entire holding look like gain.
    }

    /// Subsequent funds add their own delta on top of the existing basis.
    function test_secondFundAddsItsDeltaToTheExistingBasis() public {
        gm.mint(address(h), 100e18);
        h.addFromFunding(address(gm), _details(1e18, 200e6), 100e18);

        gm.mint(address(h), 50e18);
        h.addFromFunding(address(gm), _details(0.5e18, 100e6), 50e18);

        DiamondStorageLib.GmxPositionBenchmark memory b = h.read(address(gm));
        assertEq(b.benchmarkValueUsd, 150e18 * GM_PRICE / 1e8, "basis is cumulative");
        assertEq(b.underlyingLongTokenAmount, 1.5e18, "long legs accumulate");
        assertEq(b.underlyingShortTokenAmount, 300e6, "short legs accumulate");
    }
}
