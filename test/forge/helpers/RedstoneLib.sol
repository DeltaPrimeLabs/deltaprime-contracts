// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {Vm} from "forge-std/Vm.sol";

/**
 * RedstoneLib — pure-Solidity RedStone payload forger for Forge tests.
 * Serializes + signs data packages per the evm-connector 0.9.0 wire format
 * (verified against redstone-finance/protocol 0.9.0 JS serializer):
 *   package = [feedId32|value32]*M | ts(6B,ms,BE) | valueByteSize(4B)=32 | count(3B) | sig(65B r|s|v)
 *   payload = packages | packagesCount(2B) | unsignedMeta(padded so total%32==0) | metaLen(3B) | marker(9B)
 *   signedHash = RAW keccak256 of package bytes before sig (NOT EIP-191)
 *   data points sorted ascending by feedId before signing
 * Signers: 5 deterministic test keys keccak("DP_RS_SIGNER", i). Consumers under
 * test must authorise these via TestAuthorisedSigners (threshold 3 like prod).
 */
library RedstoneLib {
    bytes9 internal constant MARKER = 0x000002ed57011e0000;
    uint256 internal constant SIGNERS_DEFAULT = 3;

    function signerKey(uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked("DP_RS_SIGNER", i)));
    }

    function signerAddresses(Vm vm) internal pure returns (address[5] memory addrs) {
        for (uint256 i; i < 5; i++) addrs[i] = vm.addr(signerKey(i));
    }

    /// Default: all signers report identical values, ts = block.timestamp*1000, 3 signers.
    function buildPayload(Vm vm, bytes32[] memory feeds, uint256[] memory values)
        internal
        view
        returns (bytes memory)
    {
        uint256[][] memory perSigner = new uint256[][](SIGNERS_DEFAULT);
        for (uint256 i; i < SIGNERS_DEFAULT; i++) perSigner[i] = values;
        return buildPayloadPerSigner(vm, feeds, perSigner, block.timestamp * 1000, SIGNERS_DEFAULT);
    }

    /// Full control: per-signer values, explicit timestamp (ms), signer count (keys 0..signersCount-1).
    function buildPayloadPerSigner(
        Vm vm,
        bytes32[] memory feeds,
        uint256[][] memory valuesPerSigner,
        uint256 timestampMs,
        uint256 signersCount
    ) internal pure returns (bytes memory) {
        (bytes32[] memory sFeeds, uint256[][] memory sVals) = _sortByFeed(feeds, valuesPerSigner);
        bytes memory packages;
        for (uint256 s; s < signersCount; s++) {
            packages = bytes.concat(packages, _signedPackage(vm, sFeeds, sVals[s], timestampMs, signerKey(s)));
        }
        return _finalize(packages, signersCount);
    }

    /// Same as buildPayloadPerSigner but with explicit private keys (for unauthorised-signer tests).
    function buildPayloadWithKeys(
        Vm vm,
        bytes32[] memory feeds,
        uint256[] memory values,
        uint256 timestampMs,
        uint256[] memory privateKeys
    ) internal pure returns (bytes memory) {
        uint256[][] memory perSigner = new uint256[][](privateKeys.length);
        for (uint256 i; i < privateKeys.length; i++) perSigner[i] = values;
        (bytes32[] memory sFeeds, uint256[][] memory sVals) = _sortByFeed(feeds, perSigner);
        bytes memory packages;
        for (uint256 s; s < privateKeys.length; s++) {
            packages = bytes.concat(packages, _signedPackage(vm, sFeeds, sVals[s], timestampMs, privateKeys[s]));
        }
        return _finalize(packages, privateKeys.length);
    }

    /// Per-package timestamps (for TimestampsMustBeEqual tests). One package per entry.
    function buildPayloadMixedTimestamps(
        Vm vm,
        bytes32[] memory feeds,
        uint256[] memory values,
        uint256[] memory timestampsMs
    ) internal pure returns (bytes memory) {
        (bytes32[] memory sFeeds, uint256[][] memory sVals) =
            _sortByFeed(feeds, _replicate(values, timestampsMs.length));
        bytes memory packages;
        for (uint256 s; s < timestampsMs.length; s++) {
            packages = bytes.concat(packages, _signedPackage(vm, sFeeds, sVals[s], timestampsMs[s], signerKey(s)));
        }
        return _finalize(packages, timestampsMs.length);
    }

    /// Append payload to callData and call target; bubbles raw return/revert data.
    function wrap(
        Vm vm,
        address target,
        bytes memory callData,
        bytes32[] memory feeds,
        uint256[] memory values
    ) internal returns (bool ok, bytes memory ret) {
        bytes memory payload = buildPayload(vm, feeds, values);
        (ok, ret) = target.call(bytes.concat(callData, payload));
    }

    /// wrap() that reverts (bubbling inner revert data) on failure — for happy paths.
    function wrapExpectSuccess(
        Vm vm,
        address target,
        bytes memory callData,
        bytes32[] memory feeds,
        uint256[] memory values
    ) internal returns (bytes memory ret) {
        bool ok;
        (ok, ret) = wrap(vm, target, callData, feeds, values);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ---------- internals ----------

    function _signedPackage(
        Vm vm,
        bytes32[] memory sortedFeeds,
        uint256[] memory values,
        uint256 timestampMs,
        uint256 pk
    ) private pure returns (bytes memory) {
        // the wire format stores timestamps as 6 bytes (ms) — guard against silent uint48 wrap
        require(timestampMs < 2 ** 48, "RedstoneLib: timestampMs exceeds uint48");
        bytes memory points;
        for (uint256 i; i < sortedFeeds.length; i++) {
            points = bytes.concat(points, sortedFeeds[i], bytes32(values[i]));
        }
        bytes memory unsigned_ = bytes.concat(
            points,
            bytes6(uint48(timestampMs)),
            bytes4(uint32(32)),
            bytes3(uint24(sortedFeeds.length))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(unsigned_));
        return bytes.concat(unsigned_, r, s, bytes1(v));
    }

    function _finalize(bytes memory packages, uint256 count) private pure returns (bytes memory) {
        bytes memory meta = "DPFORGE";
        // pad metadata so total payload length is a multiple of 32 (matches
        // getRedstonePayloadForManualUsage; on-chain parser is agnostic but
        // alignment keeps byte-differential vs the JS reference exact)
        uint256 total = packages.length + 2 + meta.length + 3 + 9;
        uint256 pad = (32 - (total % 32)) % 32;
        for (uint256 i; i < pad; i++) meta = bytes.concat(meta, bytes1("_"));
        return bytes.concat(packages, bytes2(uint16(count)), meta, bytes3(uint24(meta.length)), MARKER);
    }

    /// Index-sort: sort an index array by feedId ascending, then rebuild outputs from it.
    /// This avoids the subtle parallel-array permutation bug in the draft insertion-sort sketch.
    function _sortByFeed(bytes32[] memory feeds, uint256[][] memory valuesPerSigner)
        private
        pure
        returns (bytes32[] memory sortedFeeds, uint256[][] memory sortedVals)
    {
        uint256 n = feeds.length;

        // Build index array [0, 1, 2, ...]
        uint256[] memory idx = new uint256[](n);
        for (uint256 i; i < n; i++) idx[i] = i;

        // Insertion-sort idx by feeds[idx[i]] ascending
        for (uint256 i = 1; i < n; i++) {
            uint256 keyIdx = idx[i];
            bytes32 keyFeed = feeds[keyIdx];
            uint256 j = i;
            while (j > 0 && feeds[idx[j - 1]] > keyFeed) {
                idx[j] = idx[j - 1];
                j--;
            }
            idx[j] = keyIdx;
        }

        // Rebuild sorted feeds and values from the sorted index
        sortedFeeds = new bytes32[](n);
        for (uint256 k; k < n; k++) {
            sortedFeeds[k] = feeds[idx[k]];
        }

        uint256 s = valuesPerSigner.length;
        sortedVals = new uint256[][](s);
        for (uint256 si; si < s; si++) {
            sortedVals[si] = new uint256[](n);
            for (uint256 k; k < n; k++) {
                sortedVals[si][k] = valuesPerSigner[si][idx[k]];
            }
        }
    }

    function _replicate(uint256[] memory values, uint256 n) private pure returns (uint256[][] memory out) {
        out = new uint256[][](n);
        for (uint256 i; i < n; i++) out[i] = values;
    }
}
