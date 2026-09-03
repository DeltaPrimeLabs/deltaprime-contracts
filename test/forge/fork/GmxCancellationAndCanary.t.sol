// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/console2.sol";
import {ArbitrumGmxForkFixture} from "../fixtures/ArbitrumGmxForkFixture.sol";
import {GmxKeeperSim} from "../helpers/gmx/GmxKeeperSim.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The live liquidator-gated unfreeze escape hatch on AssetsOperationsFacet
///      (`unfreezeAccount() external onlyWhitelistedLiquidators`, selector 0x7c5fc3fb). No
///      `remainsSolvent` modifier, so a plain call (no RedStone payload) suffices — it's a
///      recovery op, not a solvency-gated one.
interface IUnfreeze {
    function unfreezeAccount() external;
}

/// @dev Beacon-side liquidator whitelist admin (SmartLoanLiquidationFacet). `whitelistLiquidators`
///      is `onlyOwner` and is called ON THE BEACON (the diamond) — its `canLiquidate` mapping lives
///      in beacon storage and is what each loan's `onlyWhitelistedLiquidators` modifier reads.
interface ILiquidatorWhitelistAdmin {
    function whitelistLiquidators(address[] memory _liquidators) external;
    function isLiquidatorWhitelisted(address _liquidator) external view returns (bool);
}

/**
 * SP5 Task 6 — GMX cancellation + the stuck-frozen canary + frozen-account guards
 * (Arbitrum live-diamond fork). Gated — SKIPS under the default test config.
 *
 * Four tests:
 *   1. testDepositCancellationRefunds   — a deposit is forced to CANCEL (afterDepositCancellation):
 *      deposited token refunded, GM never minted, account unfrozen.
 *   2. testStuckFrozenWhenCallbackStale — the documented PRODUCT RISK canary: a deposit executes
 *      past the 5-minute cached-price window, the callback reverts CachedPricesTooStale, GMX
 *      SWALLOWS it, and the account is left FROZEN with tokens delivered. NOTE: this freeze is
 *      RECOVERABLE — a whitelisted liquidator can clear it via unfreezeAccount() (proven by test 4
 *      below). The canary pins the stuck STATE, not a permanent dead-end.
 *   3. testFrozenAccountBlocksActions   — while a deposit is in flight the account is frozen, and
 *      a normal solvency-gated operation (borrow) reverts AccountFrozen().
 *   4. testStuckFrozenRecoverableByLiquidatorUnfreeze — the RECOVERY proof (G-02 correction):
 *      reproduces the test-2 stuck-frozen state, then a whitelisted liquidator calls
 *      unfreezeAccount() and the freeze CLEARS (frozenSince → 0). Retracts the earlier
 *      "permanent freeze, no escape hatch" framing. Also asserts a non-whitelisted caller is gated.
 */
