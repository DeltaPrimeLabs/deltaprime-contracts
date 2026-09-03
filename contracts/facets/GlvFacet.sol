// SPDX-License-Identifier: BUSL-1.1
// GLV Facet for interacting with GMX V2 GLV (GMX Liquidity Vault) tokens
pragma solidity 0.8.17;

import "../ReentrancyGuardKeccak.sol";
import "../PrimeAccountModifiers.sol";
import "../lib/GmxV2FeesHelper.sol";
import {GlvHelper} from "../lib/GlvHelper.sol";
import {IGlvDepositUtils} from "../interfaces/gmx-v2/IGlvDepositUtils.sol";
import {IGlvWithdrawalUtils} from "../interfaces/gmx-v2/IGlvWithdrawalUtils.sol";
import {IGlvReader} from "../interfaces/gmx-v2/IGlvReader.sol";
import {ISmartLoanLiquidationFacet} from "../interfaces/facets/ISmartLoanLiquidationFacet.sol";


abstract contract GlvFacet is ReentrancyGuardKeccak, PrimeAccountModifiers, GmxV2FeesHelper, GlvHelper {
    using TransferHelper for address;

    

    // ============ ABSTRACT FUNCTIONS ============
    
    function getGlvRouter() internal pure virtual returns (address);
    function getGmxV2Router() internal pure virtual returns (address);
    function getGmxV2GlvDepositVault() internal pure virtual returns (address);
    function getGmxV2GlvWithdrawalVault() internal pure virtual returns (address);

    
    


    // ============ DEPOSIT LOGIC ============

    function _depositGlv(
        address gmToken,
        address depositedToken,
        uint256 tokenAmount,
        address targetMarket,
        uint256 minGlvAmount,
        uint256 executionFee
    ) internal nonReentrant noBorrowInTheSameBlock onlyOwner notInLiquidation {
        if (executionFee != msg.value) revert InvalidExecutionFee();
        
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        if (!tokenManager.isGlvTokenWhitelisted(gmToken)) revert GlvTokenNotWhitelisted();
        
        if(!tokenManager.isTokenAssetActive(depositedToken)) revert DepositTokenInactive();

        if(!tokenManager.isGmxMarketWhitelisted(targetMarket)) revert MarketNotWhitelisted();

        tokenAmount = IERC20(depositedToken).balanceOf(address(this)) < tokenAmount
            ? IERC20(depositedToken).balanceOf(address(this))
            : tokenAmount;

        if (tokenAmount == 0) revert ZeroDepositAmount();
        if (_getAvailableBalancePayable(tokenManager.tokenAddressToSymbol(depositedToken)) < tokenAmount) 
            revert InsufficientBalance();
        
        
        (address longToken, address shortToken) = _getLongAndShortTokens(gmToken);
        if( depositedToken != longToken && depositedToken != shortToken ) 
            revert WrongDepositToken();

        if (!_validateTargetMarket(targetMarket, gmToken)) 
            revert InvalidTargetMarket();
           
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(gmToken);
        GmxTokenPrices memory gmTokenPrice = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });

        {    
            DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmToken);
            if(benchmark.exists) {
                uint256 collectedFees = _sweepFees(gmToken, gmTokenPrice);
                if (collectedFees > 0) {
                    emit GlvFeesSweptDuringOperation(gmToken, collectedFees, "deposit", block.timestamp);
                }
            } 
        }

        _generateDataAndDoMultiCallForDeposit(
            gmToken,
            depositedToken,
            tokenAmount,
            targetMarket,
            minGlvAmount,
            executionFee,
            longToken, 
            shortToken
        );
        ///@dev simulating solvency check
        _simulateSolvencyCheckForDeposit(
            gmToken,
            depositedToken,
            tokenAmount,
            minGlvAmount,
            pricesAndAddresses
        );
        
        _updateGlvPositionBenchmark(gmToken, pricesAndAddresses);
        DiamondStorageLib.freezeAccount(gmToken);

        // Reserve pending exposure for the GLV token GMX will mint asynchronously, mirroring
        // GmxV2Facet._deposit. The GLV deposit execution + cancellation callbacks already clear
        // this pending entry through the shared _handleDeposit* cleanup.
        tokenManager.increasePendingExposure(
            tokenManager.tokenAddressToSymbol(gmToken),
            address(this),
            (minGlvAmount * 1e18) / 10 ** IERC20Metadata(gmToken).decimals()
        );

        _syncExposure(tokenManager, gmToken);

        _syncExposure(tokenManager, depositedToken);

        emit GlvDepositInitiated(gmToken, targetMarket, depositedToken, tokenAmount, minGlvAmount, executionFee, block.timestamp);
    }

    // ============ WITHDRAWAL LOGIC ============

    function _withdrawGlv(
        address gmToken,
        uint256 glvAmount,
        address targetMarket,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    ) internal nonReentrant noBorrowInTheSameBlock onlyOwnerOrLiquidationWithNoSolvencyCheck {
        if (executionFee != msg.value) revert InvalidExecutionFee();
        
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        if (!tokenManager.isGlvTokenWhitelisted(gmToken)) revert GlvTokenNotWhitelisted();

        if(!tokenManager.isGmxMarketWhitelisted(targetMarket)) revert MarketNotWhitelisted();

        if (!_validateTargetMarket(targetMarket, gmToken)) 
            revert InvalidTargetMarket();

        glvAmount = IERC20(gmToken).balanceOf(address(this)) < glvAmount
            ? IERC20(gmToken).balanceOf(address(this))
            : glvAmount;

        if (glvAmount == 0) revert ZeroWithdrawalAmount();
        if (_getAvailableBalancePayable(tokenManager.tokenAddressToSymbol(gmToken)) < glvAmount) 
            revert InsufficientBalance();
        

        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(gmToken);
        GmxTokenPrices memory gmTokenPrice = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });
        
        {
            DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmToken);
            if(benchmark.exists) {
                uint256 collectedFees = _sweepFees(gmToken, gmTokenPrice);
                if (collectedFees > 0) {
                    if (glvAmount <= collectedFees) {
                        revert InsufficientBalanceAfterFees();
                    }
                    glvAmount -= collectedFees;
                    emit GlvFeesSweptDuringOperation(gmToken, collectedFees, "withdraw", block.timestamp);
                }
            } 
        }
        
        _generateDataAndDoMultiCallForWithdrawal(
            gmToken,
            glvAmount,
            targetMarket,
            minLongTokenAmount,
            minShortTokenAmount,
            executionFee
        );

        _simulateSolvencyCheckForWithdraw(gmToken, glvAmount, minLongTokenAmount, minShortTokenAmount, pricesAndAddresses);
        

        DiamondStorageLib.freezeAccount(gmToken);

        _updateGlvPositionBenchmark(gmToken, pricesAndAddresses);
        (address longToken, address shortToken) = _getLongAndShortTokens(gmToken);

        // Reserve pending exposure for the long/short tokens GMX will deliver asynchronously,
        // mirroring GmxV2Facet._withdraw. Without this an over-cap GLV withdrawal passes
        // initiation and the settlement callback's exposure sync reverts, leaving the account
        // frozen. The GLV execution + cancellation callbacks already clear these pending entries
        // through the shared _handleWithdrawal* cleanup.
        tokenManager.increasePendingExposure(
            tokenManager.tokenAddressToSymbol(longToken),
            address(this),
            (minLongTokenAmount * 1e18) / 10 ** IERC20Metadata(longToken).decimals()
        );
        tokenManager.increasePendingExposure(
            tokenManager.tokenAddressToSymbol(shortToken),
            address(this),
            (minShortTokenAmount * 1e18) / 10 ** IERC20Metadata(shortToken).decimals()
        );

        _syncExposure(tokenManager, longToken);
        _syncExposure(tokenManager, shortToken);

        _syncExposure(tokenManager, gmToken);

        emit GlvWithdrawalInitiated(
            gmToken,
            targetMarket,
            glvAmount,
            minLongTokenAmount,
            minShortTokenAmount,
            executionFee,
            block.timestamp
        );
    }


    // ============ FEE SPECIFIC FUNCTIONS ============


    function getGlvPerformance(address glvToken) external view returns (uint256) {
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(glvToken);
        return _getGmAnnualisedPerformance(glvToken, pricesAndAddresses.gmTokenPrice, pricesAndAddresses.longTokenPrice, pricesAndAddresses.shortTokenPrice);
    }

    ///@dev to be called by the bots, sweeps fees and updates the benchmark
    function sweepFeesAndUpdateGlvBenchMark(address glvToken) external nonReentrant onlyWhitelistedLiquidators remainsSolvent returns (uint256 gmTokensInFees) {
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(glvToken);
        GmxTokenPrices memory glvTokenPrices = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });

        gmTokensInFees = _sweepFees(glvToken, glvTokenPrices);
        _updateGlvPositionBenchmark(glvToken, pricesAndAddresses);
        
        emit FeesSweptAndGlvBenchmarkUpdated(glvToken, gmTokensInFees, msg.sender, block.timestamp);
    }

    // ============ HELPER FUNCTIONS ============

    ///@dev returns the long and short tokens for a given GLV token by querying the GlvReader
    function _getLongAndShortTokens(address glvToken) internal view returns (address longToken, address shortToken) {
        address glvReader = DeploymentConstants.getGlvReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        
        IGlvReader.Props memory props = IGlvReader(glvReader).getGlv(dataStore, glvToken);
        
        longToken = props.longToken;
        shortToken = props.shortToken;

        if( longToken == address(0) || shortToken == address(0) ) 
            revert InvalidGlvToken();
    }

    

    ///@dev updates the benchmark for the GLV position, a derivative of GmxV2Facet::_updateGmxPositionBenchmark
    function _updateGlvPositionBenchmark(address gmToken, UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses) internal {
        uint256 glvBalance = IERC20(gmToken).balanceOf(address(this));
        (uint256 longTokenAmount, uint256 shortTokenAmount) = _getGlvLongAndShortTokenAmounts(gmToken, glvBalance);
        
        GmxPositionDetails memory positionDetails = GmxPositionDetails({
            underlyingLongTokenAmount: longTokenAmount,
            underlyingShortTokenAmount: shortTokenAmount,
            gmTokenPriceUsd: pricesAndAddresses.gmTokenPrice,
            longTokenPriceUsd: pricesAndAddresses.longTokenPrice,
            shortTokenPriceUsd: pricesAndAddresses.shortTokenPrice,
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: pricesAndAddresses.longToken,
            shortTokenAddress: pricesAndAddresses.shortToken
        });
        _createOrUpdatePositionBenchmark(gmToken, positionDetails);
    }


    function _validateTargetMarket(address targetMarket, address glvToken) internal view returns (bool) {
        address glvReader = DeploymentConstants.getGlvReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        IGlvReader.GlvInfo memory glvInfo = IGlvReader(glvReader).getGlvInfo(dataStore, glvToken);
        address[] memory markets = glvInfo.markets;
        for (uint256 i = 0; i < markets.length; i++) {
            if (markets[i] == targetMarket) {
                return true;
            }
        }
        return false;      
    }

    ///@dev a code block inside the _depositGlv function was triggering "Stack too deep" error, so moved to a separate function
    function _generateDataAndDoMultiCallForDeposit(
        address gmToken,
        address depositedToken,
        uint256 tokenAmount,
        address targetMarket,
        uint256 minGlvAmount,
        uint256 executionFee,
        address longToken,
        address shortToken) internal {
        bytes[] memory data = new bytes[](3);
        
        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGmxV2GlvDepositVault(),
            executionFee
        );
        
        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            depositedToken,
            getGmxV2GlvDepositVault(),
            tokenAmount
        );
        
        data[2] = abi.encodeWithSelector(
            ///@dev calls the GlvRouter
            /// https://github.com/gmx-io/gmx-synthetics/blob/7c502568117500181b3e8ce5520e95402c6102d6/contracts/router/GlvRouter.sol#L42
            IGlvDepositUtils.createGlvDeposit.selector,
            IGlvDepositUtils.CreateGlvDepositParams({
                addresses: IGlvDepositUtils.CreateGlvDepositParamsAddresses({
                    glv: gmToken,
                    market: targetMarket,
                    receiver: address(this),
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    initialLongToken: longToken,
                    initialShortToken: shortToken,
                    longTokenSwapPath: new address[](0),
                    shortTokenSwapPath: new address[](0)
                }),
                minGlvTokens: minGlvAmount,
                isMarketTokenDeposit: false,
                dataList: new bytes32[](0),
                shouldUnwrapNativeToken: false,
                executionFee: executionFee,
                callbackGasLimit: 600000
            })
        );

        depositedToken.safeApprove(getGmxV2Router(), 0);
        depositedToken.safeApprove(getGmxV2Router(), tokenAmount);
        
        BasicMulticall(getGlvRouter()).multicall{value: msg.value}(data);
        

    }

    ///@dev same reason as above 
    function _simulateSolvencyCheckForDeposit(
        address gmToken,
        address depositedToken,
        uint256 tokenAmount,
        uint256 minGlvAmount,
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses) internal {
            ITokenManager tokenManager = DeploymentConstants.getTokenManager();
            uint256 depositedTokenPrice = (depositedToken == pricesAndAddresses.longToken) ? pricesAndAddresses.longTokenPrice : pricesAndAddresses.shortTokenPrice;
            uint256 gmTokenPrice = pricesAndAddresses.gmTokenPrice; ///@dev reusing the variable name
            uint256 depositedUsdValue = (depositedTokenPrice * tokenAmount) / 
                10 ** IERC20Metadata(depositedToken).decimals();
            
            uint256 minGlvUsdValue = (minGlvAmount * gmTokenPrice) / 
                10 ** IERC20Metadata(gmToken).decimals();

            if (!isWithinBounds(depositedUsdValue, minGlvUsdValue)) 
                revert InvalidMinOutputValue();

            uint256 gmTokensWeightedUsdValue = (gmTokenPrice *
                minGlvAmount *
                tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), gmToken)) /
                (10 ** IERC20Metadata(gmToken).decimals() * 1e8);
            
            if ((_getThresholdWeightedValuePayable() + gmTokensWeightedUsdValue) <= _getDebtPayable()) 
                revert ActionMayCauseInsolvency();

    }
    
    ///@dev a code block inside the _withdrawGlv function was triggering "Stack too deep" error, so moved to a separate function
    function _generateDataAndDoMultiCallForWithdrawal(
        address gmToken,
        uint256 glvAmount,
        address targetMarket,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee) internal {

        bytes[] memory data = new bytes[](3);
        
        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGmxV2GlvWithdrawalVault(),
            executionFee
        );

        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            gmToken,
            getGmxV2GlvWithdrawalVault(),
            glvAmount
        );

        data[2] = abi.encodeWithSelector(
            IGlvWithdrawalUtils.createGlvWithdrawal.selector,
            IGlvWithdrawalUtils.CreateGlvWithdrawalParams({
                addresses: IGlvWithdrawalUtils.CreateGlvWithdrawalParamsAddresses({
                    receiver: address(this),
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    glv: gmToken,
                    market: targetMarket,
                    longTokenSwapPath: new address[](0),
                    shortTokenSwapPath: new address[](0)
                }),
                minLongTokenAmount: minLongTokenAmount,
                minShortTokenAmount: minShortTokenAmount,
                shouldUnwrapNativeToken: false,
                executionFee: executionFee,
                callbackGasLimit: 600000,
                dataList: new bytes32[](0)
            })
        );

        gmToken.safeApprove(getGmxV2Router(), 0);
        gmToken.safeApprove(getGmxV2Router(), glvAmount);
        
        BasicMulticall(getGlvRouter()).multicall{value: msg.value}(data);

    }

    ///@dev same reason as above
    function _simulateSolvencyCheckForWithdraw(
        address gmToken,
        uint256 glvAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses) internal {
            ITokenManager tokenManager = DeploymentConstants.getTokenManager();
            address longToken = pricesAndAddresses.longToken;
            address shortToken = pricesAndAddresses.shortToken;
            uint256 longTokenPrice = pricesAndAddresses.longTokenPrice;
            uint256 shortTokenPrice = pricesAndAddresses.shortTokenPrice;
            uint256 gmTokenPrice = pricesAndAddresses.gmTokenPrice; ///@dev reusing the variable name
            // Price-bounds validation (isWithinBounds) applies to ALL callers, including
            // whitelisted liquidators. A liquidator acting on an already-insolvent account
            // is exempt from the solvency simulation below, but must still provide in-bounds
            // min-out values — an out-of-bounds min-out would allow quietly locking in a
            // worse exit price than the oracle price would imply.
            uint256 glvUsdValue = (gmTokenPrice * glvAmount) /
                10 ** IERC20Metadata(gmToken).decimals();

            uint256 minReceivedUsdValue =
                (longTokenPrice * minLongTokenAmount) / 10 ** IERC20Metadata(longToken).decimals() +
                (shortTokenPrice * minShortTokenAmount) / 10 ** IERC20Metadata(shortToken).decimals();

            if (!isWithinBounds(glvUsdValue, minReceivedUsdValue))
                revert InvalidMinOutputValue();

            if (!ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender)) {
                uint256 receivedTokensWeightedUsdValue =
                    (((longTokenPrice * minLongTokenAmount *
                    tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), longToken)) /
                    10 ** IERC20Metadata(longToken).decimals()) +
                    ((shortTokenPrice * minShortTokenAmount *
                    tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), shortToken)) /
                    10 ** IERC20Metadata(shortToken).decimals())) / 1e8;

                if ((_getThresholdWeightedValuePayable() + receivedTokensWeightedUsdValue) <= _getDebtPayable())
                    revert ActionMayCauseInsolvency();
            }
        }


    // ============ EVENTS ============

    event GlvDepositInitiated(
        address indexed glvToken,
        address indexed targetMarket,
        address indexed depositedToken,
        uint256 tokenAmount,
        uint256 minGlvAmount,
        uint256 executionFee,
        uint256 timestamp
    );

    event GlvFeesSweptDuringOperation(
        address indexed glvToken,
        uint256 feesCollected,
        string operationType,
        uint256 timestamp
    );

    event GlvWithdrawalInitiated(
        address indexed glvToken,
        address indexed targetMarket,
        uint256 glvAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee,
        uint256 timestamp
    );

     event FeesSweptAndGlvBenchmarkUpdated(
        address indexed glvToken,
        uint256 feesCollected,
        address indexed initiator,
        uint256 timestamp
    );
}