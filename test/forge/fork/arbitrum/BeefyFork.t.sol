// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The two BeefyFinanceArbitrumFacet selectors exercised here (live @0xf2E90DF5 on the
///      Arbitrum beacon): deposit GMX into the Beefy mooGMX vault, withdraw it back.
interface IBeefyFacet {
    function stakeGmxBeefy(uint256 amount) external;
    function unstakeGmxBeefy(uint256 amount) external;
}

/// @dev Minimal view of the live Beefy mooGMX strategy (StratManager + Pausable).
interface IBeefyStrategy {
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function unpause() external;
    function setHarvestOnDeposit(bool) external;
}

interface ITokenManagerStatus {
    function tokenToStatus(address) external view returns (uint256);
}

/**
 * SP6 W8 — Beefy (GMX → mooGMX vault) live-diamond fork tests (Arbitrum). Gated — SKIPS under the
 * default test config (RUN_GMX_FORK=true + arbitrum chain config required).
 *
 * ⚠️ RUN NOTE: the live Beefy mooGMX strategy implementation is compiled with a post-Shanghai solc
 * and uses the PUSH0 (0x5f) opcode. The repo pins `evm_version = london` (solc 0.8.17 bytecode
 * parity is load-bearing), under which REVM treats PUSH0 as `NotActivated` and the strategy reverts.
 * These two tests therefore require the REVM execution spec to be bumped to Shanghai via the
 * **`FOUNDRY_EVM_VERSION=shanghai` ENV VAR** (foundry clamps the solc *compile* target back to
 * london — 0.8.17's max — while running REVM at Shanghai, so our own facets are unaffected). The
 * `--evm-version` CLI flag only changes the compile target, NOT the fork spec, so it does NOT work
 * here — the env var is required. Under the default config these SKIP, so the london default suite
 * is unaffected.
 *
 * Live state discovered on-fork (Beefy mooGMX vault `0x5B904f19…88b0`, want == GMX
 * `0xfc5A1A6E…ad0a`, strategy `0xD054E63A…403c`):
 *   - GMX + MOO_GMX are both ACTIVE (status 2) + RedStone-priced (NO Chainlink feed) on the live
 *     DeltaPrime TokenManager — i.e. a Prime Account is still allowed to hold mooGMX as collateral;
 *   - BUT the underlying Beefy strategy is **PAUSED** (`paused() == true`, harvestOnDeposit == true)
 *     — Beefy has frozen NEW deposits to this vault (it still custodies ~3.05k GMX, so existing
 *     positions remain withdrawable). So a real Prime-Account user can NO LONGER enter the position:
 *     `stakeGmxBeefy` reverts `Pausable: paused` (in the strategy's harvest-on-deposit hook).
 *
 * FINDING (registration-vs-reality drift): the only vault the BeefyFinanceArbitrumFacet supports
 * (hardcoded GMX→MOO_GMX) is deposit-frozen upstream, yet MOO_GMX is still registered ACTIVE on the
 * TokenManager. Worth a team cleanup (delist MOO_GMX) since the staking entrypoint is dead for new
 * users. {testBeefyMooGmxStakeBlockedByLivePause} proves this on-fork (load-bearing on live state).
 *
 * {testStakeUnstakeGmxBeefyE2E} still proves OUR facet's deposit→withdraw integration is correct
 * against the REAL on-chain Beefy vault + strategy by un-pausing via the strategy's actual owner
 * (and disabling harvest-on-deposit) — a documented owner-prank fork seam, in the same spirit as the
 * GMX keeper oracle/precompile mocks. The facet entrypoints, approvals, mooToken accounting,
 * `_syncExposure` owned-asset tracking, and the solvency-payload wrapping are all exercised end-to-end.
 */
