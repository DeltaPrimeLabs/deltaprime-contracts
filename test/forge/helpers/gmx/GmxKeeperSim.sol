// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {Vm} from "forge-std/Vm.sol";
import {
    IRoleStore,
    IGmxDataStore,
    IDepositHandler,
    IWithdrawalHandler,
    IGlvDepositHandler,
    IGlvWithdrawalHandler,
    IChainlinkDataStreamProvider,
    OracleUtils
} from "./IGmxArb.sol";
import {MockArbSys} from "./MockArbSys.sol";
import {MockArbGasInfo} from "./MockArbGasInfo.sol";

/**
 * @title GmxKeeperSim
 * @notice Reusable harness that simulates a GMX V2 keeper executing a queued
 *         deposit/withdrawal on an Arbitrum fork, so the real
 *         `afterDepositExecution` / `afterWithdrawalExecution` callbacks fire into
 *         our DeltaPrime diamond. Used by the SP5 GMX fork tests (T3/T4/T5/T6).
 *
 * What it does:
 *   - {etchPrecompiles}: installs {MockArbSys} at 0x64 + {MockArbGasInfo} at 0x6C so the
 *     GMX execution path (L2 block reads, keeper L1-fee reimbursement) doesn't revert
 *     on a fork.
 *   - {keeper}: discovers a live `ORDER_KEEPER` on-fork via the RoleStore (we prank it
 *     so the handler's `onlyOrderKeeper` modifier passes).
 *   - {providerFor}: resolves the DataStore-configured oracle provider for a token
 *     (the address `providers[i]` MUST equal, or the handler reverts).
 *   - {mockPrice} / {mockTwoTokenDeposit}: `vm.mockCall`-stubs the provider's
 *     `getOraclePrice` so execution uses deterministic prices instead of live
 *     Chainlink data-stream reports we cannot reproduce on a fork.
 *   - {executeDeposit} / {executeWithdrawal}: pranks the keeper and drives the handler.
 *
 * All addresses/role hashes are the live Arbitrum prod set verified on-fork
 * (recon: docs/forge/gmx-arbitrum-recon.md). The risky bit — exactly what calldata
 * the handler forwards to `getOraclePrice` (and therefore which `vm.mockCall` key
 * matches) — is validated/tuned empirically in T4; see {mockPrice} for the two keying
 * strategies and the T4 note.
 */
