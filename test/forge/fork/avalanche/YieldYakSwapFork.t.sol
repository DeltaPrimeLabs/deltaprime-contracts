// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The single YieldYakSwapFacet swap entrypoint exercised here (live 0x7b90769a on the
///      Avalanche beacon). `yakSwap(amountIn, minOut, path, adapters)` routes through the live
///      YakRouter via `swapNoSplit`.
interface IYieldYakSwapFacet {
    function yakSwap(
        uint256 _amountIn,
        uint256 _amountOut,
        address[] calldata _path,
        address[] calldata _adapters
    ) external;
}

/// @dev Minimal view of the live YakRouter (`0xC4729E56…488c`) used to BUILD the on-chain swap
///      route at fork time. `findBestPath` returns a FormattedOffer whose `path` + `adapters` are
///      exactly the arrays `yakSwap` consumes — and every adapter it returns is, by construction,
///      one of the router's whitelisted adapters (which the facet re-checks via
///      `isWhitelistedAdapterOptimized`). Querying it on-fork keeps the route robust to liquidity
///      drift (no hardcoded adapter/path that can rot).
interface IYakRouterView {
    struct FormattedOffer {
        uint256[] amounts;
        address[] adapters;
        address[] path;
    }

    function findBestPath(
        uint256 _amountIn,
        address _tokenIn,
        address _tokenOut,
        uint256 _maxSteps
    ) external view returns (FormattedOffer memory);
}

/**
 * SP6 W5 — YieldYakSwap (YakRouter aggregated swap) live-diamond fork e2e (Avalanche). Gated —
 * SKIPS under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * First-ever fork coverage of the YieldYakSwapFacet against the live YakRouter
 * (`0xC4729E56b831d74bBc18797e0e17A295fA77488c`). The route (path + adapters) is BUILT on-fork by
 * querying `YakRouter.findBestPath(amountIn, WAVAX, USDC, maxSteps)` — the same getter the
 * off-chain UI uses — so the test exercises the real aggregator routing rather than a hand-pinned
 * adapter. The funded WAVAX collateral (held as "AVAX") is swapped to USDC; both are ACTIVE +
 * RedStone-priced pool assets on the live TokenManager.
 *
 * `yakSwap` is `remainsSolvent`-gated (the swap mutates owned-asset composition — USDC is added via
 * `_syncExposure`), so it is wrapped with a test-signer RedStone payload carrying the owned ∪ pool
 * feed set (AVAX + USDC both present as pool assets).
 *
 * Load-bearing post-state (never bare no-revert):
 *   - the account's WAVAX ("AVAX") free balance dropped by EXACTLY the swapped amountIn;
 *   - the account received USDC (≥ the route-derived min-out, strictly > 0);
 *   - USDC is now a tracked owned asset (the facet's post-swap `_syncExposure` ran).
 */
contract YieldYakSwapForkTest is AvalancheYieldForkFixture {
    address internal constant YAK_ROUTER = 0xC4729E56b831d74bBc18797e0e17A295fA77488c;

    // Swap 1 WAVAX of the 5 the fixture funds → leaves ~4 WAVAX collateral so the post-swap
    // solvency check passes comfortably with zero debt.
    uint256 internal constant SWAP_IN = 1 ether;

    function testYakSwapWavaxToUsdcMovesBalances() public {
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(loan);
        assertEq(wavaxBefore, FUND_AMOUNT, "fixture WAVAX collateral missing");
        assertEq(IERC20(USDC).balanceOf(loan), 0, "unexpected pre-existing USDC");
        assertFalse(_ownsAsset(SYM_USDC), "USDC unexpectedly already an owned asset");

        // ---- build the route on-fork from the live aggregator ----
        IYakRouterView.FormattedOffer memory offer =
            IYakRouterView(YAK_ROUTER).findBestPath(SWAP_IN, WAVAX, USDC, 3);
        require(offer.path.length >= 2, "no route found WAVAX->USDC");
        require(offer.adapters.length >= 1, "route has no adapters");
        require(offer.path[0] == WAVAX, "route does not start at WAVAX");
        require(offer.path[offer.path.length - 1] == USDC, "route does not end at USDC");

        uint256 quotedOut = offer.amounts[offer.amounts.length - 1];
        require(quotedOut > 0, "router quoted zero output");
        // 5% headroom vs the same-block quote (no real slippage on a fork, but the facet enforces
        // boughtAmount >= minOut and the router enforces trade.amountOut, so keep a margin).
        uint256 minOut = (quotedOut * 95) / 100;

        // ---- execute the wrapped, solvency-gated swap ----
        _wrapSolventExpectSuccess(
            abi.encodeWithSelector(
                IYieldYakSwapFacet.yakSwap.selector, SWAP_IN, minOut, offer.path, offer.adapters
            )
        );

        // ---- load-bearing post-state ----
        uint256 wavaxAfter = IERC20(WAVAX).balanceOf(loan);
        uint256 usdcAfter = IERC20(USDC).balanceOf(loan);

        assertEq(wavaxAfter, wavaxBefore - SWAP_IN, "WAVAX not spent by exactly amountIn");
        assertGt(usdcAfter, 0, "swap produced no USDC");
        assertGe(usdcAfter, minOut, "USDC received below route min-out");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not registered as an owned asset after swap");
    }
}
