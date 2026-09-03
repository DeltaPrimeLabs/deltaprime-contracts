// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER. Live-diamond fork mode. Gated on RUN_GMX_FORK=true + arbitrum chain
// config (inherited from the GMX fixture); SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js arbitrum >/dev/null && \
//     RUN_GMX_FORK=true ARBITRUM_RPC_URL=<archive-rpc> forge test --match-path \
//     'test/forge/fork/arbitrum/Liquidation.t.sol' -vvv
// =============================================================================

import {ArbitrumGmxForkFixture} from "../../fixtures/ArbitrumGmxForkFixture.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {SolvencyFacetProd} from "../../../../contracts/facets/SolvencyFacetProd.sol";
import {ISmartLoanLiquidationFacet} from "../../../../contracts/interfaces/facets/ISmartLoanLiquidationFacet.sol";
import {DeploymentChainConfig} from "../../../../contracts/lib/DeploymentChainConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "forge-std/console2.sol";

interface ITokenManagerPoolAssetsLiq {
    function getAllPoolAssets() external view returns (bytes32[] memory);
}

/**
 * SP-liq fork — full liquidation against the REAL deployed Arbitrum diamond.
 *
 * Arbitrum counterpart of test/forge/fork/avalanche/Liquidation.t.sol. The actual
 * on-chain liquidation facet drives the seizure against the live TokenManager,
 * pools, WETH and the production STABILITY_POOL / treasury.
 *
 * Flow:
 *   1. Account is funded with 0.5 WETH (≈ $1 000 at the $2 000 test price) in setUp.
 *   2. Borrow 3 000 USDC against it (HR ≈ 1.11 at $2 000 — solvent).
 *   3. Whitelist a fresh test liquidator by pranking the live beacon owner.
 *   4. snapshotInsolvency at a crashed $200 ETH price (HR ≈ 0.86) — forged via our
 *      5 test signers (the signer-override solvency facet is cut in setUp).
 *   5. liquidate(false) → debt cleared from the account's own USDC, liquidation
 *      bonus distributed in WETH to the production STABILITY_POOL.
 */
contract LiquidationArbitrumForkTest is ArbitrumGmxForkFixture {
    uint256 internal constant CRASH_ETH_8 = 200e8; // $200 — guarantees HR < 1 for this position
    // 3 000 USDC against 0.5 WETH (~$1 000 at $2 000): HR ≈ 1.11 at $2 000 (borrow succeeds),
    // ≈ 0.86 at $200 (insolvent). Leverage high enough that an ETH crash tips it under.
    uint256 internal constant BORROW_USDC = 3_000e6;

    // Mirror of PrimeAccountModifiers.OnlyWhitelistedLiquidators (same name+args ⇒ same selector).
    error OnlyWhitelistedLiquidators();

    address internal forkLiquidator;

    /// @dev getAllPoolAssets() ∪ {ETH}, ETH at `ethP8`, USDC at $1, the rest nominal.
    function _liqFeedSet(uint256 ethP8)
        internal
        view
        returns (bytes32[] memory feeds, uint256[] memory vals)
    {
        bytes32[] memory pool = ITokenManagerPoolAssetsLiq(TOKEN_MANAGER).getAllPoolAssets();
        bool hasEth;
        for (uint256 i; i < pool.length; i++) {
            if (pool[i] == SYM_ETH) hasEth = true;
        }
        uint256 n = pool.length + (hasEth ? 0 : 1);
        feeds = new bytes32[](n);
        vals = new uint256[](n);
        for (uint256 i; i < pool.length; i++) {
            feeds[i] = pool[i];
            if (pool[i] == SYM_ETH) vals[i] = ethP8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8;
        }
        if (!hasEth) {
            feeds[pool.length] = SYM_ETH;
            vals[pool.length] = ethP8;
        }
    }

    function _wrapAs(address caller, bytes memory callData, uint256 ethP8)
        internal
        returns (bool ok, bytes memory ret)
    {
        (bytes32[] memory feeds, uint256[] memory vals) = _liqFeedSet(ethP8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        vm.prank(caller);
        (ok, ret) = loan.call(bytes.concat(callData, payload));
    }

    function _whitelistForkLiquidator() internal returns (address liq) {
        liq = makeAddr("forkLiquidatorArb");
        address[] memory liqs = new address[](1);
        liqs[0] = liq;
        (address owner_,) = _beaconAdmins();
        vm.prank(owner_);
        ISmartLoanLiquidationFacet(BEACON).whitelistLiquidators(liqs);
    }

    function testForkFullLiquidationClearsDebtAndDistributesFee() public {
        (bool okBorrow,) = _borrowRaw(SYM_USDC, BORROW_USDC);
        require(okBorrow, "fork: USDC borrow failed");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not owned after borrow");

        forkLiquidator = _whitelistForkLiquidator();

        (bool okSnap, bytes memory snapRet) = _wrapAs(
            forkLiquidator,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.snapshotInsolvency.selector),
            CRASH_ETH_8
        );
        require(okSnap, string.concat("fork: snapshotInsolvency reverted: ", _revertReason(snapRet)));
        assertGt(ISmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(), 0, "fork: snapshot not recorded");

        uint256 stabilityBefore = IERC20(WETH).balanceOf(DeploymentChainConfig.STABILITY_POOL);

        (bool okLiq, bytes memory liqRet) = _wrapAs(
            forkLiquidator,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.liquidate.selector, false),
            CRASH_ETH_8
        );
        require(okLiq, string.concat("fork: liquidate reverted: ", _revertReason(liqRet)));

        (bool okDebt, bytes memory debtRet) =
            _wrapAs(forkLiquidator, abi.encodeWithSelector(SolvencyFacetProd.getDebt.selector), CRASH_ETH_8);
        require(okDebt, "fork: getDebt read failed");
        assertEq(abi.decode(debtRet, (uint256)), 0, "fork: debt not fully repaid");

        assertEq(
            ISmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(),
            0,
            "fork: snapshot not cleared after liquidate"
        );

        uint256 stabilityAfter = IERC20(WETH).balanceOf(DeploymentChainConfig.STABILITY_POOL);
        console2.log("stability pool WETH gained", stabilityAfter - stabilityBefore);
        assertGt(stabilityAfter, stabilityBefore, "fork: stability pool received no WETH bonus");
    }

    function testForkNonWhitelistedCannotSnapshot() public {
        (bool okBorrow,) = _borrowRaw(SYM_USDC, BORROW_USDC);
        require(okBorrow, "fork: USDC borrow failed");

        address rando = makeAddr("forkRandoArb");
        (bool ok, bytes memory ret) = _wrapAs(
            rando,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.snapshotInsolvency.selector),
            CRASH_ETH_8
        );
        assertFalse(ok, "fork: non-whitelisted address must not snapshot insolvency");
        assertTrue(
            ret.length >= 4 && bytes4(ret) == OnlyWhitelistedLiquidators.selector,
            "fork: expected OnlyWhitelistedLiquidators"
        );
    }
}
