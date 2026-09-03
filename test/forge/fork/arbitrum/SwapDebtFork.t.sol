// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// =============================================================================
// FORK + FFI TIER. swapDebtParaSwap routes the refinance through the LIVE ParaSwap
// v6.2 router, so the swap calldata is fetched at fork time via `vm.ffi`
// (`node tools/scripts/paraswap-arb-swapdata.js ...`). Requires, on top of the usual
// gating (RUN_GMX_FORK=true + arbitrum chain config):
//   * `--ffi` (the default profile sets ffi=false);
//   * `FOUNDRY_EVM_VERSION=cancun` — the ParaSwap Augustus/executor bytecode uses
//     post-london opcodes (same as the W6 ParaSwap test);
//   * network access + node + the in-repo @paraswap/sdk dependency.
// Run:
//   node tools/scripts/select-chain-config.js arbitrum >/dev/null && \
//     FOUNDRY_EVM_VERSION=cancun RUN_GMX_FORK=true forge test --ffi \
//     --match-path 'test/forge/fork/arbitrum/SwapDebtFork.t.sol' -vvv
// Under the default test config the body self-skips (fixture vm.skip), so the default
// london suite is unaffected and merely needs this file to COMPILE.
// =============================================================================

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/console2.sol";

interface ISwapDebtFacet {
    function swapDebtParaSwap(
        bytes32 _fromAsset,
        bytes32 _toAsset,
        uint256 _repayAmount,
        uint256 _borrowAmount,
        bytes4 selector,
        bytes calldata data
    ) external;
}

interface ITokenManagerView {
    function getPoolAddress(bytes32 _asset) external view returns (address);
}

interface IPoolView {
    function getBorrowed(address _user) external view returns (uint256);
}

/**
 * SP6 W4 — SwapDebtFacet live-diamond fork e2e (Arbitrum, facet 0xdc168a1F…).
 *
 * Proves debt REFINANCING moves a Prime Account's debt from one pool to another against the LIVE
 * Arbitrum pools + the live ParaSwap v6.2 router. Flow:
 *   1. borrow 100 USDC → the PA carries USDC-pool debt (asset A);
 *   2. swapDebtParaSwap(USDC, ETH, 100 USDC, X ETH, …): the facet borrows X ETH (asset B), swaps
 *      that ETH → USDC via ParaSwap, and repays the 100 USDC debt.
 *
 * The swap calldata (ETH→USDC for exactly X ETH) is fetched at fork time via `vm.ffi` →
 * `tools/scripts/paraswap-arb-swapdata.js`, pinning the partner to the Arbitrum FEES_TREASURY and
 * the Prime Account as beneficiary (the only values validateSwapParameters accepts). X is sized from
 * the facet's own ±5% dollar-value guard using the LIVE Chainlink ETH price so borrowValueUSD ≈
 * repayValueUSD; the wrapped solvency/price payload prices ETH at that same live rate (see the W6
 * ParaSwap SLIPPAGE NOTE — the fixture's nominal ETH=$2000 would trip the dollar-value guard).
 *
 * Load-bearing post-state (never bare no-revert): the USDC-pool debt collapses to interest dust and
 * the ETH-pool debt appears at exactly X — i.e. the debt MOVED from pool A to pool B. (The facet caps
 * the repay to the original 100 USDC `_repayAmount`, while the live USDC pool accrues a few wei of
 * borrow interest over the block advance required by `noBorrowInTheSameBlock`, so a handful of wei of
 * USDC debt remains — a realistic, non-zero-but-negligible residual, not a faked exact zero.)
 */
