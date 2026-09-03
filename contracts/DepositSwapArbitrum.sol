// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "./abstract/DepositSwapBase.sol";

contract DepositSwapArbitrum is DepositSwapBase {
    /**
     * @notice Initialize the contract
     * @param _initialSlippageThreshold Initial slippage threshold in USD (18 decimals)
     */
    function initialize(
        uint256 _initialSlippageThreshold
    ) external initializer {
        __DepositSwapBase_init(_initialSlippageThreshold);
    }
}
