/**
 * INDEPENDENT verifier for an unwind batch (unwind-gnosis-<chain>.json) — run by a
 * co-signer BEFORE signing, so they don't have to trust the generator script or the
 * JSON. It decodes every inner transaction and asserts a set of safety invariants:
 *
 *   • every recipient (withdrawal/swap/redeem receiver) == the Safe itself
 *   • EVERY inner call of a GMX multicall is one of {sendWnt, sendTokens,
 *     createWithdrawal, createGlvWithdrawal}, and sendWnt/sendTokens go ONLY to the
 *     GMX withdrawal vault (no exfiltration via an appended sendTokens)
 *   • every approval: spender ∈ router allowlist, token is a position unwound in THIS
 *     batch, amount ≠ MaxUint256
 *   • slippage floors (minLong/minShort/minOut) are non-zero (with a WARN if a GM/GLV
 *     side is one-sided zero); GLP/swap outputs ∈ a payout-token allowlist
 *   • no inner tx targets the Safe itself, and no inner call uses a Gnosis-Safe
 *     admin selector (addOwner/changeThreshold/enableModule/setGuard/…)
 *   • every call target ∈ a known-contract allowlist (routers / vaults)
 *   • Σ(tx.value) == the declared totalValue, and only GMX withdrawals carry value
 *
 * LIMITATIONS (read these — they are NOT optional steps):
 *   • This verifies a JSON FILE, not the bytes you sign. Pair it with verify-safe-tx.js
 *     (decodes the actual proposed Safe tx + reproduces the safeTxHash) AND confirm in
 *     the Safe UI that to = canonical MultiSendCallOnly, operation = delegatecall,
 *     gasToken/refundReceiver = 0, expected nonce.
 *   • "minOut ≠ 0" alone is NOT proof of adequate slippage (minOut = 1 passes), and the
 *     structural fingerprint EXCLUDES amounts. This is why live quote checks are ON by
 *     default (they re-derive expected outputs on-chain and bound each swap/GLP minOut).
 *     --offline skips them — then minOut is only checked ≠0 (less safe).
 *
 * Deliberately SMALL (ethers only) so it can be audited top-to-bottom in minutes. By
 * default it makes read-only RPC calls (live quote checks); run --offline for a purely
 * offline pass. ONE leg of verification — also use the Safe UI decode and a Tenderly
 * asset-change + Safe-storage state-diff. No single tool is the root of trust.
 *
 * Usage:
 *   node tools/scripts/verify-safe-batch.js <path-to-unwind-gnosis-<chain>.json>
 *
 * Exit code 0 = all CRITICAL checks passed (WARN/REVIEW may still need an eyeball).
 * Exit code 1 = at least one CRITICAL failure — DO NOT SIGN.
 */

const { ethers } = require("ethers");
const fs = require("fs");
const crypto = require("crypto");

