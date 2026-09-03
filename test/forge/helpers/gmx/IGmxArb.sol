// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

/**
 * Minimal GMX V2 (Arbitrum) interfaces + structs for the keeper-simulation fork
 * harness. Struct layouts copied EXACTLY from the live gmx-synthetics v2.2 source
 * (verified on Arbiscan, chainid 42161) — `ValidatedPrice` field order is
 * `token,min,max,timestamp,provider`; `SetPricesParams` is `tokens,providers,data`.
 *
 * See docs/forge/gmx-arbitrum-recon.md for the live address set + mechanics.
 */

interface IRoleStore {
    function getRoleMembers(bytes32 roleKey, uint256 start, uint256 end)
        external
        view
        returns (address[] memory);

    function hasRole(address account, bytes32 roleKey) external view returns (bool);
}

interface IGmxDataStore {
    function getAddress(bytes32 key) external view returns (address);
}

library OracleUtils {
    struct SetPricesParams {
        address[] tokens;
        address[] providers;
        bytes[] data;
    }

    struct ValidatedPrice {
        address token;
        uint256 min;
        uint256 max;
        uint256 timestamp;
        address provider;
    }
}

interface IChainlinkDataStreamProvider {
    function getOraclePrice(address token, bytes memory data)
        external
        view
        returns (OracleUtils.ValidatedPrice memory);

    function shouldAdjustTimestamp() external pure returns (bool);

    function isChainlinkOnChainProvider() external pure returns (bool);
}

interface IGmxOracleHolder {
    /// @dev DepositHandler / WithdrawalHandler expose the configured Oracle.
    function oracle() external view returns (address);
}

interface IDepositHandler {
    function executeDeposit(bytes32 key, OracleUtils.SetPricesParams calldata oracleParams) external;
}

interface IWithdrawalHandler {
    function executeWithdrawal(bytes32 key, OracleUtils.SetPricesParams calldata oracleParams) external;
}

interface IGlvDepositHandler {
    /// @dev GLV (GMX Liquidity Vault) deposit execution. Same SetPricesParams shape as the
    ///      normal deposit handler; gated by `onlyOrderKeeper` (verified on-fork: probing the
    ///      live handler reverts `Unauthorized(caller,"ORDER_KEEPER")`).
    function executeGlvDeposit(bytes32 key, OracleUtils.SetPricesParams calldata oracleParams) external;
}

interface IGlvWithdrawalHandler {
    function executeGlvWithdrawal(bytes32 key, OracleUtils.SetPricesParams calldata oracleParams) external;
}
