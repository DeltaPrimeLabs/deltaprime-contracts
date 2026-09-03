// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER. Live-diamond fork mode. Gated on RUN_GMX_FORK=true + avalanche chain
// config (inherited from the GMX fixture); SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js avalanche >/dev/null && \
//     RUN_GMX_FORK=true forge test --match-path \
//     'test/forge/fork/avalanche/Liquidation.t.sol' -vvv
// =============================================================================

import {AvalancheGmxForkFixture} from "../../fixtures/AvalancheGmxForkFixture.sol";
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
 * SP-liq fork — full liquidation against the REAL deployed Avalanche diamond.
 *
 * This is the highest-fidelity liquidation proof: the actual on-chain liquidation
 * facet (not a fixture-cut copy) drives the seizure, using the live TokenManager,
 * pools, WAVAX and the production STABILITY_POOL / treasury. The local e2e suite
 * (test/forge/e2e/Liquidation.t.sol) covers the exhaustive guard matrix against a
 * fixture diamond; this confirms the end-to-end flow holds on the deployed bytecode.
 *
 * Flow:
 *   1. Account is funded with 5 WAVAX (≈ $150 at the $30 test price) in setUp.
 *   2. Borrow 50 USDC against it (solvent at $30).
 *   3. Whitelist a fresh test liquidator by pranking the live beacon owner.
 *   4. snapshotInsolvency at a crashed $3 AVAX price (HR ≪ 1) — forged via our
 *      5 test signers (the signer-override solvency facet is cut in setUp).
 *   5. liquidate(false) at the crash price → debt cleared from the account's own
 *      USDC, liquidation bonus distributed in WAVAX to the production STABILITY_POOL.
 */
