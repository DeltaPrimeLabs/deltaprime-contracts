/**
 * INDEPENDENT verifier for the ACTUAL Gnosis Safe transaction a co-signer is about
 * to sign. You paste the Safe app tx link (or "<chain> <safeTxHash>"); it fetches
 * the proposed tx from the Safe Transaction Service, RECOMPUTES the safeTxHash from
 * the fetched params (so the service can't show benign params behind a different
 * hash), decodes the MultiSend bytes you're signing, and runs the same safety
 * invariants as verify-safe-batch.js — then prints the SAME structural fingerprint
 * so it can be cross-checked against the JSON / an independent regen.
 *
 * This verifies the literal bytes committed by the signature, not a JSON file that
 * merely *should* correspond to them. Pair it with verify-safe-batch.js (JSON shape)
 * and a Tenderly sim (behavioral / Safe-storage state-diff). Self-contained on
 * purpose (ethers + global fetch only) so it's small enough to audit and pin by hash.
 *
 * Usage:
 *   node tools/scripts/verify-safe-tx.js "<safe-app-tx-link>"
 *   node tools/scripts/verify-safe-tx.js avax 0x<safeTxHash>
 *   node tools/scripts/verify-safe-tx.js arb1 0x<safeTxHash>
 *
 * Exit 0 = all CRITICAL checks passed.  Exit 1 = at least one CRITICAL — DO NOT SIGN.
 */

const { ethers } = require("ethers");
const crypto = require("crypto");

// Safe Transaction Service (unified) + chain prefixes. Legacy per-chain hosts are
// deprecated (308). Override base with SAFE_TX_SERVICE_URL if needed.
const NET = {
  avax: { chainId: "43114" },
  arb1: { chainId: "42161" },
};
const PREFIX_ALIAS = { avalanche: "avax", "43114": "avax", arbitrum: "arb1", arb: "arb1", "42161": "arb1" };
const svcBase = (prefix) =>
  process.env.SAFE_TX_SERVICE_URL || `https://api.safe.global/tx-service/${prefix}/api/v1`;

// MultiSendCallOnly (CALL-only; inner ops can't be delegatecall). Known addresses are
// a fast path; the authoritative check is the runtime-bytecode hash below, since some
// chains (e.g. Avalanche) deployed Safe contracts at NON-canonical addresses with the
// SAME bytecode. Confirm these once against block explorers.
const MULTISEND_CALL_ONLY = new Set(
  [
    "0x40A2aCCbd92BCA938b02010E17A5b8929b49130D", // v1.3.0 canonical
    "0x9641d764fc13c8B624c04430C7356C1C7C8102e2", // v1.4.1 canonical
    "0xA1dabEF33b3B82c7814B6D82A79e50F4AC44102B", // v1.3.0 Avalanche (non-canonical; same bytecode)
  ].map((a) => a.toLowerCase())
);
// keccak256 of the MultiSendCallOnly runtime bytecode. An address whose deployed code
// hashes to one of these IS MultiSendCallOnly (behaviour is in the code), regardless of
// address — this is what makes the wrapper check robust to non-canonical deployments.
const MSCO_RUNTIME_HASHES = new Set([
  "0xa9865ac2d9c7a1591619b188c4d88167b50df6cc0c5327fcbd1c8c75f7c066ad", // v1.3.0
  "0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939", // v1.4.1
]);

