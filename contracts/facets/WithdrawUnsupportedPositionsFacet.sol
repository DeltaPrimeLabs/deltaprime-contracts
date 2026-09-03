// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: cc89474c960bad83ebf009a447365d5b50e193ae;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DiamondStorageLib} from "../lib/DiamondStorageLib.sol";
import {LeverageTierLib} from "../lib/LeverageTierLib.sol";
import "../interfaces/ITokenManager.sol";
import "../ReentrancyGuardKeccak.sol";
import "../lib/DiamondMethodsAccess.sol";
import "../lib/DeploymentConstants.sol";
import "../interfaces/IWithdrawUnsupportedPositionsFacet.sol";
import "../PrimeAccountModifiers.sol";

contract WithdrawUnsupportedPositionsFacet is
    ReentrancyGuardKeccak,
    DiamondMethodsAccess,
    IWithdrawUnsupportedPositionsFacet,
    PrimeAccountModifiers
{
    using SafeERC20 for IERC20Metadata;

    /// @notice Checks if the contract holds any unsupported assets
    /// @dev Used by UI to determine whether to display withdrawable options
    /// @return True if any unsupported assets exist, false otherwise
    function hasUnsupportedAssets() external view returns (bool) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address[] memory unsupportedAssets = tokenManager.getUnsupportedWithdrawableAssets();
        
        for (uint256 i = 0; i < unsupportedAssets.length; i++) {
            if (IERC20Metadata(unsupportedAssets[i]).balanceOf(address(this)) > 0) {
                return true;
            }
        }
        
        return false;
    }

    /// @notice Withdraws all unsupported asset positions from the contract
    /// @dev Gets asset list dynamically from TokenManager - no more hardcoded addresses
    function withdrawUnsupportedPositions() external nonReentrant onlyOwner remainsSolvent {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address[] memory unsupportedAssets = tokenManager.getUnsupportedWithdrawableAssets();
        uint256 totalWithdrawn = 0;
        
        for (uint256 i = 0; i < unsupportedAssets.length; i++) {
            _verifyAssetUnsupported(tokenManager, unsupportedAssets[i]);
            if (_withdrawAsset(unsupportedAssets[i])) {
                totalWithdrawn++;
            }
        }

        emit WithdrawalCompleted(msg.sender, totalWithdrawn, block.timestamp);
    }

    /// @notice Withdraws a single asset from the contract to the owner
    /// @param assetAddress The address of the asset to withdraw
    /// @return success True if withdrawal occurred (balance > 0), false otherwise
    function _withdrawAsset(address assetAddress) private returns (bool success) {
        IERC20Metadata token = IERC20Metadata(assetAddress);
        uint256 balance = token.balanceOf(address(this));
        
        if (balance > 0) {
            uint256 ownerInitialBalance = token.balanceOf(msg.sender);
            token.safeTransfer(msg.sender, balance);
            
            // Verify transfer completed correctly
            uint256 expectedOwnerBalance = ownerInitialBalance + balance;
            uint256 actualOwnerBalance = token.balanceOf(msg.sender);
            if (actualOwnerBalance != expectedOwnerBalance) {
                revert InvalidOwnerBalanceAfterTransfer(expectedOwnerBalance, actualOwnerBalance);
            }
            
            uint256 contractBalance = token.balanceOf(address(this));
            if (contractBalance != 0) {
                revert InvalidContractBalanceAfterTransfer(contractBalance);
            }

            emit UnsupportedAssetWithdrawn(
                msg.sender,
                assetAddress,
                balance,
                block.timestamp
            );
            
            return true;
        }
        
        return false;
    }

    /// @notice Verifies that an asset is truly unsupported in TokenManager
    /// @param tokenManager The TokenManager contract instance
    /// @param assetAddress The address of the asset to verify
    function _verifyAssetUnsupported(ITokenManager tokenManager, address assetAddress) private view {
        // Asset must NOT be PRIME
        address primeAddress = tokenManager.getAssetAddress('PRIME', true);
        if (assetAddress == primeAddress) {
            revert CannotWithdrawPrimeToken(assetAddress);
        }

        // Asset must NOT be active
        if (tokenManager.isTokenAssetActive(assetAddress)) {
            revert AssetStillActive(assetAddress);
        }

        // Asset must have no symbol mapping
        bytes32 symbol = tokenManager.tokenAddressToSymbol(assetAddress);
        if (symbol != bytes32(0)) {
            revert AssetHasSymbolMapping(assetAddress, symbol);
        }

        // Asset must have zero debt coverage
        uint256 debtCov = tokenManager.debtCoverage(assetAddress);
        if (debtCov != 0) {
            revert AssetHasDebtCoverage(assetAddress, debtCov);
        }

        // Asset must have zero tiered debt coverage for BASIC tier
        uint256 basicTierCov = tokenManager.tieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, assetAddress);
        if (basicTierCov != 0) {
            revert AssetHasBasicTierDebtCoverage(assetAddress, basicTierCov);
        }

        // Asset must have zero tiered debt coverage for PREMIUM tier
        uint256 premiumTierCov = tokenManager.tieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, assetAddress);
        if (premiumTierCov != 0) {
            revert AssetHasPremiumTierDebtCoverage(assetAddress, premiumTierCov);
        }
    }
}
