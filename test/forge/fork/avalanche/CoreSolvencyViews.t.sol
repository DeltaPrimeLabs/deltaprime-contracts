// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER (no ffi, no special EVM version). Live-diamond fork mode. Gated on
// RUN_GMX_FORK=true + avalanche chain config (inherited from the GMX fixture);
// SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js avalanche >/dev/null && \
//     RUN_GMX_FORK=true forge test --match-path \
//     'test/forge/fork/avalanche/CoreSolvencyViews.t.sol' -vvv
// =============================================================================

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";
import {SolvencyFacetProd} from "../../../../contracts/facets/SolvencyFacetProd.sol";
import {DiamondLoupeFacet} from "../../../../contracts/facets/DiamondLoupeFacet.sol";
import "forge-std/console2.sol";

/// @dev The OLD 4-array CachedPrices shape the stale Avalanche solvency-view remnant (0x636557Cf…)
///      was deployed with — BEFORE the current source grew a 5th `tjv2TokenPrices` array. The stale
///      `getHealthRatioWithPrices`/`isSolventWithPrices` selectors (0x360398a3 / 0xc3abc376) are
///      computed over THIS 4-array tuple, which is why the current-source 5-array selectors are NOT
///      registered on the live beacon. Element type is the current `SolvencyFacetProd.AssetPrice`
///      (ABI-identical `(bytes32,uint256)`), so the canonical selectors match the recon literals.
struct OldCachedPrices {
    SolvencyFacetProd.AssetPrice[] ownedAssetsPrices;
    SolvencyFacetProd.AssetPrice[] debtAssetsPrices;
    SolvencyFacetProd.AssetPrice[] stakedPositionsPrices;
    SolvencyFacetProd.AssetPrice[] assetsToRepayPrices;
}

interface IStaleSolvencyAvax {
    function getTotalValueWithPrices(
        SolvencyFacetProd.AssetPrice[] memory ownedAssetsPrices,
        SolvencyFacetProd.AssetPrice[] memory stakedPositionsPrices
    ) external view returns (uint256);

    function getHealthRatioWithPrices(OldCachedPrices memory cachedPrices) external view returns (uint256);

    function isSolventWithPrices(OldCachedPrices memory cachedPrices) external view returns (bool);
}

/**
 * SP6 W4 — Core solvency-VIEW no-drift, Avalanche live diamond.
 *
 * Avalanche carries a RICHER stale remnant than Arbitrum: the older SolvencyFacetProd deployment
 * (0x636557Cf…, 3 selectors) serves `getTotalValueWithPrices` (0x7a70bcce), `getHealthRatioWithPrices`
 * (0x360398a3) AND `isSolventWithPrices` (0xc3abc376), while the current core logic lives on a newer
 * deployment (0x42C6…). This test proves NONE of the three stale views drift from current:
 *
 *   - getTotalValue()   == stale getTotalValueWithPrices(owned, staked)   [raw asset value]
 *   - getHealthRatio()  == stale getHealthRatioWithPrices(oldCachedPrices) [debt-coverage weighted]
 *   - isSolvent()       == stale isSolventWithPrices(oldCachedPrices)      [solvency verdict]
 *
 * given the SAME prices (snapshotted via a wrapped getAllPricesForLiquidation). The health/solvency
 * checks are run WITH a finite USDC debt so the threshold-weighted-value & debt-coverage logic is
 * actually exercised (at zero debt both branches early-return type(uint256).max / true). A mismatch
 * on any of the three is a FINDING (e.g. the stale facet predates tiered debt coverage).
 *
 * The 4-array OldCachedPrices struct is built from the current 5-array CachedPrices by dropping the
 * tjv2TokenPrices slot (our PA holds no TraderJoe V2 positions → empty anyway).
 */
