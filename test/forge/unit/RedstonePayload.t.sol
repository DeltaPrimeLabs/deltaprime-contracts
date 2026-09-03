// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {TestRedstoneConsumer} from "../helpers/TestRedstoneConsumer.sol";

contract RedstonePayloadTest is Test {
    TestRedstoneConsumer consumer;

    function setUp() public {
        vm.warp(1_750_000_000); // sane wall-clock-ish base; payload ts derives from block.timestamp
        consumer = new TestRedstoneConsumer();
    }

    function _get(bytes32[] memory feeds, bytes memory payload) internal returns (uint256[] memory) {
        (bool ok, bytes memory ret) = address(consumer).call(
            abi.encodePacked(abi.encodeWithSelector(TestRedstoneConsumer.extractValues.selector, feeds), payload)
        );
        require(ok, string(abi.encodePacked("extract failed: ", ret)));
        return abi.decode(ret, (uint256[]));
    }

    function testSingleFeedThreeSigners() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("AVAX");
        uint256[] memory values = new uint256[](1);
        values[0] = 30e8;
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, values);
        uint256[] memory got = _get(feeds, payload);
        assertEq(got[0], 30e8);
    }

    function testMultiFeedUnsortedInputIsSortedBeforeSigning() public {
        // Feed ids deliberately NOT in ascending order: "USDC" > "AVAX" numerically
        bytes32[] memory feeds = new bytes32[](3);
        feeds[0] = bytes32("USDC");
        feeds[1] = bytes32("AVAX");
        feeds[2] = bytes32("PRIME");
        uint256[] memory values = new uint256[](3);
        values[0] = 1e8;
        values[1] = 30e8;
        values[2] = 2e7;
        bytes memory payload = RedstoneLib.buildPayload(vm, feeds, values);
        uint256[] memory got = _get(feeds, payload); // request in original order
        assertEq(got[0], 1e8);
        assertEq(got[1], 30e8);
        assertEq(got[2], 2e7);
    }

    function testMedianOfDivergentSignerValues() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("AVAX");
        // 3 signers report 29, 30, 31 → median 30
        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) perSigner[i] = new uint256[](1);
        perSigner[0][0] = 29e8;
        perSigner[1][0] = 31e8;
        perSigner[2][0] = 30e8;
        bytes memory payload =
            RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, block.timestamp * 1000, 3);
        uint256[] memory got = _get(feeds, payload);
        assertEq(got[0], 30e8);
    }

    function testWrapHelperRoundTrip() public {
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("ETH");
        uint256[] memory values = new uint256[](1);
        values[0] = 2500e8;
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm,
            address(consumer),
            abi.encodeWithSelector(TestRedstoneConsumer.extractValues.selector, feeds),
            feeds,
            values
        );
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256[]))[0], 2500e8);
    }

    function testSignerAddressesAreDeterministic() public {
        address[5] memory s = RedstoneLib.signerAddresses(vm);
        for (uint256 i; i < 5; i++) {
            assertEq(s[i], vm.addr(uint256(keccak256(abi.encodePacked("DP_RS_SIGNER", i)))));
            assertTrue(s[i] != address(0));
        }
    }

    /// Determinism pin: identical inputs must serialize byte-identically — the
    /// Task-8 differential vs the official JS serializer depends on this.
    function testPayloadIsByteDeterministic() public {
        bytes32[] memory feeds = new bytes32[](2);
        feeds[0] = bytes32("AVAX");
        feeds[1] = bytes32("USDC");
        uint256[] memory values = new uint256[](2);
        values[0] = 30e8;
        values[1] = 1e8;
        bytes memory a = RedstoneLib.buildPayload(vm, feeds, values);
        bytes memory b = RedstoneLib.buildPayload(vm, feeds, values);
        assertEq(keccak256(a), keccak256(b));
    }

    function testTimestampOverflowGuard() public {
        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) {
            perSigner[i] = new uint256[](1);
            perSigner[i][0] = 30e8;
        }
        bytes32[] memory feeds = new bytes32[](1);
        feeds[0] = bytes32("AVAX");
        vm.expectRevert(bytes("RedstoneLib: timestampMs exceeds uint48"));
        this.exposedBuild(feeds, perSigner, 2 ** 48);
    }

    // external wrapper so expectRevert applies to a call, not an internal jump
    function exposedBuild(bytes32[] memory feeds, uint256[][] memory perSigner, uint256 ts)
        external
        view
        returns (bytes memory)
    {
        return RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, ts, 3);
    }
}
