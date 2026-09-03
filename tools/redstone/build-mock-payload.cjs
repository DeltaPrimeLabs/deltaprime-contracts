#!/usr/bin/env node
/**
 * Builds a payload via the OFFICIAL @redstone-finance/protocol serializer using
 * the DP test signer keys — the byte-level reference for RedstoneLib.
 *
 * Usage: node tools/redstone/build-mock-payload.cjs '<json>'
 *   json: {"timestampMs":1750000000000,"signers":3,"points":[{"feed":"AVAX","value":"3000000000"}]}
 *
 * Each point.value is the RAW 8-decimal integer (e.g. 3000000000 = AVAX @ $30).
 *
 * Using .cjs extension because @redstone-finance/protocol is CommonJS.
 *
 * ─── KEY-DERIVATION PARITY ───────────────────────────────────────────────────
 * RedstoneLib.signerKey(i) = keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i)))
 * abi.encodePacked(string, uint256) = utf8-bytes("DP_RS_SIGNER") ‖ 32-byte BE uint
 * JS equivalent: keccak256(concat([toUtf8Bytes("DP_RS_SIGNER"), zeroPad(hexlify(i), 32)]))
 * Verified: produces the same 5 addresses pinned in TestAuthorisedSigners.sol.
 *
 * ─── METADATA PARITY ─────────────────────────────────────────────────────────
 * RedstoneLib._finalize pads "DPFORGE" with '_' so total payload length % 32 == 0,
 * using: pad = (32 - (total % 32)) % 32, where total = packagesBytes+2+metaLen+3+9.
 * RedstonePayload.prepare() does NOT pad automatically.
 * This script replicates the same padding formula so the comparison in the Forge
 * differential test (testForgerMatchesOfficialSerializer) is BYTE-EXACT.
 * ─────────────────────────────────────────────────────────────────────────────
 */
"use strict";

const { DataPackage, NumericDataPoint, RedstonePayload } = require("@redstone-finance/protocol");
const { ethers } = require("ethers");

const cfg = JSON.parse(process.argv[2]);

const signed = [];
for (let i = 0; i < cfg.signers; i++) {
  // Reproduce Solidity: keccak256(abi.encodePacked("DP_RS_SIGNER", uint256(i)))
  //   = keccak256(utf8("DP_RS_SIGNER") ‖ BE32(i))
  const pk = ethers.utils.keccak256(
    ethers.utils.concat([
      ethers.utils.toUtf8Bytes("DP_RS_SIGNER"),
      ethers.utils.zeroPad(ethers.utils.hexlify(i), 32),
    ])
  );

  // value in cfg.points is the raw 8-decimal integer (e.g. "3000000000" for AVAX@$30).
  // NumericDataPoint takes a human-readable value + decimals; it multiplies by 10^decimals.
  // So we divide by 1e8 first: NumericDataPoint({value: 30, decimals: 8}) → 30*1e8 = 3000000000
  // → same 32-byte BE encoding as Solidity bytes32(30e8).
  const points = cfg.points.map(
    (p) =>
      new NumericDataPoint({
        dataFeedId: p.feed,
        value: Number(p.value) / 1e8,
        decimals: 8,
      })
  );

  const dp = new DataPackage(points, cfg.timestampMs);
  signed.push(dp.sign(pk));
}

// Step 1: produce base payload with unpadded "DPFORGE" metadata.
const baseHex = RedstonePayload.prepare(signed, "DPFORGE");
const baseLen = baseHex.length / 2; // bytes

// Step 2: replicate RedstoneLib._finalize padding formula:
//   pad = (32 - (total % 32)) % 32
// where total = packages+2+meta+3+9 = full payload length when meta="DPFORGE"(7B).
const bytesToAdd = (32 - (baseLen % 32)) % 32;

// Step 3: regenerate with padded metadata so total payload length % 32 == 0.
const paddedMeta = "DPFORGE" + "_".repeat(bytesToAdd);
const finalHex = RedstonePayload.prepare(signed, paddedMeta);

process.stdout.write("0x" + finalHex);
