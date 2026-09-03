// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheGmxForkFixture} from "../../fixtures/AvalancheGmxForkFixture.sol";
import {GmxKeeperSim} from "../../helpers/gmx/GmxKeeperSim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * SP6 W1 — GMX normal-GM DEPOSIT lifecycle (Avalanche live-diamond fork). Gated — SKIPS
 * under the default test config (RUN_GMX_FORK=true + avalanche chain config required).
 *
 * The Avalanche counterpart of the proven Arbitrum {GmxDepositLifecycleTest}. The Avax GMX
 * async path was never tested before — this is the first-ever end-to-end coverage of the
 * create -> keeper-execute -> `afterDepositExecution` callback lifecycle on Avalanche.
 *
 * Coverage:
 *   - testCreateDepositFreezesAccount: a GM deposit is CREATED on the live AVAX/USDC GM
 *     market — the GMX order lands, the account freezes, and a second request is rejected
 *     while frozen ("Account is already frozen").
 *   - testDepositExecutedByKeeperFiresCallback (the headline): a simulated GMX keeper
 *     EXECUTES the queued deposit (NO ArbSys/ArbGasInfo etch on Avax), driving the real
 *     `afterDepositExecution` callback into our diamond — GM minted (STRICT increase, which
 *     distinguishes an execute from a cancel), account unfrozen, GM exposure synced.
 *
 * Swallowed-revert-aware: GMX wraps a reverting callback as AfterDepositExecutionError and
 * still mints the GM, so tx success alone proves nothing. The load-bearing proof the callback
 * ran is the UNFREEZE (frozenSince == 0, the swallowed-revert sentinel) + the GM-balance
 * increase + the owned-asset sync — all asserted on post-state, never bare no-revert.
 */
contract GmxDepositLifecycleTest is AvalancheGmxForkFixture {
    // 2 WAVAX (long side) deposit. AVAX is cheap (~$6.77) so a couple native clears a low minGm
    // comfortably at execution; minGm kept at 1 GM so GMX mints well above it (the fixture sizes
    // the RedStone GM price so create-side isWithinBounds always passes at its centre).
    //
    // The deposit MUST stay below half the funded collateral (FUND_AMOUNT = 5 WAVAX): the facet
    // caps `tokenAmount` to the account's CURRENT balance, so after the first deposit escrows its
    // WAVAX, a second deposit of the SAME size would be silently capped to the (smaller) leftover
    // balance — that capped amount no longer matches the RedStone-sized GM price and the create
    // reverts InvalidMinOutputValue (isWithinBounds, line 104) BEFORE reaching the freeze guard
    // (freezeAccount, line 125). At 2 WAVAX the 3 WAVAX leftover still exceeds the deposit, so the
    // second create is NOT capped and reaches the freeze guard as intended ("Account is already
    // frozen"). (On Arbitrum this is incidental — its 0.1 WETH deposit is already << its funded
    // balance; on Avax it must be deliberate.)
    uint256 internal constant DEPOSIT_WAVAX = 2 ether;
    uint256 internal constant MIN_GM = 1e18;

    function testCreateDepositFreezesAccount() public {
        assertEq(_accountFrozenSince(), 0, "account unexpectedly frozen before deposit");

        bytes32 key = _createGmDeposit(true /* long = WAVAX */, DEPOSIT_WAVAX, MIN_GM);
        assertTrue(key != bytes32(0), "GMX deposit key is zero");

        // The Prime Account freezes for the duration of the in-flight async request.
        assertGt(_accountFrozenSince(), 0, "account not frozen after deposit creation");

        // While frozen, a second GMX request is rejected at the freeze guard
        // ("Account is already frozen") — the whole create reverts and rolls back.
        (bool ok, bytes memory ret) = _createGmDepositRaw(true, DEPOSIT_WAVAX, MIN_GM);
        assertFalse(ok, "second deposit must revert while account is frozen");
        assertEq(_revertReason(ret), "Account is already frozen", "unexpected frozen revert reason");
    }

    function testDepositExecutedByKeeperFiresCallback() public {
        bytes32 key = _createGmDeposit(true /* long = WAVAX */, DEPOSIT_WAVAX, MIN_GM);
        assertGt(_accountFrozenSince(), 0, "account should be frozen after create");
        uint256 gmBefore = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);

        // ---- simulate the GMX keeper executing the deposit in a separate "tx" ----
        // NO precompile etch on Avalanche (chainid 43114 → GMX reads block.number natively).
        // Market deposits execute with prices stamped AFTER creation; stay well within the
        // 5-minute cached-price window our callback enforces.
        vm.warp(block.timestamp + 1);
        // Mock the AVAX GMX oracle provider at the live AVAX price + $1 USDC, and skip the
        // Chainlink-ref-deviation + timestamp-adjust paths (isChainlinkOnChainProvider→true /
        // shouldAdjustTimestamp→false) so our synthetic min==max prices are accepted as-is.
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPrices();
        GmxKeeperSim.executeDepositAvax(vm, key, tokens, providers);

        // ---- afterDepositExecution callback effects on OUR Prime Account ----
        // (GMX swallows a reverting callback as AfterDepositExecutionError, so these
        // post-state assertions — not mere tx success — prove the callback actually ran.)
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the callback");
        // STRICT increase: distinguishes a real execution (GM minted) from a cancellation
        // (which would refund the deposited token and mint NO GM).
        assertGt(IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan), gmBefore, "GM tokens not minted to the PA");
        assertTrue(_ownsAsset(SYM_GM_AVAX), "GM market not synced into owned assets");
    }
}
