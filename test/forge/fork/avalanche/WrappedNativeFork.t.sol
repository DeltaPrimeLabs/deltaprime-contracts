// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK TIER (no ffi, no special EVM version). Live-diamond fork mode. Gated on
// RUN_GMX_FORK=true + avalanche chain config (inherited from the GMX fixture);
// SKIPS under the default test config. Run:
//   node tools/scripts/select-chain-config.js avalanche >/dev/null && \
//     RUN_GMX_FORK=true forge test --match-path \
//     'test/forge/fork/avalanche/WrappedNativeFork.t.sol' -vvv
// =============================================================================

import {AvalancheGmxForkFixture} from "../../fixtures/AvalancheGmxForkFixture.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWrappedNativeFacet {
    function depositNativeToken() external payable;
    function wrapNativeToken(uint256 amount) external;
}

/**
 * SP6 W4 — SmartLoanWrappedNativeTokenFacet live-diamond fork e2e (Avalanche, facet 0x81252DF6…).
 *
 * Avalanche mirror of the Arbitrum WrappedNative test: deposit native AVAX as WAVAX collateral via
 * depositNativeToken() (onlyOwner, not solvency-gated → no payload); wrap pre-held native AVAX via
 * wrapNativeToken(amount). Like Arbitrum, the LIVE deployed wrapNativeToken is solvency-gated even
 * though the in-repo source is not (plain call reverts `CalldataMustHaveValidPayload()`), so the
 * happy path is wrapped with a test-signer RedStone payload (deployed-vs-source drift, W7/W8 class).
 * Load-bearing post-state: the PA's WAVAX balance grows by EXACTLY the wrapped amount and "AVAX"
 * stays a tracked owned asset.
 */
contract WrappedNativeForkTest is AvalancheGmxForkFixture {
    uint256 internal constant DEPOSIT_NATIVE = 1 ether; // AVAX
    uint256 internal constant WRAP_NATIVE = 2 ether; // AVAX

    function testDepositNativeTokenWrapsToCollateral() public {
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(loan);
        assertEq(wavaxBefore, FUND_AMOUNT, "fixture WAVAX collateral missing");

        vm.deal(user, DEPOSIT_NATIVE);
        vm.prank(user);
        IWrappedNativeFacet(loan).depositNativeToken{value: DEPOSIT_NATIVE}();

        assertEq(
            IERC20(WAVAX).balanceOf(loan),
            wavaxBefore + DEPOSIT_NATIVE,
            "depositNativeToken did not wrap msg.value into WAVAX"
        );
        assertTrue(_ownsAsset(bytes32("AVAX")), "AVAX not a tracked owned asset after depositNativeToken");
    }

    function testWrapNativeTokenWrapsPreHeldBalance() public {
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(loan);

        // The live facet's wrapNativeToken enforces solvency → append a test-signer payload (AVAX is
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
            IERC20(WAVAX).balanceOf(loan),
            wavaxBefore + WRAP_NATIVE,
            "wrapNativeToken did not wrap the pre-held native balance into WAVAX"
        );
        assertEq(loan.balance, 0, "native balance not fully consumed by wrap");
        assertTrue(_ownsAsset(bytes32("AVAX")), "AVAX not a tracked owned asset after wrapNativeToken");
    }

    function testWrapNativeTokenNonOwnerReverts() public {
        vm.deal(loan, WRAP_NATIVE);
        // Append a valid payload so the ONLY possible revert reason is the owner gate.
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
