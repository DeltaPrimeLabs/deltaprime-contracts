// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {ParaSwapFacet} from "../../../contracts/facets/ParaSwapFacet.sol";
import {SwapDebtFacet} from "../../../contracts/facets/SwapDebtFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";

/**
 * ParaSwap executor whitelist moved from hardcoded ParaSwapHelper constants into the TokenManager.
 *
 * Previously `ParaSwapHelper._checkExecutorAddress` compared the decoded executor against five
 * `address private constant EXECUTOR_n` values, so every ParaSwap executor rotation meant
 * redeploying + diamondCutting ParaSwapFacet / SwapDebtFacet (and redeploying DepositSwap).
 * The set now lives in the TokenManager, owner-managed via
 * `whitelistParaSwapExecutors` / `delistParaSwapExecutors`.
 *
 * GAP THIS CLOSES: nothing ever covered the executor gate. The hardcoded constants were
 * unreachable from a local test (no test built a payload carrying a real executor address), and
 * the only executor-bearing payloads live in the network-gated ParaSwap fork tests. These tests
 * pin the whole lifecycle — not-whitelisted rejects, whitelisted passes the gate, delisted
 * rejects again — on every entrypoint that funnels through ParaSwapHelper.validateSwapParameters.
 */
contract ParaSwapExecutorWhitelistTest is DeltaPrimeFixture {
    // selector of ParaSwapHelper's `error InvalidExecutor();`
    bytes4 internal constant INVALID_EXECUTOR = bytes4(keccak256("InvalidExecutor()"));
    // ParaSwap v6 SwapExactAmountIn selector (see ParaSwapHelper.SWAP_EXACT_AMOUNT_IN_SELECTOR)
    bytes4 internal constant SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;

    /// @dev A real ParaSwap v6.2 executor address (the one that used to be EXECUTOR_3). Nothing in
    ///      these tests depends on it being real — it is just the address the whitelist is keyed on.
    address internal constant EXECUTOR = 0x006D0E0D006109F0020F3050000A713780B7B000;
    address internal constant OTHER_EXECUTOR = 0x082738D007001080A00099A000004f3006152085;

    // Mirrors of the TokenManager events (declared locally so `emit` works under solc 0.8.17,
    // which has no `emit Contract.Event(...)` syntax).
    event ParaSwapExecutorWhitelisted(address indexed performer, address indexed executor, uint256 timestamp);
    event ParaSwapExecutorDelisted(address indexed performer, address indexed executor, uint256 timestamp);

    address internal borrower;
    address internal loan;

    function setUp() public override {
        super.setUp();

        // Pre-fund both pools so the debt-swap path can actually borrow.
        address usdcLender = makeAddr("usdcLender");
        usdc.mint(usdcLender, 1_000_000e6);
        vm.startPrank(usdcLender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();

        address avaxLender = makeAddr("avaxLender");
        vm.deal(avaxLender, 1_000e18);
        vm.startPrank(avaxLender);
        wavax.deposit{value: 1_000e18}();
        wavax.approve(address(wavaxPool), 1_000e18);
        wavaxPool.deposit(1_000e18);
        vm.stopPrank();

        // The WAVAX mock (contracts/mock/WAVAX.sol) leaves the standard `src == msg.sender`
        // allowance bypass commented out, so its transfer() needs a self-allowance for the pool to
        // lend out native on borrow (mock-only workaround, same as ParaSwapGuards.t.sol).
        vm.prank(address(wavaxPool));
        wavax.approve(address(wavaxPool), type(uint256).max);

        (borrower, loan) = _createLoanFor("paraExecUser");
        vm.warp(block.timestamp + 1);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev ABI-encode a minimal-but-valid SwapExactAmountIn payload carrying `executor`:
    ///      [executor] [GenericData: src,dst,fromAmount,toAmount,quotedAmount,metadata,beneficiary]
    ///      [partnerAndFee]
    function _swapData(address executor, address src, address dst, uint256 fromAmount, uint256 toAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            executor,
            src,
            dst,
            fromAmount,
            toAmount,
            uint256(0), // quotedAmount
            bytes32(0), // metadata
            address(0), // beneficiary
            uint256(0) // partnerAndFee
        );
    }

    function _callParaSwapV6(address executor) internal returns (bool ok, bytes memory ret) {
        bytes memory data = _swapData(executor, address(wavax), address(usdc), 1e18, 1);
        vm.prank(borrower);
        (ok, ret) = loan.call(abi.encodeWithSelector(ParaSwapFacet.paraSwapV6.selector, SWAP_EXACT_AMOUNT_IN, data));
    }

    function _whitelist(address executor) internal {
        address[] memory execs = new address[](1);
        execs[0] = executor;
        tokenManager.whitelistParaSwapExecutors(execs);
    }

    function _delist(address executor) internal {
        address[] memory execs = new address[](1);
        execs[0] = executor;
        tokenManager.delistParaSwapExecutors(execs);
    }

    // ------------------------------------------------------------------
    // TokenManager bookkeeping
    // ------------------------------------------------------------------

    /// @notice Executors start un-whitelisted — including the addresses that used to be
    ///         hardcoded in ParaSwapHelper. This is the load-bearing consequence of the refactor:
    ///         a fresh TokenManager grants nothing, the set must be seeded explicitly.
    function testExecutorsStartUnwhitelisted() public {
        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "unexpected pre-whitelisted executor");
        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(OTHER_EXECUTOR), "unexpected pre-whitelisted executor");
    }

    function testWhitelistBatchThenDelistBatch() public {
        address[] memory execs = new address[](2);
        execs[0] = EXECUTOR;
        execs[1] = OTHER_EXECUTOR;

        vm.expectEmit(true, true, false, true, address(tokenManager));
        emit ParaSwapExecutorWhitelisted(address(this), EXECUTOR, block.timestamp);
        vm.expectEmit(true, true, false, true, address(tokenManager));
        emit ParaSwapExecutorWhitelisted(address(this), OTHER_EXECUTOR, block.timestamp);
        tokenManager.whitelistParaSwapExecutors(execs);

        assertTrue(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "executor not whitelisted");
        assertTrue(tokenManager.isParaSwapExecutorWhitelisted(OTHER_EXECUTOR), "executor not whitelisted");

        vm.expectEmit(true, true, false, true, address(tokenManager));
        emit ParaSwapExecutorDelisted(address(this), EXECUTOR, block.timestamp);
        vm.expectEmit(true, true, false, true, address(tokenManager));
        emit ParaSwapExecutorDelisted(address(this), OTHER_EXECUTOR, block.timestamp);
        tokenManager.delistParaSwapExecutors(execs);

        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "executor not delisted");
        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(OTHER_EXECUTOR), "executor not delisted");
    }

    /// @notice Re-sending a batch is a no-op (no duplicate event, no revert), so a partially
    ///         executed multisig batch can simply be re-submitted. Same for delisting.
    function testWhitelistAndDelistAreIdempotent() public {
        _whitelist(EXECUTOR);

        vm.recordLogs();
        _whitelist(EXECUTOR);
        assertEq(vm.getRecordedLogs().length, 0, "re-whitelisting must not emit");
        assertTrue(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "executor lost its whitelisting");

        _delist(EXECUTOR);

        vm.recordLogs();
        _delist(EXECUTOR);
        assertEq(vm.getRecordedLogs().length, 0, "re-delisting must not emit");
        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "executor re-whitelisted by delist");
    }

    /// @notice address(0) is the "no executor decoded" sentinel in ParaSwapHelper
    ///         (the swapExactAmountInOnUniswapV3 payload carries no executor), so it must never be
    ///         whitelistable — otherwise the sentinel and a real grant would be indistinguishable.
    function testWhitelistRejectsZeroAddress() public {
        address[] memory execs = new address[](2);
        execs[0] = EXECUTOR;
        execs[1] = address(0);

        vm.expectRevert("Invalid executor address");
        tokenManager.whitelistParaSwapExecutors(execs);

        // The whole batch reverted — the valid entry was not committed either.
        assertFalse(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "partial batch was committed");
    }

    function testOnlyOwnerCanWhitelistOrDelist() public {
        address stranger = makeAddr("executorStranger");
        address[] memory execs = new address[](1);
        execs[0] = EXECUTOR;

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        tokenManager.whitelistParaSwapExecutors(execs);

        _whitelist(EXECUTOR);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        tokenManager.delistParaSwapExecutors(execs);

        assertTrue(tokenManager.isParaSwapExecutorWhitelisted(EXECUTOR), "stranger managed to delist");
    }

    // ------------------------------------------------------------------
    // paraSwapV6
    // ------------------------------------------------------------------

    function testParaSwapV6RevertsWhenExecutorNotWhitelisted() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(EXECUTOR);
        assertFalse(ok, "un-whitelisted executor must be rejected");
        assertEq(bytes4(ret), INVALID_EXECUTOR, "expected InvalidExecutor");
    }

    /// @notice After whitelisting, the executor gate no longer fires. The swap still reverts (this
    ///         Prime Account holds no wAVAX and there is no ParaSwap router on the local chain), but
    ///         with a DIFFERENT error — proving the gate is what changed, not the whole call path.
    function testParaSwapV6PassesExecutorGateOnceWhitelisted() public {
        _whitelist(EXECUTOR);

        (bool ok, bytes memory ret) = _callParaSwapV6(EXECUTOR);
        assertFalse(ok, "empty-balance swap still reverts");
        assertTrue(bytes4(ret) != INVALID_EXECUTOR, "whitelisted executor must clear the executor gate");
    }

    /// @notice Whitelisting is per-address: granting one executor does not grant another.
    function testParaSwapV6RejectsADifferentExecutor() public {
        _whitelist(OTHER_EXECUTOR);

        (bool ok, bytes memory ret) = _callParaSwapV6(EXECUTOR);
        assertFalse(ok, "non-granted executor must be rejected");
        assertEq(bytes4(ret), INVALID_EXECUTOR, "expected InvalidExecutor");
    }

    /// @notice Delisting takes effect immediately for already-deployed facets — the whole point of
    ///         moving the set into the TokenManager (previously this needed a facet redeploy + cut).
    function testParaSwapV6RejectsAgainAfterDelisting() public {
        _whitelist(EXECUTOR);
        (, bytes memory retWhitelisted) = _callParaSwapV6(EXECUTOR);
        assertTrue(bytes4(retWhitelisted) != INVALID_EXECUTOR, "fixture broken: gate did not open");

        _delist(EXECUTOR);
        (bool ok, bytes memory ret) = _callParaSwapV6(EXECUTOR);
        assertFalse(ok, "delisted executor must be rejected");
        assertEq(bytes4(ret), INVALID_EXECUTOR, "expected InvalidExecutor after delisting");
    }

    /// @notice Negative control: the address(0) executor sentinel (the uniswap-v3 payload shape)
    ///         must NOT be gated, whitelist or not — otherwise swapExactAmountInOnUniswapV3 routes
    ///         would be bricked by this refactor.
    function testParaSwapV6ZeroExecutorIsNotGated() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(0));
        assertFalse(ok, "empty-balance swap still reverts");
        assertTrue(bytes4(ret) != INVALID_EXECUTOR, "address(0) executor must not trip the gate");
    }

    // ------------------------------------------------------------------
    // paraSwapBeforeLiquidation
    // ------------------------------------------------------------------

    /// @notice The liquidation entrypoint shares validateSwapParameters, and the executor gate runs
    ///         BEFORE the insolvency-snapshot requirement. Un-whitelisted → InvalidExecutor;
    ///         whitelisted → the snapshot requirement is what stops the call. The pair proves the
    ///         gate fired (and, in the second case, that it did not).
    function testParaSwapBeforeLiquidationExecutorGate() public {
        bytes memory data = _swapData(EXECUTOR, address(wavax), address(usdc), 1e18, 1);
        bytes memory cd =
            abi.encodeWithSelector(ParaSwapFacet.paraSwapBeforeLiquidation.selector, SWAP_EXACT_AMOUNT_IN, data);

        vm.prank(liquidator);
        (bool ok, bytes memory ret) = loan.call(cd);
        assertFalse(ok, "un-whitelisted executor must be rejected on the liquidation path");
        assertEq(bytes4(ret), INVALID_EXECUTOR, "expected InvalidExecutor");

        _whitelist(EXECUTOR);

        vm.prank(liquidator);
        (ok, ret) = loan.call(cd);
        assertFalse(ok, "no insolvency snapshot -> still reverts");
        assertTrue(
            _revertContains(ret, "No insolvency snapshot"),
            "whitelisted executor must clear the gate and stop at the snapshot requirement"
        );
    }

    // ------------------------------------------------------------------
    // swapDebtParaSwap
    // ------------------------------------------------------------------

    /// @notice The debt-swap entrypoint funnels through the same helper, so it inherits the
    ///         TokenManager-managed set too. Mirrors the ParaSwapGuards debt-swap setup: real AVAX
    ///         collateral + real USDC debt, refinanced USDC -> AVAX ($99 borrowed vs $100 repaid,
    ///         inside the 5% value-diff guard) so the call genuinely reaches the swap validation.
    function testSwapDebtParaSwapRevertsWhenExecutorNotWhitelisted() public {
        (address b, address l) = _createLoanFor("debtSwapExecUser");
        _fundAvax(b, l, 100e18); // $3,000 collateral
        vm.warp(block.timestamp + 1);

        vm.prank(b);
        RedstoneLib.wrapExpectSuccess(
            vm,
            l,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(),
            _prices()
        );
        vm.warp(block.timestamp + 1);

        uint256 borrowAvax = 3.3e18;
        bytes memory data = _swapData(EXECUTOR, address(wavax), address(usdc), borrowAvax, 1);

        vm.prank(b);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            l,
            abi.encodeWithSelector(
                SwapDebtFacet.swapDebtParaSwap.selector,
                bytes32("USDC"), // _fromAsset
                NATIVE_SYMBOL, // _toAsset
                uint256(100e6), // _repayAmount
                borrowAvax, // _borrowAmount
                SWAP_EXACT_AMOUNT_IN,
                data
            ),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "un-whitelisted executor must be rejected on the debt-swap path");
        assertEq(bytes4(ret), INVALID_EXECUTOR, "expected InvalidExecutor");
    }
}
