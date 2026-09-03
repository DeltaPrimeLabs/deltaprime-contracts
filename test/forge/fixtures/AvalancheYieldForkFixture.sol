// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheGmxForkFixture} from "./AvalancheGmxForkFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {IStakingPositions} from "../../../contracts/interfaces/IStakingPositions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoolAssetsView {
    function getAllPoolAssets() external view returns (bytes32[] memory);
}

/**
 * @title AvalancheYieldForkFixture
 * @notice Shared base for the SP6 W7 Avalanche yield-adapter fork tests (YieldYak / sJoe /
 *         Wombat). Extends {AvalancheGmxForkFixture} — it reuses the live-diamond attach, the
 *         signer-override solvency cut, the funded Prime Account, and the RedStone wrap helpers —
 *         and layers on the pieces every staking flow needs:
 *
 *   - {_solvencyFeedSet}: the RedStone feed set a `remainsSolvent`-gated staking call must carry.
 *     A stake mutates the account's owned-asset composition (a new STAKED POSITION is added,
 *     valued via the facet's `balanceSelector`), and `remainsSolvent` runs AFTER the body, so the
 *     post-stake solvency read requests prices for `getOwnedAssetsWithNative() ∪ getAllPoolAssets()
 *     ∪ <staked-position symbols>`. The set is built dynamically from live state and UNION-ed with
 *     the candidate staked symbols the W7 yield facets add (JOE, sAVAX/ggAVAX, the four Wombat LPs)
 *     so a wrapped staking call never reverts InsufficientNumberOfUniqueSigners on a missing feed.
 *     All Avalanche W7 staked symbols are RedStone-priced (getChainlinkFeed == 0, verified on-fork),
 *     so they MUST appear in the payload. Extra feeds are harmless (the consumer only extracts the
 *     symbols it actually requests).
 *   - {_wrapSolvent}: append a test-signer RedStone payload (the feed set above) to a facet call and
 *     fire it as `user`, returning the raw (ok, ret) without bubbling.
 *   - {_fundToken}: `deal` an input token to `user` and `fund()` it into the Prime Account.
 *   - {_hasStakedIdentifier} / {_stakedCount}: read the live staked-position list for post-state proof.
 *
 * Gated/skip behaviour is inherited verbatim from {AvalancheGmxForkFixture} (RUN_GMX_FORK=true +
 * avalanche chain config); under the default test config these SKIP.
 */
abstract contract AvalancheYieldForkFixture is AvalancheGmxForkFixture {
    // Candidate staked-position symbols the W7 yield facets add. JOE (sJoe), sAVAX/ggAVAX (Wombat
    // single-asset legs) and the four Wombat LP identifiers. All registered + RedStone-priced on the
    // live Avalanche TokenManager (verified on-fork). Included unconditionally so the solvency feed
    // set is a superset of whatever the post-stake read requests.
    function _candidateStakedSymbols() internal pure returns (bytes32[] memory s) {
        s = new bytes32[](7);
        s[0] = bytes32("JOE");
        s[1] = bytes32("sAVAX");
        s[2] = bytes32("ggAVAX");
        s[3] = bytes32("WOMBAT_sAVAX_AVAX_LP_AVAX");
        s[4] = bytes32("WOMBAT_sAVAX_AVAX_LP_sAVAX");
        s[5] = bytes32("WOMBAT_ggAVAX_AVAX_LP_AVAX");
        s[6] = bytes32("WOMBAT_ggAVAX_AVAX_LP_ggAVAX");
    }

    /// @notice Build the deduplicated RedStone feed set + nominal prices a wrapped staking call needs:
    ///         owned-with-native ∪ pool assets ∪ candidate staked symbols. With zero debt any valid
    ///         price keeps the account solvent, so AVAX/USDC get the fixture's deterministic test
    ///         prices and every other symbol a nominal $1 (8-dec) — enough to validate the payload.
    function _solvencyFeedSet() internal view returns (bytes32[] memory feeds, uint256[] memory vals) {
        // getAllOwnedAssets (a registered SmartLoanViewFacet selector) instead of the solvency
        // facet's getOwnedAssetsWithNative (NOT registered on the beacon — calling it externally
        // reverts "Diamond: Function does not exist"); AVAX (the native enrichment getPrices adds)
        // is added explicitly so the post-stake solvency read never misses the native feed.
        bytes32[] memory owned = SmartLoanViewFacet(loan).getAllOwnedAssets();
        bytes32[] memory pool = IPoolAssetsView(TOKEN_MANAGER).getAllPoolAssets();
        bytes32[] memory extra = _candidateStakedSymbols();

        bytes32[] memory native = new bytes32[](1);
        native[0] = SYM_AVAX;

        bytes32[] memory tmp = new bytes32[](owned.length + pool.length + extra.length + 1);
        uint256 n;
        n = _appendUnique(tmp, n, native);
        n = _appendUnique(tmp, n, owned);
        n = _appendUnique(tmp, n, pool);
        n = _appendUnique(tmp, n, extra);

        feeds = new bytes32[](n);
        vals = new uint256[](n);
        for (uint256 i; i < n; i++) {
            feeds[i] = tmp[i];
            if (tmp[i] == SYM_AVAX) vals[i] = AVAX_PRICE_8;
            else if (tmp[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8; // nominal $1; zero debt keeps any valid price solvent
        }
    }

    function _appendUnique(bytes32[] memory dst, uint256 count, bytes32[] memory src)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < src.length; i++) {
            bool seen;
            for (uint256 j; j < count; j++) {
                if (dst[j] == src[i]) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                dst[count] = src[i];
                count++;
            }
        }
        return count;
    }

    /// @notice Append a test-signer RedStone payload (the solvency feed set) to `callData` and call
    ///         the Prime Account as `user`. Returns raw (ok, ret) — caller asserts.
    function _wrapSolvent(bytes memory callData) internal returns (bool ok, bytes memory ret) {
        (bytes32[] memory feeds, uint256[] memory vals) = _solvencyFeedSet();
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        vm.prank(user);
        (ok, ret) = loan.call(bytes.concat(callData, payload));
    }

    /// @notice {_wrapSolvent} that bubbles the inner revert on failure (for happy paths).
    function _wrapSolventExpectSuccess(bytes memory callData) internal {
        (bool ok, bytes memory ret) = _wrapSolvent(callData);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    /// @notice `deal` `token` to `user` and `fund()` it into the Prime Account as `symbol`.
    function _fundToken(bytes32 symbol, address token, uint256 amount) internal {
        deal(token, user, amount);
        require(IERC20(token).balanceOf(user) >= amount, "fixture: token deal failed");
        vm.startPrank(user);
        IERC20(token).approve(loan, amount);
        AssetsOperationsFacet(loan).fund(symbol, amount);
        vm.stopPrank();
    }

    function _stakedPositions() internal view returns (IStakingPositions.StakedPosition[] memory) {
        return SmartLoanViewFacet(loan).getStakedPositions();
    }

    function _hasStakedIdentifier(bytes32 identifier) internal view returns (bool) {
        IStakingPositions.StakedPosition[] memory ps = _stakedPositions();
        for (uint256 i; i < ps.length; i++) {
            if (ps[i].identifier == identifier) return true;
        }
        return false;
    }
}