contract LiquidationAvalancheForkTest is AvalancheGmxForkFixture {
    uint256 internal constant CRASH_AVAX_8 = 3e8; // $3 — guarantees HR < 1 for this position
    // 500 USDC against 5 WAVAX (~$150 at $30): HR ≈ 1.08 at $30 (borrow succeeds), ≈ 0.86 at $3
    // (insolvent). A smaller borrow stays solvent on the crash because the borrowed USDC itself
    // is stable collateral — the position must be leveraged enough that an AVAX crash tips it under.
    uint256 internal constant BORROW_USDC = 500e6;

    // Mirror of PrimeAccountModifiers.OnlyWhitelistedLiquidators (same name+args ⇒ same selector).
    error OnlyWhitelistedLiquidators();

    address internal forkLiquidator;

    /// @dev Build the RedStone feed set a liquidation solvency read requests:
    ///      getAllPoolAssets() ∪ {AVAX}, with AVAX at `avaxP8`, USDC at $1, the rest nominal.
    ///      Every requested symbol needs ≥3 signers or RedStone reverts; only AVAX/USDC affect
    ///      the math here (the account owns AVAX + the borrowed USDC).
    function _liqFeedSet(uint256 avaxP8)
        internal
        view
        returns (bytes32[] memory feeds, uint256[] memory vals)
    {
        bytes32[] memory pool = ITokenManagerPoolAssetsLiq(TOKEN_MANAGER).getAllPoolAssets();
        bool hasAvax;
        for (uint256 i; i < pool.length; i++) {
            if (pool[i] == SYM_AVAX) hasAvax = true;
        }
        uint256 n = pool.length + (hasAvax ? 0 : 1);
        feeds = new bytes32[](n);
        vals = new uint256[](n);
        for (uint256 i; i < pool.length; i++) {
            feeds[i] = pool[i];
            if (pool[i] == SYM_AVAX) vals[i] = avaxP8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8;
        }
        if (!hasAvax) {
            feeds[pool.length] = SYM_AVAX;
            vals[pool.length] = avaxP8;
        }
    }

    /// @dev Append a forged RedStone payload to `callData` and call the loan as `caller`.
    function _wrapAs(address caller, bytes memory callData, uint256 avaxP8)
        internal
        returns (bool ok, bytes memory ret)
    {
        (bytes32[] memory feeds, uint256[] memory vals) = _liqFeedSet(avaxP8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        vm.prank(caller);
        (ok, ret) = loan.call(bytes.concat(callData, payload));
    }

    function _whitelistForkLiquidator() internal returns (address liq) {
        liq = makeAddr("forkLiquidatorAvax");
        address[] memory liqs = new address[](1);
        liqs[0] = liq;
        (address owner_,) = _beaconAdmins();
        vm.prank(owner_);
        ISmartLoanLiquidationFacet(BEACON).whitelistLiquidators(liqs);
    }

    function testForkFullLiquidationClearsDebtAndDistributesFee() public {
        // 2) borrow 50 USDC against the funded 5 WAVAX (solvent at $30).
        (bool okBorrow,) = _borrowRaw(SYM_USDC, BORROW_USDC);
        require(okBorrow, "fork: USDC borrow failed");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not owned after borrow");

        // 3) whitelist a fresh liquidator via the live beacon owner.
        forkLiquidator = _whitelistForkLiquidator();

        // 4) snapshot insolvency at the crashed $3 AVAX price.
        (bool okSnap, bytes memory snapRet) = _wrapAs(
            forkLiquidator,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.snapshotInsolvency.selector),
            CRASH_AVAX_8
        );
        require(okSnap, string.concat("fork: snapshotInsolvency reverted: ", _revertReason(snapRet)));
        assertGt(
            ISmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(),
            0,
            "fork: snapshot not recorded"
        );

        uint256 stabilityBefore = IERC20(WAVAX).balanceOf(DeploymentChainConfig.STABILITY_POOL);

        // 5) liquidate at the crash price.
        (bool okLiq, bytes memory liqRet) = _wrapAs(
            forkLiquidator,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.liquidate.selector, false),
            CRASH_AVAX_8
        );
        require(okLiq, string.concat("fork: liquidate reverted: ", _revertReason(liqRet)));

        // Debt fully repaid from the account's own USDC.
        (bool okDebt, bytes memory debtRet) =
            _wrapAs(forkLiquidator, abi.encodeWithSelector(SolvencyFacetProd.getDebt.selector), CRASH_AVAX_8);
        require(okDebt, "fork: getDebt read failed");
        assertEq(abi.decode(debtRet, (uint256)), 0, "fork: debt not fully repaid");

        // Snapshot cleared.
        assertEq(
            ISmartLoanLiquidationFacet(loan).getLastInsolventTimestamp(),
            0,
            "fork: snapshot not cleared after liquidate"
        );

        // Liquidation bonus distributed in WAVAX to the production stability pool.
        uint256 stabilityAfter = IERC20(WAVAX).balanceOf(DeploymentChainConfig.STABILITY_POOL);
        console2.log("stability pool WAVAX gained", stabilityAfter - stabilityBefore);
        assertGt(stabilityAfter, stabilityBefore, "fork: stability pool received no WAVAX bonus");
    }

    function testForkNonWhitelistedCannotSnapshot() public {
        (bool okBorrow,) = _borrowRaw(SYM_USDC, BORROW_USDC);
        require(okBorrow, "fork: USDC borrow failed");

        address rando = makeAddr("forkRandoAvax");
        (bool ok, bytes memory ret) = _wrapAs(
            rando,
            abi.encodeWithSelector(ISmartLoanLiquidationFacet.snapshotInsolvency.selector),
            CRASH_AVAX_8
        );
        assertFalse(ok, "fork: non-whitelisted address must not snapshot insolvency");
        // onlyWhitelistedLiquidators is the outermost modifier ⇒ it fires before any solvency check.
        assertTrue(
            ret.length >= 4 && bytes4(ret) == OnlyWhitelistedLiquidators.selector,
            "fork: expected OnlyWhitelistedLiquidators"
        );
    }
}
