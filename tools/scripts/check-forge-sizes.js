#!/usr/bin/env node
// CI size gate: fails if any PRODUCTION contract's deployed-bytecode size exceeds
// the EIP-170 limit (24,576 bytes), unless allowlisted in tools/forge-size-allowlist.json.
//
// Measures artifact bytes DIRECTLY from out/**/*.json (deployedBytecode length)
// instead of trusting `forge build --sizes` — that report's semantics drifted
// between forge versions (a newer stable reported 24,666 for a facet whose
// artifact, per both hardhat and forge artifacts on the same source, is 24,527
// bytes; see feat/forge-port CI run 27389233100). Artifact bytes are the truth
// that matters at deployment.
//
// Classification comes from the artifact's compilationTarget source path:
//   - contracts/**           -> production, gated
//   - test/forge/**, lib/**, node_modules/** -> skipped (test/dev-only)
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const LIMIT = 24576;

execSync('FOUNDRY_DISABLE_NIGHTLY_WARNING=1 forge build', { stdio: ['ignore', 'inherit', 'inherit'] });

const allow = JSON.parse(fs.readFileSync(`${__dirname}/../forge-size-allowlist.json`, 'utf8'));
// names entries: {name, reason, maxSize?} — maxSize caps how big an allowlisted
// contract may measure before the gate fails anyway (regression backstop for
// platform-divergent solc codegen; see the GmxV2FacetArbitrum entry).
const allowed = (name, size) => {
  const entry = allow.names.find((n) => (typeof n === 'string' ? n === name : n.name === name));
  if (entry) return typeof entry === 'string' || !entry.maxSize || size <= entry.maxSize;
  return allow.patterns.some((p) => new RegExp(p.regex).test(name));
};

function* artifacts(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) yield* artifacts(p);
    else if (entry.name.endsWith('.json') && !entry.name.endsWith('.metadata.json')) yield p;
  }
}

let fail = false;
const seen = new Set();
for (const file of artifacts('out')) {
  let art;
  try {
    art = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    continue;
  }
  const hex = art.deployedBytecode && (art.deployedBytecode.object || art.deployedBytecode);
  if (typeof hex !== 'string' || hex.length <= 2) continue; // abstract/interface/empty
  const target = art.metadata && art.metadata.settings && art.metadata.settings.compilationTarget;
  if (!target) continue;
  const [sourcePath, name] = Object.entries(target)[0];
  if (!sourcePath.startsWith('contracts/')) continue; // test/dev/vendored-dep artifact
  if (seen.has(`${sourcePath}:${name}`)) continue;
  seen.add(`${sourcePath}:${name}`);
  const size = (hex.length - 2) / 2;
  if (size > LIMIT) {
    if (allowed(name, size)) {
      console.log(`ALLOW ${name} ${size} (allowlisted)`);
    } else {
      console.error(`FAIL  ${name} ${size} > ${LIMIT} (${sourcePath})`);
      fail = true;
    }
  }
}
if (seen.size === 0) {
  console.error('FAIL  no production artifacts found under out/ — build/classification broken');
  fail = true;
}
console.log(`Checked ${seen.size} production contracts.`);
console.log(fail ? 'Size gate: FAILED' : 'Size gate: OK');
process.exit(fail ? 1 : 0);
