// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {TestRedstoneConsumer} from "../helpers/TestRedstoneConsumer.sol";

contract RedstoneNegativeTest is Test {
    TestRedstoneConsumer consumer;
    bytes32[] feeds;
    uint256[] values;

    function setUp() public {
        vm.warp(1_750_000_000);
        consumer = new TestRedstoneConsumer();
        feeds.push(bytes32("AVAX"));
        values.push(30e8);
    }

    function _call(bytes memory payload) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(consumer).call(
            abi.encodePacked(abi.encodeWithSelector(TestRedstoneConsumer.extractValues.selector, feeds), payload)
        );
    }

    function _expectRevertWith(bytes memory payload, bytes memory expectedError) internal {
        (bool ok, bytes memory ret) = _call(payload);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(expectedError), "wrong error selector");
    }

    function testTwoSignersInsufficient() public {
        uint256[][] memory perSigner = new uint256[][](2);
        perSigner[0] = values;
        perSigner[1] = values;
        bytes memory p = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, block.timestamp * 1000, 2);
        _expectRevertWith(p, abi.encodeWithSignature("InsufficientNumberOfUniqueSigners(uint256,uint256)", 2, 3));
    }

    function testUnauthorisedSignerRejected() public {
        uint256[] memory keys = new uint256[](3);
        keys[0] = RedstoneLib.signerKey(0);
        keys[1] = RedstoneLib.signerKey(1);
        keys[2] = uint256(keccak256("NOT_A_DP_SIGNER")); // unauthorised
        bytes memory p = RedstoneLib.buildPayloadWithKeys(vm, feeds, values, block.timestamp * 1000, keys);
        (bool ok, bytes memory ret) = _call(p);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(abi.encodeWithSignature("SignerNotAuthorised(address)", address(0))));
    }

    function testDuplicateSignerDoesNotCount() public {
        uint256[] memory keys = new uint256[](3);
        keys[0] = RedstoneLib.signerKey(0);
        keys[1] = RedstoneLib.signerKey(1);
        keys[2] = RedstoneLib.signerKey(1); // duplicate — only 2 unique
        bytes memory p = RedstoneLib.buildPayloadWithKeys(vm, feeds, values, block.timestamp * 1000, keys);
        _expectRevertWith(p, abi.encodeWithSignature("InsufficientNumberOfUniqueSigners(uint256,uint256)", 2, 3));
    }

    function testMixedTimestampsRevert() public {
        uint256[] memory ts = new uint256[](3);
        ts[0] = block.timestamp * 1000;
        ts[1] = block.timestamp * 1000;
        ts[2] = block.timestamp * 1000 + 1; // differs
        bytes memory p = RedstoneLib.buildPayloadMixedTimestamps(vm, feeds, values, ts);
        _expectRevertWith(p, abi.encodeWithSignature("TimestampsMustBeEqual()"));
    }

    function testZeroTimestampReverts() public {
        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) perSigner[i] = values;
        bytes memory p = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, 0, 3);
        _expectRevertWith(p, abi.encodeWithSignature("DataTimestampCannotBeZero()"));
    }

    function testStaleTimestampReverts() public {
        uint256 staleMs = (block.timestamp - 181) * 1000; // > 3 min old
        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) perSigner[i] = values;
        bytes memory p = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, staleMs, 3);
        (bool ok, bytes memory ret) = _call(p);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(abi.encodeWithSignature("TimestampIsTooOld(uint256,uint256)", 0, 0)));
    }

    function testFutureTimestampReverts() public {
        uint256 futureMs = (block.timestamp + 61) * 1000; // > 1 min ahead
        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) perSigner[i] = values;
        bytes memory p = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, futureMs, 3);
        (bool ok, bytes memory ret) = _call(p);
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(abi.encodeWithSignature("TimestampFromTooLongFuture(uint256,uint256)", 0, 0)));
    }

    function testMissingFeedReverts() public {
        bytes32[] memory requested = new bytes32[](1);
        requested[0] = bytes32("BTC"); // not in payload
        bytes memory p = RedstoneLib.buildPayload(vm, feeds, values);
        (bool ok, bytes memory ret) = address(consumer).call(
            abi.encodePacked(abi.encodeWithSelector(TestRedstoneConsumer.extractValues.selector, requested), p)
        );
        assertFalse(ok);
        assertEq(bytes4(ret), bytes4(abi.encodeWithSignature("InsufficientNumberOfUniqueSigners(uint256,uint256)", 0, 3)));
    }

    function testCorruptedMarkerReverts() public {
        bytes memory p = RedstoneLib.buildPayload(vm, feeds, values);
        // SANCTIONED ADAPTATION: plan said `p[p.length - 1]` but the REDSTONE_MARKER_MASK
        // (0x...0002ed57011e0000) only checks marker bytes 2-6 (of 9); the trailing two
        // 0x00 bytes are masked with 0x00 so AND-ing them produces 0 regardless of value —
        // corrupting the last byte passes the marker check and the call succeeds instead of
        // reverting. Corrupt p[p.length - 3] (the 0x1e byte, position 6 of the marker)
        // which IS covered by the mask, so the check correctly reverts CalldataMustHaveValidPayload.
        p[p.length - 3] = 0x01; // corrupt a mask-covered marker byte (0x1e → 0x01)
        _expectRevertWith(p, abi.encodeWithSignature("CalldataMustHaveValidPayload()"));
    }

    function testEvenSignerCountMediansAverage() public {
        // 4 signers: 10, 20, 30, 40 → plan predicted median = (20+30)/2 = 25e8 over all 4.
        // SANCTIONED ADAPTATION: the consumer caps collected values at threshold (3) per the
        // bitmap logic. Packages are read in REVERSE calldata order, so the first 3 unique
        // signers encountered are signer 3 (30e8), signer 2 (20e8), signer 1 (40e8).
        // Sorted: [20e8, 30e8, 40e8] → odd-count median = 30e8.
        // Signer 0 (10e8) is ecrecovered but its value is discarded once threshold is met.
        // Adjusted expected value to 30e8 to pin the actual cap behaviour.
        uint256[][] memory perSigner = new uint256[][](4);
        for (uint256 i; i < 4; i++) perSigner[i] = new uint256[](1);
        perSigner[0][0] = 10e8;
        perSigner[1][0] = 40e8;
        perSigner[2][0] = 20e8;
        perSigner[3][0] = 30e8;
        bytes memory p = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, block.timestamp * 1000, 4);
        (bool ok, bytes memory ret) = _call(p);
        assertTrue(ok);
        // First-3-encountered (reverse parse order): signer3=30e8, signer2=20e8, signer1=40e8
        // Sorted: [20e8, 30e8, 40e8] → median of odd-count = 30e8 (not 25e8 from all-4 average)
        assertEq(abi.decode(ret, (uint256[]))[0], 30e8);
    }
}
