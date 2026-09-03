// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";

/// @dev The two YieldYakFacet selectors (live @0xF62b6263 on the Avalanche beacon).
interface IYieldYakFacet {
    function stakeGLPYak(uint256 amount) external;
    function unstakeGLPYak(uint256 amount) external;
}

/**
 * SP6 W7 — YieldYak adapter SUNSET verdict (Avalanche live-diamond fork). Gated — SKIPS under the
 * default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * The live YieldYakFacet (`0xF62b6263…`, 2 selectors) exposes exactly ONE vault: `YY_GLP`
 * (`0x9f637540…Aff5C`), the auto-compounding wrapper around GMX **V1** staked-GLP
 * (`GLP 0x9e295B5B…9660`). GMX V1 is sunset on Avalanche, and both `GLP` and `YY_GLP` have been
 * DELISTED from the live TokenManager — so the staking position is no longer enterable through a
 * Prime Account:
 *   - funding GLP is impossible: `getAssetAddress('GLP'/'YY_GLP')` reverts `Asset not supported.`;
 *   - `stakeGLPYak` reverts before any external interaction (its `_getAvailableBalance('GLP')`
 *     resolves the GLP address through the TokenManager and reverts `Asset not supported.`).
 *
 * There is no other vault in the facet to substitute, so per the W7 ground rules this protocol is
 * documented as SUNSET rather than faked. This test PROVES the sunset precondition on-fork (the
 * assertions are load-bearing on live TokenManager state) instead of merely skipping — if GLP is
 * ever re-listed the asserts flip and this file fails loudly, prompting a real stake→unstake e2e.
 */
contract YieldYakForkTest is AvalancheYieldForkFixture {
    address internal constant GLP = 0x9e295B5B976a184B14aD8cd72413aD846C299660;
    address internal constant YY_GLP = 0x9f637540149f922145c06e1aa3f38dcDc32Aff5C;

    function testYieldYakGlpVaultIsSunset() public {
        // 1) Both the deposit token and the vault token are delisted from the live TokenManager.
        assertTrue(_assetUnsupported(bytes32("GLP")), "GLP unexpectedly still registered");
        assertTrue(_assetUnsupported(bytes32("YY_GLP")), "YY_GLP unexpectedly still registered");

        // 2) The facet is on the beacon but the stake entrypoint is unenterable: it reverts while
        //    resolving the GLP balance through the (now empty) TokenManager mapping. Wrapped with a
        //    solvency payload so only the genuine delisting revert can surface (not a calldata issue).
        (bool ok, bytes memory ret) =
            _wrapSolvent(abi.encodeWithSelector(IYieldYakFacet.stakeGLPYak.selector, uint256(1 ether)));
        assertFalse(ok, "stakeGLPYak unexpectedly succeeded against a sunset vault");
        assertEq(_revertReason(ret), "Asset not supported.", "unexpected stakeGLPYak revert reason");
    }

    /// @dev True iff `getAssetAddress(symbol, true)` reverts `Asset not supported.` on the live TM.
    function _assetUnsupported(bytes32 symbol) internal view returns (bool) {
        (bool ok, bytes memory ret) = TOKEN_MANAGER.staticcall(
            abi.encodeWithSignature("getAssetAddress(bytes32,bool)", symbol, true)
        );
        if (ok) return false;
        return keccak256(bytes(_revertReason(ret))) == keccak256(bytes("Asset not supported."));
    }
}
