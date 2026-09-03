// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 3f18be6969cfcf20cc641b51da287b780b070a86;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";

import "../../ReentrancyGuardKeccak.sol";
import "../../lib/DiamondMethodsAccess.sol";
import "../../interfaces/facets/avalanche/IYieldYak.sol";
import "../../PrimeAccountModifiers.sol";

import {DiamondStorageLib} from "../../lib/DiamondStorageLib.sol";
import "../../interfaces/IWrappedNativeToken.sol";

//This path is updated during deployment
import "../../lib/DeploymentConstants.sol";

contract YieldYakFacet is ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers {
    using TransferHelper for address payable;
    using TransferHelper for address;

    // Staking Vaults tokens
    address private constant YY_GLP = 0x9f637540149f922145c06e1aa3f38dcDc32Aff5C;

    // Tokens
    address private constant GLP_TOKEN = 0x9e295B5B976a184B14aD8cd72413aD846C299660;
    // Older version of stakedGLP token (without decimals() that YieldYak uses
    address private constant sGLP_TOKEN = 0x5643F4b25E36478eE1E90418d5343cb6591BcB9d;


    // ----- STAKE -----

    /**
       * Stakes GLP in Yield Yak protocol
       * @dev This function uses the redstone-evm-connector
       * @param amount amount of GLP to be staked
    **/
    function stakeGLPYak(uint256 amount) public onlyOwner nonReentrant remainsSolvent {
        // Extra approve for the stakedGLP contract that is being used to transfer fsGLP
        sGLP_TOKEN.safeApprove(YY_GLP, 0);
        sGLP_TOKEN.safeApprove(YY_GLP, amount);
        _stakeTokenYY(IYieldYak.YYStakingDetails({
        tokenAddress: GLP_TOKEN,
        vaultAddress: YY_GLP,
        tokenSymbol: "GLP",
        vaultTokenSymbol: "YY_GLP",
        amount: amount
        }));

        // revoke unused approval
        sGLP_TOKEN.safeApprove(YY_GLP, 0);
    }

    // ----- UNSTAKE -----

    /**
    * Unstakes GLP from Yield Yak protocol
    * @dev This function uses the redstone-evm-connector
        * @param amount amount of GLP to be unstaked
    **/
    function unstakeGLPYak(uint256 amount) public onlyOwnerOrLiquidation nonReentrant {
        _unstakeTokenYY(IYieldYak.YYStakingDetails({
        tokenAddress: GLP_TOKEN,
        vaultAddress: YY_GLP,
        tokenSymbol: "GLP",
        vaultTokenSymbol: "YY_GLP",
        amount: amount
        }));
    }

    // ----- PRIVATE METHODS -----

    /**
      * Stakes {stakingDetails.tokenAddress} token in the YieldYak protocol
      * @dev This function uses the redstone-evm-connector
      * @param stakingDetails IYieldYak.YYStakingDetails staking details
    **/
    function _stakeTokenYY(IYieldYak.YYStakingDetails memory stakingDetails) noBorrowInTheSameBlock notInLiquidation private {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        IERC20Metadata yrtToken = IERC20Metadata(stakingDetails.vaultAddress);
        uint256 initialYRTBalance = yrtToken.balanceOf(address(this));

        stakingDetails.amount = Math.min(_getAvailableBalance(stakingDetails.tokenSymbol), stakingDetails.amount);
        require(stakingDetails.amount > 0, "Cannot stake 0 tokens");

        // _ACTIVE = 2
        require(tokenManager.tokenToStatus(stakingDetails.tokenAddress) == 2, "Token not supported");
        require(tokenManager.tokenToStatus(stakingDetails.vaultAddress) == 2, "Vault token not supported");

        stakingDetails.tokenAddress.safeApprove(stakingDetails.vaultAddress, 0);
        stakingDetails.tokenAddress.safeApprove(stakingDetails.vaultAddress, stakingDetails.amount);
        IYieldYak(stakingDetails.vaultAddress).deposit(stakingDetails.amount);

        uint256 yrtTokenReceived = yrtToken.balanceOf(address(this)) - initialYRTBalance;
        _syncExposure(tokenManager, stakingDetails.vaultAddress);
        _syncExposure(tokenManager, stakingDetails.tokenAddress);

        // revoke unused approval
        stakingDetails.tokenAddress.safeApprove(stakingDetails.vaultAddress, 0);

        emit Staked(
            msg.sender,
            stakingDetails.tokenSymbol,
            stakingDetails.vaultAddress,
            stakingDetails.amount,
            yrtTokenReceived,
            block.timestamp);
    }

    /**
      * Unstakes {stakingDetails.tokenAddress} token in the YieldYak protocol
      * @dev This function uses the redstone-evm-connector
      * @param stakingDetails IYieldYak.YYStakingDetails staking details
    **/
    function _unstakeTokenYY(IYieldYak.YYStakingDetails memory stakingDetails) noBorrowInTheSameBlock private {
        IYieldYak vaultContract = IYieldYak(stakingDetails.vaultAddress);
        IERC20Metadata depositToken = IERC20Metadata(stakingDetails.tokenAddress);
        uint256 initialDepositTokenBalance = depositToken.balanceOf(address(this));
        stakingDetails.amount = Math.min(_getAvailableBalance(stakingDetails.vaultTokenSymbol), stakingDetails.amount);

        require(stakingDetails.amount > 0, "Insufficient balance");

        vaultContract.withdraw(stakingDetails.amount);

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        uint256 depositTokenReceived = depositToken.balanceOf(address(this)) - initialDepositTokenBalance;
        _syncExposure(tokenManager, stakingDetails.tokenAddress);
        _syncExposure(tokenManager, stakingDetails.vaultAddress);

        emit Unstaked(
            msg.sender,
            stakingDetails.tokenSymbol,
            stakingDetails.vaultAddress,
            depositToken.balanceOf(address(this)) - initialDepositTokenBalance,
            stakingDetails.amount,
            block.timestamp);
    }


    /* ========== RECEIVE AVAX FUNCTION ========== */
    receive() external payable {}

    /**
        * @dev emitted when user stakes an asset
        * @param user the address executing staking
        * @param asset the asset that was staked
        * @param vault address of the vault token
        * @param depositTokenAmount how much of deposit token was staked
        * @param receiptTokenAmount how much of receipt token was received
        * @param timestamp of staking
    **/
    event Staked(address indexed user, bytes32 indexed asset, address indexed vault, uint256 depositTokenAmount, uint256 receiptTokenAmount, uint256 timestamp);

    /**
        * @dev emitted when user unstakes an asset
        * @param user the address executing unstaking
        * @param vault address of the vault token
        * @param asset the asset that was unstaked
        * @param depositTokenAmount how much deposit token was received
        * @param receiptTokenAmount how much receipt token was unstaked
        * @param timestamp of unstaking
    **/
    event Unstaked(address indexed user, bytes32 indexed asset, address indexed vault, uint256 depositTokenAmount, uint256 receiptTokenAmount, uint256 timestamp);
}