#!/usr/bin/env node
/* eslint-disable no-console */
//
// verify-onchain-bytecode.js
// ─────────────────────────────────────────────────────────────────────────────
// SELF-CONTAINED on-chain runtime-bytecode verifier for this Hardhat repo.
// (Hardhat analog of the degen-prime Foundry on-chain verifier.)
//
// DETERMINISTIC BY DEFAULT. With no flags it (1) checks out the repo's current
// HEAD into an isolated throwaway git worktree, (2) embeds that commit into the
// `// Last deployed from commit: <sha>;` stamp (a comment — it changes the
// appended metadata hash, never the executable bytecode), (3) does a CLEAN
// `npx hardhat compile` there, and (4) byte-compares against chain. So the verdict
// never depends on a stale local artifacts/ and — once the deploy-box embeds the
// deploy commit at deploy time (in progress) — reproduces a clean `full` match.
// Your working tree is NEVER touched (all stamping happens in the throwaway worktree).
//
// Given a chain (arbitrum / avalanche) and one or more DEPLOYED addresses, it:
//   1. compiles the chosen commit     → `npx hardhat compile` (clean, in the worktree)
//   2. reads the COMPILED runtime      → Hardhat artifact `.deployedBytecode`
//   3. fetches the ON-CHAIN runtime    → ethers `provider.getCode(addr)`  (eth_getCode)
//   4. compares them metadata-aware    → strip trailing CBOR metadata + mask solc
//                                        immutables on BOTH sides, then keccak-compare
//   5. prints a verdict per address    → full / partial / mismatch
//      and exits non-zero if ANY address is mismatch / error.
//
// Verdicts (identical classification to the CAO worker's bytecode-repro plugin):
//   full     — compiled runtime === on-chain runtime, byte-for-byte (incl. metadata).
//   partial  — PASS. The EXECUTABLE (runtime) code is byte-for-byte identical after
//              stripping the appended CBOR metadata trailer + masking solc immutables;
//              ONLY that non-executable trailer (and/or construction-time immutables)
//              differs — a genuine code match. The usual cause is that the on-chain
//              "// Last deployed from commit:" stamp differs from yours (e.g. --no-embed,
//              or a deploy made before the box began embedding the commit). The stamp
//              is a comment, so it changes metadata, never bytecode.
//   mismatch — differ even after strip+mask → LOUD FAIL (deployed code != this repo).
//
// Identify the contract behind an address two ways:
//   • --name <ContractName>  → verify every address against that one artifact.
//   • (no --name)            → SCAN all compiled artifacts and auto-match the one
//                              whose metadata-stripped runtime equals the on-chain
//                              runtime (no name needed).
//
// DEPENDENCIES: ONLY this repo's own source + node_modules (ethers + hardhat, both
// already deps) + an RPC endpoint. NO AWS, NO block-explorer API key, NO external
// service. RPC comes from --rpc-url, else $ARBITRUM_RPC_URL / $AVALANCHE_RPC_URL,
// else a public default (so it runs with zero secrets configured).
//
// getCode QUORUM (default ON): a single compromised RPC could feed fake bytecode and
// silently pass. We cross-check eth_getCode across N independent RPCs (the private/env
// one + a random sample of reputable no-API-key PUBLIC endpoints), all pinned to ONE
// finalized block; ALL must return byte-identical code or we abort LOUDLY
// ("⚠ RPC DISAGREEMENT", exit 3). Tune with --rpc-quorum <N> (default 4) /
// --rpc-quorum-min <N> (default 3); --no-quorum (or --rpc-quorum 1) = single RPC.
//
// USAGE:
//   node tools/scripts/verify-onchain-bytecode.js --chain arbitrum \
//        --address 0xabc... [--address 0xdef...] [--name DiamondLoupeFacet] \
//        [--deploy-commit <sha>] [--no-embed] [--no-build] [--rpc-url https://...]
//
//   # zero-flag deterministic verify (auto-identify, public RPC):
//   node tools/scripts/verify-onchain-bytecode.js --chain arbitrum --address 0xabc...
//
// FLAGS:
//   --deploy-commit <sha>  Build+stamp this commit instead of HEAD (verify a contract
//                          deployed from a different commit). Must be reachable here.
//   --no-embed             Do NOT stamp the deploy commit. Needed for contracts deployed
//                          BEFORE the box began embedding (on-chain stamp is empty `;`);
//                          you still get partial (executable-verified) at worst.
//   --no-build             Skip the clean isolated compile; read the EXISTING
//                          artifacts/ (fast path). Implies --no-embed. (--no-compile alias)
//   --cao-payload <file>   Read a CAO Dashboard verification JSON and verify every
//                          contract in it that belongs to this repo (arbitrum / avalanche).
//                          Groups by deploy-commit, builds+verifies each group, and
//                          prints a combined summary table. Ignores --address/--name
//                          from the CLI; all other flags are forwarded.
//
//   # Verify all arb/avax contracts from a CAO Dashboard JSON export:
//   node tools/scripts/verify-onchain-bytecode.js --cao-payload cao-verify-arbitrum-2026-06-30.json
//
// Heavy build-info JSON (immutables source) is only parsed when a contract actually
// HAS immutables; if you hit it, run with: node --max-old-space-size=8192 <this> ...
//
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execSync, execFileSync } = require('child_process');
const { ethers } = require('ethers');

// keccak256 over a 0x-prefixed hex string (ethers v5).
const keccak256 = ethers.utils.keccak256;

const REPO_ROOT = path.resolve(__dirname, '..', '..');
// Where compiled artifacts are read from. Repointed at the isolated build worktree
// when we do a clean build (default); falls back to the user checkout for --no-build.
let artifactsContractsDir = path.join(REPO_ROOT, 'artifacts', 'contracts');

// Forge support: the CAO deployer-box uses forge, so contracts deployed via it must
// be verified against forge-compiled artifacts. When foundry.toml exists and `--forge`
// is passed (or the default auto-detect picks it), we compile with `forge build` and
// read artifacts from `out/` (forge's default output dir).
let useForge = null; // null = auto-detect, true = forced, false = forced off
let forgeOutDir = null; // set when forge is active

const CHAINS = {
  arbitrum: { id: 42161, envVar: 'ARBITRUM_RPC_URL', publicRpc: 'https://arb1.arbitrum.io/rpc' },
  avalanche: { id: 43114, envVar: 'AVALANCHE_RPC_URL', publicRpc: 'https://api.avax.network/ext/bc/C/rpc' },
};
const CHAIN_ALIASES = { arb: 'arbitrum', arbitrum: 'arbitrum', avax: 'avalanche', avalanche: 'avalanche' };