// ─── Known-good addresses — CONFIRM ONCE against explorers (the trust anchor). ──
const CHAINS = {
  "43114": {
    name: "Avalanche",
    safe: "0x18C244c62372dF1b933CD455769f9B4DdB820F0C",
    targets: {
      "0x8f550e53dfe96c055d5bdb267c21f268fcaf63b2": "GMX ExchangeRouter",
      "0x7e425c47b2ff0be67228c842b9c792d0bce58ae6": "GMX GlvRouter",
      "0xb70b91ce0771d3f4c81d87660f71da31d48eb3b3": "GMX RewardRouterV2",
      "0x60ae616a2155ee3d9a68541ba4544862310933d4": "TraderJoe V1 Router",
      "0x9f637540149f922145c06e1aa3f38dcdc32aff5c": "YieldYak GMX-fsGLP vault",
      "0xaac0f2d0630d1d09ab2b5a400412a4840b866d95": "YieldYak Aave-AVAX vault",
    },
    spenders: {
      "0x820f5ffc5b525cd4d88cd91acf2c28f16530cc68": "GMX V2 Router",
      "0x60ae616a2155ee3d9a68541ba4544862310933d4": "TraderJoe V1 Router",
    },
    withdrawalVaults: {
      "0x8f550e53dfe96c055d5bdb267c21f268fcaf63b2": "0xf5f30b10141e1f63fc11ed772931a8294a591996", // GM WithdrawalVault
      "0x7e425c47b2ff0be67228c842b9c792d0bce58ae6": "0x527fb0bcff63c47761039bb386cfe181a92a4701", // GLV WithdrawalVault
    },
    payoutTokens: { "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e": "USDC" },
    rpc: "https://api.avax.network/ext/bc/C/rpc",
    glpManager: "0xD152c7F25db7F4B95b7658323c5F33d176818EE4",
    stables: { "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e": "USDC" },
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
    spenders: { "0x7452c558d45f8afc8c83dae62c3f8a5be19c71f6": "GMX V2 Router" },
    withdrawalVaults: {
      "0x1c3fa76e6e1088bce750f23a5bfcffa1efef6a41": "0x0628d46b5d145f183adb6ef1f2c97ed1c4701c55", // GM WithdrawalVault
      "0x7eadee2ca1b4d06a0d82fdf03d715550c26aa12f": "0x393053b58f9678c9c28c2ce941ff6cac49c3f8f9", // GLV WithdrawalVault
    },
    payoutTokens: { "0xf97f4df75117a78c1a5a0dbb814af92458539fb4": "LINK" },
    rpc: "https://arb1.arbitrum.io/rpc",
    glpManager: "0x3963FfC9dff443c2A94f21b129D429891E32ec18",
    stables: {},
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
    yakVaults: [],
  },
};

// Live minOut vs a fresh on-chain quote — tiered, because a minOut below the quote is the
// SAFE direction and the quote drifts between generation and signing. By minOut/live ratio:
//   <50% gutted (CRIT for AMM swaps; WARN for oracle-priced GLP) · 50-90% WARN (drift or
//   loosened) · >102% WARN (likely revert, price fell since generation).
const QUOTE_GUT_BPS = 5000;
const QUOTE_LOW_BPS = 9000;
const QUOTE_HIGH_BPS = 10200;
const DEX_QUOTE = new ethers.utils.Interface([
  "function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[])",
]);
const GLP_MANAGER = new ethers.utils.Interface([
  "function getPrice(bool maximise) view returns (uint256)",
]);

// ─── Interfaces (same set as verify-safe-batch.js) ─────────────────────────────
const MULTISEND = new ethers.utils.Interface(["function multiSend(bytes transactions)"]);
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
const SAFE_ADMIN_SELECTORS = new Set(Object.values(SAFE_ADMIN.functions).map((f) => SAFE_ADMIN.getSighash(f)));

const SAFE_TX_TYPES = {
  SafeTx: [
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
    { name: "operation", type: "uint8" },
    { name: "safeTxGas", type: "uint256" },
    { name: "baseGas", type: "uint256" },
    { name: "gasPrice", type: "uint256" },
    { name: "gasToken", type: "address" },
    { name: "refundReceiver", type: "address" },
    { name: "nonce", type: "uint256" },
  ],
};

