#!/usr/bin/env node
/**
 * Fetches a REAL signed redstone-primary-prod payload for manual usage.
 * Usage: node tools/redstone/fetch-payload.cjs AVAX,USDC,ETH
 * Prints hex payload (0x…) to stdout. Used via vm.ffi in FOUNDRY_PROFILE=live.
 *
 * Using .cjs extension because @redstone-finance/evm-connector is CommonJS
 * (no "type":"module" in its package.json); require() avoids ESM/CJS interop issues.
 */
"use strict";

const { DataServiceWrapper } = require("@redstone-finance/evm-connector");

const feeds = process.argv[2].split(",");
const wrapper = new DataServiceWrapper({
  dataServiceId: "redstone-primary-prod",
  uniqueSignersCount: 3,
  dataPackagesIds: feeds,
  authorizedSigners: [
    "0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774",
    "0xdEB22f54738d54976C4c0fe5ce6d408E40d88499",
    "0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202",
    "0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE",
    "0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de",
  ],
});

// prepareRedstonePayload(true) pads total payload length to a multiple of 32 bytes
// (same alignment that getRedstonePayloadForManualUsage produces).
// Returns hex without 0x prefix; we add it so vm.ffi hex-decodes the output.
(async () => {
  const payload = await wrapper.prepareRedstonePayload(true);
  process.stdout.write("0x" + payload);
})();
