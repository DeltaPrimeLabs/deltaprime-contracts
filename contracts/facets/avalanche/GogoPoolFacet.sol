// SPDX-License-Identifier: BUSL-1.1
// Last deployed from commit: 499a35c62f8a913d89f7faf78bf5c6b3cea2ee8b;
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/lib/contracts/libraries/TransferHelper.sol";
import "../../ReentrancyGuardKeccak.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {DiamondStorageLib} from "../../lib/DiamondStorageLib.sol";
import "../../lib/DiamondMethodsAccess.sol";
import "../../PrimeAccountModifiers.sol";
import "../../interfaces/IWrappedNativeToken.sol";
import "../../interfaces/IGgAvax.sol";

//This path is updated during deployment
import "../../lib/DeploymentConstants.sol";

contract GogoPoolFacet is ReentrancyGuardKeccak, DiamondMethodsAccess, PrimeAccountModifiers {
    using TransferHelper for address;

    address private constant GG_AVAX =
        0xA25EaF2906FA1a3a13EdAc9B9657108Af7B703e3;

    function swapToGgAvax(uint256 _amount)
        external
        nonReentrant
        onlyOwner
        noBorrowInTheSameBlock
        remainsSolvent
        notInLiquidation
    {
        IWrappedNativeToken wrapped = IWrappedNativeToken(DeploymentConstants.getNativeToken());
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();

        _amount = Math.min(_getAvailableBalance(DeploymentConstants.getNativeTokenSymbol()), _amount);
        require(_amount > 0, "Amount has to be greater than 0");

        wrapped.withdraw(_amount);

        uint256 initialGgAvaxBalance = IERC20(GG_AVAX).balanceOf(address(this));

        IGgAvax ggAvax = IGgAvax(GG_AVAX);
        ggAvax.depositAVAX{value: _amount}();

        _syncExposure(tokenManager, GG_AVAX);
        _syncExposure(tokenManager, address(wrapped));
    }

    function swapFromGgAvaxToWavax(uint256 _amount, uint256 _minAvaxOut)
        external
        nonReentrant
        noBorrowInTheSameBlock
        onlyOwnerOrLiquidation
        
    {
        ITokenManager tokenManager = DeploymentConstants.getTokenManager();
        IWrappedNativeToken wrapped = IWrappedNativeToken(DeploymentConstants.getNativeToken());

        _amount = Math.min(_getAvailableBalance(bytes32("ggAVAX")), _amount);
        require(_amount > 0, "Amount has to be greater than 0");
        uint256 initialNativeBalance = address(this).balance;

        IGgAvax ggAvax = IGgAvax(GG_AVAX);
        uint256 redeemedAVAX = ggAvax.redeemAVAX(_amount);

        uint256 finalNativeBalance = address(this).balance;
        require(finalNativeBalance - initialNativeBalance >= _minAvaxOut, "Balance received is less than desired");
        require(redeemedAVAX >= _minAvaxOut, "redeemedAVAX is less than minAvaxOut");


        wrapped.deposit{value: redeemedAVAX}();

        _syncExposure(tokenManager, GG_AVAX);
        _syncExposure(tokenManager, address(wrapped));
    }

    /* ========== RECEIVE AVAX FUNCTION ========== */
    receive() external payable {}
}
