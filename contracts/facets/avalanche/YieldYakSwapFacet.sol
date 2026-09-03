// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: ab0885e12c84fa9d3f0a7206af57350bca360edb;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../../interfaces/facets/IYieldYakRouter.sol";
import "../../ReentrancyGuardKeccak.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {DiamondStorageLib} from "../../lib/DiamondStorageLib.sol";
import "../../lib/DiamondMethodsAccess.sol";
import "../../interfaces/ITokenManager.sol";
import "../../PrimeAccountModifiers.sol";

//This path is updated during deployment
import "../../lib/DeploymentConstants.sol";

contract YieldYakSwapFacet is ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers {
    using TransferHelper for address;

    uint256 private constant MAX_BPS = 10000;
    uint256 private constant MAX_SLIPPAGE_BPS = 500; // 5% per-swap cap vs oracle price (mirrors ParaSwapHelper)
    uint256 private constant PRICE_DECIMALS = 10; // RedStone prices are 8-decimals; scaling matches ParaSwapHelper

    struct SwapTokensDetails {
        bytes32 tokenSoldSymbol;
        bytes32 tokenBoughtSymbol;
        IERC20Metadata soldToken;
        IERC20Metadata boughtToken;
        uint256 initialSoldTokenBalance;
        uint256 initialBoughtTokenBalance;
    }

    function getInitialTokensDetails(address _soldTokenAddress, address _boughtTokenAddress) internal returns (SwapTokensDetails memory){
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        if (_boughtTokenAddress == 0xaE64d55a6f09E4263421737397D1fdFA71896a69) {
            _boughtTokenAddress = 0x9e295B5B976a184B14aD8cd72413aD846C299660;
        }

        if (_soldTokenAddress == 0x9e295B5B976a184B14aD8cd72413aD846C299660) {
            _soldTokenAddress = 0xaE64d55a6f09E4263421737397D1fdFA71896a69;
        }

        bytes32 _tokenSoldSymbol = tokenManager.tokenAddressToSymbol(_soldTokenAddress);
        bytes32 _tokenBoughtSymbol = tokenManager.tokenAddressToSymbol(_boughtTokenAddress);

        require(tokenManager.isTokenAssetActive(_boughtTokenAddress), "Asset not supported.");

        IERC20Metadata _soldToken = IERC20Metadata(_soldTokenAddress);
        IERC20Metadata _boughtToken = IERC20Metadata(_boughtTokenAddress);

        return SwapTokensDetails({
            tokenSoldSymbol: _tokenSoldSymbol,
            tokenBoughtSymbol: _tokenBoughtSymbol,
            soldToken: _soldToken,
            boughtToken: _boughtToken,
            initialSoldTokenBalance: _soldToken.balanceOf(address(this)),
            initialBoughtTokenBalance: _boughtToken.balanceOf(address(this))
        });
    }

    function isWhitelistedAdapterOptimized(address adapter) public virtual view returns (bool) {
        IYieldYakRouter router = IYieldYakRouter(YY_ROUTER());
        uint256 count = router.adaptersCount();
        for (uint256 i = 0; i < count; i++) {
            if (router.ADAPTERS(i) == adapter) {
                return true;
            }
        }
        return false;
    }

    function yakSwap(
        uint256 _amountIn,
        uint256 _amountOut,
        address[] calldata _path,
        address[] calldata _adapters
    ) external nonReentrant onlyOwner noBorrowInTheSameBlock remainsSolvent notInLiquidation {
        IYieldYakRouter router = IYieldYakRouter(YY_ROUTER());

        // Check if all adapters are whitelisted in router
        for (uint256 i = 0; i < _adapters.length; i++) {
            require(isWhitelistedAdapterOptimized(_adapters[i]), "YakSwap: Adapter not whitelisted in router");
        }

        SwapTokensDetails memory swapTokensDetails = getInitialTokensDetails(_path[0], _path[_path.length - 1]);

        _amountIn = Math.min(_getAvailableBalance(swapTokensDetails.tokenSoldSymbol), _amountIn);
        require(_amountIn > 0, "Amount of tokens to sell has to be greater than 0 / Insufficient balance");
        

        address(swapTokensDetails.soldToken).safeApprove(YY_ROUTER(), 0);
        address(swapTokensDetails.soldToken).safeApprove(YY_ROUTER(), _amountIn);

        IYieldYakRouter.Trade memory trade = IYieldYakRouter.Trade({
            amountIn: _amountIn,
            amountOut: _amountOut,
            path: _path,
            adapters: _adapters
        });

        router.swapNoSplit(trade, address(this), 0);

        uint256 boughtTokenFinalAmount = swapTokensDetails.boughtToken.balanceOf(address(this)) - swapTokensDetails.initialBoughtTokenBalance;
        require(boughtTokenFinalAmount >= _amountOut, "Insufficient output amount");

        uint256 soldTokenFinalAmount = swapTokensDetails.initialSoldTokenBalance - swapTokensDetails.soldToken.balanceOf(address(this));

        // Bound realised output against oracle prices (5% cap, mirrors
        // ParaSwapHelper.checkSlippage). Defense-in-depth on top of remainsSolvent, limiting
        // MEV / self-sandwich value leakage through thin whitelisted pools.
        _checkOracleSlippage(swapTokensDetails, soldTokenFinalAmount, boughtTokenFinalAmount);

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        _syncExposure(tokenManager, address(swapTokensDetails.boughtToken));
        _syncExposure(tokenManager, address(swapTokensDetails.soldToken));

        // revoke unused approval
        address(swapTokensDetails.soldToken).safeApprove(YY_ROUTER(), 0);

        emit Swap(
            msg.sender,
            swapTokensDetails.tokenSoldSymbol,
            swapTokensDetails.tokenBoughtSymbol,
            soldTokenFinalAmount,
            boughtTokenFinalAmount,
            block.timestamp
        );
    }

    /**
     * @dev Reverts if the realised swap output is worse than the oracle-implied value by
     *      MAX_SLIPPAGE_BPS or more. Mirrors ParaSwapHelper.checkSlippage. Applies to every
     *      swap: both legs are registered, priceable assets by the time this runs (see the
     *      note in the body), so there is no leg the cap can legitimately be skipped for.
     */
    function _checkOracleSlippage(
        SwapTokensDetails memory details,
        uint256 soldAmount,
        uint256 boughtAmount
    ) internal view {
        // Both legs are provably registered by the time this runs, so there is no
        // unpriceable-leg case to skip: the sold leg passed
        // `_getAvailableBalance(tokenSoldSymbol)` above, which reverts "Asset not supported."
        // on a zero symbol, and `getInitialTokensDetails` requires the bought leg to be an
        // ACTIVE token asset (TokenManager keeps symbol and status in lockstep). An earlier
        // revision skipped the cap when either symbol was zero; that branch was unreachable
        // and, being a silent fail-open on a security check, was the wrong default. If the
        // invariant is ever broken upstream, `getPrices` reverts rather than waving the swap
        // through.
        bytes32[] memory symbols = new bytes32[](2);
        symbols[0] = details.tokenSoldSymbol;
        symbols[1] = details.tokenBoughtSymbol;
        uint256[] memory prices = getPrices(symbols);
        require(prices.length == 2, "Invalid price data");

        uint256 soldTokenDollarValue = prices[0] * soldAmount * (10 ** PRICE_DECIMALS) / (10 ** details.soldToken.decimals());
        uint256 boughtTokenDollarValue = prices[1] * boughtAmount * (10 ** PRICE_DECIMALS) / (10 ** details.boughtToken.decimals());

        if (soldTokenDollarValue > boughtTokenDollarValue) {
            uint256 slippage = ((soldTokenDollarValue - boughtTokenDollarValue) * MAX_BPS) / soldTokenDollarValue;
            require(slippage < MAX_SLIPPAGE_BPS, "YakSwap: slippage too high vs oracle");
        }
    }

    function YY_ROUTER() internal virtual pure returns (address) {
        return 0xC4729E56b831d74bBc18797e0e17A295fA77488c;
    }

    /**
     * @dev emitted after a swap of assets
     * @param user the address of user making the purchase
     * @param soldAsset sold by the user
     * @param boughtAsset bought by the user
     * @param amountSold amount of tokens sold
     * @param amountBought amount of tokens bought
     * @param timestamp time of the swap
     **/
    event Swap(address indexed user, bytes32 indexed soldAsset, bytes32 indexed boughtAsset, uint256 amountSold, uint256 amountBought, uint256 timestamp);
}
