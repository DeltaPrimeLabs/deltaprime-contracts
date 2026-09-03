// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeploymentConstants} from "../../../contracts/lib/DeploymentConstants.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";

contract DeploymentConstantsTest is Test {
    function testActiveConfigMatchesKnownChainSet() public {
        bytes32 key = keccak256(bytes(DeploymentChainConfig.CHAIN_KEY));
        if (key == keccak256("test")) {
            // Test addresses are precomputed from keccak256("dp.test.<label>") low-order 20 bytes.
            // Cross-verified against the Solidity expression form used in earlier revisions.
            assertEq(DeploymentConstants.getNativeTokenSymbol(), bytes32("AVAX"));
            assertEq(DeploymentConstants.getNativeToken(), payable(address(uint160(uint256(keccak256("dp.test.nativeToken"))))));
            assertEq(DeploymentConstants.getDiamondAddress(), address(uint160(uint256(keccak256("dp.test.diamondBeacon")))));
            assertEq(DeploymentConstants.getSmartLoansFactoryAddress(), address(uint160(uint256(keccak256("dp.test.smartLoansFactory")))));
            assertEq(address(DeploymentConstants.getTokenManager()), address(uint160(uint256(keccak256("dp.test.tokenManager")))));
            assertEq(DeploymentConstants.getAddressProvider(), address(uint160(uint256(keccak256("dp.test.addressProvider")))));
            assertEq(DeploymentConstants.getTreasuryAddress(), address(uint160(uint256(keccak256("dp.test.feesTreasury")))));
            assertEq(DeploymentConstants.getStabilityPoolAddress(), address(uint160(uint256(keccak256("dp.test.stabilityPool")))));
            assertEq(DeploymentConstants.getGmxDataStoreAddress(), address(uint160(uint256(keccak256("dp.test.gmxDataStore")))));
            assertEq(DeploymentConstants.getGmxReaderAddress(), address(uint160(uint256(keccak256("dp.test.gmxReader")))));
            assertEq(DeploymentConstants.getGlvReaderAddress(), address(uint160(uint256(keccak256("dp.test.glvReader")))));
        } else if (key == keccak256("avalanche")) {
            assertEq(DeploymentConstants.getNativeTokenSymbol(), bytes32("AVAX"));
            assertEq(DeploymentConstants.getNativeToken(), payable(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7));
            assertEq(DeploymentConstants.getDiamondAddress(), 0x2916B3bf7C35bd21e63D01C93C62FB0d4994e56D);
            assertEq(DeploymentConstants.getSmartLoansFactoryAddress(), 0x3Ea9D480295A73fd2aF95b4D96c2afF88b21B03D);
            assertEq(address(DeploymentConstants.getTokenManager()), 0xF3978209B7cfF2b90100C6F87CEC77dE928Ed58e);
            assertEq(DeploymentConstants.getAddressProvider(), address(0));
            assertEq(DeploymentConstants.getTreasuryAddress(), 0x18C244c62372dF1b933CD455769f9B4DdB820F0C);
            assertEq(DeploymentConstants.getStabilityPoolAddress(), 0x8Ac151296Ae72a8AeE01ECB33cd8Ad9842F2704f);
            assertEq(DeploymentConstants.getGmxDataStoreAddress(), 0x2F0b22339414ADeD7D5F06f9D604c7fF5b2fe3f6);
            assertEq(DeploymentConstants.getGmxReaderAddress(), 0x62Cb8740E6986B29dC671B2EB596676f60590A5B);
            assertEq(DeploymentConstants.getGlvReaderAddress(), 0x5C6905A3002f989E1625910ba1793d40a031f947);
        } else if (key == keccak256("arbitrum")) {
            assertEq(DeploymentConstants.getNativeTokenSymbol(), bytes32("ETH"));
            assertEq(DeploymentConstants.getNativeToken(), payable(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1));
            assertEq(DeploymentConstants.getDiamondAddress(), 0x62Cf82FB0484aF382714cD09296260edc1DC0c6c);
            assertEq(DeploymentConstants.getSmartLoansFactoryAddress(), 0xFf5e3dDaefF411a1dC6CcE00014e4Bca39265c20);
            assertEq(address(DeploymentConstants.getTokenManager()), 0x0a0D954d4b0F0b47a5990C0abd179A90fF74E255);
            assertEq(DeploymentConstants.getAddressProvider(), 0x6Aa0Fe94731aDD419897f5783712eBc13E8F3982);
            assertEq(DeploymentConstants.getTreasuryAddress(), 0x764a9756994f4E6cd9358a6FcD924d566fC2e666);
            assertEq(DeploymentConstants.getStabilityPoolAddress(), 0x6B9836D18978a2e865A935F12F4f958317DA4619);
            assertEq(DeploymentConstants.getGmxDataStoreAddress(), 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
            assertEq(DeploymentConstants.getGmxReaderAddress(), 0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789);
            assertEq(DeploymentConstants.getGlvReaderAddress(), 0x2C670A23f1E798184647288072e84054938B5497);
        } else {
            revert("unknown CHAIN_KEY in DeploymentChainConfig");
        }
        assertEq(DeploymentConstants.getPercentagePrecision(), 1000);
    }
}
