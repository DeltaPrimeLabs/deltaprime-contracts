// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 56b7ba6f74e4dd5f903aad49110b5db8a353f45f;
pragma solidity 0.8.17;

import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../Pool.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

//This path is updated during deployment
import "../lib/DeploymentConstants.sol";
import "../lib/GmxV2FeesHelper.sol";
import {IGmxReader} from "../interfaces/gmx-v2/IGmxReader.sol";
import "../PrimeAccountModifiers.sol";

contract SmartLoanViewFacet is GmxV2FeesHelper, PrimeAccountModifiers {
    using TransferHelper for address payable;
    using TransferHelper for address;

    struct AssetNameBalance {
        bytes32 name;
        uint256 balance;
    }

    struct AssetNameBalanceDebtCoverage {
        bytes32 name;
        uint256 balance;
        uint256 debtCoverage;
    }

    struct AssetNameDebt {
        bytes32 name;
        uint256 debt;
    }

    struct AssetNamePrice {
        bytes32 name;
        uint256 price;
    }

    /////////////////////
    // ERRORS
    /////////////////////
    error NotGMXMarket();
    error SymbolNotFoundInArray();

    /* ========== PUBLIC AND EXTERNAL MUTATIVE FUNCTIONS ========== */

    function initialize(address owner) external {
        require(owner != address(0), "Initialize: Cannot set the owner to a zero address");
        require(address(this) != DeploymentConstants.getDiamondAddress(), "DiamondInit: Cannot initialize DiamondBeacon");

        DiamondStorageLib.SmartLoanStorage storage sls = DiamondStorageLib.smartLoanStorage();
        require(!sls._initialized, "DiamondInit: contract is already initialized");
        DiamondStorageLib.setContractOwner(owner);
        DiamondStorageLib.setPrimeLeverageTier(LeverageTierLib.LeverageTier.BASIC);
        sls._initialized = true;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getPercentagePrecision() public view virtual returns (uint256) {
        return DeploymentConstants.getPercentagePrecision();
    }

    function getAccountFrozenSince() public view returns (uint256){
        DiamondStorageLib.SmartLoanStorage storage sls = DiamondStorageLib.smartLoanStorage();
        return sls.frozenSince;
    }

    /**
    * Returns the saved GMX position benchmark for a given market
    * @param market The GMX market address to get benchmark data for
    * @return benchmark The benchmark data including value, token amounts, timestamps, and addresses
    */
    function getGmxPositionBenchmark(address market) external view returns (DiamondStorageLib.GmxPositionBenchmark memory benchmark) {
        return DiamondStorageLib.getGmxPositionBenchmark(market);
    }


    /**
    * Returns a current balance of the asset held by the smart loan
    * @param _asset the code of an asset
    **/
    function getBalance(bytes32 _asset) public view returns (uint256) {
        IERC20 token = IERC20(DeploymentConstants.getTokenManager().getAssetAddress(_asset, true));
        return token.balanceOf(address(this));
    }

    function getAllOwnedAssets() external view returns (bytes32[] memory result) {
        return DeploymentConstants.getAllOwnedAssets();
    }

    function getSupportedTokensAddresses() external view returns (address[] memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        return tokenManager.getSupportedTokensAddresses();
    }

    function getAllAssetsBalancesDebtCoverages() public view returns (AssetNameBalanceDebtCoverage[] memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory assets = tokenManager.getAllTokenAssets();
        AssetNameBalanceDebtCoverage[] memory result = new AssetNameBalanceDebtCoverage[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            address assetAddress = tokenManager.getAssetAddress(assets[i], true);
            result[i] = AssetNameBalanceDebtCoverage({
                name : assets[i],
                balance : IERC20(assetAddress).balanceOf(address(this)),
                debtCoverage : tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(), assetAddress)
            });
        }

        return result;
    }

    
    function getAllAssetsBalances() public view returns (AssetNameBalance[] memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory assets = tokenManager.getAllTokenAssets();
        AssetNameBalance[] memory result = new AssetNameBalance[](assets.length);
        
        // Collect all unique symbols needed for GM tokens
        bytes32[] memory uniqueGMTokensSymbols = _collectGmTokenSymbols(assets, tokenManager);
        uint256[] memory allPrices = uniqueGMTokensSymbols.length > 0 ? getPrices(uniqueGMTokensSymbols) : new uint256[](0);
        
        // Populate results
        for (uint256 i = 0; i < assets.length; i++) {
            result[i] = _getAssetBalance(assets[i], uniqueGMTokensSymbols, allPrices, tokenManager);
        }
        
        return result;
    }

    function _collectGmTokenSymbols(
        bytes32[] memory assets,
        ITokenManager tokenManager
    ) internal view returns (bytes32[] memory uniqueGMTokensSymbols) {
        // Temporary storage for collecting unique symbols. 
        // Worst case is all assets are GMX markets with 3 unique symbols each.
        bytes32[] memory allSymbols = new bytes32[](assets.length * 3);
        uint256 symbolCount = 0;
        
        for (uint256 i = 0; i < assets.length; i++) {
            address assetAddress = tokenManager.getAssetAddress(assets[i], true);
            if (tokenManager.isGmxMarketWhitelisted(assetAddress)) {
                symbolCount = _addGmTokenSymbols(assetAddress, allSymbols, symbolCount, tokenManager);
            }
        }
        
        // Create final array with exact size
        uniqueGMTokensSymbols = new bytes32[](symbolCount);
        for (uint256 i = 0; i < symbolCount; i++) {
            uniqueGMTokensSymbols[i] = allSymbols[i];
        }
    }

    function _addGmTokenSymbols(
        address gmToken,
        bytes32[] memory allSymbols,
        uint256 currentCount,
        ITokenManager tokenManager
    ) internal view returns (uint256 newCount) {
        // Get market properties
        (address longToken, address shortToken) = _getMarketTokens(gmToken);
        
        // Get symbols
        bytes32 gmSymbol = tokenManager.tokenAddressToSymbol(gmToken);
        bytes32 longSymbol = tokenManager.tokenAddressToSymbol(longToken);
        
        newCount = currentCount;
        
        // Add GM token symbol if not present
        if (!_symbolExists(allSymbols, newCount, gmSymbol)) {
            allSymbols[newCount] = gmSymbol;
            newCount++;
        }
        
        // Add long token symbol if not present
        if (!_symbolExists(allSymbols, newCount, longSymbol)) {
            allSymbols[newCount] = longSymbol;
            newCount++;
        }
        
        // Add short token symbol if it's different (not GmxPlus market)
        if (!tokenManager.isGmxPlusMarket(gmToken)) {
            bytes32 shortSymbol = tokenManager.tokenAddressToSymbol(shortToken);
            if (!_symbolExists(allSymbols, newCount, shortSymbol)) {
                allSymbols[newCount] = shortSymbol;
                newCount++;
            }
        }
    }

    // Just getting the underlying token addresses.
    function _getMarketTokens(address gmToken) internal view returns (address longToken, address shortToken) {
        address gmxReader = DeploymentConstants.getGmxReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        IGmxReader.MarketProps memory marketProps = IGmxReader(gmxReader).getMarket(dataStore, gmToken);
        longToken = marketProps.longToken;
        shortToken = marketProps.shortToken;
        if (longToken == address(0)) revert NotGMXMarket();
    }

    // Getting balance for a single asset, handling GMX markets with fee deductions. 
    // Prices are passed in to avoid multiple redundant fetches.
    function _getAssetBalance(
        bytes32 assetName,
        bytes32[] memory uniqueGMTokensSymbols,
        uint256[] memory allPrices,
        ITokenManager tokenManager
    ) internal view returns (AssetNameBalance memory) {
        address assetAddress = tokenManager.getAssetAddress(assetName, true);
        
        if (tokenManager.isGmxMarketWhitelisted(assetAddress)) {
            return AssetNameBalance({
                name: assetName,
                balance: _getGmTokenBalanceAfterFeesWithPrices(assetAddress, uniqueGMTokensSymbols, allPrices)
            });
        } else {
            return AssetNameBalance({
                name: assetName,
                balance: IERC20(assetAddress).balanceOf(address(this))
            });
        }
    }

    // helper function to check if a symbol already exists in the array
    function _symbolExists(bytes32[] memory symbols, uint256 length, bytes32 symbol) private pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (symbols[i] == symbol) {
                return true;
            }
        }
        return false;
    }

    // helper function to find the index of a symbol in the array
    function _findPriceIndex(bytes32[] memory symbols, bytes32 targetSymbol) private pure returns (uint256) {
        for (uint256 i = 0; i < symbols.length; i++) {
            if (symbols[i] == targetSymbol) {
                return i;
            }
        }
        revert SymbolNotFoundInArray();
    }

    function _getGmTokenBalanceAfterFeesWithPrices(
        address gmToken,
        bytes32[] memory allSymbols,
        uint256[] memory allPrices
    ) internal view returns (uint256) {
        // Get market tokens
        (address longToken, address shortToken) = _getMarketTokens(gmToken);
        
        // Get token manager
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        // Get prices for this GM token
        (uint256 gmPrice, uint256 longPrice, uint256 shortPrice) = _getGmTokenPrices(
            gmToken, longToken, shortToken, allSymbols, allPrices, tokenManager
        );
        
        // Calculate fees and balance
        uint256 feeInGmTokens = _getDeductibleFeesInGmTokens(gmToken, gmPrice, longPrice, shortPrice);
        uint256 balance = IERC20(gmToken).balanceOf(address(this));
        
        return feeInGmTokens >= balance ? 0 : balance - feeInGmTokens;
    }

    function _getGmTokenPrices(
        address gmToken,
        address longToken,
        address shortToken,
        bytes32[] memory allSymbols,
        uint256[] memory allPrices,
        ITokenManager tokenManager
    ) internal view returns (uint256 gmPrice, uint256 longPrice, uint256 shortPrice) {
        // Get symbols
        bytes32 gmSymbol = tokenManager.tokenAddressToSymbol(gmToken);
        bytes32 longSymbol = tokenManager.tokenAddressToSymbol(longToken);
        
        // Find prices from pre-fetched array
        gmPrice = allPrices[_findPriceIndex(allSymbols, gmSymbol)];
        longPrice = allPrices[_findPriceIndex(allSymbols, longSymbol)];
        
        if (tokenManager.isGmxPlusMarket(gmToken)) {
            shortPrice = 0; // Avoid double counting for GmxPlus markets
        } else {
            bytes32 shortSymbol = tokenManager.tokenAddressToSymbol(shortToken);
            shortPrice = allPrices[_findPriceIndex(allSymbols, shortSymbol)];
        }
    }
    
    // Redefining and keeping this function for backward compatibility
    function getGmTokenBalanceAfterFees(address gmToken) external view returns (uint256) {
        // Get market tokens
        (address longToken, address shortToken) = _getMarketTokens(gmToken);
        
        // Get token manager
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256[] memory prices;
        uint256 feeInGmTokens;
        if(!tokenManager.isGmxPlusMarket(gmToken)) {
            bytes32[] memory symbols = new bytes32[](3);
            symbols[0] = tokenManager.tokenAddressToSymbol(gmToken);
            symbols[1] = tokenManager.tokenAddressToSymbol(longToken);
            symbols[2] = tokenManager.tokenAddressToSymbol(shortToken);
            prices = getPrices(symbols);
            feeInGmTokens = _getDeductibleFeesInGmTokens(gmToken, prices[0], prices[1], prices[2]);
        } else {
            bytes32[] memory symbols = new bytes32[](2);
            symbols[0] = tokenManager.tokenAddressToSymbol(gmToken);
            symbols[1] = tokenManager.tokenAddressToSymbol(longToken);
            prices = getPrices(symbols);
            feeInGmTokens = _getDeductibleFeesInGmTokens(gmToken, prices[0], prices[1], 0);
        }
        // Calculate fees and balance
        uint256 balance = IERC20(gmToken).balanceOf(address(this));
        
        return feeInGmTokens >= balance ? 0 : balance - feeInGmTokens;
    }

    function getDebts() public view returns (AssetNameDebt[] memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory assets = tokenManager.getAllPoolAssets();
        AssetNameDebt[] memory result = new AssetNameDebt[](assets.length);

        for (uint256 i = 0; i < assets.length; i++) {
            Pool pool = Pool(tokenManager.getPoolAddress(assets[i]));

            result[i] = AssetNameDebt({
            name : assets[i],
            debt : pool.getBorrowed(address(this))
            });
        }

        return result;
    }

    /**
     * Returns the prices of all assets supported by the TokenManager
     * It could be used as a helper method for UI
     * @dev This function uses the redstone-evm-connector
     **/
    function getAllAssetsPrices() public returns (AssetNamePrice[] memory) {
        bytes32[] memory assets = DeploymentConstants.getTokenManager().getAllTokenAssets();
        uint256[] memory prices = DiamondMethodsAccess.getPrices(assets);
        AssetNamePrice[] memory result = new AssetNamePrice[](assets.length);
        for (uint i = 0; i < assets.length; i++) {
            result[i] = AssetNamePrice({
                name : assets[i],
                price : prices[i]
            });
        }
        return result;
    }

    function getContractOwner() external view returns (address _owner) {
        _owner = DiamondStorageLib.contractOwner();
    }

    function getProposedOwner() external view returns (address _proposed) {
        _proposed = DiamondStorageLib.proposedOwner();
    }

    function getStakedPositions() external view returns (IStakingPositions.StakedPosition[] memory  _positions) {
        _positions = DiamondStorageLib.stakedPositions();
    }
}