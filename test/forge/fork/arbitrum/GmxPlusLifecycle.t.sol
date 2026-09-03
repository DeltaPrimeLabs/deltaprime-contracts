// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumGmxForkFixture} from "../../fixtures/ArbitrumGmxForkFixture.sol";
import {GmxKeeperSim} from "../../helpers/gmx/GmxKeeperSim.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {
    IGmxDataStore,
    IGmxOracleHolder,
    IChainlinkDataStreamProvider
} from "../../helpers/gmx/IGmxArb.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal view of the single-token "Plus" GM entrypoints on GmxV2PlusFacetArbitrum.
///      The ETH Plus market is single-asset: longToken == shortToken == WETH, so a deposit sends
///      `tokenAmount/2` of WETH twice and a withdrawal returns WETH as both legs.
interface IGmxPlusFacetArb {
    function depositEthGmxV2Plus(uint256 tokenAmount, uint256 minGmAmount, uint256 executionFee)
        external
        payable;
    function withdrawEthGmxV2Plus(
        uint256 gmAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;
}

interface ITokenManagerPlusView {
    function getAllPoolAssets() external view returns (bytes32[] memory);
    function tokenAddressToSymbol(address) external view returns (bytes32);
}

/**
 * SP6 W2 — GMX V2 **PLUS** (single-token GM) lifecycle (Arbitrum live-diamond fork). Gated —
 * SKIPS under the default test config (RUN_GMX_FORK=true + ARBITRUM_RPC_URL + arbitrum chain
 * config required).
 *
 * First-ever end-to-end coverage of the GMX V2 *Plus* async path on Arbitrum. "Plus" markets are
 * single-asset GM pools where longToken == shortToken (here both WETH). The deposit splits the
 * supplied `tokenAmount` into two equal `tokenAmount/2` halves and escrows both as the same token
 * (GmxV2PlusFacet._deposit L67-75); the callback is the SAME GmxV2CallbacksFacet
 * `afterDepositExecution`/`afterWithdrawalExecution` (already wired live on the beacon), which
 * detects the Plus market via `isGmxPlusMarket` and forces the short-token price to 0 to avoid
 * double-counting (GmxV2FeesHelper L141).
 *
 * Differences from the proven SP5 normal-GM lifecycle:
 *   - Entrypoint is `depositEthGmxV2Plus`/`withdrawEthGmxV2Plus` on the Plus facet (0x736D70bA),
 *     market GM_ETH_WETH (single-token, NOT the ETH/USDC two-token market).
 *   - The unified price fetch requests only [GM_PLUS_symbol, ETH] (no USDC — the short side IS
 *     WETH), so the wrapped RedStone create payload carries getAllPoolAssets() ∪ {GM_PLUS_symbol}
 *     and the keeper execution mocks only the single WETH oracle price (tokens=[WETH]).
 *   - Arbitrum keeper sim: etchPrecompiles (ArbSys/ArbGasInfo) + the Arbitrum
 *     executeDeposit/executeWithdrawal (NOT the Avax variants).
 *
 * Swallowed-revert-aware: GMX wraps a reverting callback as AfterDepositExecutionError and still
 * mints the GM, so tx success alone proves nothing. The load-bearing proof the callback ran is
 * the UNFREEZE (frozenSince == 0) + the GM-balance STRICT increase (distinguishes execute from
 * cancel) + the owned-asset sync — all asserted on post-state, never bare no-revert.
 */
contract GmxPlusLifecycleTest is ArbitrumGmxForkFixture {
    // The single-token ETH Plus GM market (long == short == WETH). Whitelisted plus=true live.
    address internal constant GM_ETH_WETH_PLUS = 0x450bb6774Dd8a756274E0ab4107953259d2ac541;

    // 0.1 WETH deposit (sent as 0.05 + 0.05). minGm kept low (1 GM) so GMX mints comfortably
    // above it at execution — guarantees an EXECUTE (mint) rather than a MinMarketTokens cancel.
    uint256 internal constant DEPOSIT_WETH = 0.1 ether;
    uint256 internal constant MIN_GM = 1e18;

    function testPlusDepositExecutedFiresCallback() public {
        assertEq(_accountFrozenSince(), 0, "account unexpectedly frozen before deposit");

        bytes32 key = _createPlusDeposit(DEPOSIT_WETH, MIN_GM);
        assertTrue(key != bytes32(0), "GMX Plus deposit key is zero");
        // The Prime Account freezes for the duration of the in-flight async request.
        assertGt(_accountFrozenSince(), 0, "account not frozen after Plus deposit creation");

        uint256 gmBefore = IERC20(GM_ETH_WETH_PLUS).balanceOf(loan);

        // ---- simulate the GMX keeper executing the deposit in a separate "tx" ----
        // Arbitrum needs the ArbSys/ArbGasInfo precompile etch. Single-token market → mock ONLY WETH.
        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1);
        (address[] memory tokens, address[] memory providers) = _mockPlusKeeperPrices();
        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);

