// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {SolvencyFacetTestArbitrum} from "../helpers/facets/SolvencyFacetTestArbitrum.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
import {DiamondLoupeFacet} from "../../../contracts/facets/DiamondLoupeFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SolvencyFacetProd} from "../../../contracts/facets/SolvencyFacetProd.sol";
import {GmxKeeperSim} from "../helpers/gmx/GmxKeeperSim.sol";
import {
    IGmxDataStore,
    IGmxOracleHolder,
    IChainlinkDataStreamProvider
} from "../helpers/gmx/IGmxArb.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IGmxForkFactory {
    function createLoan() external returns (address);
    function getLoanForOwner(address user) external view returns (address);
    function getOwnerOfLoan(address loan) external view returns (address);
}

/// @dev Minimal view of the ETH/USDC GM deposit entrypoint on GmxV2FacetArbitrum.
///      `depositEthUsdcGmxV2(isLongToken, tokenAmount, minGmAmount, executionFee)` payable.
interface IGmxDepositFacet {
    function depositEthUsdcGmxV2(
        bool isLongToken,
        uint256 tokenAmount,
        uint256 minGmAmount,
        uint256 executionFee
    ) external payable;
}

interface ITokenManagerPoolAssets {
    function getAllPoolAssets() external view returns (bytes32[] memory);
}

