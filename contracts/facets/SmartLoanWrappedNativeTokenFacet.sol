// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 56b7ba6f74e4dd5f903aad49110b5db8a353f45f;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../interfaces/IWrappedNativeToken.sol";
import "../lib/DiamondMethodsAccess.sol";
import "../PrimeAccountModifiers.sol";
import "../ReentrancyGuardKeccak.sol";

//This path is updated during deployment
import "../lib/DeploymentConstants.sol";

contract SmartLoanWrappedNativeTokenFacet is DiamondMethodsAccess, PrimeAccountModifiers, ReentrancyGuardKeccak {
    using TransferHelper for address payable;

    function wrapNativeToken(uint256 amount) onlyOwnerOrLiquidation nonReentrant public {
        require(amount <= address(this).balance, "Not enough native token to wrap");
        require(amount > 0, "Cannot wrap 0 tokens");
        IWrappedNativeToken wrapped = IWrappedNativeToken(DeploymentConstants.getNativeToken());
        wrapped.deposit{value : amount}();

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        _syncExposure(tokenManager, address(wrapped));

        emit WrapNative(msg.sender, amount, block.timestamp);
    }

    function depositNativeToken() public payable virtual onlyOwner {
        IWrappedNativeToken wrapped = IWrappedNativeToken(DeploymentConstants.getNativeToken());
        wrapped.deposit{value : msg.value}();

        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        _syncExposure(tokenManager, address(wrapped));

        emit DepositNative(msg.sender, msg.value, block.timestamp);
    }


    /* ========== EVENTS ========== */

    /**
    * @dev emitted when native tokens are wrapped in the SmartLoan
    * @param user the address initiating wrap
    * @param amount of wrapped funds
    * @param timestamp of wrap
    **/
    event WrapNative(address indexed user, uint256 amount, uint256 timestamp);

    /**
    * @dev emitted when native tokens are deposited to the SmartLoan
    * @param user the address initiating deposit of native token
    * @param amount of deposited funds
    * @param timestamp of deposit
    **/
    event DepositNative(address indexed user, uint256 amount, uint256 timestamp);

    /**
    * @dev emitted when native tokens are unwrapped and withdrawn from the SmartLoan
    * @param user the address initiating unwrap and withdraw of native token
    * @param amount of unwrapped and withdrawn funds
    * @param timestamp of unwrap and withdraw
    **/
    event UnwrapAndWithdraw(address indexed user, uint256 amount, uint256 timestamp);

}