// ─── Known-good addresses — CONFIRM THESE ONCE against block explorers. ─────────
// Treat this map as the signer's own trusted reference, not something the generator
// supplies. If the batch references anything not in here, the verifier flags it.
const CHAINS = {
  "43114": {
    name: "Avalanche",
    safe: "0x18C244c62372dF1b933CD455769f9B4DdB820F0C",
    // valid `to` for a non-approve call:
    targets: {
      "0x8f550e53dfe96c055d5bdb267c21f268fcaf63b2": "GMX ExchangeRouter",
      "0x7e425c47b2ff0be67228c842b9c792d0bce58ae6": "GMX GlvRouter",
      "0xb70b91ce0771d3f4c81d87660f71da31d48eb3b3": "GMX RewardRouterV2",
      "0x60ae616a2155ee3d9a68541ba4544862310933d4": "TraderJoe V1 Router",
      "0x9f637540149f922145c06e1aa3f38dcdc32aff5c": "YieldYak GMX-fsGLP vault",
      "0xaac0f2d0630d1d09ab2b5a400412a4840b866d95": "YieldYak Aave-AVAX vault",
    },
    // valid spenders for an ERC20 approve:
    spenders: {
      "0x820f5ffc5b525cd4d88cd91acf2c28f16530cc68": "GMX V2 Router",
      "0x60ae616a2155ee3d9a68541ba4544862310933d4": "TraderJoe V1 Router",
    },
    // the ONLY valid receiver of a multicall's inner sendWnt/sendTokens, keyed by the
    // multicall target (ExchangeRouter→GM vault, GlvRouter→GLV vault). Anything else
    // is exfiltration.
    withdrawalVaults: {
      "0x8f550e53dfe96c055d5bdb267c21f268fcaf63b2": "0xf5f30b10141e1f63fc11ed772931a8294a591996", // GM WithdrawalVault
      "0x7e425c47b2ff0be67228c842b9c792d0bce58ae6": "0x527fb0bcff63c47761039bb386cfe181a92a4701", // GLV WithdrawalVault
    },
    // tokens the unwind is allowed to convert INTO (GLP redeem tokenOut / swap output).
    payoutTokens: { "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e": "USDC" },
    // --check-quotes only: re-derive expected outputs on-chain to bound each minOut.
    rpc: "https://api.avax.network/ext/bc/C/rpc",
    glpManager: "0xD152c7F25db7F4B95b7658323c5F33d176818EE4",
    stables: { "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e": "USDC" }, // ~$1 GLP redeem tokens
    // valid GM/GM+ market tokens and GLV tokens that may be withdrawn (LOW-04).
    markets: [
      "0xfb02132333a79c8b5bd0b64e3abcca5f7faf2937", "0xb7e69749e3d2edd90ea59a4932efea2d41e245d7",
      "0x913c1f46b48b3ed35e7dc3cf754d4ae8499f31cf", "0x3ce7bcdb37bf587d1c17b930fa0a7000a0648d12",
      "0x2a3cf4ad7db715df994393e4482d6f1e58a1b533", "0x08b25a2a89036d298d6db8a74ace9d1ce6db15e5",
    ],
    glvTokens: ["0x901ee57f7118a7be56ac079cbcda7f22663a3874"],
    yakVaults: ["0x9f637540149f922145c06e1aa3f38dcdc32aff5c", "0xaac0f2d0630d1d09ab2b5a400412a4840b866d95"],
  },
  "42161": {
    name: "Arbitrum",
    safe: "0x764a9756994f4E6cd9358a6FcD924d566fC2e666",
    targets: {
      "0x1c3fa76e6e1088bce750f23a5bfcffa1efef6a41": "GMX ExchangeRouter",
      "0x7eadee2ca1b4d06a0d82fdf03d715550c26aa12f": "GMX GlvRouter",
      "0xb95db5b167d75e6d04227cfffa61069348d271f5": "GMX RewardRouterV2",
    },
    spenders: {
      "0x7452c558d45f8afc8c83dae62c3f8a5be19c71f6": "GMX V2 Router",
    },
    withdrawalVaults: {
      "0x1c3fa76e6e1088bce750f23a5bfcffa1efef6a41": "0x0628d46b5d145f183adb6ef1f2c97ed1c4701c55", // GM WithdrawalVault
      "0x7eadee2ca1b4d06a0d82fdf03d715550c26aa12f": "0x393053b58f9678c9c28c2ce941ff6cac49c3f8f9", // GLV WithdrawalVault
    },
    payoutTokens: { "0xf97f4df75117a78c1a5a0dbb814af92458539fb4": "LINK" },
    rpc: "https://arb1.arbitrum.io/rpc",
    glpManager: "0x3963FfC9dff443c2A94f21b129D429891E32ec18",
    stables: {}, // Arb GLP redeems to LINK (not a stable) → not re-quoted by --check-quotes
    markets: [
      "0x70d95587d40a2caf56bd97485ab3eec10bee6336", "0xc25cef6061cf5de5eb761b50e4743c1f5d7e5407",
      "0x7f1fa204bb700853d36994da19f830b6ad18455c", "0xc7abb2c5f3bf3ceb389df0eecd6120d451170b50",
      "0x47c031236e19d024b42f8ae6780e44a573170703", "0x09400d9db990d5ed3f35d7be61dfaeb900af03c9",
      "0x63dc80ee90f26363b3fcd609007cc9e14c8991be", "0x248c35760068ce009a13076d573ed3497a47bcd4",
      "0x55391d178ce46e7ac8eaaea50a72d1a5a8a622da", "0x6ecf2133e2c9751caadcb6958b9654bae198a797",
      "0xb489711b1cb86afda48924730084e23310eb4883", "0x450bb6774dd8a756274e0ab4107953259d2ac541",
      "0x7c11f78ce78768518d743e81fdfa2f860c6b9a77", "0xbd48149673724f9caee647bb4e9d9ddaf896efeb",
    ],
    glvTokens: ["0x528a5bac7e746c9a509a1f4f6df58a03d44279f9", "0xdf03eed325b82bc1d4db8b49c30ecc9e05104b96"],
    yakVaults: [], // no Yield Yak unwinds on Arbitrum
  },
};

