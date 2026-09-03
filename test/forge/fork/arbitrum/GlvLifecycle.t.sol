// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {Vm} from "forge-std/Vm.sol";
import {ArbitrumGmxForkFixture} from "../../fixtures/ArbitrumGmxForkFixture.sol";
import {GmxKeeperSim} from "../../helpers/gmx/GmxKeeperSim.sol";
import {RedstoneLib} from "../../helpers/RedstoneLib.sol";
import {
    IGmxDataStore,
    IGmxOracleHolder,
    IChainlinkDataStreamProvider
} from "../../helpers/gmx/IGmxArb.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GlvFacetArbitrum} from "../../../../contracts/facets/arbitrum/GlvFacetArbitrum.sol";
import {IDiamondCut} from "../../../../contracts/interfaces/IDiamondCut.sol";

/// @dev GLV deposit/withdraw entrypoints on GlvFacetArbitrum (0xCA96…). Note the EXTRA
///      `targetMarket` arg (selects which GM sub-market the WETH is deposited into) versus the
///      normal-GM entrypoints, and the `minGlvAmount` ordering.
interface IGlvFacetArb {
    function depositWethUsdcGlv(
        bool isLongToken,
        uint256 tokenAmount,
        uint256 minGlvAmount,
        address targetMarket,
        uint256 executionFee
    ) external payable;

    function withdrawWethUsdcGlv(
        uint256 glvAmount,
        address targetMarket,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;
}

interface IGlvReaderView {
    struct Props {
        address glvToken;
        address longToken;
        address shortToken;
    }

    struct GlvInfo {
        Props glv;
        address[] markets;
    }

    function getGlvInfo(address dataStore, address glv) external view returns (GlvInfo memory);
}

interface IGmxReaderView {
    struct MarketProps {
        address marketToken;
        address indexToken;
        address longToken;
        address shortToken;
    }