// ── getCode QUORUM (defense-in-depth) ─────────────────────────────────────────
// A single compromised/poisoned RPC could return fake bytecode and silently pass
// verification. To defend against that we cross-check `eth_getCode` across N
// INDEPENDENT RPCs (the private/env one + a random sample of reputable, no-API-key
// PUBLIC endpoints), all at the SAME pinned block, and require them to agree
// byte-for-byte. If two valid responses differ we abort LOUDLY rather than trust
// either. Opt out with --no-quorum / --rpc-quorum 1 (single private RPC, faster).
//
// Curated keyless PUBLIC lists per chain (easy to extend). Only endpoints that work
// WITHOUT an API key belong here.
const PUBLIC_RPCS = {
  arbitrum: [
    'https://arb1.arbitrum.io/rpc',
    'https://arbitrum-one.publicnode.com',
    'https://arbitrum-one-rpc.publicnode.com',
    'https://arbitrum.llamarpc.com',
    'https://arbitrum.drpc.org',
    'https://1rpc.io/arb',
    'https://arbitrum.meowrpc.com',
    'https://arbitrum-one.public.blastapi.io',
    'https://rpc.ankr.com/arbitrum',
    'https://arbitrum.blockpi.network/v1/rpc/public',
    'https://endpoints.omniatech.io/v1/arbitrum/one/public',
    'https://arbitrum.api.onfinality.io/public',
    'https://public.stackup.sh/api/v1/node/arbitrum-one',
    'https://arb-pokt.nodies.app',
    'https://arbitrum.gateway.tenderly.co',
    'https://arbitrum.rpc.subquery.network/public',
    'https://0xrpc.io/arb',
    'https://arb1.lava.build',
  ],
  avalanche: [
    'https://api.avax.network/ext/bc/C/rpc',
    'https://avalanche-c-chain-rpc.publicnode.com',
    'https://avalanche.public-rpc.com',
    'https://avalanche.drpc.org',
    'https://1rpc.io/avax/c',
    'https://avax.meowrpc.com',
    'https://ava-mainnet.public.blastapi.io/ext/bc/C/rpc',
    'https://rpc.ankr.com/avalanche',
    'https://endpoints.omniatech.io/v1/avax/mainnet/public',
    'https://avalanche.blockpi.network/v1/rpc/public',
    'https://avax-pokt.nodies.app/ext/bc/C/rpc',
    'https://0xrpc.io/avax',
    'https://avalanche.api.onfinality.io/public/ext/bc/C/rpc',
    'https://public.stackup.sh/api/v1/node/avalanche-mainnet',
  ],
};

const QUORUM_TIMEOUT_MS = 8000;   // per-RPC timeout
const CONFIRMATION_LAG = 16;      // blocks below `latest` if the chain has no `finalized` tag

function shuffle(a) {
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

/** Ordered provider pool: private/env first (always, if set), then a shuffled,
 *  de-duped list of the chain's public RPCs. */
function buildQuorumPool(chainKey, priv) {
  const pool = [];
  const seen = new Set();
  const add = (u) => {
    if (!u) return;
    const k = u.toLowerCase();
    if (seen.has(k)) return;
    seen.add(k);
    pool.push(u);
  };
  add(priv);
  for (const u of shuffle([...(PUBLIC_RPCS[chainKey] || [])])) add(u);
  return pool;
}

function quorumProvider(url, chainKey) {
  // Pin the network so ethers skips its eth_chainId auto-detection round-trip.
  return new ethers.providers.JsonRpcProvider(url, { chainId: CHAINS[chainKey].id, name: chainKey });
}

function withTimeout(p, ms) {
  let t;
  const to = new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`timeout after ${ms}ms`)), ms); });
  return Promise.race([p, to]).finally(() => clearTimeout(t));
}

/** Pin a block ONCE for the whole run: a recent `finalized` block from the first
 *  responsive RPC (private first); fallback to `latest - CONFIRMATION_LAG` when the
 *  chain/RPC has no `finalized` tag. */
async function resolvePinnedBlock(pool, chainKey) {
  for (const url of pool) {
    const p = quorumProvider(url, chainKey);
    try {
      const blk = await withTimeout(p.send('eth_getBlockByNumber', ['finalized', false]), QUORUM_TIMEOUT_MS);
      if (blk && blk.number) { const n = parseInt(blk.number, 16); if (Number.isFinite(n) && n > 0) return n; }
    } catch (_) { /* fall through to latest-lag on the same url */ }
    try {
      const bn = await withTimeout(p.send('eth_blockNumber', []), QUORUM_TIMEOUT_MS);
      const n = parseInt(bn, 16) - CONFIRMATION_LAG;
      if (Number.isFinite(n) && n > 0) return n;
    } catch (_) { /* try the next url */ }
  }
  throw new Error('could not resolve a pinned block from any RPC (private + public all unreachable)');
}

/** Fetch `eth_getCode(address, @pinnedBlock)` across the pool, requiring agreement.
 *  - All non-empty valid responses MUST be byte-identical → else throw a DISAGREEMENT
 *    error (.disagreement set; caller aborts loudly).
 *  - Non-response / error / timeout / empty-when-others-non-empty are skipped; we pull
 *    the next provider until we reach `K` agreeing responses (or exhaust the pool).
 *  - Require at least `min` agreeing responses (counting the private one) → else throw
 *    (.insufficient set). Returns the agreed 0x-prefixed bytecode. */
async function quorumGetCode(chainKey, address, pool, K, min, blockNum) {
  const blockHex = '0x' + blockNum.toString(16);
  const target = Math.max(K, min);
  const queried = [];
  const valid = [];
  const failed = [];
  let agreed = null;
  const agreeing = () => (agreed !== null
    ? valid.filter((v) => v.norm === agreed).length
    : valid.filter((v) => v.norm === '').length);

  let i = 0;
  while (i < pool.length && agreeing() < target) {
    const need = Math.max(1, target - agreeing());
    const batch = pool.slice(i, i + need);
    i += batch.length;
    const settled = await Promise.all(batch.map(async (url) => {
      try {
        const code = await withTimeout(
          quorumProvider(url, chainKey).send('eth_getCode', [address, blockHex]), QUORUM_TIMEOUT_MS,
        );
        return { url, ok: true, code };
      } catch (e) {
        return { url, ok: false, err: (e && e.message) || String(e) };
      }
    }));
    for (const r of settled) {
      queried.push(r.url);
      if (!r.ok) { failed.push({ url: r.url, err: r.err }); continue; }
      valid.push({ url: r.url, norm: norm(r.code) });
    }
    const nonEmpty = valid.filter((v) => v.norm !== '');
    if (nonEmpty.length >= 1) {
      const first = nonEmpty[0].norm;
      if (nonEmpty.some((v) => v.norm !== first)) {
        const err = new Error('RPC disagreement on getCode');
        err.disagreement = valid.map((v) => ({
          url: v.url, keccak: keccak256('0x' + v.norm), empty: v.norm === '',
        }));
        throw err;
      }
      agreed = first;
    }
  }

  const m = agreeing();
  if (m < min) {
    const err = new Error(`insufficient RPC quorum (${m}/${min})`
      + (failed.length ? ` — ${failed.length} provider(s) failed: ${failed.slice(0, 5).map((f) => `${f.url} (${f.err})`).join('; ')}` : ''));
    err.insufficient = { got: m, min };
    throw err;
  }
  console.log(`✓ getCode quorum: ${m}/${queried.length} providers agree @ block ${blockNum}`);
  return agreed !== null ? '0x' + agreed : '0x';
}