/// @dev Minimal view of the ETH/USDC GM withdrawal entrypoint on GmxV2FacetArbitrum.
///      `withdrawEthUsdcGmxV2(gmAmount, minLong, minShort, executionFee)` payable.
interface IGmxWithdrawFacet {
    function withdrawEthUsdcGmxV2(
        uint256 gmAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;
}

/// @dev Chainlink AggregatorV3 latestRoundData (8-dec ETH/USD). Named uniquely to avoid a
///      symbol clash with the same-shaped interface declared locally in the deposit test.
interface IGmxForkAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title ArbitrumGmxForkFixture
 * @notice Live-diamond fork fixture for the GMX V2 keeper-simulation tests (SP5).
 *
 * Attaches to the REAL deployed DeltaPrime diamond on an Arbitrum fork
 * (factory / TokenManager / beacon at their prod addresses, GMX facets already
 * cut in, GM markets already whitelisted), then:
 *   1. pranks the beacon owner/pauseAdmin to Replace-cut a signer-override
 *      solvency facet so create-side getPrices() validates our 5 deterministic
 *      RedStone test signers instead of the prod primary-prod signer set;
 *   2. creates a Prime Account for `user` (plain createLoan — the prod factory's
 *      only gate is hasNoLoan, so a fresh address just works);
 *   3. funds the account with real WETH as "ETH" collateral.
 *
 * Gated behind RUN_GMX_FORK=true + chain config == arbitrum (ARBITRUM_RPC_URL is
 * optional — defaults to the public endpoint; set a dedicated archive RPC for CI)
 * (DeploymentChainConfig.SMART_LOANS_FACTORY must equal the live prod factory,
 * which only happens when select-chain-config.js arbitrum has been run). Under
 * the default "test" config it SKIPS — never runs in the default CI matrix.
 */
abstract contract ArbitrumGmxForkFixture is Test {
    // ---- live Arbitrum prod address set (recon: docs/forge/gmx-arbitrum-recon.md) ----
    address internal constant FACTORY = 0xFf5e3dDaefF411a1dC6CcE00014e4Bca39265c20;
    address internal constant TOKEN_MANAGER = 0x0a0D954d4b0F0b47a5990C0abd179A90fF74E255;
    address internal constant BEACON = 0x62Cf82FB0484aF382714cD09296260edc1DC0c6c;
    address internal constant BEACON_OWNER = 0x43D9A211BDdC5a925fA2b19910D44C51D5c9aa93;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant GM_ETH_WETH_USDC = 0x70d95587d40A2caf56bd97485aB3Eec10Bee6336;

    // SmartLoanStorage lives at keccak256("diamond.standard.smartloan.storage").
    // Field order: [0]=pauseAdmin, [1]=contractOwner, [2]=proposedOwner, ...
    bytes32 internal constant SMARTLOAN_STORAGE_POSITION =
        0x8d5bb42e0ac1496a2c326edc9c00758985246e6c2bb146d6c2f4a0d509e0960a; // keccak256("diamond.standard.smartloan.storage")

    uint256 internal constant ETH_PRICE_8 = 2000e8; // deterministic test ETH price (8-dec oracle format)
    uint256 internal constant USDC_PRICE_8 = 1e8; // deterministic test USDC price (8-dec oracle format)
    uint256 internal constant FUND_AMOUNT = 0.5 ether; // WETH collateral funded into the PA

    // The ETH GM market's RedStone symbol + the two underlying-token symbols (Arbitrum
    // TokenManager maps WETH→"ETH", USDC→"USDC", GM_ETH_WETH_USDC→"GM_ETH_WETH_USDC").
    // These three are the union of every getPrices() lookup the deposit entrypoint makes
    // (the GM market's [gm, long, short] price fetch + the owned-asset solvency sim), so
    // they are exactly the RedStone feed set the wrapped create call must carry.
    bytes32 internal constant SYM_ETH = bytes32("ETH");
    bytes32 internal constant SYM_USDC = bytes32("USDC");
    bytes32 internal constant SYM_GM_ETH = bytes32("GM_ETH_WETH_USDC");

    // GMX execution fee paid as native msg.value. Covers callbackGasLimit (600k) + the
    // keeper's execution gas comfortably at any realistic Arbitrum gas price — generous so
    // GMX's create-time fee validation never reverts on a fork. (See plan: 0.001 → bump.)
    uint256 internal constant GMX_EXECUTION_FEE = 0.01 ether;

    // Chainlink ETH/USD on Arbitrum (8-dec) — feeds GMX a realistic WETH price at keeper
    // execution so the GM pool valuation is sane (mirrors the deposit test's seam).
    address internal constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    address internal user;
    address internal loan;
    address internal liveSolvencyFacet; // the prod solvency facet we Replace-cut over
    address internal testSolvencyFacet; // our etched SolvencyFacetTestArbitrum

    function _gmxForkActive() internal returns (bool) {
        if (!vm.envOr("RUN_GMX_FORK", false)) return false;
        // Symmetric with the Avalanche fixture: ARBITRUM_RPC_URL is OPTIONAL for
        // running (createSelectFork falls back to the public endpoint below). For
        // CI it should be set to a dedicated archive RPC — forge-full.yml's guard
        // requires it there. The only hard gate is the arbitrum chain config, so
        // DeploymentConstants resolves to the prod diamond addresses.
        return DeploymentChainConfig.SMART_LOANS_FACTORY == FACTORY;
    }

    function setUp() public virtual {
        if (!_gmxForkActive()) {
            vm.skip(true);
            return;
        }
        // Opt-in block pinning for reproducibility: ARBITRUM_FORK_BLOCK=0/unset → fork at
        // LATEST (local default; the public RPC always serves head). CI sets it to a fixed
        // block so the deterministic gating tier is reproducible — that requires the archive
        // RPC secret (public nodes prune old state). The live-swap tier deliberately leaves it
        // unset (forks at latest) so live ParaSwap routes / DEX quotes match the fork head.
        string memory arbRpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        uint256 arbForkBlock = vm.envOr("ARBITRUM_FORK_BLOCK", uint256(0));
        if (arbForkBlock == 0) {
            vm.createSelectFork(arbRpc);
        } else {
            vm.createSelectFork(arbRpc, arbForkBlock);
        }

        // 1) Replace-cut the signer-override solvency facet onto the live beacon.
        _cutSignerOverrideSolvencyFacet();

        // 2) create a Prime Account for `user`.
        user = makeAddr("gmxUser");
        loan = _createLoanFor(user);
        require(loan != address(0), "fixture: createLoan returned address(0)");

        // 3) fund WETH collateral (as "ETH"). fund() has no solvency check and
        //    _syncExposure → updateUserExposure is balance-based (no oracle), so
        //    no RedStone payload is required for funding.
        _fundEth(FUND_AMOUNT);

        // 4) prove the signer-override cut is live end-to-end: a wrapped solvency
        //    read with our 5 test signers must validate (the prod facet would have
        //    reverted InsufficientNumberOfUniqueSigners on these signers).
        _assertSignerOverrideActive();
    }

    // ---------------------------------------------------------------------------
    // Virtuals (overridden below; kept virtual so future tasks can specialise)
    // ---------------------------------------------------------------------------

    function _cutSignerOverrideSolvencyFacet() internal virtual {
        // Enumerate the solvency selectors currently registered on the beacon via
        // the loupe: find the facet serving getPrices(), then pull ALL its selectors.
        // This is self-adapting — no hardcoded selector list that can drift from prod.
        address live = DiamondLoupeFacet(BEACON).facetAddress(SolvencyFacetProd.getPrices.selector);
        require(live != address(0), "fixture: no live solvency facet for getPrices");
        bytes4[] memory selectors = DiamondLoupeFacet(BEACON).facetFunctionSelectors(live);
        require(selectors.length > 0, "fixture: zero solvency selectors enumerated");
        liveSolvencyFacet = live;

        // Etch the test facet (>24KB; new() would hit EIP-170, vm.etch bypasses it).
        address testFacet = makeAddr("solvencyFacetTestArbitrum");
        vm.etch(testFacet, type(SolvencyFacetTestArbitrum).runtimeCode);
        testSolvencyFacet = testFacet;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(testFacet, IDiamondCut.FacetCutAction.Replace, selectors);

        (address owner_, address pauseAdmin_) = _beaconAdmins();
        console2.log("beacon contractOwner", owner_);
        console2.log("beacon pauseAdmin   ", pauseAdmin_);
        console2.log("live solvency facet ", live);
        console2.log("solvency selectors  ", selectors.length);

        // pause -> diamondCut(Replace) -> unpause. Each prank is single-shot.
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).pause();
        vm.prank(owner_);
        IDiamondCut(BEACON).diamondCut(cuts, address(0), "");
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).unpause();