contract GmxCancellationAndCanaryTest is ArbitrumGmxForkFixture {
    // our facet's own callback-side event (proof afterDepositCancellation ran).
    bytes32 internal constant DEPOSIT_CANCELLED_SIG =
        keccak256("DepositCancelled(address,address,uint256)");

    // -------------------------------------------------------------------------
    // 1) Cancellation — forced via a near-zero WETH price at execution (path b).
    // -------------------------------------------------------------------------
    //
    // We keep a NORMAL minGm (50e18, the T4-safe value — same pending-exposure footprint that is
    // already known to pass the GM market's exposure cap at create) and instead force GMX to
    // cancel by feeding a near-zero WETH price at EXECUTION. The 0.1 WETH deposit then values to
    // ~$0, so GMX would mint far fewer than 50e18 GM → MinMarketTokens → the DepositHandler
    // cancels the deposit and our `afterDepositCancellation` fires. Because the execution happens
    // 1s after create (benchmark fresh, well within the 5-minute window), the cancellation
    // callback runs CLEANLY (it ALSO refreshes the benchmark, which would revert if stale).
    function testDepositCancellationRefunds() public {
        uint256 wethStart = IERC20(WETH).balanceOf(loan); // collateral funded in setUp (~0.5 WETH)

        bytes32 key = _createGmDeposit(true /* long = WETH */, 0.1 ether, 50e18);
        assertGt(_accountFrozenSince(), 0, "account not frozen after deposit create");
        uint256 wethAfterCreate = IERC20(WETH).balanceOf(loan);
        assertLt(wethAfterCreate, wethStart, "deposit did not escrow WETH to the vault");
        assertEq(IERC20(GM_ETH_WETH_USDC).balanceOf(loan), 0, "unexpected GM before execution");

        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(block.timestamp + 1); // execute within the window → CLEAN cancellation callback

        // WETH = $1 (1e12, GMX 18-dec scale) forces GMX to mint << minMarketTokens (50e18) GM:
        // in a USDC-token-count-dominated pool the mint scales ~linearly with the depressed WETH
        // price, collapsing to a fraction of a GM → MinMarketTokens → cancellation.
        (address[] memory tokens, address[] memory providers) =
            _mockGmxKeeperPricesCustom(1e12 /* WETH=$1 */, 1e24 /* USDC=$1 */);

        vm.recordLogs();
        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);
        bool cancelled = _recordedLogHasTopic0(DEPOSIT_CANCELLED_SIG);

        uint256 wethAfter = IERC20(WETH).balanceOf(loan);

        // afterDepositCancellation effects (NOT afterDepositExecution):
        assertTrue(cancelled, "afterDepositCancellation (DepositCancelled) did not fire");
        assertGe(wethAfter, wethStart, "escrowed WETH not refunded on cancellation");
        assertGt(wethAfter, wethAfterCreate, "WETH refund did not restore the loan balance");
        assertEq(IERC20(GM_ETH_WETH_USDC).balanceOf(loan), 0, "GM minted despite cancellation");
        assertEq(_accountFrozenSince(), 0, "account must be unfrozen by the cancellation callback");
    }

    // -------------------------------------------------------------------------
    // 2) Stuck-frozen canary — frozen until a whitelisted liquidator unfreezes (RECOVERABLE).
    // -------------------------------------------------------------------------
    //
    // ⚠️⚠️⚠️  DOCUMENTED PRODUCT RISK — DO NOT "FIX" THIS TEST BY WEAKENING IT  ⚠️⚠️⚠️
    //
    // When a GM deposit is executed and `block.timestamp` is more than 5 minutes past the
    // deposit's benchmark, our `afterDepositExecution` callback reverts `CachedPricesTooStale`
    // inside `_updatePositionBenchmark`. GMX wraps the callback in try/catch and SWALLOWS the
    // revert (emitting AfterDepositExecutionError), so the keeper transaction SUCCEEDS and GMX
    // has already MINTED the GM tokens to our Prime Account — but the callback's
    // `unfreezeAccount` is rolled back with the rest of the reverted callback, and GMX never
    // retries it. Result: the Prime Account is left STUCK FROZEN holding live GM tokens.
    //
    // CORRECTION (G-02): this freeze is RECOVERABLE, NOT permanent. A whitelisted liquidator can
    // clear it on-chain via `AssetsOperationsFacet.unfreezeAccount()` (live selector 0x7c5fc3fb on
    // both beacons — Arbitrum facet 0x53C1F700…64A567) — proven end-to-end by
    // `testStuckFrozenRecoverableByLiquidatorUnfreeze` below. The earlier "permanent freeze, no
    // escape hatch" framing was overstated and is retracted. Residual risk is operational, not a
    // dead-end: recovery is manual + liquidator-gated (there is a `// TODO: Separate manager for
    // unfreezing - not liquidators` on the facet), plus the zero-margin 300s coincidence noted
    // below. This test PINS the stuck STATE after the swallowed callback (its passing means the bad
    // state still reproduces); test 4 PINS that the state is recoverable.
    //
    // ZERO-MARGIN NOTE (verified on this fork): GMX's REQUEST_EXPIRATION_TIME is 300s, which is
    // EXACTLY our 5-minute cached-price window. A naively-late execution (warp +6min, fresh
    // oracle ts) is therefore gated out by GMX itself — it reverts
    // `OracleTimestampsAreLargerThanRequestExpirationTime` before our callback can run. We
    // reproduce the stuck state the way it actually arises in the field: the keeper executes in a
    // block 1s past our window while submitting an oracle price report stamped 299s after the
    // request (still inside GMX's expiration). OUR block.timestamp-based staleness check trips
    // while GMX's oracle-timestamp-based expiration passes. The latent risk is the ZERO safety
    // margin: if GMX ever raises REQUEST_EXPIRATION_TIME above 5 minutes, this becomes reachable
    // through ordinary late execution with no price-lag trick at all.
    function testStuckFrozenWhenCallbackStale() public {
        bytes32 key = _createGmDeposit(true /* long = WETH */, 0.1 ether, 50e18);
        uint256 t0 = block.timestamp; // deposit benchmark + GMX request time
        assertGt(_accountFrozenSince(), 0, "account not frozen after create");

        GmxKeeperSim.etchPrecompiles(vm);
        // Execute 1s PAST our 5-minute (300s) window so the callback's benchmark is stale...
        vm.warp(t0 + 301);
        // ...but stamp the oracle prices 299s after the request, INSIDE GMX's 300s expiration, so
        // GMX still executes (mints GM) — only OUR callback trips on the now-301s-old benchmark.
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPricesAt(t0 + 299);

        // The keeper tx SUCCEEDS — GMX executes the deposit (minting GM to the loan), then catches
        // our reverting callback and swallows it. If executeDeposit itself reverted here, GMX
        // would be re-throwing the callback error instead of swallowing it (itself a finding); the
        // assertions below would then fail loudly rather than silently pass.
        //
        // VERIFIED via `-vvvv` (the load-bearing swallow evidence): inside afterDepositExecution
        // our `_updatePositionBenchmark` reverts `CachedPricesTooStale()`, and GMX emits
        // `AfterDepositExecutionError` and continues — the keeper transaction returns success.
        // (We do NOT assert on the rolled-back DepositExecuted log: forge's recordLogs captures
        // logs from reverted sub-frames, so that log is present even though its frame reverted —
        // it is not a reliable signal. The post-state below is.)
        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);

        uint256 gmHeld = IERC20(GM_ETH_WETH_USDC).balanceOf(loan);

        // THE CANARY — both halves of the stuck-frozen risk:
        //  (a) GMX delivered the GM tokens to the Prime Account (the deposit executed), and
        //  (b) the account is nonetheless STILL FROZEN because our unfreeze was rolled back with
        //      the reverted callback and GMX never retries it → stuck frozen (recoverable by a
        //      whitelisted liquidator's unfreezeAccount(); see test 4).
        assertGt(gmHeld, 0, "CANARY: GMX should have delivered GM tokens before the callback");
        assertGt(
            _accountFrozenSince(),
            0,
            "CANARY: account should be STUCK FROZEN after a swallowed stale-price callback"
        );

        console2.log("CANARY: GM tokens held while stuck-frozen =", gmHeld);
        console2.log("CANARY: frozenSince (non-zero = still frozen, recoverable via liquidator unfreeze) =", _accountFrozenSince());
    }

    // -------------------------------------------------------------------------
    // 3) Frozen account blocks normal operations.
    // -------------------------------------------------------------------------
    //
    // An in-flight GM deposit freezes the account; a normal solvency-gated operation (borrow)
    // must then revert at the freeze guard: remainsSolvent → SolvencyFacetProd.isSolvent()
    // reverts AccountFrozen() before any health math. (T3 already covers that a SECOND GMX
    // request is rejected with "Account is already frozen"; here we prove a DIFFERENT, ordinary
    // operation is blocked too.)
    function testFrozenAccountBlocksActions() public {
        _createGmDeposit(true /* long = WETH */, 0.1 ether, 50e18);
        assertGt(_accountFrozenSince(), 0, "account should be frozen with an in-flight deposit");

        (bool ok, bytes memory ret) = _borrowRaw(SYM_USDC, 1e6 /* 1 USDC */);
        assertFalse(ok, "borrow must revert while the account is frozen");

        // remainsSolvent runs the solvency read through RedStone's ProxyConnector, which catches
        // the inner SolvencyFacetProd.isSolvent() AccountFrozen() custom-error revert and re-wraps
        // it as ProxyCalldataFailedWithCustomError(bytes) carrying the raw AccountFrozen()
        // selector (0x552afea0). Assert the exact wrapped revert — proving the freeze guard, not
        // some incidental failure, blocked the borrow.
        bytes memory expected = abi.encodeWithSignature(
            "ProxyCalldataFailedWithCustomError(bytes)",
            abi.encodeWithSignature("AccountFrozen()")
        );
        assertEq(ret, expected, "borrow did not revert with the (proxy-wrapped) AccountFrozen() freeze guard");
    }

    // -------------------------------------------------------------------------
    // 4) RECOVERY PROOF — the stuck-frozen state is liquidator-recoverable (G-02 correction).
    // -------------------------------------------------------------------------
    //
    // This is the load-bearing retraction of the earlier "permanent freeze, no on-chain escape
    // hatch" finding. We reproduce the EXACT stuck-frozen state from testStuckFrozenWhenCallbackStale
    // (deposit executes 1s past our 5-min window with the oracle report inside GMX's 300s expiration
    // → afterDepositExecution reverts CachedPricesTooStale → GMX swallows it → account left frozen
    // holding live GM), then prove a whitelisted liquidator clears the freeze via the LIVE
    // `AssetsOperationsFacet.unfreezeAccount()` (selector 0x7c5fc3fb, cut on both prod beacons).
    function testStuckFrozenRecoverableByLiquidatorUnfreeze() public {
        // --- Reproduce the stuck-frozen state (identical to testStuckFrozenWhenCallbackStale) ---
        bytes32 key = _createGmDeposit(true /* long = WETH */, 0.1 ether, 50e18);
        uint256 t0 = block.timestamp;
        assertGt(_accountFrozenSince(), 0, "account not frozen after create");

        GmxKeeperSim.etchPrecompiles(vm);
        vm.warp(t0 + 301); // 1s past OUR 5-min (300s) cached-price window
        (address[] memory tokens, address[] memory providers) = _mockGmxKeeperPricesAt(t0 + 299);
        GmxKeeperSim.executeDeposit(vm, key, tokens, providers);

        // Precondition: the bad state actually reproduced — GM delivered, account STILL frozen.
        assertGt(IERC20(GM_ETH_WETH_USDC).balanceOf(loan), 0, "precondition: GMX should have delivered GM");
        assertGt(_accountFrozenSince(), 0, "precondition: account must be STUCK FROZEN before recovery");

        // --- The gate: a NON-whitelisted caller cannot unfreeze (proves it's liquidator-gated) ---
        address notLiquidator = makeAddr("g02NotALiquidator");
        vm.prank(notLiquidator);
        (bool gateOk, bytes memory gateRet) =
            loan.call(abi.encodeWithSelector(IUnfreeze.unfreezeAccount.selector));
        assertFalse(gateOk, "non-whitelisted caller must NOT be able to unfreeze");
        assertEq(
            gateRet,
            abi.encodeWithSignature("OnlyWhitelistedLiquidators()"),
            "non-whitelisted unfreeze did not revert with OnlyWhitelistedLiquidators()"
        );
        assertGt(_accountFrozenSince(), 0, "still frozen after the blocked non-whitelisted attempt");

        // --- Whitelist a test liquidator on the beacon (onlyOwner — prank the beacon owner, the
        //     same signer the fixture pranks for the solvency Replace-cut). ---
        address liquidator = makeAddr("g02RecoveryLiquidator");
        (address beaconOwner,) = _beaconAdmins();
        address[] memory toAdd = new address[](1);
        toAdd[0] = liquidator;
        vm.prank(beaconOwner);
        ILiquidatorWhitelistAdmin(BEACON).whitelistLiquidators(toAdd);
        assertTrue(
            ILiquidatorWhitelistAdmin(BEACON).isLiquidatorWhitelisted(liquidator),
            "liquidator whitelist did not take on the beacon"
        );

        // --- THE RECOVERY: the whitelisted liquidator clears the freeze. No RedStone payload —
        //     unfreezeAccount() has no remainsSolvent modifier (it's a recovery op). ---
        vm.prank(liquidator);
        IUnfreeze(loan).unfreezeAccount();

        // --- Load-bearing proof: the freeze is CLEARED → the stuck state was NOT permanent. ---
        assertEq(
            _accountFrozenSince(),
            0,
            "RECOVERED: a whitelisted liquidator's unfreezeAccount() must clear frozenSince"
        );
        // The GM tokens remain with the Prime Account — recovery only clears the freeze flag.
        assertGt(IERC20(GM_ETH_WETH_USDC).balanceOf(loan), 0, "GM must remain held after unfreeze");

        console2.log("RECOVERED: frozenSince after liquidator unfreezeAccount() =", _accountFrozenSince());
    }
}
