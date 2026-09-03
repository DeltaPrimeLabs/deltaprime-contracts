// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The WombatFacet entrypoints exercised here (live @0x94aAa81E on the Avalanche beacon).
///      The sAVAX/AVAX pool native-AVAX leg is the representative flow (one of Wombat's 25
///      selectors): deposit native AVAX → mint+stake the AVAX-side LP → withdraw back to AVAX.
interface IWombatFacet {
    function depositAvaxToAvaxSavax(uint256 amount, uint256 minLpOut) external;
    function withdrawAvaxFromAvaxSavax(uint256 amount, uint256 minOut) external returns (uint256);
    function avaxBalanceAvaxSavax() external view returns (uint256);
}

/**
 * SP6 W7 — Wombat (sAVAX/AVAX pool, AVAX leg) live-diamond fork e2e (Avalanche). Gated — SKIPS
 * under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * First-ever fork coverage of the WombatFacet deposit/stake/withdraw lifecycle against the live
 * Wombat sAVAX/AVAX pool (`0xE3Abc29B…9D87`) + WombatMaster (`0x6521a549…cd7b`, pid 2 on-fork).
 * The representative flow uses the Prime Account's funded WAVAX collateral: `depositAvaxToAvaxSavax`
 * unwraps WAVAX, `addLiquidityNative` into the AVAX side of the pool, stakes the LP into the master
 * in one call, and records a `WOMBAT_sAVAX_AVAX_LP_AVAX` staked position. That symbol is registered
 * + RedStone-priced on the live TokenManager (verified on-fork), and the deposit is
 * `remainsSolvent`-gated, so the create is wrapped with a test-signer RedStone payload carrying the
 * LP feed (+ owned/pool feeds).
 *
 * NOTE (deployed-vs-source drift, on-fork finding): the in-repo `_withdrawNative` carries no
 * `remainsSolvent`, but the LIVE deployed facet calls `isSolvent()` (selector 0x5ce23950) on exit,
 * so `withdrawAvaxFromAvaxSavax` ALSO requires a RedStone payload on-fork (a plain call reverts
 * `CalldataMustHaveValidPayload`). We wrap it accordingly.
 *
 * Load-bearing post-state (never bare no-revert):
 *   - after deposit: the staked LP balance (`avaxBalanceAvaxSavax()` → WombatMaster.userInfo.amount)
 *     is > 0 and the `WOMBAT_sAVAX_AVAX_LP_AVAX` staked position is recorded;
 *   - after withdraw: the AVAX comes back to the Prime Account (re-wrapped, WAVAX balance up), the
 *     staked LP balance falls to zero and the staked position is removed.
 */
contract WombatForkTest is AvalancheYieldForkFixture {
    bytes32 internal constant LP_AVAX = bytes32("WOMBAT_sAVAX_AVAX_LP_AVAX");

    // 1 AVAX of the 5 WAVAX the fixture funds — leaves ~4 WAVAX as collateral so the post-deposit
    // solvency check passes comfortably regardless of the LP's staked debt-coverage on prod.
    uint256 internal constant DEPOSIT_AVAX = 1 ether;

    function testDepositAvaxToSavaxPoolCreatesLpPosition() public {
        assertEq(IWombatFacet(loan).avaxBalanceAvaxSavax(), 0, "unexpected pre-existing Wombat LP");

        _wrapSolventExpectSuccess(
            abi.encodeWithSelector(IWombatFacet.depositAvaxToAvaxSavax.selector, DEPOSIT_AVAX, uint256(0))
        );

        // The LP minted and was staked into the master under the PA.
        assertGt(IWombatFacet(loan).avaxBalanceAvaxSavax(), 0, "no staked Wombat LP after deposit");
        assertTrue(_hasStakedIdentifier(LP_AVAX), "WOMBAT_sAVAX_AVAX_LP_AVAX position not recorded");
    }

    function testDepositWithdrawAvaxSavaxE2E() public {
        uint256 wavaxBeforeDeposit = IERC20(WAVAX).balanceOf(loan);

        // ---- deposit (solvency-gated) ----
        _wrapSolventExpectSuccess(
            abi.encodeWithSelector(IWombatFacet.depositAvaxToAvaxSavax.selector, DEPOSIT_AVAX, uint256(0))
        );
        uint256 lp = IWombatFacet(loan).avaxBalanceAvaxSavax();
        assertGt(lp, 0, "deposit did not stake any LP");
        assertTrue(_hasStakedIdentifier(LP_AVAX), "LP position missing after deposit");
        // The deposit consumed ~DEPOSIT_AVAX of WAVAX (unwrapped into the pool).
        assertLt(IERC20(WAVAX).balanceOf(loan), wavaxBeforeDeposit, "deposit did not spend WAVAX");

        uint256 wavaxAfterDeposit = IERC20(WAVAX).balanceOf(loan);

        // ---- withdraw the full LP back to AVAX (live facet checks isSolvent on exit → wrapped) ----
        (bool ok, bytes memory ret) = _wrapSolvent(
            abi.encodeWithSelector(IWombatFacet.withdrawAvaxFromAvaxSavax.selector, type(uint256).max, uint256(0))
        );
        assertTrue(ok, "wrapped withdraw reverted");
        uint256 amountOut = abi.decode(ret, (uint256));
        assertGt(amountOut, 0, "withdraw returned no AVAX");

        // AVAX came back, was re-wrapped to WAVAX, and the staked position is gone.
        assertEq(IWombatFacet(loan).avaxBalanceAvaxSavax(), 0, "staked LP not drained by withdraw");
        assertFalse(_hasStakedIdentifier(LP_AVAX), "LP position not removed after full withdraw");
        assertGt(IERC20(WAVAX).balanceOf(loan), wavaxAfterDeposit, "AVAX not returned to the PA as WAVAX");
    }
}
