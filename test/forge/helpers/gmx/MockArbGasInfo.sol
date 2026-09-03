// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

/**
 * @title MockArbGasInfo
 * @notice Minimal stand-in for the Arbitrum `ArbGasInfo` precompile (0x6C), etched onto
 *         that address by {GmxKeeperSim.etchPrecompiles} on a fork.
 *
 * During keeper execution GMX reimburses the keeper's L1 calldata gas, which it reads
 * via `ArbGasInfo.getCurrentTxL1GasFees()`. On a Foundry fork the precompile has no
 * bytecode, so the call reverts and execution dies. Returning 0 makes the L1-fee
 * reimbursement a no-op, which is exactly what we want in the simulation (we are not
 * measuring keeper economics here).
 */
contract MockArbGasInfo {
    /// @dev Report zero L1 gas fees so keeper fee-reimbursement is a no-op.
    function getCurrentTxL1GasFees() external pure returns (uint256) {
        return 0;
    }
}
