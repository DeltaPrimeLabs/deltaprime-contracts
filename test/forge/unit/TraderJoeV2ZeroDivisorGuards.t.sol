// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {PriceHelper} from "../../../contracts/lib/joe-v2/PriceHelper.sol";
import {Uint256x256Math} from "../../../contracts/lib/joe-v2/math/Uint256x256Math.sol";

/**
 * @title TraderJoeV2ZeroDivisorGuardsTest
 * @notice Deterministic tier coverage for the two divisors guarded in
 *         SolvencyFacetProd._getTotalTraderJoeV2 and HealthMeterFacetProd._getTotalTraderJoeV2Weighted.
 *         The fork suite covers the same states end-to-end but is gated on RUN_GMX_FORK, so it does
 *         not run in CI. This pins the real (id, binStep) -> zero-price boundary from the library
 *         itself (no fork, no mock) and the arithmetic shape of both guards.
 */
contract TraderJoeV2ZeroDivisorGuardsTest is Test {
    using Uint256x256Math for uint256;

    /// @dev First id whose 128.128 price survives the round-DOWN conversion to 18 decimals.
    ///      Every id below it prices to exactly zero. Measured, not assumed - the binary search
    ///      below re-derives it, so a change in PriceHelper fails this file loudly.
    uint24 internal constant FIRST_NONZERO_ID_BINSTEP_10 = 8_347_141;
    uint24 internal constant FIRST_NONZERO_ID_BINSTEP_25 = 8_372_009;

    function _decimalPrice(uint24 id, uint16 binStep) internal pure returns (uint256) {
        return PriceHelper.convert128x128PriceToDecimal(PriceHelper.getPriceFromId(id, binStep));
    }

    /// @dev External wrapper so a reverting `getPriceFromId` can be caught during the search.
    function decimalPrice(uint24 id, uint16 binStep) external pure returns (uint256) {
        return _decimalPrice(id, binStep);
    }

    function _firstNonZeroId(uint16 binStep) internal view returns (uint24) {
        uint24 lo = 1;
        uint24 hi = 8_388_607;
        while (lo < hi) {
            uint24 mid = lo + (hi - lo) / 2;
            uint256 price;
            try this.decimalPrice(mid, binStep) returns (uint256 v) { price = v; } catch { price = 0; }
            if (price == 0) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    // ── the zero-price band is real, and where the library says it is ─────────────────────────

    function testZeroPriceBandBoundaryBinStep10() public {
        assertEq(_firstNonZeroId(10), FIRST_NONZERO_ID_BINSTEP_10, "zero-price boundary moved");
        assertEq(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_10 - 1, 10), 0, "bin below the boundary must price to zero");
        assertGt(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_10, 10), 0, "boundary bin must price above zero");
    }

    function testZeroPriceBandBoundaryBinStep25() public {
        assertEq(_firstNonZeroId(25), FIRST_NONZERO_ID_BINSTEP_25, "zero-price boundary moved");
        assertEq(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_25 - 1, 25), 0, "bin below the boundary must price to zero");
        assertGt(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_25, 25), 0, "boundary bin must price above zero");
    }

    /// @dev The band is wide and mintable, not a single edge id.
    function testZeroPriceBandIsWide() public {
        assertEq(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_10 - 1, 10), 0);
        assertEq(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_10 - 10_000, 10), 0);
        assertEq(_decimalPrice(FIRST_NONZERO_ID_BINSTEP_10 - 47_300, 10), 0);
    }

    // ── divisor 1: price ──────────────────────────────────────────────────────────────────────

    function divideByPrice(uint256 liquidity, uint256 price) external pure returns (uint256) {
        return 1e18 * liquidity / price;
    }

    function testTokenXLegPanicsOnZeroPrice() public {
        vm.expectRevert(stdError.divisionError);
        this.divideByPrice(1e18, 0);
    }

    /// @dev What the guard does instead: a zero-priced bin contributes nothing.
    function testZeroPricedBinIsSkipped() public {
        uint256 price = _decimalPrice(FIRST_NONZERO_ID_BINSTEP_10 - 1, 10);
        uint256 total;
        if (price == 0) {
            // `continue` in the facet loop
        } else {
            total = this.divideByPrice(1e18, price);
        }
        assertEq(total, 0, "a zero-priced bin must add nothing, not revert");
    }

    // ── divisor 2: bin total supply ───────────────────────────────────────────────────────────

    function shareUnguarded(uint256 legValue, uint256 balance, uint256 supply) external pure returns (uint256) {
        return legValue.mulDivRoundDown(balance, 1e18).mulDivRoundDown(1e18, supply);
    }

    function _shareGuarded(uint256 legValue, uint256 balance, uint256 supply) internal pure returns (uint256) {
        return legValue.mulDivRoundDown(balance, 1e18).mulDivRoundDown(1e18, Math.max(supply, 1));
    }

    function testEmptyBinPanicsWithoutTheGuard() public {
        vm.expectRevert(stdError.divisionError);
        this.shareUnguarded(1_000e18, 0, 0);
    }

    function testEmptyBinContributesZeroWithTheGuard() public {
        assertEq(_shareGuarded(1_000e18, 0, 0), 0, "an empty bin must add nothing, not revert");
    }

    /// @dev The guard must be a pure no-op for every bin anybody actually holds.
    function testFuzz_guardIsNoOpForNonEmptyBins(uint128 legValue, uint128 balance, uint128 supply) public {
        vm.assume(supply > 0);
        vm.assume(balance <= supply);
        assertEq(
            _shareGuarded(legValue, balance, supply),
            this.shareUnguarded(legValue, balance, supply),
            "Math.max(_, 1) changed a healthy bin's valuation"
        );
    }
}
