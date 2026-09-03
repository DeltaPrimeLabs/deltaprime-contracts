// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: ecd675d46c3f696de7562f6be071a442d97f37d9;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/ITokenManager.sol";
import "../Pool.sol";
import "../DiamondHelper.sol";
import "../interfaces/IStakingPositions.sol";
import "../interfaces/facets/avalanche/ITraderJoeV2Facet.sol";
import {PriceHelper} from "../lib/joe-v2/PriceHelper.sol";
import {Uint256x256Math} from "../lib/joe-v2/math/Uint256x256Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {GmxBenchmarkMath} from "../lib/GmxBenchmarkMath.sol";

//This path is updated during deployment
import "../lib/DeploymentConstants.sol";

abstract contract SolvencyFacetProd is PrimaryProdDataServiceConsumerBase, DiamondHelper {
    using PriceHelper for uint256;
    using Uint256x256Math for uint256;

    struct AssetPrice {
        bytes32 asset;
        uint256 price;
    }

    // Struct used in the liquidation process to obtain necessary prices only once
    struct CachedPrices {
        AssetPrice[] ownedAssetsPrices;
        AssetPrice[] debtAssetsPrices;
        AssetPrice[] stakedPositionsPrices;
        AssetPrice[] assetsToRepayPrices;
        // Prices of TraderJoe V2 bin tokens (tokenX / tokenY) that may not be in ownedAssets.
        AssetPrice[] tjv2TokenPrices;
    }

    struct PriceInfo {
        address tokenX;
        address tokenY;
        uint256 priceX;
        uint256 priceY;
    }

    ////////////////////////////////////////////////////////////////////////
    /////////// Chainlink Integration Methods //////////////////////////////
    ////////////////////////////////////////////////////////////////////////

    ///@dev updated to 25 hours
    uint256 private constant CHAINLINK_MAX_DELAY = 6 hours;


    // Struct to track pricing request info
    struct PriceRequest {
        bool useDirect;              // True if using Redstone directly 
        bytes32 directSymbol;        // If useDirect is true, the token symbol to request.
        address chainlinkFeed;       // If useDirect is false, the chainlink feed address for ChainLink.
    }

    /**
    * @notice Retrieves prices for an array of token symbols using Redstone or Chainlink oracles
    * @dev Determines oracle source per token, batches Redstone calls, fetches Chainlink individually
    * @param symbols Array of asset symbols to get prices for
    * @return finalPrices Array of prices corresponding to input symbols, normalized to 8 decimals
    */
    function getPricesFromRedstoneAndChainlink(bytes32[] memory symbols) public view returns (uint256[] memory finalPrices) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256 n = symbols.length;
        PriceRequest[] memory requests = new PriceRequest[](n);
        uint256 totalSymbolsCount = 0; // Upper bound for total symbols needed
        
        // Pass 1: Build a request for each token.
        for (uint256 i = 0; i < n; i++) {
            address tokenAddr = tokenManager.getAssetAddress(symbols[i], true);
            
            // Check if Chainlink feed exists for this token
            address feedAddress = tokenManager.getChainlinkFeed(tokenAddr);
            bool isConfigured = feedAddress != address(0);
            if (isConfigured) {
                try tokenManager.getPoolAddress(symbols[i]) {
                    revert BorrowableAssetRedstoneRequired(symbols[i]);
                } catch {} 

                    // Chainlink is configured and asset is not borrowable, use Chainlink
                    requests[i] = PriceRequest({
                        useDirect: false,
                        directSymbol: 0,
                        chainlinkFeed: feedAddress
                    });
                
            } else {
                // Not configured: use the input symbol directly via Redstone
                bytes32 requestSymbol = symbols[i];
                requests[i] = PriceRequest({
                    useDirect: true,
                    directSymbol: requestSymbol,
                    chainlinkFeed: address(0)
                });
                totalSymbolsCount+=1;
            }
        }
        
        // Pass 2: Build a global unique list of Redstone symbols.
        bytes32[] memory globalSymbolsTemp = new bytes32[](totalSymbolsCount);
        uint256 globalCount = 0;
        for (uint256 i = 0; i < n; i++) {
            if (requests[i].useDirect) {
                bytes32 sym = requests[i].directSymbol;
                // Check for duplicates
                if (!contains(globalSymbolsTemp, globalCount, sym)) {
                    globalSymbolsTemp[globalCount] = sym;
                    globalCount++;
                }
            }
        }
        
        bytes32[] memory globalUniqueSymbols = new bytes32[](globalCount);
        for (uint256 i = 0; i < globalCount; i++) {
            globalUniqueSymbols[i] = globalSymbolsTemp[i];
        
        }
        
        // --- Pass 3: Retrieve prices for all unique symbols in one call using Redstone ---
        uint256[] memory globalPrices = getOracleNumericValuesWithDuplicatesFromTxMsg(globalUniqueSymbols); 
        
        // Pass 4: Assemble final prices per input token.
        finalPrices = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            if (requests[i].useDirect) {
                uint256 index = findIndex(globalUniqueSymbols, requests[i].directSymbol);
                // Redstone prices are already in 8 decimals
                finalPrices[i] = globalPrices[index];
            } else {
                // getChainlinkPrice returns price normalized to 8 decimals
                finalPrices[i] = getChainlinkPrice(requests[i].chainlinkFeed);
            }
        }
        return finalPrices;
    }

    /**
    * @notice Fetches price from Chainlink feed and normalizes to 8 decimals
    * @param feedAddress Address of the Chainlink price feed
    * @return price Price normalized to 8 decimals
    */
    function getChainlinkPrice(address feedAddress) internal view returns (uint256 price) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feedAddress);
        
        (
            uint80 roundId,
            int256 answer,
            /* uint256 startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();
        
        // Validate Chainlink response
        if (answer <= 0) revert ChainlinkWrongPrice();
        if (answeredInRound < roundId) revert ChainlinkStaleRound();
        if (updatedAt == 0) revert ChainlinkIncompleteRound();
        ///@dev can get rid of this check if this is an overkill. Different feeds have highly varied heartbeats
        if (block.timestamp - updatedAt > CHAINLINK_MAX_DELAY) revert ChainlinkStaleData();
        
        // Get feed decimals and normalize to 8 decimals
        uint8 feedDecimals = priceFeed.decimals();

        if (feedDecimals > 36) revert ChainlinkWrongDecimals(); ///@dev should never happen
        
        if (feedDecimals < 8) {
            // Scale up to 8 decimals
            price = uint256(answer) * (10 ** (8 - feedDecimals));
        } else if (feedDecimals > 8) {
            // Scale down to 8 decimals
            price = uint256(answer) / (10 ** (feedDecimals - 8));
        } else {
            // Already 8 decimals
            price = uint256(answer);
        }
        
        return price;
    }

    /**
    * @notice Helper function to check if a symbol exists in an array
    * @param array Array to search in
    * @param length Current length of valid elements
    * @param symbol Symbol to search for
    * @return bool True if symbol exists
    */
    function contains(bytes32[] memory array, uint256 length, bytes32 symbol) internal pure returns (bool) {
        for (uint256 i = 0; i < length; i++) {
            if (array[i] == symbol) {
                return true;
            }
        }
        return false;
    }

    /**
    * @notice Helper function to find index of a symbol in an array
    * @param array Array to search in
    * @param symbol Symbol to find
    * @return uint256 Index of the symbol
    */
    function findIndex(bytes32[] memory array, bytes32 symbol) internal pure returns (uint256) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == symbol) {
                return i;
            }
        }
        revert SymbolNotFound(symbol);
    }

    /**
    * @notice Helper function to find a price from the CachedPrices struct
    * @param cachedPrices The struct containing all pre-fetched price arrays
    * @param symbol The asset symbol to find
    * @return price The price of the symbol
    */
    function findPriceInCachedPrices(CachedPrices memory cachedPrices, bytes32 symbol) internal pure returns (uint256 price) {
        // Search owned assets (most likely)
        for (uint256 i = 0; i < cachedPrices.ownedAssetsPrices.length; i++) {
            if (cachedPrices.ownedAssetsPrices[i].asset == symbol) {
                return cachedPrices.ownedAssetsPrices[i].price;
            }
        }
        // Search debt assets
        for (uint256 i = 0; i < cachedPrices.debtAssetsPrices.length; i++) {
            if (cachedPrices.debtAssetsPrices[i].asset == symbol) {
                return cachedPrices.debtAssetsPrices[i].price;
            }
        }
        // Search staked assets
        for (uint256 i = 0; i < cachedPrices.stakedPositionsPrices.length; i++) {
            if (cachedPrices.stakedPositionsPrices[i].asset == symbol) {
                return cachedPrices.stakedPositionsPrices[i].price;
            }
        }
        // Search repay assets (in case it was passed in during liquidation)
        for (uint256 i = 0; i < cachedPrices.assetsToRepayPrices.length; i++) {
            if (cachedPrices.assetsToRepayPrices[i].asset == symbol) {
                return cachedPrices.assetsToRepayPrices[i].price;
            }
        }
        // Search TJv2 bin-token prices (tokenX / tokenY that are not in ownedAssets)
        for (uint256 i = 0; i < cachedPrices.tjv2TokenPrices.length; i++) {
            if (cachedPrices.tjv2TokenPrices[i].asset == symbol) {
                return cachedPrices.tjv2TokenPrices[i].price;
            }
        }
        revert SymbolNotFound(symbol);
    }


    ////////////////////////////////////////////////////////////////////////
    /////////// End of Chainlink Integration Methods ///////////////////////
    ////////////////////////////////////////////////////////////////////////

    /**
      * Checks if the loan is solvent.
      * It means that the Health Ratio is greater than 1e18.
      * @dev This function uses the redstone-evm-connector
    **/
    function isSolvent() public view returns (bool) {
        if(DiamondStorageLib.isAccountFrozen()){
            revert AccountFrozen();
        }
        return getHealthRatio() >= 1e18;
    }

    function isSolventPayable() external payable returns (bool) {
        return isSolvent();
    }

    /**
      * Checks if the loan is solvent.
      * It means that the Health Ratio is greater than 1e18.
      * Uses provided AssetPrice struct arrays instead of extracting the pricing data from the calldata again.
      * @param cachedPrices Struct containing arrays of Asset/Price structs used to calculate value of owned assets, debt and staked positions
    **/
    function isSolventWithPrices(CachedPrices memory cachedPrices) public view returns (bool) {
        return getHealthRatioWithPrices(cachedPrices) >= 1e18;
    }

    /**
      * Returns an array of Asset/Price structs of staked positions.
      * @dev This function uses the redstone-evm-connector
    **/
    function getStakedPositionsPrices() public view returns(AssetPrice[] memory result) {
        IStakingPositions.StakedPosition[] storage positions = DiamondStorageLib.stakedPositions();

        bytes32[] memory symbols = new bytes32[](positions.length);
        for(uint256 i=0; i<positions.length; i++) {
            symbols[i] = positions[i].symbol;
        }

        uint256[] memory stakedPositionsPrices = getPricesFromRedstoneAndChainlink(symbols);
        result = new AssetPrice[](stakedPositionsPrices.length);

        for(uint i; i<stakedPositionsPrices.length; i++){
            result[i] = AssetPrice({
                asset: symbols[i],
                price: stakedPositionsPrices[i]
            });
        }
    }

    /**
      * Returns an array of bytes32[] symbols of debt (borrowable) assets.
    **/
    function getDebtAssets() public view returns(bytes32[] memory result) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        result = tokenManager.getAllPoolAssets();
    }

    /**
      * Returns an array of Asset/Price structs of debt (borrowable) assets.
      * @dev This function uses the redstone-evm-connector
    **/
    function getDebtAssetsPrices() public view returns(AssetPrice[] memory result) {
        bytes32[] memory debtAssets = getDebtAssets();

        uint256[] memory debtAssetsPrices = getPricesFromRedstoneAndChainlink(debtAssets);
        result = new AssetPrice[](debtAssetsPrices.length);

        for(uint i; i<debtAssetsPrices.length; i++){
            result[i] = AssetPrice({
                asset: debtAssets[i],
                price: debtAssetsPrices[i]
            });
        }
    }

    /**
      * Returns an array of Asset/Price structs of enriched (always containing AVAX at index 0) owned assets.
      * @dev This function uses the redstone-evm-connector
    **/
    function getOwnedAssetsWithNativePrices() public view returns(AssetPrice[] memory result) {
        bytes32[] memory assetsEnriched = getOwnedAssetsWithNative();
        uint256[] memory prices = getPricesFromRedstoneAndChainlink(assetsEnriched);

        result = new AssetPrice[](assetsEnriched.length);

        for(uint i; i<assetsEnriched.length; i++){
            result[i] = AssetPrice({
                asset: assetsEnriched[i],
                price: prices[i]
            });
        }
    }

    /**
      * Returns an array of bytes32[] symbols of staked positions.
    **/
    function getStakedAssets() internal view returns (bytes32[] memory result) {
        IStakingPositions.StakedPosition[] storage positions = DiamondStorageLib.stakedPositions();
        result = new bytes32[](positions.length);
        for(uint i; i<positions.length; i++) {
            result[i] = positions[i].symbol;
        }
    }

    /**
      * Returns an array of unique bytes32[] symbols of tokens in TraderJoe V2 positions.
      * This is needed because TJv2 positions may contain tokens that are not in ownedAssets.
    **/
    function getTraderJoeV2TokenSymbols() internal view returns (bytes32[] memory result) {
        ITraderJoeV2Facet.TraderJoeV2Bin[] memory ownedBins = DiamondStorageLib.getTjV2OwnedBinsView();

        if (ownedBins.length == 0) {
            return new bytes32[](0);
        }

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        // Maximum possible unique tokens is 2 * number of bins (each bin has tokenX and tokenY)
        bytes32[] memory tempSymbols = new bytes32[](ownedBins.length * 2);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < ownedBins.length; i++) {
            address tokenXAddress = address(ownedBins[i].pair.getTokenX());
            address tokenYAddress = address(ownedBins[i].pair.getTokenY());

            bytes32 symbolX = tokenManager.tokenAddressToSymbol(tokenXAddress);
            bytes32 symbolY = tokenManager.tokenAddressToSymbol(tokenYAddress);

            // Add symbolX if not already in the array
            bool foundX = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tempSymbols[j] == symbolX) {
                    foundX = true;
                    break;
                }
            }
            if (!foundX) {
                tempSymbols[uniqueCount] = symbolX;
                uniqueCount++;
            }

            // Add symbolY if not already in the array
            bool foundY = false;
            for (uint256 j = 0; j < uniqueCount; j++) {
                if (tempSymbols[j] == symbolY) {
                    foundY = true;
                    break;
                }
            }
            if (!foundY) {
                tempSymbols[uniqueCount] = symbolY;
                uniqueCount++;
            }
        }

        // Copy to correctly sized array
        result = new bytes32[](uniqueCount);
        for (uint256 i = 0; i < uniqueCount; i++) {
            result[i] = tempSymbols[i];
        }
    }

    function copyToArray(bytes32[] memory target, bytes32[] memory source, uint256 offset, uint256 numberOfItems) pure internal {
        if(numberOfItems > source.length){
            revert ArrayLengthMismatch();
        }
        if(offset + numberOfItems > target.length){
            revert ArrayLengthMismatch();
        }

        for(uint i; i<numberOfItems; i++){
            target[i + offset] = source[i];
        }
    }

    function copyToAssetPriceArray(AssetPrice[] memory target, bytes32[] memory sourceAssets, uint256[] memory sourcePrices, uint256 offset, uint256 numberOfItems) pure internal {
        if(numberOfItems > sourceAssets.length){
            revert ArrayLengthMismatch();
        }
        if(numberOfItems > sourcePrices.length){
            revert ArrayLengthMismatch();
        }
        if(offset + numberOfItems > sourceAssets.length){
            revert ArrayLengthMismatch();
        }
        if(offset + numberOfItems > sourcePrices.length){
            revert ArrayLengthMismatch();
        }

        for(uint i; i<numberOfItems; i++){
            target[i] = AssetPrice({
                asset: sourceAssets[i+offset],
                price: sourcePrices[i+offset]
            });
        }
    }

    /**
      * Returns CachedPrices struct consisting of Asset/Price arrays for ownedAssets, debtAssets, stakedPositions and assetsToRepay.
      * Used during the liquidation process in order to obtain all necessary prices from calldata only once.
      * @dev This function uses the redstone-evm-connector
    **/
    function getAllPricesForLiquidation(bytes32[] memory assetsToRepay) public view returns (CachedPrices memory result) {
        bytes32[] memory ownedAssetsEnriched = getOwnedAssetsWithNative();
        bytes32[] memory debtAssets = getDebtAssets();
        bytes32[] memory stakedAssets = getStakedAssets();
        bytes32[] memory tjv2TokenSymbols = getTraderJoeV2TokenSymbols();

        bytes32[] memory allAssetsSymbols = new bytes32[](ownedAssetsEnriched.length + debtAssets.length + stakedAssets.length + assetsToRepay.length + tjv2TokenSymbols.length);
        uint256 offset;

        // Populate allAssetsSymbols with owned assets symbols
        copyToArray(allAssetsSymbols, ownedAssetsEnriched, offset, ownedAssetsEnriched.length);
        offset += ownedAssetsEnriched.length;

        // Populate allAssetsSymbols with debt assets symbols
        copyToArray(allAssetsSymbols, debtAssets, offset, debtAssets.length);
        offset += debtAssets.length;

        // Populate allAssetsSymbols with staked assets symbols
        copyToArray(allAssetsSymbols, stakedAssets, offset, stakedAssets.length);
        offset += stakedAssets.length;

        // Populate allAssetsSymbols with assets to repay symbols
        copyToArray(allAssetsSymbols, assetsToRepay, offset, assetsToRepay.length);
        offset += assetsToRepay.length;

        // Populate allAssetsSymbols with TJv2 token symbols (needed for _getTotalTraderJoeV2)
        copyToArray(allAssetsSymbols, tjv2TokenSymbols, offset, tjv2TokenSymbols.length);

        uint256[] memory allAssetsPrices = getPricesFromRedstoneAndChainlink(allAssetsSymbols);

        offset = 0;

        AssetPrice[] memory ownedAssetsPrices = new AssetPrice[](ownedAssetsEnriched.length);
        copyToAssetPriceArray(ownedAssetsPrices, allAssetsSymbols, allAssetsPrices, offset, ownedAssetsEnriched.length);
        offset += ownedAssetsEnriched.length;

        // Populate debtAssetsPrices struct
        AssetPrice[] memory debtAssetsPrices = new AssetPrice[](debtAssets.length);
        copyToAssetPriceArray(debtAssetsPrices, allAssetsSymbols, allAssetsPrices, offset, debtAssets.length);
        offset += debtAssets.length;

        // Populate stakedPositionsPrices struct
        AssetPrice[] memory stakedPositionsPrices = new AssetPrice[](stakedAssets.length);
        copyToAssetPriceArray(stakedPositionsPrices, allAssetsSymbols, allAssetsPrices, offset, stakedAssets.length);
        offset += stakedAssets.length;

        // Populate assetsToRepayPrices struct
        // Stack too deep :F
        AssetPrice[] memory assetsToRepayPrices = new AssetPrice[](assetsToRepay.length);
        for(uint i=0; i<assetsToRepay.length; i++){
            assetsToRepayPrices[i] = AssetPrice({
                asset: allAssetsSymbols[i+offset],
                price: allAssetsPrices[i+offset]
            });
        }
        offset += assetsToRepay.length;

        // Populate tjv2TokenPrices in its own slot so findPriceInCachedPrices can
        // resolve tokenX / tokenY for non-owned TJv2 bin tokens
        AssetPrice[] memory tjv2TokenPrices = new AssetPrice[](tjv2TokenSymbols.length);
        copyToAssetPriceArray(tjv2TokenPrices, allAssetsSymbols, allAssetsPrices, offset, tjv2TokenSymbols.length);

        result = CachedPrices({
            ownedAssetsPrices: ownedAssetsPrices,
            debtAssetsPrices: debtAssetsPrices,
            stakedPositionsPrices: stakedPositionsPrices,
            assetsToRepayPrices: assetsToRepayPrices,
            tjv2TokenPrices: tjv2TokenPrices
        });
    }

    // Check whether there is enough debt-denominated tokens to fully repaid what was previously borrowed
    function canRepayDebtFully() external view returns(bool) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory poolAssets = tokenManager.getAllPoolAssets();

        for(uint i; i< poolAssets.length; i++) {
            Pool pool = Pool(DeploymentConstants.getTokenManager().getPoolAddress(poolAssets[i]));
            IERC20 token = IERC20(pool.tokenAddress());
            if(token.balanceOf(address(this)) < pool.getBorrowed(address(this))) {
                return false;
            }
        }
        return true;
    }

    /**
      * Helper method exposing the getPricesFromRedstoneAndChainlink() method.
      * @dev This function uses the redstone-evm-connector
    **/
    function getPrices(bytes32[] memory symbols) external view returns (uint256[] memory) {
        return getPricesFromRedstoneAndChainlink(symbols);
    }

    /**
      * Helper method exposing the getPricesFromRedstoneAndChainlink() method.
      * @dev This function uses the redstone-evm-connector
    **/
    function getPrice(bytes32 symbol) external view returns (uint256) {
        bytes32[] memory symbols = new bytes32[](1);
        symbols[0] = symbol;
        uint256[] memory prices = getPricesFromRedstoneAndChainlink(symbols);
        return prices[0];
    }

    /**
      * Returns TotalWeightedValue of OwnedAssets in USD based on the supplied array of Asset/Price struct, tokenBalance and debtCoverage
    **/
    function _getTWVOwnedAssets(AssetPrice[] memory ownedAssetsPrices) internal virtual view returns (uint256) {
        bytes32 nativeTokenSymbol = DeploymentConstants.getNativeTokenSymbol();
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        uint256 weightedValueOfTokens = ownedAssetsPrices[0].price * address(this).balance * tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(),tokenManager.getAssetAddress(nativeTokenSymbol, true)) / (10 ** 26);

        if (ownedAssetsPrices.length > 0) {

            for (uint256 i = 0; i < ownedAssetsPrices.length; i++) {
                IERC20Metadata token = IERC20Metadata(tokenManager.getAssetAddress(ownedAssetsPrices[i].asset, true));
                uint256 balance = _getSolvencyBalance(address(token), ownedAssetsPrices[i].price, ownedAssetsPrices, tokenManager);
                weightedValueOfTokens = weightedValueOfTokens + (ownedAssetsPrices[i].price * balance * tokenManager.tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(),address(token)) / (10 ** token.decimals() * 1e8));
            }
        }
        return weightedValueOfTokens;
    }

    /**
     * @notice Returns the balance of a given token to use in solvency calculations, adjusted
     *         for any pending GMX V2 performance fee owed on GM/GLV positions.
     * @dev For a token with an active GMX V2 benchmark this returns `balance - feeInGmTokens`,
     *      so the solvency path nets out the unrealized-performance fee exactly as the view
     *      path does — without this, a PA could borrow against the gross (pre-fee) value and
     *      sweepFeesAndUpdateBenchMark() could be blocked by its own remainsSolvent modifier.
     *      For all other tokens it returns the raw balance.
     *
     *      If a price for an underlying long/short token is not present in
     *      `ownedAssetsPrices` (e.g. the PA holds the GM token but not the underlying), the
     *      price is fetched via the same RedStone+Chainlink path used to build
     *      `ownedAssetsPrices`, which reverts if the caller did not sign that price. This
     *      prevents a PA from skipping the fee deduction by keeping the underlying tokens
     *      out of its `ownedAssets`.
     */
    function _getSolvencyBalance(
        address token,
        uint256 tokenPriceUsd,
        AssetPrice[] memory ownedAssetsPrices,
        ITokenManager tokenManager
    ) internal view returns (uint256) {
        uint256 rawBalance = IERC20Metadata(token).balanceOf(address(this));

        DiamondStorageLib.GmxPositionBenchmark memory benchmark = DiamondStorageLib.getGmxPositionBenchmark(token);
        if (!benchmark.exists || tokenPriceUsd == 0 || rawBalance == 0) {
            return rawBalance;
        }

        // Resolve long/short prices. _findPriceForToken returns a real price or reverts —
        // there is no silent fail-open path. For GmxPlus markets we skip the short lookup
        // entirely because shortTokenAddress == longTokenAddress (or address(0)) and the
        // short side contributes 0.
        uint256 longPrice = _findPriceForToken(benchmark.longTokenAddress, ownedAssetsPrices, tokenManager);

        uint256 shortPrice;
        if (benchmark.shortTokenAddress != address(0) && benchmark.shortTokenAddress != benchmark.longTokenAddress) {
            shortPrice = _findPriceForToken(benchmark.shortTokenAddress, ownedAssetsPrices, tokenManager);
        }

        // Delegate to `GmxBenchmarkMath.deductibleFeeInGmTokens` so this code path and
        // `GmxV2FeesHelper._getDeductibleFeesInGmTokens` (used by SmartLoanViewFacet for
        // net-of-fee balance reporting) share a single source of truth for the fee math.
        uint256 feeInGmTokens = GmxBenchmarkMath.deductibleFeeInGmTokens(
            token, tokenPriceUsd, longPrice, shortPrice
        );
        return feeInGmTokens >= rawBalance ? 0 : rawBalance - feeInGmTokens;
    }

    /// @dev Returns the price for `token`. Searches the pre-built `prices` array first; if
    /// the symbol is absent (the caller holds the token but it is not in their `ownedAssets`
    /// registry, e.g. a GM market's underlying long/short token), falls back to the
    /// RedStone+Chainlink path, which reverts if the price was not signed by the caller.
    function _findPriceForToken(address token, AssetPrice[] memory prices, ITokenManager tokenManager) internal view returns (uint256) {
        bytes32 symbol = tokenManager.tokenAddressToSymbol(token);
        for (uint256 i = 0; i < prices.length; i++) {
            if (prices[i].asset == symbol) {
                return prices[i].price;
            }
        }
        bytes32[] memory single = new bytes32[](1);
        single[0] = symbol;
        return getPricesFromRedstoneAndChainlink(single)[0];
    }

    /**
      * Returns TotalWeightedValue of StakedPositions in USD based on the supplied array of Asset/Price struct, positionBalance and debtCoverage
    **/
    function _getTWVStakedPositions(AssetPrice[] memory stakedPositionsPrices) internal view returns (uint256) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        IStakingPositions.StakedPosition[] storage positions = DiamondStorageLib.stakedPositions();

        uint256 weightedValueOfStaked;

        for (uint256 i; i < positions.length; i++) {
            if(stakedPositionsPrices[i].asset != positions[i].symbol){
                revert PriceSymbolPositionMismatch();
            }

            (bool success, bytes memory result) = address(this).staticcall(abi.encodeWithSelector(positions[i].balanceSelector));

            if (success) {
                uint256 balance = abi.decode(result, (uint256));

                IERC20Metadata token = IERC20Metadata(DeploymentConstants.getTokenManager().getAssetAddress(stakedPositionsPrices[i].asset, true));

                weightedValueOfStaked += stakedPositionsPrices[i].price * balance * tokenManager.tieredDebtCoverageStaked(DiamondStorageLib.getPrimeLeverageTier(), positions[i].identifier) / (10 ** token.decimals() * 10**8);
            }


        }
        return weightedValueOfStaked;
    }

    function _getThresholdWeightedValueBase(CachedPrices memory cachedPrices) internal view virtual returns (uint256) {
        return _getTWVOwnedAssets(cachedPrices.ownedAssetsPrices) 
            + _getTWVStakedPositions(cachedPrices.stakedPositionsPrices) 
            + _getTotalTraderJoeV2(true, cachedPrices);
    }

    /**
      * Returns the threshold weighted value of assets in USD including all tokens as well as staking and LP positions
      * @dev This function uses the redstone-evm-connector
    **/
    function getThresholdWeightedValue() public view virtual returns (uint256) {
        CachedPrices memory cachedPrices = getAllPricesForLiquidation(new bytes32[](0));
        return _getThresholdWeightedValueBase(cachedPrices);
    }

    function getThresholdWeightedValuePayable() external payable virtual returns (uint256) {
        return getThresholdWeightedValue();
    }

    /**
      * Returns the threshold weighted value of assets in USD including all tokens as well as staking and LP positions
      * Uses provided AssetPrice struct arrays instead of extracting the pricing data from the calldata again.
    **/
    function getThresholdWeightedValueWithPrices(CachedPrices memory cachedPrices) public view virtual returns (uint256) {
        return _getThresholdWeightedValueBase(cachedPrices);
    }


    /**
     * Returns the current debt denominated in USD
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function getDebtBase(AssetPrice[] memory debtAssetsPrices) internal view returns (uint256){
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256 debt;

        for (uint256 i; i < debtAssetsPrices.length; i++) {
            IERC20Metadata token = IERC20Metadata(tokenManager.getAssetAddress(debtAssetsPrices[i].asset, true));

            Pool pool = Pool(tokenManager.getPoolAddress(debtAssetsPrices[i].asset));
            //10**18 (wei in eth) / 10**8 (precision of oracle feed) = 10**10
            debt = debt + pool.getBorrowed(address(this)) * debtAssetsPrices[i].price * 10 ** 10
            / 10 ** token.decimals();
        }

        return debt;
    }

    /**
     * Returns the current debt denominated in USD
     * @dev This function uses the redstone-evm-connector
    **/
    function getDebt() public view virtual returns (uint256) {
        AssetPrice[] memory debtAssetsPrices = getDebtAssetsPrices();
        return getDebtBase(debtAssetsPrices);
    }

    function getDebtPayable() external payable returns (uint256){
        return getDebt();
    }

    /**
     * Returns the current debt denominated in USD
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function getDebtWithPrices(AssetPrice[] memory debtAssetsPrices) public view virtual returns (uint256) {
        return getDebtBase(debtAssetsPrices);
    }


    /**
     * Returns the current value of Prime Account in USD including all tokens as well as staking and LP positions
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function _getTotalAssetsValueBase(AssetPrice[] memory ownedAssetsPrices) public virtual view returns (uint256) {
        if (ownedAssetsPrices.length > 0) {
            ITokenManager tokenManager = DeploymentConstants.getTokenManager();

            uint256 total = address(this).balance * ownedAssetsPrices[0].price / 10 ** 8;

            for (uint256 i = 0; i < ownedAssetsPrices.length; i++) {
                IERC20Metadata token = IERC20Metadata(tokenManager.getAssetAddress(ownedAssetsPrices[i].asset, true));
                // Deduct any pending GMX V2 performance fee from GM/GLV token balances.
                // For non-GM/GLV tokens this returns the raw balance.
                uint256 assetBalance = _getSolvencyBalance(address(token), ownedAssetsPrices[i].price, ownedAssetsPrices, tokenManager);

                total = total + (ownedAssetsPrices[i].price * 10 ** 10 * assetBalance / (10 ** token.decimals()));
            }
            return total;
        } else {
            return 0;
        }
    }

    /**
     * Returns the current value of Prime Account in USD including all tokens as well as staking and LP positions
     * @dev This function uses the redstone-evm-connector
     **/
    function getTotalAssetsValue() public view virtual returns (uint256) {
        AssetPrice[] memory ownedAssetsPrices = getOwnedAssetsWithNativePrices();
        return _getTotalAssetsValueBase(ownedAssetsPrices);
    }

    /**
     * Returns the current value of Prime Account in USD including all tokens as well as staking and LP positions
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function getTotalAssetsValueWithPrices(AssetPrice[] memory ownedAssetsPrices) public view virtual returns (uint256) {
        return _getTotalAssetsValueBase(ownedAssetsPrices);
    }

    /**
      * Returns list of owned assets that always included NativeToken at index 0
    **/
    function getOwnedAssetsWithNative() public view returns(bytes32[] memory){
        bytes32[] memory ownedAssets = DeploymentConstants.getAllOwnedAssets();
        bytes32 nativeTokenSymbol = DeploymentConstants.getNativeTokenSymbol();

        // If account already owns the native token the use ownedAssets.length; Otherwise add one element to account for additional native token.
        uint256 numberOfAssets = DiamondStorageLib.hasAsset(nativeTokenSymbol) ? ownedAssets.length : ownedAssets.length + 1;
        bytes32[] memory assetsWithNative = new bytes32[](numberOfAssets);

        uint256 lastUsedIndex;
        assetsWithNative[0] = nativeTokenSymbol; // First asset = NativeToken

        for(uint i=0; i< ownedAssets.length; i++){
            if(ownedAssets[i] != nativeTokenSymbol){
                lastUsedIndex += 1;
                assetsWithNative[lastUsedIndex] = ownedAssets[i];
            }
        }
        return assetsWithNative;
    }

    /**
     * Returns the current value of staked positions in USD.
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function _getStakedValueBase(AssetPrice[] memory stakedPositionsPrices) internal view returns (uint256) {
        IStakingPositions.StakedPosition[] storage positions = DiamondStorageLib.stakedPositions();

        uint256 usdValue;

        for (uint256 i; i < positions.length; i++) {
            if(stakedPositionsPrices[i].asset != positions[i].symbol){
                revert PriceSymbolPositionMismatch();
            }

            (bool success, bytes memory result) = address(this).staticcall(abi.encodeWithSelector(positions[i].balanceSelector));

            if (success) {
                uint256 balance = abi.decode(result, (uint256));
                IERC20Metadata token = IERC20Metadata(DeploymentConstants.getTokenManager().getAssetAddress(stakedPositionsPrices[i].asset, true));
                usdValue += stakedPositionsPrices[i].price * 10 ** 10 * balance / (10 ** token.decimals());
            }
        }

        return usdValue;
    }

    function getTotalTraderJoeV2() public view virtual returns (uint256) {
        CachedPrices memory cachedPrices = getAllPricesForLiquidation(new bytes32[](0));
        return _getTotalTraderJoeV2(false, cachedPrices);
    }

    function _getTotalTraderJoeV2(bool weighted, CachedPrices memory cachedPrices) internal view returns (uint256) {
        uint256 total;

        ITraderJoeV2Facet.TraderJoeV2Bin[] memory ownedTraderJoeV2Bins = DiamondStorageLib.getTjV2OwnedBinsView();

        PriceInfo memory priceInfo;

        if (ownedTraderJoeV2Bins.length > 0) {
            for (uint256 i; i < ownedTraderJoeV2Bins.length; i++) {
                ITraderJoeV2Facet.TraderJoeV2Bin memory binInfo = ownedTraderJoeV2Bins[i];

                uint256 price;
                uint256 liquidity;

                {
                    address tokenXAddress = address(binInfo.pair.getTokenX());
                    address tokenYAddress = address(binInfo.pair.getTokenY());

                    if (priceInfo.tokenX != tokenXAddress || priceInfo.tokenY != tokenYAddress) {
                        bytes32 symbolX = DeploymentConstants.getTokenManager().tokenAddressToSymbol(tokenXAddress);
                        bytes32 symbolY = DeploymentConstants.getTokenManager().tokenAddressToSymbol(tokenYAddress);

                        uint256 priceX = findPriceInCachedPrices(cachedPrices, symbolX);
                        uint256 priceY = findPriceInCachedPrices(cachedPrices, symbolY);
                        
                        priceInfo = PriceInfo(tokenXAddress, tokenYAddress, priceX, priceY);
                    }
                }

                {
                    (uint128 binReserveX, uint128 binReserveY) = binInfo.pair.getBin(binInfo.id);

                    price = PriceHelper.convert128x128PriceToDecimal(binInfo.pair.getPriceFromId(binInfo.id));

                    liquidity = price * binReserveX / 10 ** 18 + binReserveY;

                    // Bin prices are truncated to 18 decimals and collapse to zero for bins far
                    // enough below the active one, which would make the tokenX-denominated leg
                    // below divide by zero. A bin priced under 1e-18 of the pair ratio holds no
                    // meaningful value, so skip it rather than divide by its price.
                    if (price == 0) continue;
                }


                {
                    // tokenX-denominated leg, factored so the shared decimals/price tail is applied
                    // once. Division order is unchanged from the two inlined branches it replaces.
                    uint256 valueX;
                    {
                        uint256 debtCoverageX = weighted ? DeploymentConstants.getTokenManager().tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(),address(binInfo.pair.getTokenX())) : 1e18;
                        valueX = price > 10**24 ?
                            debtCoverageX * liquidity / (price / 10 ** 18)
                            :
                            debtCoverageX * liquidity / price * 10**18;
                    }
                    valueX = valueX / 10 ** IERC20Metadata(address(binInfo.pair.getTokenX())).decimals() * priceInfo.priceX / 10 ** 8;

                    uint256 debtCoverageY = weighted ? DeploymentConstants.getTokenManager().tieredDebtCoverage(DiamondStorageLib.getPrimeLeverageTier(),address(binInfo.pair.getTokenY())) : 1e18;

                    total = total +
                    Math.min(
                        valueX,
                        debtCoverageY * liquidity / 10**(IERC20Metadata(address(binInfo.pair.getTokenY())).decimals()) * priceInfo.priceY / 10 ** 8
                    )
                    .mulDivRoundDown(binInfo.pair.balanceOf(address(this), binInfo.id), 1e18)
                    .mulDivRoundDown(1e18, Math.max(binInfo.pair.totalSupply(binInfo.id), 1));
                }
            }

            return total;
        } else {
            return 0;
        }
    }

    /**
     * Returns the current value of staked positions in USD.
     * Uses provided AssetPrice struct array instead of extracting the pricing data from the calldata again.
    **/
    function getStakedValueWithPrices(AssetPrice[] memory stakedPositionsPrices) public view returns (uint256) {
        return _getStakedValueBase(stakedPositionsPrices);
    }

    /**
     * Returns the current value of staked positions in USD.
     * @dev This function uses the redstone-evm-connector
    **/
    function getStakedValue() public view virtual returns (uint256) {
        AssetPrice[] memory stakedPositionsPrices = getStakedPositionsPrices();
        return _getStakedValueBase(stakedPositionsPrices);
    }

    /**
     * Returns the current value of Prime Account in USD including all tokens as well as staking and LP positions
     * @dev This function uses the redstone-evm-connector
    **/
    function getTotalValue() public view virtual returns (uint256) {
        CachedPrices memory cachedPrices = getAllPricesForLiquidation(new bytes32[](0));
        
        uint256 assetsValue = getTotalAssetsValueWithPrices(cachedPrices.ownedAssetsPrices);
        uint256 stakedValue = getStakedValueWithPrices(cachedPrices.stakedPositionsPrices);
        uint256 tjv2Value = _getTotalTraderJoeV2(false, cachedPrices);

        return assetsValue + stakedValue + tjv2Value;
    }

    function getFullLoanStatus() public view returns (uint256[5] memory) {
        return [getTotalValue(), getDebt(), getThresholdWeightedValue(), getHealthRatio(), isSolvent() ? uint256(1) : uint256(0)];
    }

    /**
     * Returns current health ratio (solvency) associated with the loan, defined as threshold weighted value of divided
     * by current debt
     * @dev This function uses the redstone-evm-connector
     **/
    function getHealthRatio() public view virtual returns (uint256) {
        CachedPrices memory cachedPrices = getAllPricesForLiquidation(new bytes32[](0));
        uint256 debt = getDebtWithPrices(cachedPrices.debtAssetsPrices);

        if (debt == 0) {
            return type(uint256).max;
        } else {
            uint256 thresholdWeightedValue = getThresholdWeightedValueWithPrices(cachedPrices);
            return thresholdWeightedValue * 1e18 / debt;
        }
    }

    /**
     * Returns current health ratio (solvency) associated with the loan, defined as threshold weighted value of divided
     * by current debt
     * Uses provided AssetPrice struct arrays instead of extracting the pricing data from the calldata again.
     **/
    function getHealthRatioWithPrices(CachedPrices memory cachedPrices) public view virtual returns (uint256) {
        uint256 debt = getDebtWithPrices(cachedPrices.debtAssetsPrices);

        if (debt == 0) {
            return type(uint256).max;
        } else {
            uint256 thresholdWeightedValue = getThresholdWeightedValueWithPrices(cachedPrices);
            return thresholdWeightedValue * 1e18 / debt;
        }
    }

    // ERRORS
    error PriceSymbolPositionMismatch();

    error AccountFrozen();

    error ArrayLengthMismatch();

    error ChainlinkWrongDecimals();
    error ChainlinkWrongPrice();
    error ChainlinkStaleRound();
    error ChainlinkIncompleteRound();
    error ChainlinkStaleData();
    error BorrowableAssetRedstoneRequired(bytes32 symbol);
    error SymbolNotFound(bytes32 symbol);
}