// ─── helpers ───────────────────────────────────────────────────────────────────
function parseInput(args) {
  const joined = args.join(" ");
  const hash = (joined.match(/0x[0-9a-fA-F]{64}/) || [])[0];
  let prefix =
    (joined.match(/safe=([a-z0-9]+):/i) || [])[1] ||
    (joined.match(/tx-service\/([a-z0-9]+)\//i) || [])[1] ||
    args.map((a) => a.toLowerCase()).find((a) => NET[a] || PREFIX_ALIAS[a]);
  if (prefix) prefix = (PREFIX_ALIAS[prefix.toLowerCase()] || prefix).toLowerCase();
  return { prefix, hash };
}

function recomputeSafeTxHash(chainId, safe, tx) {
  const v = {
    to: tx.to,
    value: tx.value || "0",
    data: tx.data || "0x",
    operation: tx.operation,
    safeTxGas: tx.safeTxGas || "0",
    baseGas: tx.baseGas || "0",
    gasPrice: tx.gasPrice || "0",
    gasToken: tx.gasToken || ethers.constants.AddressZero,
    refundReceiver: tx.refundReceiver || ethers.constants.AddressZero,
    nonce: tx.nonce,
  };
  const withChain = ethers.utils._TypedDataEncoder.hash(
    { chainId: Number(chainId), verifyingContract: safe }, SAFE_TX_TYPES, v
  );
  const legacy = ethers.utils._TypedDataEncoder.hash({ verifyingContract: safe }, SAFE_TX_TYPES, v);
  return { withChain, legacy };
}

function unpackMultiSend(packedHex) {
  const data = ethers.utils.arrayify(packedHex);
  const txs = [];
  let i = 0;
  while (i < data.length) {
    const operation = data[i]; i += 1;
    const to = ethers.utils.getAddress(ethers.utils.hexlify(data.slice(i, i + 20))); i += 20;
    const value = ethers.BigNumber.from(data.slice(i, i + 32)); i += 32;
    const len = ethers.BigNumber.from(data.slice(i, i + 32)).toNumber(); i += 32;
    const d = ethers.utils.hexlify(data.slice(i, i + len)); i += len;
    txs.push({ operation, to, value, data: d });
  }
  return txs;
}

// ─── main ────────────────────────────────────────────────────────────────────
(async () => {
  const { prefix, hash } = parseInput(process.argv.slice(2));
  // Live quote checks ON by default (this tool already needs network to fetch the tx).
  // --no-quotes / --offline skips only the minOut re-quote (less safe).
  const checkQuotes = !(process.argv.slice(2).includes("--no-quotes") || process.argv.slice(2).includes("--offline"));
  if (!prefix || !NET[prefix] || !hash) {
    console.error('Usage: node tools/scripts/verify-safe-tx.js "<safe-app-tx-link>" [--no-quotes]  |  <avax|arb1> 0x<safeTxHash>');
    process.exit(2);
  }
  const chainId = NET[prefix].chainId;
  const cfg = CHAINS[chainId];
  const url = `${svcBase(prefix)}/multisig-transactions/${hash}/`;

  console.log(`\nFetching ${url}`);
  let tx;
  try {
    const res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    tx = await res.json();
  } catch (e) {
    console.error(`Could not fetch tx (${e.message}). Set SAFE_TX_SERVICE_URL or check the link.`);
    process.exit(2);
  }

  const SAFE = (cfg.safe).toLowerCase();
  const eq = (a, b) => a && b && a.toLowerCase() === b.toLowerCase();
  const isSafe = (a) => eq(a, SAFE);
  const MAX = ethers.constants.MaxUint256;
  const ZERO = ethers.constants.AddressZero;
  const crit = [], warn = [], lines = [], struct = [];
  const approves = []; // {tag, token, spender} — token validated after the loop
  const unwound = new Set(); // tokens actually unwound (markets / glv / swap input)
  const quoteChecks = []; // re-quoted live only with --check-quotes

  console.log(`Chain   : ${cfg.name} (${chainId})`);
  console.log(`Safe    : ${cfg.safe}  (service says ${tx.safe})`);
  console.log(`Nonce   : ${tx.nonce}\n`);

  if (!eq(tx.safe, cfg.safe)) crit.push(`service safe ${tx.safe} != expected ${cfg.safe}`);

  // (1) safeTxHash must reproduce from the fetched params (you sign THIS hash).
  const rc = recomputeSafeTxHash(chainId, cfg.safe, tx);
  if (eq(rc.withChain, hash)) console.log(`safeTxHash : ${hash}  ✓ reproduced (EIP-712, chainId domain)`);
  else if (eq(rc.legacy, hash)) {
    console.log(`safeTxHash : ${hash}  ✓ reproduced (LEGACY chainId-less domain)`);
    warn.push(`safeTxHash reproduced only via the LEGACY (chainId-less) domain — expected for Safe < 1.3.0 only; confirm this Safe's version`);
  } else { console.log(`safeTxHash : ${hash}  ✗ recomputed ${rc.withChain}`); crit.push(`safeTxHash does NOT reproduce from params — refuse to sign`); }
  if (tx.safeTxHash && !eq(tx.safeTxHash, hash)) crit.push(`service safeTxHash ${tx.safeTxHash} != link hash ${hash}`);

  // (2) wrapper checks — confirm `to` is MultiSendCallOnly by address (fast path) OR
  // by runtime-bytecode hash (robust to non-canonical deployments like Avalanche's).
  async function isMultiSendCallOnly(addr) {
    if (MULTISEND_CALL_ONLY.has((addr || "").toLowerCase())) return { ok: true, how: "known address" };
    if (!cfg.rpc) return { ok: false, how: "not a known address; no RPC to bytecode-verify" };
    try {
      const code = await new ethers.providers.JsonRpcProvider(cfg.rpc).getCode(addr);
      if (code && code !== "0x" && MSCO_RUNTIME_HASHES.has(ethers.utils.keccak256(code)))
        return { ok: true, how: "bytecode-verified (non-listed address)" };
      return { ok: false, how: "bytecode does NOT match MultiSendCallOnly" };
    } catch (e) {
      return { ok: false, how: `bytecode fetch failed: ${e.message}` };
    }
  }
  let msco = { ok: false };
  if (Number(tx.operation) === 1) {
    msco = await isMultiSendCallOnly(tx.to);
    if (!msco.ok) crit.push(`DELEGATECALL to ${tx.to} is NOT verified MultiSendCallOnly (${msco.how}) — full-takeover risk`);
    else console.log(`wrapper    : delegatecall → MultiSendCallOnly ${tx.to} ✓ (${msco.how})`);
  } else {
    console.log(`wrapper    : single CALL (operation 0) to ${tx.to}`);
  }
  // Gas-refund drain: after execution the Safe pays (gasUsed + baseGas) * gasPrice in
  // gasToken (native if 0) to refundReceiver — or to tx.origin (the executor) when
  // refundReceiver == 0 (the default). So gasPrice != 0 ALONE drains native to whoever
  // executes, even with refundReceiver/gasToken zeroed. Safe{Wallet} relayed batches set
  // gasPrice = baseGas = safeTxGas = 0 (confirmed against the live tx), so any non-zero
  // is illegitimate → CRITICAL. (safeTxGas isn't in the refund formula → WARN.)
  const bn = (x) => ethers.BigNumber.from(x || "0");
  if (!eq(tx.gasToken || ZERO, ZERO)) crit.push(`gasToken ${tx.gasToken} != 0 (gas-refund paid in a token)`);
  if (!eq(tx.refundReceiver || ZERO, ZERO)) crit.push(`refundReceiver ${tx.refundReceiver} != 0 (gas-refund redirect)`);
  if (!bn(tx.gasPrice).isZero()) crit.push(`gasPrice ${tx.gasPrice} != 0 — Safe pays (gasUsed+baseGas)*gasPrice native to the executor (refund drain)`);
  if (!bn(tx.baseGas).isZero()) crit.push(`baseGas ${tx.baseGas} != 0 — inflates the gas-refund drain`);
  if (!bn(tx.safeTxGas).isZero()) crit.push(`safeTxGas ${tx.safeTxGas} != 0 — Safe{Wallet} batches use 0; non-zero is a manual/refund-griefing flag`);

  // (3) expand inner transactions (fail closed + gracefully on a malformed payload)
  let inner = [];
  if (Number(tx.operation) === 1 && msco.ok) {
    try {
      const packed = MULTISEND.decodeFunctionData("multiSend", tx.data).transactions;
      inner = unpackMultiSend(packed);
    } catch (e) {
      crit.push(`malformed MultiSend payload (${e.message}) — cannot decode inner txs`);
    }
  } else {
    inner = [{ operation: Number(tx.operation), to: tx.to, value: ethers.BigNumber.from(tx.value || "0"), data: tx.data || "0x" }];
  }

  let sum = ethers.BigNumber.from(0);
  inner.forEach((t, i) => {
    const value = ethers.BigNumber.from(t.value || "0");
    sum = sum.add(value);
    const sel = (t.data || "0x").slice(0, 10);
    const to = t.to;
    const tag = `tx#${i}`;

    if (Number(t.operation) !== 0) crit.push(`${tag}: inner operation ${t.operation} (expected 0/CALL — delegatecall forbidden)`);
    if (isSafe(to)) crit.push(`${tag}: targets the SAFE ITSELF (${to}) — possible self-admin takeover`);
    if (SAFE_ADMIN_SELECTORS.has(sel)) crit.push(`${tag}: Gnosis-Safe ADMIN selector ${sel} — never valid in an unwind`);

    try {
      if (sel === ERC20.getSighash("approve")) {
        const { spender, amount } = ERC20.decodeFunctionData("approve", t.data);
        const sp = cfg.spenders[spender.toLowerCase()];
        if (!sp) crit.push(`${tag}: approve spender ${spender} is NOT a known router`);
        if (amount.eq(MAX)) crit.push(`${tag}: UNLIMITED approval (MaxUint256) to ${spender} — never legitimate`);
        if (!value.isZero()) crit.push(`${tag}: approve carries non-zero value`);
        approves.push({ tag, token: to.toLowerCase(), spender });
        struct.push({ t: "approve", token: to.toLowerCase(), spender: spender.toLowerCase() });
        lines.push(`${tag}  approve  token=${to}  spender=${spender} (${sp || "UNKNOWN"})  amount=${amount.eq(MAX) ? "MAX" : amount.toString()}`);
        return;
      }
      const target = cfg.targets[to.toLowerCase()];
      if (!target) crit.push(`${tag}: call target ${to} is NOT a known contract`);

      if (sel === ROUTER.getSighash("multicall")) {
        // EVERY inner call must be expected AND sendWnt/sendTokens must go ONLY to the
        // GMX withdrawal vault — an appended sendTokens(token, attacker, …) executes
        // on-chain (Safe stays msg.sender → Router.pluginTransfer pulls from the Safe).
        const expectedVault = (cfg.withdrawalVaults || {})[to.toLowerCase()];
        if (!expectedVault) crit.push(`${tag}: multicall to ${to} has no known withdrawal vault`);
        const [calls] = ROUTER.decodeFunctionData("multicall", t.data);
        let wnt = null, recv = null, minL = null, minS = null, fee = null, kind = "GM", market = null, glv = null, cb = null, swapHops = 0, sentToken = null;
        let nWithdraw = 0, nSendTokens = 0, nSendWnt = 0;
        for (const c of calls) {
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
        if (swapHops > 0) crit.push(`${tag}: ${kind} withdrawal has ${swapHops} swap-path hop(s) — must be empty (proceeds re-routed)`);
        if (market && cfg.markets && !cfg.markets.includes(market.toLowerCase())) crit.push(`${tag}: ${kind} market ${market} not in the known-markets allowlist`);
        if (glv && cfg.glvTokens && !cfg.glvTokens.includes(glv.toLowerCase())) crit.push(`${tag}: GLV token ${glv} not in the known-GLV allowlist`);
        const expectToken = kind === "GLV" ? glv : market;
        if (sentToken && expectToken && !eq(sentToken, expectToken)) crit.push(`${tag}: ${kind} sendTokens token ${sentToken} != withdrawn ${kind === "GLV" ? "glv" : "market"} ${expectToken}`);
        if (minL && minS) {
          if (minL.isZero() && minS.isZero()) crit.push(`${tag}: ${kind} minLong AND minShort both 0 (no slippage protection)`);
          else if (minL.isZero() || minS.isZero()) warn.push(`${tag}: ${kind} one side min=0 (${minL.isZero() ? "minLong" : "minShort"}) — confirm that side is genuinely ~0`);
        }
        if (fee && !fee.eq(value)) crit.push(`${tag}: ${kind} executionFee ${fee} != tx.value ${value}`);
        if (wnt && !wnt.eq(value)) crit.push(`${tag}: ${kind} sendWnt ${wnt} != tx.value ${value}`);
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
        quoteChecks.push({ kind: "swap", tag, router: to, amountIn: d.amountIn, path: d.path, minOut: d.amountOutMin });
        unwound.add(d.path[0].toLowerCase());
        struct.push({ t: "swap", to: to.toLowerCase(), path: d.path.map((x) => x.toLowerCase()), recipient: d.to.toLowerCase() });
        lines.push(`${tag}  swap  to=${target}  recipient=${isSafe(d.to) ? "Safe ✓" : d.to}  in=${d.path[0]} out=${d.path[d.path.length - 1]}  minOut=${d.amountOutMin}`);
        return;
      }
      if (sel === YAK.getSighash("withdraw")) {
        if (cfg.yakVaults && !cfg.yakVaults.includes(to.toLowerCase())) crit.push(`${tag}: Yak.withdraw target ${to} is not a known Yield Yak vault`);
        struct.push({ t: "yak", to: to.toLowerCase() });
        lines.push(`${tag}  Yak.withdraw  to=${target}  shares=${ethers.utils.formatUnits(YAK.decodeFunctionData("withdraw", t.data).amount, 18)}`);
        return;
      }
      crit.push(`${tag}: UNRECOGNISED selector ${sel} on ${to} (${target || "unknown"}) — decode manually`);
      lines.push(`${tag}  ??? selector=${sel} to=${to}`);
    } catch (e) {
      crit.push(`${tag}: failed to decode (${e.message})`);
    }
  });

  // Each approved token must be a position actually unwound in this batch.
  for (const a of approves) {
    if (!unwound.has(a.token)) crit.push(`${a.tag}: approve token ${a.token} is NOT a position unwound in this batch — unexpected approval`);
  }

  // Value handling. For a delegatecall multiSend (operation 1) the outer value is
  // IGNORED by delegatecall — each inner call's value is paid from the SAFE's own
  // balance during execution. So the correct invariant is NOT "outer == Σ inner"
  // (outer is 0); it's "the Safe holds ≥ Σ inner values". For a single CALL
  // (operation 0) the outer value must equal the single inner value.
  const wrapperVal = ethers.BigNumber.from(tx.value || "0");
  let balNote = "";
  if (Number(tx.operation) === 0) {
    if (!wrapperVal.eq(sum)) crit.push(`single-call value ${wrapperVal} != inner value ${sum}`);
  } else {
    if (!wrapperVal.isZero()) warn.push(`outer multiSend value ${wrapperVal} is non-zero (ignored by delegatecall)`);
    if (cfg.rpc && !sum.isZero()) {
      try {
        const bal = await new ethers.providers.JsonRpcProvider(cfg.rpc).getBalance(cfg.safe);
        balNote = ` | Safe native balance ${ethers.utils.formatEther(bal)}`;
        if (bal.lt(sum)) warn.push(`Safe native balance ${ethers.utils.formatEther(bal)} < Σ inner values ${ethers.utils.formatEther(sum)} — batch reverts until topped up`);
      } catch (e) { /* balance check is advisory */ }
    }
  }

  console.log("\nDECODED INNER TRANSACTIONS");
  console.log("─".repeat(80));
  for (const l of lines) console.log("  " + l);
  console.log("─".repeat(80));
  console.log(`  Σ inner value = ${sum.toString()} wei (${ethers.utils.formatEther(sum)} native, paid from the Safe's balance via delegatecall)${balNote}\n`);

  const sha256 = (s) => crypto.createHash("sha256").update(s).digest("hex");
  const fingerprint = sha256(JSON.stringify({ chainId, safe: SAFE, txs: struct }));
  console.log("FINGERPRINT");
  console.log("─".repeat(80));
  console.log(`  structural : ${fingerprint}`);
  console.log(`               ↑ must EQUAL the structural fingerprint from verify-safe-batch.js`);
  console.log(`                 (run on the JSON) and from an independent generator re-run.\n`);

  // Optional live quote checks — bound each swap/GLP minOut against a fresh on-chain
  // quote (GM/GLV are GMX-keeper/oracle-priced, not pool-sandwichable, so not re-quoted).
  if (checkQuotes) {
    console.log("LIVE QUOTE CHECKS (on by default; --offline to skip)");
    console.log("─".repeat(80));
    if (!cfg.rpc) {
      warn.push("--check-quotes: no RPC configured — minOut not bounded");
    } else {
      const provider = new ethers.providers.JsonRpcProvider(cfg.rpc);
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
            const price = await new ethers.Contract(cfg.glpManager, GLP_MANAGER, provider).getPrice(false);
            const live = q.glpAmount.mul(price).div(ethers.BigNumber.from(10).pow(42));
            console.log(`  ${q.tag} glp  : minOut ${q.minOut} vs live NAV ${live} → ${assess(q.tag, "GLP", false, q.minOut, live)}`);
          }
        } catch (e) {
          crit.push(`${q.tag}: live quote check FAILED (${e.message}) — minOut NOT bounded; fix RPC or re-run with --no-quotes to accept the risk`);
        }
      }
      console.log(`  (GM/GLV mins are GMX-keeper/oracle-priced — not pool-sandwichable — so not re-quoted.)`);
    }
    console.log("");
  } else if (quoteChecks.length) {
    console.log(`⚠  --no-quotes: ${quoteChecks.length} swap/GLP minOut(s) NOT bounded against live quotes (only checked ≠0). Less safe.\n`);
  }

  if (warn.length) { console.log("⚠  WARNINGS:"); for (const w of warn) console.log("   • " + w); console.log(""); }
  if (crit.length) {
    console.log("⛔ CRITICAL FAILURES — DO NOT SIGN:");
    for (const c of crit) console.log("   • " + c);
    console.log("");
    process.exit(1);
  }
  console.log("✅ All CRITICAL invariants passed (safeTxHash reproduced; wrapper, recipients,");
  console.log("   approvals, slippage and value all verified). Final sanity: glance at a Tenderly");
  console.log("   sim for net asset changes + NO change to Safe owners/threshold/modules/guard.");
})();