    function getMarket(address dataStore, address key) external view returns (MarketProps memory);
}

interface ITokenManagerGlvView {
    function getAllPoolAssets() external view returns (bytes32[] memory);
    function tokenAddressToSymbol(address) external view returns (bytes32);
    function getChainlinkFeed(address token) external view returns (address);
}

interface IAggregatorV3View {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

interface IGmxDataStoreUint {
    function getUint(bytes32 key) external view returns (uint256);
}

/**
 * SP6 W3 — GMX **GLV** (GMX Liquidity Vault) lifecycle (Arbitrum live-diamond fork). Gated —
 * SKIPS under the default test config (RUN_GMX_FORK=true + ARBITRUM_RPC_URL + arbitrum chain
 * config required). GLV is LIVE ON ARBITRUM ONLY (the Avax beacon has no GLV facet/callbacks).
 *
 * First-ever end-to-end coverage of the GMX V2 GLV async path. A GLV is a vault OF GM tokens:
 * GLV[WETH-USDC] (0x528A…) holds GM tokens across 56 sub-markets, all WETH/USDC-collateralised
 * but with distinct (mostly synthetic) index tokens. This makes GLV the most complex GMX product:
 *
 *   - CREATE (`depositWethUsdcGlv`): wrapped with a test-signer RedStone payload (the facet's
 *     `_getUnifiedGlvTokenPricesAndAddresses` fetches [GLVWETHUSDC, ETH, USDC]; the solvency sim
 *     adds the owned-asset + zero-debt pool reads), routed through the GlvRouter multicall. The
 *     account freezes; isMarketTokenDeposit=false so WETH is deposited into a chosen `targetMarket`
 *     GM sub-market, GMX mints GM into the GLV, and the GLV mints GLV tokens to the receiver (loan).
 *     NB GlvFacet does NOT call increasePendingExposure (only _syncExposure) — but freeze still happens.
 *
 *   - EXECUTE (keeper `executeGlvDeposit` on the GlvHandler 0x7492…): because GLV execution VALUES
 *     THE ENTIRE VAULT, the keeper oracle params must carry a price for EVERY token across ALL 56
 *     sub-markets — WETH + USDC + 55 index tokens. We discover the market set on-fork (GlvReader →
 *     GmxReader), dedup+sort the token union, resolve each token's GMX oracle provider (all share
 *     the one ChainlinkDataStreamProvider 0xE1d5a068…), and mock `getOraclePrice` per token. WETH +
 *     USDC (the shared collateral) get live prices; each synthetic index token gets a PER-MARKET
 *     price (see `_indexPrice`) chosen so that sub-market's pool value stays POSITIVE — a flat
 *     nominal price overprices the cheap synthetics by orders of magnitude and reverts
 *     `GlvNegativeMarketPoolValue`. We derive that price from on-chain market state: the net-zero
 *     trader-PnL price, capped so the position-impact-pool (held in index tokens, subtracted from
 *     pool value) stays ≤ 25% of collateral.
 *
 * Swallowed-revert-aware: GMX wraps a reverting callback as AfterGlvDepositExecutionError and still
 * mints the GLV, so tx success alone proves nothing. The load-bearing proof the
 * `afterGlvDepositExecution` callback ran is the UNFREEZE (frozenSince == 0) + the GLV-balance
 * STRICT increase + the owned-asset sync — all asserted on post-state.
 */
interface ITMExposureView {
    function pendingUserExposure(address user, bytes32 assetIdentifier) external view returns (uint256);
    function tokenAddressToSymbol(address token) external view returns (bytes32);
}

contract GlvLifecycleTest is ArbitrumGmxForkFixture {
    // GLV[WETH-USDC] token + its TokenManager symbol (whitelisted live).
    address internal constant GLV_WETH_USDC = 0x528A5bac7E746C9A509A1f4F6dF58A03d44279F9;
    bytes32 internal constant SYM_GLV = bytes32("GLVWETHUSDC");

    // The ETH/USDC GM sub-market (markets[0] of the GLV; index == WETH). Whitelisted as a GMX
    // market live (the SP5 normal-GM test deposits into this exact market).
    address internal constant TARGET_MARKET = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    // GMX/GLV readers (arbitrum chain config; same DataStore as GmxKeeperSim.DATA_STORE).
    address internal constant GMX_READER = 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789;
    address internal constant GLV_READER = 0x2C670A23f1E798184647288072e84054938B5497;

    // 0.1 WETH long-token deposit. The GLV token is priced via its Chainlink feed (NOT the RedStone
    // payload — `getPricesFromRedstoneAndChainlink` prefers Chainlink for non-borrowable assets that
    // have a feed configured), so `minGlv` is anchored to the live Chainlink GLV price and sized at
    // 96% of the create-side deposit USD value to land inside `isWithinBounds` [95%,105%].
    //
    // We value the create-side deposit at a deliberately LOW deterministic ETH price ($300, vs the
    // live ~$2.5k used at execution). Why: our keeper-sim prices each GLV sub-market at a
    // PnL-neutral / impact-capped value (so no pool value goes negative — see `_indexPrice`), which
    // values the whole vault somewhat HIGHER than the live GLV feed → GMX's GLV price is higher →
    // it mints FEWER GLV per deposited dollar than the feed implies. Anchoring `minGlv` to the feed
    // at the full live deposit value would then exceed the minted amount (a MinGlvTokens cancel).
    // Sizing the create against a low deposit USD keeps `minGlv` (~26 GLV) far below the ~150+ GLV
    // GMX actually mints (deposit valued at the live ETH price), guaranteeing an EXECUTE. This only
    // touches the create-side bookkeeping; the GMX execution uses the keeper-sim's own (live-ETH)
    // mocked prices, independent of this value.
    uint256 internal constant DEPOSIT_WETH = 0.1 ether;
    uint256 internal constant GLV_CREATE_ETH_8 = 300e8; // low deterministic create-side ETH price
    uint256 internal constant MIN_GLV_BPS = 9600; // 96% of the (low) create-side deposit USD value

    /// @dev Replace-cut a freshly-compiled GlvFacetArbitrum so withdrawWethUsdcGlv carries the
    ///      DPSC-459 pending-exposure reservation (the forked diamond otherwise runs the deployed
    ///      facet). depositWethUsdcGlv stays on the live facet; both share diamond storage.
    function setUp() public override {
        super.setUp();
        if (loan == address(0)) return; // fork not active (gated test skipped in super.setUp)

        bytes4[] memory sels = new bytes4[](2);
        sels[0] = IGlvFacetArb.withdrawWethUsdcGlv.selector;
        sels[1] = IGlvFacetArb.depositWethUsdcGlv.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new GlvFacetArbitrum()), IDiamondCut.FacetCutAction.Replace, sels
        );

