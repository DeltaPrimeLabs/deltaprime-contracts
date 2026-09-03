// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {TestERC20} from "../helpers/TestERC20.sol";
import {ParaSwapFacet} from "../../../contracts/facets/ParaSwapFacet.sol";
import {SwapDebtFacet} from "../../../contracts/facets/SwapDebtFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";

/**
 * GM/GLV-not-swappable guard (HackenProof DPSC-457 / DPSC-469).
 *
 * GMX GM market tokens and GLV tokens carry fee-aware accounting (performance-fee
 * benchmark) that the generic ParaSwap execution path does not respect, and they are
 * not routable through ParaSwap on-chain anyway (mint/redeem-only via the GMX keeper).
 * The fix rejects any swap whose source OR destination token is a whitelisted GM/GLV
 * market, across every entrypoint that funnels through ParaSwapHelper.getInitialTokensDetails:
 * paraSwapV6, paraSwapBeforeLiquidation and swapDebtParaSwap.
 *
 * GAP THIS CLOSES: the existing ParaSwap fork tests only ever swap WETH/WAVAX<->USDC;
 * no test ever passed a GM/GLV token as src or dest to any swap entrypoint.
 */
contract ParaSwapGuardsTest is DeltaPrimeFixture {
    // selector of the new custom error error GmGlvNotSwappable(address token);
    bytes4 internal constant GM_GLV_NOT_SWAPPABLE = bytes4(keccak256("GmGlvNotSwappable(address)"));
    // ParaSwap v6 SwapExactAmountIn selector (see ParaSwapHelper.SWAP_EXACT_AMOUNT_IN_SELECTOR)
    bytes4 internal constant SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;

    TestERC20 internal gm;
    TestERC20 internal glv;
    address internal borrower;
    address internal loan;

    function setUp() public override {
        super.setUp();

        // A whitelisted GM market token and a whitelisted GLV token.
        gm = new TestERC20("GM Market", "GM", 18);
        glv = new TestERC20("GLV Token", "GLV", 18);
        _whitelistGmxMarket(address(gm));
        _whitelistGlvToken(address(glv));

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

        // The WAVAX mock (contracts/mock/WAVAX.sol) leaves the standard
        // `src == msg.sender` allowance bypass commented out, so its transfer() needs a
        // self-allowance for the pool to lend out native on borrow. Real WAVAX9 does not
        // require this; it is a mock-only workaround so the debt-swap path can borrow AVAX.
        vm.prank(address(wavaxPool));
        wavax.approve(address(wavaxPool), type(uint256).max);

        (borrower, loan) = _createLoanFor("paraUser");
        vm.warp(block.timestamp + 1);
    }

    // ABI-encode a minimal-but-valid SwapExactAmountIn payload:
    // [executor(0)] [GenericData: src,dst,fromAmount,toAmount,quotedAmount(0),metadata(0),beneficiary(0)] [partnerAndFee(0)]
    function _swapData(address src, address dst, uint256 fromAmount, uint256 toAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            address(0), // executor
            src,
            dst,
            fromAmount,
            toAmount,
            uint256(0), // quotedAmount
            bytes32(0), // metadata
            address(0), // beneficiary
            uint256(0)  // partnerAndFee
        );
    }

    function _callParaSwapV6(address src, address dst) internal returns (bool ok, bytes memory ret) {
        bytes memory data = _swapData(src, dst, 1e18, 1);
        vm.prank(borrower);
        (ok, ret) = loan.call(
            abi.encodeWithSelector(ParaSwapFacet.paraSwapV6.selector, SWAP_EXACT_AMOUNT_IN, data)
        );
    }

    // ----------------------- paraSwapV6 -----------------------

    function testParaSwapV6RevertsWhenSrcIsGmMarket() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(gm), address(usdc));
        assertFalse(ok, "GM as src must be rejected");
        assertEq(bytes4(ret), GM_GLV_NOT_SWAPPABLE, "expected GmGlvNotSwappable");
    }

    function testParaSwapV6RevertsWhenDestIsGmMarket() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(usdc), address(gm));
        assertFalse(ok, "GM as dest must be rejected");
        assertEq(bytes4(ret), GM_GLV_NOT_SWAPPABLE, "expected GmGlvNotSwappable");
    }

    function testParaSwapV6RevertsWhenSrcIsGlvToken() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(glv), address(usdc));
        assertFalse(ok, "GLV as src must be rejected");
        assertEq(bytes4(ret), GM_GLV_NOT_SWAPPABLE, "expected GmGlvNotSwappable");
    }

    function testParaSwapV6RevertsWhenDestIsGlvToken() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(usdc), address(glv));
        assertFalse(ok, "GLV as dest must be rejected");
        assertEq(bytes4(ret), GM_GLV_NOT_SWAPPABLE, "expected GmGlvNotSwappable");
    }

    /// @notice Negative control: a normal (non-GM/GLV) token pair must NOT trip the guard.
    ///         It reverts for an unrelated reason (no balance / no route), proving the guard
    ///         is not over-blocking ordinary assets.
    function testParaSwapV6NormalTokensDoNotTripGuard() public {
        (bool ok, bytes memory ret) = _callParaSwapV6(address(usdc), address(wavax));
        assertFalse(ok, "empty-balance swap still reverts");
        assertTrue(bytes4(ret) != GM_GLV_NOT_SWAPPABLE, "must not be the GM/GLV guard");
    }

    // ----------------------- swapDebtParaSwap -----------------------

    /// @notice The same guard must reject a debt-swap whose ParaSwap payload moves a GM/GLV token.
    function testSwapDebtParaSwapRevertsWhenSwapDataUsesGmMarket() public {
        (address b, address l) = _createLoanFor("debtSwapper");
        _fundAvax(b, l, 100e18); // $3,000 collateral
        vm.warp(block.timestamp + 1);

        // Borrow $100 USDC so there is real from-asset debt to "refinance".
        vm.prank(b);
        RedstoneLib.wrapExpectSuccess(
            vm,
            l,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(),
            _prices()
        );
        vm.warp(block.timestamp + 1);

        // Refinance USDC -> AVAX, but the ParaSwap payload sells a GM market token.
        // 3.3 AVAX @ $30 = $99 vs $100 repay -> 1% value diff (< 5% guard).
        uint256 borrowAvax = 3.3e18;
        bytes memory data = _swapData(address(gm), address(usdc), borrowAvax, 1);

        vm.prank(b);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            l,
            abi.encodeWithSelector(
                SwapDebtFacet.swapDebtParaSwap.selector,
                bytes32("USDC"),   // _fromAsset
                NATIVE_SYMBOL,     // _toAsset
                uint256(100e6),    // _repayAmount
                borrowAvax,        // _borrowAmount
                SWAP_EXACT_AMOUNT_IN,
                data
            ),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "debt-swap moving a GM token must be rejected");
        assertEq(bytes4(ret), GM_GLV_NOT_SWAPPABLE, "expected GmGlvNotSwappable");
    }
}
