// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";
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
 * SP6 W5 — TraderJoe V2 Liquidity Book add/remove liquidity live-diamond fork e2e (Avalanche).
 * Gated — SKIPS under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * First-ever fork coverage of the TraderJoeV2AvalancheFacet (live 0x1899F6D5 on the beacon) against
 * the live WAVAX/USDC LB pair 0x864d4e5E (v2.2, binStep 10, whitelisted pool #6) via the v2.2
 * LBRouter 0x18556DA1. The Prime Account funds both legs (WAVAX held as "AVAX" + dealt USDC),
 * then deposits into a SINGLE bin (the live active bin, read on-fork — robust to bin drift, with
 * idSlippage maxed) and withdraws the full LB position back.
 *
 * `addLiquidityTraderJoeV2` is `remainsSolvent`-gated (the new TJ-V2 bin position is valued by the
 * solvency facet via the pair's tokenX/tokenY = AVAX/USDC, both pool assets) → wrapped with a
 * test-signer RedStone payload. `removeLiquidityTraderJoeV2` carries no `remainsSolvent` in the repo
 * source but the LIVE deployed facets enforce `isSolvent()` on exit (W7/W8 deployed-vs-source drift
 * finding), so the remove is wrapped too — harmless if the live facet ignores the trailing payload,
 * required if it consumes one.
 *
 * Load-bearing post-state (never bare no-revert):
 *   - after add: exactly one owned TJ-V2 bin is tracked, the PA holds a non-zero LB-token balance in
 *     that bin, and both WAVAX + USDC free balances dropped (real liquidity was provided);
 *   - after remove: the owned-bin list is empty, the PA's LB-token balance is zero, and both
 *     WAVAX + USDC free balances came back up (the underlying tokens returned).
 */
contract TraderJoeV2ForkTest is AvalancheYieldForkFixture {
    address internal constant LB_ROUTER_V22 = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address internal constant PAIR_WAVAX_USDC = 0x864d4e5Ee7318e97483DB7EB0912E09F161516EA;
    uint16 internal constant BIN_STEP = 10;

    uint256 internal constant ADD_WAVAX = 1 ether; // 1 of the 5 WAVAX funded
    uint256 internal constant ADD_USDC = 10e6; // 10 USDC

    function testAddRemoveLiquidityWavaxUsdc() public {
        // Fund the USDC leg (WAVAX is already funded as "AVAX" by the fixture).
        _fundToken(SYM_USDC, USDC, ADD_USDC);
        assertEq(IERC20(USDC).balanceOf(loan), ADD_USDC, "USDC not funded into the PA");

        uint256 wavaxBeforeAdd = IERC20(WAVAX).balanceOf(loan);
        uint256 usdcBeforeAdd = IERC20(USDC).balanceOf(loan);
        assertEq(_ownedBinsCount(), 0, "unexpected pre-existing TJ-V2 bins");

        // ---- add liquidity to the live active bin ----
        uint24 activeId = ILBPairView(PAIR_WAVAX_USDC).getActiveId();
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
        assertEq(address(bins[0].pair), PAIR_WAVAX_USDC, "tracked bin pair mismatch");
        uint256 lbBal = ILBPairView(PAIR_WAVAX_USDC).balanceOf(loan, binId);
        assertGt(lbBal, 0, "no LB tokens minted to the PA");
        assertLt(IERC20(WAVAX).balanceOf(loan), wavaxBeforeAdd, "add did not spend WAVAX");
        assertLt(IERC20(USDC).balanceOf(loan), usdcBeforeAdd, "add did not spend USDC");

        uint256 wavaxAfterAdd = IERC20(WAVAX).balanceOf(loan);
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
        assertEq(ILBPairView(PAIR_WAVAX_USDC).balanceOf(loan, binId), 0, "LB tokens not burned");
        assertEq(_ownedBinsCount(), 0, "owned-bin list not cleaned after full remove");
        assertGt(IERC20(WAVAX).balanceOf(loan), wavaxAfterAdd, "WAVAX not returned on remove");
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
            tokenX: IERC20(WAVAX),
            tokenY: IERC20(USDC),
            binStep: BIN_STEP,
            amountX: ADD_WAVAX,
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
            tokenX: IERC20(WAVAX),
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
