// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheGmxForkFixture} from "../../fixtures/AvalancheGmxForkFixture.sol";
import {GmxKeeperSim} from "../../helpers/gmx/GmxKeeperSim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * SP6 W1 — GMX normal-GM WITHDRAWAL lifecycle (Avalanche live-diamond fork). Gated — SKIPS
 * under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * The Avalanche counterpart of the proven Arbitrum {GmxWithdrawalLifecycleTest}. Builds on the
 * proven Avax deposit+execute flow (`_depositAndExecute`): a simulated keeper first executes a
 * GM deposit so the Prime Account holds a REAL GM position, then the account creates a GM
 * withdrawal and a simulated keeper EXECUTES it — driving the real `afterWithdrawalExecution`
 * callback into our diamond. First-ever end-to-end coverage of the async withdrawal lifecycle
 * on Avalanche.
 *
 * Swallowed-revert-aware: GMX wraps a reverting callback as AfterWithdrawalExecutionError and
 * STILL returns the long+short tokens to the receiver, so the token return alone does not prove
 * our callback ran. The load-bearing proof that `afterWithdrawalExecution` executed is the
 * UNFREEZE + exposure sync; we assert BOTH of those AND the token return (GM burned, WAVAX+USDC
 * up) — together they distinguish a real execution from both a swallowed callback and a cancel.
 */
contract GmxWithdrawalLifecycleTest is AvalancheGmxForkFixture {
    function testWithdrawalExecutedByKeeperFiresCallback() public {
        // 1) establish a real GM position via the proven deposit+execute path.
        _depositAndExecute();
        uint256 gmBefore = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);
        assertGt(gmBefore, 0, "no GM position to withdraw");
        assertEq(_accountFrozenSince(), 0, "account should be unfrozen after deposit-execute");

        // 2) create a FULL GM withdrawal. minLong/minShort kept tiny (well below the ~$20 the
        //    position returns) so the keeper execution fills both legs; the fixture sizes the
        //    RedStone GM price to the min-output USD so create-side isWithinBounds passes at its
        //    centre.
        uint256 minLong = 0.001 ether; // a sliver of WAVAX
        uint256 minShort = 1e6; //        $1 of USDC
        bytes32 key = _createGmWithdrawal(gmBefore, minLong, minShort);
        assertTrue(key != bytes32(0), "GMX withdrawal key is zero");
        // the account re-freezes for the duration of the in-flight withdrawal request.
        assertGt(_accountFrozenSince(), 0, "account not frozen after withdrawal create");

        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(loan);
        uint256 usdcBefore = IERC20(USDC).balanceOf(loan);

        // 3) simulate the keeper executing the withdrawal in a separate "tx" (no precompile etch).
        vm.warp(block.timestamp + 1); // stay well within the 5-minute cached-price window
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPrices();
        GmxKeeperSim.executeWithdrawalAvax(vm, key, tokens, providers);

        // 4) afterWithdrawalExecution callback effects on OUR Prime Account.
        uint256 gmAfter = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);
        uint256 wavaxAfter = IERC20(WAVAX).balanceOf(loan);
        uint256 usdcAfter = IERC20(USDC).balanceOf(loan);

        // GM burned by the withdrawal (full position → balance ~0). Combined with the token
        // return below, this proves EXECUTION, not a cancellation (a cancel would REFUND the GM
        // and return no long/short).
        assertLt(gmAfter, gmBefore, "GM not burned by the withdrawal");

        // Long + short returned to the loan — the load-bearing distinguisher that GMX actually
        // processed the withdrawal (WAVAX also picks up the wrapped execution-fee refund).
        assertGt(wavaxAfter, wavaxBefore, "WAVAX (long) not returned to the loan");
        assertGt(usdcAfter, usdcBefore, "USDC (short) not returned to the loan");

        // Our callback ran: account unfrozen + both returned legs synced as owned assets.
        // (If the callback had reverted and been swallowed, the account would remain FROZEN even
        // though GMX returned the tokens — so this unfreeze is the proof the callback executed.)
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the withdrawal callback");
        assertTrue(_ownsAsset(SYM_AVAX), "AVAX (long) not synced into owned assets");
        assertTrue(_ownsAsset(SYM_USDC), "USDC (short) not synced into owned assets");
    }
}
