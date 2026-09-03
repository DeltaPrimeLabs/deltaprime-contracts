// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "@redstone-finance/evm-connector/contracts/core/RedstoneConsumerNumericBase.sol";
import {TestAuthorisedSigners} from "./TestAuthorisedSigners.sol";

/// Minimal harness: REAL 0.9.0 parsing/aggregation/timestamp code, test signers, prod threshold.
/// Signer addresses derived from keys: keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i)))
/// for i in 0..4. Verified via cast: i=0 key=0xeb514472... addr=0x8F0406...
/// The if-chain lives in TestAuthorisedSigners (single source of truth shared with
/// SolvencyFacetTestAvalanche).
contract TestRedstoneConsumer is RedstoneConsumerNumericBase, TestAuthorisedSigners {
    function getDataServiceId() public view virtual override returns (string memory) {
        return "redstone-primary-prod";
    }

    function getUniqueSignersThreshold() public view virtual override returns (uint8) {
        return 3;
    }

    function getAuthorisedSignerIndex(address signerAddress) public view virtual override returns (uint8) {
        return _testSignerIndex(signerAddress);
    }

    function extractValues(bytes32[] memory feeds) external view returns (uint256[] memory) {
        return getOracleNumericValuesFromTxMsg(feeds);
    }

    function extractValuesWithDuplicates(bytes32[] memory feeds) external view returns (uint256[] memory) {
        return getOracleNumericValuesWithDuplicatesFromTxMsg(feeds);
    }
}
