// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITraderJoeV2Facet} from "../../../../contracts/interfaces/facets/avalanche/ITraderJoeV2Facet.sol";
import {ILBRouter} from "../../../../contracts/interfaces/joe-v2/ILBRouter.sol";

/// @dev Minimal view of a live LB pair (it is an ILBToken) used to read the active bin id at fork
///      time and the Prime Account's per-bin LB-token balance for post-state proof.
interface ILBPairView {
    function getActiveId() external view returns (uint24);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/**
 * SP6 W6 — TraderJoe V2 Liquidity Book add/remove liquidity live-diamond fork e2e (Arbitrum).
 * Gated — SKIPS under the default test config (RUN_GMX_FORK=true + arbitrum chain config required).
 *
 * First-ever fork coverage of the TraderJoeV2ArbitrumFacet (live 0x9DB80164 on the beacon) against
 * the live WETH/USDC LB pair 0xb7236B92 (v2.2, binStep 10, whitelisted pool #13) via the v2.2
 * LBRouter 0x18556DA1 (the same deterministic-address router TraderJoe ships on every chain — its
 * factory `getLBPairInformation(WETH, USDC, 10)` resolves to exactly this whitelisted pair,
 * verified on-fork). Mirrors the proven W5 Avalanche TJ-V2 test with Arbitrum addresses. The Prime
 * Account funds both legs (WETH held as "ETH" + dealt USDC), deposits into a SINGLE bin (the live
 * active bin, read on-fork — robust to bin drift, with idSlippage maxed) and withdraws the full LB
 * position back.
 *
 * `addLiquidityTraderJoeV2` is `remainsSolvent`-gated (the new TJ-V2 bin position is valued by the
 * solvency facet via the pair's tokenX/tokenY = ETH/USDC, both pool assets) → wrapped with a
 * test-signer RedStone payload. `removeLiquidityTraderJoeV2` carries no `remainsSolvent` in the repo
 * source but the LIVE deployed facets enforce `isSolvent()` on exit (W7/W8 deployed-vs-source drift
 * finding), so the remove is wrapped too — harmless if the live facet ignores the trailing payload,
 * required if it consumes one.
 *
 * Load-bearing post-state (never bare no-revert):
 *   - after add: exactly one owned TJ-V2 bin is tracked, the PA holds a non-zero LB-token balance in
 *     that bin, and both WETH + USDC free balances dropped (real liquidity was provided);
 *   - after remove: the owned-bin list is empty, the PA's LB-token balance is zero, and both
 *     WETH + USDC free balances came back up (the underlying tokens returned).
 */
contract TraderJoeV2ForkTest is ArbitrumYieldForkFixture {
    address internal constant LB_ROUTER_V22 = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address internal constant PAIR_WETH_USDC = 0xb7236B927e03542AC3bE0A054F2bEa8868AF9508;
    uint16 internal constant BIN_STEP = 10;

    uint256 internal constant ADD_WETH = 0.1 ether; // 0.1 of the 0.5 WETH funded
    uint256 internal constant ADD_USDC = 10e6; // 10 USDC

    function testAddRemoveLiquidityWethUsdc() public {
        // Fund the USDC leg (WETH is already funded as "ETH" by the fixture).
        _fundToken(SYM_USDC, USDC, ADD_USDC);
        assertEq(IERC20(USDC).balanceOf(loan), ADD_USDC, "USDC not funded into the PA");

        uint256 wethBeforeAdd = IERC20(WETH).balanceOf(loan);
        uint256 usdcBeforeAdd = IERC20(USDC).balanceOf(loan);
        assertEq(_ownedBinsCount(), 0, "unexpected pre-existing TJ-V2 bins");

        // ---- add liquidity to the live active bin ----
        uint24 activeId = ILBPairView(PAIR_WETH_USDC).getActiveId();
        _wrapSolventExpectSuccess(
            abi.encodeWithSelector(
                ITraderJoeV2Facet.addLiquidityTraderJoeV2.selector,
                LB_ROUTER_V22,
                _singleBinParams(activeId)
            )
        );

        // Exactly one bin tracked, PA holds LB tokens in it, both legs were spent.
        assertEq(_ownedBinsCount(), 1, "add did not record exactly one TJ-V2 bin");
        ITraderJoeV2Facet.TraderJoeV2Bin[] memory bins =
            ITraderJoeV2Facet(loan).getOwnedTraderJoeV2Bins();
        uint256 binId = bins[0].id;
        assertEq(address(bins[0].pair), PAIR_WETH_USDC, "tracked bin pair mismatch");
        uint256 lbBal = ILBPairView(PAIR_WETH_USDC).balanceOf(loan, binId);
        assertGt(lbBal, 0, "no LB tokens minted to the PA");
        assertLt(IERC20(WETH).balanceOf(loan), wethBeforeAdd, "add did not spend WETH");
        assertLt(IERC20(USDC).balanceOf(loan), usdcBeforeAdd, "add did not spend USDC");

        uint256 wethAfterAdd = IERC20(WETH).balanceOf(loan);
        uint256 usdcAfterAdd = IERC20(USDC).balanceOf(loan);

        // ---- remove the full LB position back to the underlying tokens ----
        (bool ok,) = _wrapSolvent(
            abi.encodeWithSelector(
                ITraderJoeV2Facet.removeLiquidityTraderJoeV2.selector,
                LB_ROUTER_V22,
                _removeParams(binId, lbBal)
            )
        );
        assertTrue(ok, "wrapped removeLiquidity reverted");

        // The bin is fully drained + untracked, and both underlying tokens returned to the PA.
        assertEq(ILBPairView(PAIR_WETH_USDC).balanceOf(loan, binId), 0, "LB tokens not burned");
        assertEq(_ownedBinsCount(), 0, "owned-bin list not cleaned after full remove");
        assertGt(IERC20(WETH).balanceOf(loan), wethAfterAdd, "WETH not returned on remove");
        assertGt(IERC20(USDC).balanceOf(loan), usdcAfterAdd, "USDC not returned on remove");
    }

    function _ownedBinsCount() internal view returns (uint256) {
        return ITraderJoeV2Facet(loan).getOwnedTraderJoeV2Bins().length;
    }

    /// @dev Single-bin (active-bin) liquidity params: deltaIds=[0], 100% of each leg into the
    ///      active bin. idSlippage maxed so any active-bin drift between read + add is tolerated.
    function _singleBinParams(uint24 activeId)
        internal
        view
        returns (ILBRouter.LiquidityParameters memory p)
    {
        int256[] memory deltaIds = new int256[](1);
        deltaIds[0] = 0;
        uint256[] memory distX = new uint256[](1);
        distX[0] = 1e18;
        uint256[] memory distY = new uint256[](1);
        distY[0] = 1e18;

        p = ILBRouter.LiquidityParameters({
            tokenX: IERC20(WETH),
            tokenY: IERC20(USDC),
            binStep: BIN_STEP,
            amountX: ADD_WETH,
            amountY: ADD_USDC,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: activeId,
            idSlippage: 16777215, // max uint24 — accept any distance from the active bin
            deltaIds: deltaIds,
            distributionX: distX,
            distributionY: distY,
            to: loan, // overwritten to address(this) by the facet
            refundTo: loan,
            deadline: block.timestamp + 1000
        });
    }

    function _removeParams(uint256 binId, uint256 amount)
        internal
        view
        returns (ITraderJoeV2Facet.RemoveLiquidityParameters memory p)
    {
        uint256[] memory ids = new uint256[](1);
        ids[0] = binId;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        p = ITraderJoeV2Facet.RemoveLiquidityParameters({
            tokenX: IERC20(WETH),
            tokenY: IERC20(USDC),
            binStep: BIN_STEP,
            amountXMin: 0,
            amountYMin: 0,
            ids: ids,
            amounts: amounts,
            deadline: block.timestamp + 1000
        });
    }
}
