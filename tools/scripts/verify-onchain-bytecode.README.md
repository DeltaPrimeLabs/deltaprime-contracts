# `verify-onchain-bytecode.js` — self-contained on-chain bytecode verifier

Proves that a **deployed** contract's runtime bytecode is reproducible from **this
repo's own source** — no AWS, no block-explorer API, no external service. The
Hardhat analog of the degen-prime (Foundry) on-chain verifier.

**Deterministic by default — just run it.** With no flags it (1) checks out the
repo's current `HEAD` into an **isolated throwaway git worktree** (your working
tree is never touched), (2) **embeds that commit** into the
`// Last deployed from commit: <sha>;` stamp (a comment — it changes the appended
metadata hash, never the executable bytecode), (3) does a **clean
`npx hardhat compile`** there, and (4) byte-compares against chain. So the verdict
never depends on a stale local `artifacts/`, and — once the deploy-box embeds the
deploy commit at deploy time (in progress) — reproduces a clean `full` match.

```bash
# Zero-flag deterministic verify (auto-identify, public RPC):
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum --address 0xabc...

# Verify a contract deployed from a SPECIFIC commit → deterministic `full`:
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum \
     --deploy-commit <deployCommit> --address 0xabc...
```

## What it does

Given a chain (`arbitrum` / `avalanche`) and one or more deployed addresses:

1. **Builds the chosen commit** — clean `npx hardhat compile` in the isolated
   worktree (or, with `--no-build`, reads the existing `artifacts/`).
2. **Reads the compiled runtime** from the Hardhat artifact
   (`artifacts/contracts/<path>/<File>.sol/<Name>.json` → `.deployedBytecode`).
3. **Fetches the on-chain runtime** via ethers `provider.getCode(addr)` (`eth_getCode`).
4. **Compares metadata-aware** — strips the trailing CBOR metadata section and
   masks solc `immutableReferences` (read from Hardhat `build-info`) on **both**
   sides, then keccak-compares.
5. **Prints a verdict per address** and exits non-zero if any is `mismatch`/error.

### Flags

| Flag | Effect |
|---|---|
| *(none)* | Deterministic default: clean compile of `HEAD` in an isolated worktree, commit stamp embedded, byte-compare. |
| `--deploy-commit <sha>` | Build + stamp this commit instead of `HEAD` (verify a contract deployed from a different commit). |
| `--no-embed` | Skip stamping. Use for contracts deployed **before** the box began embedding (on-chain stamp is empty `;`, so embedding would mismatch). You still get `partial`/`full`. |
| `--no-build` | Skip the clean isolated compile; read the **existing** `artifacts/` (fast path; you must `npx hardhat compile` yourself first). Implies `--no-embed`. (alias: `--no-compile`) |
| `--name <C>` | Verify every address against this contract artifact. Omit to auto-scan. |
| `--address <a>` | Deployed address (repeatable; bare `0x…` positionals also work). |
| `--rpc-url <url>` | RPC override. |
| `--chain <arbitrum\|avalanche>` | Picks default RPC + env var (`arb`/`avax` aliases accepted). |

> **Prerequisites:** the repo + Hardhat (`npx hardhat`, already a dep) + an RPC
> (public is fine). No AWS, no explorer API key. The isolated build reuses your
> checkout's `node_modules` via symlink (no reinstall).

### Verdicts (identical classification to the CAO worker `bytecode-repro` plugin)

| Verdict | Meaning |
|---|---|
| `full` | Compiled runtime === on-chain runtime, **byte-for-byte** (incl. metadata). |
| `partial` | **PASS.** The executable (runtime) code is **byte-for-byte identical** after stripping the appended CBOR metadata trailer + masking solc immutables; only that non-executable trailer (and/or construction-time immutables) differs — a genuine code match. |
| `mismatch` | Differ even after strip+mask → LOUD **FAIL** (deployed code is not this repo). |

## Understanding the result

**For the everyday question — "is the deployed code the reviewed code?" — a `partial`
with matching stripped hashes is the definitive YES.** The executable logic on chain is
byte-for-byte identical to what you compiled; nothing functional differs.

