// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 3d82a02e8428929338629f259e5db546859ee768;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../ReentrancyGuardKeccak.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../lib/DiamondMethodsAccess.sol";
import "../Pool.sol";
import "../interfaces/ITokenManager.sol";
import "../PrimeAccountModifiers.sol";

//This path is updated during deployment
import "../lib/DeploymentConstants.sol";

import "./avalanche/SolvencyFacetProdAvalanche.sol";
import "../SmartLoanDiamondBeacon.sol";
import "../interfaces/IBorrowersRegistry.sol";
import "../interfaces/facets/ISmartLoanLiquidationFacet.sol";
import "../lib/LeverageTierLib.sol";


contract SmartLoanLiquidationFacet is ISmartLoanLiquidationFacet, ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers {
    /**
    * Liquidation fee percentages based on leverage tier
    * BASIC: 14% of the repay amount
    * PREMIUM: 7% of the repay amount
    */
    uint256 public constant LIQUIDATION_FEE_PERCENT_BASIC = 140;
    uint256 public constant LIQUIDATION_FEE_PERCENT_PREMIUM = 70;
    uint256 private constant DUST_THRESHOLD_USD = 1e17;

    using TransferHelper for address payable;
    using TransferHelper for address;

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @return uint256 liquidation fee percentage based on user's leverage tier
    **/
    /**
    * @dev Fee percentage for an explicitly supplied tier. liquidate() uses this
    *      with the tier captured by snapshotInsolvency so the fee cannot be moved by the
    *      account owner inside the liquidation window. Takes uint256 rather than the enum
    *      because that is how the snapshot stores it.
    *
    *      `internal` deliberately: liquidate() is its only consumer and calls it in-contract,
    *      so a public selector would have to be added to the diamond — and this repo's cut
    *      tooling has no Add path (checkMethodsSelectorsAgainstDiamondLoupe defaults to
    *      replaceOnly and silently filters unregistered selectors; its else branch throws
    *      "Not implemented!"). Keeping it internal means the selector never exists, so a pure
    *      Replace cut stays correct.
    */
    function getLiquidationFeePercentForTier(uint256 tier) internal pure returns (uint256) {
        if (tier == uint256(LeverageTierLib.LeverageTier.PREMIUM)) {
            return LIQUIDATION_FEE_PERCENT_PREMIUM;
        }
        // Default to BASIC (also covers _NON_EXISTENT and any unset snapshot).
        return LIQUIDATION_FEE_PERCENT_BASIC;
    }

    function getLiquidationFeePercent() public view returns (uint256) {
        LeverageTierLib.LeverageTier currentTier = DiamondStorageLib.getPrimeLeverageTier();
        
        if (currentTier == LeverageTierLib.LeverageTier.PREMIUM) {
            return LIQUIDATION_FEE_PERCENT_PREMIUM;
        } else {
            // Default to BASIC tier fee (also covers _NON_EXISTENT case)
            return LIQUIDATION_FEE_PERCENT_BASIC;
        }
    }

    /**
     * @dev Check if an address is a whitelisted liquidator
     * @param _liquidator Address to check
     * @return bool True if address is whitelisted
     */
    function isLiquidatorWhitelisted(address _liquidator) public view returns(bool){
        DiamondStorageLib.LiquidationStorage storage ls = DiamondStorageLib.liquidationStorage();
        return ls.canLiquidate[_liquidator];
    }

    /**
    * @dev Returns the timestamp of the last insolvency snapshot
    * @return uint256 Timestamp when the insolvency snapshot was taken (0 if not taken)
    */
    function getLastInsolventTimestamp() external view returns (uint256) {
        DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
        return ls.lastInsolventTimestamp;
    }

    /**
    * @dev Returns the health ratio from the insolvency snapshot
    * @return uint256 Health ratio when insolvency snapshot was taken
    */
    function getHealthRatioSnapshot() external view returns (uint256) {
        DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
        return ls.healthRatioSnapshot;
    }

    /* ========== PUBLIC AND EXTERNAL MUTATIVE FUNCTIONS ========== */

    function whitelistLiquidators(address[] memory _liquidators) external onlyOwner {
        address smartLoansFactory = DeploymentConstants.getSmartLoansFactoryAddress();
        DiamondStorageLib.LiquidationStorage storage ls = DiamondStorageLib.liquidationStorage();

        for(uint i; i<_liquidators.length; i++){
            require(IBorrowersRegistry(smartLoansFactory).getLoanForOwner(_liquidators[i])== address(0), "liquidators can't have loans");
            ls.canLiquidate[_liquidators[i]] = true;
            emit LiquidatorWhitelisted(_liquidators[i], msg.sender, block.timestamp);
        }
    }

    function delistLiquidators(address[] memory _liquidators) external onlyOwner {
        DiamondStorageLib.LiquidationStorage storage ls = DiamondStorageLib.liquidationStorage();
        for(uint i; i<_liquidators.length; i++){
            ls.canLiquidate[_liquidators[i]] = false;
            emit LiquidatorDelisted(_liquidators[i], msg.sender, block.timestamp);
        }
    }

    function snapshotInsolvency() external onlyWhitelistedLiquidators accountNotFrozen nonReentrant {
        DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
        bool reArmingExpired = ls.lastInsolventTimestamp != 0 &&
            block.timestamp - ls.lastInsolventTimestamp >= DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY;
        require(ls.lastInsolventTimestamp == 0 || reArmingExpired, "Account is already being liquidated");

        uint256 hr = _getHealthRatio();
        require(hr < 1e18, "Account is solvent");

        ls.lastInsolventTimestamp = block.timestamp;
        ls.healthRatioSnapshot = hr;
        ls.debtSnapshotDollars = _getDebt();
        // Pin the leverage tier. liquidate() reads the fee from this rather than from live
        // storage, so nothing the owner can change inside the window (the tier, and therefore
        // both the fee percentage and the tier's debt coverage) can move the fee.
        ls.leverageTierSnapshot = uint256(DiamondStorageLib.getPrimeLeverageTier());

        // Carry over the accumulated pre-liquidation loss on an expiry re-arm; reset only on a fresh cycle.
        if (!reArmingExpired) {
            delete ls.cumulativeLossDollars;
        }

        emit InsolvencySnapshot(msg.sender, hr, block.timestamp);
    }

    /**
    * @dev Clears the insolvency snapshot when the account becomes solvent again.
    * Can only be called by whitelisted liquidators and requires the account to be solvent.
    */
    function clearInsolvencySnapshot() external onlyWhitelistedLiquidators remainsSolvent accountNotFrozen nonReentrant {
        DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
        require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot to clear");

        // Clear insolvency snapshot
        delete ls.lastInsolventTimestamp;
        delete ls.healthRatioSnapshot;
        delete ls.debtSnapshotDollars;
        delete ls.cumulativeLossDollars;
        delete ls.leverageTierSnapshot;

        emit InsolvencySnapshotCleared(msg.sender, block.timestamp);
    }

    /**
    * This function fully liquidates an insolvent account after an insolvency snapshot has been taken.
    * All debt is repaid using the account's existing tokens and a liquidation fee is 
    * calculated based on the user's leverage tier (14% for BASIC, 7% for PREMIUM) of the repaid amount.
    * 
    * @param _emergencyMode If true, allows partial debt repayment when account lacks sufficient assets.
    *                       In emergency mode: no liquidation bonus, total account value must be 0 post-liquidation.
    **/
    function liquidate(bool _emergencyMode) 
        external 
        onlyWhitelistedLiquidators 
        accountNotFrozen 
        nonReentrant 
    {
        DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
        require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot - call snapshotInsolvency first");
        ///@dev the snapshot itself is the proof of insolvency; once a whitelisted liquidator has
        /// taken it, they are entitled to liquidate within the 15-minute window enforced below
        /// regardless of any subsequent price recovery. Re-checking _isSolvent() here would let an
        /// attacker block legitimate liquidation by pumping prices for a single block.
        require(block.timestamp - ls.lastInsolventTimestamp < DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY, "Insolvency snapshot expired - take a new one");
        
        if (_emergencyMode) {
            _repayAllDebtsPartial();
            
            uint256 totalValue = _getTotalValue();
            require(totalValue <= DUST_THRESHOLD_USD, "Emergency liquidation requires total account value to be 0");
            
            // No liquidation fee distribution in emergency mode
        } else {
            uint256 initialDebt = _getDebt();

            _repayAllDebts();

            uint256 remainingDebt = _getDebt();
            require(remainingDebt == 0, "Not all debt was repaid");
            
            // Use tier-based liquidation fee calculation
            // The fee percentage comes from the tier captured at snapshot time, never from
            // live storage.
            uint256 liquidationFee = initialDebt
                * getLiquidationFeePercentForTier(ls.leverageTierSnapshot)
                / DeploymentConstants.getPercentagePrecision();
            
            uint256 currentTotalValue = _getTotalValue();
            
            uint256 actualLiquidationFee = Math.min(liquidationFee, currentTotalValue);

            // Guard against 0/0: when collateral is fully consumed by debt repayment
            // currentTotalValue == 0 (and actualLiquidationFee is 0 via Math.min above), so a
            // plain division panics. There is no value left to take a fee from, so we skip
            // distribution and let the standard path complete with the debt fully repaid.
            uint256 percentageToTake = currentTotalValue > 0
                ? actualLiquidationFee * 1e18 / currentTotalValue
                : 0;

            if(percentageToTake > 0) {
                _distributeLiquidationFee(percentageToTake);
            }
        }
        
        // Clear insolvency snapshot
        delete ls.lastInsolventTimestamp;
        delete ls.healthRatioSnapshot;
        delete ls.debtSnapshotDollars;
        delete ls.cumulativeLossDollars;
        delete ls.leverageTierSnapshot;

        // Emit liquidation event
        emit Liquidated(
            msg.sender,
            block.timestamp
        );
    }

    /**
    * @dev Repay all debts of the account using its own assets
    */
    function _repayAllDebts() internal {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory debtAssets = tokenManager.getAllPoolAssets();
        
        for (uint256 i = 0; i < debtAssets.length; i++) {
            IERC20Metadata token = IERC20Metadata(tokenManager.getAssetAddress(debtAssets[i], true));
            Pool pool = Pool(tokenManager.getPoolAddress(debtAssets[i]));
            
            uint256 debtAmount = pool.getBorrowed(address(this));
            if (debtAmount > 0) {
                uint256 balance = token.balanceOf(address(this));
                require(balance >= debtAmount, "Insufficient token balance to repay debt");
                
                address(token).safeApprove(address(pool), 0);
                address(token).safeApprove(address(pool), debtAmount);
                pool.repay(debtAmount);
                
                _syncExposure(tokenManager, address(token));
                
                emit LiquidationRepay(msg.sender, debtAssets[i], debtAmount, block.timestamp);
            }
        }
    }

    /**
    * @dev Repay debts partially using available balances (for emergency liquidation mode)
    */
    function _repayAllDebtsPartial() internal {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        bytes32[] memory debtAssets = tokenManager.getAllPoolAssets();
        
        for (uint256 i = 0; i < debtAssets.length; i++) {
            IERC20Metadata token = IERC20Metadata(tokenManager.getAssetAddress(debtAssets[i], true));
            Pool pool = Pool(tokenManager.getPoolAddress(debtAssets[i]));
            
            uint256 debtAmount = pool.getBorrowed(address(this));
            if (debtAmount > 0) {
                uint256 balance = token.balanceOf(address(this));
                
                // Repay as much as possible with available balance
                uint256 repayAmount = Math.min(balance, debtAmount);
                
                if (repayAmount > 0) {
                    address(token).safeApprove(address(pool), 0);
                    address(token).safeApprove(address(pool), repayAmount);
                    pool.repay(repayAmount);
                    
                    _syncExposure(tokenManager, address(token));
                    
                    emit LiquidationRepay(msg.sender, debtAssets[i], repayAmount, block.timestamp);
                }
            }
        }
    }

    /**
    * @dev Distribute the liquidation fee to different treasuries (3-way split)
    */
    function _distributeLiquidationFee(uint256 percentageToTake) internal {
        // Native token transfer (2-way split: 1/3 to stability pool, 2/3 to treasury)
        if (address(this).balance > 0) {
            uint256 transferAmount = address(this).balance * percentageToTake / 1e18;
            uint256 stabilityPoolTransferAmount = transferAmount / 3;
            uint256 treasuryTransferAmount = transferAmount - stabilityPoolTransferAmount;

            if(transferAmount > 3){
                payable(DeploymentConstants.getStabilityPoolAddress()).safeTransferETH(stabilityPoolTransferAmount);
                emit LiquidationTransfer(DeploymentConstants.getStabilityPoolAddress(), DeploymentConstants.getNativeTokenSymbol(), stabilityPoolTransferAmount, block.timestamp);

                payable(DeploymentConstants.getTreasuryAddress()).safeTransferETH(treasuryTransferAmount);
                emit LiquidationFeesTransfer(DeploymentConstants.getTreasuryAddress(), DeploymentConstants.getNativeTokenSymbol(), treasuryTransferAmount, block.timestamp);
            }
        }
        
        bytes32[] memory assetsOwned = DeploymentConstants.getAllOwnedAssets();
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        for (uint256 i; i < assetsOwned.length; i++) {
            IERC20Metadata token = getERC20TokenInstance(assetsOwned[i], true);
            address exposureUpdateAddress = address(token);
            if(address(token) == 0x9e295B5B976a184B14aD8cd72413aD846C299660){
                token = IERC20Metadata(0xaE64d55a6f09E4263421737397D1fdFA71896a69);
            }
            
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                uint256 transferAmount = balance * percentageToTake / 1e18;
                uint256 stabilityPoolTransferAmount = transferAmount / 3;
                uint256 treasuryTransferAmount = transferAmount - stabilityPoolTransferAmount;

                if(transferAmount > 3){
                    address(token).safeTransfer(DeploymentConstants.getStabilityPoolAddress(), stabilityPoolTransferAmount);
                    emit LiquidationTransfer(DeploymentConstants.getStabilityPoolAddress(), assetsOwned[i], stabilityPoolTransferAmount, block.timestamp);

                    address(token).safeTransfer(DeploymentConstants.getTreasuryAddress(), treasuryTransferAmount);
                    emit LiquidationFeesTransfer(DeploymentConstants.getTreasuryAddress(), assetsOwned[i], treasuryTransferAmount, block.timestamp);
                }
                
                _syncExposure(tokenManager, exposureUpdateAddress);
            }
        }
    }
}