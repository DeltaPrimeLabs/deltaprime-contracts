// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {GmxBenchmarkMath} from "../../../contracts/lib/GmxBenchmarkMath.sol";
import {TestERC20} from "../helpers/TestERC20.sol";

/**
 * @title  GmxBenchmarkMathTest
 * @notice Pins the precondition behind DPSC-539.
 *
 *         `premiumScaledUnderlying` derives a ratio as
 *         `totalGmWorth / totalUnderlyingWorth`, and `totalUnderlyingWorth` is built
 *         entirely from the supplied long/short prices. A zero price struct therefore
 *         makes the denominator zero and the call reverts with Panic(0x12).
 *
 *         `AssetsOperationsFacet.fund()` used to populate `gmxTokenPrices` only inside
 *         `if (benchmark.exists)` while calling
 *         `_createOrUpdateBenchmarkIfGmOrGlvToken` unconditionally, so the first fund()
 *         of a GM market token into an account with no benchmark reached exactly this
 *         division and reverted — the collateral never arrived. The facet now fetches
 *         prices for any whitelisted GM/GLV token; this suite pins WHY that matters.
 */
contract GmxBenchmarkMathTest is Test {
    TestERC20 internal market;
    TestERC20 internal longToken;
    TestERC20 internal shortToken;

    address internal holder = address(0xBEEF);

    // 8-decimal oracle format, as used throughout the GMX fee helpers.
    uint256 constant GM_PRICE    = 1e8;      // $1.00
    uint256 constant LONG_PRICE  = 3_000e8;  // $3 000 (ETH-like)
    uint256 constant SHORT_PRICE = 1e8;      // $1 (USDC-like)

    function setUp() public {
        market     = new TestERC20("GM Market", "GM",   18);
        longToken  = new TestERC20("Wrapped ETH", "WETH", 18);
        shortToken = new TestERC20("USD Coin",   "USDC",  6);

        // A market backed by 100 WETH + 300 000 USDC, 600 000 GM in circulation.
        market.mint(holder, 600_000e18);
        longToken.mint(address(market), 100e18);
        shortToken.mint(address(market), 300_000e6);
    }

    /// A zero price struct — what fund() used to pass on a first-time GM deposit —
    /// divides by zero rather than producing a degenerate result.
    function test_dpsc539_zeroPricesRevertWithDivisionByZero() public {
        vm.expectRevert(stdError.divisionError);
        GmxBenchmarkMath.premiumScaledUnderlying(
            address(market),
            1_000e18,
            address(longToken),
            address(shortToken),
            0, // gmTokenPrice
            0, // longTokenPrice
            0, // shortTokenPrice
            false
        );
    }

    /// A partially-zero struct is just as fatal: only the long/short legs build the
    /// denominator, so a non-zero GM price does not save it.
    function test_dpsc539_zeroUnderlyingPricesRevertEvenWithGmPrice() public {
        vm.expectRevert(stdError.divisionError);
        GmxBenchmarkMath.premiumScaledUnderlying(
            address(market), 1_000e18, address(longToken), address(shortToken),
            GM_PRICE, 0, 0, false
        );
    }

    /// With real prices the call returns a split whose value matches the GM value —
    /// the invariant the benchmark relies on.
    function test_dpsc539_realPricesProduceValueMatchedSplit() public {
        (uint256 longAmt, uint256 shortAmt) = GmxBenchmarkMath.premiumScaledUnderlying(
            address(market), 1_000e18, address(longToken), address(shortToken),
            GM_PRICE, LONG_PRICE, SHORT_PRICE, false
        );

        assertGt(longAmt, 0, "long leg must be non-zero");
        assertGt(shortAmt, 0, "short leg must be non-zero");

        // longAmt * longPrice + shortAmt * shortPrice ~= gmAmount * gmPrice (18-dec USD)
        uint256 underlyingUsd =
            (longAmt * LONG_PRICE / 1e8) * 1e18 / 1e18 +
            (shortAmt * SHORT_PRICE / 1e8) * 1e18 / 1e6;
        uint256 gmUsd = 1_000e18 * GM_PRICE / 1e8;

        assertApproxEqRel(underlyingUsd, gmUsd, 1e15, "split must carry the GM value (0.1%)");
    }

    /// Plus-markets zero the short leg by construction; the long price alone must then
    /// carry the denominator.
    function test_dpsc539_plusMarketUsesLongLegOnly() public {
        (uint256 longAmt, uint256 shortAmt) = GmxBenchmarkMath.premiumScaledUnderlying(
            address(market), 1_000e18, address(longToken), address(shortToken),
            GM_PRICE, LONG_PRICE, SHORT_PRICE, true
        );

        assertEq(shortAmt, 0, "plus market has no short leg");
        assertGt(longAmt, 0, "long leg must still be priced");
    }
}