/** Build a getCode fetcher: quorum (default) or single private/env RPC (--no-quorum).
 *  Caches per-address so the embed pre-pass + main verify loop don't double-query. */
async function makeCodeFetcher(args, chainKey, singleRpcUrl) {
  const cache = new Map();
  if (!args.quorum) {
    const provider = new ethers.providers.JsonRpcProvider(singleRpcUrl);
    console.log(`getCode        : single RPC (quorum OFF) → ${singleRpcUrl}`);
    return {
      async getCode(address) {
        if (cache.has(address)) return cache.get(address);
        const code = await provider.getCode(address);
        cache.set(address, code);
        return code;
      },
    };
  }
  const priv = args.rpcUrl || process.env[CHAINS[chainKey].envVar] || undefined;
  const pool = buildQuorumPool(chainKey, priv);
  if (pool.length === 0) throw new Error(`no RPCs available for quorum on ${chainKey}`);
  const blockNum = await resolvePinnedBlock(pool, chainKey);
  console.log(`getCode        : QUORUM across ${pool.length} RPC(s) (${priv ? 'private + ' : ''}public list), `
    + `K=${args.quorumK} min=${args.quorumMin} @ pinned block ${blockNum}`);
  return {
    async getCode(address) {
      if (cache.has(address)) return cache.get(address);
      const code = await quorumGetCode(chainKey, address, pool, args.quorumK, args.quorumMin, blockNum);
      cache.set(address, code);
      return code;
    },
  };
}

/** On a fetch failure: a DISAGREEMENT aborts the whole run LOUDLY (exit non-zero);
 *  any other quorum/RPC failure becomes a per-address error string for the caller. */
function handleFetchError(e, address) {
  if (e && e.disagreement) {
    console.error('\n⚠ RPC DISAGREEMENT — possible RPC compromise');
    console.error(`  ${address}: RPCs returned DIFFERENT bytecode at the pinned block —`);
    for (const d of e.disagreement) {
      console.error(`    ${d.url}  keccak=${d.keccak}${d.empty ? '  (EMPTY)' : ''}`);
    }
    console.error('  Aborting WITHOUT comparing bytecode (one honest RPC is not enough when another disagrees).');
    process.exit(3);
  }
  return (e && e.message) || String(e);
}

// ── Pure compare logic — ported VERBATIM from the CAO worker's bytecode-repro.ts ──
// (so the verdicts match exactly). keccak256 is the only injected dependency.

function norm(hex) {
  const h = (hex || '').trim();
  return (h.startsWith('0x') || h.startsWith('0X') ? h.slice(2) : h).toLowerCase();
}

function hashHex(bodyNoPrefix) {
  // keccak256 over the raw bytes; '' → keccak of empty.
  return keccak256('0x' + bodyNoPrefix);
}

/**
 * Strip the trailing CBOR metadata section solc appends to runtime bytecode.
 * Layout: `…<code><cbor metadata><2-byte big-endian length of the cbor section>`.
 * Read the last 2 bytes as the length, then strip `length+2` bytes — BUT only if
 * the byte at the computed metadata start is a CBOR map marker (0xa1/0xa2/0xa3).
 * Otherwise (e.g. `metadata.bytecodeHash:none` → no trailer, or a malformed
 * length) DON'T strip — return the input unchanged + `hadMetadata:false`
 * (loud: never strip real code on a bad guess).
 */
function stripMetadata(hex) {
  const h = norm(hex);
  if (h.length < 4) return { body: h, hadMetadata: false };
  const cborLenBytes = parseInt(h.slice(-4), 16);
  if (!Number.isFinite(cborLenBytes) || cborLenBytes <= 0) return { body: h, hadMetadata: false };
  const stripHexLen = (cborLenBytes + 2) * 2;
  if (stripHexLen >= h.length) return { body: h, hadMetadata: false };
  const metaStart = h.length - stripHexLen;
  const marker = h.slice(metaStart, metaStart + 2);
  if (marker !== 'a1' && marker !== 'a2' && marker !== 'a3') {
    return { body: h, hadMetadata: false }; // not a CBOR metadata map → don't strip
  }
  return { body: h.slice(0, metaStart), hadMetadata: true };
}

/**
 * Mask solc library-link placeholders (__$<34hex>$__) in the compiled bytecode,
 * and zero the corresponding 20-byte positions in the on-chain bytecode (which
 * has the real library addresses). Without this, keccak256 on the compiled hex
 * crashes (non-hex characters in the placeholder) and the comparison fails.
 */
function maskLibraryPlaceholders(onchainHex, compiledHex) {
  const re = /__\$[0-9a-fA-F]{34}\$__/g;
  let match;
  const positions = [];
  while ((match = re.exec(compiledHex)) !== null) {
    positions.push({ start: match.index, length: match[0].length }); // 40 hex chars
  }
  if (positions.length === 0) return { onchain: onchainHex, compiled: compiledHex, count: 0 };
  const onArr = onchainHex.split('');
  const coArr = compiledHex.split('');
  for (const { start, length } of positions) {
    for (let i = 0; i < length; i++) {
      if (start + i < coArr.length) coArr[start + i] = '0';
      if (start + i < onArr.length) onArr[start + i] = '0';
    }
  }
  return { onchain: onArr.join(''), compiled: coArr.join(''), count: positions.length };
}

/**
 * Zero the immutable byte ranges (solc `immutableReferences`) in a runtime
 * bytecode hex string. Immutables are written at construction, so they legitimately
 * differ between the compiled artifact (placeholders) and the on-chain code; mask
 * the SAME ranges in BOTH sides before comparing. Returns the masked hex + count.
 */
function maskImmutables(hex, refs) {
  const h = norm(hex);
  if (!refs || Object.keys(refs).length === 0) return { masked: h, count: 0 };
  const arr = h.split('');
  let count = 0;
  for (const key of Object.keys(refs)) {
    for (const r of refs[key] || []) {
      const startHex = r.start * 2;
      const lenHex = r.length * 2;
      for (let i = 0; i < lenHex; i++) {
        const idx = startHex + i;
        if (idx >= 0 && idx < arr.length) arr[idx] = '0';
      }
      count++;
    }
  }
  return { masked: arr.join(''), count };
}

/**
 * Classify on-chain vs compiled runtime bytecode. Precedence: full → partial →
 * mismatch.
 */