        // Structural proof: every enumerated selector now resolves to the test facet.
        require(
            DiamondLoupeFacet(BEACON).facetAddress(SolvencyFacetProd.getPrices.selector) == testFacet,
            "fixture: getPrices not remapped to test facet"
        );
    }

    function _createLoanFor(address u) internal virtual returns (address) {
        // The prod SmartLoansFactory.createLoan() only gates on hasNoLoan: a fresh
        // EOA that is not already a borrower and is not a whitelisted liquidator can
        // create a loan with no extra authorisation. No whitelist / AlphaAccessList
        // gate exists on the DeltaPrime Arbitrum factory (unlike DegenPrime/Base).
        require(IGmxForkFactory(FACTORY).getLoanForOwner(u) == address(0), "fixture: user already has loan");
        vm.prank(u);
        IGmxForkFactory(FACTORY).createLoan();
        return IGmxForkFactory(FACTORY).getLoanForOwner(u);
    }

    // ---------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------

    function _fundEth(uint256 amount) internal {
        // Try forge deal first; fall back to native wrap if WETH's slot resists deal.
        try this.__dealWeth(user, amount) {
            // ok
        } catch {
            vm.deal(user, amount);
            vm.prank(user);
            IWETH(WETH).deposit{value: amount}();
        }
        require(IWETH(WETH).balanceOf(user) >= amount, "fixture: WETH funding of user failed");

        vm.startPrank(user);
        IWETH(WETH).approve(loan, amount);
        AssetsOperationsFacet(loan).fund(bytes32("ETH"), amount);
        vm.stopPrank();
    }

    /// @dev external wrapper so the deal attempt can be try/catch'd.
    function __dealWeth(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal");
        deal(WETH, to, amount);
    }

    // ---------------------------------------------------------------------------
    // Signer-override verification (wrapped RedStone solvency read)
    // ---------------------------------------------------------------------------

    function _assertSignerOverrideActive() internal {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("ETH");
        uint256[] memory vals = new uint256[](1);
        vals[0] = ETH_PRICE_8;

        bytes memory ret = RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SolvencyFacetProd.getPrices.selector, feeds),
            feeds,
            vals
        );
        uint256[] memory prices = abi.decode(ret, (uint256[]));
        require(prices.length == 1, "fixture: getPrices wrong length");
        require(prices[0] == ETH_PRICE_8, "fixture: ETH price not from test-signer payload");
        console2.log("signer-override verified: getPrices(ETH) =", prices[0]);
    }

    // ---------------------------------------------------------------------------
    // Internal helpers (reused by later tasks)
    // ---------------------------------------------------------------------------

    /// @dev Read (contractOwner, pauseAdmin) straight from the beacon's
    ///      SmartLoanStorage so we prank the real signers (robust to a
    ///      multisig/timelock owner; vm.prank works regardless).
    function _beaconAdmins() internal view returns (address owner_, address pauseAdmin_) {
        pauseAdmin_ = address(uint160(uint256(vm.load(BEACON, SMARTLOAN_STORAGE_POSITION))));
        owner_ = address(uint160(uint256(vm.load(BEACON, bytes32(uint256(SMARTLOAN_STORAGE_POSITION) + 1)))));
    }

    // ---------------------------------------------------------------------------
    // GMX deposit creation (SP5 Task 3) — wrapped create + GMX deposit-key extraction
    // ---------------------------------------------------------------------------

    /// @notice Create an ETH/USDC GM deposit through the Prime Account's
    ///         `depositEthUsdcGmxV2` entrypoint, wrapped with a test-signer RedStone
    ///         payload and a native execution fee. Returns the GMX deposit `key`.
    ///
    /// @dev The deposit's on-chain `isWithinBounds` guard requires the supplied `minGm`
    ///      USD value to sit within ±5% of the deposited-token USD value. We size the
    ///      RedStone GM price so `minGmUSD == depositUSD` exactly (the bound's centre),
    ///      which lets the caller pass any positive `minGm` and have the create succeed —
    ///      while keeping `minGm` (the GMX `minMarketTokens`) freely choosable for the
    ///      keeper-execution test (a low `minGm` guarantees GMX mints enough to EXECUTE
    ///      rather than cancel). The GM price set here only feeds the create-side
    ///      self-consistent USD math + the cached benchmark; the GM tokens actually minted
    ///      are decided by GMX's own oracle at execution, not by this value.
    function _createGmDeposit(bool isLongToken, uint256 tokenAmount, uint256 minGm)
        internal
        returns (bytes32 key)
    {
        (bool ok, bytes memory ret) = _createGmDepositRaw(isLongToken, tokenAmount, minGm);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractDepositKey();
        require(key != bytes32(0), "fixture: GMX deposit key not found in logs");
    }

    /// @notice Same as {_createGmDeposit} but never bubbles — returns the raw
    ///         (success, returndata) so a test can assert a deposit is REJECTED (e.g. the
    ///         second deposit on an already-frozen account). Records logs either way so a
    ///         successful call's key can still be extracted via {_extractDepositKey}.
    function _createGmDepositRaw(bool isLongToken, uint256 tokenAmount, uint256 minGm)
        internal
        returns (bool ok, bytes memory ret)
    {
        require(minGm > 0, "fixture: minGm must be > 0 (isWithinBounds rejects 0)");

        uint256 depPrice8 = isLongToken ? ETH_PRICE_8 : USDC_PRICE_8;
        uint256 depDecimals = isLongToken ? 18 : 6;
        // depositUSD in 8-dec USD units (price is 8-dec, amount in token-native units).
        uint256 depositUsd8 = (depPrice8 * tokenAmount) / (10 ** depDecimals);
        // GM price (8-dec) s.t. minGm * gmPrice / 1e18 == depositUsd8  → isWithinBounds centre.
        uint256 gmPrice8 = (depositUsd8 * 1e18) / minGm;

        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxDepositFacet.depositEthUsdcGmxV2.selector,
            isLongToken,
            tokenAmount,
            minGm,
            GMX_EXECUTION_FEE
        );

        vm.deal(user, GMX_EXECUTION_FEE);
        vm.recordLogs();
        vm.prank(user);
        (ok, ret) = loan.call{value: GMX_EXECUTION_FEE}(bytes.concat(callData, payload));
    }

    /// @notice Build the full RedStone feed set the wrapped create call must carry.
    /// @dev The deposit consumes prices through THREE solvency entrypoints, not just the
    ///      GM price fetch:
    ///        1. `_getUnifiedGmxTokenPricesAndAddresses` → getPrices([GM, ETH, USDC]);
    ///        2. `getThresholdWeightedValuePayable` → owned-asset prices ([ETH]);
    ///        3. `getDebtPayable` → prices for EVERY pool (borrowable) asset
    ///           (`getAllPoolAssets()` = USDC, DAI, BTC, ARB, ETH on Arbitrum), even at
    ///           zero debt — each is multiplied by a zero borrow, but RedStone still
    ///           requires ≥3 signers for every requested symbol or it reverts
    ///           InsufficientNumberOfUniqueSigners(0,3).
    ///      So the feed set is `getAllPoolAssets() ∪ {GM_ETH_WETH_USDC}` (ETH+USDC are
    ///      already pool assets). Pool assets other than ETH/USDC get a nominal $1 price —
    ///      harmless because zero debt zeroes their contribution. Discovered dynamically so
    ///      the test survives a change to the borrowable-asset set.
    function _depositFeedSet(uint256 gmPrice8)
        internal
        view
        returns (bytes32[] memory feeds, uint256[] memory vals)
    {
        bytes32[] memory pool = ITokenManagerPoolAssets(TOKEN_MANAGER).getAllPoolAssets();
        feeds = new bytes32[](pool.length + 1);
        vals = new uint256[](pool.length + 1);
        for (uint256 i = 0; i < pool.length; i++) {
            feeds[i] = pool[i];
            if (pool[i] == SYM_ETH) vals[i] = ETH_PRICE_8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8; // nominal — zero debt nulls the contribution
        }
        feeds[pool.length] = SYM_GM_ETH;
        vals[pool.length] = gmPrice8;
    }

    /// @notice Pull the GMX deposit `key` out of the logs recorded around the create call.
    /// @dev GMX's EventEmitter logs `DepositCreated` via `emitEventLog2(name, key, account,
    ///      data)` → topics = [EventLog2 sig, keccak256("DepositCreated"), key, account].
    ///      We match the indexed event-name hash (topics[1]) and read the key (topics[2]),
    ///      which is emitter-agnostic and survives an EventEmitter address change.
    function _extractDepositKey() internal returns (bytes32 key) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nameHash = keccak256(bytes("DepositCreated"));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[1] == nameHash) {
                return logs[i].topics[2];
            }
        }
        return bytes32(0);
    }

    /// @dev Decode the string from a `require`/`Error(string)` revert returndata (or "").
    function _revertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "";
        assembly {
            ret := add(ret, 0x04) // skip Error(string) selector
        }
        return abi.decode(ret, (string));
    }

    function _accountFrozenSince() internal view returns (uint256) {
        return SmartLoanViewFacet(loan).getAccountFrozenSince();
    }

    function _ownsAsset(bytes32 symbol) internal view returns (bool) {
        bytes32[] memory owned = SmartLoanViewFacet(loan).getAllOwnedAssets();
        for (uint256 i = 0; i < owned.length; i++) {
            if (owned[i] == symbol) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------
    // GMX keeper-simulation oracle mocking (SP5 Tasks 4/5/6) — shared by all fork tests
    // ---------------------------------------------------------------------------

    /// @notice Live ETH/USD (8-dec) from Chainlink on the fork — used to feed GMX a realistic
    ///         WETH price at keeper execution.
    function _liveEthUsd8() internal view returns (uint256) {
        (, int256 answer,,,) = IGmxForkAggregatorV3(CHAINLINK_ETH_USD).latestRoundData();
        require(answer > 0, "fixture: bad ETH/USD feed");
        return uint256(answer);
    }

    /// @notice Mock the GMX oracle provider for WETH+USDC with explicit GMX-scaled prices and
    ///         skip its Chainlink-ref-deviation + timestamp-adjust paths so the keeper execution
    ///         accepts our synthetic min==max prices as-is. Call AFTER any `vm.warp` so the
    ///         ValidatedPrice timestamp == block.timestamp. Returns the aligned
    ///         tokens[]/providers[] arrays the handler expects.
    /// @dev GMX prices are scaled by 10^(30 - tokenDecimals): WETH (18-dec) → price×1e12,
    ///      USDC (6-dec) → price×1e24.
    function _mockGmxKeeperPricesCustom(uint256 wethGmxPrice, uint256 usdcGmxPrice)
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address oracle = IGmxOracleHolder(GmxKeeperSim.DEPOSIT_HANDLER).oracle();
        address provWeth = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, WETH);
        address provUsdc = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, USDC);
        require(provWeth != address(0) && provWeth == provUsdc, "fixture: unexpected GMX provider config");

        GmxKeeperSim.mockPrice(vm, provWeth, WETH, wethGmxPrice);
        GmxKeeperSim.mockPrice(vm, provUsdc, USDC, usdcGmxPrice);
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

        tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        providers = new address[](2);
        providers[0] = provWeth;
        providers[1] = provUsdc;
    }

    /// @notice {_mockGmxKeeperPricesCustom} at the live ETH price + $1 USDC — the realistic
    ///         configuration used to drive a successful deposit/withdrawal execution.
    function _mockGmxKeeperPrices()
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        return _mockGmxKeeperPricesCustom((_liveEthUsd8() * 1e12) / 1e8, 1e24);
    }

    /// @notice Live prices but with an EXPLICIT oracle timestamp `ts` (for the stuck-frozen
    ///         canary). Lets the keeper execute in a block past our 5-minute cached-price window
    ///         while the oracle prices stay inside GMX's REQUEST_EXPIRATION_TIME.
    function _mockGmxKeeperPricesAt(uint256 ts)
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address oracle = IGmxOracleHolder(GmxKeeperSim.DEPOSIT_HANDLER).oracle();
        address provWeth = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, WETH);
        address provUsdc = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.DATA_STORE), oracle, USDC);
        require(provWeth != address(0) && provWeth == provUsdc, "fixture: unexpected GMX provider config");

        GmxKeeperSim.mockPriceAt(vm, provWeth, WETH, (_liveEthUsd8() * 1e12) / 1e8, ts);
        GmxKeeperSim.mockPriceAt(vm, provUsdc, USDC, 1e24, ts);
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

        tokens = new address[](2);
        tokens[0] = WETH;
        tokens[1] = USDC;
        providers = new address[](2);
        providers[0] = provWeth;
        providers[1] = provUsdc;
    }

    /// @notice Establish a real GM position: deposit 0.1 WETH into the ETH/USDC GM market and
    ///         have a simulated keeper execute it (the proven T4 flow). Returns the GM minted.
    ///         The account is unfrozen on return (the execution callback ran).
    function _depositAndExecute() internal returns (uint256 gmMinted) {
        bytes32 key = _createGmDeposit(true /* long = WETH */, 0.1 ether, 50e18);
        require(_accountFrozenSince() > 0, "fixture: deposit-create did not freeze");

        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1); // market deposits execute with prices stamped after create
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPrices();

        uint256 gmBefore = IERC20(GM_ETH_WETH_USDC).balanceOf(loan);
        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);
        uint256 gmAfter = IERC20(GM_ETH_WETH_USDC).balanceOf(loan);

        require(_accountFrozenSince() == 0, "fixture: deposit-execute did not unfreeze");
        require(gmAfter > gmBefore, "fixture: deposit-execute minted no GM");
        gmMinted = gmAfter - gmBefore;
    }

    // ---------------------------------------------------------------------------
    // GMX withdrawal creation (SP5 Task 5) — wrapped create + GMX withdrawal-key extraction
    // ---------------------------------------------------------------------------

    /// @notice Create an ETH/USDC GM withdrawal through the Prime Account's
    ///         `withdrawEthUsdcGmxV2` entrypoint, wrapped with a test-signer RedStone payload +
    ///         a native execution fee. Returns the GMX withdrawal `key`.
    /// @dev Mirrors {_createGmDeposit}. The withdrawal's `isWithinBounds` guard requires the
    ///      supplied min-output USD value to sit within ±5% of the GM-being-burned USD value;
    ///      we size the RedStone GM price so `outputUSD == gmUSD` exactly (the bound's centre),
    ///      letting any small positive `minLong`/`minShort` pass create while keeping the GMX
    ///      `minLongTokenAmount`/`minShortTokenAmount` low enough that the keeper execution
    ///      fills (rather than reverts on min output).
    function _createGmWithdrawal(uint256 gmAmount, uint256 minLong, uint256 minShort)
        internal
        returns (bytes32 key)
    {
        (bool ok, bytes memory ret) = _createGmWithdrawalRaw(gmAmount, minLong, minShort);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        key = _extractWithdrawalKey();
        require(key != bytes32(0), "fixture: GMX withdrawal key not found in logs");
    }

    function _createGmWithdrawalRaw(uint256 gmAmount, uint256 minLong, uint256 minShort)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 bal = IERC20(GM_ETH_WETH_USDC).balanceOf(loan);
        uint256 effGm = gmAmount > bal ? bal : gmAmount; // facet caps to balance; mirror it here
        require(effGm > 0, "fixture: no GM balance to withdraw");

        // USD value (8-dec) of the requested min outputs at the deterministic test prices.
        uint256 outUsd8 = (ETH_PRICE_8 * minLong) / 1e18 + (USDC_PRICE_8 * minShort) / 1e6;
        require(outUsd8 > 0, "fixture: zero min-output value (isWithinBounds needs > 0)");

        // GM price (8-dec) s.t. (gmPrice * effGm)/1e18 == outUsd8 → isWithinBounds centre.
        uint256 gmPrice8 = (outUsd8 * 1e18) / effGm;
        require(gmPrice8 > 0, "fixture: GM price rounds to zero - raise the min outputs");

        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxWithdrawFacet.withdrawEthUsdcGmxV2.selector,
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

    /// @notice Pull the GMX withdrawal `key` from the logs recorded around the create call.
    /// @dev GMX's EventEmitter logs `WithdrawalCreated` via `emitEventLog2(name, key, account,
    ///      data)` → topics = [EventLog2 sig, keccak256("WithdrawalCreated"), key, account].
    function _extractWithdrawalKey() internal returns (bytes32 key) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 nameHash = keccak256(bytes("WithdrawalCreated"));
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 3 && logs[i].topics[1] == nameHash) {
                return logs[i].topics[2];
            }
        }
        return bytes32(0);
    }

    // ---------------------------------------------------------------------------
    // Frozen-guard helpers (SP5 Task 6) — borrow + log/selector utilities
    // ---------------------------------------------------------------------------

    /// @notice Attempt a wrapped `borrow` as the owner without bubbling — returns the raw
    ///         (success, returndata). A solvency-gated normal operation: on a frozen account it
    ///         reverts AccountFrozen() (remainsSolvent → SolvencyFacetProd.isSolvent()).
    function _borrowRaw(bytes32 asset, uint256 amount) internal returns (bool ok, bytes memory ret) {
        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(USDC_PRICE_8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, asset, amount);
        vm.prank(user);
        (ok, ret) = loan.call(bytes.concat(callData, payload));
    }

    /// @dev True if any log recorded since the last `vm.recordLogs()` has `topic0` as topic[0].
    ///      Consumes the recorded-log buffer (single call per recording window).
    function _recordedLogHasTopic0(bytes32 topic0) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length >= 1 && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }
}
