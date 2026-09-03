// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {SwapDebtFacet} from "../../../contracts/facets/SwapDebtFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {PrimeLeverageFacet} from "../../../contracts/facets/PrimeLeverageFacet.sol";
import {LeverageTierLib} from "../../../contracts/lib/LeverageTierLib.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";

/**
 * swapDebtParaSwap token-binding (HackenProof DPSC-460).
 *
 * swapDebtParaSwap is meant to refinance: borrow _toAsset, sell it via ParaSwap, buy
 * _fromAsset, repay the _fromAsset debt. v1.1.0 only checked fromAmount == _borrowAmount,
 * never binding the decoded ParaSwap srcToken/destToken to the declared assets. The fix
 * requires srcToken == _toAsset (the borrowed token) and destToken == _fromAsset (the
 * repaid token), so an unrelated swap can no longer create new debt while repaying nothing.
 *
 * GAP THIS CLOSES: SwapDebtFork.t.sol only runs the matched happy path (USDC<->ETH); no
 * test ever passed mismatched src/dest tokens.
 */
contract SwapDebtBindingTest is DeltaPrimeFixture {
    bytes4 internal constant SWAP_EXACT_AMOUNT_IN = 0xe3ead59e;

    function setUp() public override {
        super.setUp();

        // Fund both lending pools.
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

        // WAVAX mock needs a self-allowance for the pool to lend native (see ParaSwapGuards.t.sol).
        vm.prank(address(wavaxPool));
        wavax.approve(address(wavaxPool), type(uint256).max);

        // PREMIUM tier: cut PrimeLeverageFacet + set a non-zero staking ratio so the
        // PRIME-stake gate is exercised by the stake-sync test below.
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(
            address(new PrimeLeverageFacet()),
            IDiamondCut.FacetCutAction.Add,
            _primeLeverageSelectors()
        );
        IDiamondCut(address(beacon)).diamondCut(cuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();

        // 5 PRIME staked per $100 of max borrowable value (PREMIUM only).
        tokenManager.setTieredPrimeStakingRatio(LeverageTierLib.LeverageTier.PREMIUM, 5e18);
    }

    function _primeLeverageSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = PrimeLeverageFacet.stakePrimeAndActivatePremium.selector;
        s[1] = PrimeLeverageFacet.getLeverageTier.selector;
    }

    function _swapData(address src, address dst, uint256 fromAmount, uint256 toAmount)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            address(0), src, dst, fromAmount, toAmount, uint256(0), bytes32(0), address(0), uint256(0)
        );
    }

    /// Create a loan with $100 USDC debt against AVAX collateral.
    function _loanWithUsdcDebt() internal returns (address b, address l) {
        (b, l) = _createLoanFor("debtSwapper");
        _fundAvax(b, l, 100e18);
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
    }

    function _callSwapDebt(address l, address b, address src, address dst)
        internal
        returns (bool ok, bytes memory ret)
    {
        uint256 borrowAvax = 3.3e18; // ~$99 vs $100 repay -> within the 5% value guard
        bytes memory data = _swapData(src, dst, borrowAvax, 1);
        vm.prank(b);
        (ok, ret) = RedstoneLib.wrap(
            vm,
            l,
            abi.encodeWithSelector(
                SwapDebtFacet.swapDebtParaSwap.selector,
                bytes32("USDC"),  // _fromAsset
                NATIVE_SYMBOL,    // _toAsset (borrow AVAX)
                uint256(100e6),   // _repayAmount
                borrowAvax,       // _borrowAmount
                SWAP_EXACT_AMOUNT_IN,
                data
            ),
            _feeds(),
            _prices()
        );
    }

    /// srcToken must equal the borrowed _toAsset (AVAX). Passing PRIME instead is rejected.
    function testRevertsWhenSrcTokenIsNotBorrowedAsset() public {
        (address b, address l) = _loanWithUsdcDebt();
        // src = PRIME (wrong), dest = USDC (correct = _fromAsset)
        (bool ok, bytes memory ret) = _callSwapDebt(l, b, address(prime), address(usdc));
        assertFalse(ok, "mismatched srcToken must revert");
        assertTrue(_revertContains(ret, "sell the borrowed asset"), "expected src-binding revert");
    }

    /// destToken must equal the repaid _fromAsset (USDC). Passing PRIME instead is rejected.
    function testRevertsWhenDestTokenIsNotRepaidAsset() public {
        (address b, address l) = _loanWithUsdcDebt();
        // src = AVAX (correct = _toAsset), dest = PRIME (wrong)
        (bool ok, bytes memory ret) = _callSwapDebt(l, b, address(wavax), address(prime));
        assertFalse(ok, "mismatched destToken must revert");
        assertTrue(_revertContains(ret, "buy the repaid asset"), "expected dest-binding revert");
    }

    /// swapDebt must run the same PRIME debt-snapshot + stake sync as borrow(). A PREMIUM
    /// account whose collateral grew after activation (raising the required stake) and that has
    /// no free PRIME left must be unable to refinance through swapDebt — exactly as a normal
    /// borrow() would be blocked. (HackenProof DPSC-460, second inconsistency.)
    function testRevertsWhenPremiumStakeRequirementUnmet() public {
        (address b, address l) = _createLoanFor("premiumSwapper");
        _fundAvax(b, l, 100e18); // $3,000 equity -> required stake 1,500 PRIME

        // Mint + stake exactly the required PRIME, activate PREMIUM (no free PRIME left).
        prime.mint(l, 1_500e18);
        vm.warp(block.timestamp + 1);
        vm.prank(b);
        RedstoneLib.wrapExpectSuccess(
            vm, l, abi.encodeWithSelector(PrimeLeverageFacet.stakePrimeAndActivatePremium.selector), _feeds(), _prices()
        );

        // Borrow $100 USDC to refinance; stake requirement unchanged at this equity (no-op).
        vm.warp(block.timestamp + 1);
        vm.prank(b);
        RedstoneLib.wrapExpectSuccess(
            vm,
            l,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(),
            _prices()
        );

        // Add more collateral: required stake roughly doubles, but no free PRIME remains.
        // (fund() is also noBorrowInTheSameBlock-gated, so advance past the borrow block first.)
        vm.warp(block.timestamp + 1);
        _fundAvax(b, l, 100e18);
        vm.warp(block.timestamp + 1);

        uint256 borrowAvax = 3.3e18;
        bytes memory data = _swapData(address(wavax), address(usdc), borrowAvax, 1); // correct binding
        vm.prank(b);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            l,
            abi.encodeWithSelector(
                SwapDebtFacet.swapDebtParaSwap.selector,
                bytes32("USDC"),
                NATIVE_SYMBOL,
                uint256(100e6),
                borrowAvax,
                SWAP_EXACT_AMOUNT_IN,
                data
            ),
            _feeds(),
            _prices()
        );
        assertFalse(ok, "swapDebt must enforce the PRIME stake top-up");
        assertTrue(_revertContains(ret, "Insufficient PRIME balance"), "expected PRIME stake gate");
    }
}