// Live minOut vs a fresh on-chain quote. A minOut BELOW the live quote is the SAFE
// direction (the Safe is guaranteed ≥ minOut and gets more if price rose) — and a tx
// generated earlier is verified later, so the quote drifts. So we can't treat "a few %
// below live" as an attack. Tiers, by minOut/liveQuote ratio:
//   < 50%  → implausibly low; no realistic drift explains it → gutted floor.
//   50-90% → loosely below; price drift since generation OR a loosened floor → eyeball.
//   > 102% → above the live quote → likely to revert (price fell; regenerate).
// AMM swaps are pool-sandbox-able, so a gutted swap floor is CRITICAL; GLP redemption is
// oracle-priced (not sandbox-able), so even a gutted GLP floor is only a WARN.
const QUOTE_GUT_BPS = 5000;   // < 50% of live  → gutted
const QUOTE_LOW_BPS = 9000;   // < 90% of live  → WARN (drift or loosened)
const QUOTE_HIGH_BPS = 10200; // > 102% of live → WARN (revert risk)
const DEX_QUOTE = new ethers.utils.Interface([
  "function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[])",
]);
const GLP_MANAGER = new ethers.utils.Interface([
  "function getPrice(bool maximise) view returns (uint256)",
]);

// ─── Interfaces ────────────────────────────────────────────────────────────────
const ERC20 = new ethers.utils.Interface(["function approve(address spender, uint256 amount)"]);
const ROUTER = new ethers.utils.Interface([
  "function sendWnt(address receiver, uint256 amount)",
  "function sendTokens(address token, address receiver, uint256 amount)",
  "function multicall(bytes[] data)",
]);
const EXCH = new ethers.utils.Interface([
  "function createWithdrawal(((address receiver,address callbackContract,address uiFeeReceiver,address market,address[] longTokenSwapPath,address[] shortTokenSwapPath) addresses,uint256 minLongTokenAmount,uint256 minShortTokenAmount,bool shouldUnwrapNativeToken,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList) params)",
]);
const GLV = new ethers.utils.Interface([
  "function createGlvWithdrawal(((address receiver,address callbackContract,address uiFeeReceiver,address market,address glv,address[] longTokenSwapPath,address[] shortTokenSwapPath) addresses,uint256 minLongTokenAmount,uint256 minShortTokenAmount,bool shouldUnwrapNativeToken,uint256 executionFee,uint256 callbackGasLimit,bytes32[] dataList) params)",
]);
const REWARD = new ethers.utils.Interface([
  "function unstakeAndRedeemGlp(address tokenOut, uint256 glpAmount, uint256 minOut, address receiver)",
]);
const DEX = new ethers.utils.Interface([
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline)",
]);
const YAK = new ethers.utils.Interface(["function withdraw(uint256 amount)"]);

// Gnosis-Safe admin selectors — must NEVER appear in an unwind batch. Computed by
// ethers (not hand-typed) so they can't be a fat-fingered constant.
const SAFE_ADMIN = new ethers.utils.Interface([
  "function addOwnerWithThreshold(address owner, uint256 _threshold)",
  "function removeOwner(address prevOwner, address owner, uint256 _threshold)",
  "function swapOwner(address prevOwner, address oldOwner, address newOwner)",
  "function changeThreshold(uint256 _threshold)",
  "function enableModule(address module)",
  "function disableModule(address prevModule, address module)",
  "function setGuard(address guard)",
  "function setFallbackHandler(address handler)",
  "function execTransactionFromModule(address to, uint256 value, bytes data, uint8 operation)",
  "function approveHash(bytes32 hashToApprove)",
  "function setup(address[] _owners, uint256 _threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver)",
]);
const SAFE_ADMIN_SELECTORS = new Set(
  Object.values(SAFE_ADMIN.functions).map((f) => SAFE_ADMIN.getSighash(f))
);