function classifyBytecode(onchain, compiled, immutableRefs) {
  let onFull = norm(onchain);
  let coFull = norm(compiled);

  // Mask library-link placeholders FIRST — __$<34hex>$__ is not valid hex, so
  // keccak256/arrayify would throw. The on-chain code has real addresses in those
  // positions; zero both sides so the rest of the comparison works.
  const libMask = maskLibraryPlaceholders(onFull, coFull);
  onFull = libMask.onchain;
  coFull = libMask.compiled;

  const onchainHash = hashHex(onFull);
  const compiledHash = hashHex(coFull);

  // Mask immutables (both sides, same ranges), then strip metadata (both sides).
  const onMask = maskImmutables(onFull, immutableRefs);
  const coMask = maskImmutables(coFull, immutableRefs);
  const onStrip = stripMetadata(onMask.masked);
  const coStrip = stripMetadata(coMask.masked);
  const onchainStrippedHash = hashHex(onStrip.body);
  const compiledStrippedHash = hashHex(coStrip.body);
  const metadataStripped = onStrip.hadMetadata || coStrip.hadMetadata;
  const immutableRefsMasked = Math.max(onMask.count, coMask.count);

  let status;
  if (onFull.length > 0 && onFull === coFull) status = 'full';
  else if (onStrip.body.length > 0 && onStrip.body === coStrip.body) status = 'partial';
  else status = 'mismatch';

  return {
    status,
    onchainHash,
    compiledHash,
    onchainStrippedHash,
    compiledStrippedHash,
    metadataStripped,
    immutableRefsMasked,
    libraryPlaceholdersMasked: libMask.count,
    onchainBytes: onFull.length / 2,
    compiledBytes: coFull.length / 2,
  };
}

// ── Artifact / build-info readers (no Hardhat runtime needed) ──────────────────

function walkArtifacts(dir, out) {
  out = out || [];
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (_) {
    return out;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walkArtifacts(full, out);
    else if (e.isFile() && e.name.endsWith('.json') && !e.name.endsWith('.dbg.json')) out.push(full);
  }
  return out;
}

function readArtifact(jsonPath) {
  const a = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  // Forge artifacts: deployedBytecode is { object: "0x..." }
  // Hardhat artifacts: deployedBytecode is "0x..."
  const bc = typeof a.deployedBytecode === 'string' ? a.deployedBytecode
    : (a.deployedBytecode && typeof a.deployedBytecode.object === 'string') ? a.deployedBytecode.object
    : null;
  if (!a || !bc) return null;
  // Forge uses `ast.absolutePath` for source name; Hardhat uses `sourceName`.
  const sourceName = a.sourceName
    || (a.ast && a.ast.absolutePath)
    || (a.id !== undefined && a.metadata && (() => {
      try {
        const meta = typeof a.metadata === 'string' ? JSON.parse(a.metadata) : a.metadata;
        const srcs = meta && meta.settings && meta.settings.compilationTarget;
        return srcs ? Object.keys(srcs)[0] : undefined;
      } catch (_) { return undefined; }
    })())
    || undefined;
  const contractName = a.contractName
    || (sourceName && path.basename(jsonPath, '.json'))
    || path.basename(jsonPath, '.json');
  return {
    jsonPath,
    sourceName: sourceName || path.basename(path.dirname(jsonPath)),
    contractName,
    deployedBytecode: bc,
  };
}

function findArtifactByName(name) {
  const searchDir = forgeOutDir || artifactsContractsDir;
  const matches = [];
  for (const f of walkArtifacts(searchDir)) {
    if (path.basename(f) === `${name}.json`) {
      const art = readArtifact(f);
      if (art && art.contractName === name) matches.push(art);
    }
  }
  if (matches.length === 0) {
    const compiler = forgeOutDir ? 'forge' : 'hardhat';
    throw new Error(`no compiled artifact named "${name}" under ${searchDir} (did you ${compiler === 'forge' ? 'forge build' : 'npx hardhat compile'}?)`);
  }
  if (matches.length > 1) {
    const list = matches.map((m) => m.sourceName).join(', ');
    throw new Error(`ambiguous contract name "${name}" — found in: ${list}. Disambiguate by deploying/compiling only one, or use scan mode.`);
  }
  return matches[0];
}

// Lazy + cached build-info loader (files can be >100MB; only parsed when a
// candidate actually needs its immutableReferences).
const _buildInfoCache = new Map();
function loadBuildInfo(biPath) {
  if (_buildInfoCache.has(biPath)) return _buildInfoCache.get(biPath);
  let parsed = null;
  try {
    parsed = JSON.parse(fs.readFileSync(biPath, 'utf8'));
  } catch (e) {
    console.warn(`  ! could not read build-info ${path.basename(biPath)} for immutables (${e.message}); proceeding without immutable mask`);
    parsed = null;
  }
  _buildInfoCache.set(biPath, parsed);
  return parsed;
}

function getImmutableRefs(art) {
  const dbgPath = art.jsonPath.replace(/\.json$/, '.dbg.json');
  if (!fs.existsSync(dbgPath)) return {};
  let dbg;
  try {
    dbg = JSON.parse(fs.readFileSync(dbgPath, 'utf8'));
  } catch (_) {
    return {};
  }
  const biPath = path.resolve(path.dirname(dbgPath), dbg.buildInfo);
  const bi = loadBuildInfo(biPath);
  const c = bi && bi.output && bi.output.contracts
    && bi.output.contracts[art.sourceName]
    && bi.output.contracts[art.sourceName][art.contractName];
  return (c && c.evm && c.evm.deployedBytecode && c.evm.deployedBytecode.immutableReferences) || {};
}

// Classify one (onchain, artifact) with LAZY immutables: only touch build-info if
// the cheap (no-mask) compare is a mismatch yet code lengths line up (→ likely an
// immutable diff).
function classifyArtifact(onchainCode, art) {
  let res = classifyBytecode(onchainCode, art.deployedBytecode, {});
  if (res.status === 'mismatch') {
    const onLen = stripMetadata(norm(onchainCode)).body.length;
    const coLen = stripMetadata(norm(art.deployedBytecode)).body.length;
    if (onLen > 0 && onLen === coLen) {
      const refs = getImmutableRefs(art);
      if (refs && Object.keys(refs).length > 0) {
        res = classifyBytecode(onchainCode, art.deployedBytecode, refs);
      }
    }
  }
  return res;
}

// Scan every compiled artifact; return the matching contract(s) (full/partial).
function scanIdentify(onchainCode) {
  const onStrip = stripMetadata(norm(onchainCode)).body;
  const onLen = onStrip.length;
  const candidates = [];
  const searchDir = forgeOutDir || artifactsContractsDir;
  for (const f of walkArtifacts(searchDir)) {
    let art;
    try {
      art = readArtifact(f);
    } catch (_) {
      continue;
    }
    if (!art) continue;
    // Mask library placeholders before length comparison (they are 40 hex chars
    // each, same as a real address, so length is preserved — but norm() on
    // unmasked __$...$__ would include non-hex chars in the body).
    const masked = maskLibraryPlaceholders('', norm(art.deployedBytecode));
    const bc = masked.compiled;
    if (bc.length === 0) continue; // interface / abstract / library-only → no runtime
    const artStrip = stripMetadata(bc).body;
    if (artStrip.length !== onLen) continue; // cheap necessary filter (mask preserves length)
    const res = classifyArtifact(onchainCode, art);
    if (res.status === 'full' || res.status === 'partial') {
      candidates.push({ art, res });
    }
  }
  return candidates;
}

