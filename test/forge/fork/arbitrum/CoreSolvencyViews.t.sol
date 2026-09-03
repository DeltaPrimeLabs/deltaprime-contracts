// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER (no ffi, no special EVM version). Live-diamond fork mode. Gated on
// RUN_GMX_FORK=true + arbitrum chain config (inherited from the GMX fixture);
// SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js arbitrum >/dev/null && \
//     RUN_GMX_FORK=true forge test --match-path \
//     'test/forge/fork/arbitrum/CoreSolvencyViews.t.sol' -vvv
// =============================================================================

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {SolvencyFacetProd} from "../../../../contracts/facets/SolvencyFacetProd.sol";
import {DiamondLoupeFacet} from "../../../../contracts/facets/DiamondLoupeFacet.sol";
import "forge-std/console2.sol";

/// @dev The STALE solvency-view remnant on the live Arbitrum beacon serves a SINGLE selector —
///      `getTotalValueWithPrices(AssetPrice[],AssetPrice[])` (0x7a70bcce) — from an OLDER
///      SolvencyFacetProd deployment (0x79f2…) than the current core solvency logic (0x2a43…).
///      Note the signature is the OLD 2-array shape (owned + staked), not the current source's
///      `getTotalAssetsValueWithPrices(AssetPrice[])`. We reference it via a local interface using
///      the current `SolvencyFacetProd.AssetPrice` element type — the ABI canonical form is
///      `(bytes32,uint256)[]` either way, so the computed selector still equals 0x7a70bcce.
interface IStaleSolvencyArb {
    function getTotalValueWithPrices(
        SolvencyFacetProd.AssetPrice[] memory ownedAssetsPrices,
        SolvencyFacetProd.AssetPrice[] memory stakedPositionsPrices
    ) external view returns (uint256);
}

/**
 * SP6 W4 — Core solvency-VIEW no-drift, Arbitrum live diamond.
 *
 * The live Arbitrum beacon is a partial-upgrade remnant: the `*WithPrices` solvency view family is
 * served by an OLDER SolvencyFacetProd deployment than the rest of solvency (recon:
 * docs/forge/both-chain-facet-inventory.md headline #4). This test proves the stale remnant does
 * NOT behaviorally DRIFT from the current core logic: given the SAME prices, the stale
 * `getTotalValueWithPrices` must return the same USD total value as the current `getTotalValue()`.
 *
 * Method:
 *   1. structurally confirm the stale `getTotalValueWithPrices` selector resolves to a facet that is
 *      DISTINCT from the facet serving the rest of solvency (i.e. it really is the stale remnant);
 *   2. snapshot the exact prices the current path uses via a wrapped `getAllPricesForLiquidation`
 *      (the canonical CachedPrices builder, served by the etched current-source test facet);
 *   3. compare current `getTotalValue()` (wrapped, builds its own CachedPrices from the SAME signed
 *      payload) against the stale `getTotalValueWithPrices(owned, staked)` fed that snapshot —
 *      once at the funded state (single ETH collateral, zero debt) and once after borrowing USDC
 *      (two owned assets + finite debt). Equality on BOTH = no drift; a mismatch is a FINDING.
 *
 * getTotalValue is the RAW summed asset value (price × balance, no debt coverage), so it is the
 * version-stable view to pin: a drift here would mean the stale facet computes asset value
 * differently (decimals / native handling) than current — a real correctness gap. (The
 * debt-coverage-weighted health/solvency `*WithPrices` selectors are NOT on the Arbitrum stale
 * facet — only on Avalanche's — so those drift checks live in the Avalanche counterpart.)
 */
contract CoreSolvencyViewsArbitrumTest is ArbitrumYieldForkFixture {
    // OLD 2-array getTotalValueWithPrices(owned, staked) — confirmed against the recon inventory.
    bytes4 internal constant SEL_TOTAL_VALUE_WITH_PRICES = 0x7a70bcce;

    function testWithPricesNoDrift() public {
        // ---- 1) structural: the stale view is a DISTINCT (older) facet ----
        address coreFacet = DiamondLoupeFacet(BEACON).facetAddress(SolvencyFacetProd.getPrices.selector);
        address staleFacet = DiamondLoupeFacet(BEACON).facetAddress(SEL_TOTAL_VALUE_WITH_PRICES);
        console2.log("core solvency facet (etched current-source) ", coreFacet);
        console2.log("stale getTotalValueWithPrices facet         ", staleFacet);
        assertTrue(staleFacet != address(0), "stale getTotalValueWithPrices selector not registered");
        assertTrue(staleFacet != coreFacet, "WithPrices not served by a distinct (stale) facet");

        // ---- 2) zero-debt baseline: single ETH collateral ----
        _assertTotalValueNoDrift("zero-debt");

        // ---- 3) with-debt: borrow USDC so owned spans two assets + a finite debt exists ----
        (bool ok,) = _borrowRaw(SYM_USDC, 10e6); // 10 USDC against ~$1000 ETH collateral
        require(ok, "fixture: USDC borrow failed");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not owned after borrow");
        _assertTotalValueNoDrift("with-debt");
    }

    /// @dev Snapshot the current-path prices, then assert current getTotalValue() == stale
    ///      getTotalValueWithPrices(owned, staked) at the SAME prices.
    function _assertTotalValueNoDrift(string memory phase) internal {
        SolvencyFacetProd.CachedPrices memory cp = _cachedPrices();

        uint256 currentTotal = abi.decode(
            _wrappedView(abi.encodeWithSelector(SolvencyFacetProd.getTotalValue.selector)),
            (uint256)
        );
        uint256 staleTotal =
            IStaleSolvencyArb(loan).getTotalValueWithPrices(cp.ownedAssetsPrices, cp.stakedPositionsPrices);

        console2.log(phase);
        console2.log("  current getTotalValue()           ", currentTotal);
        console2.log("  stale  getTotalValueWithPrices()  ", staleTotal);
        assertGt(currentTotal, 0, "current total value is zero (collateral not priced)");
        assertEq(staleTotal, currentTotal, "DRIFT: stale getTotalValueWithPrices != current getTotalValue");
    }

    /// @dev Wrapped `getAllPricesForLiquidation([])` (served by the etched current-source facet,
    ///      validates the test signers) → the exact CachedPrices the current view path uses.
    function _cachedPrices() internal returns (SolvencyFacetProd.CachedPrices memory cp) {
        bytes memory ret = _wrappedView(
            abi.encodeWithSelector(SolvencyFacetProd.getAllPricesForLiquidation.selector, new bytes32[](0))
        );
        cp = abi.decode(ret, (SolvencyFacetProd.CachedPrices));
    }

    /// @dev Wrap a view selector with the solvency feed-set payload, fire it, bubble any revert,
    ///      return the raw returndata.
    function _wrappedView(bytes memory callData) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = _wrapSolvent(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
