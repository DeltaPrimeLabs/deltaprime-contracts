// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "../../../../contracts/facets/SmartLoanViewFacet.sol";

/// @dev ViewFacetV2 — used exclusively by OwnershipUpgrade.t.sol (SP4.3) to pin
///      the "beacon upgrade propagates to ALL existing proxy accounts" invariant.
///
///      Inherits SmartLoanViewFacet verbatim and appends a sentinel viewVersion()
///      function so that a Replace+Add diamondCut can be verified on every
///      pre-existing loan without any per-loan action.
///
///      Size note: total bytecode exceeds EIP-170 (>24 KB) due to the inherited
///      facet chain. NEVER deploy with `new`. Always etch:
///          address t = makeAddr("viewFacetV2");
///          vm.etch(t, type(ViewFacetV2).runtimeCode);
///      The contract is stateless (no constructor, no immutables), so runtimeCode
///      etch is safe.
contract ViewFacetV2 is SmartLoanViewFacet {
    /// @notice Sentinel: returns the facet generation number (always 2).
    ///         Called from tests to confirm both pre-existing loan proxies route
    ///         to the upgraded facet after a diamondCut Replace+Add operation.
    function viewVersion() external pure returns (uint256) {
        return 2;
    }
}