/**
 * Resolve (matchArt, res) for one address: pinned --name artifact, else auto-scan.
 * Returns { matchArt, res, multiple } or { error } or { none:true }.
 */
function classifyAddress(onchainCode, namedArt) {
  if (namedArt) return { matchArt: namedArt, res: classifyArtifact(onchainCode, namedArt) };
  const candidates = scanIdentify(onchainCode);
  if (candidates.length === 0) return { none: true };
  if (candidates.length > 1) {
    candidates.sort((a, b) => (a.res.status === 'full' ? -1 : 1));
    return { matchArt: candidates[0].art, res: candidates[0].res, multiple: candidates };
  }
  return { matchArt: candidates[0].art, res: candidates[0].res };
}

// ── Isolated build + deploy-commit embedding ──────────────────────────────────
//
// All of this happens in a THROWAWAY git worktree so the user's working tree is
// never mutated. The flow mirrors what the deploy-box does at deploy time:
//   checkout <commit> → (embed the commit stamp) → compile.

function resolveCommitSha(ref) {
  try {
    return execFileSync('git', ['-C', REPO_ROOT, 'rev-parse', '--verify', `${ref}^{commit}`], { encoding: 'utf8' }).trim();
  } catch (_) {
    throw new Error(`--deploy-commit "${ref}" is not a commit reachable in this repo`);
  }
}

function headSha() {
  return execFileSync('git', ['-C', REPO_ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
}

function createBuildWorktree(commit) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dp-verify-'));
  fs.rmdirSync(dir); // `git worktree add` needs the path absent
  execFileSync('git', ['-C', REPO_ROOT, 'worktree', 'add', '--detach', dir, commit], { stdio: 'inherit' });
  return dir;
}

function removeWorktree(dir) {
  if (!dir) return;
  try {
    execFileSync('git', ['-C', REPO_ROOT, 'worktree', 'remove', '--force', dir], { stdio: 'ignore' });
  } catch (_) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_2) { /* best effort */ }
    try { execFileSync('git', ['-C', REPO_ROOT, 'worktree', 'prune'], { stdio: 'ignore' }); } catch (_3) {}
  }
}

/** Reuse the user checkout's installed deps in the fresh worktree (symlink, no
 *  reinstall). A fresh `git worktree` materializes submodule dirs as EMPTY
 *  mountpoints, so we force-replace them with a symlink to the populated upstream. */
function linkDeps(worktree) {
  for (const name of ['node_modules', 'lib']) {
    const src = path.join(REPO_ROOT, name);
    const dst = path.join(worktree, name);
    if (fs.existsSync(src) && (name === 'node_modules' || fs.readdirSync(src).length > 0)) {
      try {
        fs.rmSync(dst, { recursive: true, force: true });
        fs.symlinkSync(src, dst, 'dir');
      } catch (_) { /* fall back to install below */ }
    }
  }
  if (!fs.existsSync(path.join(worktree, 'node_modules'))) {
    if (fs.existsSync(path.join(worktree, 'yarn.lock'))) {
      console.log('  (no upstream node_modules to reuse — running `yarn install --frozen-lockfile`)');
      execFileSync('yarn', ['install', '--frozen-lockfile'], { cwd: worktree, stdio: 'inherit' });
    } else if (fs.existsSync(path.join(worktree, 'package-lock.json'))) {
      console.log('  (no upstream node_modules to reuse — running `npm ci`)');
      execFileSync('npm', ['ci'], { cwd: worktree, stdio: 'inherit' });
    }
  }
}

/** Best-effort: regenerate DeploymentChainConfig for the target chain, exactly
 *  like the deploy-box does before building. Non-fatal if unavailable. */
function runSelectChainConfig(worktree, chainKey) {
  const script = path.join(worktree, 'tools', 'scripts', 'select-chain-config.js');
  if (!fs.existsSync(script)) {
    console.log('  (skipping select-chain-config — script not present at this commit)');
    return;
  }
  try {
    execFileSync('node', ['tools/scripts/select-chain-config.js', chainKey], { cwd: worktree, stdio: 'inherit' });
  } catch (e) {
    console.log(`  (select-chain-config failed — continuing without it: ${e.message})`);
  }
}

function hardhatCompile(worktree) {
  execSync('npx hardhat compile', { cwd: worktree, stdio: 'inherit' });
}

function forgeBuild(worktree) {
  execSync('forge build', { cwd: worktree, stdio: 'inherit' });
}

function detectCompiler(root) {
  return fs.existsSync(path.join(root, 'foundry.toml'));
}

/**
 * Stamp `commit` into the deploy-commit comment of each given source file. Mirrors
 * tools/scripts/embed-commit-hash.js exactly:
 *   data.replace(/\/\/ Last deployed from commit: .*;/g, `// Last deployed from commit: <sha>;`)
 * (replaces an EXISTING stamp line; a file without one is left unchanged — same as
 * the deploy-time embed). Operates on worktree files only. Returns the files changed.
 */
function stampSourceFiles(worktree, sourceRelPaths, commit) {
  const re = /\/\/ Last deployed from commit: .*;/g;
  const line = `// Last deployed from commit: ${commit};`;
  const changed = [];
  for (const rel of sourceRelPaths) {
    const abs = path.join(worktree, rel);
    if (!fs.existsSync(abs)) { console.log(`  (cannot stamp ${rel} — not found in worktree)`); continue; }
    const before = fs.readFileSync(abs, 'utf8');
    const after = before.replace(re, line);
    if (after !== before) { fs.writeFileSync(abs, after, 'utf8'); changed.push(rel); }
    else console.log(`  (no "// Last deployed from commit:" line in ${rel} — nothing to stamp)`);
  }
  return changed;
}

// ── CLI ────────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  // embed + build default ON (deterministic "just run it"); opt out with --no-*.
  // quorum default ON (getCode cross-checked across N RPCs); opt out with --no-quorum.
  const out = {
    addresses: [], chain: null, name: null, rpcUrl: null, build: true, embed: true, deployCommit: null, help: false,
    quorum: true, quorumK: 4, quorumMin: 3, forge: null,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') out.help = true;
    else if (a === '--no-build' || a === '--no-compile') out.build = false;
    else if (a === '--no-embed') out.embed = false;
    else if (a === '--build' || a === '--embed') { /* explicit ON (default) — accepted as no-op */ }
    else if (a === '--forge') out.forge = true;
    else if (a === '--hardhat' || a === '--no-forge') out.forge = false;
    else if (a === '--deploy-commit') out.deployCommit = argv[++i];
    else if (a === '--chain') out.chain = argv[++i];
    else if (a === '--address' || a === '--addr') out.addresses.push(argv[++i]);
    else if (a === '--name') out.name = argv[++i];
    else if (a === '--rpc-url') out.rpcUrl = argv[++i];
    else if (a === '--cao-payload') out.caoPayload = argv[++i];
    else if (a === '--no-quorum') out.quorum = false;
    else if (a === '--rpc-quorum') {
      const n = parseInt(argv[++i], 10);
      if (!Number.isFinite(n) || n < 1) throw new Error('--rpc-quorum needs an integer >= 1');
      out.quorumK = n;
      if (n === 1) out.quorum = false; // 1 provider == single-RPC (no quorum)
    }
    else if (a === '--rpc-quorum-min') {
      const n = parseInt(argv[++i], 10);
      if (!Number.isFinite(n) || n < 1) throw new Error('--rpc-quorum-min needs an integer >= 1');
      out.quorumMin = n;
    }
    else if (a.startsWith('0x') && a.length === 42) out.addresses.push(a); // bare positional address
    else throw new Error(`unknown argument: ${a}`);
  }
  if (out.quorumMin > out.quorumK) out.quorumK = out.quorumMin; // gather at least `min` before checking
  return out;
}

