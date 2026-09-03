// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumGmxForkFixture} from "../fixtures/ArbitrumGmxForkFixture.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {GmxKeeperSim} from "../helpers/gmx/GmxKeeperSim.sol";
import {
    IGmxDataStore,
    IGmxOracleHolder,
    IChainlinkDataStreamProvider
} from "../helpers/gmx/IGmxArb.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * SP5 GMX deposit lifecycle (Arbitrum live-diamond fork). Gated — SKIPS under the
 * default test config (RUN_GMX_FORK=true + arbitrum chain config required).
 *
 * Coverage:
 *   - T1 spike: fixture attaches, cuts the signer-override solvency facet, creates a
 *     Prime Account, funds it with real WETH.
 *   - T3: a GM deposit is CREATED — the GMX order lands, the account freezes, and a
 *     second request is rejected while frozen.
 *   - T4 (crown jewel): a simulated GMX keeper EXECUTES the queued deposit, driving the
 *     real `afterDepositExecution` callback into our diamond — GM minted, account
 *     unfrozen, GM exposure synced. First-ever end-to-end coverage of the async
 *     create→keeper-execute→callback lifecycle.
 */
contract GmxDepositLifecycleTest is ArbitrumGmxForkFixture {
    // 0.1 WETH (long side) deposit. minGm kept low so GMX mints comfortably more than
    // this at execution (T4) — at create time minGm only needs to be > 0 (the fixture
    // sizes the RedStone GM price so isWithinBounds always passes).
    uint256 internal constant DEPOSIT_WETH = 0.1 ether;
    uint256 internal constant MIN_GM = 50e18;

    function testFixtureFundsAccount() public {
        // funded in setUp; assert collateral present
        assertGt(SmartLoanViewFacet(loan).getBalance(bytes32("ETH")), 0, "ETH collateral not funded");
    }

    function testCreateDepositFreezesAccount() public {
        assertEq(_accountFrozenSince(), 0, "account unexpectedly frozen before deposit");

        bytes32 key = _createGmDeposit(true /* long = WETH */, DEPOSIT_WETH, MIN_GM);
        assertTrue(key != bytes32(0), "GMX deposit key is zero");

        // The Prime Account freezes for the duration of the in-flight async request.
        assertGt(_accountFrozenSince(), 0, "account not frozen after deposit creation");

        // While frozen, a second GMX request is rejected at the freeze guard
        // ("Account is already frozen") — the whole create reverts and rolls back.
        (bool ok, bytes memory ret) = _createGmDepositRaw(true, DEPOSIT_WETH, MIN_GM);
        assertFalse(ok, "second deposit must revert while account is frozen");
        assertEq(_revertReason(ret), "Account is already frozen", "unexpected frozen revert reason");
    }

    function testDepositExecutedByKeeperFiresCallback() public {
        bytes32 key = _createGmDeposit(true /* long = WETH */, DEPOSIT_WETH, MIN_GM);
        assertGt(_accountFrozenSince(), 0, "account should be frozen after create");
        uint256 gmBefore = IERC20(GM_ETH_WETH_USDC).balanceOf(loan);

        // ---- simulate the GMX keeper executing the deposit in a separate "tx" ----
        GmxKeeperSim.etchPrecompiles(vm);
        // Market deposits execute with prices stamped AFTER creation; stay well within the
        // 5-minute cached-price window our callback enforces.
        vm.warp(block.timestamp + 1);

        address oracle = IGmxOracleHolder(GmxKeeperSim.DEPOSIT_HANDLER).oracle();
        address provWeth = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, WETH);
        address provUsdc = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, USDC);
        assertTrue(provWeth != address(0) && provWeth == provUsdc, "unexpected oracle provider config");

        // GMX oracle prices are per-token, scaled by 10^(30 - tokenDecimals). Feed a real
        // ETH price (WETH 18-dec → ×1e12) and $1 USDC (6-dec → ×1e24). min==max is fine —
        // isChainlinkOnChainProvider→true skips the ref-deviation check.
        //   realUSD = ethUsd8 / 1e8 ; wethGmxPrice = realUSD * 1e12 = ethUsd8 * 1e12 / 1e8
        uint256 wethGmxPrice = (_liveEthUsd8() * 1e12) / 1e8;
        uint256 usdcGmxPrice = 1e24;

        // Prices mocked AFTER the warp so the ValidatedPrice timestamp == block.timestamp.
        GmxKeeperSim.mockPrice(vm, provWeth, WETH, wethGmxPrice);
        GmxKeeperSim.mockPrice(vm, provUsdc, USDC, usdcGmxPrice);
        // Skip GMX's Chainlink ref-price deviation + timestamp adjustment paths so our
        // synthetic min==max prices are accepted as-is.
        vm.mockCall(provWeth, abi.encodeWithSelector(IChainlinkDataStreamProvider.isChainlinkOnChainProvider.selector), abi.encode(true));
        vm.mockCall(provWeth, abi.encodeWithSelector(IChainlinkDataStreamProvider.shouldAdjustTimestamp.selector), abi.encode(false));

        address[] memory tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        address[] memory providers = new address[](2);
        providers[0] = provWeth;
        providers[1] = provUsdc;

        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);

        // ---- afterDepositExecution callback effects on OUR Prime Account ----
        // (GMX swallows a reverting callback as AfterDepositExecutionError, so these
        // post-state assertions — not mere tx success — prove the callback actually ran.)
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the callback");
        assertGt(IERC20(GM_ETH_WETH_USDC).balanceOf(loan), gmBefore, "GM tokens not minted to the PA");
        assertTrue(_ownsAsset(SYM_GM_ETH), "GM market not synced into owned assets");
    }
}
