// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";

/// @dev The two YieldYakFacetArbi selectors (live @0xF5b4a277 on the Arbitrum beacon).
interface IYieldYakFacetArbi {
    function stakeGLPYak(uint256 amount) external;
    function unstakeGLPYak(uint256 amount) external;
}

/**
 * SP6 W8 — YieldYakFacetArbi adapter SUNSET verdict (Arbitrum live-diamond fork). Gated — SKIPS
 * under the default test config (RUN_GMX_FORK=true + arbitrum chain config required).
 *
 * The live YieldYakFacetArbi (`0xF5b4a277…`, 2 selectors) exposes exactly ONE vault: `YY_WOMBEX_GLP`
 * (`0x28f37fa1…b6ac`), the YieldYak wrapper around GMX **V1** staked-GLP (`GLP 0x5402B5F4…Cffdf`).
 * GMX V1 is sunset on Arbitrum, and both `GLP` and `YY_WOMBEX_GLP` have been DELISTED from the live
 * TokenManager (verified on-fork: `tokenToStatus == 0`, no symbol mapping) — so the staking position
 * is no longer enterable through a Prime Account:
 *   - funding GLP is impossible: `getAssetAddress('GLP'/'YY_WOMBEX_GLP')` reverts `Asset not supported.`;
 *   - `stakeGLPYak` reverts before any external interaction (its `_getAvailableBalance('GLP')`
 *     resolves the GLP address through the (now empty) TokenManager mapping and reverts
 *     `Asset not supported.`).
 *
 * There is no other vault in the facet to substitute, so per the W7/W8 ground rules this protocol is
 * documented as SUNSET rather than faked — exactly mirroring the Avalanche YieldYakFacet verdict.
 * This test PROVES the sunset precondition on-fork (the assertions are load-bearing on live
 * TokenManager state) instead of merely skipping — if GLP is ever re-listed the asserts flip and
 * this file fails loudly, prompting a real stake→unstake e2e.
 */
contract YieldYakForkTest is ArbitrumYieldForkFixture {
    address internal constant GLP = 0x5402B5F40310bDED796c7D0F3FF6683f5C0cFfdf;
    address internal constant YY_WOMBEX_GLP = 0x28f37fa106AA2159c91C769f7AE415952D28b6ac;

    function testYieldYakGlpVaultIsSunset() public {
        // 1) Both the deposit token and the vault token are delisted from the live TokenManager.
        assertTrue(_assetUnsupported(bytes32("GLP")), "GLP unexpectedly still registered");
        assertTrue(_assetUnsupported(bytes32("YY_WOMBEX_GLP")), "YY_WOMBEX_GLP unexpectedly still registered");

        // 2) The facet is on the beacon but the stake entrypoint is unenterable: it reverts while
        //    resolving the GLP balance through the (now empty) TokenManager mapping. Wrapped with a
        //    solvency payload so only the genuine delisting revert can surface (not a calldata issue).
        (bool ok, bytes memory ret) =
            _wrapSolvent(abi.encodeWithSelector(IYieldYakFacetArbi.stakeGLPYak.selector, uint256(1 ether)));
        assertFalse(ok, "stakeGLPYak unexpectedly succeeded against a sunset vault");
        assertEq(_revertReason(ret), "Asset not supported.", "unexpected stakeGLPYak revert reason");
    }
}
