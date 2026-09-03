// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "../lib/DiamondStorageLib.sol";
import "../lib/LeverageTierLib.sol";
import "../interfaces/facets/IPrimeLeverageFacet.sol";
import "../interfaces/ITokenManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../ReentrancyGuardKeccak.sol";
import "../lib/DiamondMethodsAccess.sol";
import "../PrimeAccountModifiers.sol";

//this path is updated during deployment
import "../lib/DeploymentConstants.sol";

contract PrimeLeverageFacet is  IPrimeLeverageFacet,ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers {
    
    using TransferHelper for address;

    // for token burning
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;


    ///@dev clone of IAssetsOperationsFacet.Fund event
    event Funded(address indexed user, bytes32 indexed asset, uint256 amount, uint256 timestamp);
        
    
    /**
    * @notice A modified version of fund() method in AssetsOperationsFacet as a workaround for PRIME price feeds.
    * Funds the loan with a specified amount of a defined token
    * @dev Requires approval for ERC20 token on frontend side
    * @param _amount to be funded
    **/
    function depositPrime( uint256 _amount) public virtual onlyOwner noBorrowInTheSameBlock  nonReentrant remainsSolvent {

        require(_amount > 0, "Amount must be > 0 to deposit PRIME");
        IERC20Metadata token = getERC20TokenInstance(bytes32("PRIME"), true);
        _amount = Math.min(_amount, token.balanceOf(msg.sender));

        address(token).safeTransferFrom(msg.sender, address(this), _amount);

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        syncExposureOfPrime(tokenManager, address(token));

        emit Funded(msg.sender, bytes32("PRIME"), _amount, block.timestamp);
    }
    
    
    function activatePremium() private  {
        require(DiamondStorageLib.getPrimeLeverageTier() != LeverageTierLib.LeverageTier.PREMIUM, "Already in premium tier");
        // Update storage
        DiamondStorageLib.setPrimeLeverageTier(LeverageTierLib.LeverageTier.PREMIUM);
       
        LeverageTierLib.updatePrimeDebtSnapshot(_getDebt());
        
        emit LeverageTierChanged(msg.sender, LeverageTierLib.LeverageTier.BASIC, LeverageTierLib.LeverageTier.PREMIUM, block.timestamp);
    }   
    
    /**
     * @dev Activates PREMIUM tier (10x leverage mode) for the user
     */
    // notInLiquidation: without it a BASIC-tier owner could flip to PREMIUM
    // inside the 15-minute liquidation window and halve the liquidation fee (140 -> 70 bps
    // of initial debt), diverting the difference from the stability pool and treasury.
    // PREMIUM activation is meant to be a deliberate choice made while the account is
    // healthy; ~25 other owner state-changing entry points already carry this guard.
    function stakePrimeAndActivatePremium() external onlyOwner nonReentrant notInLiquidation {
        uint256 totalCollateral = _getTotalValue() - _getDebt();
        uint256 requiredMaxStake = getRequiredPrimeStake(LeverageTierLib.LeverageTier.PREMIUM, totalCollateral * 10); // 10x max debt
        stakePrime(requiredMaxStake);
        DiamondStorageLib.setLastPrimeDebtUpdate(block.timestamp);
        activatePremium();
    }
    
    /**
     * @dev Deactivates PREMIUM tier back to BASIC tier
     * @param withdrawStake Whether to withdraw excess staked PRIME
     */
    // notInLiquidation is for consistency with stakePrimeAndActivatePremium; that direction
    // only ever raises the fee, so it is hygiene rather than a fix.
    //
    // remainsSolvent is load-bearing. Downgrading does two things that cut the
    // account's threshold-weighted value in one transaction: it drops tieredDebtCoverage from
    // the PREMIUM value to the BASIC one across every asset, and, with withdrawStake, releases
    // excess staked PRIME. repayPrimeDebt below settles only the PRIME staking debt, not the
    // account's pool debt, so a leveraged account kept its full borrow position while its
    // coverage fell — letting an owner drive themselves from solvent to insolvent in one call.
    // There is no attacker profit (the value stays in the account and it is simply liquidated),
    // but a downgrade from the top of the PREMIUM band could land far enough under the
    // threshold that liquidation does not recover it, which is depositor bad debt. The owner
    // must now deleverage first and then downgrade.
    function deactivatePremiumTier(bool withdrawStake) external onlyOwner nonReentrant remainsSolvent notInLiquidation {
        require(DiamondStorageLib.getPrimeLeverageTier() != LeverageTierLib.LeverageTier.BASIC, "Already in BASIC tier");

        /// @dev gets the current debt, tries to repay it fully before deactivating
        /// if full repayment is not possible, it will revert
        uint256 totalDebt = _getDebt();
        uint256 currentDebt = LeverageTierLib.getCurrentPrimeDebt(totalDebt);
        repayPrimeDebt(currentDebt); // Repay all PRIME debt before downgrading
        
        
        

        LeverageTierLib.LeverageTier oldTier = DiamondStorageLib.getPrimeLeverageTier();
        DiamondStorageLib.setPrimeLeverageTier(LeverageTierLib.LeverageTier.BASIC);
        
        // Withdraw excess staked PRIME if requested
        if (withdrawStake) {
            ITokenManager tokenManager = DeploymentConstants.getTokenManager();
            address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
            uint256 currentStaked = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
            uint256 newRequiredStake = getRequiredPrimeStake(LeverageTierLib.LeverageTier.BASIC, _getDebt());
            
            if (currentStaked > newRequiredStake) {
                uint256 excessStake = currentStaked - newRequiredStake;
                DiamondStorageLib.removeStakedTokenAmount(primeTokenAddress, excessStake);
                
                
                emit PrimeUnstaked(msg.sender, excessStake, newRequiredStake, block.timestamp);
            }
        }
        
        emit LeverageTierChanged(msg.sender, oldTier, LeverageTierLib.LeverageTier.BASIC, block.timestamp);
    }
    
    /**
     * @dev Stakes additional PRIME tokens (without changing tier)
     * @param amount Amount of PRIME to stake
     */
    function stakePrime(uint256 amount) private {
        require(amount > 0, "Amount must be > 0");
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        
        require(_getAvailableBalance("PRIME") >= amount, "Insufficient PRIME balance");

        uint256 currentStaked = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        
        DiamondStorageLib.addStakedTokenAmount(primeTokenAddress,amount);
        
        emit PrimeStaked(msg.sender, amount, currentStaked + amount, block.timestamp);
    }

    function getPrimeStakedAmount() external view returns (uint256) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        // Return the staked amount of PRIME tokens
        return DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        
    }
    
    /**
     * @dev Unstakes PRIME tokens (if requirements are still met)
     * @param amount Amount of PRIME to unstake
     */
    function unstakePrime(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be > 0");
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        
        uint256 currentStaked = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        require(amount <= currentStaked, "Insufficient staked amount");
        
        uint256 borrowedValue = _getDebt();
        uint256 remainingStake = currentStaked - amount;

        if (getLeverageTier() != LeverageTierLib.LeverageTier.BASIC) {
            uint256 primeStakingRatio = tokenManager.tieredPrimeStakingRatio(LeverageTierLib.LeverageTier.PREMIUM);
            uint256 requiredPrimeStakeAmount = borrowedValue * primeStakingRatio / (100 * 10 ** 18);
            require(remainingStake >= requiredPrimeStakeAmount, "Would fall below minimum stake requirement for PREMIUM tier");
        }

        // A PREMIUM account with accrued PRIME debt must keep enough staked PRIME to cover
        // that debt, otherwise an unstake could leave the protocol with a PRIME-debt that
        // exceeds available stake even though the USD-denominated stake ratio is satisfied.
        // Settle accrued-but-unsnapshotted debt into recordedPrimeDebt first; reading
        // DiamondStorageLib.getPrimeDebt() directly would let a user time their unstake to
        // bypass the check while accrual sits outside the recorded value.
        LeverageTierLib.updatePrimeDebtSnapshot(borrowedValue);
        uint256 currentPrimeDebt = LeverageTierLib.getCurrentPrimeDebt(borrowedValue);
        require(remainingStake >= currentPrimeDebt, "Would fall below accrued PRIME debt");
        
        
        DiamondStorageLib.removeStakedTokenAmount(primeTokenAddress, amount);
        
        emit PrimeUnstaked(msg.sender, amount, remainingStake, block.timestamp);
    }
    
    /**
     * @dev Updates the recorded Prime debt with accrued amount
     */
    function updatePrimeDebt() public {
        uint256 totalDebt = _getDebt();
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);        
    }

     /**
    * @notice A modified version of _syncExposure() method in DiamondMethodsAccess which doesn't 
    * add PRIME as an owned asset for solvency calculations.
    * @param tokenManager tokenManager instance
    * @param _token to be funded
    **/
    function syncExposureOfPrime(ITokenManager tokenManager, address _token) internal virtual {
        // Tell TokenManager to update the exposure based on current on-chain balance.
        tokenManager.updateUserExposure(address(this), _token);
    }

    
    /**
     * @dev Repays Prime debt using PRIME tokens
     * @param amount Amount of PRIME to use for debt repayment
     */
    function repayPrimeDebt(uint256 amount) public onlyOwner {
        require(amount > 0, "Amount must be > 0");
        uint256 totalDebt = _getDebt();
        LeverageTierLib.updatePrimeDebtSnapshot(totalDebt);
        uint256 currentDebt = LeverageTierLib.getCurrentPrimeDebt(totalDebt);
        require(currentDebt > 0, "No debt to repay");
        require(_getAvailableBalance("PRIME") >= amount, "Not enough PRIME to repay the debt");
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        // to ensure no overpayment of debt, cap the amount to current debt if user tries to repay more than owed
        amount = Math.min(amount, currentDebt);
        
        
        // Split: 50% burn, 50% to treasury
        uint256 burnAmount = amount / 2;
        uint256 treasuryAmount = amount - burnAmount;


        primeTokenAddress.safeTransfer(BURN_ADDRESS, burnAmount);
        
       
        address treasuryAddress = DeploymentConstants.getTreasuryAddress();
        primeTokenAddress.safeTransfer(treasuryAddress, treasuryAmount);
        
        // Update debt (need to update the recorded debt, not just subtract from current)
        uint256 recordedDebt = DiamondStorageLib.getPrimeDebt();
        DiamondStorageLib.setPrimeDebt(recordedDebt > amount ? recordedDebt - amount : 0);

        uint256 currentDebtAfter = LeverageTierLib.getCurrentPrimeDebt(totalDebt);
        
        emit PrimeDebtRepaid(msg.sender, amount, currentDebtAfter, block.timestamp);
    }
    
    
    
    /**
     * @notice Returns required Prime stake for a specific tier and borrowed amount
     */
    function getRequiredPrimeStake(LeverageTierLib.LeverageTier tier, uint256 borrowedValue) public view returns (uint256) {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256 tierStakingRatio = tokenManager.tieredPrimeStakingRatio(tier);
        return (borrowedValue * tierStakingRatio) / (100 * 10 ** 18); // tierStakingRatio is per $100 borrowed
    }

    

    
    /**
     * @notice Returns current leverage tier
     */
    function getLeverageTier() public view returns (LeverageTierLib.LeverageTier) {
        return DiamondStorageLib.getPrimeLeverageTier();
    }
    
    /**
     * @notice Returns leverage tier information for UI display
     */
    function getLeverageTierFullInfo() public view returns (
        LeverageTierLib.LeverageTier currentTier,
        uint256 stakedPrime,
        uint256 recordedDebt
    ) {
        currentTier = DiamondStorageLib.getPrimeLeverageTier();
        stakedPrime = DiamondStorageLib.getStakedTokenAmount(DeploymentConstants.getTokenManager().getAssetAddress("PRIME", true));
        recordedDebt = DiamondStorageLib.getPrimeDebt();
    }
    
    /**
     * @notice Checks if Prime liquidation should trigger
     */
    function shouldLiquidatePrimeDebt() public returns (bool) {
        LeverageTierLib.LeverageTier currentTier = DiamondStorageLib.getPrimeLeverageTier();
        uint256 totalBorrowedValue = _getDebt();
        
        LeverageTierLib.updatePrimeDebtSnapshot(totalBorrowedValue);
    
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256 stakedPrime = DiamondStorageLib.getStakedTokenAmount(tokenManager.getAssetAddress("PRIME", true));

        
        // Get current total borrowed value (in USD)
        
        // Get the Prime Debt ratio (e.g., 2 PRIME per 100 USD borrowed per year)
        uint256 primeDebtRatio = tokenManager.tieredPrimeDebtRatio(currentTier);
        
        // Calculate weekly accrual at current borrow level
        /// @dev primeDebtRatio is in 18-decimal precision, must divide by 10**18 to normalize (matches LeverageTierLib.sol:L55)
        uint256 weeklyAccrualAtCurrentBorrow = (totalBorrowedValue * primeDebtRatio * 7 days) / (100 * 365 days * 10 ** 18);

        uint256 primeDebt = DiamondStorageLib.getPrimeDebt();

        
        ///@dev rather than simply checking primeDebt > stakedPrime, the user gets a buffer of further accrual of another week
        ///@dev so could try and borrow more which would inherently trigger further staking from the PRIME balance
        /// @dev equivalent to (primeDebt - weeklyAccrualAtCurrentBorrow > stakedPrime), but done this way to avoid underflow issues.
        if (primeDebt > weeklyAccrualAtCurrentBorrow + stakedPrime) {
            return true;
        }

        return false;
        
    }
    
    /**
     * @dev Emergency liquidation of Prime debt (only callable by whitelisted liquidators)
     */
    function liquidatePrimeDebt() external onlyWhitelistedLiquidators nonReentrant {
        require(shouldLiquidatePrimeDebt(), "Prime liquidation not triggered");
        
        
        ///@dev there shouldn't be any accrued debt at this point, since the require check should have triggered 
        ///@dev _updatePrimeDebtSnapshot();
        uint256 primeDebt = DiamondStorageLib.getPrimeDebt(); 
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        address primeTokenAddress = tokenManager.getAssetAddress("PRIME", true);
        uint256 stakedPrime = DiamondStorageLib.getStakedTokenAmount(primeTokenAddress);
        
        // Liquidate staked Prime to cover debt
        uint256 liquidatedAmount = primeDebt < stakedPrime ? primeDebt : stakedPrime;
        
        // Reduce Prime debt and stake
        uint256 newDebt = primeDebt > liquidatedAmount ? primeDebt - liquidatedAmount : 0;

        DiamondStorageLib.setPrimeDebt(newDebt);
        
        DiamondStorageLib.removeStakedTokenAmount(primeTokenAddress, liquidatedAmount);

        // Transfer liquidated PRIME: 50% burn, 50% to treasury
        uint256 burnAmount = liquidatedAmount / 2;
        uint256 treasuryAmount = liquidatedAmount - burnAmount;
        primeTokenAddress.safeTransfer(BURN_ADDRESS, burnAmount);
        address treasuryAddress = DeploymentConstants.getTreasuryAddress();
        primeTokenAddress.safeTransfer(treasuryAddress, treasuryAmount);

        // If remaining Prime can't cover remaining debt, force switch to BASIC
        uint256 remainingPrime = stakedPrime - liquidatedAmount;
        uint256 remainingDebt = LeverageTierLib.getCurrentPrimeDebt(_getDebt());
        if (remainingDebt > remainingPrime) {
            LeverageTierLib.LeverageTier oldTier = DiamondStorageLib.getPrimeLeverageTier();
            DiamondStorageLib.setPrimeLeverageTier(LeverageTierLib.LeverageTier.BASIC);
            emit LeverageTierChanged(address(this), oldTier, LeverageTierLib.LeverageTier.BASIC, block.timestamp);
        }
        
        emit PrimeLiquidated(address(this), liquidatedAmount, block.timestamp);
    }
}