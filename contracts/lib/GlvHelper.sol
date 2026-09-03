// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./DeploymentConstants.sol";
import "./DiamondStorageLib.sol";
import "./DiamondMethodsAccess.sol";
import "../ReentrancyGuardKeccak.sol";
import "../PrimeAccountModifiers.sol";
import "../interfaces/ITokenManager.sol";
import {IGlvReader} from "../interfaces/gmx-v2/IGlvReader.sol";
import {GmxGlvUnifiedHelper} from "./GmxGlvUnifiedHelper.sol";

contract GlvHelper is ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers, GmxGlvUnifiedHelper {


    ///@dev amount of long and short tokens if we're assuming half the GLV tokens are of each
    function _getGlvLongAndShortTokenAmounts(address glvToken, uint256 glvAmount) internal view returns (uint256 longTokenAmount, uint256 shortTokenAmount) {
        UnifiedGmxTokenPricesAndAddresses memory pricesAndAddresses = _getUnifiedGlvTokenPricesAndAddresses(glvToken);
        uint256 glvTokenValue = glvAmount * pricesAndAddresses.gmTokenPrice / (10 ** IERC20Metadata(glvToken).decimals());
        uint256 longTokenValue = glvTokenValue / 2;  ///@dev 8 decimals, so negligible loss of precision
        uint256 shortTokenValue = glvTokenValue / 2;
        longTokenAmount = (longTokenValue * 10 ** IERC20Metadata(pricesAndAddresses.longToken).decimals()) / (pricesAndAddresses.longTokenPrice);
        shortTokenAmount = (shortTokenValue * 10 ** IERC20Metadata(pricesAndAddresses.shortToken).decimals()) / (pricesAndAddresses.shortTokenPrice); //shortTokenValue / pricesAndAddresses.shortTokenPrice;
    }

    function _getGlvLongAndShortTokenAmountsWithCachedPrices(address glvToken, uint256 glvAmount, GmxTokenPrices memory glvTokenPrices) internal view returns (uint256 longTokenAmount, uint256 shortTokenAmount) {
        address glvReader = DeploymentConstants.getGlvReaderAddress();
        address dataStore = DeploymentConstants.getGmxDataStoreAddress();
        IGlvReader.Props memory glvProps = IGlvReader(glvReader).getGlv(dataStore, glvToken);
        uint256 glvTokenValue = glvAmount * glvTokenPrices.gmTokenPrice / (10 ** IERC20Metadata(glvToken).decimals());
        uint256 longTokenValue = glvTokenValue / 2;  ///@dev 8 decimals, so negligible loss of precision
        uint256 shortTokenValue = glvTokenValue / 2;
        longTokenAmount = (longTokenValue * 10 ** IERC20Metadata(glvProps.longToken).decimals()) / (glvTokenPrices.longTokenPrice);
        shortTokenAmount = (shortTokenValue * 10 ** IERC20Metadata(glvProps.shortToken).decimals()) / (glvTokenPrices.shortTokenPrice);
    }

    ///@dev reusing the struct from GmxV2FeesHelper for convenience
    ///@dev any further addition to GmxV2FeesHelper was exceeding the size limit, so adding this function in this facet
    function _getUnifiedGlvTokenPricesAndAddresses(address glvToken) internal view returns (UnifiedGmxTokenPricesAndAddresses memory) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bool isGlvToken = tokenManager.isGlvTokenWhitelisted(glvToken); 
        if (!isGlvToken) revert GlvTokenNotWhitelisted();
        address glvReader = DeploymentConstants.getGlvReaderAddress();
        ///@dev same data store for both GMX and GLV readers
        address dataStore = DeploymentConstants.getGmxDataStoreAddress(); 
        IGlvReader.Props memory glvProps = IGlvReader(glvReader).getGlv(dataStore, glvToken);

        
        address longToken = glvProps.longToken;
        address shortToken = glvProps.shortToken;
        if (longToken == address(0) || shortToken == address(0)) revert GlvTokenNotFound();
        
        bytes32[] memory symbols = new bytes32[](3); // Need glvToken, long token, and short token
        symbols[0] = tokenManager.tokenAddressToSymbol(glvToken);
        symbols[1] = tokenManager.tokenAddressToSymbol(longToken);
        symbols[2] = tokenManager.tokenAddressToSymbol(shortToken);
        
        uint256[] memory prices = getPrices(symbols);
        
        return UnifiedGmxTokenPricesAndAddresses({
            gmTokenPrice: prices[0], // GLV token price, reusing the struct, hence the name
            longTokenPrice: prices[1],
            shortTokenPrice: prices[2], 
            longToken: longToken,
            shortToken: shortToken,
            isPlusMarket: false
        });
    }
    
}