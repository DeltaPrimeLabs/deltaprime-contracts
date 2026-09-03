// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK + FFI TIER. The happy-path swap calls the live ParaSwap API over the
// network via `vm.ffi` (`node tools/scripts/paraswap-arb-swapdata.js ...`) AND
// runs against an Arbitrum fork. It therefore requires, on top of the usual
// gating (RUN_GMX_FORK=true + arbitrum chain config):
//   * ffi enabled — `--ffi` (the default profile sets ffi=false);
//   * `FOUNDRY_EVM_VERSION=cancun` — the ParaSwap v6.2 Augustus/executor bytecode
//     uses post-london opcodes (PUSH0 + newer), `NotActivated` under the repo's
//     pinned london fork spec (same class of issue as the W5 Avalanche DEX work);
//   * network access + node + the in-repo @paraswap/sdk dependency.
// Under the default test config the body self-skips (the fixture's vm.skip), so the
// default london suite is unaffected and merely needs this file to COMPILE.
// =============================================================================

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";

interface IParaSwapV6Facet {
    function paraSwapV6(bytes4 selector, bytes memory data) external;
}

/**
 * SP6 W6 — ParaSwap v6.2 (Augustus) swap live-diamond fork e2e (Arbitrum). Gated — SKIPS under
 * the default test config. Arbitrum mirror of the proven W5 Avalanche ParaSwap test.
 *
 * First-ever Arbitrum fork coverage of the ParaSwapFacet.paraSwapV6 entrypoint (live 0x641493cB on
 * the beacon) against the live ParaSwap v6.2 router. The swap calldata (4-byte Augustus selector ++
 * swap bytes) is fetched at fork time from the live ParaSwap API via `vm.ffi` to
 * `tools/scripts/paraswap-arb-swapdata.js` (chainId 42161), restricted to the two contract methods
 * the facet can decode (`swapExactAmountIn` 0xe3ead59e / `swapExactAmountInOnUniswapV3` 0x876a02f6).
 * The funded WETH collateral (held as "ETH") is sold for USDC; the ffi route pins the partner to the
 * Arbitrum FEES_TREASURY (the only non-zero partner validateSwapParameters accepts) and the Prime
 * Account as beneficiary.
 *
 * `paraSwapV6` is onlyOwner + remainsSolvent → the call is pranked as `user` and wrapped with a
 * test-signer RedStone payload (ETH + USDC are pool assets in the solvency feed set).
 *
 * SLIPPAGE NOTE: unlike the YakSwap/TJ-V2 tests, ParaSwap's facet runs an oracle-priced slippage
 * guard (`checkSlippage`, NORMAL_MAX_SLIPPAGE_BPS = 5%) that compares the sold-vs-bought $-value
 * using the prices in OUR RedStone payload. The fixture's deterministic ETH=$2000 would make a real
 * ~$172 WETH→USDC swap (live ETH ≈ $1727) look like a ~13% loss → SlippageTooHigh. So the payload
 * here prices ETH at the LIVE Chainlink ETH/USD (the same feed the fixture uses for GMX keeper sims)
 * and USDC at $1, so the oracle-implied value ≈ the real DEX execution and the genuine slippage
 * (~DEX fee) is well under 5%. Solvency is unaffected (zero debt → any valid price is solvent).
 *
 * Load-bearing post-state (never bare no-revert): the account's WETH free balance dropped, it
 * received USDC (> 0), and USDC became a tracked owned asset (post-swap `_syncExposure` ran).
 */
