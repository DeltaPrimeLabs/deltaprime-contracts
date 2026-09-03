// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: ;
pragma solidity 0.8.17;


import "../ReentrancyGuardKeccak.sol";
import "../PrimeAccountModifiers.sol";
import "../lib/GmxV2FeesHelper.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";

abstract contract GmxV2PlusFacet is ReentrancyGuardKeccak, PrimeAccountModifiers, GmxV2FeesHelper {
    using TransferHelper for address;

    // GMX contracts
    function getGmxV2Router() internal pure virtual returns (address);

    function getGmxV2ExchangeRouter() internal pure virtual returns (address);

    function getGmxV2DepositVault() internal pure virtual returns (address);

    function getGmxV2WithdrawalVault() internal pure virtual returns (address);

    function _deposit(
        address gmToken,
        uint256 tokenAmount,
        uint256 minGmAmount,
        uint256 executionFee
    ) internal nonReentrant noBorrowInTheSameBlock onlyOwner notInLiquidation {
        if (executionFee != msg.value) revert InvalidExecutionFee();
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        if (!tokenManager.isGmxMarketWhitelisted(gmToken)) revert MarketNotWhitelisted();

        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGmxTokenPricesAndAddresses(gmToken);
        address depositedToken = pricesAndAddresses.longToken; // For Plus markets, longToken = shortToken
        
        tokenAmount = IERC20(depositedToken).balanceOf(address(this)) < tokenAmount
            ? IERC20(depositedToken).balanceOf(address(this))
            : tokenAmount;

        if (_getAvailableBalancePayable(tokenManager.tokenAddressToSymbol(depositedToken)) < tokenAmount) revert InsufficientBalance();
        
        GmxTokenPrices memory gmxTokenPrice = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });
        
        {
            DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmToken);
            if(benchmark.exists) {
                uint256 collectedFees = _sweepFees(gmToken, gmxTokenPrice);
                if (collectedFees > 0) {
                    emit FeesSweptDuringOperation(gmToken, collectedFees, "deposit_plus", block.timestamp);
                }
            } 
        }

        bytes[] memory data = new bytes[](4);
        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGmxV2DepositVault(),
            executionFee
        );
        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            depositedToken,
            getGmxV2DepositVault(),
            tokenAmount / 2
        );
        data[2] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            depositedToken,
            getGmxV2DepositVault(),
            tokenAmount / 2
        );
        data[3] = abi.encodeWithSelector(
            IDepositUtils.createDeposit.selector,
            IDepositUtils.CreateDepositParams({
                addresses: IDepositUtils.CreateDepositParamsAddresses({
                    receiver: address(this),
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    market: gmToken,
                    initialLongToken: depositedToken,
                    initialShortToken: depositedToken,
                    longTokenSwapPath: new address[](0),
                    shortTokenSwapPath: new address[](0)
                }),
                minMarketTokens: minGmAmount,
                shouldUnwrapNativeToken: false,
                executionFee: executionFee,
                callbackGasLimit: 600000,
                dataList: new bytes32[](0)
            })
        );

        depositedToken.safeApprove(getGmxV2Router(), 0);
        depositedToken.safeApprove(getGmxV2Router(), tokenAmount);
        BasicMulticall(getGmxV2ExchangeRouter()).multicall{value: msg.value}(data);

        // Simulate solvency check using already fetched prices
        {
            if (!isWithinBounds(
                (pricesAndAddresses.longTokenPrice * tokenAmount) /
                    10 ** IERC20Metadata(depositedToken).decimals(), // Deposit Amount In USD
                (minGmAmount * pricesAndAddresses.gmTokenPrice) /
                    10 ** IERC20Metadata(gmToken).decimals()
            )) revert InvalidMinOutputValue();

            uint256 gmTokensWeightedUsdValue = (pricesAndAddresses.gmTokenPrice *
                minGmAmount *
                tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), gmToken)) /
                (10 ** IERC20Metadata(gmToken).decimals() * 1e8);
            if ((_getThresholdWeightedValuePayable() + gmTokensWeightedUsdValue) <= _getDebtPayable())
                revert ActionMayCauseInsolvency();
        }

        // Freeze account
        DiamondStorageLib.freezeAccount(gmToken);

        // update position benchmark, pass already fetched prices and addresses to save gas
        _updatePositionBenchmark(gmToken, pricesAndAddresses);

        tokenManager.increasePendingExposure(
            tokenManager.tokenAddressToSymbol(gmToken),
            address(this),
            (minGmAmount * 1e18) / 10 ** IERC20Metadata(gmToken).decimals()
        );

        // Update exposures
        _syncExposure(tokenManager, depositedToken);

        emit DepositPlusInitiated(gmToken, depositedToken, tokenAmount, minGmAmount, executionFee, block.timestamp);
    }

    function _withdraw(
        address gmToken,
        uint256 gmAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee
    )
        internal
        nonReentrant
        noBorrowInTheSameBlock
        onlyOwnerOrLiquidationWithNoSolvencyCheck
    {
        if (executionFee != msg.value) revert InvalidExecutionFee();
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        if (!tokenManager.isGmxMarketWhitelisted(gmToken)) revert MarketNotWhitelisted();

        gmAmount = IERC20(gmToken).balanceOf(address(this)) < gmAmount
            ? IERC20(gmToken).balanceOf(address(this))
            : gmAmount;

        if (_getAvailableBalancePayable(tokenManager.tokenAddressToSymbol(gmToken)) < gmAmount) revert InsufficientBalance();
        
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGmxTokenPricesAndAddresses(gmToken);
        GmxTokenPrices memory gmxTokenPrice = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });
        
        {
            DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmToken);
            if(benchmark.exists) {
                uint256 collectedFees = _sweepFees(gmToken, gmxTokenPrice);
                if (collectedFees > 0) {
                    if (gmAmount <= collectedFees) {
                        revert InsufficientBalanceAfterFees();
                    }
                    gmAmount -= collectedFees;
                    emit FeesSweptDuringOperation(gmToken, collectedFees, "withdraw_plus", block.timestamp);
                }
            } 
        }

        bytes[] memory data = new bytes[](3);
        data[0] = abi.encodeWithSelector(
            IGmxV2Router.sendWnt.selector,
            getGmxV2WithdrawalVault(),
            executionFee
        );

        data[1] = abi.encodeWithSelector(
            IGmxV2Router.sendTokens.selector,
            gmToken,
            getGmxV2WithdrawalVault(),
            gmAmount
        );

        data[2] = abi.encodeWithSelector(
            IWithdrawalUtils.createWithdrawal.selector,
            IWithdrawalUtils.CreateWithdrawalParams({
                addresses: IWithdrawalUtils.CreateWithdrawalParamsAddresses({
                    receiver: address(this),
                    callbackContract: address(this),
                    uiFeeReceiver: address(0),
                    market: gmToken,
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

        IERC20(gmToken).approve(getGmxV2Router(), gmAmount);
        BasicMulticall(getGmxV2ExchangeRouter()).multicall{value: msg.value}(data);

        // Both longToken and shortToken are the same in Plus markets
        address longToken = pricesAndAddresses.longToken;
        address shortToken = pricesAndAddresses.shortToken;

        // Price-bounds validation (isWithinBounds) applies to ALL callers, including
        // whitelisted liquidators. A liquidator acting on an already-insolvent account
        // is exempt from the solvency simulation below, but must still provide in-bounds
        // min-out values - an out-of-bounds min-out would allow quietly locking in a
        // worse exit price than the oracle price would imply.
        if (!isWithinBounds(
            (pricesAndAddresses.gmTokenPrice * gmAmount) /
                10 ** IERC20Metadata(gmToken).decimals(), // Deposit Amount In USD
            (pricesAndAddresses.longTokenPrice * minLongTokenAmount) /
                10 ** IERC20Metadata(longToken).decimals() +
                (pricesAndAddresses.longTokenPrice * minShortTokenAmount) /    ///@dev shortToken == longToken
                10 ** IERC20Metadata(shortToken).decimals()
        )) revert InvalidMinOutputValue();

        // Solvency simulation remains gated to non-liquidator callers (i.e. the owner):
        // a whitelisted liquidator must be able to withdraw from an already-insolvent
        // account to unwind positions, otherwise the very recovery path would revert.
        if (msg.sender == DiamondStorageLib.contractOwner()) {
            uint256 receivedTokensWeightedUsdValue = (((pricesAndAddresses.longTokenPrice *
                minLongTokenAmount *
                tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), longToken)) /
                10 ** IERC20Metadata(longToken).decimals()) +
                ((pricesAndAddresses.longTokenPrice *
                    minShortTokenAmount *
                    tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), shortToken)) /
                    10 ** IERC20Metadata(shortToken).decimals())) / 1e8;
            if ((_getThresholdWeightedValuePayable() + receivedTokensWeightedUsdValue) <= _getDebtPayable())
                revert ActionMayCauseInsolvency();
        }

        // Freeze account
        DiamondStorageLib.freezeAccount(gmToken);

        // update position benchmark, pass in already fetched prices and addresses to save gas
        _updatePositionBenchmark(gmToken, pricesAndAddresses);

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

        // Update exposures
        _syncExposure(tokenManager, gmToken);

        emit WithdrawalPlusInitiated(
            gmToken,
            gmAmount,
            minLongTokenAmount,
            minShortTokenAmount,
            executionFee,
            block.timestamp
        );
    }

    ///@dev to be called by the bots, sweeps fees and updates the benchmark
    function sweepFeesAndUpdateBenchMarkGmxPlus(address gmToken) external nonReentrant onlyWhitelistedLiquidators remainsSolvent returns (uint256 gmTokensInFees) {
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGmxTokenPricesAndAddresses(gmToken);
        GmxTokenPrices memory gmxTokenPrices = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });

        gmTokensInFees = _sweepFees(gmToken, gmxTokenPrices);
        uint256 gmTokenAmount = IERC20(gmToken).balanceOf(address(this));
        _updatePositionBenchmark(gmToken, pricesAndAddresses);
        
        emit FeesSweptAndBenchmarkUpdated(gmToken, gmTokensInFees, msg.sender, true, block.timestamp);
    }

    function _updatePositionBenchmark(address market, UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses) internal {
        GmxTokenPrices memory gmxTokenPrices = GmxTokenPrices({
            gmTokenPrice: pricesAndAddresses.gmTokenPrice,
            longTokenPrice: pricesAndAddresses.longTokenPrice,
            shortTokenPrice: pricesAndAddresses.shortTokenPrice
        });
        
        // Both longToken and shortToken are the same in Plus markets
        (uint256 longTokenAmount, uint256 shortTokenAmount) = _getUnderlyingTokenDetails(market, gmxTokenPrices, pricesAndAddresses.longToken, pricesAndAddresses.shortToken);
        
        GmxPositionDetails memory positionDetails = GmxPositionDetails({
            underlyingLongTokenAmount: longTokenAmount,
            underlyingShortTokenAmount: shortTokenAmount,
            gmTokenPriceUsd: pricesAndAddresses.gmTokenPrice,
            longTokenPriceUsd: pricesAndAddresses.longTokenPrice,
            shortTokenPriceUsd: 0, ///@dev setting short token price to zero as there is no short token in GMX V2 Plus markets
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: pricesAndAddresses.longToken,
            shortTokenAddress: pricesAndAddresses.shortToken
        });
        _createOrUpdatePositionBenchmark(market, positionDetails);
    }


    function getGmPlusPerformance(address gmToken) external view returns (uint256) {
        GmxTokenPrices memory gmTokenPrices = _getGmxTokenPrices(gmToken);
        return _getGmAnnualisedPerformance(gmToken, gmTokenPrices.gmTokenPrice, gmTokenPrices.longTokenPrice, gmTokenPrices.shortTokenPrice);
    }

    event DepositPlusInitiated(
        address indexed gmToken,
        address indexed depositedToken,
        uint256 tokenAmount,
        uint256 minGmAmount,
        uint256 executionFee,
        uint256 timestamp
    );

    event WithdrawalPlusInitiated(
        address indexed gmToken,
        uint256 gmAmount,
        uint256 minLongTokenAmount,
        uint256 minShortTokenAmount,
        uint256 executionFee,
        uint256 timestamp
    );

    event FeesSweptDuringOperation(
        address indexed gmToken,
        uint256 feesCollected,
        string operationType,
        uint256 timestamp
    );

    event FeesSweptAndBenchmarkUpdated(
        address indexed gmToken,
        uint256 feesCollected,
        address indexed initiator,
        bool isPlusMarket,
        uint256 timestamp
    );
}