#!/usr/bin/env node
// Compares Forge vs Hardhat deployedBytecode for given fully-qualified contracts,
// ignoring the trailing CBOR metadata section (last-2-bytes = metadata length).
// Usage: node tools/scripts/compare-forge-hardhat-bytecode.js contracts/TokenManager.sol:TokenManager ...
const { execSync } = require('child_process');
const fs = require('fs');

function stripMeta(hex) {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  if (h.length < 4) return h;
  const metaLen = parseInt(h.slice(-4), 16); // bytes
  return h.slice(0, h.length - (metaLen + 2) * 2);
}

let fail = false;
for (const fq of process.argv.slice(2)) {
  const [path, name] = fq.split(':');
  // Suppress nightly-build warning; take only the last non-empty line (hex string)
  const forgeRaw = execSync(
    `FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge inspect ${fq} deployedBytecode`,
    { encoding: 'utf8' }
  ).trim();
  // forge may emit leading warnings; the hex is the last line
  const forgeHex = forgeRaw.split('\n').filter(l => l.trim()).pop().trim();

  const artPath = `artifacts/${path}/${name}.json`;
  if (!fs.existsSync(artPath)) {
    console.log(`MISSING hardhat artifact: ${artPath}`);
    fail = true;
    continue;
  }
  const art = JSON.parse(fs.readFileSync(artPath, 'utf8'));
  const a = stripMeta(forgeHex);
  const b = stripMeta(art.deployedBytecode);
  const ok = a === b;
  console.log(
    `${ok ? 'MATCH ' : 'DIFFER'} ${fq}` +
    ` (forge ${a.length / 2}B vs hardhat ${b.length / 2}B sans metadata)`
  );
  if (!ok) {
    // Find first differing nibble pair for quick root-cause
    const minLen = Math.min(a.length, b.length);
    let diffAt = -1;
    for (let i = 0; i < minLen; i += 2) {
      if (a[i] !== b[i] || a[i + 1] !== b[i + 1]) { diffAt = i / 2; break; }
    }
    if (diffAt >= 0) {
      console.log(`  First diff at byte ${diffAt} (0x${diffAt.toString(16)})`);
      console.log(`  forge[${diffAt}..${diffAt+8}]: ${a.slice(diffAt*2, diffAt*2+16)}`);
      console.log(`  hhat [${diffAt}..${diffAt+8}]: ${b.slice(diffAt*2, diffAt*2+16)}`);
    } else if (a.length !== b.length) {
      console.log(`  Length mismatch after stripping metadata: forge=${a.length/2}B hhat=${b.length/2}B`);
    }
    fail = true;
  }
}
process.exit(fail ? 1 : 0);