// ─── Verify ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
// Live quote checks are ON by default ("just running it" = maximally safe). They
// re-derive expected outputs on-chain to bound each minOut. --offline / --no-quotes
// skips them (then minOut is only checked ≠0; less safe — see the printed note).
const checkQuotes = !(args.includes("--offline") || args.includes("--no-quotes"));
const file = args.find((a) => !a.startsWith("-"));
if (!file) {
  console.error("Usage: node tools/scripts/verify-safe-batch.js <unwind-gnosis-<chain>.json> [--offline]");
  process.exit(2);
}
const j = JSON.parse(fs.readFileSync(file, "utf8"));
const cfg = CHAINS[String(j.chainId)];
if (!cfg) {
  console.error(`Unknown chainId ${j.chainId} — add it to CHAINS (and confirm addresses).`);
  process.exit(2);
}
const SAFE = cfg.safe.toLowerCase();
const eq = (a, b) => a && b && a.toLowerCase() === b.toLowerCase();
const isSafe = (a) => eq(a, SAFE);
const MAX = ethers.constants.MaxUint256;

const crit = [];
const warn = [];
const lines = [];
const struct = []; // deterministic, security-relevant shape (NO volatile amounts)
const approves = []; // {tag, token, spender} — token validated after the loop
const unwound = new Set(); // tokens actually being unwound (markets / glv / swap input)
const quoteChecks = []; // {kind, tag, ...} re-quoted live only with --check-quotes
let sum = ethers.BigNumber.from(0);

console.log(`\nVerifying ${file}`);
console.log(`Chain   : ${cfg.name} (${j.chainId})`);
console.log(`Safe    : ${cfg.safe}`);
console.log(`Txs     : ${j.transactions.length}\n`);