contract ParaSwapForkTest is ArbitrumYieldForkFixture {
    using Strings for uint256;

    uint256 internal constant SWAP_IN = 0.1 ether; // 0.1 of the 0.5 WETH funded

    function testParaSwapV6WethToUsdcMovesBalances() public {
        uint256 wethBefore = IERC20(WETH).balanceOf(loan);
        assertEq(wethBefore, FUND_AMOUNT, "fixture WETH collateral missing");
        assertEq(IERC20(USDC).balanceOf(loan), 0, "unexpected pre-existing USDC");

        // ---- build the ParaSwap route via the live API (ffi) ----
        (bytes4 selector, bytes memory swapData) =
            _paraSwapRoute(WETH, 18, USDC, 6, SWAP_IN, loan);
        require(swapData.length > 0, "empty ParaSwap calldata");

        // ---- execute the wrapped, solvency-gated swap, payload priced at the LIVE ETH rate so the
        //      facet's oracle-priced checkSlippage sees the real value (see SLIPPAGE NOTE) ----
        bytes memory payload = _realPricedPayload();
        bytes memory cd =
            abi.encodeWithSelector(IParaSwapV6Facet.paraSwapV6.selector, selector, swapData);
        vm.prank(user);
        (bool ok, bytes memory ret) = loan.call(bytes.concat(cd, payload));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        // ---- load-bearing post-state ----
        uint256 wethAfter = IERC20(WETH).balanceOf(loan);
        uint256 usdcAfter = IERC20(USDC).balanceOf(loan);
        assertLt(wethAfter, wethBefore, "WETH not spent by the swap");
        assertGt(usdcAfter, 0, "swap produced no USDC");
        assertTrue(_ownsAsset(SYM_USDC), "USDC not registered as an owned asset after swap");
    }

    /// @notice Access-control guard (no ffi/network): a non-owner cannot call paraSwapV6. `onlyOwner`
    ///         is checked before the body decodes any swap data, so dummy calldata + a real RedStone
    ///         trailer (so the ONLY failure reason is the owner gate) suffices. Load-bearing on the
    ///         live facet's access control; runs whenever the fork is active (no API dependency).
    ///         We assert the revert IS the DiamondStorageLib owner-gate error — not just "it reverted"
    ///         — because the garbage selector/data would revert in the body too. If `onlyOwner` were
    ///         removed, the body would revert with a DIFFERENT (calldata-driven) error and this
    ///         assertion would correctly FAIL, proving the GATE fired, not the dummy calldata.
    function testParaSwapV6NonOwnerReverts() public {
        (bytes32[] memory feeds, uint256[] memory vals) = _solvencyFeedSet();
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory cd =
            abi.encodeWithSelector(IParaSwapV6Facet.paraSwapV6.selector, bytes4(0), bytes(""));

        address attacker = makeAddr("paraSwapAttacker");
        vm.prank(attacker);
        (bool ok, bytes memory ret) = loan.call(bytes.concat(cd, payload));
        assertFalse(ok, "non-owner must not be able to execute paraSwapV6");
        assertTrue(
            _revertIsOwnerGate(ret),
            "paraSwapV6 must revert at the onlyOwner gate (DiamondStorageLib owner error), not in the body"
        );
    }

    /// @dev True iff `ret` is an Error(string) revert whose message carries the DiamondStorageLib
    ///      owner-gate signal ("Must be contract owner"). Proves the onlyOwner gate fired BEFORE the
    ///      body — so this assertion would correctly FAIL if the gate were removed (the body would
    ///      then revert with a different, calldata-driven error). Mirrors DeltaPrimeFixture._revertContains.
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

    /// @dev The fixture's full solvency feed set, but with the ETH feed re-priced to the LIVE
    ///      Chainlink ETH/USD so the facet's oracle-priced slippage guard reflects the real swap
    ///      value (USDC stays $1). Every other feed keeps its nominal value (zero debt → solvent).
    function _realPricedPayload() internal view returns (bytes memory) {
        (bytes32[] memory feeds, uint256[] memory vals) = _solvencyFeedSet();
        uint256 liveEth = _liveEthUsd8();
        for (uint256 i; i < feeds.length; i++) {
            if (feeds[i] == SYM_ETH) vals[i] = liveEth;
            else if (feeds[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
        }
        return RedstoneLib.buildPayload(vm, feeds, vals);
    }

    // ---------------------------------------------------------------------------
    // ffi: ParaSwap route fetch + selector split (mirrors the W5 Avalanche pattern)
    // ---------------------------------------------------------------------------

    function _paraSwapRoute(
        address srcToken,
        uint256 srcDecimals,
        address destToken,
        uint256 destDecimals,
        uint256 srcAmount,
        address userAddress
    ) internal returns (bytes4 selector, bytes memory swapData) {
        string[] memory args = new string[](8);
        args[0] = "node";
        args[1] = "tools/scripts/paraswap-arb-swapdata.js";
        args[2] = Strings.toHexString(uint256(uint160(srcToken)), 20);
        args[3] = srcDecimals.toString();
        args[4] = Strings.toHexString(uint256(uint160(destToken)), 20);
        args[5] = destDecimals.toString();
        args[6] = srcAmount.toString();
        args[7] = Strings.toHexString(uint256(uint160(userAddress)), 20);
        bytes memory fullData = vm.ffi(args);
        require(fullData.length >= 4, "ParaSwap ffi returned too few bytes");

        assembly {
            selector := mload(add(fullData, 32))
        }
        uint256 len = fullData.length - 4;
        swapData = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            swapData[i] = fullData[i + 4];
        }
    }
}
