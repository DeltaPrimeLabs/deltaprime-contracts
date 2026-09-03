# Gnosis Safe position-unwind toolkit

Four files (each can live in its own gist):

| File | Role |
|------|------|
| `unwind-gnosis-safe.js` | **Generator** — builds the Safe Transaction Builder batch JSON |
| `verify-safe-batch.js`  | **Verifier (JSON)** — checks the batch JSON file |
| `verify-safe-tx.js`     | **Verifier (on-chain)** — checks the actual Safe tx you sign (paste the link) |
| `unwind-gnosis-README.md` | this file |

Requires **ethers v5** and **Node 18+** (uses global `fetch`). Run with
`NODE_PATH=<repo>/node_modules` if ethers isn't resolvable from cwd.

---

## What it does

Generates one Safe batch that unwinds the Safe's DeFi positions:

- **GMX V2** GM / GM+ markets → `ExchangeRouter.multicall(createWithdrawal)` (async; underlying returns via keeper)
- **GMX GLV** vaults → `GlvRouter.multicall(createGlvWithdrawal)`
- **GMX V1 GLP** → `RewardRouterV2.unstakeAndRedeemGlp` (synchronous → USDC)
- **BENQI sAVAX** (Avalanche) → DEX swap sAVAX→USDC (avoids the 15-day native-unstake)
- **Yield Yak** vaults (Avalanche) → `YakStrategy.withdraw` (the GMX-fsGLP vault chains into the GLP redeem)

Safety baked into the output:
- **Execution fee** read live from the GMX DataStore (GasUtils formula, 1.5× headroom); GMX refunds the surplus to the Safe. `totalValue` = Σ inner tx values so the multiSend is funded.
- **Slippage floors** (`minOut`, default 2%): GM/GM+/GLV from the GMX SyntheticsReader, sAVAX from the DEX quote, GLP from GlpManager NAV. Yield Yak withdrawals are 1:1 (no slippage).
- **Dust filter** (default $1): priced positions worth less are skipped.

### Generate

```
node unwind-gnosis-safe.js [avax|arb|all] [flags]

  --no-glp         skip the GLP redeem (default: ON; redeems direct fsGLP + YY GLP → USDC)
  --no-savax       skip the BENQI sAVAX → USDC swap
  --no-yieldyak    skip Yield Yak withdrawals (alias --no-yak)
  --dust=<usd>     dust threshold (default 1); --dust=0 / --include-dust disables
  --allow-no-min   emit positions even if a min-out can't be computed (NO protection)
```

Writes `unwind-gnosis-<chain>.json`. Import it into the Safe Transaction Builder.

---

## Two-party verification (the important part)

**Principle:** the co-signer verifies the *output* independently of the *generator*.
What you actually sign is the Safe tx hash over `(to, value, data, operation, …)`; if
that's validated against on-chain reality + a fixed allowlist, a tampered generator
**or** a tampered JSON can't hurt you. Three independent legs, none trusting the generator:

**Per batch:**

1. **On-chain bytes** — co-signer runs `verify-safe-tx.js` on the Safe app link:
   ```
   node verify-safe-tx.js "https://app.safe.global/transactions/tx?safe=avax:0x…&id=multisig_0x…_0x<safeTxHash>"
   # or:  node verify-safe-tx.js avax 0x<safeTxHash>
   ```
   It fetches the proposed tx, **recomputes the safeTxHash** from the params (so the
   service can't show benign params behind a different hash — mismatch ⇒ refuse to sign),
   confirms the `MultiSendCallOnly` wrapper, decodes the inner txs, runs all invariants,
   and prints a **structural fingerprint**. Must end `✅ All CRITICAL invariants passed`.

2. **Reproducibility** — independently regenerate and compare the **structural fingerprint**:
   ```
   node unwind-gnosis-safe.js <chain>            # prints "Structural fingerprint : …"
   node verify-safe-batch.js unwind-gnosis-<chain>.json   # prints the same value
   ```
   The fingerprint from step 1 (on-chain bytes), the regenerated generator, and the JSON
   verifier **must all be equal**. A match means the bytes you're signing are the genuine
   generator output, not hand-edited targets/recipients.

3. **Behavior** — one glance at a **Tenderly** simulation: it succeeds, net asset changes
   are sane (only expected tokens leave, USDC/AVAX arrive), and — critically — the
   **State-diff shows NO change to the Safe's own storage** (owners / threshold / modules /
   guard / fallback handler). You do **not** need to eyeball each tx; steps 1–2 cover that.

### The structural fingerprint

A sha256 over only the deterministic, security-relevant shape — chain, Safe, and per-tx
`{target, method, recipient, spender, token/path, order}` — **excluding** live amounts,
fees, `minOut`s, and the deadline. So:

- **Stable across runs** → two signers compare one string instead of diffing JSON.
- The **raw-file hash is NOT comparable** (every run has fresh fees/quotes/deadline);
  the verifiers print it only so you don't mistakenly compare it.

All three scripts produce the identical fingerprint for the same batch.

---

## Trust anchors — pin these once