j.transactions.forEach((t, i) => {
  const value = ethers.BigNumber.from(t.value || "0");
  sum = sum.add(value);
  const sel = (t.data || "0x").slice(0, 10);
  const to = t.to;
  const tag = `tx#${i}`;

  // Universal red lines.
  if (isSafe(to)) crit.push(`${tag}: targets the SAFE ITSELF (${to}) — possible self-admin takeover`);
  if (SAFE_ADMIN_SELECTORS.has(sel)) crit.push(`${tag}: Gnosis-Safe ADMIN selector ${sel} — never valid in an unwind`);

  try {
    if (sel === ERC20.getSighash("approve")) {
      const { spender, amount } = ERC20.decodeFunctionData("approve", t.data);
      const sp = cfg.spenders[spender.toLowerCase()];
      if (!sp) crit.push(`${tag}: approve spender ${spender} is NOT a known router`);
      // The generator only ever approves the exact balance, so MAX is never legitimate.
      if (amount.eq(MAX)) crit.push(`${tag}: UNLIMITED approval (MaxUint256) to ${spender} — never legitimate`);
      if (!value.isZero()) crit.push(`${tag}: approve carries non-zero value`);
      // The TOKEN being approved must be a position unwound in this same batch. We can
      // only know that after seeing every withdrawal/swap, so defer to the post-loop check.
      approves.push({ tag, token: to.toLowerCase(), spender });
      struct.push({ t: "approve", token: to.toLowerCase(), spender: spender.toLowerCase() });
      lines.push(`${tag}  approve  token=${to}  spender=${spender} (${sp || "UNKNOWN"})  amount=${amount.eq(MAX) ? "MAX" : amount.toString()}`);
      return;
    }

    // Non-approve calls must hit a known target.
    const target = cfg.targets[to.toLowerCase()];
    if (!target) crit.push(`${tag}: call target ${to} is NOT a known contract`);

    if (sel === ROUTER.getSighash("multicall")) {
      // GMX GM / GLV withdrawal bundle. EVERY inner call must be one of the four
      // expected selectors AND its receiver must be the GMX withdrawal vault — an
      // appended sendTokens(USDC, attacker, …) executes on-chain (multicall keeps the
      // Safe as msg.sender → Router.pluginTransfer pulls from the Safe), so it must be
      // rejected here, not silently ignored.
      const expectedVault = (cfg.withdrawalVaults || {})[to.toLowerCase()];
      if (!expectedVault) crit.push(`${tag}: multicall to ${to} has no known withdrawal vault`);
      const [inner] = ROUTER.decodeFunctionData("multicall", t.data);
      let wnt = null, recv = null, minL = null, minS = null, fee = null, kind = "GM", market = null, glv = null, cb = null, swapHops = 0, sentToken = null;
      let nWithdraw = 0, nSendTokens = 0, nSendWnt = 0;
      for (const c of inner) {
        const s = c.slice(0, 10);
        if (s === ROUTER.getSighash("sendWnt")) {
          nSendWnt++;
          const d = ROUTER.decodeFunctionData("sendWnt", c);
          wnt = d.amount;
          if (expectedVault && !eq(d.receiver, expectedVault)) crit.push(`${tag}: inner sendWnt receiver ${d.receiver} != withdrawal vault`);
        } else if (s === ROUTER.getSighash("sendTokens")) {
          nSendTokens++;
          const d = ROUTER.decodeFunctionData("sendTokens", c);
          sentToken = d.token;
          if (expectedVault && !eq(d.receiver, expectedVault)) crit.push(`${tag}: inner sendTokens receiver ${d.receiver} != withdrawal vault — TOKEN EXFILTRATION`);
        } else if (s === EXCH.getSighash("createWithdrawal")) {
          nWithdraw++;
          const p = EXCH.decodeFunctionData("createWithdrawal", c).params;
          recv = p.addresses.receiver; minL = p.minLongTokenAmount; minS = p.minShortTokenAmount; fee = p.executionFee; market = p.addresses.market; cb = p.addresses.callbackContract;
          swapHops += p.addresses.longTokenSwapPath.length + p.addresses.shortTokenSwapPath.length;
        } else if (s === GLV.getSighash("createGlvWithdrawal")) {
          nWithdraw++; kind = "GLV";
          const p = GLV.decodeFunctionData("createGlvWithdrawal", c).params;
          recv = p.addresses.receiver; minL = p.minLongTokenAmount; minS = p.minShortTokenAmount; fee = p.executionFee; market = p.addresses.market; glv = p.addresses.glv; cb = p.addresses.callbackContract;
          swapHops += p.addresses.longTokenSwapPath.length + p.addresses.shortTokenSwapPath.length;
        } else {
          crit.push(`${tag}: UNRECOGNISED inner call ${s} inside multicall — possible exfiltration`);
        }
      }
      if (nWithdraw !== 1) crit.push(`${tag}: expected exactly 1 createWithdrawal/createGlvWithdrawal, found ${nWithdraw}`);
      if (nSendWnt > 1) crit.push(`${tag}: ${nSendWnt} sendWnt calls (expected ≤1)`);
      if (nSendTokens > 1) crit.push(`${tag}: ${nSendTokens} sendTokens calls (expected ≤1)`);
      if (!isSafe(recv)) crit.push(`${tag}: ${kind} withdrawal receiver ${recv} != Safe`);
      if (cb && cb !== ethers.constants.AddressZero) crit.push(`${tag}: ${kind} callbackContract ${cb} != 0 (untrusted callback)`);
      // Swap paths must be empty: a non-empty long/short swap path routes proceeds through
      // attacker-chosen GMX markets (price-impact-exposed), and the fingerprint doesn't cover it.
      if (swapHops > 0) crit.push(`${tag}: ${kind} withdrawal has ${swapHops} swap-path hop(s) — must be empty (proceeds re-routed)`);
      // market / glv must be known (LOW-04): fabricated values revert on-chain but should fail offline too.
      if (market && cfg.markets && !cfg.markets.includes(market.toLowerCase())) crit.push(`${tag}: ${kind} market ${market} not in the known-markets allowlist`);
      if (glv && cfg.glvTokens && !cfg.glvTokens.includes(glv.toLowerCase())) crit.push(`${tag}: GLV token ${glv} not in the known-GLV allowlist`);
      // the GM token sent to the vault must be the market being withdrawn (GLV: the glv token).
      const expectToken = kind === "GLV" ? glv : market;
      if (sentToken && expectToken && !eq(sentToken, expectToken)) crit.push(`${tag}: ${kind} sendTokens token ${sentToken} != withdrawn ${kind === "GLV" ? "glv" : "market"} ${expectToken}`);
      if (minL && minS) {
        if (minL.isZero() && minS.isZero()) crit.push(`${tag}: ${kind} minLong AND minShort both 0 (no slippage protection)`);
        else if (minL.isZero() || minS.isZero()) warn.push(`${tag}: ${kind} one side min=0 (${minL.isZero() ? "minLong" : "minShort"}) — confirm that side is genuinely ~0`);
      }
      if (fee && !fee.eq(value)) crit.push(`${tag}: ${kind} executionFee ${fee} != tx.value ${value}`);
      if (wnt && !wnt.eq(value)) crit.push(`${tag}: ${kind} sendWnt ${wnt} != tx.value ${value}`);
      // the approved token for this position (gmToken for GM, glvToken for GLV)
      if (kind === "GLV" && glv) unwound.add(glv.toLowerCase());
      else if (market) unwound.add(market.toLowerCase());
      struct.push({ t: kind, to: to.toLowerCase(), receiver: (recv || "").toLowerCase(), market: (market || "").toLowerCase(), glv: (glv || "").toLowerCase() });
      lines.push(`${tag}  ${kind}.withdraw  to=${target}  receiver=${isSafe(recv) ? "Safe ✓" : recv}  minL=${minL}  minS=${minS}  value=${value}`);
      return;
    }

    if (sel === REWARD.getSighash("unstakeAndRedeemGlp")) {
      const d = REWARD.decodeFunctionData("unstakeAndRedeemGlp", t.data);
      if (!isSafe(d.receiver)) crit.push(`${tag}: GLP redeem receiver ${d.receiver} != Safe`);
      if (d.minOut.isZero()) crit.push(`${tag}: GLP redeem minOut == 0 (no slippage protection)`);
      if (!(cfg.payoutTokens || {})[d.tokenOut.toLowerCase()]) crit.push(`${tag}: GLP redeem tokenOut ${d.tokenOut} not in payout allowlist`);
      if (!value.isZero()) warn.push(`${tag}: GLP redeem carries value (expected 0)`);
      quoteChecks.push({ kind: "glp", tag, tokenOut: d.tokenOut.toLowerCase(), glpAmount: d.glpAmount, minOut: d.minOut });
      struct.push({ t: "glp", to: to.toLowerCase(), tokenOut: d.tokenOut.toLowerCase(), receiver: d.receiver.toLowerCase() });
      lines.push(`${tag}  GLP.redeem  to=${target}  receiver=${isSafe(d.receiver) ? "Safe ✓" : d.receiver}  amount=${ethers.utils.formatUnits(d.glpAmount, 18)}  minOut=${d.minOut}`);
      return;
    }

    if (sel === DEX.getSighash("swapExactTokensForTokens")) {
      const d = DEX.decodeFunctionData("swapExactTokensForTokens", t.data);
      if (!isSafe(d.to)) crit.push(`${tag}: swap recipient ${d.to} != Safe`);
      if (d.amountOutMin.isZero()) crit.push(`${tag}: swap amountOutMin == 0 (no slippage protection)`);
      const out = d.path[d.path.length - 1];
      if (!(cfg.payoutTokens || {})[out.toLowerCase()]) crit.push(`${tag}: swap output token ${out} not in payout allowlist`);
      if (!value.isZero()) crit.push(`${tag}: token swap carries value`);
      quoteChecks.push({ kind: "swap", tag, router: to, amountIn: d.amountIn, path: d.path, minOut: d.amountOutMin });
      unwound.add(d.path[0].toLowerCase()); // swap input is an unwound asset (its approve is legit)
      struct.push({ t: "swap", to: to.toLowerCase(), path: d.path.map((x) => x.toLowerCase()), recipient: d.to.toLowerCase() });
      lines.push(`${tag}  swap  to=${target}  recipient=${isSafe(d.to) ? "Safe ✓" : d.to}  in=${d.path[0]} out=${d.path[d.path.length - 1]}  minOut=${d.amountOutMin}`);
      return;
    }

    if (sel === YAK.getSighash("withdraw")) {
      // withdraws to msg.sender (the Safe); no recipient param, no min (1:1).
      if (!value.isZero()) crit.push(`${tag}: Yak withdraw carries value`);
      if (cfg.yakVaults && !cfg.yakVaults.includes(to.toLowerCase())) crit.push(`${tag}: Yak.withdraw target ${to} is not a known Yield Yak vault`);
      struct.push({ t: "yak", to: to.toLowerCase() });
      lines.push(`${tag}  Yak.withdraw  to=${target}  shares=${ethers.utils.formatUnits(YAK.decodeFunctionData("withdraw", t.data).amount, 18)}`);
      return;
    }

    crit.push(`${tag}: UNRECOGNISED selector ${sel} on ${to} (${target || "unknown"}) — decode manually before signing`);
    lines.push(`${tag}  ??? selector=${sel} to=${to}`);
  } catch (e) {
    crit.push(`${tag}: failed to decode (${e.message})`);
  }
});