contract SwapDebtForkTest is ArbitrumYieldForkFixture {
    using Strings for uint256;

    uint256 internal constant USDC_DEBT = 100e6; // 100 USDC of refinanced debt

    function testSwapDebtUsdcToEthMovesDebt() public {
        ITokenManagerView tm = ITokenManagerView(TOKEN_MANAGER);
        IPoolView usdcPool = IPoolView(tm.getPoolAddress(SYM_USDC));
        IPoolView ethPool = IPoolView(tm.getPoolAddress(bytes32("ETH")));

        // ---- 1) open USDC-pool debt (asset A) ----
        (bool okBorrow,) = _borrowRaw(SYM_USDC, USDC_DEBT);
        require(okBorrow, "fixture: USDC borrow failed");
        assertEq(usdcPool.getBorrowed(loan), USDC_DEBT, "USDC debt not opened");
        assertEq(ethPool.getBorrowed(loan), 0, "unexpected pre-existing ETH debt");

        // swapDebt has noBorrowInTheSameBlock — advance past the USDC borrow's block.
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);

        // ---- 2) size the ETH borrow from the facet's ±5% dollar-value guard at the LIVE ETH price ----
        uint256 ethLive = _liveEthUsd8(); // 8-dec Chainlink ETH/USD
        // repayValueUSD (facet math): USDC_PRICE_8 * repay * 1e10 / 10^6
        uint256 repayValueUsd = USDC_PRICE_8 * USDC_DEBT * 1e10 / 1e6;
        // borrowValueUSD = ethLive * borrow * 1e10 / 1e18 == repayValueUSD  →  borrow = repayValueUSD * 1e8 / ethLive
        uint256 ethBorrow = repayValueUsd * 1e8 / ethLive;
        require(ethBorrow > 0, "computed zero ETH borrow");

        // ---- 3) live ParaSwap route: sell exactly `ethBorrow` WETH for USDC, beneficiary = PA ----
        (bytes4 selector, bytes memory swapData) = _paraSwapRoute(WETH, 18, USDC, 6, ethBorrow, loan);
        require(swapData.length > 0, "empty ParaSwap calldata");

        // ---- 4) execute the wrapped, solvency-gated refinance (ETH priced live so the ±5% guard
        //         + remainsSolvent both reflect the real swap value) ----
        bytes memory payload = _realPricedPayload(ethLive);
        bytes memory cd = abi.encodeWithSelector(
            ISwapDebtFacet.swapDebtParaSwap.selector,
            SYM_USDC, // from (repay)
            bytes32("ETH"), // to (borrow)
            USDC_DEBT,
            ethBorrow,
            selector,
            swapData
        );
        vm.prank(user);
        (bool ok, bytes memory ret) = loan.call(bytes.concat(cd, payload));
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }

        // ---- 5) load-bearing post-state: debt MOVED USDC → ETH ----
        uint256 usdcDebtAfter = usdcPool.getBorrowed(loan);
        uint256 ethDebtAfter = ethPool.getBorrowed(loan);
        console2.log("USDC debt after refinance", usdcDebtAfter);
        console2.log("ETH  debt after refinance", ethDebtAfter);
        // USDC debt collapses to (at most) a few wei of borrow-interest dust accrued over the block
        // advance; assert it is below 0.01 USDC (≫ the observed ~4 wei) — the refinance cleared it.
        assertLt(usdcDebtAfter, 1e4, "USDC debt not collapsed to interest dust by the refinance");
        // and the debt re-appeared in the ETH pool at exactly the borrowed amount.
        assertEq(ethDebtAfter, ethBorrow, "ETH debt did not appear at the borrowed amount");
    }

    /// @dev The fixture's solvency feed set with ETH re-priced to the live Chainlink rate (USDC $1);
    ///      every other feed keeps its nominal value (zero net distortion — see W6 SLIPPAGE NOTE).
    function _realPricedPayload(uint256 ethLive) internal view returns (bytes memory) {
        (bytes32[] memory feeds, uint256[] memory vals) = _solvencyFeedSet();
        for (uint256 i; i < feeds.length; i++) {
            if (feeds[i] == SYM_ETH) vals[i] = ethLive;
            else if (feeds[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
        }
        return RedstoneLib.buildPayload(vm, feeds, vals);
    }

    // ffi: ParaSwap route fetch + selector split (mirrors the W6 ParaSwap pattern).
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
