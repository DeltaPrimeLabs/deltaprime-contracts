// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";

contract CreateLoanFundTest is DeltaPrimeFixture {
    /// @notice Create a loan as a borrower; verify registry and owner are set correctly.
    function testCreateLoanRegistersAccount() public {
        address borrower = makeAddr("borrower");
        vm.prank(borrower);
        factory.createLoan();
        address loan = factory.getLoanForOwner(borrower);
        assertTrue(loan != address(0), "loan address must be non-zero");
        assertEq(SmartLoanViewFacet(loan).getContractOwner(), borrower, "loan owner must be borrower");
    }

    /// @notice Fund a loan with 100 AVAX; verify the proxy holds wAVAX and lists it as owned.
    function testFundAvaxCollateral() public {
        (address borrower, address loan) = _createLoanFor("borrower");
        _fundAvax(borrower, loan, 100e18);
        assertEq(SmartLoanViewFacet(loan).getBalance(NATIVE_SYMBOL), 100e18, "wAVAX balance must equal funded amount");
        bytes32[] memory owned = SmartLoanViewFacet(loan).getAllOwnedAssets();
        assertEq(owned.length, 1, "exactly one owned asset after fund");
        assertEq(owned[0], NATIVE_SYMBOL, "owned asset must be AVAX");
    }
}