// Each approved token must be a position actually unwound in this batch (a GM/GLV
// token withdrawn, or the sAVAX swap input). This binds approvals to the unwind so
// you can't approve an unrelated asset (e.g. USDC) to a known router.
for (const a of approves) {
  if (!unwound.has(a.token)) crit.push(`${a.tag}: approve token ${a.token} is NOT a position unwound in this batch — unexpected approval`);
}

// value integrity
const declared = ethers.BigNumber.from(j.totalValue || "0");
if (!declared.eq(sum)) crit.push(`totalValue ${declared} != Σ(tx.value) ${sum}`);

console.log("DECODED TRANSACTIONS");
console.log("─".repeat(80));
for (const l of lines) console.log("  " + l);
console.log("─".repeat(80));
console.log(`  Σ value = ${sum.toString()} wei  (declared totalValue ${declared.toString()} ${declared.eq(sum) ? "✓" : "✗"})\n`);

// Structural fingerprint: sha256 over the deterministic, security-relevant shape
// (chain, Safe, and per-tx target/method/recipient/spender/token/path/order) —
// EXCLUDING live amounts, fees, minOuts, deadline, createdAt. Two independent runs
// of the (pinned) generator yield the SAME fingerprint, so two signers can compare
// this one string instead of eyeballing every tx. A raw-file hash would NOT match.
const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
const preimage = JSON.stringify({ chainId: String(j.chainId), safe: SAFE, txs: struct });
const fingerprint = sha256(preimage);
const rawHash = sha256(fs.readFileSync(file));
console.log("FINGERPRINTS");
console.log("─".repeat(80));
console.log(`  structural : ${fingerprint}`);
console.log(`               ↑ COMPARE THIS with your co-signer (stable across runs).`);
console.log(`  raw file   : ${rawHash}`);
console.log(`               ↑ varies every run (live fees/quotes/deadline) — do NOT compare.`);
console.log(`  NOTE: the structural fingerprint covers targets/recipients/spenders/tokens/order`);
console.log(`        but NOT amounts or slippage floors. A matching fingerprint does NOT prove`);
console.log(`        minOut is adequate — only that it is non-zero (see WARN/CRIT above). For`);
console.log(`        slippage assurance, re-quote live or compare minOut to a fresh generator run.\n`);

