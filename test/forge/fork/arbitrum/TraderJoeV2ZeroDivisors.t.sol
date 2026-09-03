// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {ArbitrumYieldForkFixture} from "../../fixtures/ArbitrumYieldForkFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITraderJoeV2Facet} from "../../../../contracts/interfaces/facets/avalanche/ITraderJoeV2Facet.sol";
import {ILBRouter} from "../../../../contracts/interfaces/joe-v2/ILBRouter.sol";
import {TraderJoeV2Facet} from "../../../../contracts/facets/TraderJoeV2Facet.sol";
import {TraderJoeV2ArbitrumFacet} from "../../../../contracts/facets/arbitrum/TraderJoeV2ArbitrumFacet.sol";
import {IDiamondCut} from "../../../../contracts/interfaces/IDiamondCut.sol";
import {DiamondLoupeFacet} from "../../../../contracts/facets/DiamondLoupeFacet.sol";
import {HealthMeterFacetProd} from "../../../../contracts/facets/HealthMeterFacetProd.sol";

interface ILBPairView {
    function getActiveId() external view returns (uint24);
    function getPriceFromId(uint24 id) external view returns (uint256);
    function totalSupply(uint256 id) external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function approveForAll(address spender, bool approved) external;
}

/**
 * @title TraderJoeV2ZeroDivisorsForkTest
 * @notice Live-diamond regression coverage for the two zero divisors a tracked TraderJoe V2 bin can
 *         carry into `SolvencyFacetProd._getTotalTraderJoeV2`. Either one used to make EVERY
 *         solvency read on the account revert `Panic(0x12)`, which in turn made the account
 *         impossible to snapshot and therefore impossible to liquidate while its debt stayed live.
 *
 *           price = PriceHelper.convert128x128PriceToDecimal(pair.getPriceFromId(bin.id));
 *           ...
 *           debtCoverageX * liquidity / price ...                 // (1) price == 0
 *           .mulDivRoundDown(1e18, pair.totalSupply(bin.id));     // (2) totalSupply == 0
 *
 *         (1) the 128.128 -> decimal conversion is `p128 * 1e18 >> 128`, a round-DOWN shift, so
 *             every bin priced under 1e-18 of the pair ratio maps to a decimal price of zero. On a
 *             live pair that is the whole band a few thousand bins below the active id.
 *         (2) a bin nobody holds liquidity in has a zero LB-token total supply. The account's own
 *             balance in such a bin is necessarily zero too, so its contribution is zero either way
 *             - but the division ran before that could matter.
 *
 *         Both states are reached here by mocking the live pair, which keeps the coverage
 *         independent of whichever TraderJoe facet version happens to be cut into the diamond.
 *         `testZeroAmountFundIsRejected` covers the entry-side guard that stops a bin the account
 *         holds nothing in from being registered in the first place.
 *
 * @dev Gated - SKIPS under the default test config. Run with RUN_GMX_FORK=true, the arbitrum chain
 *      config selected, and a pinned ARBITRUM_FORK_BLOCK.
 */