        (address owner_, address pauseAdmin_) = _beaconAdmins();
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).pause();
        vm.prank(owner_);
        IDiamondCut(BEACON).diamondCut(cuts, address(0), "");
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).unpause();
    }

    function testGlvDepositExecutedFiresCallback() public {
        assertEq(_accountFrozenSince(), 0, "account unexpectedly frozen before GLV deposit");

        bytes32 key = _createGlvDeposit(DEPOSIT_WETH);
        assertTrue(key != bytes32(0), "GLV deposit key is zero");
        // The Prime Account freezes for the duration of the in-flight async GLV request.
        assertGt(_accountFrozenSince(), 0, "account not frozen after GLV deposit creation");

        uint256 glvBefore = IERC20(GLV_WETH_USDC).balanceOf(loan);

        // ---- simulate the GMX keeper executing the GLV deposit in a separate "tx" ----
        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1); // GLV deposit executes with prices stamped after create
        (address[] memory tokens, address[] memory providers) = _mockGlvKeeperPrices();
        GmxKeeperSim.executeGlvDeposit(vm, key, tokens, providers);

        // ---- afterGlvDepositExecution callback effects on OUR Prime Account ----
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the GLV callback");
        // STRICT increase: a real execution mints GLV tokens (a cancellation would refund WETH).
        assertGt(IERC20(GLV_WETH_USDC).balanceOf(loan), glvBefore, "GLV tokens not minted to the PA");
        assertTrue(_ownsAsset(SYM_GLV), "GLV not synced into owned assets");
    }

    function testGlvWithdrawalExecuted() public {
        // 1) establish a real GLV position via deposit + keeper-execute.
        bytes32 dkey = _createGlvDeposit(DEPOSIT_WETH);
        assertGt(_accountFrozenSince(), 0, "account should be frozen after GLV deposit create");
        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1);
        {
            (address[] memory dt, address[] memory dp) = _mockGlvKeeperPrices();
            GmxKeeperSim.executeGlvDeposit(vm, dkey, dt, dp);
        }
        assertEq(_accountFrozenSince(), 0, "account should be unfrozen after GLV deposit-execute");
        uint256 glvHeld = IERC20(GLV_WETH_USDC).balanceOf(loan);
        assertGt(glvHeld, 0, "no GLV position to withdraw");

        uint256 wethBefore = IERC20(WETH).balanceOf(loan);
        uint256 usdcBefore = IERC20(USDC).balanceOf(loan);

        // 2) create a partial GLV withdrawal. The min-out legs are sized internally (split
        //    ~48%/48% WETH/USDC of the GLV value at the live prices) so create-side isWithinBounds
        //    passes and the keeper execution fills each leg. Account re-freezes.
        bytes32 wkey = _createGlvWithdrawal(glvHeld / 2);
        assertTrue(wkey != bytes32(0), "GLV withdrawal key is zero");
        assertGt(_accountFrozenSince(), 0, "account not frozen after GLV withdrawal create");

        // 3) simulate the keeper executing the GLV withdrawal.
        vm.warp(block.timestamp + 1);
        (address[] memory wt, address[] memory wp) = _mockGlvKeeperPrices();
        GmxKeeperSim.executeGlvWithdrawal(vm, wkey, wt, wp);

        // ---- afterGlvWithdrawalExecution callback effects ----
        // GLV left the loan (escrowed to the withdrawal vault at create, then burned by GMX) and
        // the underlying WETH+USDC legs are returned. The unfreeze is the load-bearing proof the
        // callback ran. Compare GLV against the pre-create position (it leaves at create).
        assertLt(IERC20(GLV_WETH_USDC).balanceOf(loan), glvHeld, "GLV not burned by withdrawal");
        assertTrue(
            IERC20(WETH).balanceOf(loan) > wethBefore || IERC20(USDC).balanceOf(loan) > usdcBefore,
            "no underlying (WETH/USDC) returned by GLV withdrawal"
        );
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the GLV withdrawal callback");
    }

    /// @notice DPSC-459 (symmetry with GmxV2Facet._deposit): a GLV deposit must reserve pending
    ///         exposure for the GLV token GMX will mint asynchronously. The deposit
    ///         execution/cancellation callbacks already clear it via _handleDeposit*.
    function testGlvDepositReservesPendingExposure() public {
        ITMExposureView tm = ITMExposureView(TOKEN_MANAGER);
        uint256 glvBefore = tm.pendingUserExposure(loan, SYM_GLV);

        // Create the deposit (reserves pending) but do NOT keeper-execute (which would clear it).
        bytes32 dkey = _createGlvDeposit(DEPOSIT_WETH);
        assertTrue(dkey != bytes32(0), "GLV deposit not created");

        assertGt(tm.pendingUserExposure(loan, SYM_GLV), glvBefore, "GLV-token pending exposure not reserved on deposit");
    }

    /// @notice HackenProof DPSC-459: a GLV withdrawal must reserve pending exposure for the
    ///         ETH/USDC it will receive asynchronously, exactly as GmxV2Facet._withdraw does.
    ///         Without it an over-cap GLV withdrawal passes initiation and the settlement
    ///         callback's exposure sync can revert, leaving the account frozen.
    function testGlvWithdrawalReservesPendingExposure() public {
        // 1) establish a real GLV position.
        bytes32 dkey = _createGlvDeposit(DEPOSIT_WETH);
        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1);
        {
            (address[] memory dt, address[] memory dp) = _mockGlvKeeperPrices();
            GmxKeeperSim.executeGlvDeposit(vm, dkey, dt, dp);
        }
        uint256 glvHeld = IERC20(GLV_WETH_USDC).balanceOf(loan);
        assertGt(glvHeld, 0, "no GLV position to withdraw");

        ITMExposureView tm = ITMExposureView(TOKEN_MANAGER);
        bytes32 longSym = tm.tokenAddressToSymbol(WETH);
        bytes32 shortSym = tm.tokenAddressToSymbol(USDC);
        uint256 longBefore = tm.pendingUserExposure(loan, longSym);
        uint256 shortBefore = tm.pendingUserExposure(loan, shortSym);

        // 2) initiate the GLV withdrawal — must reserve pending exposure for both output legs.
        bytes32 wkey = _createGlvWithdrawal(glvHeld / 2);
        assertTrue(wkey != bytes32(0), "GLV withdrawal not created");

        assertGt(tm.pendingUserExposure(loan, longSym), longBefore, "long-token (WETH) pending exposure not reserved");
        assertGt(tm.pendingUserExposure(loan, shortSym), shortBefore, "short-token (USDC) pending exposure not reserved");
    }

    // ---------------------------------------------------------------------------
    // GLV create helpers (mirror the fixture's GM deposit helpers + the extra targetMarket arg)
    // ---------------------------------------------------------------------------

    function _createGlvDeposit(uint256 tokenAmount) internal returns (bytes32 key) {
        (bool ok, bytes memory ret) = _createGlvDepositRaw(tokenAmount);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractGlvDepositKey();
        require(key != bytes32(0), "fixture: GLV deposit key not found in logs");
    }

    function _createGlvDepositRaw(uint256 tokenAmount) internal returns (bool ok, bytes memory ret) {
        // GLV deposit-side isWithinBounds(depositUSD, minGlvUSD): depositUSD = longTokenPrice(ETH) *
        // tokenAmount / 1e18; minGlvUSD = minGlv * glvPrice / 1e18. The GLV price here is the LIVE
        // Chainlink feed value (the facet's getPrices uses Chainlink for the GLV token), which we
        // cannot control via the RedStone payload — so we size `minGlv` instead, against a low
        // deterministic ETH price (see GLV_CREATE_ETH_8) so it stays below the executed mint.
        uint256 depositUsd8 = (GLV_CREATE_ETH_8 * tokenAmount) / 1e18;
        uint256 minGlv = (depositUsd8 * MIN_GLV_BPS * 1e18) / (_glvChainlinkPrice8() * 10000);
        require(minGlv > 0, "fixture: minGlv rounds to zero");

        (bytes32[] memory feeds, uint256[] memory vals) = _glvFeedSetWithEth(GLV_CREATE_ETH_8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGlvFacetArb.depositWethUsdcGlv.selector,
            true, // isLongToken (WETH)
            tokenAmount,
            minGlv,
            TARGET_MARKET,
            GMX_EXECUTION_FEE
        );

        vm.deal(user, GMX_EXECUTION_FEE);
        vm.recordLogs();
        vm.prank(user);
        (ok, ret) = loan.call{value: GMX_EXECUTION_FEE}(bytes.concat(callData, payload));
    }

    /// @notice The live Chainlink GLV price, normalized to 8 decimals — the value the facet's
    ///         `getPricesFromRedstoneAndChainlink` returns for the (non-borrowable, feed-configured)
    ///         GLV token. Read it so we can centre `isWithinBounds` against the real price.
    function _glvChainlinkPrice8() internal view returns (uint256) {
        address feed = ITokenManagerGlvView(TOKEN_MANAGER).getChainlinkFeed(GLV_WETH_USDC);
        require(feed != address(0), "fixture: GLV has no Chainlink feed");
        (, int256 ans,,,) = IAggregatorV3View(feed).latestRoundData();
        require(ans > 0, "fixture: bad GLV feed price");
        uint8 d = IAggregatorV3View(feed).decimals();
        if (d == 8) return uint256(ans);
        return d > 8 ? uint256(ans) / (10 ** (d - 8)) : uint256(ans) * (10 ** (8 - d));
    }

    function _createGlvWithdrawal(uint256 glvAmount) internal returns (bytes32 key) {
        (bool ok, bytes memory ret) = _createGlvWithdrawalRaw(glvAmount);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractGlvWithdrawalKey();
        require(key != bytes32(0), "fixture: GLV withdrawal key not found in logs");
    }

    function _createGlvWithdrawalRaw(uint256 glvAmount) internal returns (bool ok, bytes memory ret) {
        uint256 bal = IERC20(GLV_WETH_USDC).balanceOf(loan);
        uint256 effGlv = glvAmount > bal ? bal : glvAmount; // facet caps to balance; mirror it here
        require(effGlv > 0, "fixture: no GLV balance to withdraw");

        // GLV withdraw-side isWithinBounds(glvUSD, minReceivedUSD): glvUSD = glvPrice * effGlv / 1e18
        // (glvPrice = the LIVE Chainlink GLV feed, uncontrollable); minReceivedUSD = ETH*minLong/1e18
        // + USDC*minShort/1e6. A GLV[WETH-USDC] withdrawal returns ~half value in WETH, half in USDC,
        // so we split the min-out ~48%/48% across the two legs (total ~96% ∈ [95%,105%]) — each leg
        // min staying below the ~50%-of-value GMX actually returns per leg, so the keeper fills.
        // We value the WETH leg at the live ETH price so the create-side leg valuation matches the
        // amount GMX returns (which is priced at the live ETH price too).
        uint256 ethPrice8 = _liveEthUsd8();
        uint256 glvUsd8 = (_glvChainlinkPrice8() * effGlv) / 1e18;
        uint256 legUsd8 = (glvUsd8 * 48) / 100;
        uint256 minLong = (legUsd8 * 1e18) / ethPrice8; // WETH amount (18-dec)
        uint256 minShort = (legUsd8 * 1e6) / USDC_PRICE_8; // USDC amount (6-dec)
        require(minLong > 0 && minShort > 0, "fixture: GLV withdrawal legs round to zero");

        // The withdrawal create's ETH price must equal what we valued minLong at.
        (bytes32[] memory feeds, uint256[] memory vals) = _glvFeedSetWithEth(ethPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGlvFacetArb.withdrawWethUsdcGlv.selector,
            glvAmount,
            TARGET_MARKET,
            minLong,
            minShort,
            GMX_EXECUTION_FEE
        );

        vm.deal(user, GMX_EXECUTION_FEE);
        vm.recordLogs();
        vm.prank(user);
        (ok, ret) = loan.call{value: GMX_EXECUTION_FEE}(bytes.concat(callData, payload));
    }

    /// @notice The RedStone feed set the wrapped GLV create call must carry: just getAllPoolAssets().
    ///         The GLV token itself is priced from its Chainlink feed (not RedStone), so it is NOT in
    ///         the RedStone request — only the long/short (ETH/USDC) of the unified fetch plus the
    ///         owned-asset + zero-debt pool reads of the create-side solvency sim need feeds, and
    ///         those are exactly the pool assets (ETH+USDC are pool assets).
    function _glvFeedSet() internal view returns (bytes32[] memory feeds, uint256[] memory vals) {
        return _glvFeedSetWithEth(ETH_PRICE_8);
    }

    /// @dev {_glvFeedSet} with an explicit "ETH" price (the withdrawal values its WETH min-out leg
    ///      at the live ETH price so the create-side leg valuation matches the amount GMX returns).
    function _glvFeedSetWithEth(uint256 ethPrice8)
        internal
        view
        returns (bytes32[] memory feeds, uint256[] memory vals)
    {
        bytes32[] memory pool = ITokenManagerGlvView(TOKEN_MANAGER).getAllPoolAssets();
        feeds = new bytes32[](pool.length);
        vals = new uint256[](pool.length);
        for (uint256 i = 0; i < pool.length; i++) {
            feeds[i] = pool[i];
            if (pool[i] == SYM_ETH) vals[i] = ethPrice8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8; // nominal — zero debt nulls the contribution
        }
    }

    /// @dev GLV's EventEmitter logs `GlvDepositCreated` via `emitEventLog2(name, key, account,…)`
    ///      → topics = [EventLog2 sig, keccak256("GlvDepositCreated"), key, account].
    function _extractGlvDepositKey() internal returns (bytes32 key) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nameHash = keccak256(bytes("GlvDepositCreated"));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[1] == nameHash) {
                return logs[i].topics[2];
            }
        }
        return bytes32(0);
    }

    function _extractGlvWithdrawalKey() internal returns (bytes32 key) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nameHash = keccak256(bytes("GlvWithdrawalCreated"));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[1] == nameHash) {
                return logs[i].topics[2];
            }
        }
        return bytes32(0);
    }

    // ---------------------------------------------------------------------------
    // GLV keeper price-mock — price EVERY token the vault valuation reads
    // ---------------------------------------------------------------------------

    /// @notice Build + mock the full oracle price set executeGlvDeposit/Withdrawal needs: WETH +
    ///         USDC + every sub-market's index token, deduped and sorted ascending (mirrors the
    ///         proven [WETH<USDC] ordering). All tokens share the one ChainlinkDataStreamProvider,
    ///         so the isChainlinkOnChainProvider/shouldAdjustTimestamp skip-mocks are set once.
    ///         Returns the aligned tokens[]/providers[] arrays the handler expects.
    ///
    /// @dev The hard part of GLV: each sub-market's pool value must stay POSITIVE or GMX reverts
    ///      `GlvNegativeMarketPoolValue`. The shared collateral (WETH/USDC) gets live prices; each
    ///      index token gets its OPEN-INTEREST BREAK-EVEN price (ΣoiUsd / ΣoiTokens over both
    ///      collaterals + both sides), which zeroes the market's net trader PnL so its pool value
    ///      equals collateral (> 0). A flat nominal price overprices the cheap synthetics by orders
    ///      of magnitude and flips net-long pools negative — the OI break-even is the robust,
    ///      data-driven price every market accepts.
    function _mockGlvKeeperPrices()
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address[] memory markets =
            IGlvReaderView(GLV_READER).getGlvInfo(GmxKeeperSim.DATA_STORE, GLV_WETH_USDC).markets;

        uint256 ethPrice = (_liveEthUsd8() * 1e12) / 1e8; // WETH GMX price (×1e12, 18-dec)
        uint256 usdcPrice = 1e24; // USDC GMX price ($1, ×1e24, 6-dec)

        // Collect the deduped (token, price) set: WETH + USDC + every market's index token.
        uint256 cap = markets.length + 2;
        address[] memory tBuf = new address[](cap);
        uint256[] memory pBuf = new uint256[](cap);
        uint256 n;
        (tBuf, pBuf, n) = _put(tBuf, pBuf, n, WETH, ethPrice);
        (tBuf, pBuf, n) = _put(tBuf, pBuf, n, USDC, usdcPrice);
        for (uint256 i = 0; i < markets.length; i++) {
            address idx = IGmxReaderView(GMX_READER).getMarket(GmxKeeperSim.DATA_STORE, markets[i]).indexToken;
            // index==WETH (the ETH/USDC market) keeps the live WETH price already seeded.
            (tBuf, pBuf, n) = _put(tBuf, pBuf, n, idx, _indexPrice(markets[i], ethPrice, usdcPrice));
        }
        _sortByAddr(tBuf, pBuf, n);

        // Mock each token's provider price, resolve aligned providers, set the skip-mocks once.
        address oracle = IGmxOracleHolder(GmxKeeperSim.GLV_DEPOSIT_HANDLER).oracle();
        tokens = new address[](n);
        providers = new address[](n);
        address sharedProvider;
        for (uint256 i = 0; i < n; i++) {
            address p = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, tBuf[i]);
            require(p != address(0), "fixture: no GMX provider for a GLV token");
            tokens[i] = tBuf[i];
            providers[i] = p;
            sharedProvider = p; // all GLV[WETH-USDC] tokens resolve to the same provider on-fork
            GmxKeeperSim.mockPrice(vm, p, tBuf[i], pBuf[i]);
        }
        vm.mockCall(
            sharedProvider,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.isChainlinkOnChainProvider.selector),
            abi.encode(true)
        );
        vm.mockCall(
            sharedProvider,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.shouldAdjustTimestamp.selector),
            abi.encode(false)
        );
    }

    /// @notice A safe index price (GMX units, 10^(30-decimals)) that keeps `market`'s pool value
    ///         POSITIVE so GMX's GLV valuation does not revert `GlvNegativeMarketPoolValue`.
    ///
    /// @dev Two distortions can flip a sub-market's pool value negative under a mispriced index:
    ///        1. trader PnL — neutralised by the NET-ZERO-PnL price
    ///           `(oiLongUsd − oiShortUsd) / (oiLongTok − oiShortTok)` (net trader PnL == 0 there,
    ///           so pool value == collateral);
    ///        2. the POSITION IMPACT POOL — held in index-token units and SUBTRACTED from pool value
    ///           at the index price; for a thin/zero-OI market with a big impact pool this dominates,
    ///           so we additionally CAP the price so the impact-pool USD stays ≤ 25% of collateral.
    ///      Underpricing relative to these bounds only ever ADDS to pool value (smaller impact-pool
    ///      subtraction, bigger net-long trader loss), so the cap is always safe. A zero-OI market
    ///      with no impact pool accepts any price → nominal $1.
    function _indexPrice(address market, uint256 ethPrice, uint256 usdcPrice)
        internal
        view
        returns (uint256 price)
    {
        price = _netZeroPnlPrice(market); // (1) trader-PnL-neutral price (0 if none/degenerate)
        if (price == 0) price = 1e12; // fallback nominal ($1@18-dec) — capped below if needed

        // (2) impact-pool safety cap: impactPoolUsd = impactAmt * price ≤ 25% of collateral.
        uint256 cap = _impactPoolPriceCap(market, ethPrice, usdcPrice);
        if (cap != 0 && price > cap) price = cap;
        if (price == 0) price = 1; // the oracle rejects a zero price
    }

    /// @dev The index price at which `market`'s net trader PnL is zero (pool value == collateral):
    ///      (oiLongUsd − oiShortUsd) / (oiLongTok − oiShortTok), summed over {WETH,USDC} collateral.
    ///      Returns 0 when undefined (no/equal token OI) or non-positive.
    function _netZeroPnlPrice(address market) internal view returns (uint256) {
        bytes32 OI = keccak256(abi.encode("OPEN_INTEREST"));
        bytes32 OIT = keccak256(abi.encode("OPEN_INTEREST_IN_TOKENS"));
        address ds = GmxKeeperSim.DATA_STORE;
        int256 num; // longUsd - shortUsd
        int256 den; // longTok - shortTok
        address[2] memory cols = [WETH, USDC];
        for (uint256 c = 0; c < 2; c++) {
            num += int256(IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(OI, market, cols[c], true))));
            num -= int256(IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(OI, market, cols[c], false))));
            den += int256(IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(OIT, market, cols[c], true))));
            den -= int256(IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(OIT, market, cols[c], false))));
        }
        if (den == 0) return 0;
        int256 ps = num / den;
        return ps > 0 ? uint256(ps) : 0;
    }

    /// @dev Max index price keeping the position-impact-pool USD ≤ 25% of `market`'s collateral
    ///      (impactAmt * price ≤ collateralUsd/4). Returns 0 (no cap) when there is no impact pool.
    function _impactPoolPriceCap(address market, uint256 ethPrice, uint256 usdcPrice)
        internal
        view
        returns (uint256)
    {
        address ds = GmxKeeperSim.DATA_STORE;
        uint256 impactAmt = IGmxDataStoreUint(ds).getUint(
            keccak256(abi.encode(keccak256(abi.encode("POSITION_IMPACT_POOL_AMOUNT")), market))
        );
        if (impactAmt == 0) return 0;
        bytes32 PA = keccak256(abi.encode("POOL_AMOUNT"));
        uint256 poolWeth = IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(PA, market, WETH)));
        uint256 poolUsdc = IGmxDataStoreUint(ds).getUint(keccak256(abi.encode(PA, market, USDC)));
        uint256 cap = (poolWeth * ethPrice + poolUsdc * usdcPrice) / (impactAmt * 4);
        return cap == 0 ? 1 : cap;
    }

    /// @dev Dedup-insert (token, price); existing tokens keep their first price.
    function _put(address[] memory t, uint256[] memory p, uint256 n, address a, uint256 price)
        private
        pure
        returns (address[] memory, uint256[] memory, uint256)
    {
        if (a == address(0)) return (t, p, n);
        for (uint256 i = 0; i < n; i++) {
            if (t[i] == a) return (t, p, n);
        }
        t[n] = a;
        p[n] = price;
        return (t, p, n + 1);
    }

    /// @dev Insertion sort the first `n` (token, price) pairs ascending by uint160(token) — GMX's
    ///      oracle params are conventionally token-ascending (the proven SP5 set is [WETH<USDC]).
    function _sortByAddr(address[] memory t, uint256[] memory p, uint256 n) private pure {
        for (uint256 i = 1; i < n; i++) {
            address kt = t[i];
            uint256 kp = p[i];
            uint256 j = i;
            while (j > 0 && uint160(t[j - 1]) > uint160(kt)) {
                t[j] = t[j - 1];
                p[j] = p[j - 1];
                j--;
            }
            t[j] = kt;
            p[j] = kp;
        }
    }
}
