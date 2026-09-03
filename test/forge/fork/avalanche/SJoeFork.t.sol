// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheYieldForkFixture} from "../../fixtures/AvalancheYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The five SJoeFacet selectors exercised here (live @0x8aD9028f on the Avalanche beacon).
interface ISJoeFacet {
    function stakeJoe(uint256 amount) external;
    function unstakeJoe(uint256 amount) external;
    function claimSJoeRewards() external;
    function joeBalanceInSJoe() external view returns (uint256);
    function rewardsInSJoe() external view returns (uint256);
}

/**
 * SP6 W7 — sJoe (TraderJoe revenue-share staking) live-diamond fork e2e (Avalanche). Gated —
 * SKIPS under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * First-ever fork coverage of the SJoeFacet staking lifecycle against the live sJoe contract
 * (StableJoeStaking `0x1a731B22…Cb51`, reward token USDC). The facet stakes JOE
 * (`0x6e84a621…0fDd`, ACTIVE + RedStone-priced on the live TokenManager, verified on-fork) and
 * records a `'sJOE'` staked position whose value the solvency check reads via
 * `joeBalanceInSJoe()` → so `stakeJoe` is solvency-gated and must be wrapped with a test-signer
 * RedStone payload carrying the `'JOE'` feed (+ owned/pool feeds).
 *
 * NOTE (deployed-vs-source drift, on-fork finding): the in-repo `SJoeFacet.unstakeJoe` carries no
 * `remainsSolvent`, but the LIVE deployed facet calls `isSolvent()` (selector 0x5ce23950) on exit,
 * so `unstakeJoe` ALSO requires a RedStone payload on-fork. We wrap it accordingly (a plain call
 * reverts `CalldataMustHaveValidPayload`). The staked `'sJOE'` position survives a full unstake
 * (the facet never removes it), so the post-unstake solvency read still requests the `'JOE'` feed.
 *
 * Load-bearing post-state (never bare no-revert):
 *   - after stake: `joeBalanceInSJoe() > 0`, the `'sJOE'` staked position is present, and the
 *     account's free JOE balance dropped by the staked amount;
 *   - after unstake: the JOE returns to the Prime Account (free balance back up) and the staked
 *     sJoe balance falls to zero.
 */
contract SJoeForkTest is AvalancheYieldForkFixture {
    address internal constant JOE = 0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd;
    address internal constant SJOE = 0x1a731B2299E22FbAC282E7094EdA41046343Cb51;
    bytes32 internal constant SJOE_IDENTIFIER = bytes32("sJOE");

    uint256 internal constant STAKE_JOE = 100 ether; // 100 JOE (18-dec)

    function testStakeJoeCreatesPosition() public {
        _fundToken(bytes32("JOE"), JOE, STAKE_JOE);
        assertEq(IERC20(JOE).balanceOf(loan), STAKE_JOE, "JOE not funded into the PA");
        assertEq(ISJoeFacet(loan).joeBalanceInSJoe(), 0, "unexpected pre-existing sJoe stake");

        _wrapSolventExpectSuccess(abi.encodeWithSelector(ISJoeFacet.stakeJoe.selector, STAKE_JOE));

        // The JOE left the PA's free balance and now sits inside sJoe (no deposit fee on-chain →
        // ~1:1; assert STRICT > 0 + the free-balance drop, which together prove a real stake).
        assertEq(IERC20(JOE).balanceOf(loan), 0, "JOE not moved out of free balance by stake");
        assertGt(ISJoeFacet(loan).joeBalanceInSJoe(), 0, "no JOE staked in sJoe");
        assertTrue(_hasStakedIdentifier(SJOE_IDENTIFIER), "sJOE staked position not recorded");
    }

    function testStakeClaimUnstakeJoeE2E() public {
        _fundToken(bytes32("JOE"), JOE, STAKE_JOE);

        // ---- stake ----
        _wrapSolventExpectSuccess(abi.encodeWithSelector(ISJoeFacet.stakeJoe.selector, STAKE_JOE));
        uint256 staked = ISJoeFacet(loan).joeBalanceInSJoe();
        assertGt(staked, 0, "stake did not land in sJoe");
        assertTrue(_hasStakedIdentifier(SJOE_IDENTIFIER), "sJOE position missing after stake");

        // ---- claim (solvency-gated; on a fork with no fresh USDC fee deposits pendingReward is 0,
        //      so this is a no-op claim that still exercises the wrapped claim entrypoint) ----
        _wrapSolventExpectSuccess(abi.encodeWithSelector(ISJoeFacet.claimSJoeRewards.selector));
        assertEq(ISJoeFacet(loan).joeBalanceInSJoe(), staked, "claim must not move the JOE principal");

        // ---- unstake (live facet checks isSolvent on exit → wrap with a RedStone payload) ----
        uint256 joeBefore = IERC20(JOE).balanceOf(loan);
        _wrapSolventExpectSuccess(abi.encodeWithSelector(ISJoeFacet.unstakeJoe.selector, staked));

        // JOE principal returns to the Prime Account and the sJoe balance is drained.
        assertEq(ISJoeFacet(loan).joeBalanceInSJoe(), 0, "sJoe balance not drained by unstake");
        assertGt(IERC20(JOE).balanceOf(loan), joeBefore, "JOE not returned to the PA on unstake");
        assertApproxEqAbs(
            IERC20(JOE).balanceOf(loan),
            joeBefore + staked,
            1e15,
            "returned JOE != staked principal"
        );
    }
}