function usage() {
  console.log(`
verify-onchain-bytecode.js — self-contained on-chain runtime-bytecode verifier (Hardhat)

  DETERMINISTIC by default: checks out HEAD into an isolated throwaway worktree,
  embeds the commit stamp, runs a CLEAN \`npx hardhat compile\` there, reads the
  compiled runtime, fetches the on-chain runtime via ethers (eth_getCode), strips
  CBOR metadata + masks solc immutables on both sides, and prints full / partial /
  mismatch per address. No AWS, no block-explorer, no secrets required. Your
  working tree is never touched.

USAGE
  node tools/scripts/verify-onchain-bytecode.js --chain <arbitrum|avalanche> \\
       --address 0x... [--address 0x...] [--name <ContractName>] \\
       [--deploy-commit <sha>] [--no-embed] [--no-build] [--rpc-url <url>]

OPTIONS
  --chain <c>            arbitrum (arb) | avalanche (avax). Picks default RPC + env var.
  --address <a>          Deployed address to verify (repeatable). Bare 0x… positionals also work.
  --name <Name>          Verify every address against this contract artifact. Omit to AUTO-SCAN.
  --deploy-commit <sha>  Build+stamp this commit instead of HEAD (verify a contract deployed
                         from a different commit). Must be reachable in this repo.
  --no-embed             Do NOT stamp the deploy commit (for pre-embed deployments whose on-chain
                         stamp is empty \`;\`). You still get partial (executable-verified) at worst.
  --no-build             Skip the clean isolated compile; read EXISTING artifacts/ (fast path).
                         Implies --no-embed. (alias: --no-compile)
  --rpc-url <url>        RPC override. Else $ARBITRUM_RPC_URL / $AVALANCHE_RPC_URL, else public.
                         (Also the PRIVATE member of the getCode quorum.)
  --rpc-quorum <N>       Cross-check eth_getCode across N independent RPCs (private + random
                         public), all pinned to one finalized block; ALL must agree byte-for-byte
                         or it aborts loudly ("⚠ RPC DISAGREEMENT"). Defends against a compromised
                         RPC feeding fake bytecode. (default 4)
  --rpc-quorum-min <N>   Minimum agreeing RPCs required, incl. the private one. (default 3)
  --no-quorum            Single private/env RPC only (== --rpc-quorum 1); faster, no defense.
  --cao-payload <file>   Read a CAO Dashboard verification JSON and verify every contract
                         in it that belongs to this repo (arbitrum / avalanche). Groups by
                         deploy-commit, builds+verifies each group, prints a summary table.

EXIT CODE  non-zero if ANY address is mismatch or errors, or 3 on RPC DISAGREEMENT.
           (full/partial → 0)
`);
}

// What, exactly, differs on a `partial` (the executable code is identical by
// definition of partial; only these non-executable parts vary).
function partialDiffNoun(res) {
  const hasImm = res.immutableRefsMasked > 0;
  const hasMeta = res.metadataStripped;
  if (hasImm && hasMeta) return 'appended metadata trailer and construction-time immutable values';
  if (hasImm) return 'construction-time immutable values (set at deploy, masked on both sides)';
  return 'appended metadata trailer';
}

// One-line "why this is still a genuine match" hint for a `partial`.
function partialHint(res) {
  const COMMIT_STAMP =
    'The metadata differs because the on-chain "// Last deployed from commit:" stamp '
    + 'differs from yours (e.g. --no-embed, or a deploy made before the box embedded the commit). '
    + 'The stamp is a comment — it changes metadata, never bytecode.';
  if (res.immutableRefsMasked > 0) {
    // Immutables are written at construction → they legitimately differ from the
    // compiled placeholders; we mask the same ranges on both sides before comparing.
    let s = 'This is a genuine code match. Immutable values are written at construction time, '
      + 'so they always differ from the compiled placeholders (masked on both sides).';
    if (res.metadataStripped) s += ' ' + COMMIT_STAMP;
    return s + ' For a cosmetic FULL match, pass --deploy-commit <deployCommit> (see README).';
  }
  return 'This is a genuine code match. ' + COMMIT_STAMP
    + ' For a cosmetic FULL match, pass --deploy-commit <deployCommit> (see README).';
}

// ── CAO Dashboard payload mode ─────────────────────────────────────────────
// Reads the verification JSON exported by the CAO Dashboard's "↓ verify JSON"
// button, filters to contracts belonging to this repo (arbitrum / avalanche),
// groups by (chain, commit), and re-invokes THIS script per contract with the
// equivalent CLI flags. Prints a combined summary table at the end.

const CAO_SUPPORTED_CHAINS = new Set(['arbitrum', 'avalanche']);

