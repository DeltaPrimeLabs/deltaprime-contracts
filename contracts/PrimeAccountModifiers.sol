// SPDX-License-Identifier: MIT
// Provides modifiers for Prime Account (smart loan) operations

import {DiamondStorageLib} from "./lib/DiamondStorageLib.sol";
import {ISmartLoanLiquidationFacet} from "./interfaces/facets/ISmartLoanLiquidationFacet.sol";
import "./lib/DeploymentConstants.sol";
import {DiamondSolvencyMethodsAccess} from "./lib/DiamondSolvencyMethodsAccess.sol";

pragma solidity 0.8.17;

/**
 * @dev Provides access control modifiers
 */
abstract contract PrimeAccountModifiers is DiamondSolvencyMethodsAccess {

    /**
     * @dev Enforces that caller is the contract owner
     */
    modifier onlyOwner() {
        DiamondStorageLib.enforceIsContractOwner();
        _;
    }

    /**
     * @dev Enforces ownership only if there is no liquidation ongoing
     */
    modifier onlyOwnerOrLiquidation() {
        bool isWhitelistedLiquidator = ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender);

        if (isWhitelistedLiquidator) {
            DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
            require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot - call snapshotInsolvency first");
            require(block.timestamp - ls.lastInsolventTimestamp < DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY, "Insolvency snapshot expired - take a new one");
        } else{
            DiamondStorageLib.enforceIsContractOwner();
        }

        _;

        if (!isWhitelistedLiquidator) {
            require(_isSolvent(), "Must stay solvent");
        }
    }

    /**
     * @dev Enforces ownership only if there is no liquidation ongoing
     * This modifier CAN ONLY BE USED with methods that implement alternative solvency checks at the end as this one does not check for solvency at the end
     */
    modifier onlyOwnerOrLiquidationWithNoSolvencyCheck() {
        bool isWhitelistedLiquidator = ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender);

        if (isWhitelistedLiquidator) {
            DiamondStorageLib.LiquidationSnapshotStorage storage ls = DiamondStorageLib.liquidationSnapshotStorage();
            require(ls.lastInsolventTimestamp > 0, "No insolvency snapshot - call snapshotInsolvency first");
            require(block.timestamp - ls.lastInsolventTimestamp < DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY, "Insolvency snapshot expired - take a new one");
        } else{
            DiamondStorageLib.enforceIsContractOwner();
        }

        _;
    }

    /**
     * @dev Enforces that caller is a whitelisted liquidator
     */
    modifier onlyWhitelistedLiquidators() {
        if (!ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender))
            revert OnlyWhitelistedLiquidators();
        _;
    }

    /**
     * @dev Allows either the account owner OR a whitelisted liquidator.
     *      Unlike onlyOwnerOrLiquidation, this does NOT require an insolvency
     *      snapshot and does NOT enforce solvency after the call.
     *      Use ONLY for cleanup operations (e.g. unwinding unsupported positions)
     *      where the solvency check itself would revert.
     */
    modifier onlyOwnerOrWhitelistedLiquidator() {
        if (!ISmartLoanLiquidationFacet(DeploymentConstants.getDiamondAddress()).isLiquidatorWhitelisted(msg.sender)) {
            DiamondStorageLib.enforceIsContractOwner();
        }
        _;
    }

    /**
     * @dev Checks whether account is solvent (health higher than 1)
     */
    modifier remainsSolvent() {
        _;
        require(_isSolvent(), "The action may cause an account to become insolvent");
    }

    /**
     * @dev Checks whether account can fully repay debt
     */
    modifier canRepayDebtFully() {
        _;
        require(_canRepayDebtFully(), "Insufficient assets to fully repay the debt");
    }

    /**
     * @dev Prevents borrowing in the same block
     */
    modifier noBorrowInTheSameBlock() {
        {
            DiamondStorageLib.DiamondStorage storage ds = DiamondStorageLib.diamondStorage();
            require(ds._lastBorrowTimestamp != block.timestamp, "Borrowing must happen in a standalone transaction");
        }
        _;
    }

    /**
     * @dev Prevents actions within 24 hours of ownership transfer
     */
    modifier noOwnershipTransferInLast24hrs() {
        DiamondStorageLib.SmartLoanStorage storage sls = DiamondStorageLib.smartLoanStorage();
        require(block.timestamp - sls.lastOwnershipTransferTimestamp > 1 days, "Ownership was transferred in the last 24 hours");
        _;
    }

    /**
     * @dev Ensures account is not currently in liquidation
     */
    modifier notInLiquidation() {
        _;
        DiamondStorageLib.LiquidationSnapshotStorage storage lss = DiamondStorageLib.liquidationSnapshotStorage();
        require(
            lss.lastInsolventTimestamp == 0 ||
            block.timestamp - lss.lastInsolventTimestamp >= DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY,
            "Account is being liquidated"
        );
    }

    /**
     * @dev Ensures account is not frozen
     */
    modifier accountNotFrozen() {
        require(!DiamondStorageLib.isAccountFrozen(), "Account is frozen");
        _;
    }

    error OnlyWhitelistedLiquidators();
}
