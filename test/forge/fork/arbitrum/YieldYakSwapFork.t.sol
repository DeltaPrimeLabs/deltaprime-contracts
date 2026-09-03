// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The single YieldYakSwapArbitrumFacet swap entrypoint exercised here (live 0xa60cD8eB on the
///      Arbitrum beacon). `yakSwap(amountIn, minOut, path, adapters)` routes through the live
///      Arbitrum YakRouter via `swapNoSplit`.
interface IYieldYakSwapFacet {
    function yakSwap(
        uint256 _amountIn,
        uint256 _amountOut,
        address[] calldata _path,
        address[] calldata _adapters
    ) external;
}

/// @dev Minimal view of the live Arbitrum YakRouter (`0xb32C79a2…3cE3`, hardcoded in
///      YieldYakSwapArbitrumFacet.YY_ROUTER) used to BUILD the on-chain swap route at fork time.
///      `findBestPath` returns a FormattedOffer whose `path` + `adapters` are exactly the arrays
///      `yakSwap` consumes — and every adapter it returns is, by construction, one of the router's
///      whitelisted adapters (which the facet re-checks via `isWhitelistedAdapterOptimized`).
///      Querying it on-fork keeps the route robust to liquidity drift (no hardcoded adapter/path
///      that can rot).
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
 * SP6 W6 — YieldYakSwap (YakRouter aggregated swap) live-diamond fork e2e (Arbitrum). Gated —
 * SKIPS under the default test config (RUN_GMX_FORK=true + arbitrum chain config required).
 *
 * First-ever fork coverage of the YieldYakSwapArbitrumFacet against the live Arbitrum YakRouter
 * (`0xb32C79a25291265eF240Eb32E9faBbc6DcEE3cE3`). Mirrors the proven W5 Avalanche YieldYakSwap test
 * with Arbitrum addresses. The route (path + adapters) is BUILT on-fork by querying
 * `YakRouter.findBestPath(amountIn, WETH, USDC, maxSteps)` — the same getter the off-chain UI uses —
 * so the test exercises the real aggregator routing rather than a hand-pinned adapter (the live
 * best route is a 2-hop WETH→USDC.e→USDC through two whitelisted adapters). The funded WETH
 * collateral (held as "ETH") is swapped to USDC; both are ACTIVE + priced pool assets on the live
 * TokenManager.
 *
 * `yakSwap` is `remainsSolvent`-gated (the swap mutates owned-asset composition — USDC is added via
 * `_syncExposure`), so it is wrapped with a test-signer RedStone payload carrying the owned ∪ pool
 * feed set (ETH + USDC both present as pool assets).
 *
 * Load-bearing post-state (never bare no-revert):
 *   - the account's WETH ("ETH") free balance dropped by EXACTLY the swapped amountIn;
 *   - the account received USDC (≥ the route-derived min-out, strictly > 0);
 *   - USDC is now a tracked owned asset (the facet's post-swap `_syncExposure` ran).
 */
contract YieldYakSwapForkTest is ArbitrumYieldForkFixture {
    address internal constant YAK_ROUTER = 0xb32C79a25291265eF240Eb32E9faBbc6DcEE3cE3;

    // Swap 0.1 WETH of the 0.5 the fixture funds → leaves ~0.4 WETH collateral so the post-swap
    // solvency check passes comfortably with zero debt.
    uint256 internal constant SWAP_IN = 0.1 ether;

    function testYakSwapWethToUsdcMovesBalances() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(loan);
        assertEq(wethBefore, FUND_AMOUNT, "fixture WETH collateral missing");
        assertEq(IERC20(USDC).balanceOf(loan), 0, "unexpected pre-existing USDC");
        assertFalse(_ownsAsset(SYM_USDC), "USDC unexpectedly already an owned asset");

        // ---- build the route on-fork from the live aggregator ----
        IYakRouterView.FormattedOffer memory offer =
            IYakRouterView(YAK_ROUTER).findBestPath(SWAP_IN, WETH, USDC, 3);
        require(offer.path.length >= 2, "no route found WETH->USDC");
        require(offer.adapters.length >= 1, "route has no adapters");
        require(offer.path[0] == WETH, "route does not start at WETH");
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
        uint256 wethAfter = IERC20(WETH).balanceOf(loan);
        uint256 usdcAfter = IERC20(USDC).balanceOf(loan);

        assertEq(wethAfter, wethBefore - SWAP_IN, "WETH not spent by exactly amountIn");
        assertGt(usdcAfter, 0, "swap produced no USDC");
        assertGe(usdcAfter, minOut, "USDC received below route min-out");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not registered as an owned asset after swap");
    }
}
