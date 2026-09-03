// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumGmxForkFixture} from "./ArbitrumGmxForkFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {GmxKeeperSim} from "../helpers/gmx/GmxKeeperSim.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {IStakingPositions} from "../../../contracts/interfaces/IStakingPositions.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPoolAssetsView {
    function getAllPoolAssets() external view returns (bytes32[] memory);
}

/**
 * @title ArbitrumYieldForkFixture
 * @notice Shared base for the SP6 W8 Arbitrum yield-adapter fork tests (YieldYakFacetArbi / Beefy).
 *         Extends {ArbitrumGmxForkFixture} — reuses the live-diamond attach, the signer-override
 *         solvency cut, the funded Prime Account, and the RedStone verification helper — and layers
 *         on the pieces every staking flow needs (the W7 Avalanche-yield pattern ported to Arbitrum):
 *
 *   - {_solvencyFeedSet}: the RedStone feed set a solvency-gated staking call must carry. A stake
 *     mutates the account's owned-asset composition (the Beefy/YieldYak vault token is added as an
 *     OWNED asset via `_syncExposure`, valued via its RedStone symbol) and the solvency read runs
 *     AFTER the body, so the post-stake read requests prices for `getOwnedAssetsWithNative() ∪
 *     getAllPoolAssets() ∪ <candidate staked/vault symbols>`. The set is built dynamically from live
 *     state and UNION-ed with the candidate symbols the W8 yield facets touch (GMX/MOO_GMX for
 *     Beefy, GLP/YY_WOMBEX_GLP for YieldYak). On the live Arbitrum TokenManager GMX + MOO_GMX have
 *     NO Chainlink feed configured (verified on-fork) → both resolve through the RedStone path of
 *     `getPricesFromRedstoneAndChainlink`, so they MUST appear in the payload or a wrapped staking
 *     call reverts InsufficientNumberOfUniqueSigners on the missing feed. Extra feeds are harmless
 *     (the consumer only extracts the symbols it actually requests).
 *   - {_wrapSolvent}: append a test-signer RedStone payload (the feed set above) to a facet call and
 *     fire it as `user`, returning the raw (ok, ret) without bubbling.
 *   - {_fundToken}: `deal` an input token to `user` and `fund()` it into the Prime Account.
 *   - {_hasStakedIdentifier} / {_stakedCount}: read the live staked-position list (kept for parity
 *     with the Avalanche base; the W8 adapters track their vault token as an owned asset rather than
 *     a StakedPosition, so the tests assert {_ownsAsset} + the vault-token balance directly).
 *
 * Gated/skip behaviour is inherited verbatim from {ArbitrumGmxForkFixture} (RUN_GMX_FORK=true +
 * arbitrum chain config); under the default test config these SKIP.
 */
abstract contract ArbitrumYieldForkFixture is ArbitrumGmxForkFixture {
    /// @dev After the base fork attach + funded PA, install the ArbSys (0x64) / ArbGasInfo (0x6C)
    ///      precompile stubs. The Beefy GMX strategy harvests on deposit (`beforeDeposit` →
    ///      `_harvest`), and the GMX reward path reads those Arbitrum precompiles — absent the
    ///      stubs a deposit reverts `NotActivated` deep inside the strategy. Harmless for the
    ///      YieldYak SUNSET path (which reverts before any external interaction).
    function setUp() public virtual override {
        super.setUp();
        if (_gmxForkActive()) {
            GmxKeeperSim.etchPrecompiles(vm);
        }
    }

    // Candidate staked/vault symbols the W8 yield facets touch. GMX + MOO_GMX (Beefy) are ACTIVE +
    // RedStone-priced (no Chainlink feed) on the live Arbitrum TokenManager (verified on-fork). GLP +
    // YY_WOMBEX_GLP (YieldYakFacetArbi) are DELISTED (status 0) — included only so the union is a
    // superset; if YieldYak is ever re-listed the feed set already covers it.
    function _candidateStakedSymbols() internal pure returns (bytes32[] memory s) {
        s = new bytes32[](4);
        s[0] = bytes32("GMX");
        s[1] = bytes32("MOO_GMX");
        s[2] = bytes32("GLP");
        s[3] = bytes32("YY_WOMBEX_GLP");
    }

    /// @notice Build the deduplicated RedStone feed set + nominal prices a wrapped staking call needs:
    ///         owned-with-native ∪ pool assets ∪ candidate staked symbols. With zero debt any valid
    ///         price keeps the account solvent, so ETH/USDC get the fixture's deterministic test
    ///         prices and every other symbol a nominal $1 (8-dec) — enough to validate the payload.
    function _solvencyFeedSet() internal view returns (bytes32[] memory feeds, uint256[] memory vals) {
        // getAllOwnedAssets (a registered SmartLoanViewFacet selector) instead of the solvency
        // facet's getOwnedAssetsWithNative (NOT registered on the beacon — calling it externally
        // reverts "Diamond: Function does not exist"); ETH (the native enrichment getPrices adds on
        // Arbitrum) is added explicitly so the post-stake solvency read never misses the native feed.
        bytes32[] memory owned = SmartLoanViewFacet(loan).getAllOwnedAssets();
        bytes32[] memory pool = IPoolAssetsView(TOKEN_MANAGER).getAllPoolAssets();
        bytes32[] memory extra = _candidateStakedSymbols();

        bytes32[] memory native = new bytes32[](1);
        native[0] = SYM_ETH;

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
            if (tmp[i] == SYM_ETH) vals[i] = ETH_PRICE_8;
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

    /// @dev True iff `getAssetAddress(symbol, true)` reverts "Asset not supported." on the live TM —
    ///      i.e. the symbol has been DELISTED (status 0, no registered address). Used by the YieldYak
    ///      SUNSET proof.
    function _assetUnsupported(bytes32 symbol) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            TOKEN_MANAGER.staticcall(abi.encodeWithSignature("getAssetAddress(bytes32,bool)", symbol, true));
        if (ok) return false;
        return keccak256(bytes(_revertReason(ret))) == keccak256(bytes("Asset not supported."));
    }
}