// Optional live quote checks bound each swap/GLP minOut against a fresh on-chain
// quote — closing the "minOut=1 passes" gap that the offline checks + fingerprint
// can't catch. GM/GLV mins are GMX-keeper/oracle-priced (not pool-sandwichable) and
// are not re-quoted. Then print the verdict.
(async () => {
  if (checkQuotes) {
    console.log("LIVE QUOTE CHECKS (on by default; --offline to skip)");
    console.log("─".repeat(80));
    if (!cfg.rpc) {
      warn.push("--check-quotes: no RPC configured for this chain — minOut not bounded");
    } else {
      const provider = new ethers.providers.JsonRpcProvider(cfg.rpc);
      // sandboxable=true (AMM swap) → gutted floor is CRIT; false (oracle-priced) → WARN.
      const assess = (tag, what, sandboxable, minOut, live) => {
        if (live.isZero()) { warn.push(`${tag}: ${what} live quote is 0 — minOut NOT bounded`); return "?"; }
        const r = minOut.mul(10000).div(live);
        const below = Math.max(0, 10000 - r.toNumber()) / 100;
        if (r.lt(QUOTE_GUT_BPS)) {
          const msg = `${tag}: ${what} minOut ${minOut} is ${below.toFixed(1)}% below live ${live} — implausibly low (gutted floor?)`;
          if (sandboxable) crit.push(msg); else warn.push(`${msg} [oracle-priced: not sandbox-able, but verify]`);
          return "✗ GUTTED";
        }
        if (r.lt(QUOTE_LOW_BPS)) { warn.push(`${tag}: ${what} minOut ${below.toFixed(1)}% below live quote ${live} — confirm price drift since generation, not a loosened floor`); return "⚠ low"; }
        if (r.gt(QUOTE_HIGH_BPS)) { warn.push(`${tag}: ${what} minOut is above live quote ${live} — tx may REVERT (price fell since generation; regenerate)`); return "⚠ high (revert?)"; }
        return "✓";
      };
      for (const q of quoteChecks) {
        try {
          if (q.kind === "swap") {
            const amts = await new ethers.Contract(q.router, DEX_QUOTE, provider).getAmountsOut(q.amountIn, q.path);
            const live = amts[amts.length - 1];
            console.log(`  ${q.tag} swap : minOut ${q.minOut} vs live ${live} → ${assess(q.tag, "swap", true, q.minOut, live)}`);
          } else if (q.kind === "glp") {
            if (!(cfg.stables || {})[q.tokenOut]) { console.log(`  ${q.tag} glp  : tokenOut not a ~$1 stable — skipped (oracle-priced)`); continue; }
            if (!cfg.glpManager) { console.log(`  ${q.tag} glp  : no GlpManager configured — skipped`); continue; }
            const price = await new ethers.Contract(cfg.glpManager, GLP_MANAGER, provider).getPrice(false); // 1e30 USD/GLP
            const live = q.glpAmount.mul(price).div(ethers.BigNumber.from(10).pow(42)); // → 6dp $1 token
            console.log(`  ${q.tag} glp  : minOut ${q.minOut} vs live NAV ${live} → ${assess(q.tag, "GLP", false, q.minOut, live)}`);
          }
        } catch (e) {
          // Fail closed: if we can't bound the minOut, don't quietly pass it.
          crit.push(`${q.tag}: live quote check FAILED (${e.message}) — minOut NOT bounded; fix RPC or re-run with --offline to accept the risk`);
        }
      }
      console.log(`  (GM/GLV mins are GMX-keeper/oracle-priced — not pool-sandwichable — so not re-quoted.)`);
    }
    console.log("");
  } else if (quoteChecks.length) {
    console.log(`⚠  --offline: ${quoteChecks.length} swap/GLP minOut(s) NOT bounded against live quotes (only checked ≠0). Less safe.\n`);
  }

  if (warn.length) {
    console.log("⚠  WARNINGS (eyeball these):");
    for (const w of warn) console.log("   • " + w);
    console.log("");
  }
  if (crit.length) {
    console.log("⛔ CRITICAL FAILURES — DO NOT SIGN:");
    for (const c of crit) console.log("   • " + c);
    console.log("");
    process.exit(1);
  }
  console.log("✅ All CRITICAL invariants passed.");
  console.log("   Still required before signing: (1) Safe UI shows to = canonical MultiSendCallOnly,");
  console.log("   gasPrice/gasToken/refundReceiver = 0, expected nonce; (2) Tenderly sim shows only");
  console.log("   expected outflows to the Safe and NO change to Safe owners/threshold/modules/guard.");
})();
