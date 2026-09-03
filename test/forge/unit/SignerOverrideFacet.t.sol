// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {SolvencyFacetTestAvalanche} from "../helpers/facets/SolvencyFacetTestAvalanche.sol";

contract SignerOverrideFacetTest is Test {
    SolvencyFacetTestAvalanche facet;

    function setUp() public {
        // SolvencyFacetTestAvalanche is >24KB (prod facet ~24,538B + override).
        // Deploy via vm.etch to bypass EIP-170 enforcement in test environments
        // and avoid linking issues that `new` may trigger for library-heavy facets.
        address target = makeAddr("solvencyFacetTest");
        vm.etch(target, type(SolvencyFacetTestAvalanche).runtimeCode);
        facet = SolvencyFacetTestAvalanche(target);
    }

    /// All 5 test signers must be mapped to their correct indices 0-4.
    function testTestSignersAuthorised() public {
        address[5] memory s = RedstoneLib.signerAddresses(vm);
        for (uint8 i; i < 5; i++) {
            assertEq(facet.getAuthorisedSignerIndex(s[i]), i);
        }
    }

    /// A real RedStone primary-prod signer must NOT be authorised in the test facet.
    /// This is the inversion: the prod signer set is swapped out for the test set.
    function testRealRedstoneSignerNowRejected() public {
        // 0x8BB8F32D... is index 0 in PrimaryProdDataServiceConsumerBase (prod signer)
        vm.expectRevert(); // SignerNotAuthorised(address)
        facet.getAuthorisedSignerIndex(0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774);
    }

    /// Threshold and timestamp validation are inherited unchanged from the prod facet.
    function testThresholdAndTimestampLogicUntouched() public {
        // Threshold must still be 3 (same as prod)
        assertEq(facet.getUniqueSignersThreshold(), 3);

        // Timestamp validation: 4 minutes stale must revert (prod rule: >180s stale)
        vm.warp(1_750_000_000);
        vm.expectRevert();
        facet.validateTimestamp((block.timestamp - 240) * 1000);

        // A fresh (current) timestamp must pass
        facet.validateTimestamp(block.timestamp * 1000);
    }
}