        // ---- afterDepositExecution callback effects on OUR Prime Account ----
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the callback");
        // STRICT increase: a real execution mints GM (a cancellation would refund WETH, no GM).
        assertGt(IERC20(GM_ETH_WETH_PLUS).balanceOf(loan), gmBefore, "GM-Plus tokens not minted to the PA");
        assertTrue(_ownsAsset(_plusGmSymbol()), "GM-Plus market not synced into owned assets");
    }

    function testPlusWithdrawalExecuted() public {
        // 1) establish a real GM-Plus position via deposit + keeper-execute.
        bytes32 dkey = _createPlusDeposit(DEPOSIT_WETH, MIN_GM);
        assertGt(_accountFrozenSince(), 0, "account should be frozen after deposit create");
        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1);
        {
            (address[] memory dt, address[] memory dp) = _mockPlusKeeperPrices();
            GmxKeeperSim.executeDeposit(vm, dkey, dt, dp);
        }
        assertEq(_accountFrozenSince(), 0, "account should be unfrozen after deposit-execute");
        uint256 gmHeld = IERC20(GM_ETH_WETH_PLUS).balanceOf(loan);
        assertGt(gmHeld, 0, "no GM-Plus position to withdraw");

        uint256 wethBefore = IERC20(WETH).balanceOf(loan);

        // 2) create a partial GM-Plus withdrawal. minLong/minShort kept tiny (both WETH legs) so
        //    the keeper execution fills; create-side isWithinBounds passes at its centre. The
        //    account re-freezes for the in-flight request.
        uint256 minLeg = 0.0001 ether; // a sliver of WETH per leg
        bytes32 wkey = _createPlusWithdrawal(gmHeld / 2, minLeg, minLeg);
        assertTrue(wkey != bytes32(0), "GMX Plus withdrawal key is zero");
        assertGt(_accountFrozenSince(), 0, "account not frozen after Plus withdrawal create");

        // 3) simulate the keeper executing the withdrawal.
        vm.warp(block.timestamp + 1);
        (address[] memory wt, address[] memory wp) = _mockPlusKeeperPrices();
        GmxKeeperSim.executeWithdrawal(vm, wkey, wt, wp);

        // ---- afterWithdrawalExecution callback effects ----
        // GM left the loan (escrowed to the withdrawal vault at create, then burned by GMX) and
        // the single underlying token (WETH) is returned. The unfreeze is the load-bearing proof
        // the callback ran (a swallowed callback would leave the account frozen even though GMX
        // returned the tokens). Compare against the pre-create position, like the SP5 normal test.
        assertLt(IERC20(GM_ETH_WETH_PLUS).balanceOf(loan), gmHeld, "GM-Plus not burned by withdrawal");
        assertGt(IERC20(WETH).balanceOf(loan), wethBefore, "single token (WETH) not returned");
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the withdrawal callback");
        assertTrue(_ownsAsset(SYM_ETH), "WETH (returned leg) not synced into owned assets");
    }

    // ---------------------------------------------------------------------------
    // Plus-specific create helpers (single-token market + Plus GM symbol feed set)
    // ---------------------------------------------------------------------------

    /// @dev TokenManager symbol for the single-token Plus GM market, discovered on-fork.
    function _plusGmSymbol() internal view returns (bytes32 sym) {
        sym = ITokenManagerPlusView(TOKEN_MANAGER).tokenAddressToSymbol(GM_ETH_WETH_PLUS);
        require(sym != bytes32(0), "fixture: GM-Plus market has no TokenManager symbol");
    }

    /// @notice The RedStone feed set the wrapped Plus create call must carry:
    ///         getAllPoolAssets() ∪ {GM_PLUS_symbol}. Mirrors the fixture's `_depositFeedSet`
    ///         but substitutes the single-token Plus GM symbol (the unified price fetch requests
    ///         only [GM_PLUS, ETH]; the rest cover the owned-asset + zero-debt pool reads).
    function _plusFeedSet(uint256 gmPrice8)
        internal
        view
        returns (bytes32[] memory feeds, uint256[] memory vals)
    {
        bytes32[] memory pool = ITokenManagerPlusView(TOKEN_MANAGER).getAllPoolAssets();
        feeds = new bytes32[](pool.length + 1);
        vals = new uint256[](pool.length + 1);
        for (uint256 i = 0; i < pool.length; i++) {
            feeds[i] = pool[i];
            if (pool[i] == SYM_ETH) vals[i] = ETH_PRICE_8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8; // nominal — zero debt nulls the contribution
        }
        feeds[pool.length] = _plusGmSymbol();
        vals[pool.length] = gmPrice8;
    }

    function _createPlusDeposit(uint256 tokenAmount, uint256 minGm) internal returns (bytes32 key) {
        (bool ok, bytes memory ret) = _createPlusDepositRaw(tokenAmount, minGm);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractDepositKey();
        require(key != bytes32(0), "fixture: GMX Plus deposit key not found in logs");
    }

    function _createPlusDepositRaw(uint256 tokenAmount, uint256 minGm)
        internal
        returns (bool ok, bytes memory ret)
    {
        require(minGm > 0, "fixture: minGm must be > 0 (isWithinBounds rejects 0)");
        // Plus deposit-side isWithinBounds: depositUSD = longTokenPrice * tokenAmount / 1e18
        // (WETH 18-dec, FULL amount), minGmUSD = minGm * gmPrice / 1e18 (GM 18-dec). Size the GM
        // price so minGmUSD == depositUSD exactly (the bound's centre).
        uint256 depositUsd8 = (ETH_PRICE_8 * tokenAmount) / 1e18;
        uint256 gmPrice8 = (depositUsd8 * 1e18) / minGm;
        require(gmPrice8 > 0, "fixture: GM price rounds to zero");

        (bytes32[] memory feeds, uint256[] memory vals) = _plusFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxPlusFacetArb.depositEthGmxV2Plus.selector,
            tokenAmount,
            minGm,
            GMX_EXECUTION_FEE
        );

        vm.deal(user, GMX_EXECUTION_FEE);
        vm.recordLogs();
        vm.prank(user);
        (ok, ret) = loan.call{value: GMX_EXECUTION_FEE}(bytes.concat(callData, payload));
    }

    function _createPlusWithdrawal(uint256 gmAmount, uint256 minLong, uint256 minShort)
        internal
        returns (bytes32 key)
    {
        (bool ok, bytes memory ret) = _createPlusWithdrawalRaw(gmAmount, minLong, minShort);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractWithdrawalKey();
        require(key != bytes32(0), "fixture: GMX Plus withdrawal key not found in logs");
    }

    function _createPlusWithdrawalRaw(uint256 gmAmount, uint256 minLong, uint256 minShort)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 bal = IERC20(GM_ETH_WETH_PLUS).balanceOf(loan);
        uint256 effGm = gmAmount > bal ? bal : gmAmount; // facet caps to balance; mirror it here
        require(effGm > 0, "fixture: no GM-Plus balance to withdraw");

        // Plus withdraw-side isWithinBounds uses longTokenPrice for BOTH legs (short == long ==
        // WETH, both 18-dec). outUSD = ETH_PRICE_8 * (minLong + minShort) / 1e18.
        uint256 outUsd8 = (ETH_PRICE_8 * minLong) / 1e18 + (ETH_PRICE_8 * minShort) / 1e18;
        require(outUsd8 > 0, "fixture: zero min-output value (isWithinBounds needs > 0)");

        uint256 gmPrice8 = (outUsd8 * 1e18) / effGm; // isWithinBounds centre
        require(gmPrice8 > 0, "fixture: GM price rounds to zero - raise the min outputs");

        (bytes32[] memory feeds, uint256[] memory vals) = _plusFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxPlusFacetArb.withdrawEthGmxV2Plus.selector,
            gmAmount,
            minLong,
            minShort,
            GMX_EXECUTION_FEE
        );

        vm.deal(user, GMX_EXECUTION_FEE);
        vm.recordLogs();
        vm.prank(user);
        (ok, ret) = loan.call{value: GMX_EXECUTION_FEE}(bytes.concat(callData, payload));
    }

    // ---------------------------------------------------------------------------
    // Plus-specific keeper-price mock (single underlying token: WETH only)
    // ---------------------------------------------------------------------------

    /// @notice Mock the GMX oracle provider for WETH (the sole token in the Plus market) at the
    ///         live ETH price and skip the Chainlink-ref-deviation + timestamp-adjust paths so the
    ///         keeper execution accepts our synthetic min==max price. Returns the single-entry
    ///         tokens[]/providers[] arrays the handler expects. Call AFTER any vm.warp.
    function _mockPlusKeeperPrices()
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address oracle = IGmxOracleHolder(GmxKeeperSim.DEPOSIT_HANDLER).oracle();
        address provWeth = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, WETH);
        require(provWeth != address(0), "fixture: no GMX provider for WETH");

        // GMX price scaled by 10^(30 - 18) = 1e12 for WETH.
        GmxKeeperSim.mockPrice(vm, provWeth, WETH, (_liveEthUsd8() * 1e12) / 1e8);
        vm.mockCall(
            provWeth,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.isChainlinkOnChainProvider.selector),
            abi.encode(true)
        );
        vm.mockCall(
            provWeth,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.shouldAdjustTimestamp.selector),
            abi.encode(false)
        );

        tokens = new address[](1);
        tokens[0] = WETH;
        providers = new address[](1);
        providers[0] = provWeth;
    }
}