A `partial` (rather than `full`) means the on-chain `// Last deployed from commit:` stamp
differs from the one you embedded. The metadata trailer is a hash of the source inputs, so
anything that changes the source text — even that comment — changes it; but the stamp is a
**comment**, so it alters the metadata hash and **never** the bytecode. The two common causes:

- The contract was **deployed before the box started embedding** the commit (its on-chain
  stamp is empty `;`). Re-run with **`--no-embed`** — that builds without a stamp, so a
  contract deployed from this exact source tree comes back `full`.
- You verified the wrong commit. Pass **`--deploy-commit <deployCommit>`** with the commit
  the contract was actually deployed from:

```bash
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum \
     --deploy-commit <deployCommit> --address <address>
```

(Immutables can also produce `partial` — those are values written at construction time, so
they legitimately differ from the compiled placeholders; the script masks the same ranges on
both sides before comparing.)

> Deterministic `full` for a freshly-deployed contract also depends on the **deploy-box
> embedding the commit at deploy time** (in progress). For pre-embed deployments, use
> `--no-embed` and expect `partial` (executable-verified) or `full` when built from the
> exact deploy commit.

`mismatch` is the only failing verdict (non-zero exit): the code differs **even after**
metadata-strip + immutable-mask, so the deployed bytecode is genuinely not this source.

## Identifying the contract behind an address

- `--name <ContractName>` — verify every address against that one artifact.
- *(omit `--name`)* — **auto-scan** every compiled artifact and identify the one
  whose metadata-stripped runtime matches the on-chain code (no name needed). If
  several contracts share identical bytecode (e.g. the many `*PoolTUP` /
  `*IndexTUP` proxies, which are all the same proxy template), all are listed.

## Dependencies — NONE beyond this repo + an RPC

Requires only `fs`, `path`, `child_process`, and `ethers` (already a repo dep).
**No AWS, no Etherscan/Snowtrace/Arbiscan key, no external service.** RPC URL comes
from `--rpc-url`, else `$ARBITRUM_RPC_URL` / `$AVALANCHE_RPC_URL`, else a public
default (so it runs with zero secrets configured).

## Usage

```bash
# Zero-flag deterministic verify (auto-identify, public RPC, isolated clean build + embed):
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum --address 0xabc...

# Verify a contract deployed from a specific commit → deterministic `full`:
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum \
     --deploy-commit <deployCommit> --address 0xabc...

# Pre-embed deployment (on-chain stamp empty) — skip stamping:
node tools/scripts/verify-onchain-bytecode.js --chain avalanche --no-embed --address 0xdef...

# Fast path: reuse existing local artifacts/ (no isolation, no stamp):
npx hardhat compile
node tools/scripts/verify-onchain-bytecode.js --chain avalanche \
     --name WavaxDepositIndex --address 0xdef... \
     --rpc-url https://api.avax.network/ext/bc/C/rpc --no-build

# Multiple addresses at once (bare 0x… positionals also accepted):
node tools/scripts/verify-onchain-bytecode.js --chain arbitrum 0xaaa... 0xbbb...
```

> Heavy `build-info` JSON (the immutables source) is only parsed when a contract
> actually has immutables. If you hit it on a large project, run with
> `node --max-old-space-size=8192 tools/scripts/verify-onchain-bytecode.js …`.

## Example (verified live against Arbitrum)

```
$ node tools/scripts/verify-onchain-bytecode.js --chain arbitrum \
       --name WethDepositIndex --address 0xe47a879D96f30613122EB4D780Cb60154c24d051
...
compiling repo : npx hardhat compile ...
Compiled 1 Solidity file successfully

address        : 0xe47a879D96f30613122EB4D780Cb60154c24d051
matched repo   : contracts/deployment/arbitrum/WethDepositIndex.sol:WethDepositIndex
metadataStripped : true   immutableRefsMasked : 0
onchain  hash (full)     : 0xb5f24ef969afd6ed7b42cfb1246f08c5bd9fa20d4fbd3f86bb34612ea93903f2
compiled hash (full)     : 0xb5f24ef969afd6ed7b42cfb1246f08c5bd9fa20d4fbd3f86bb34612ea93903f2
status         : FULL
```