contract BeefyForkTest is ArbitrumYieldForkFixture {
    address internal constant GMX = 0xfc5A1A6EB076a2C7aD06eD22C90d7E710E35ad0a;
    address internal constant MOO_GMX = 0x5B904f19fb9ccf493b623e5c8cE91603665788b0;
    address internal constant MOO_GMX_STRATEGY = 0xD054E63A61724E336d93d3c58Bcf9b94968c403c;
    bytes32 internal constant SYM_GMX = bytes32("GMX");
    bytes32 internal constant SYM_MOO_GMX = bytes32("MOO_GMX");

    uint256 internal constant STAKE_GMX = 50 ether; // 50 GMX (18-dec)

    /// @notice Real-user reality: the Beefy mooGMX strategy is paused upstream, so the facet's stake
    ///         entrypoint is dead for new positions — even though DeltaPrime still lists the vault
    ///         ACTIVE. Load-bearing on live on-chain state (asserts flip if Beefy ever un-pauses).
    function testBeefyMooGmxStakeBlockedByLivePause() public {
        // The Beefy strategy is paused upstream...
        assertTrue(IBeefyStrategy(MOO_GMX_STRATEGY).paused(), "mooGMX strategy unexpectedly NOT paused");
        // ...yet DeltaPrime's TokenManager still lists both the want + vault token as ACTIVE (drift).
        assertEq(ITokenManagerStatus(TOKEN_MANAGER).tokenToStatus(GMX), 2, "GMX not ACTIVE on TokenManager");
        assertEq(ITokenManagerStatus(TOKEN_MANAGER).tokenToStatus(MOO_GMX), 2, "MOO_GMX not ACTIVE on TokenManager");

        // Fund GMX so the stake reaches the vault.deposit (and thus the paused harvest hook) rather
        // than tripping the facet's "Cannot stake 0 tokens" guard first.
        _fundToken(SYM_GMX, GMX, STAKE_GMX);
        (bool ok, bytes memory ret) =
            _wrapSolvent(abi.encodeWithSelector(IBeefyFacet.stakeGmxBeefy.selector, STAKE_GMX));
        assertFalse(ok, "stakeGmxBeefy unexpectedly succeeded against a paused vault");
        assertEq(_revertReason(ret), "Pausable: paused", "unexpected stakeGmxBeefy revert reason");
    }

    /// @notice Full deposit→withdraw e2e of the facet against the live Beefy vault, with the vault
    ///         un-paused via its real owner (documented fork seam). Proves the facet integration.
    function testStakeUnstakeGmxBeefyE2E() public {
        // Un-pause the live strategy via its actual owner, and disable harvest-on-deposit so the
        // deposit path is isolated to the pure staking mechanics (not Beefy's reward compounding).
        address mgr = IBeefyStrategy(MOO_GMX_STRATEGY).owner();
        vm.startPrank(mgr);
        IBeefyStrategy(MOO_GMX_STRATEGY).unpause();
        IBeefyStrategy(MOO_GMX_STRATEGY).setHarvestOnDeposit(false);
        vm.stopPrank();
        assertFalse(IBeefyStrategy(MOO_GMX_STRATEGY).paused(), "strategy still paused after owner unpause");

        _fundToken(SYM_GMX, GMX, STAKE_GMX);
        uint256 gmxFunded = IERC20(GMX).balanceOf(loan);
        assertEq(gmxFunded, STAKE_GMX, "GMX not funded into the PA");
        assertEq(IERC20(MOO_GMX).balanceOf(loan), 0, "unexpected pre-existing mooGMX share");

        // ---- stake (solvency-gated) ----
        _wrapSolventExpectSuccess(abi.encodeWithSelector(IBeefyFacet.stakeGmxBeefy.selector, STAKE_GMX));
        uint256 moo = IERC20(MOO_GMX).balanceOf(loan);
        assertGt(moo, 0, "stake minted no mooGMX shares");
        assertEq(IERC20(GMX).balanceOf(loan), 0, "stake did not consume the funded GMX");
        assertTrue(_ownsAsset(SYM_MOO_GMX), "MOO_GMX not registered as an owned asset after stake");

        uint256 gmxBeforeUnstake = IERC20(GMX).balanceOf(loan);

        // ---- unstake the full vault-share balance back to GMX (live facet checks isSolvent on
        //      exit → wrapped with a RedStone payload) ----
        _wrapSolventExpectSuccess(abi.encodeWithSelector(IBeefyFacet.unstakeGmxBeefy.selector, moo));

        // GMX principal came back and the mooGMX vault shares were fully burned.
        assertEq(IERC20(MOO_GMX).balanceOf(loan), 0, "mooGMX shares not drained by unstake");
        uint256 gmxReturned = IERC20(GMX).balanceOf(loan);
        assertGt(gmxReturned, gmxBeforeUnstake, "GMX not returned to the PA on unstake");
        // Same-block deposit→withdraw: returned GMX ~ the staked principal (any Beefy entrance/
        // withdraw fee is well within 5%). Proves the real principal returned, not dust.
        assertGt(gmxReturned, (gmxFunded * 95) / 100, "returned GMX far below staked principal");
        assertApproxEqRel(gmxReturned, gmxFunded, 0.05e18, "returned GMX deviates from staked principal");
    }
}
