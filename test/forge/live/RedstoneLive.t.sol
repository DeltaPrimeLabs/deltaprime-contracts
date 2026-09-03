// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {TestRedstoneConsumer} from "../helpers/TestRedstoneConsumer.sol";
import "@redstone-finance/evm-connector/contracts/data-services/PrimaryProdDataServiceConsumerBase.sol";

// ---------------------------------------------------------------------------
// Minimal prod consumer: real signers + real threshold + real timestamp/median.
// Adds extractValues and extractTimestamp entry points for direct ffi testing.
// ---------------------------------------------------------------------------
contract ProdConsumerHarness is PrimaryProdDataServiceConsumerBase {
    function extractValues(bytes32[] memory feeds) external view returns (uint256[] memory) {
        return getOracleNumericValuesFromTxMsg(feeds);
    }

    /// Extracts the common timestamp from all packages (ms). Reverts if packages
    /// have different timestamps — used to warp block.timestamp before price read.
    function extractTimestamp() external view returns (uint256) {
        return extractTimestampsAndAssertAllAreEqual();
    }
}

// ---------------------------------------------------------------------------
// Live tests — SKIP unless RUN_LIVE_REDSTONE=true.
// Run: RUN_LIVE_REDSTONE=true FOUNDRY_PROFILE=live forge test \
//        --match-path 'test/forge/live/**' -vv
//
// NOTE: scripts are .cjs (not .mjs) because @redstone-finance/evm-connector and
// @redstone-finance/protocol are CommonJS packages (no "type":"module") — using
// require() avoids ESM/CJS interop issues.
//
// Payload comparison strategy (testForgerMatchesOfficialSerializer):
//   BYTE-EXACT — both the Solidity forger and build-mock-payload.cjs apply the
//   same padding formula: pad = (32 - total%32) % 32 appended to "DPFORGE"
//   metadata, producing an identical byte sequence from packages through marker.
//   If this assertion ever fails purely on metadata padding (e.g. due to an
//   upstream change in RedstonePayload.prepare padding behaviour), the fallback
//   is prefix+parse-equivalence: compare only the packages+count prefix bytes
//   and assert identical values via TestRedstoneConsumer. Currently byte-exact
//   is verified to hold for the test case used.
// ---------------------------------------------------------------------------
contract RedstoneLiveTest is Test {
    modifier liveOnly() {
        // vm.skip BEFORE any ffi call; live tests self-skip in the default profile
        // (where ffi=false) so plain `forge test --match-path 'test/forge/**'` is safe.
        if (!vm.envOr("RUN_LIVE_REDSTONE", false)) {
            vm.skip(true);
        }
        _;
    }

    // -----------------------------------------------------------------------
    // Test 1: real RedStone gateway → unmodified PrimaryProd consumer.
    // Verifies that real signers + real on-chain parser + real timestamp
    // validation accept a fresh gateway payload.
    // -----------------------------------------------------------------------
    function testLiveGatewayPayloadAgainstUnmodifiedProdConsumer() public liveOnly {
        string[] memory args = new string[](3);
        args[0] = "node";
        args[1] = "tools/redstone/fetch-payload.cjs";
        args[2] = "AVAX,ETH,USDC";
        bytes memory payload = vm.ffi(args);

        ProdConsumerHarness prod = new ProdConsumerHarness();

        bytes32[] memory feeds = new bytes32[](3);
        feeds[0] = bytes32("AVAX");
        feeds[1] = bytes32("ETH");
        feeds[2] = bytes32("USDC");

        // Align block.timestamp to the payload's embedded timestamp so the
        // ±180s / +60s validation in RedstoneDefaultsLib accepts it.
        (bool okTs, bytes memory tsRet) = address(prod).call(
            abi.encodePacked(
                abi.encodeWithSelector(ProdConsumerHarness.extractTimestamp.selector),
                payload
            )
        );
        require(okTs, "timestamp extraction failed: payload malformed?");
        uint256 tsMs = abi.decode(tsRet, (uint256));
        vm.warp(tsMs / 1000);

        (bool ok, bytes memory ret) = address(prod).call(
            abi.encodePacked(
                abi.encodeWithSelector(ProdConsumerHarness.extractValues.selector, feeds),
                payload
            )
        );
        assertTrue(ok, "real signers + unmodified prod consumer must verify");
        uint256[] memory vals = abi.decode(ret, (uint256[]));
        for (uint256 i; i < 3; i++) assertGt(vals[i], 0);
        // Sanity: ETH priced above AVAX (not a market call; fails only if feeds
        // are misrouted or the test fixture is using wildly wrong prices).
        assertGt(vals[1], vals[0], "ETH should price above AVAX");
    }

    // -----------------------------------------------------------------------
    // Test 2: forger byte-differential.
    // Both sides produce a payload for AVAX=30e8, USDC=1e8, ts=1750000000000,
    // 3 DP test signers. Asserts BYTE-EXACT equality (keccak256).
    //
    // Parity guarantees (see scripts for detail):
    //   key:   keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i)))
    //          ≡ keccak256(concat([utf8("DP_RS_SIGNER"), zeroPad(hexlify(i),32)]))
    //   value: bytes32(30e8) ≡ NumericDataPoint({value:30, decimals:8}) → 30*1e8
    //   sig:   vm.sign (raw ECDSA RFC 6979) r‖s‖v ≡ signingKey.signDigest r‖s‖v
    //   meta:  "DPFORGE" padded by (32-(total%32))%32 '_' bytes — same formula
    // -----------------------------------------------------------------------
    function testForgerMatchesOfficialSerializer() public liveOnly {
        bytes32[] memory feeds = new bytes32[](2);
        feeds[0] = bytes32("AVAX");
        feeds[1] = bytes32("USDC");
        uint256[] memory values = new uint256[](2);
        values[0] = 30e8;
        values[1] = 1e8;
        uint256 tsMs = 1_750_000_000_000;

        uint256[][] memory perSigner = new uint256[][](3);
        for (uint256 i; i < 3; i++) perSigner[i] = values;
        bytes memory ours = RedstoneLib.buildPayloadPerSigner(vm, feeds, perSigner, tsMs, 3);

        string[] memory args = new string[](3);
        args[0] = "node";
        args[1] = "tools/redstone/build-mock-payload.cjs";
        args[2] = '{"timestampMs":1750000000000,"signers":3,"points":[{"feed":"AVAX","value":"3000000000"},{"feed":"USDC","value":"100000000"}]}';
        bytes memory jsRef = vm.ffi(args);

        assertEq(keccak256(ours), keccak256(jsRef), "forger drifted from official serializer");
    }
}
