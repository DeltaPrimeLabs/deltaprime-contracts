// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {SolvencyFacetTestAvalanche} from "../helpers/facets/SolvencyFacetTestAvalanche.sol";
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

interface IWAVAX {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IGmxForkFactory {
    function createLoan() external returns (address);
    function getLoanForOwner(address user) external view returns (address);
    function getOwnerOfLoan(address loan) external view returns (address);
}

/// @dev Minimal view of the AVAX/USDC GM deposit entrypoint on GmxV2FacetAvalanche.
///      `depositAvaxUsdcGmxV2(isLongToken, tokenAmount, minGmAmount, executionFee)` payable.
interface IGmxDepositFacet {
    function depositAvaxUsdcGmxV2(
        bool isLongToken,
        uint256 tokenAmount,
        uint256 minGmAmount,
        uint256 executionFee
    ) external payable;
}

interface ITokenManagerPoolAssets {
    function getAllPoolAssets() external view returns (bytes32[] memory);
}

/// @dev Minimal view of the AVAX/USDC GM withdrawal entrypoint on GmxV2FacetAvalanche.
///      `withdrawAvaxUsdcGmxV2(gmAmount, minLong, minShort, executionFee)` payable.
interface IGmxWithdrawFacet {
    function withdrawAvaxUsdcGmxV2(
        uint256 gmAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) external payable;
}

/// @dev Chainlink AggregatorV3 latestRoundData (8-dec AVAX/USD). Named uniquely to avoid a
///      symbol clash with the same-shaped interface in any companion test.
interface IGmxForkAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title AvalancheGmxForkFixture
 * @notice Live-diamond fork fixture for the GMX V2 keeper-simulation tests on AVALANCHE
 *         (SP6 W1). The Avalanche counterpart of {ArbitrumGmxForkFixture}.
 *
 * Attaches to the REAL deployed DeltaPrime diamond on an Avalanche fork (factory /
 * TokenManager / beacon at their prod addresses, GMX facets already cut in, GM markets
 * already whitelisted), then:
 *   1. pranks the beacon owner + (separate) pauseAdmin to Replace-cut a signer-override
 *      solvency facet so create-side getPrices() validates our 5 deterministic RedStone test
 *      signers instead of the prod primary-prod signer set;
 *   2. creates a Prime Account for `user` (plain createLoan — the prod factory's only gate is
 *      hasNoLoan, so a fresh address just works; verified on-fork);
 *   3. funds the account with real WAVAX as "AVAX" collateral.
 *
 * Two structural differences from the Arbitrum fixture (recon:
 * docs/forge/both-chain-facet-inventory.md, verified on-fork):
 *   - NO ArbSys/ArbGasInfo precompile etch (chainid 43114 → GMX uses block.number natively).
 *     The Avax keeper flow uses {GmxKeeperSim.executeDepositAvax}/{executeWithdrawalAvax}.
 *   - The GMX oracle provider mock seam is the AVAX ChainlinkDataStreamProvider
 *     (0xC181eB02…, discovered dynamically, NOT Arbitrum's 0xE1d5a068…).
 *
 * Gated behind RUN_GMX_FORK=true + chain config == avalanche
 * (DeploymentChainConfig.SMART_LOANS_FACTORY must equal the live prod factory, which only
 * happens when select-chain-config.js avalanche has been run). Under the default "test"
 * config it SKIPS — never runs in the default CI matrix. The Avalanche RPC defaults to the
 * public endpoint, so AVALANCHE_RPC_URL need not be set.
 */
abstract contract AvalancheGmxForkFixture is Test {
    // ---- live Avalanche prod address set (recon: docs/forge/both-chain-facet-inventory.md) ----
    address internal constant FACTORY = 0x3Ea9D480295A73fd2aF95b4D96c2afF88b21B03D;
    address internal constant TOKEN_MANAGER = 0xF3978209B7cfF2b90100C6F87CEC77dE928Ed58e;
    address internal constant BEACON = 0x2916B3bf7C35bd21e63D01C93C62FB0d4994e56D;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant GM_AVAX_WAVAX_USDC = 0x913C1F46b48b3eD35E7dc3Cf754d4ae8499F31CF;

    // SmartLoanStorage lives at keccak256("diamond.standard.smartloan.storage").
    // Field order: [0]=pauseAdmin, [1]=contractOwner, [2]=proposedOwner, ...
    // On-fork: pauseAdmin 0x60f6…2e28 and contractOwner 0x5C31…f358 (the Timelock24H) DIFFER,
    // exactly as on Arbitrum — both are read from storage and pranked separately.
    bytes32 internal constant SMARTLOAN_STORAGE_POSITION =
        0x8d5bb42e0ac1496a2c326edc9c00758985246e6c2bb146d6c2f4a0d509e0960a; // keccak256("diamond.standard.smartloan.storage")

    uint256 internal constant AVAX_PRICE_8 = 30e8; // deterministic test AVAX price (8-dec oracle format)
    uint256 internal constant USDC_PRICE_8 = 1e8; // deterministic test USDC price (8-dec oracle format)
    uint256 internal constant FUND_AMOUNT = 5 ether; // WAVAX collateral funded into the PA

    // The AVAX GM market's RedStone symbol + the two underlying-token symbols (Avalanche
    // TokenManager maps WAVAX→"AVAX", USDC→"USDC", GM_AVAX_WAVAX_USDC→"GM_AVAX_WAVAX_USDC",
    // all verified on-fork). These three are the union of every getPrices() lookup the deposit
    // entrypoint makes (the GM market's [gm, long, short] price fetch + the owned-asset
    // solvency sim), so they are exactly the RedStone feed set a wrapped create call must carry.
    bytes32 internal constant SYM_AVAX = bytes32("AVAX");
    bytes32 internal constant SYM_USDC = bytes32("USDC");
    bytes32 internal constant SYM_GM_AVAX = bytes32("GM_AVAX_WAVAX_USDC");

    // GMX execution fee paid as native msg.value (AVAX). Covers callbackGasLimit (600k) + the
    // keeper's execution gas comfortably — generous so GMX's create-time fee validation never
    // reverts on a fork.
    uint256 internal constant GMX_EXECUTION_FEE = 0.01 ether;

    // Chainlink AVAX/USD on Avalanche (8-dec) — feeds GMX a realistic WAVAX price at keeper
    // execution so the GM pool valuation is sane (mirrors the Arbitrum fixture's seam).
    address internal constant CHAINLINK_AVAX_USD = 0x0A77230d17318075983913bC2145DB16C7366156;

    address internal user;
    address internal loan;
    address internal liveSolvencyFacet; // the prod solvency facet we Replace-cut over
    address internal testSolvencyFacet; // our etched SolvencyFacetTestAvalanche

    function _gmxForkActive() internal returns (bool) {
        if (!vm.envOr("RUN_GMX_FORK", false)) return false;
        // chain config must be avalanche so DeploymentConstants resolves to prod addresses.
        // (No AVALANCHE_RPC_URL requirement — createSelectFork defaults to the public endpoint.)
        return DeploymentChainConfig.SMART_LOANS_FACTORY == FACTORY;
    }

    function setUp() public virtual {
        if (!_gmxForkActive()) {
            vm.skip(true);
            return;
        }
        // Opt-in block pinning for reproducibility: AVALANCHE_FORK_BLOCK=0/unset → fork at
        // LATEST (local default; the public RPC always serves head). CI sets it to a fixed
        // block so the deterministic gating tier is reproducible — that requires the archive
        // RPC secret (public nodes prune old state). The live-swap tier deliberately leaves it
        // unset (forks at latest) so live ParaSwap routes / DEX quotes match the fork head.
        string memory avaxRpc = vm.envOr("AVALANCHE_RPC_URL", string("https://api.avax.network/ext/bc/C/rpc"));
        uint256 avaxForkBlock = vm.envOr("AVALANCHE_FORK_BLOCK", uint256(0));
        if (avaxForkBlock == 0) {
            vm.createSelectFork(avaxRpc);
        } else {
            vm.createSelectFork(avaxRpc, avaxForkBlock);
        }

        // 1) Replace-cut the signer-override solvency facet onto the live beacon.
        _cutSignerOverrideSolvencyFacet();

        // 2) create a Prime Account for `user`.
        user = makeAddr("gmxUserAvax");
        loan = _createLoanFor(user);
        require(loan != address(0), "fixture: createLoan returned address(0)");

        // 3) fund WAVAX collateral (as "AVAX"). fund() has no solvency check and
        //    _syncExposure → updateUserExposure is balance-based (no oracle), so no
        //    RedStone payload is required for funding.
        _fundAvax(FUND_AMOUNT);

        // 4) prove the signer-override cut is live end-to-end: a wrapped solvency read with our
        //    5 test signers must validate (the prod facet would have reverted
        //    InsufficientNumberOfUniqueSigners on these signers).
        _assertSignerOverrideActive();
    }

    // ---------------------------------------------------------------------------
    // Virtuals (overridden below; kept virtual so future tasks can specialise)
    // ---------------------------------------------------------------------------

    function _cutSignerOverrideSolvencyFacet() internal virtual {
        // Enumerate the solvency selectors currently registered on the beacon via the loupe:
        // find the facet serving getPrices(), then pull ALL its selectors. Self-adapting — no
        // hardcoded selector list that can drift from prod.
        address live = DiamondLoupeFacet(BEACON).facetAddress(SolvencyFacetProd.getPrices.selector);
        require(live != address(0), "fixture: no live solvency facet for getPrices");
        bytes4[] memory selectors = DiamondLoupeFacet(BEACON).facetFunctionSelectors(live);
        require(selectors.length > 0, "fixture: zero solvency selectors enumerated");
        liveSolvencyFacet = live;

        // Etch the test facet (>24KB; new() would hit EIP-170, vm.etch bypasses it).
        address testFacet = makeAddr("solvencyFacetTestAvalanche");
        vm.etch(testFacet, type(SolvencyFacetTestAvalanche).runtimeCode);
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
        // The prod SmartLoansFactory.createLoan() only gates on hasNoLoan: a fresh EOA that is
        // not already a borrower can create a loan with no extra authorisation. No whitelist /
        // AlphaAccessList gate exists on the DeltaPrime Avalanche factory (verified on-fork:
        // getLoanForOwner(random) == address(0)).
        require(IGmxForkFactory(FACTORY).getLoanForOwner(u) == address(0), "fixture: user already has loan");
        vm.prank(u);
        IGmxForkFactory(FACTORY).createLoan();
        return IGmxForkFactory(FACTORY).getLoanForOwner(u);
    }

    // ---------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------

    function _fundAvax(uint256 amount) internal {
        // Try forge deal first; fall back to native wrap if WAVAX's slot resists deal.
        try this.__dealWavax(user, amount) {
            // ok
        } catch {
            vm.deal(user, amount);
            vm.prank(user);
            IWAVAX(WAVAX).deposit{value: amount}();
        }
        require(IWAVAX(WAVAX).balanceOf(user) >= amount, "fixture: WAVAX funding of user failed");

        vm.startPrank(user);
        IWAVAX(WAVAX).approve(loan, amount);
        AssetsOperationsFacet(loan).fund(bytes32("AVAX"), amount);
        vm.stopPrank();
    }

    /// @dev external wrapper so the deal attempt can be try/catch'd.
    function __dealWavax(address to, uint256 amount) external {
        require(msg.sender == address(this), "internal");
        deal(WAVAX, to, amount);
    }

    // ---------------------------------------------------------------------------
    // Signer-override verification (wrapped RedStone solvency read)
    // ---------------------------------------------------------------------------

    function _assertSignerOverrideActive() internal {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("AVAX");
        uint256[] memory vals = new uint256[](1);
        vals[0] = AVAX_PRICE_8;

        bytes memory ret = RedstoneLib.wrapExpectSuccess(
            vm,
            loan,
            abi.encodeWithSelector(SolvencyFacetProd.getPrices.selector, feeds),
            feeds,
            vals
        );
        uint256[] memory prices = abi.decode(ret, (uint256[]));
        require(prices.length == 1, "fixture: getPrices wrong length");
        require(prices[0] == AVAX_PRICE_8, "fixture: AVAX price not from test-signer payload");
        console2.log("signer-override verified: getPrices(AVAX) =", prices[0]);
    }

    // ---------------------------------------------------------------------------
    // Internal helpers (reused by later tasks)
    // ---------------------------------------------------------------------------

    /// @dev Read (contractOwner, pauseAdmin) straight from the beacon's SmartLoanStorage so we
    ///      prank the real signers (robust to a multisig/timelock owner; vm.prank works
    ///      regardless — the Avax owner is the Timelock24H).
    function _beaconAdmins() internal view returns (address owner_, address pauseAdmin_) {
        pauseAdmin_ = address(uint160(uint256(vm.load(BEACON, SMARTLOAN_STORAGE_POSITION))));
        owner_ = address(uint160(uint256(vm.load(BEACON, bytes32(uint256(SMARTLOAN_STORAGE_POSITION) + 1)))));
    }

    // ---------------------------------------------------------------------------
    // GMX deposit creation (W1) — wrapped create + GMX deposit-key extraction
    // ---------------------------------------------------------------------------

    /// @notice Create an AVAX/USDC GM deposit through the Prime Account's
    ///         `depositAvaxUsdcGmxV2` entrypoint, wrapped with a test-signer RedStone payload +
    ///         a native execution fee. Returns the GMX deposit `key`. Mirrors the Arbitrum
    ///         fixture's `_createGmDeposit`; see it for the isWithinBounds sizing rationale.
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

    /// @notice Same as {_createGmDeposit} but never bubbles — returns the raw (success,
    ///         returndata) so a test can assert a deposit is REJECTED (e.g. the second deposit on
    ///         an already-frozen account). Records logs either way.
    function _createGmDepositRaw(bool isLongToken, uint256 tokenAmount, uint256 minGm)
        internal
        returns (bool ok, bytes memory ret)
    {
        require(minGm > 0, "fixture: minGm must be > 0 (isWithinBounds rejects 0)");

        uint256 depPrice8 = isLongToken ? AVAX_PRICE_8 : USDC_PRICE_8;
        uint256 depDecimals = isLongToken ? 18 : 6;
        // depositUSD in 8-dec USD units (price is 8-dec, amount in token-native units).
        uint256 depositUsd8 = (depPrice8 * tokenAmount) / (10 ** depDecimals);
        // GM price (8-dec) s.t. minGm * gmPrice / 1e18 == depositUsd8  → isWithinBounds centre.
        uint256 gmPrice8 = (depositUsd8 * 1e18) / minGm;

        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxDepositFacet.depositAvaxUsdcGmxV2.selector,
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

    /// @notice Build the full RedStone feed set the wrapped create call must carry: the
    ///         borrowable-asset set `getAllPoolAssets()` ∪ {GM_AVAX_WAVAX_USDC} (AVAX+USDC are
    ///         already pool assets). Every requested symbol needs ≥3 signers or RedStone reverts
    ///         InsufficientNumberOfUniqueSigners — even the zero-debt pool assets. Discovered
    ///         dynamically so the test survives a change to the borrowable-asset set. (Mirrors the
    ///         Arbitrum fixture's `_depositFeedSet`.)
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
            if (pool[i] == SYM_AVAX) vals[i] = AVAX_PRICE_8;
            else if (pool[i] == SYM_USDC) vals[i] = USDC_PRICE_8;
            else vals[i] = 1e8; // nominal — zero debt nulls the contribution
        }
        feeds[pool.length] = SYM_GM_AVAX;
        vals[pool.length] = gmPrice8;
    }

    /// @notice Pull the GMX deposit `key` out of the logs recorded around the create call.
    /// @dev GMX's EventEmitter logs `DepositCreated` via `emitEventLog2(name, key, account,
    ///      data)` → topics = [EventLog2 sig, keccak256("DepositCreated"), key, account]. We
    ///      match the indexed event-name hash (topics[1]) and read the key (topics[2]) —
    ///      emitter-agnostic, survives an EventEmitter address change.
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
    // GMX keeper-simulation oracle mocking (W1) — shared by all Avax fork tests
    // ---------------------------------------------------------------------------

    /// @notice Live AVAX/USD (8-dec) from Chainlink on the fork — used to feed GMX a realistic
    ///         WAVAX price at keeper execution.
    function _liveAvaxUsd8() internal view returns (uint256) {
        (, int256 answer,,,) = IGmxForkAggregatorV3(CHAINLINK_AVAX_USD).latestRoundData();
        require(answer > 0, "fixture: bad AVAX/USD feed");
        return uint256(answer);
    }

    /// @notice Mock the GMX oracle provider for WAVAX+USDC with explicit GMX-scaled prices and
    ///         skip its Chainlink-ref-deviation + timestamp-adjust paths so the keeper execution
    ///         accepts our synthetic min==max prices as-is. Call AFTER any `vm.warp`. Returns the
    ///         aligned tokens[]/providers[] arrays the handler expects.
    /// @dev GMX prices are scaled by 10^(30 - tokenDecimals): WAVAX (18-dec) → price×1e12,
    ///      USDC (6-dec) → price×1e24. The Avax provider (0xC181eB02…) is discovered dynamically
    ///      and its live `isChainlinkOnChainProvider()` is false → we mock it true (same as
    ///      Arbitrum) to skip the ref-price deviation check.
    function _mockGmxKeeperPricesCustom(uint256 wavaxGmxPrice, uint256 usdcGmxPrice)
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address oracle = IGmxOracleHolder(GmxKeeperSim.AVAX_DEPOSIT_HANDLER).oracle();
        address provWavax = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.AVAX_DATA_STORE), oracle, WAVAX);
        address provUsdc = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.AVAX_DATA_STORE), oracle, USDC);
        require(provWavax != address(0) && provWavax == provUsdc, "fixture: unexpected GMX provider config");

        GmxKeeperSim.mockPrice(vm, provWavax, WAVAX, wavaxGmxPrice);
        GmxKeeperSim.mockPrice(vm, provUsdc, USDC, usdcGmxPrice);
        vm.mockCall(
            provWavax,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.isChainlinkOnChainProvider.selector),
            abi.encode(true)
        );
        vm.mockCall(
            provWavax,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.shouldAdjustTimestamp.selector),
            abi.encode(false)
        );

        tokens = new address[](2);
        tokens[0] = WAVAX;
        tokens[1] = USDC;
        providers = new address[](2);
        providers[0] = provWavax;
        providers[1] = provUsdc;
    }

    /// @notice {_mockGmxKeeperPricesCustom} at the live AVAX price + $1 USDC — the realistic
    ///         configuration used to drive a successful deposit/withdrawal execution.
    function _mockGmxKeeperPrices()
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        return _mockGmxKeeperPricesCustom((_liveAvaxUsd8() * 1e12) / 1e8, 1e24);
    }

    /// @notice Live prices but with an EXPLICIT oracle timestamp `ts` (for the stuck-frozen
    ///         canary). Lets the keeper execute in a block past our 5-minute cached-price window
    ///         while the oracle prices stay inside GMX's REQUEST_EXPIRATION_TIME.
    function _mockGmxKeeperPricesAt(uint256 ts)
        internal
        returns (address[] memory tokens, address[] memory providers)
    {
        address oracle = IGmxOracleHolder(GmxKeeperSim.AVAX_DEPOSIT_HANDLER).oracle();
        address provWavax = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.AVAX_DATA_STORE), oracle, WAVAX);
        address provUsdc = GmxKeeperSim.providerFor(IGmxDataStore(GmxKeeperSim.AVAX_DATA_STORE), oracle, USDC);
        require(provWavax != address(0) && provWavax == provUsdc, "fixture: unexpected GMX provider config");

        GmxKeeperSim.mockPriceAt(vm, provWavax, WAVAX, (_liveAvaxUsd8() * 1e12) / 1e8, ts);
        GmxKeeperSim.mockPriceAt(vm, provUsdc, USDC, 1e24, ts);
        vm.mockCall(
            provWavax,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.isChainlinkOnChainProvider.selector),
            abi.encode(true)
        );
        vm.mockCall(
            provWavax,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.shouldAdjustTimestamp.selector),
            abi.encode(false)
        );

        tokens = new address[](2);
        tokens[0] = WAVAX;
        tokens[1] = USDC;
        providers = new address[](2);
        providers[0] = provWavax;
        providers[1] = provUsdc;
    }

    /// @notice Establish a real GM position: deposit WAVAX into the AVAX/USDC GM market and have
    ///         a simulated keeper execute it. Returns the GM minted; the account is unfrozen on
    ///         return (the execution callback ran). No precompile etch on Avalanche.
    /// @dev W1 NOTE: the deposit size / minGm here are sized for a realistic AVAX price (cheap
    ///      token → deposit more native than the Arb WETH equivalent and keep minGm low so GMX
    ///      mints comfortably above it). W1 implementers should tune these against the live GM
    ///      pool state if a market's depth/price drifts.
    function _depositAndExecute() internal returns (uint256 gmMinted) {
        bytes32 key = _createGmDeposit(true /* long = WAVAX */, 3 ether, 1e18);
        require(_accountFrozenSince() > 0, "fixture: deposit-create did not freeze");

        vm.warp(block.timestamp + 1); // market deposits execute with prices stamped after create
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPrices();

        uint256 gmBefore = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);
        GmxKeeperSim.executeDepositAvax(vm, key, tokens, providers);
        uint256 gmAfter = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);

        require(_accountFrozenSince() == 0, "fixture: deposit-execute did not unfreeze");
        require(gmAfter > gmBefore, "fixture: deposit-execute minted no GM");
        gmMinted = gmAfter - gmBefore;
    }

    // ---------------------------------------------------------------------------
    // GMX withdrawal creation (W1) — wrapped create + GMX withdrawal-key extraction
    // ---------------------------------------------------------------------------

    /// @notice Create an AVAX/USDC GM withdrawal through the Prime Account's
    ///         `withdrawAvaxUsdcGmxV2` entrypoint, wrapped with a test-signer RedStone payload +
    ///         a native execution fee. Returns the GMX withdrawal `key`. Mirrors the Arbitrum
    ///         fixture's `_createGmWithdrawal`.
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
        uint256 bal = IERC20(GM_AVAX_WAVAX_USDC).balanceOf(loan);
        uint256 effGm = gmAmount > bal ? bal : gmAmount; // facet caps to balance; mirror it here
        require(effGm > 0, "fixture: no GM balance to withdraw");

        // USD value (8-dec) of the requested min outputs at the deterministic test prices.
        uint256 outUsd8 = (AVAX_PRICE_8 * minLong) / 1e18 + (USDC_PRICE_8 * minShort) / 1e6;
        require(outUsd8 > 0, "fixture: zero min-output value (isWithinBounds needs > 0)");

        // GM price (8-dec) s.t. (gmPrice * effGm)/1e18 == outUsd8 → isWithinBounds centre.
        uint256 gmPrice8 = (outUsd8 * 1e18) / effGm;
        require(gmPrice8 > 0, "fixture: GM price rounds to zero - raise the min outputs");

        (bytes32[] memory feeds, uint256[] memory vals) = _depositFeedSet(gmPrice8);
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, vals);
        bytes memory callData = abi.encodeWithSelector(
            IGmxWithdrawFacet.withdrawAvaxUsdcGmxV2.selector,
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
    // Frozen-guard helpers (W1) — borrow + log/selector utilities
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
