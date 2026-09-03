// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

/**
 * @title MockArbSys
 * @notice Minimal stand-in for the Arbitrum `ArbSys` precompile (0x64), etched onto
 *         that address by {GmxKeeperSim.etchPrecompiles} on a fork.
 *
 * GMX V2 internals read `ArbSys.arbBlockNumber()` (and occasionally `arbBlockHash`)
 * for L2 block bookkeeping during keeper execution. On a Foundry fork the precompile
 * has no bytecode, so any call reverts and execution dies. This stub maps the
 * Arbitrum block-number/hash semantics back onto the EVM globals Foundry DOES expose
 * (`block.number` / `blockhash`), which is sufficient for the keeper-sim path.
 */
contract MockArbSys {
    /// @dev Arbitrum returns the L2 block number; on a fork we just return block.number.
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }

    /// @dev Arbitrum returns the L2 block hash; map onto the EVM blockhash opcode.
    function arbBlockHash(uint256 n) external view returns (bytes32) {
        return blockhash(n);
    }
}