function runCaoPayload(opts) {
  const jsonPath = opts.caoPayload;
  if (!fs.existsSync(jsonPath)) {
    console.error(`error: file not found: ${jsonPath}`);
    return 2;
  }
  let payload;
  try {
    payload = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  } catch (e) {
    console.error(`error: invalid JSON: ${e.message}`);
    return 2;
  }
  if (!payload.contracts || !Array.isArray(payload.contracts) || payload.contracts.length === 0) {
    console.error('error: JSON has no "contracts" array (or it is empty).');
    return 2;
  }

  const mine = payload.contracts.filter((c) => CAO_SUPPORTED_CHAINS.has(c.chain));
  if (mine.length === 0) {
    console.log('No contracts for this repo (arbitrum / avalanche) found in the JSON.');
    console.log(`The file contains ${payload.contracts.length} contract(s) for other chains.`);
    return 0;
  }

  console.log('verify-onchain-bytecode — CAO Dashboard batch verification (dp-contracts)');
  console.log(`  JSON: ${jsonPath}`);
  console.log(`  exported: ${payload.exportedAt || '(unknown)'}`);
  console.log(`  contracts for this repo: ${mine.length} / ${payload.contracts.length}`);

  // Group by (chain, commit) — each group gets ONE self-invocation (own worktree+build).
  const groups = new Map();
  for (const c of mine) {
    const key = `${c.chain}::${c.commit}`;
    if (!groups.has(key)) groups.set(key, { chain: c.chain, commit: c.commit, contracts: [] });
    groups.get(key).contracts.push(c);
  }

  let anyFailed = false;
  const results = [];

  for (const [, group] of groups) {
    const { chain, commit, contracts } = group;
    console.log(`\n${'─'.repeat(72)}`);
    console.log(`chain: ${chain}    commit: ${commit}`);
    console.log(`contracts: ${contracts.map((c) => c.name).join(', ')}`);
    console.log('─'.repeat(72));

    // This script's --name accepts only a single value, so verify one contract at
    // a time. All contracts in a group share the same commit, so the worktree+build
    // is redone per contract (the script handles its own worktree lifecycle).
    for (const c of contracts) {
      const args = ['--chain', chain, '--deploy-commit', commit, '--address', c.address, '--name', c.name];
      if (opts.rpcUrl) args.push('--rpc-url', opts.rpcUrl);
      if (!opts.quorum) args.push('--no-quorum');
      else {
        if (opts.quorumK !== 4) args.push('--rpc-quorum', String(opts.quorumK));
        if (opts.quorumMin !== 3) args.push('--rpc-quorum-min', String(opts.quorumMin));
      }

      try {
        const output = execFileSync('node', [__filename, ...args], {
          cwd: REPO_ROOT,
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'inherit'],
          timeout: 15 * 60 * 1000,
        });
        process.stdout.write(output);

        const addrLower = c.address.toLowerCase();
        const statusMatch = output.match(new RegExp(addrLower + '[\\s\\S]*?status\\s*:\\s*(\\w+)', 'i'));
        const verdict = statusMatch ? statusMatch[1] : 'unknown';
        results.push({ ...c, localVerdict: verdict });
        if (verdict === 'mismatch' || verdict === 'unknown') anyFailed = true;
      } catch (e) {
        if (e.stdout) process.stdout.write(e.stdout);
        anyFailed = true;
        results.push({ ...c, localVerdict: 'error' });
      }
    }
  }

  // ── Summary table ────────────────────────────────────────────────────────
  console.log('\n\n' + '═'.repeat(100));
  console.log('  CAO VERIFICATION SUMMARY');
  console.log('═'.repeat(100));

  const nameW = Math.max(12, ...results.map((r) => r.name.length));
  const addrW = 42;
  const chainW = 10;
  const boxW = 10;
  const localW = 10;
  const pad = (s, w) => (s + ' '.repeat(w)).slice(0, w);
  const header = `  ${pad('CONTRACT', nameW)}  ${pad('ADDRESS', addrW)}  ${pad('CHAIN', chainW)}  ${pad('BOX', boxW)}  ${pad('LOCAL', localW)}`;
  console.log(header);
  console.log('  ' + '─'.repeat(header.length - 2));

  for (const r of results) {
    const boxIcon = r.boxVerdict === 'full' || r.boxVerdict === 'partial' ? '✅' : '❌';
    const localIcon =
      r.localVerdict === 'full' || r.localVerdict === 'partial' ? '✅'
        : r.localVerdict === 'error' || r.localVerdict === 'mismatch' ? '❌' : '❓';
    console.log(`  ${pad(r.name, nameW)}  ${pad(r.address, addrW)}  ${pad(r.chain, chainW)}  ${boxIcon} ${pad(r.boxVerdict, boxW - 3)}  ${localIcon} ${pad(r.localVerdict, localW - 3)}`);
  }

  console.log('═'.repeat(100));
  const passed = results.filter((r) => r.localVerdict === 'full' || r.localVerdict === 'partial').length;
  const failed = results.length - passed;
  if (failed === 0) {
    console.log(`\n✅ ALL ${passed} contract(s) independently verified.`);
  } else {
    console.log(`\n❌ ${failed} contract(s) FAILED verification. ${passed} passed.`);
  }
  console.log('');
  return anyFailed ? 1 : 0;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return 0;
  }

  // ── CAO Dashboard payload mode ──────────────────────────────────────────────
  if (args.caoPayload) {
    return runCaoPayload(args);
  }

  if (!args.chain) throw new Error('--chain <arbitrum|avalanche> is required');
  const chainKey = CHAIN_ALIASES[args.chain.toLowerCase()];
  if (!chainKey) throw new Error(`unsupported --chain "${args.chain}" (use arbitrum|avalanche)`);
  const chain = CHAINS[chainKey];
  if (args.addresses.length === 0) throw new Error('at least one --address is required');

  // --no-build means "read existing artifacts": embedding can't apply (it requires
  // a rebuild), so force it off.
  if (!args.build && args.embed) {
    if (args.deployCommit) console.log('note: --no-build disables --deploy-commit embedding (cannot re-stamp without rebuilding).');
    args.embed = false;
  }

  const rpcUrl = args.rpcUrl || process.env[chain.envVar] || chain.publicRpc;
  const rpcSource = args.rpcUrl ? '--rpc-url' : (process.env[chain.envVar] ? `$${chain.envVar}` : 'public default');

  // Resolve compiler: --forge / --hardhat override; else auto-detect foundry.toml.
  const isForge = args.forge === true ? true
    : args.forge === false ? false
    : detectCompiler(REPO_ROOT);
  if (isForge) {
    useForge = true;
  }

  console.log(`chain          : ${chainKey} (${chain.id})`);
  console.log(`rpc            : ${rpcUrl}  [${rpcSource}]`);
  console.log(`compiler       : ${isForge ? 'forge (Foundry)' : 'hardhat'}${args.forge === null ? ' (auto-detected)' : ''}`);
  console.log(`mode           : ${args.name ? `--name ${args.name}` : 'auto-scan artifacts'}`);
  console.log(`addresses      : ${args.addresses.length}`);

  const fetcher = await makeCodeFetcher(args, chainKey, rpcUrl);
  let worktree = null;
  let anyBad = false;

  try {
    // 1) Build: clean isolated compile (default) or reuse existing artifacts (--no-build).
    if (args.build) {
      const commit = args.deployCommit ? resolveCommitSha(args.deployCommit) : headSha();
      const compilerLabel = isForge ? 'forge build' : 'npx hardhat compile';
      console.log(`build          : clean \`${compilerLabel}\` of ${commit}${args.embed ? ' (commit stamp embedded)' : ' (--no-embed)'} in an isolated worktree`);
      worktree = createBuildWorktree(commit);
      linkDeps(worktree);
      runSelectChainConfig(worktree, chainKey);

      if (isForge) {
        forgeOutDir = path.join(worktree, 'out');
      } else {
        artifactsContractsDir = path.join(worktree, 'artifacts', 'contracts');
      }

      // ── Pre-stamp: when --name is known, stamp BEFORE the first compile (exactly
      //    like the deploy box does). Avoids the Hardhat/forge incremental-cache issue
      //    where a post-compile stamp (comment-only change) may not trigger a metadata-
      //    hash update on recompilation. ──
      let preStamped = false;
      if (args.embed && args.name) {
        const candidates = [
          `contracts/${args.name}.sol`,
          `contracts/facets/${args.name}.sol`,
        ];
        // Also search chain-specific subdirectories under contracts/facets/
        for (const sub of ['arbitrum', 'avalanche', 'base']) {
          candidates.push(`contracts/facets/${sub}/${args.name}.sol`);
        }
        const toStamp = candidates.filter((rel) => fs.existsSync(path.join(worktree, rel)));
        if (toStamp.length > 0) {
          console.log(`pre-stamp      : embedding commit into ${toStamp.join(', ')}`);
          stampSourceFiles(worktree, toStamp, commit);
          preStamped = true;
        }
      }

      console.log(`\ncompiling repo : ${compilerLabel}${preStamped ? '' : ' (pass 1)'} ...`);
      if (isForge) {
        forgeBuild(worktree);
      } else {
        hardhatCompile(worktree);
      }

      if (args.embed && !preStamped) {
        // Fallback 2-pass: identify which source files need stamping from pass 1
        // artifacts, stamp, then delete the cache to force full recompilation.
        const toStamp = new Set();
        const namedArt = args.name ? findArtifactByName(args.name) : null;
        for (const address of args.addresses) {
          let code;
          try { code = await fetcher.getCode(address); } catch (e) { handleFetchError(e, address); continue; }
          if (!code || code === '0x') continue;
          const r = classifyAddress(code, namedArt);
          if (r && r.res && r.res.status === 'partial' && r.matchArt && r.matchArt.sourceName) toStamp.add(r.matchArt.sourceName);
        }
        if (toStamp.size > 0) {
          console.log(`embedding      : commit into ${toStamp.size} source file(s): ${[...toStamp].join(', ')}`);
          const changed = stampSourceFiles(worktree, [...toStamp], commit);
          if (changed.length > 0) {
            if (isForge) {
              const forgeCache = path.join(worktree, 'cache_forge');
              if (fs.existsSync(forgeCache)) fs.rmSync(forgeCache, { recursive: true, force: true });
              console.log('\ncompiling repo : forge build (pass 2, re-stamped, cache cleared) ...');
              forgeBuild(worktree);
            } else {
              const hhCache = path.join(worktree, 'cache');
              if (fs.existsSync(hhCache)) fs.rmSync(hhCache, { recursive: true, force: true });
              console.log('\ncompiling repo : npx hardhat compile (pass 2, re-stamped, cache cleared) ...');
              hardhatCompile(worktree);
            }
          }
        } else {
          console.log('embedding      : nothing to re-stamp (addresses already full, or unidentified/mismatch)');
        }
      }
    } else {
      // --no-build: read existing artifacts from the user checkout.
      if (isForge) {
        forgeOutDir = path.join(REPO_ROOT, 'out');
        console.log(`\ncompiling repo : SKIPPED (--no-build) — reading existing forge output at ${forgeOutDir}`);
        if (!fs.existsSync(forgeOutDir)) {
          throw new Error(`no forge output at ${forgeOutDir} — run \`forge build\` first, or drop --no-build`);
        }
      } else {
        console.log('\ncompiling repo : SKIPPED (--no-build) — reading existing artifacts/');
        if (!fs.existsSync(artifactsContractsDir)) {
          throw new Error(`no artifacts at ${artifactsContractsDir} — run \`npx hardhat compile\` first, or drop --no-build`);
        }
      }
    }

    // 2) Resolve the named artifact once (if --name), then verify each address.
    const namedArt = args.name ? findArtifactByName(args.name) : null;

    for (const address of args.addresses) {
      console.log('\n' + '─'.repeat(78));
      console.log(`address        : ${address}`);
      let onchainCode;
      try {
        onchainCode = await fetcher.getCode(address);
      } catch (e) {
        const detail = handleFetchError(e, address); // may process.exit(3) on DISAGREEMENT
        console.log(`status         : ERROR (getCode failed: ${detail})`);
        anyBad = true;
        continue;
      }
      if (!onchainCode || onchainCode === '0x') {
        console.log('status         : ERROR (no code at address — EOA or wrong chain?)');
        anyBad = true;
        continue;
      }
      console.log(`onchain bytes  : ${(norm(onchainCode).length) / 2}`);

      const m = classifyAddress(onchainCode, namedArt);
      if (m.none) {
        console.log('matched repo   : (none — no compiled contract matches this runtime)');
        console.log('status         : mismatch (deployed code not reproducible from this repo)');
        anyBad = true;
        continue;
      }
      if (m.multiple) {
        console.log(`matched repo   : MULTIPLE (${m.multiple.map((c) => `${c.art.sourceName}:${c.art.contractName} [${c.res.status}]`).join(' | ')})`);
      }
      const matchArt = m.matchArt;
      const res = m.res;

      console.log(`matched repo   : ${matchArt.sourceName}:${matchArt.contractName}`);
      console.log(`compiled bytes : ${res.compiledBytes}`);
      console.log(`metadataStripped : ${res.metadataStripped}   immutableRefsMasked : ${res.immutableRefsMasked}   libraryPlaceholdersMasked : ${res.libraryPlaceholdersMasked}`);
      console.log(`onchain  hash (full)     : ${res.onchainHash}`);
      console.log(`compiled hash (full)     : ${res.compiledHash}`);
      console.log(`onchain  hash (stripped) : ${res.onchainStrippedHash}`);
      console.log(`compiled hash (stripped) : ${res.compiledStrippedHash}`);
      // Verdict line — make `partial` read unambiguously as a PASS.
      if (res.status === 'full') {
        console.log('status         : full — ✅ FULL MATCH (incl. metadata) — on-chain runtime == compiled runtime, byte-for-byte.');
      } else if (res.status === 'partial') {
        console.log(`status         : partial — ✅ EXECUTABLE CODE VERIFIED (runtime byte-for-byte identical); only the ${partialDiffNoun(res)} differs.`);
        console.log(`                 ↳ ${partialHint(res)}`);
      } else {
        console.log('status         : mismatch — ❌ FAILED — bytecode differs even after metadata-strip + immutable-mask (deployed code is NOT this repo).');
        anyBad = true;
      }
    }
  } finally {
    removeWorktree(worktree);
  }

  console.log('\n' + '═'.repeat(78));
  if (anyBad) {
    console.log('RESULT: ❌ at least one MISMATCH / ERROR — deployed code does NOT match this repo.');
  } else {
    console.log('RESULT: ✅ all addresses verified (full or partial). '
      + 'partial = executable runtime byte-for-byte identical; only metadata/immutables differ — a genuine code match.');
  }
  return anyBad ? 1 : 0;
}

if (require.main === module) {
  main()
    .then((code) => process.exit(code))
    .catch((e) => {
      console.error(`\nFATAL: ${e.message}`);
      process.exit(2);
    });
}

// Exported for testing (quorum logic is independently verifiable without a compile).
module.exports = {
  norm, classifyBytecode, stripMetadata, maskImmutables, maskLibraryPlaceholders,
  buildQuorumPool, quorumProvider, resolvePinnedBlock, quorumGetCode, makeCodeFetcher,
};