contract TraderJoeV2ZeroDivisorsForkTest is ArbitrumYieldForkFixture {
    address internal constant LB_ROUTER_V22 = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address internal constant PAIR_WETH_USDC = 0xb7236B927e03542AC3bE0A054F2bEa8868AF9508; // whitelisted, binStep 10
    uint16 internal constant BIN_STEP = 10;

    uint256 internal constant ADD_WETH = 0.1 ether;
    uint256 internal constant ADD_USDC = 10e6;

    // ── (1) zero decimal price ────────────────────────────────────────────────────────────────

    function testZeroPriceBinDoesNotBrickSolvency() public {
        uint256 binId = _openSingleBinPosition();
        uint256 valueBefore = _readValue("getTotalValue()");
        assertGt(valueBefore, 0, "baseline: the account must hold value");

        // Force the bin's 128.128 price to 1, which truncates to a decimal price of exactly zero -
        // the state every bin far enough below the active one is already in on-chain.
        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.getPriceFromId.selector, uint24(binId)), abi.encode(uint256(1))
        );
        assertEq((ILBPairView(PAIR_WETH_USDC).getPriceFromId(uint24(binId)) * 1e18) >> 128, 0, "mock did not produce a zero decimal price");

        // Every solvency read must survive, and the zero-priced bin must simply stop contributing.
        uint256 valueAfter = _readValue("getTotalValue()");
        assertLt(valueAfter, valueBefore, "the zero-priced bin should no longer contribute value");
        _readValue("getThresholdWeightedValue()");
        _readValue("getHealthRatio()");
        _readValue("isSolvent()");
    }

    // ── (2) zero bin total supply ─────────────────────────────────────────────────────────────

    function testEmptyBinDoesNotBrickSolvency() public {
        uint256 binId = _openSingleBinPosition();
        uint256 valueBefore = _readValue("getTotalValue()");
        assertGt(valueBefore, 0, "baseline: the account must hold value");

        // An empty tracked bin: nobody holds liquidity in it, so both the account's balance and the
        // bin's total supply are zero. Mocked together because they cannot diverge on-chain.
        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.totalSupply.selector, binId), abi.encode(uint256(0))
        );
        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.balanceOf.selector, loan, binId), abi.encode(uint256(0))
        );

        uint256 valueAfter = _readValue("getTotalValue()");
        assertLt(valueAfter, valueBefore, "the empty bin should no longer contribute value");
        _readValue("getThresholdWeightedValue()");
        _readValue("getHealthRatio()");
        _readValue("isSolvent()");
    }

    // ── (3) the same two divisors in HealthMeterFacetProd ─────────────────────────────────────
    //
    // `HealthMeterFacetProd._getTotalTraderJoeV2Weighted` is a second copy of the bin-valuation
    // loop above. `getHealthMeter()` is the read a liquidation keeper ranks accounts by, so while
    // it gates no on-chain operation, a revert there hides a poisoned account from monitoring.

    function testZeroPriceBinDoesNotBrickHealthMeter() public {
        uint256 binId = _openSingleBinPosition();
        _cutLocalHealthMeterFacet();
        assertGt(_readValue("getHealthMeter()"), 0, "baseline: the account must have a health meter");

        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.getPriceFromId.selector, uint24(binId)), abi.encode(uint256(1))
        );

        _readValue("getHealthMeter()");
    }

    function testEmptyBinDoesNotBrickHealthMeter() public {
        uint256 binId = _openSingleBinPosition();
        _cutLocalHealthMeterFacet();
        assertGt(_readValue("getHealthMeter()"), 0, "baseline: the account must have a health meter");

        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.totalSupply.selector, binId), abi.encode(uint256(0))
        );
        vm.mockCall(
            PAIR_WETH_USDC, abi.encodeWithSelector(ILBPairView.balanceOf.selector, loan, binId), abi.encode(uint256(0))
        );

        _readValue("getHealthMeter()");
    }

    // ── entry-side guard ──────────────────────────────────────────────────────────────────────

    function testZeroAmountFundIsRejected() public {
        _cutLocalTraderJoeFacet();

        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        ids[0] = 8329416; // any bin; the guard trips before the transfer is attempted
        amounts[0] = 0;

        vm.prank(user);
        ILBPairView(PAIR_WETH_USDC).approveForAll(loan, true);

        vm.warp(block.timestamp + 1); // noBorrowInTheSameBlock
        vm.prank(user);
        (bool ok, bytes memory ret) = loan.call(
            abi.encodeWithSelector(ITraderJoeV2Facet.fundLiquidityTraderJoeV2.selector, PAIR_WETH_USDC, ids, amounts)
        );
        assertFalse(ok, "funding a zero LB amount must revert");
        assertEq(bytes4(ret), TraderJoeV2Facet.ZeroFundedAmount.selector, "expected ZeroFundedAmount()");
        assertEq(_ownedBinsCount(), 0, "no bin may be registered by a rejected fund");

        // A non-zero amount must get PAST the guard - it fails later, on the LB-token transfer of a
        // balance the owner does not have, which is the pre-existing behaviour.
        amounts[0] = 1;
        vm.prank(user);
        (bool ok2, bytes memory ret2) = loan.call(
            abi.encodeWithSelector(ITraderJoeV2Facet.fundLiquidityTraderJoeV2.selector, PAIR_WETH_USDC, ids, amounts)
        );
        assertFalse(ok2, "the owner holds no LB tokens, so the transfer still fails");
        assertTrue(bytes4(ret2) != TraderJoeV2Facet.ZeroFundedAmount.selector, "a non-zero amount must not trip the zero guard");
    }

    // ── helpers ───────────────────────────────────────────────────────────────────────────────

    /// @dev Provide real liquidity to the live active bin so the account tracks exactly one bin.
    function _openSingleBinPosition() internal returns (uint256 binId) {
        _fundToken(SYM_USDC, USDC, ADD_USDC);
        assertEq(_ownedBinsCount(), 0, "unexpected pre-existing TJ-V2 bins");

        uint24 activeId = ILBPairView(PAIR_WETH_USDC).getActiveId();
        _wrapSolventExpectSuccess(
            abi.encodeWithSelector(
                ITraderJoeV2Facet.addLiquidityTraderJoeV2.selector, ILBRouter(LB_ROUTER_V22), _singleBinParams(activeId)
            )
        );

        ITraderJoeV2Facet.TraderJoeV2Bin[] memory bins = ITraderJoeV2Facet(loan).getOwnedTraderJoeV2Bins();
        assertEq(bins.length, 1, "expected exactly one tracked bin");
        binId = bins[0].id;
        assertGt(ILBPairView(PAIR_WETH_USDC).balanceOf(loan, binId), 0, "no LB tokens minted to the PA");
    }

    function _ownedBinsCount() internal view returns (uint256) {
        return ITraderJoeV2Facet(loan).getOwnedTraderJoeV2Bins().length;
    }

    /// @dev Wrapped solvency read that must NOT revert; returns the decoded word.
    function _readValue(string memory signature) internal returns (uint256 value) {
        (bool ok, bytes memory ret) = _wrapSolvent(abi.encodeWithSignature(signature));
        assertTrue(ok, string.concat(signature, " must not revert on a bin carrying a zero divisor"));
        value = abi.decode(ret, (uint256));
    }

    /// @dev Replace the live TraderJoe facet's `fundLiquidityTraderJoeV2` with the local build, so
    ///      the entry-side guard under test is the one in this repo rather than whatever is cut in.
    function _cutLocalTraderJoeFacet() internal {
        bytes4 selector = ITraderJoeV2Facet.fundLiquidityTraderJoeV2.selector;
        require(DiamondLoupeFacet(BEACON).facetAddress(selector) != address(0), "fixture: fundLiquidity not routed");

        address testFacet = makeAddr("traderJoeV2FacetLocal");
        vm.etch(testFacet, type(TraderJoeV2ArbitrumFacet).runtimeCode);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(testFacet, IDiamondCut.FacetCutAction.Replace, selectors);

        (address owner_, address pauseAdmin_) = _beaconAdmins();
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).pause();
        vm.prank(owner_);
        IDiamondCut(BEACON).diamondCut(cuts, address(0), "");
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).unpause();

        require(DiamondLoupeFacet(BEACON).facetAddress(selector) == testFacet, "fixture: fundLiquidity not remapped");
    }

    /// @dev Replace the live `getHealthMeter()` with the local build, so the guards under test are
    ///      the ones in this repo rather than whatever is cut into the diamond.
    function _cutLocalHealthMeterFacet() internal {
        bytes4 selector = HealthMeterFacetProd.getHealthMeter.selector;
        require(DiamondLoupeFacet(BEACON).facetAddress(selector) != address(0), "fixture: getHealthMeter not routed");

        address testFacet = makeAddr("healthMeterFacetLocal");
        vm.etch(testFacet, type(HealthMeterFacetProd).runtimeCode);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut(testFacet, IDiamondCut.FacetCutAction.Replace, selectors);

        (address owner_, address pauseAdmin_) = _beaconAdmins();
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).pause();
        vm.prank(owner_);
        IDiamondCut(BEACON).diamondCut(cuts, address(0), "");
        vm.prank(pauseAdmin_);
        IDiamondCut(BEACON).unpause();

        require(DiamondLoupeFacet(BEACON).facetAddress(selector) == testFacet, "fixture: getHealthMeter not remapped");
    }

    /// @dev Single-bin (active-bin) liquidity params, idSlippage maxed to tolerate bin drift.
    function _singleBinParams(uint24 activeId) internal view returns (ILBRouter.LiquidityParameters memory p) {
        int256[] memory deltaIds = new int256[](1);
        deltaIds[0] = 0;
        uint256[] memory distX = new uint256[](1);
        distX[0] = 1e18;
        uint256[] memory distY = new uint256[](1);
        distY[0] = 1e18;

        p = ILBRouter.LiquidityParameters({
            tokenX: IERC20(WETH),
            tokenY: IERC20(USDC),
            binStep: BIN_STEP,
            amountX: ADD_WETH,
            amountY: ADD_USDC,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: activeId,
            idSlippage: 16777215,
            deltaIds: deltaIds,
            distributionX: distX,
            distributionY: distY,
            to: loan,
            refundTo: loan,
            deadline: block.timestamp + 1000
        });
    }
}
