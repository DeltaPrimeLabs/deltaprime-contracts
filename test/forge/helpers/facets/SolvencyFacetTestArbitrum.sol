// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {SolvencyFacetProdArbitrum} from "../../../../contracts/facets/arbitrum/SolvencyFacetProdArbitrum.sol";
import {TestAuthorisedSigners} from "../TestAuthorisedSigners.sol";

/**
 * @title SolvencyFacetTestArbitrum
 * @notice Production Arbitrum solvency facet with ONLY the signer set swapped to the 5 DP
 *         test signers (keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i)))).
 *
 * Everything else — threshold (3), median aggregation, ±180s/+60s timestamp
 * validation, and all solvency/oracle parsing logic — is the real production code
 * (SolvencyFacetProdArbitrum == SolvencyFacetProd; both chains now consume the
 * same RedStone primary-prod node).
 *
 * Deployment note: this contract exceeds EIP-170 (24KB). Deploy it via
 * `vm.etch(target, type(SolvencyFacetTestArbitrum).runtimeCode)` in tests,
 * NOT via `new SolvencyFacetTestArbitrum()`. Forge does NOT enforce EIP-170
 * on vm.etch, so the etch succeeds even on the >24KB bytecode. (This is the
 * exact pattern SolvencyFacetTestAvalanche uses.)
 *
 * Both SolvencyFacetProdArbitrum (via PrimaryProdDataServiceConsumerBase →
 * RedstoneConsumerNumericBase → RedstoneConstants) and TestAuthorisedSigners
 * (direct import) inherit from RedstoneConstants. Solidity's C3 linearization
 * handles this diamond without conflicts — RedstoneConstants has no mutable
 * state and no virtual functions, only constants and error definitions.
 */
contract SolvencyFacetTestArbitrum is SolvencyFacetProdArbitrum, TestAuthorisedSigners {
    /**
     * @dev Override the prod signer set with the 5 deterministic test signers.
     *      Only this one function is replaced; all other consumer virtuals
     *      (getUniqueSignersThreshold, validateTimestamp, aggregateValues, etc.)
     *      remain the real production implementation.
     */
    function getAuthorisedSignerIndex(address signerAddress)
        public
        view
        virtual
        override
        returns (uint8)
    {
        return _testSignerIndex(signerAddress);
    }
}