library GmxKeeperSim {
    // ---- live GMX V2 Arbitrum address set (recon: docs/forge/gmx-arbitrum-recon.md) ----
    address internal constant ROLE_STORE = 0x3c3d99FD298f679DBC2CEcd132b4eC4d0F5e6e72;
    address internal constant DATA_STORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;
    address internal constant DEPOSIT_HANDLER = 0x33871b8568eDC4adf33338cdD8cF52a0eCC84D42;
    address internal constant WITHDRAWAL_HANDLER = 0x11e9E7464f3Bc887a7290ec41fCd22f619b177fd;

    // ---- live GMX V2 Arbitrum GLV handler set (SP6 W3) ----
    // Discovered on-fork: `GlvRouter(0x7EAdEE2c…).glvDepositHandler()` / `.glvWithdrawalHandler()`.
    // (The RoleStore holds FOUR CONTROLLER members shaped like a GlvHandler — old + current
    // versions — so the GlvRouter's getter, not a glvVault() scan, picks the ACTIVE one.)
    // Both gate execution on ORDER_KEEPER (probing either reverts Unauthorized(_,"ORDER_KEEPER")),
    // so {keeper} below works for GLV too. Their `oracle()` == the deposit handler's oracle, so
    // {providerFor} resolves the same per-token providers.
    address internal constant GLV_DEPOSIT_HANDLER = 0x749291a06b1Eb031288A5c864F68de83e4091Ff8;
    address internal constant GLV_WITHDRAWAL_HANDLER = 0x1EEA01a3592b8943737977b93ed24be7842D2427;

    /// @notice GLV deposit/withdrawal execution prices the ENTIRE vault (every GM sub-market in
    ///         the GLV — 56 markets for GLV[WETH-USDC]), so it is far heavier than a single-market
    ///         deposit. A generous ceiling so the 56-market valuation + the target-market GM
    ///         deposit + our 600k callback all fit.
    uint256 internal constant GLV_KEEPER_EXEC_GAS = 400_000_000;

    /// @dev keccak256(abi.encode("ORDER_KEEPER")) — GMX hashes role keys with abi.encode.
    bytes32 internal constant ORDER_KEEPER =
        0x40a07f8f0fc57fcf18b093d96362a8e661eaac7b7e6edbf66f242111f83a6794;

    // ---- Arbitrum precompiles we etch over on the fork ----
    address internal constant ARB_SYS = 0x0000000000000000000000000000000000000064;
    address internal constant ARB_GAS_INFO = 0x000000000000000000000000000000000000006C;

    /// @dev Key prefix DataStore uses for the per-token oracle provider mapping. GMX
    ///      derives the storage key as keccak256(abi.encode(<prefix>, oracle, token)),
    ///      where <prefix> == keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN")) ==
    ///      0x657bbff942bd72a4c9f2ae3dde95e145191db37af62643255f43fd27fb007981
    ///      (computed via `cast keccak "$(cast abi-encode 'f(string)' 'ORACLE_PROVIDER_FOR_TOKEN')"`).
    ///      Computed inline in {providerFor} — `keccak256(abi.encode(...))` is not a
    ///      compile-time-constant initializer so it cannot be a `constant` here.
    bytes32 internal constant ORACLE_PROVIDER_FOR_TOKEN =
        0x657bbff942bd72a4c9f2ae3dde95e145191db37af62643255f43fd27fb007981;

    /// @notice Generous gas stipend for the keeper execution call (deposit/withdrawal
    ///         execution + our callback + GMX bookkeeping comfortably fit under this).
    uint256 internal constant KEEPER_EXEC_GAS = 30_000_000;

    // ---------------------------------------------------------------------------
    // Precompile etch
    // ---------------------------------------------------------------------------

    /// @notice Install the ArbSys (0x64) and ArbGasInfo (0x6C) precompile stubs so the
    ///         GMX keeper-execution path does not revert on a fork. Call once per test
    ///         (after the fork is selected) before {executeDeposit}/{executeWithdrawal}.
    function etchPrecompiles(Vm vm) internal {
        vm.etch(ARB_SYS, type(MockArbSys).runtimeCode);
        vm.etch(ARB_GAS_INFO, type(MockArbGasInfo).runtimeCode);
    }

    // ---------------------------------------------------------------------------
    // Keeper discovery
    // ---------------------------------------------------------------------------

    /// @notice First live `ORDER_KEEPER` registered in the RoleStore. Prank this so the
    ///         handler's `onlyOrderKeeper` modifier passes. Discovered on-fork (not
    ///         hardcoded) so it survives keeper-set rotation.
    /// @dev `Vm` is unused but kept in the signature so call sites read `keeper(vm)`,
    ///      matching the rest of the harness API.
    function keeper(Vm) internal view returns (address) {
        return IRoleStore(ROLE_STORE).getRoleMembers(ORDER_KEEPER, 0, 1)[0];
    }

    // ---------------------------------------------------------------------------
    // Provider discovery
    // ---------------------------------------------------------------------------

    /// @notice Resolve the DataStore-configured oracle provider for `token`.
    ///         `providers[i]` passed to {executeDeposit}/{executeWithdrawal} MUST equal
    ///         this address for the corresponding token, or the handler's
    ///         `withOraclePrices` validation reverts. For WETH/USDC this returns the
    ///         ChainlinkDataStreamProvider (0xE1d5a068…), but it can re-migrate — always
    ///         discover, never hardcode.
    /// @param dataStore the live GMX DataStore (use {DATA_STORE}).
    /// @param oracle    the handler's configured Oracle. Read it in the fixture via
    ///                  `IGmxOracleHolder(DEPOSIT_HANDLER).oracle()` and thread it in —
    ///                  the provider key is namespaced per oracle.
    /// @param token     the token whose provider to resolve.
    function providerFor(IGmxDataStore dataStore, address oracle, address token)
        internal
        view
        returns (address)
    {
        // key = keccak256(abi.encode(keccak256(abi.encode("ORACLE_PROVIDER_FOR_TOKEN")), oracle, token))
        bytes32 key = keccak256(abi.encode(ORACLE_PROVIDER_FOR_TOKEN, oracle, token));
        return dataStore.getAddress(key);
    }

    // ---------------------------------------------------------------------------
    // Oracle price mocking
    // ---------------------------------------------------------------------------

    /// @notice Mock `provider.getOraclePrice(token, "")` to return a controlled
    ///         8-decimal price. PRIMARY (exact-calldata) keying.
    ///
    /// @dev We build the `SetPricesParams` ourselves with `data[i] = ""` (see
    ///      {executeDeposit}), so the handler should forward exactly
    ///      `getOraclePrice(token, "")` to the provider — hence the exact-calldata key
    ///      `abi.encodeWithSelector(getOraclePrice.selector, token, "")`. Because the
    ///      key includes `token`, a two-token deposit can carry DIFFERENT prices per
    ///      token (which a selector-only mock cannot — its single `ValidatedPrice`
    ///      return has one `token` field). So this exact-match variant is the primary
    ///      one for multi-token deposits.
    ///
    ///      ⚠️ T4 VALIDATES THIS. If the handler wraps/transforms `data[i]` before
    ///      calling the provider, the exact-calldata key won't match and the mock won't
    ///      fire. Capture the ACTUAL calldata from a `-vvvv` trace and either re-key this
    ///      mock on it, or fall back to {mockPriceSelectorOnly} (selector-only match) for
    ///      single-token cases, or etch a custom price-mapping provider over the address.
    function mockPrice(Vm vm, address provider, address token, uint256 price8) internal {
        OracleUtils.ValidatedPrice memory vp = OracleUtils.ValidatedPrice({
            token: token,
            min: price8,
            max: price8,
            timestamp: block.timestamp,
            provider: provider
        });
        vm.mockCall(
            provider,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.getOraclePrice.selector, token, ""),
            abi.encode(vp)
        );
    }

    /// @notice {mockPrice} variant with an EXPLICIT oracle timestamp (instead of
    ///         block.timestamp). Used by the stuck-frozen canary (T6): the keeper executes in a
    ///         block just past our 5-minute cached-price window while the oracle prices carry a
    ///         timestamp still INSIDE GMX's REQUEST_EXPIRATION_TIME — so GMX executes but our
    ///         block.timestamp-based staleness check trips. Mirrors a keeper submitting a
    ///         slightly-lagged price report.
    function mockPriceAt(Vm vm, address provider, address token, uint256 price8, uint256 ts)
        internal
    {
        OracleUtils.ValidatedPrice memory vp = OracleUtils.ValidatedPrice({
            token: token,
            min: price8,
            max: price8,
            timestamp: ts,
            provider: provider
        });
        vm.mockCall(
            provider,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.getOraclePrice.selector, token, ""),
            abi.encode(vp)
        );
    }

    /// @notice T4-FALLBACK: mock `provider.getOraclePrice(...)` for ANY data argument
    ///         (selector-only match). Returns the SAME `ValidatedPrice` (incl. its single
    ///         `token` field) for every call to `provider`, so this only suits the
    ///         SINGLE-token case (e.g. a one-token GM market) — for a multi-token deposit
    ///         where each token needs a distinct price, use {mockPrice} (exact-calldata,
    ///         per-token) or {mockTwoTokenDeposit}.
    /// @dev Provided so T4 can switch keying strategy without editing {mockPrice} if the
    ///      exact-calldata key turns out not to match the handler's forwarded calldata.
    function mockPriceSelectorOnly(Vm vm, address provider, address token, uint256 price8)
        internal
    {
        OracleUtils.ValidatedPrice memory vp = OracleUtils.ValidatedPrice({
            token: token,
            min: price8,
            max: price8,
            timestamp: block.timestamp,
            provider: provider
        });
        vm.mockCall(
            provider,
            abi.encodeWithSelector(IChainlinkDataStreamProvider.getOraclePrice.selector),
            abi.encode(vp)
        );
    }

    /// @notice Convenience for the common two-token GM deposit (long + short): mock both
    ///         token prices via the primary exact-calldata {mockPrice}. Each token gets
    ///         its own distinct price.
    function mockTwoTokenDeposit(
        Vm vm,
        address provider,
        address tokenA,
        uint256 priceA8,
        address tokenB,
        uint256 priceB8
    ) internal {
        mockPrice(vm, provider, tokenA, priceA8);
        mockPrice(vm, provider, tokenB, priceB8);
    }

    // ---------------------------------------------------------------------------
    // Execution (prank the keeper, drive the handler)
    // ---------------------------------------------------------------------------

    /// @notice Simulate the keeper executing a queued deposit. `tokens[i]`/`providers[i]`
    ///         must be aligned (see {providerFor}); `data[]` is empty (content is ignored
    ///         once {mockPrice} stubs `getOraclePrice`, but the LENGTH must equal
    ///         `tokens.length`). The real `afterDepositExecution` callback fires into our
    ///         diamond from here.
    function executeDeposit(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeper(vm));
        IDepositHandler(DEPOSIT_HANDLER).executeDeposit{gas: KEEPER_EXEC_GAS}(key, p);
    }

    /// @notice Simulate the keeper executing a queued withdrawal. Same conventions as
    ///         {executeDeposit}; drives `afterWithdrawalExecution`.
    function executeWithdrawal(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeper(vm));
        IWithdrawalHandler(WITHDRAWAL_HANDLER).executeWithdrawal{gas: KEEPER_EXEC_GAS}(key, p);
    }

    // ---------------------------------------------------------------------------
    // GLV execution (SP6 W3) — prank ORDER_KEEPER, drive the GLV handler
    // ---------------------------------------------------------------------------

    /// @notice Simulate the keeper executing a queued GLV deposit. Unlike a single-market
    ///         deposit, `tokens[]`/`providers[]` must carry a price for EVERY token the GLV
    ///         valuation reads — WETH + USDC + every sub-market's index token (the caller builds
    ///         this set via the GlvReader/GmxReader). Drives `afterGlvDepositExecution` into our
    ///         diamond.
    function executeGlvDeposit(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeper(vm));
        IGlvDepositHandler(GLV_DEPOSIT_HANDLER).executeGlvDeposit{gas: GLV_KEEPER_EXEC_GAS}(key, p);
    }

    /// @notice Simulate the keeper executing a queued GLV withdrawal. Same conventions as
    ///         {executeGlvDeposit}; drives `afterGlvWithdrawalExecution`.
    function executeGlvWithdrawal(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeper(vm));
        IGlvWithdrawalHandler(GLV_WITHDRAWAL_HANDLER).executeGlvWithdrawal{gas: GLV_KEEPER_EXEC_GAS}(key, p);
    }

    // ===========================================================================
    // AVALANCHE variants (SP6 W1)
    // ===========================================================================
    //
    // Avalanche (chainid 43114) needs NO ArbSys/ArbGasInfo etch — GMX `Chain.sol`
    // only routes through the 0x64/0x6C precompiles on Arbitrum chainids; on Avax it
    // reads block.number/block.timestamp natively. So the Avax flow is: discover a live
    // ORDER_KEEPER on the AVAX RoleStore, mock the per-token oracle provider prices via the
    // SAME chain-agnostic {providerFor}/{mockPrice}/{mockPriceAt} helpers above (just thread
    // in {AVAX_DATA_STORE} + the AVAX handler's oracle), then call {executeDepositAvax} /
    // {executeWithdrawalAvax} (NO precompile etch). The DeltaPrime callback's `onlyGmxV2Keeper`
    // check passes natively because the AVAX handler holds GMX's CONTROLLER role.
    //
    // Live GMX V2 Avalanche address set (recon: docs/forge/both-chain-facet-inventory.md,
    // verified on-fork). ORDER_KEEPER role hash is identical across chains.

    address internal constant AVAX_ROLE_STORE = 0xA44F830B6a2B6fa76657a3B92C1fe74fcB7C6AfD;
    address internal constant AVAX_DATA_STORE = 0x2F0b22339414ADeD7D5F06f9D604c7fF5b2fe3f6;
    address internal constant AVAX_DEPOSIT_HANDLER = 0xCC2645E961514A694bca228686ec664933c70647;
    address internal constant AVAX_WITHDRAWAL_HANDLER = 0x334237f7d75497a22B1443f44DDCcF95e72904A0;

    /// @notice First live `ORDER_KEEPER` registered in the Avalanche RoleStore (20 live
    ///         members on-fork). Prank this so the AVAX handler's `onlyOrderKeeper` modifier
    ///         passes. Discovered on-fork (not hardcoded) so it survives keeper rotation.
    function keeperAvax(Vm) internal view returns (address) {
        return IRoleStore(AVAX_ROLE_STORE).getRoleMembers(ORDER_KEEPER, 0, 1)[0];
    }

    /// @notice Avalanche deposit execution: identical to {executeDeposit} but pranks the AVAX
    ///         keeper, drives the AVAX DepositHandler, and does NOT etch any precompiles.
    function executeDepositAvax(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeperAvax(vm));
        IDepositHandler(AVAX_DEPOSIT_HANDLER).executeDeposit{gas: KEEPER_EXEC_GAS}(key, p);
    }

    /// @notice Avalanche withdrawal execution: AVAX counterpart of {executeWithdrawal}.
    function executeWithdrawalAvax(
        Vm vm,
        bytes32 key,
        address[] memory tokens,
        address[] memory providers
    ) internal {
        bytes[] memory data = new bytes[](tokens.length);
        OracleUtils.SetPricesParams memory p = OracleUtils.SetPricesParams(tokens, providers, data);
        vm.prank(keeperAvax(vm));
        IWithdrawalHandler(AVAX_WITHDRAWAL_HANDLER).executeWithdrawal{gas: KEEPER_EXEC_GAS}(key, p);
    }
}