contract CoreSolvencyViewsAvalancheTest is AvalancheYieldForkFixture {
    bytes4 internal constant SEL_TOTAL_VALUE_WITH_PRICES = 0x7a70bcce;
    bytes4 internal constant SEL_HEALTH_RATIO_WITH_PRICES = 0x360398a3;
    bytes4 internal constant SEL_IS_SOLVENT_WITH_PRICES = 0xc3abc376;

    function testWithPricesNoDrift() public {
        // ---- 1) structural: the stale views are a DISTINCT (older) facet ----
        address coreFacet = DiamondLoupeFacet(BEACON).facetAddress(SolvencyFacetProd.getPrices.selector);
        address staleFacet = DiamondLoupeFacet(BEACON).facetAddress(SEL_TOTAL_VALUE_WITH_PRICES);
        console2.log("core solvency facet (etched current-source) ", coreFacet);
        console2.log("stale WithPrices facet                      ", staleFacet);
        assertTrue(staleFacet != address(0), "stale getTotalValueWithPrices selector not registered");
        assertTrue(staleFacet != coreFacet, "WithPrices not served by a distinct (stale) facet");
        // health/solvent stale selectors should share the same stale facet
        assertEq(
            DiamondLoupeFacet(BEACON).facetAddress(SEL_HEALTH_RATIO_WITH_PRICES),
            staleFacet,
            "stale getHealthRatioWithPrices on an unexpected facet"
        );
        assertEq(
            DiamondLoupeFacet(BEACON).facetAddress(SEL_IS_SOLVENT_WITH_PRICES),
            staleFacet,
            "stale isSolventWithPrices on an unexpected facet"
        );

        // ---- 2) zero-debt baseline: total value (single AVAX collateral) ----
        _assertTotalValueNoDrift("zero-debt");

        // ---- 3) with-debt: borrow USDC, then check ALL THREE stale views vs current ----
        (bool ok,) = _borrowRaw(SYM_USDC, 10e6); // 10 USDC against ~$150 AVAX collateral
        require(ok, "fixture: USDC borrow failed");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not owned after borrow");

        _assertTotalValueNoDrift("with-debt");
        _assertHealthAndSolvencyNoDrift();
    }

    function _assertTotalValueNoDrift(string memory phase) internal {
        SolvencyFacetProd.CachedPrices memory cp = _cachedPrices();
        uint256 currentTotal = abi.decode(
            _wrappedView(abi.encodeWithSelector(SolvencyFacetProd.getTotalValue.selector)),
            (uint256)
        );
        uint256 staleTotal =
            IStaleSolvencyAvax(loan).getTotalValueWithPrices(cp.ownedAssetsPrices, cp.stakedPositionsPrices);
        console2.log(phase);
        console2.log("  current getTotalValue()          ", currentTotal);
        console2.log("  stale  getTotalValueWithPrices() ", staleTotal);
        assertGt(currentTotal, 0, "current total value is zero (collateral not priced)");
        assertEq(staleTotal, currentTotal, "DRIFT: stale getTotalValueWithPrices != current getTotalValue");
    }

    function _assertHealthAndSolvencyNoDrift() internal {
        SolvencyFacetProd.CachedPrices memory cp = _cachedPrices();
        OldCachedPrices memory old = OldCachedPrices({
            ownedAssetsPrices: cp.ownedAssetsPrices,
            debtAssetsPrices: cp.debtAssetsPrices,
            stakedPositionsPrices: cp.stakedPositionsPrices,
            assetsToRepayPrices: cp.assetsToRepayPrices
        });

        uint256 currentHR = abi.decode(
            _wrappedView(abi.encodeWithSelector(SolvencyFacetProd.getHealthRatio.selector)),
            (uint256)
        );
        uint256 staleHR = IStaleSolvencyAvax(loan).getHealthRatioWithPrices(old);

        bool currentSolvent = abi.decode(
            _wrappedView(abi.encodeWithSelector(SolvencyFacetProd.isSolvent.selector)),
            (bool)
        );
        bool staleSolvent = IStaleSolvencyAvax(loan).isSolventWithPrices(old);

        console2.log("with-debt health/solvency");
        console2.log("  current getHealthRatio()          ", currentHR);
        console2.log("  stale  getHealthRatioWithPrices() ", staleHR);
        console2.log("  current isSolvent()               ", currentSolvent);
        console2.log("  stale  isSolventWithPrices()      ", staleSolvent);

        // finite debt → health ratio must NOT be the zero-debt sentinel (proves the TWV/debt path ran)
        assertLt(currentHR, type(uint256).max, "expected a finite health ratio (USDC debt not registered)");
        assertEq(staleHR, currentHR, "DRIFT: stale getHealthRatioWithPrices != current getHealthRatio");
        assertEq(staleSolvent, currentSolvent, "DRIFT: stale isSolventWithPrices != current isSolvent");
    }

    function _cachedPrices() internal returns (SolvencyFacetProd.CachedPrices memory cp) {
        bytes memory ret = _wrappedView(
            abi.encodeWithSelector(SolvencyFacetProd.getAllPricesForLiquidation.selector, new bytes32[](0))
        );
        cp = abi.decode(ret, (SolvencyFacetProd.CachedPrices));
    }

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