- **Pin all four files by content hash**, not just gist URLs (gists are owner-mutable):
  ```
  shasum -a 256 unwind-gnosis-safe.js verify-safe-batch.js verify-safe-tx.js unwind-gnosis-README.md
  ```
  Record the hashes; re-check before each use. (Tip: gist *revision* permalinks are also immutable.)
- **Review the `CHAINS` allowlist** in both verifiers (Safe address + known routers/spenders).
  That allowlist is the real trust root — an attacker's easiest move is to add their address
  to it, so confirm every entry against block explorers when you pin.

## What the verifiers catch (CRITICAL → do not sign)

- a recipient (withdrawal/swap/redeem receiver) ≠ the Safe
- **inside a GMX `multicall`**: any inner call that isn't `sendWnt`/`sendTokens`/
  `createWithdrawal`/`createGlvWithdrawal`; a `sendWnt`/`sendTokens` whose receiver
  isn't the GMX withdrawal vault (token-exfiltration vector); a `sendTokens` whose
  **token isn't the withdrawn market/glv**; >1 withdrawal, >1 sendTokens, a non-zero
  `callbackContract`; a **non-empty long/short swap path** (re-routes proceeds, and
  it's fingerprint-invisible); a `market`/`glv` not in the per-chain allowlist
- an `approve` whose spender isn't in the allowlist, whose **token isn't a position
  unwound in this same batch**, or whose amount is `MaxUint256` (all CRITICAL)
- a `Yak.withdraw` whose target isn't a known Yield Yak vault
- `minOut` / `minLong` / `minShort` == 0; GLP/swap **output token** not in the payout
  allowlist (one-sided GM/GLV `min=0` is a WARN naming the side)
- any inner tx targeting the Safe itself, or a Gnosis-Safe admin selector
  (`addOwner` / `changeThreshold` / `enableModule` / `setGuard` / …)
- a call target not in the allowlist; an unrecognised selector
- (JSON verifier) `Σ(tx.value)` ≠ the declared `totalValue`
- (on-chain verifier) safeTxHash doesn't reproduce; the `delegatecall` wrapper isn't
  **MultiSendCallOnly** — confirmed by *runtime-bytecode hash*, not just address, so
  non-canonical deployments (e.g. Avalanche's `0xA1dabEF…`) pass and a look-alike fails;
  **`gasPrice` ≠ 0 or `baseGas` ≠ 0** (the Safe pays `(gasUsed+baseGas)·gasPrice` native
  to the executor — a refund drain even with `refundReceiver`/`gasToken` zeroed), or
  `gasToken` / `refundReceiver` ≠ 0. (The inner GMX execution fees are paid from the
  Safe's own balance via the delegatecall, so the outer multiSend value is 0 — the
  verifier instead checks the Safe holds ≥ Σ inner values.)

Both verifiers are tamper-tested: redirected receiver, **appended exfiltration `sendTokens`**,
unrelated/unlimited approve, `minOut=0`, one-sided `min=0`, Safe self-target, and admin
selectors are all flagged. The on-chain verifier additionally proves the decoded bytes match
the safeTxHash you sign.

**Slippage magnitude — enforced by default.** "`minOut` ≠ 0" alone isn't proof of *adequate*
slippage (`minOut = 1` passes the offline check, and the fingerprint excludes amounts). So both
verifiers run **live quote checks by default**: they re-derive the expected output on-chain and
compare each swap/GLP `minOut` to it. Because a batch is generated earlier and signed later, the
quote drifts — and a `minOut` *below* the live quote is the **safe** direction (the Safe is
guaranteed ≥ `minOut` and gets more if price rose). So the check is tiered by `minOut / liveQuote`:
**< 50%** = implausibly low → gutted floor (**CRITICAL** for AMM swaps, which are sandbox-able;
**WARN** for GLP, which is oracle-priced and not sandbox-able); **50–90%** = WARN (price drift
since generation *or* a loosened floor — eyeball it); **> 102%** = WARN (likely to revert, price
fell since generation → regenerate). This needs a read-only RPC; `--offline`/`--no-quotes` skips
it (falls back to the weaker `≠0` check with a "less safe" warning). GM/GLV mins are
GMX-keeper/oracle-priced (not pool-sandwichable) so they aren't re-quoted. On the generator side,
the sAVAX swap floor is `max(AMM −2%, oracle −5%)` where the oracle leg
(`getPooledAvaxByShares × AVAX/USD`) is manipulation-resistant.

---

## Notes

- Safe Transaction Service: unified `https://api.safe.global/tx-service/{avax,arb1}` (no API
  key for reads). Override with `SAFE_TX_SERVICE_URL` if needed. Legacy
  `safe-transaction-<net>.safe.global` hosts are deprecated.
- GMX V2 GM/GLV withdrawals are **two-step/async**: the batch only *creates* the requests
  (GM tokens + exec fee → WithdrawalVault); a GMX keeper delivers the underlying to the Safe
  minutes later. GLP (V1) and the sAVAX swap are synchronous.
- The Safe must hold enough native (AVAX/ETH) to cover `totalValue` (the GMX execution fees);
  the unused portion is refunded after keeper execution.
