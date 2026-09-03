// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 799a1765b64edc5c158198ef84f785af79e234ae;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../ReentrancyGuardKeccak.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import "../lib/GmxV2FeesHelper.sol";
import {GlvHelper} from "../lib/GlvHelper.sol";
import "../interfaces/ITokenManager.sol";
import "../interfaces/IWrappedNativeToken.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";
import {IGlvReader} from "../interfaces/gmx-v2/IGlvReader.sol";

import "../interfaces/gmx-v2/DepositV2.sol";
import "../interfaces/gmx-v2/WithdrawalV2.sol";
import "../interfaces/gmx-v2/IRoleStore.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../interfaces/gmx-v2/IDepositCallbackReceiver.sol";
import "../interfaces/gmx-v2/EventUtils.sol";
import "../interfaces/gmx-v2/IWithdrawalCallbackReceiver.sol";
import "../interfaces/gmx-v2/IGasFeeCallbackReceiver.sol";
import "../interfaces/gmx-v2/IGlvDepositCallbackReceiver.sol";
import "../interfaces/gmx-v2/IGlvWithdrawalCallbackReceiver.sol";

//This path is updated during deployment
import "../lib/DeploymentConstants.sol";

abstract contract GmxV2CallbacksFacet is IDepositCallbackReceiver, IWithdrawalCallbackReceiver, IGasFeeCallbackReceiver, IGlvDepositCallbackReceiver, IGlvWithdrawalCallbackReceiver, ReentrancyGuardKeccak, GmxV2FeesHelper, GlvHelper {
    using TransferHelper for address;
    using Deposit for Deposit.Props;
    using Withdrawal for Withdrawal.Props;

    // CONSTANTS
    bytes32 constant public CONTROLLER = keccak256(abi.encode("CONTROLLER"));

    // Custom Errors
    error AccountNotFoundInDepositData();
    error MarketNotFoundInDepositData();
    error ExecutionFeeNotFoundInDepositData();
    error AccountNotFoundInWithdrawalData();
    error MarketNotFoundInWithdrawalData();
    error ExecutionFeeNotFoundInWithdrawalData();
    error InitialLongTokenAmountNotFound();
    error InitialShortTokenAmountNotFound();
    error BenchmarkDoesNotExist();
    error CachedPricesTooStale();
    error MustBeGmxV2AuthorizedKeeper();
    error OrderCreatorNotAuthorized();
    error GlvNotFoundInDepositData();
    error GlvNotFoundInWithdrawalData();

    // GMX contracts
    function getGmxV2RoleStore() internal pure virtual returns (address);

    // Struct to hold market token addresses (works for both GM and GM Plus)
    struct MarketTokens {
        address longToken;
        address shortToken;
        bool isPlusMarket;
    }

    // Internal method to get token addresses for any GM market (regular or Plus)
    function _getMarketTokens(address gmMarket) internal view returns (MarketTokens memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bool isPlusMarket = tokenManager.isGmxPlusMarket(gmMarket);
        bool isGlvMarket = tokenManager.isGlvTokenWhitelisted(gmMarket);
        
        address gmxReader = DeploymentConstants.getGmxReaderAddress();
        address glvReader = DeploymentConstants.getGlvReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        IGmxReader.MarketProps memory marketProps;
        IGlvReader.Props memory props;
        if (!isGlvMarket) {
            marketProps = IGmxReader(gmxReader).getMarket(dataStore, gmMarket);
        } else {
            props = IGlvReader(glvReader).getGlv(dataStore, gmMarket);
           
        }
        
        if (isPlusMarket) {
            // Plus markets: both long and short are the same token
            address token = marketProps.longToken;
            if (token == address(0)) revert GmxPlusMarketTokenNotFound();
            return MarketTokens({
                longToken: token,
                shortToken: token, // Same token for both
                isPlusMarket: true
            });
        } else if (isGlvMarket) {
            // GLV markets: both long and short are different
            address glv = props.glvToken;
            if (glv == address(0)) revert GlvTokenNotFound();
            address longToken = props.longToken;
            address shortToken = props.shortToken;
            if (longToken == address(0) || shortToken == address(0)) revert GlvTokenNotFound();
            return MarketTokens({
                longToken: longToken,
                shortToken: shortToken, 
                isPlusMarket: false
            });
        } else {
            // Regular GM markets: different long and short tokens
            address longToken = marketProps.longToken;
            address shortToken = marketProps.shortToken;
            if (longToken == address(0) || shortToken == address(0)) revert GmxMarketTokensNotFound();
            return MarketTokens({
                longToken: longToken,
                shortToken: shortToken,
                isPlusMarket: false
            });
        }
    }

    // Helper functions for backward compatibility (now non-abstract)
    function marketToLongToken(address market) internal view returns (address) {
        MarketTokens memory tokens = _getMarketTokens(market);
        return tokens.longToken;
    }

    function marketToShortToken(address market) internal view returns (address) {
        MarketTokens memory tokens = _getMarketTokens(market);
        return tokens.shortToken;
    }

    // Helper function to check if caller is authorized GMX keeper
    function isCallerAuthorized(address caller) internal view returns (bool) {
        IRoleStore roleStore = IRoleStore(getGmxV2RoleStore());
        return roleStore.hasRole(caller, CONTROLLER);
    }

    // Helper function to wrap native tokens
    function wrapNativeToken() internal {
        uint256 balance = address(this).balance;
        if(balance > 0){
            IWrappedNativeToken nativeToken = IWrappedNativeToken(DeploymentConstants.getNativeToken());
            nativeToken.deposit{value : balance}();
            ITokenManager tokenManager = DeploymentConstants.getTokenManager();
            _syncExposure(tokenManager, address(nativeToken));
        }
    }
    
    // Helper function to extract data from EventUtils.EventLogData
    function extractDepositDataFromEvent(EventUtils.EventLogData memory depositData) internal pure returns (
        address account,
        address market,
        uint256 executionFee
    ) {
        // Use EventUtils library functions directly
        bool found;
        
        (found, account) = EventUtils.getWithoutRevert(depositData.addressItems, "account");
        if (!found) revert AccountNotFoundInDepositData();
        
        (found, market) = EventUtils.getWithoutRevert(depositData.addressItems, "market");
        if (!found) revert MarketNotFoundInDepositData();
        
        (found, executionFee) = EventUtils.getWithoutRevert(depositData.uintItems, "executionFee");
        if (!found) revert ExecutionFeeNotFoundInDepositData();
    }

    function extractWithdrawalDataFromEvent(EventUtils.EventLogData memory withdrawalData) internal pure returns (
        address account,
        address market,
        uint256 executionFee
    ) {
        // Use EventUtils library functions directly
        bool found;
        
        (found, account) = EventUtils.getWithoutRevert(withdrawalData.addressItems, "account");
        if (!found) revert AccountNotFoundInWithdrawalData();
        
        (found, market) = EventUtils.getWithoutRevert(withdrawalData.addressItems, "market");
        if (!found) revert MarketNotFoundInWithdrawalData();
        
        (found, executionFee) = EventUtils.getWithoutRevert(withdrawalData.uintItems, "executionFee");
        if (!found) revert ExecutionFeeNotFoundInWithdrawalData();
    }

    function _updatePositionBenchmark(address market) internal {
        // Use cached prices instead of calling getPrices()
        GmxTokenPrices memory cachedPrices = _getPricesFromBenchmarkWithValidation(market);
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        // Get token addresses for this market
        MarketTokens memory tokens = _getMarketTokens(market);
        
        uint256 gmTokenAmount = IERC20(market).balanceOf(address(this));
        uint256 longTokenAmount;
        uint256 shortTokenAmount;
        if (tokenManager.isGlvTokenWhitelisted(market)) {
            (longTokenAmount, shortTokenAmount) = _getGlvLongAndShortTokenAmountsWithCachedPrices(market, gmTokenAmount, cachedPrices);
        } else {
            (longTokenAmount, shortTokenAmount) = _getUnderlyingTokenDetails(market, cachedPrices, tokens.longToken, tokens.shortToken);    
        }
    
        
        GmxPositionDetails memory positionDetails = GmxPositionDetails({
            underlyingLongTokenAmount: longTokenAmount,
            underlyingShortTokenAmount: shortTokenAmount,
            gmTokenPriceUsd: cachedPrices.gmTokenPrice,
            longTokenPriceUsd: cachedPrices.longTokenPrice,
            shortTokenPriceUsd: tokens.isPlusMarket ? 0 : cachedPrices.shortTokenPrice, // Set to 0 for Plus markets
            benchmarkTimeStamp: block.timestamp,
            longTokenAddress: tokens.longToken,
            shortTokenAddress: tokens.shortToken
        });
        
        _createOrUpdatePositionBenchmark(market, positionDetails);
    }

    function _getPricesFromBenchmarkWithValidation(address gmMarket) internal view returns (GmxTokenPrices memory) {    
        DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(gmMarket);
        
        if (!benchmark.exists) revert BenchmarkDoesNotExist();
        if (block.timestamp - benchmark.benchmarkTimeStamp > 5 minutes) revert CachedPricesTooStale();
        
        return GmxTokenPrices({
            gmTokenPrice: benchmark.gmTokenPriceUsd,
            longTokenPrice: benchmark.longTokenPriceUsd,
            shortTokenPrice: benchmark.shortTokenPriceUsd
        });
    }

    // NEW CALLBACK SIGNATURES from v2.2
    function afterDepositExecution(bytes32 key, EventUtils.EventLogData memory depositData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractDepositDataFromEvent(depositData);
        _handleDepositExecution(account, market, executionFee);
        _updatePositionBenchmark(market);
    }

    function afterDepositCancellation(bytes32 key, EventUtils.EventLogData memory depositData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractDepositDataFromEvent(depositData);
        
        bool found;
        uint256 initialLongTokenAmount;
        uint256 initialShortTokenAmount;
        
        (found, initialLongTokenAmount) = EventUtils.getWithoutRevert(depositData.uintItems, "initialLongTokenAmount");
        if (!found) revert InitialLongTokenAmountNotFound();
        
        (found, initialShortTokenAmount) = EventUtils.getWithoutRevert(depositData.uintItems, "initialShortTokenAmount");
        if (!found) revert InitialShortTokenAmountNotFound();
        
        _handleDepositCancellation(account, market, executionFee, initialLongTokenAmount, initialShortTokenAmount);
        _updatePositionBenchmark(market);
    }

    function afterWithdrawalExecution(bytes32 key, EventUtils.EventLogData memory withdrawalData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractWithdrawalDataFromEvent(withdrawalData);
        _handleWithdrawalExecution(account, market, executionFee);
        uint256 gmTokenAmount = IERC20(market).balanceOf(address(this));
        _updatePositionBenchmark(market);
    }

    function afterWithdrawalCancellation(bytes32 key, EventUtils.EventLogData memory withdrawalData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractWithdrawalDataFromEvent(withdrawalData);
        _handleWithdrawalCancellation(account, market, executionFee);
        uint256 gmTokenAmount = IERC20(market).balanceOf(address(this));
        _updatePositionBenchmark(market);
    }

    ///// GLV CALLBACKS ///////////

    function afterGlvDepositExecution(bytes32 key, EventUtils.EventLogData memory glvDepositData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        ///@dev the market isn't exactly a market but the glv token address, but calling it market to be used consistently with other methods
        (address account, address market, uint256 executionFee) = extractGlvDepositDataFromEvent(glvDepositData);
        _handleDepositExecution(account, market, executionFee);
        _updatePositionBenchmark(market);
    }

    function afterGlvDepositCancellation(bytes32 key, EventUtils.EventLogData memory glvDepositData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractGlvDepositDataFromEvent(glvDepositData);
        
        bool found;
        uint256 initialLongTokenAmount;
        uint256 initialShortTokenAmount;
        
        (found, initialLongTokenAmount) = EventUtils.getWithoutRevert(glvDepositData.uintItems, "initialLongTokenAmount");
        if (!found) revert InitialLongTokenAmountNotFound();
        
        (found, initialShortTokenAmount) = EventUtils.getWithoutRevert(glvDepositData.uintItems, "initialShortTokenAmount");
        if (!found) revert InitialShortTokenAmountNotFound();
        
        _handleDepositCancellation(account, market, executionFee, initialLongTokenAmount, initialShortTokenAmount);
        _updatePositionBenchmark(market);
    }

    function afterGlvWithdrawalExecution(bytes32 key, EventUtils.EventLogData memory glvWithdrawalData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractGlvWithdrawalDataFromEvent(glvWithdrawalData);
        _handleWithdrawalExecution(account, market, executionFee);
        _updatePositionBenchmark(market);
    }

    function afterGlvWithdrawalCancellation(bytes32 key, EventUtils.EventLogData memory glvWithdrawalData, EventUtils.EventLogData memory eventData) external onlyGmxV2Keeper nonReentrant {
        (address account, address market, uint256 executionFee) = extractGlvWithdrawalDataFromEvent(glvWithdrawalData);
        _handleWithdrawalCancellation(account, market, executionFee);
        _updatePositionBenchmark(market);
    }


    // Extract GLV deposit data
    function extractGlvDepositDataFromEvent(EventUtils.EventLogData memory glvDepositData) internal pure returns (
        address account,
        address glv,  // Use "glv" not "market"
        uint256 executionFee
    ) {
        bool found;
        
        (found, account) = EventUtils.getWithoutRevert(glvDepositData.addressItems, "account");
        if (!found) revert AccountNotFoundInDepositData();
        
        (found, glv) = EventUtils.getWithoutRevert(glvDepositData.addressItems, "glv");
        if (!found) revert GlvNotFoundInDepositData(); 
        
        (found, executionFee) = EventUtils.getWithoutRevert(glvDepositData.uintItems, "executionFee");
        if (!found) revert ExecutionFeeNotFoundInDepositData();
    }

    // Extract GLV withdrawal data - similar pattern
    function extractGlvWithdrawalDataFromEvent(EventUtils.EventLogData memory glvWithdrawalData) internal pure returns (
        address account,
        address glv,
        uint256 executionFee
    ) {
        bool found;
        
        (found, account) = EventUtils.getWithoutRevert(glvWithdrawalData.addressItems, "account");
        if (!found) revert AccountNotFoundInWithdrawalData();
        
        (found, glv) = EventUtils.getWithoutRevert(glvWithdrawalData.addressItems, "glv");
        if (!found) revert GlvNotFoundInWithdrawalData();  
        
        (found, executionFee) = EventUtils.getWithoutRevert(glvWithdrawalData.uintItems, "executionFee");
        if (!found) revert ExecutionFeeNotFoundInWithdrawalData();
    }


    ///// END OF GLV CALLBACKS ////

    // SHARED INTERNAL LOGIC - Extract common logic to avoid duplication
    function _handleDepositExecution(address account, address market, uint256 executionFee) internal {
        if(account != address(this)){
            revert OrderCreatorNotAuthorized();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        // Native token transfer happens after execution of this method
        wrapNativeToken();

        // Sync exposures for the GM token
        _syncExposure(tokenManager, market);

        // Clear pending exposure for the GM token
        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(market), account);

        DiamondStorageLib.unfreezeAccount(msg.sender);
        emit DepositExecuted(msg.sender, market, IERC20Metadata(market).balanceOf(address(this)), executionFee);
    }

    function _handleDepositCancellation(address account, address market, uint256 executionFee, uint256 initialLongTokenAmount, uint256 initialShortTokenAmount) internal {
        if(account != address(this)){
            revert OrderCreatorNotAuthorized();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        MarketTokens memory tokens = _getMarketTokens(market);

        // Native token transfer happens after execution of this method
        wrapNativeToken();

        if(initialLongTokenAmount > 0) {
            _syncExposure(tokenManager, tokens.longToken);
        }
        if(initialShortTokenAmount > 0) {
            _syncExposure(tokenManager, tokens.shortToken);
        }

        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(market), account);

        DiamondStorageLib.unfreezeAccount(msg.sender);
        emit DepositCancelled(msg.sender, market, executionFee);
    }

    function _handleWithdrawalExecution(address account, address market, uint256 executionFee) internal {
        if(account != address(this)){
            revert OrderCreatorNotAuthorized();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        MarketTokens memory tokens = _getMarketTokens(market);

        // Native token transfer happens after execution
        wrapNativeToken();

        _syncExposure(tokenManager, tokens.longToken);
        _syncExposure(tokenManager, tokens.shortToken);

        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(tokens.longToken), account);
        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(tokens.shortToken), account);

        DiamondStorageLib.unfreezeAccount(msg.sender);
        emit WithdrawalExecuted(
            msg.sender,
            market,
            IERC20Metadata(tokens.longToken).balanceOf(address(this)),
            IERC20Metadata(tokens.shortToken).balanceOf(address(this)),
            executionFee
        );
    }

    function _handleWithdrawalCancellation(address account, address market, uint256 executionFee) internal {
        if(account != address(this)){
            revert OrderCreatorNotAuthorized();
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        MarketTokens memory tokens = _getMarketTokens(market);

        // Native token transfer happens after execution
        wrapNativeToken();

        // A cancelled withdrawal refunds the GM MARKET token: GMX returns
        // withdrawal.market()/marketTokenAmount(), not the long/short legs. _withdraw had
        // already synced the GM to a zero balance, which removed it from ownedAssets, so
        // without this the refunded collateral sits in the account invisible to
        // SolvencyFacetProd and to the liquidation engine.
        //
        // Exposure bookkeeping mirrors initiation: _withdraw syncs ACTUAL exposure for what it
        // spends (the GM) and RESERVES pending for what it expects (long + short), so the
        // cancellation owes a sync on the market and a pending-clear on long/short. The two
        // long/short syncs that used to sit here were no-ops — nothing was refunded on those
        // legs, the account is frozen for the whole async window, and wrapNativeToken() above
        // already syncs the wrapped-native leg itself — so they are dropped. Their PENDING
        // clears below stay; that is what _withdraw actually booked.
        //
        // Note this sync CAN revert: restoring the GM raises exposure, so it reaches
        // TokenManager's `current <= max` check. That is a real cost of correctness here, not
        // something the change avoids — GMX swallows a failing callback, so a cap breach would
        // leave the account frozen with the GM still unregistered, recoverable only by a
        // whitelisted liquidator calling unfreezeAccount(). It is accepted because the GM
        // exposure groups run far below their caps and the alternative is leaving real
        // collateral permanently invisible to solvency. If a GM group is ever configured close
        // to its cap, revisit this: the restore is a rollback of exposure this same account
        // released at initiation, so it arguably should not be cap-gated at all.
        _syncExposure(tokenManager, market);

        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(tokens.longToken), account);
        tokenManager.setPendingExposureToZero(tokenManager.tokenAddressToSymbol(tokens.shortToken), account);

        DiamondStorageLib.unfreezeAccount(msg.sender);
        emit WithdrawalCancelled(msg.sender, market, executionFee);
    }

    function refundExecutionFee(bytes32 /* key */, EventUtils.EventLogData memory /* eventData */) external payable nonReentrant onlyGmxV2Keeper {
        wrapNativeToken();
        emit GasFeeRefunded(msg.value);
    }

    // MODIFIERS
    modifier onlyGmxV2Keeper() {
        if (!isCallerAuthorized(msg.sender)) revert MustBeGmxV2AuthorizedKeeper();
        _;
    }

    // EVENTS
    event DepositExecuted(address indexed accountAddress, address indexed market, uint256 gmAmount, uint256 executionFee);
    event DepositCancelled(address indexed accountAddress, address indexed market, uint256 executionFee);
    event WithdrawalExecuted(address indexed accountAddress, address indexed market, uint256 longTokenAmount, uint256 shortTokenAmount, uint256 executionFee);
    event WithdrawalCancelled(address indexed accountAddress, address indexed market, uint256 executionFee);
    event GasFeeRefunded(uint256 refundedFee);
}