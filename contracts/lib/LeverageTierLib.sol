// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./DeploymentConstants.sol";
import "./DiamondStorageLib.sol";
import "../interfaces/ITokenManager.sol";


/**
 * @title LeverageTierLib
 * @dev Library for managing different leverage tier operations, with prime debt calculations
 */
library LeverageTierLib {
    
    enum LeverageTier { BASIC, PREMIUM, _NON_EXISTENT }

    /// @dev Updates the PRIME debt snapshot based on the total borrowed value
    /// @param totalBorrowedValue The total borrowed value in USD
    /// @dev totalBorrowedValue is fetched via _getDebt(), use with caution
    function updatePrimeDebtSnapshot(uint256 totalBorrowedValue) internal {
       
        
        // Calculate current total Prime Debt (recorded + accrued)
        uint256 currentPrimeDebt = getCurrentPrimeDebt(totalBorrowedValue);

        DiamondStorageLib.setPrimeDebt(currentPrimeDebt);

        DiamondStorageLib.setLastPrimeDebtUpdate(block.timestamp);
        
    }

    /// @dev Gets the current Prime Debt based on the total borrowed value
    /// @param totalBorrowedValue The total borrowed value in USD
    /// @return The current Prime Debt amount
    function getCurrentPrimeDebt(uint256 totalBorrowedValue) internal view returns (uint256) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        
        // Get the last recorded Prime Debt snapshot
        uint256 recordedPrimeDebt = DiamondStorageLib.getPrimeDebt();
        
        // Calculate time elapsed since last snapshot
        uint256 timeElapsed = block.timestamp - DiamondStorageLib.getLastPrimeDebtUpdate();
        
        // Get current total borrowed value (in USD)
        // uint256 totalBorrowedValue = _getDebt();
        
        // Get the Prime Debt ratio (e.g., 2 PRIME per 100 USD borrowed per year)
        uint256 primeDebtRatio = tokenManager.tieredPrimeDebtRatio(DiamondStorageLib.getPrimeLeverageTier());
        
        // Calculate accrued Prime Debt since last snapshot
        /// @dev accrued Prime Debt is calculated as:
        /// (totalBorrowedValue * primeDebtRatio * timeElapsed) / (100 * 365 days)
        /// where: primeDebtRatio is expressed in 18 decimal precision, explicitly divided by 100 for clarity on ratio being per 100 USD borrowed
        /// and timeElapsed is in seconds, so we divide by 365 days to get annual debt accrual
        uint256 accruedPrimeDebt = (totalBorrowedValue * primeDebtRatio * timeElapsed) / (100 * 365 days* 10 ** 18);
        
        // Return total Prime Debt (recorded + accrued)
        return recordedPrimeDebt + accruedPrimeDebt;
    }


    /// @dev validates whether the loan has enough PRIME staked for the current leverage tier, stakes or unstakes accordingly
    /// @param _maxBorrowableValue The maximum value that can be borrowed
    /// @param primeAvailableBalance The available balance of PRIME tokens
    /// @dev primeAvailableBalance is fetched in AssetsOperationsFacet and passed in as a parameter in this library function
    /// @dev warning: primeAvailableBalance should always be == _getAvailableBalance("PRIME") 
    function validateAndUpdateStakedPrime(uint256 _maxBorrowableValue, uint256 primeAvailableBalance) internal {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        uint256 primeStakingRatio = tokenManager.tieredPrimeStakingRatio(DiamondStorageLib.getPrimeLeverageTier());
        uint256 requiredPrimeStakeAmount = _maxBorrowableValue * primeStakingRatio / (100 * 10 **18);
        uint256 stakedPrimeAmount = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        if (stakedPrimeAmount == requiredPrimeStakeAmount) return;
    
        stakedPrimeAmount < requiredPrimeStakeAmount 
            ? stakePrime(primeTokenAddress, requiredPrimeStakeAmount - stakedPrimeAmount, primeAvailableBalance)
            : unstakePrime(primeTokenAddress, stakedPrimeAmount - requiredPrimeStakeAmount);
    
    }

    /**
     * @dev Stakes additional PRIME tokens (without changing tier)
     * @param primeTokenAddress Address of the PRIME token contract
     * @param amount Amount of PRIME to stake
     */
    function stakePrime(address primeTokenAddress, uint256 amount, uint256 primeAvailableBalance) internal {
        require(amount > 0, "Amount must be > 0");
        
        require(primeAvailableBalance >= amount, "Insufficient PRIME balance");

        uint256 currentStaked = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        
        DiamondStorageLib.addStakedTokenAmount(primeTokenAddress,amount);
        
        emit PrimeStaked(msg.sender, amount, currentStaked + amount, block.timestamp);
    }

    /**
     * @dev Unstakes PRIME tokens (if requirements are still met)
     * @param primeTokenAddress Address of the PRIME token contract
     * @param amount Amount of PRIME to unstake
     */
    function unstakePrime(address primeTokenAddress, uint256 amount) internal {
        require(amount > 0, "Amount must be > 0");
       
        uint256 currentStaked = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        require(amount <= currentStaked, "Insufficient staked amount");

        uint256 remainingStake = currentStaked - amount;
        DiamondStorageLib.removeStakedTokenAmount(primeTokenAddress, amount);
        
        emit PrimeUnstaked(msg.sender, amount, remainingStake, block.timestamp);
    }


    /// Events

    /**
     * @dev Emitted when PRIME tokens are staked
     * @param user The user who staked
     * @param amount The amount staked
     * @param totalStaked The total amount staked after this operation
     * @param timestamp When the staking occurred
     */
    event PrimeStaked(
        address indexed user, 
        uint256 amount, 
        uint256 totalStaked, 
        uint256 timestamp
    );

     /**
     * @dev Emitted when PRIME tokens are unstaked
     * @param user The user who unstaked
     * @param amount The amount unstaked
     * @param totalStaked The total amount staked after this operation
     * @param timestamp When the unstaking occurred
     */
    event PrimeUnstaked(
        address indexed user, 
        uint256 amount, 
        uint256 totalStaked, 
        uint256 timestamp
    );

    
}