// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER (no ffi, no special EVM version). Live-diamond fork mode. Gated on
// RUN_GMX_FORK=true + arbitrum chain config (inherited from the GMX fixture);
// SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js arbitrum >/dev/null && \
//     RUN_GMX_FORK=true forge test --match-path \
//     'test/forge/fork/arbitrum/WrappedNativeFork.t.sol' -vvv
// =============================================================================

import {ArbitrumGmxForkFixture} from "../../fixtures/ArbitrumGmxForkFixture.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWrappedNativeFacet {
    function depositNativeToken() external payable;
    function wrapNativeToken(uint256 amount) external;
}

/**
 * SP6 W4 — SmartLoanWrappedNativeTokenFacet live-diamond fork e2e (Arbitrum, facet 0x8D784A9b…).
 *
 * Two entrypoints:
 *   - depositNativeToken(): onlyOwner, NOT solvency-gated on the live facet (no payload) — wrap
 *     native ETH sent as msg.value into WETH collateral inside the PA.
 *   - wrapNativeToken(amount): wrap native ETH the PA already holds (e.g. a GMX execution-fee
 *     refund) into WETH collateral. DEPLOYED-VS-SOURCE DRIFT: the in-repo source carries no
 *     `remainsSolvent`, but the LIVE deployed facet DOES (a plain call reverts
 *     `CalldataMustHaveValidPayload()`), so the happy path is wrapped with a test-signer RedStone
 *     payload — same drift class flagged in W7/W8 for the deployed unstake/withdraw facets.
 *
 * Load-bearing post-state (never bare no-revert): the PA's WETH balance grows by EXACTLY the wrapped
 * amount and "ETH" stays a tracked owned asset (the facet's `_syncExposure` ran).
 */
contract WrappedNativeForkTest is ArbitrumGmxForkFixture {
    uint256 internal constant DEPOSIT_NATIVE = 0.2 ether;
    uint256 internal constant WRAP_NATIVE = 0.3 ether;

    function testDepositNativeTokenWrapsToCollateral() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(loan);
        assertEq(wethBefore, FUND_AMOUNT, "fixture WETH collateral missing");

        vm.deal(user, DEPOSIT_NATIVE);
        vm.prank(user);
        IWrappedNativeFacet(loan).depositNativeToken{value: DEPOSIT_NATIVE}();

        assertEq(
            IERC20(WETH).balanceOf(loan),
            wethBefore + DEPOSIT_NATIVE,
            "depositNativeToken did not wrap msg.value into WETH"
        );
        assertTrue(_ownsAsset(bytes32("ETH")), "ETH not a tracked owned asset after depositNativeToken");
    }

    function testWrapNativeTokenWrapsPreHeldBalance() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(loan);

        // Seed the PA with raw native ETH (as a GMX fee refund would), then wrap it in-place.
        // The live facet's wrapNativeToken enforces solvency → append a test-signer payload (ETH is
        // a pool asset in the feed set; zero debt → solvent).
        vm.deal(loan, WRAP_NATIVE);
        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(USDC_PRICE_8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory cd = abi.encodeWithSelector(IWrappedNativeFacet.wrapNativeToken.selector, WRAP_NATIVE);
        vm.prank(user);
        (bool ok, bytes memory ret) = loan.call(bytes.concat(cd, payload));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        assertEq(
            IERC20(WETH).balanceOf(loan),
            wethBefore + WRAP_NATIVE,
            "wrapNativeToken did not wrap the pre-held native balance into WETH"
        );
        assertEq(loan.balance, 0, "native balance not fully consumed by wrap");
        assertTrue(_ownsAsset(bytes32("ETH")), "ETH not a tracked owned asset after wrapNativeToken");
    }

    function testWrapNativeTokenNonOwnerReverts() public {
        vm.deal(loan, WRAP_NATIVE);
        // Append a valid payload so the ONLY possible revert reason is the owner gate (not a
        // missing RedStone payload), making this a genuine access-control assertion.
        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(USDC_PRICE_8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory cd = abi.encodeWithSelector(IWrappedNativeFacet.wrapNativeToken.selector, WRAP_NATIVE);
        address attacker = makeAddr("wrapAttacker");
        vm.prank(attacker);
        (bool ok, bytes memory ret) = loan.call(bytes.concat(cd, payload));
        assertFalse(ok, "non-owner must not be able to wrap native token");
        // Tighten: assert the revert IS the owner gate (onlyOwnerOrLiquidation → enforceIsContractOwner)
        // and not some incidental failure — robustness + consistency with the ParaSwap guard.
        assertTrue(
            _revertIsOwnerGate(ret),
            "wrapNativeToken must revert at the owner gate (DiamondStorageLib owner error)"
        );
    }

    /// @dev True iff `ret` is an Error(string) revert whose message carries the DiamondStorageLib
    ///      owner-gate signal ("Must be contract owner"). Mirrors DeltaPrimeFixture._revertContains.
    function _revertIsOwnerGate(bytes memory ret) internal pure returns (bool) {
        if (ret.length < 4 || bytes4(ret) != bytes4(0x08c379a0)) return false;
        bytes memory data = new bytes(ret.length - 4);
        for (uint256 i; i < data.length; i++) data[i] = ret[i + 4];
        bytes memory hay = bytes(abi.decode(data, (string)));
        bytes memory needle = bytes("Must be contract owner");
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; i++) {
            bool found = true;
            for (uint256 j; j < needle.length; j++) {
                if (hay[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
