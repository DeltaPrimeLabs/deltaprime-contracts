// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: ;
pragma solidity 0.8.17;

import "../interfaces/ITokenManager.sol";
import {DiamondStorageLib} from "./DiamondStorageLib.sol";
import {DeploymentChainConfig} from "./DeploymentChainConfig.sol";

/**
 * DeploymentConstants
 * Stable facade over the generated DeploymentChainConfig (compile-time chain
 * selection — regenerate the config with tools/scripts/select-chain-config.js,
 * never edit it by hand). Replaces the per-chain lib/<chain>/DeploymentConstants.sol
 * variants and the import-rewriting in tools/scripts/update-constants.js.
 * BE CAREFUL WHEN UPDATING. CONSTANTS ARE USED ACROSS MANY FACETS.
 **/
library DeploymentConstants {
    // Used for LiquidationBonus calculations (identical on every chain)
    uint256 private constant _PERCENTAGE_PRECISION = 1000;

    //implementation-specific

    function getPercentagePrecision() internal pure returns (uint256) {
        return _PERCENTAGE_PRECISION;
    }

    //blockchain-specific

    function getNativeTokenSymbol() internal pure returns (bytes32 symbol) {
        return DeploymentChainConfig.NATIVE_TOKEN_SYMBOL;
    }

    function getNativeToken() internal pure returns (address payable) {
        return payable(DeploymentChainConfig.NATIVE_ADDRESS);
    }

    function getGmxDataStoreAddress() internal pure returns (address) {
        return DeploymentChainConfig.GMX_DATA_STORE;
    }

    function getGmxReaderAddress() internal pure returns (address) {
        return DeploymentChainConfig.GMX_READER;
    }

    function getGlvReaderAddress() internal pure returns (address) {
        return DeploymentChainConfig.GLV_READER;
    }

    //deployment-specific

    function getDiamondAddress() internal pure returns (address) {
        return DeploymentChainConfig.DIAMOND_BEACON;
    }

    function getSmartLoansFactoryAddress() internal pure returns (address) {
        return DeploymentChainConfig.SMART_LOANS_FACTORY;
    }

    function getTokenManager() internal pure returns (ITokenManager) {
        return ITokenManager(DeploymentChainConfig.TOKEN_MANAGER);
    }

    function getDepositSwapAddress() internal pure returns (address) {
        return DeploymentChainConfig.DEPOSIT_SWAP;
    }

    function getAddressProvider() internal pure returns (address) {
        return DeploymentChainConfig.ADDRESS_PROVIDER;
    }

    function getTreasuryAddress() internal pure returns (address) {
        return DeploymentChainConfig.FEES_TREASURY;
    }

    function getStabilityPoolAddress() internal pure returns (address) {
        return DeploymentChainConfig.STABILITY_POOL;
    }

    /**
    * Returns all owned assets keys
    **/
    function getAllOwnedAssets() internal view returns (bytes32[] memory result) {
        DiamondStorageLib.SmartLoanStorage storage sls = DiamondStorageLib.smartLoanStorage();
        return sls.ownedAssets._inner._keys._inner._values;
    }
}
