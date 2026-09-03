/**
 * Generate Gnosis Safe (Transaction Builder) batch JSON to unwind the DeFi
 * positions held by a Safe. Covers:
 *   • GM markets (GMX V2)              → ExchangeRouter.multicall(createWithdrawal)
 *   • GM+ markets (GMX V2 single-side) → same flow as GM (same router/vault)
 *   • GLV vaults (GMX Liquidity Vaults)→ GlvRouter.multicall(createGlvWithdrawal)
 *   • GLP (GMX V1)                     → RewardRouterV2.unstakeAndRedeemGlp
 *   • BENQI sAVAX        (Avalanche)   → DEX swap sAVAX→USDC (15-day native-unstake
 *                                        avoided; liquid swap instead)
 *   • Yield Yak vaults   (Avalanche)   → YakStrategy.withdraw → deposit token back
 *                                        (GMX-fsGLP vault chains into the GLP redeem)
 *
 * Supports Avalanche and Arbitrum. sAVAX + Yield Yak are Avalanche-only (config-gated).
 *
 * EXECUTION FEE (GMX GM/GM+/GLV): the native `value` is computed dynamically from
 * the GMX V2 DataStore (on-chain data reader, `getUint(bytes32)`) via GMX's own
 * GasUtils formula (adjustedGasLimit × gasPrice, 1.5× headroom), so it satisfies
 * GMX's `validateExecutionFee` at creation; GMX refunds the unused portion to the
 * Safe. Top-level `totalValue` = Σ inner tx values, so the multiSend is funded.
 *
 * SLIPPAGE PROTECTION (minOut, default 2%):
 *   • GM/GM+ : SyntheticsReader.getWithdrawalAmountOut (6-arg, swapPricingType=
 *              Withdrawal) on live GMX tickers → per-side minLong/minShort.
 *   • GLV    : GlvReader.getGlvTokenPrice → GM-equivalent of the target market →
 *              same getWithdrawalAmountOut for the exact split.
 *   • sAVAX  : DEX router getAmountsOut quote → minOut.
 *   • GLP    : GlpManager NAV → minOut (in tokenOut).
 *   • Yield Yak withdrawals are 1:1 share→underlying (no slippage surface).
 * A protected position whose min can't be computed is SKIPPED (never emitted
 * unprotected) unless --allow-no-min.
 *
 * Usage:
 *   node tools/scripts/unwind-gnosis-safe.js [avax|arb|all] [flags]
 *
 *   [avax|arb|all]   target chain(s)                              (default: all)
 *   --no-glp         skip the GLP redeem. By DEFAULT the GLP redeem is ON: it
 *                    redeems direct fsGLP + any GLP a YY-fsGLP withdrawal pulls in
 *                    → USDC, chained in one batch (YY withdraw emitted first).
 *                    (--glp/--with-glp/--include-glp are accepted no-ops now.)
 *   --no-savax       skip the BENQI sAVAX → USDC swap (Avalanche)
 *   --no-yieldyak    skip the Yield Yak vault withdrawals (alias: --no-yak)
 *   --dust=<usd>     skip priced positions worth less than this (default $1, ON).
 *                    --dust=0 or --include-dust unwinds dust too.
 *   --allow-no-min   emit positions even if min-out can't be computed (min=0,
 *                    NO slippage protection). Default: skip such positions.
 *
 * Requires: ethers v5 (npm install ethers@5)
 */

const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

// ─── Chain Configs ────────────────────────────────────────────────────────────

const CHAINS = {
  avax: {
    name: "Avalanche",
    chainId: "43114",
    rpc: "https://api.avax.network/ext/bc/C/rpc",
    safeAddress: "0x18C244c62372dF1b933CD455769f9B4DdB820F0C",
    // Fallback only — execution fee is normally read live from the DataStore.
    executionFeeFallback: ethers.utils.parseEther("0.03"), // 0.03 AVAX
    router: "0x820F5FfC5b525cD4d88Cd91aCf2c28F16530Cc68",
    exchangeRouter: "0x8f550E53DFe96C055D5Bdb267c21F268fCAF63B2",
    withdrawalVault: "0xf5F30B10141E1F63FC11eD772931A8294a591996",
    // GMX V2 DataStore (on-chain data reader for gas-limit / fee params)
    dataStore: "0x2F0b22339414ADeD7D5F06f9D604c7fF5b2fe3f6",
    // GMX V2 SyntheticsReader — getWithdrawalAmountOut / getMarket(s) / getMarketTokenPrice
    reader: "0x62Cb8740E6986B29dC671B2EB596676f60590A5B",
    // GMX GlvReader — getGlvInfo / getGlvTokenPrice (for GLV NAV)
    glvReader: "0x5C6905A3002f989E1625910ba1793d40a031f947",
    // GMX off-chain oracle prices (same the keeper executes against), keyed by token address
    gmxTickers: [
      "https://avalanche-api.gmxinfra.io/prices/tickers",
      "https://avalanche-api.gmxinfra2.io/prices/tickers",
    ],
    nativeSymbol: "AVAX",
    redstoneService: "redstone-primary-prod",
    // GM markets (multi-asset) + GM+ markets (single-asset). Both use the same
    // ExchangeRouter / WithdrawalVault and the same createWithdrawal flow, so
    // they share this list. `kind` only affects display labelling.
    markets: [
      // GM (multi-asset)
      { kind: "GM",  name: "GM_BTC_BTCb_USDC",   gmToken: "0xFb02132333A79C8B5Bd0b64E3AbccA5f7fAf2937" },
      { kind: "GM",  name: "GM_ETH_WETHe_USDC",  gmToken: "0xB7e69749E3d2EDd90ea59A4932EFEa2D41E245d7" },
      { kind: "GM",  name: "GM_AVAX_WAVAX_USDC", gmToken: "0x913C1F46b48b3eD35E7dc3Cf754d4ae8499F31CF" },
      // GM+ (single-asset)
      { kind: "GM+", name: "GM_BTC_BTCb",        gmToken: "0x3ce7BCDB37Bf587d1C17B930Fa0A7000A0648D12" },
      { kind: "GM+", name: "GM_ETH_WETHe",       gmToken: "0x2A3Cf4ad7db715DF994393e4482D6f1e58a1b533" },
      { kind: "GM+", name: "GM_AVAX_WAVAX",      gmToken: "0x08b25A2a89036d298D6dB8A74ace9d1ce6Db15E5" },
    ],
    glv: {
      glvRouter: "0x7E425c47b2Ff0bE67228c842B9C792D0BCe58ae6",
      withdrawalVault: "0x527FB0bCfF63C47761039bB386cFE181A92a4701",
      // approve target is the GMX V2 Router (same as GM)
      approveSpender: "0x820F5FfC5b525cD4d88Cd91aCf2c28F16530Cc68",
      vaults: [
        {
          name: "GLV_WAVAX_USDC",
          glvToken: "0x901eE57f7118A7be56ac079cbCDa7F22663A3874",
          // Underlying GM market to settle into when unwinding
          targetMarket: "0x913C1F46b48b3eD35E7dc3Cf754d4ae8499F31CF", // GM_AVAX_WAVAX_USDC
        },
      ],
    },
    glp: {
      // sGLP / fsGLP token (ERC20 transfer-restricted; balanceOf returns staked GLP)
      glpToken: "0x9e295B5B976a184B14aD8cd72413aD846C299660",
      // RewardRouterV2 used for unstakeAndRedeemGlp
      rewardRouter: "0xB70B91CE0771d3f4c81D87660f71Da31d48eB3B3",
      // GlpManager — used only for on-chain price lookup
      glpManager: "0xD152c7F25db7F4B95b7658323c5F33d176818EE4",
      // Token to redeem GLP into (USDC default — must be GLP-supported)
      tokenOut: "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", // USDC (native)
      tokenOutSymbol: "USDC",
      tokenOutDecimals: 6,
    },
    // BENQI sAVAX (liquid-staking receipt held in the wallet). 15-day cooldown to
    // native-unstake, so we exit via a DEX swap instead: sAVAX→WAVAX→USDC on
    // TraderJoe V1 (deep liquidity in both hops), minOut from getAmountsOut.
    savax: {
      token: "0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE",
      swapRouter: "0x60aE616a2155Ee3d9A68541Ba4544862310933d4", // TraderJoe V1 Router
      swapRouterLabel: "TraderJoe V1 Router",
      swapPath: [
        "0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE", // sAVAX
        "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", // WAVAX
        "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E", // USDC
      ],
      outSymbol: "USDC",
      outDecimals: 6,
      // RedStone feed for the staked asset, used for the manipulation-resistant floor.
      oracleSymbol: "AVAX",
    },
    // Yield Yak auto-compounding vaults (YakStrategyV2: withdraw(shares) burns the
    // YRT receipt and returns the deposit token — no approve, you burn your own).
    // The GMX-fsGLP vault returns GLP into the Safe; when --glp is set we chain the
    // GLP redeem after it. Aave-AVAX returns native AVAX. (gAVAX dust + the defunct
    // Platypus sAVAX vault are intentionally omitted.)
    yieldYak: {
      vaults: [
        { name: "YY_GMX_fsGLP", token: "0x9f637540149f922145c06e1aa3f38dcDc32Aff5C", isGlp: true,  out: "GLP" },
        { name: "YY_AAVE_AVAX", token: "0xaAc0F2d0630d1D09ab2B5A400412a4840B866d95", isGlp: false, out: "AVAX (native)" },
      ],
    },
  },

  arb: {
    name: "Arbitrum",
    chainId: "42161",
    rpc: "https://arb1.arbitrum.io/rpc",
    safeAddress: "0x764a9756994f4E6cd9358a6FcD924d566fC2e666",
    // Fallback only — execution fee is normally read live from the DataStore.
    executionFeeFallback: ethers.utils.parseEther("0.002"), // 0.002 ETH
    router: "0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6",
    exchangeRouter: "0x1C3fa76e6E1088bCE750f23a5BFcffa1efEF6A41",
    withdrawalVault: "0x0628D46b5D145f183AdB6Ef1f2c97eD1C4701C55",
    // GMX V2 DataStore (on-chain data reader for gas-limit / fee params)
    dataStore: "0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8",
    // GMX V2 SyntheticsReader — getWithdrawalAmountOut / getMarket(s) / getMarketTokenPrice
    reader: "0x470fbC46bcC0f16532691Df360A07d8Bf5ee0789",
    // GMX GlvReader — getGlvInfo / getGlvTokenPrice (for GLV NAV)
    glvReader: "0x2C670A23f1E798184647288072e84054938B5497",
    // GMX off-chain oracle prices (same the keeper executes against), keyed by token address
    gmxTickers: [
      "https://arbitrum-api.gmxinfra.io/prices/tickers",
      "https://arbitrum-api.gmxinfra2.io/prices/tickers",
    ],
    nativeSymbol: "ETH",
    redstoneService: "redstone-primary-prod",
    markets: [
      // GM (multi-asset)
      { kind: "GM",  name: "GM_ETH_WETH_USDC",   gmToken: "0x70d95587d40A2caf56bd97485aB3Eec10Bee6336" },
      { kind: "GM",  name: "GM_ARB_ARB_USDC",    gmToken: "0xC25cEf6061Cf5dE5eb761b50E4743c1F5D7E5407" },
      { kind: "GM",  name: "GM_LINK_LINK_USDC",  gmToken: "0x7f1fa204bb700853D36994DA19F830b6Ad18455C" },
      { kind: "GM",  name: "GM_UNI_UNI_USDC",    gmToken: "0xc7Abb2C5f3BF3CEB389dF0Eecd6120D451170B50" },
      { kind: "GM",  name: "GM_BTC_WBTC_USDC",   gmToken: "0x47c031236e19d024b42f8AE6780E44A573170703" },
      { kind: "GM",  name: "GM_SOL_SOL_USDC",    gmToken: "0x09400D9DB990D5ed3f35D7be61DfAEB900Af03C9" },
      { kind: "GM",  name: "GM_NEAR_WETH_USDC",  gmToken: "0x63Dc80EE90F26363B3FCD609007CC9e14c8991BE" },
      { kind: "GM",  name: "GM_ATOM_WETH_USDC", gmToken: "0x248C35760068cE009a13076D573ed3497A47bCD4" },
      { kind: "GM",  name: "GM_GMX_GMX_USDC",   gmToken: "0x55391D178Ce46e7AC8eaAEa50A72D1A5a8A622Da" },
      { kind: "GM",  name: "GM_SUI_WETH_USDC",  gmToken: "0x6Ecf2133E2C9751cAAdCb6958b9654baE198a797" },
      { kind: "GM",  name: "GM_SEI_WETH_USDC",  gmToken: "0xB489711B1cB86afDA48924730084e23310EB4883" },
      // GM+ (single-asset)
      { kind: "GM+", name: "GM_ETH_WETH",        gmToken: "0x450bb6774Dd8a756274E0ab4107953259d2ac541" },
      { kind: "GM+", name: "GM_BTC_WBTC",        gmToken: "0x7C11F78Ce78768518D743E81Fdfa2F860C6b9A77" },
      { kind: "GM+", name: "GM_GMX_GMX",         gmToken: "0xbD48149673724f9cAeE647bb4e9D9dDaF896Efeb" },
    ],
    glv: {
      glvRouter: "0x7EAdEE2ca1b4D06a0d82fDF03D715550c26AA12F",
      withdrawalVault: "0x393053B58f9678C9c28c2cE941fF6cac49C3F8f9",
      approveSpender: "0x7452c558d45f8afC8c83dAe62C3f8A5BE19c71f6",
      vaults: [
        {
          name: "GLV_WETH_USDC",
          glvToken: "0x528A5bac7E746C9A509A1f4F6dF58A03d44279F9",
          targetMarket: "0x70d95587d40A2caf56bd97485aB3Eec10Bee6336", // GM_ETH_WETH_USDC
        },
        {
          name: "GLV_BTC_USDC",
          glvToken: "0xdF03EEd325b82bC1d4Db8b49c30ecc9E05104b96",
          targetMarket: "0x47c031236e19d024b42f8AE6780E44A573170703", // GM_BTC_WBTC_USDC
        },
      ],
    },
    glp: {
      glpToken: "0x5402B5F40310bDED796c7D0F3FF6683f5C0cFfdf",
      rewardRouter: "0xB95DB5B167D75e6d04227CfFFA61069348d271F5",
      glpManager: "0x3963FfC9dff443c2A94f21b129D429891E32ec18",
      // USDC redemption reverts with "Vault: reserve exceeds pool" — the GMX V1
      // vault has reservedAmounts ≈ poolAmounts on USDC/WETH/WBTC and buffer
      // floors >> pool. LINK is currently the only token with real headroom
      // (~$1.27K available as of 2026-05-05). Swap LINK → USDC after redemption.
      tokenOut: "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4", // LINK
      tokenOutSymbol: "LINK",
      tokenOutDecimals: 18, // LINK is 18 dp — without this the GLP minOut floor scales 1e12× too small
    },
  },
};

// ─── ABIs (minimal) ──────────────────────────────────────────────────────────

const ERC20_ABI = [
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
];

const GMX_ROUTER_ABI = [
  "function sendWnt(address receiver, uint256 amount) payable",
  "function sendTokens(address token, address receiver, uint256 amount) payable",
];

const EXCHANGE_ROUTER_ABI = [
  "function multicall(bytes[] calldata data) payable returns (bytes[] memory)",
  `function createWithdrawal(
    (
      (
        address receiver,
        address callbackContract,
        address uiFeeReceiver,
        address market,
        address[] longTokenSwapPath,
        address[] shortTokenSwapPath
      ) addresses,
      uint256 minLongTokenAmount,
      uint256 minShortTokenAmount,
      bool shouldUnwrapNativeToken,
      uint256 executionFee,
      uint256 callbackGasLimit,
      bytes32[] dataList
    ) params
  ) payable returns (bytes32)`,
];

const GLV_ROUTER_ABI = [
  "function multicall(bytes[] calldata data) payable returns (bytes[] memory)",
  `function createGlvWithdrawal(
    (
      (
        address receiver,
        address callbackContract,
        address uiFeeReceiver,
        address market,
        address glv,
        address[] longTokenSwapPath,
        address[] shortTokenSwapPath
      ) addresses,
      uint256 minLongTokenAmount,
      uint256 minShortTokenAmount,
      bool shouldUnwrapNativeToken,
      uint256 executionFee,
      uint256 callbackGasLimit,
      bytes32[] dataList
    ) params
  ) payable returns (bytes32)`,
];

const REWARD_ROUTER_V2_ABI = [
  "function unstakeAndRedeemGlp(address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) returns (uint256)",
];

const GLP_MANAGER_ABI = [
  "function getPrice(bool _maximise) view returns (uint256)",
];

// GMX V2 DataStore — the canonical on-chain data reader for protocol params.
const DATASTORE_ABI = [
  "function getUint(bytes32 key) view returns (uint256)",
  "function getAddressCount(bytes32 setKey) view returns (uint256)",
];

// UniswapV2-style DEX router (TraderJoe V1 / Pangolin) — used to swap sAVAX→USDC.
const DEX_ROUTER_ABI = [
  "function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[])",
  "function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] path, address to, uint256 deadline) returns (uint256[])",
];

// Yield Yak YakStrategyV2 — withdraw(shares) burns the YRT receipt and returns
// the deposit token. No approve needed (you burn your own shares).
const YAK_STRATEGY_ABI = [
  "function withdraw(uint256 amount)",
  "function depositToken() view returns (address)",
  "function getDepositTokensForShares(uint256 amount) view returns (uint256)",
];

// ─── GMX execution-fee computation (via DataStore data reader) ─────────────────
//
// GMX validates `executionFee >= adjustedGasLimit * tx.gasprice` inside
// createWithdrawal / createGlvWithdrawal (GasUtils.validateExecutionFee), where
// tx.gasprice is the gas price WHEN THE SAFE EXECUTES — possibly long after this
// JSON is generated. We replicate GasUtils exactly off the DataStore, then floor
// the gas price at 2× current baseFee and apply a safety multiplier for drift.
//
// Overpayment is harmless: after the keeper executes, GMX's GasUtils.payExecutionFee
// refunds the UNUSED execution fee (provided fee − actual keeper gas) in native
// token to the withdrawal's `account` — i.e. back to THIS Safe (verified: that is
// exactly the native refund DeltaPrime's GmxV2CallbacksFacet re-wraps post-exec).
// So a 1.5× cushion costs nothing in steady state; it only ever means a slightly
// larger temporary outlay that comes straight back.

// Unused gas-fee headroom is refunded, so we err a little high. Effective gasPrice =
// max(currentGasPrice, 2×baseFee) × this multiplier (expressed in bps for BigNumber math).
const EXEC_FEE_GAS_PRICE_MULT_BPS = 15000; // 1.5×
const EXEC_FEE_GAS_PRICE_MULTIPLIER = EXEC_FEE_GAS_PRICE_MULT_BPS / 10000; // for display

// GasUtils precision: Precision.applyFactor(value, factor) = value * factor / 1e30
const GAS_FEE_PRECISION = ethers.BigNumber.from("1000000000000000000000000000000");
const applyFactor = (value, factor) => value.mul(factor).div(GAS_FEE_PRECISION);

// GMX DataStore keys are keccak256(abi.encode("NAME")) — computed by ethers
// (never hand-guessed). Per-vault GLV market-list key adds the vault address.
const hashString = (s) =>
  ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["string"], [s]));
const hashStringAddr = (s, addr) =>
  ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["bytes32", "address"], [hashString(s), addr])
  );

const GMX_KEYS = {
  WITHDRAWAL_GAS_LIMIT: hashString("WITHDRAWAL_GAS_LIMIT"),
  ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1: hashString("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"),
  ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR: hashString("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"),
  ESTIMATED_GAS_FEE_PER_ORACLE_PRICE: hashString("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"),
  GLV_WITHDRAWAL_GAS_LIMIT: hashString("GLV_WITHDRAWAL_GAS_LIMIT"),
  GLV_PER_MARKET_GAS_LIMIT: hashString("GLV_PER_MARKET_GAS_LIMIT"),
};

/**
 * Read GMX gas-limit / fee params from the DataStore and derive the execution
 * fee for a GM/GM+ withdrawal (uniform) and for each GLV vault (depends on how
 * many markets that GLV holds). Returns BigNumber wei values.
 */
async function computeGmxExecutionFees(chain, provider) {
  const ds = new ethers.Contract(chain.dataStore, DATASTORE_ABI, provider);

  const [
    withdrawalGasLimit,
    baseAmount,
    multiplierFactor,
    perOraclePrice,
    glvWithdrawalGasLimit,
    glvPerMarketGasLimit,
    rawGasPrice,
    block,
  ] = await Promise.all([
    ds.getUint(GMX_KEYS.WITHDRAWAL_GAS_LIMIT),
    ds.getUint(GMX_KEYS.ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1),
    ds.getUint(GMX_KEYS.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR),
    ds.getUint(GMX_KEYS.ESTIMATED_GAS_FEE_PER_ORACLE_PRICE),
    ds.getUint(GMX_KEYS.GLV_WITHDRAWAL_GAS_LIMIT),
    ds.getUint(GMX_KEYS.GLV_PER_MARKET_GAS_LIMIT),
    provider.getGasPrice(),
    provider.getBlock("latest"),
  ]);

  const baseFee = block.baseFeePerGas || ethers.BigNumber.from(0);
  const floor = baseFee.mul(2);
  let gasPrice = rawGasPrice.gt(floor) ? rawGasPrice : floor;
  gasPrice = gasPrice.mul(EXEC_FEE_GAS_PRICE_MULT_BPS).div(10000);

  // GasUtils.adjustGasLimitForEstimate: base + perOracle*oracleCount + factor·estGas
  const adjust = (estGasLimit, oracleCount) =>
    baseAmount
      .add(perOraclePrice.mul(oracleCount))
      .add(applyFactor(estGasLimit, multiplierFactor));

  // GM / GM+ withdrawal: no swap paths, no callback → estGas = withdrawalGasLimit.
  // estimateWithdrawalOraclePriceCount(0 swaps) = 3.
  const gmFee = adjust(withdrawalGasLimit, ethers.BigNumber.from(3)).mul(gasPrice);

  // GLV withdrawal: keeper revalues the whole GLV, so gas + oracle count scale
  // with the number of markets the GLV holds. estGas = glvWithdrawalGasLimit +
  // glvPerMarket*marketCount + withdrawalGasLimit (the underlying GM withdrawal).
  const glvFeeByToken = {};
  if (chain.glv) {
    await Promise.all(
      chain.glv.vaults.map(async (v) => {
        let marketCount;
        try {
          marketCount = await ds.getAddressCount(
            hashStringAddr("GLV_SUPPORTED_MARKET_LIST", v.glvToken)
          );
        } catch (_) {
          marketCount = ethers.BigNumber.from(20); // conservative fallback
        }
        const estGlv = glvWithdrawalGasLimit
          .add(glvPerMarketGasLimit.mul(marketCount))
          .add(withdrawalGasLimit);
        const oracleCount = marketCount.add(2);
        glvFeeByToken[v.glvToken.toLowerCase()] = {
          fee: adjust(estGlv, oracleCount).mul(gasPrice),
          marketCount,
        };
      })
    );
  }

  return {
    gmFee,
    glvFeeByToken,
    gasPrice,
    rawGasPrice,
    baseFee,
    params: { withdrawalGasLimit, baseAmount, multiplierFactor, perOraclePrice },
  };
}

// ─── GMX min-output computation (via SyntheticsReader / GlvReader) ─────────────
//
// We ask GMX's own Reader for the exact, price-impact- and fee-aware per-side
// output of each withdrawal (matching what the keeper will deliver), then shave
// MIN_OUT_SLIPPAGE_BPS off as the minLong/minShort floor. This protects the Safe
// from being sandwiched/"rugged" on the underlying GM swap. Mirrors the approach
// the liquidation bot uses (aws-serverless gmxV2.js, commit 00fd3800) and the
// DeltaPrime UI, on the current Reader (6-arg getWithdrawalAmountOut w/
// swapPricingType=Withdrawal) so the estimate matches the keeper's execution path.
//
// GLV has no direct amount-out function, so we value the GLV via GlvReader
// (getGlvTokenPrice over its markets), convert to the equivalent amount of the
// settlement (target) GM market at that market's GM price, then run the same
// getWithdrawalAmountOut for the exact per-side split — replicating GMX's own
// GLV→GM→tokens settlement path.

// Per-side slippage shaved off GMX's exact estimate. 2% absorbs price/pool drift
// between Safe-tx generation and (delayed) multisig execution + async keeper run,
// while staying well inside fair value. Below the keeper's per-side check so the
// withdrawal executes rather than getting cancelled.
const MIN_OUT_SLIPPAGE_BPS = 200; // 2%

// Independent oracle safety-net for the sAVAX swap floor. The AMM's own getAmountsOut
// can be skewed if the pool is manipulated when the generator runs, so we ALSO derive
// a floor from the sAVAX→AVAX on-chain stake rate × the AVAX oracle price, and take the
// HIGHER of the two as minOut. This band must exceed the honest 2-hop swap cost (~2.4%
// for our size) so it never reverts legitimately; it only binds (capping loss) when the
// AMM quote is suspiciously low. 5% = honest cost + margin, worst-case loss ceiling.
const SAVAX_ORACLE_FLOOR_BPS = 500; // 5%

// Dust filter (ON by default): priced positions worth less than this many USD are
// skipped — unwinding cents isn't worth the keeper gas / exec fee. Override with
// --dust=<usd>; disable with --dust=0 (or --include-dust). Positions with no USD
// value (Yield Yak 1:1 withdrawals) are never dust-filtered.
const DUST_USD_DEFAULT = 1;

// ISwapPricingUtils.SwapPricingType.Withdrawal — matches the keeper's path.
const SWAP_PRICING_TYPE_WITHDRAWAL = 4;
const MAX_PNL_FACTOR_FOR_WITHDRAWALS = hashString("MAX_PNL_FACTOR_FOR_WITHDRAWALS");

const READER_ABI = [
  "function getMarket(address dataStore, address key) view returns (tuple(address marketToken, address indexToken, address longToken, address shortToken))",
  "function getMarkets(address dataStore, uint256 start, uint256 end) view returns (tuple(address marketToken, address indexToken, address longToken, address shortToken)[])",
  "function getMarketTokenPrice(address dataStore, tuple(address marketToken, address indexToken, address longToken, address shortToken) market, tuple(uint256 min, uint256 max) indexTokenPrice, tuple(uint256 min, uint256 max) longTokenPrice, tuple(uint256 min, uint256 max) shortTokenPrice, bytes32 pnlFactorType, bool maximize) view returns (int256, tuple(int256 poolValue, int256 longPnl, int256 shortPnl, int256 netPnl, uint256 longTokenAmount, uint256 shortTokenAmount, uint256 longTokenUsd, uint256 shortTokenUsd, uint256 totalBorrowingFees, uint256 borrowingFeePoolFactor, uint256 impactPoolAmount, uint256 lentImpactPoolAmount))",
  "function getWithdrawalAmountOut(address dataStore, tuple(address marketToken, address indexToken, address longToken, address shortToken) market, tuple(tuple(uint256 min, uint256 max) indexTokenPrice, tuple(uint256 min, uint256 max) longTokenPrice, tuple(uint256 min, uint256 max) shortTokenPrice) prices, uint256 marketTokenAmount, address uiFeeReceiver, uint8 swapPricingType) view returns (uint256, uint256)",
];

const GLV_READER_ABI = [
  "function getGlvInfo(address dataStore, address glv) view returns (tuple(tuple(address glvToken, address longToken, address shortToken) glv, address[] markets))",
  "function getGlvTokenPrice(address dataStore, address[] marketAddresses, tuple(uint256 min, uint256 max)[] indexTokenPrices, tuple(uint256 min, uint256 max) longTokenPrice, tuple(uint256 min, uint256 max) shortTokenPrice, address glv, bool maximize) view returns (uint256, uint256, uint256)",
];

async function fetchGmxTickers(chain) {
  let lastErr;
  for (const url of chain.gmxTickers) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(8000) });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const arr = await res.json();
      const map = {};
      for (const t of arr) {
        map[t.tokenAddress.toLowerCase()] = {
          min: ethers.BigNumber.from(t.minPrice),
          max: ethers.BigNumber.from(t.maxPrice),
        };
      }
      return map;
    } catch (e) {
      lastErr = e;
    }
  }
  throw new Error(`GMX tickers fetch failed: ${lastErr && lastErr.message}`);
}

function tickerPrice(map, addr, label) {
  if (addr === ethers.constants.AddressZero) return { min: 0, max: 0 };
  const p = map[addr.toLowerCase()];
  if (!p) throw new Error(`GMX ticker missing price for ${label} ${addr}`);
  return p;
}

const applyMinSlippage = (amount) =>
  amount.mul(10000 - MIN_OUT_SLIPPAGE_BPS).div(10000);

// One-time per-chain context: Reader/GlvReader contracts, oracle tickers, and a
// marketToken→Props map (so we don't getMarket() once per market).
async function buildGmxMinOutContext(chain, provider) {
  const reader = new ethers.Contract(chain.reader, READER_ABI, provider);
  const glvReader = chain.glvReader
    ? new ethers.Contract(chain.glvReader, GLV_READER_ABI, provider)
    : null;
  const [tickers, allMarkets] = await Promise.all([
    fetchGmxTickers(chain),
    reader.getMarkets(chain.dataStore, 0, 1000),
  ]);
  const marketProps = {};
  for (const m of allMarkets) marketProps[m.marketToken.toLowerCase()] = m;
  return { chain, reader, glvReader, tickers, marketProps };
}

async function getMarketProps(ctx, marketToken) {
  return (
    ctx.marketProps[marketToken.toLowerCase()] ||
    (await ctx.reader.getMarket(ctx.chain.dataStore, marketToken))
  );
}

function pricesForMarket(ctx, props, label) {
  return {
    indexTokenPrice: tickerPrice(ctx.tickers, props.indexToken, `${label} index`),
    longTokenPrice: tickerPrice(ctx.tickers, props.longToken, `${label} long`),
    shortTokenPrice: tickerPrice(ctx.tickers, props.shortToken, `${label} short`),
  };
}

// Exact per-side min-out for a GM / GM+ withdrawal of `gmAmount`.
async function computeGmMinOut(ctx, gmToken, gmAmount, label) {
  const props = await getMarketProps(ctx, gmToken);
  const prices = pricesForMarket(ctx, props, label);
  const [expLong, expShort] = await ctx.reader.getWithdrawalAmountOut(
    ctx.chain.dataStore,
    props,
    prices,
    gmAmount,
    ethers.constants.AddressZero,
    SWAP_PRICING_TYPE_WITHDRAWAL
  );
  return {
    minLong: applyMinSlippage(expLong),
    minShort: applyMinSlippage(expShort),
    expLong,
    expShort,
    longToken: props.longToken,
    shortToken: props.shortToken,
  };
}

// Exact per-side min-out for a GLV withdrawal of `glvAmount` settling into
// `targetMarket`: value GLV via GlvReader → GM-equivalent of targetMarket →
// getWithdrawalAmountOut for the real long/short split.
async function computeGlvMinOut(ctx, glvToken, targetMarket, glvAmount, label) {
  if (!ctx.glvReader) throw new Error("no GlvReader configured");
  const glvInfo = await ctx.glvReader.getGlvInfo(ctx.chain.dataStore, glvToken);

  // index price for every market the GLV holds (aligned with glvInfo.markets)
  const indexPrices = [];
  for (const mkt of glvInfo.markets) {
    const props = await getMarketProps(ctx, mkt);
    indexPrices.push(tickerPrice(ctx.tickers, props.indexToken, `${label} market ${mkt} index`));
  }
  const longP = tickerPrice(ctx.tickers, glvInfo.glv.longToken, `${label} long`);
  const shortP = tickerPrice(ctx.tickers, glvInfo.glv.shortToken, `${label} short`);

  // maximize=false → conservative (min) GLV value → conservative gmEquiv → safe min
  const [glvPrice] = await ctx.glvReader.getGlvTokenPrice(
    ctx.chain.dataStore,
    glvInfo.markets,
    indexPrices,
    longP,
    shortP,
    glvToken,
    false
  );

  const targetProps = await getMarketProps(ctx, targetMarket);
  const tPrices = pricesForMarket(ctx, targetProps, `${label} target`);
  const [gmTargetPriceInt] = await ctx.reader.getMarketTokenPrice(
    ctx.chain.dataStore,
    targetProps,
    tPrices.indexTokenPrice,
    tPrices.longTokenPrice,
    tPrices.shortTokenPrice,
    MAX_PNL_FACTOR_FOR_WITHDRAWALS,
    false
  );
  const gmTargetPrice = ethers.BigNumber.from(gmTargetPriceInt);
  if (gmTargetPrice.lte(0)) throw new Error("non-positive GM target price");

  // GLV and GM prices share GMX's 1e30 convention → ratio is unit-free, and GLV
  // and GM tokens both have 18 decimals → gmEquiv is in 1e18 GM units.
  const gmEquiv = glvAmount.mul(glvPrice).div(gmTargetPrice);

  const [expLong, expShort] = await ctx.reader.getWithdrawalAmountOut(
    ctx.chain.dataStore,
    targetProps,
    tPrices,
    gmEquiv,
    ethers.constants.AddressZero,
    SWAP_PRICING_TYPE_WITHDRAWAL
  );
  return {
    minLong: applyMinSlippage(expLong),
    minShort: applyMinSlippage(expShort),
    expLong,
    expShort,
    gmEquiv,
    longToken: targetProps.longToken,
    shortToken: targetProps.shortToken,
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

async function fetchRedstonePrices(serviceId) {
  const url = `https://oracle-gateway-1.a.redstone.finance/data-packages/latest/${serviceId}`;
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`RedStone gateway ${serviceId} returned HTTP ${res.status}`);
  }
  const json = await res.json();
  const prices = {};
  for (const [feedId, packages] of Object.entries(json)) {
    if (!Array.isArray(packages) || packages.length === 0) continue;
    const values = packages
      .map((p) => p?.dataPoints?.[0]?.value)
      .filter((v) => typeof v === "number" && Number.isFinite(v))
      .sort((a, b) => a - b);
    if (values.length === 0) continue;
    prices[feedId] = values[Math.floor(values.length / 2)]; // median
  }
  return prices;
}

function formatUsd(n) {
  if (n >= 1_000_000) return `$${(n / 1_000_000).toFixed(2)}M`;
  if (n >= 1_000) return `$${(n / 1_000).toFixed(2)}K`;
  return `$${n.toFixed(2)}`;
}

function encodeApprove(spender, amount) {
  const iface = new ethers.utils.Interface(ERC20_ABI);
  return iface.encodeFunctionData("approve", [spender, amount]);
}

function encodeGmMulticall(chain, gmToken, gmAmount, receiver, executionFee, minLong, minShort) {
  const routerIface = new ethers.utils.Interface(GMX_ROUTER_ABI);
  const exchangeIface = new ethers.utils.Interface(EXCHANGE_ROUTER_ABI);

  const sendWntData = routerIface.encodeFunctionData("sendWnt", [
    chain.withdrawalVault,
    executionFee,
  ]);

  const sendTokensData = routerIface.encodeFunctionData("sendTokens", [
    gmToken,
    chain.withdrawalVault,
    gmAmount,
  ]);

  const createWithdrawalData = exchangeIface.encodeFunctionData(
    "createWithdrawal",
    [
      {
        addresses: {
          receiver: receiver,
          callbackContract: ethers.constants.AddressZero,
          uiFeeReceiver: ethers.constants.AddressZero,
          market: gmToken,
          longTokenSwapPath: [],
          shortTokenSwapPath: [],
        },
        minLongTokenAmount: minLong,
        minShortTokenAmount: minShort,
        shouldUnwrapNativeToken: false,
        executionFee: executionFee,
        callbackGasLimit: 0,
        dataList: [],
      },
    ]
  );

  return exchangeIface.encodeFunctionData("multicall", [
    [sendWntData, sendTokensData, createWithdrawalData],
  ]);
}

function encodeGlvMulticall(chain, glvToken, glvAmount, targetMarket, receiver, executionFee, minLong, minShort) {
  const routerIface = new ethers.utils.Interface(GMX_ROUTER_ABI);
  const glvIface = new ethers.utils.Interface(GLV_ROUTER_ABI);

  const sendWntData = routerIface.encodeFunctionData("sendWnt", [
    chain.glv.withdrawalVault,
    executionFee,
  ]);

  const sendTokensData = routerIface.encodeFunctionData("sendTokens", [
    glvToken,
    chain.glv.withdrawalVault,
    glvAmount,
  ]);

  const createGlvWithdrawalData = glvIface.encodeFunctionData(
    "createGlvWithdrawal",
    [
      {
        addresses: {
          receiver: receiver,
          callbackContract: ethers.constants.AddressZero,
          uiFeeReceiver: ethers.constants.AddressZero,
          market: targetMarket,
          glv: glvToken,
          longTokenSwapPath: [],
          shortTokenSwapPath: [],
        },
        minLongTokenAmount: minLong,
        minShortTokenAmount: minShort,
        shouldUnwrapNativeToken: false,
        executionFee: executionFee,
        callbackGasLimit: 0,
        dataList: [],
      },
    ]
  );

  return glvIface.encodeFunctionData("multicall", [
    [sendWntData, sendTokensData, createGlvWithdrawalData],
  ]);
}

function encodeUnstakeAndRedeemGlp(tokenOut, glpAmount, minOut, receiver) {
  const iface = new ethers.utils.Interface(REWARD_ROUTER_V2_ABI);
  return iface.encodeFunctionData("unstakeAndRedeemGlp", [
    tokenOut,
    glpAmount,
    minOut,
    receiver,
  ]);
}

function encodeSwapExactTokensForTokens(amountIn, minOut, path, to, deadline) {
  const iface = new ethers.utils.Interface(DEX_ROUTER_ABI);
  return iface.encodeFunctionData("swapExactTokensForTokens", [
    amountIn,
    minOut,
    path,
    to,
    deadline,
  ]);
}

function encodeYakWithdraw(amount) {
  const iface = new ethers.utils.Interface(YAK_STRATEGY_ABI);
  return iface.encodeFunctionData("withdraw", [amount]);
}

// ─── Position builders ───────────────────────────────────────────────────────

async function buildGmPositions(chain, provider, redstonePrices, executionFee, ctx) {
  return Promise.all(
    chain.markets.map(async (market) => {
      const token = new ethers.Contract(market.gmToken, ERC20_ABI, provider);
      const [balance, decimals, allowance] = await Promise.all([
        token.balanceOf(chain.safeAddress),
        token.decimals(),
        token.allowance(chain.safeAddress, chain.router),
      ]);
      const price = redstonePrices[market.name];
      const balanceFloat = parseFloat(ethers.utils.formatUnits(balance, decimals));
      const usdValue = price != null ? balanceFloat * price : null;

      // Exact per-side min-out from GMX's Reader (only meaningful for non-zero).
      let minOut = null, minError = null, minSummary = null;
      if (!balance.isZero()) {
        try {
          minOut = await computeGmMinOut(ctx, market.gmToken, balance, market.name);
          minSummary =
            `long ≥ ${minOut.minLong.toString()} | short ≥ ${minOut.minShort.toString()} ` +
            `(−${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% vs GMX est; long=${minOut.longToken.slice(0, 8)}… short=${minOut.shortToken.slice(0, 8)}…)`;
        } catch (e) {
          minError = e.message;
        }
      }

      return {
        kind: market.kind,
        name: market.name,
        token: market.gmToken,
        balance,
        decimals,
        allowance,
        approveSpender: chain.router,
        approveSpenderLabel: "GMX V2 Router",
        price,
        priceSource: price != null ? "RedStone" : null,
        balanceFloat,
        usdValue,
        order: 0,
        protected: true,
        minOut,
        minError,
        minSummary,
        // fingerprint entry — MUST match verify-safe-*.js exactly (fields + key order)
        fp: { t: "GM", to: chain.exchangeRouter.toLowerCase(), receiver: chain.safeAddress.toLowerCase(), market: market.gmToken.toLowerCase(), glv: "" },
        unwind: {
          to: chain.exchangeRouter,
          value: executionFee,
          buildData: (amount) =>
            encodeGmMulticall(
              chain,
              market.gmToken,
              amount,
              chain.safeAddress,
              executionFee,
              minOut ? minOut.minLong : 0,
              minOut ? minOut.minShort : 0
            ),
          label: "ExchangeRouter.multicall(createWithdrawal)",
        },
      };
    })
  );
}

async function buildGlvPositions(chain, provider, glvFeeByToken, ctx) {
  if (!chain.glv) return [];
  return Promise.all(
    chain.glv.vaults.map(async (vault) => {
      const token = new ethers.Contract(vault.glvToken, ERC20_ABI, provider);
      const [balance, decimals, allowance] = await Promise.all([
        token.balanceOf(chain.safeAddress),
        token.decimals(),
        token.allowance(chain.safeAddress, chain.glv.approveSpender),
      ]);
      const balanceFloat = parseFloat(ethers.utils.formatUnits(balance, decimals));
      const executionFee =
        (glvFeeByToken && glvFeeByToken[vault.glvToken.toLowerCase()]) ||
        chain.executionFeeFallback;

      // Exact per-side min-out via GlvReader NAV → target-market withdrawal.
      let minOut = null, minError = null, usdValue = null, minSummary = null;
      if (!balance.isZero()) {
        try {
          minOut = await computeGlvMinOut(ctx, vault.glvToken, vault.targetMarket, balance, vault.name);
          // Derive a USD estimate from the (pre-slippage) expected outputs so the
          // GLV position is no longer "n/a" in the ranking.
          const longUsd = Number(
            ethers.utils.formatUnits(minOut.expLong.mul(ctx.tickers[minOut.longToken.toLowerCase()].min), 30)
          );
          const shortUsd = Number(
            ethers.utils.formatUnits(minOut.expShort.mul(ctx.tickers[minOut.shortToken.toLowerCase()].min), 30)
          );
          usdValue = longUsd + shortUsd;
          minSummary =
            `long ≥ ${minOut.minLong.toString()} | short ≥ ${minOut.minShort.toString()} ` +
            `(−${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% vs GMX est; GLV→GM equiv ${ethers.utils.formatUnits(minOut.gmEquiv, 18)})`;
        } catch (e) {
          minError = e.message;
        }
      }

      return {
        kind: "GLV",
        name: vault.name,
        token: vault.glvToken,
        balance,
        decimals,
        allowance,
        approveSpender: chain.glv.approveSpender,
        approveSpenderLabel: "GMX V2 Router",
        price: null,
        priceSource: usdValue != null ? "GlvReader" : null,
        balanceFloat,
        usdValue,
        order: 0,
        protected: true,
        minOut,
        minError,
        minSummary,
        fp: { t: "GLV", to: chain.glv.glvRouter.toLowerCase(), receiver: chain.safeAddress.toLowerCase(), market: vault.targetMarket.toLowerCase(), glv: vault.glvToken.toLowerCase() },
        unwind: {
          to: chain.glv.glvRouter,
          value: executionFee,
          buildData: (amount) =>
            encodeGlvMulticall(
              chain,
              vault.glvToken,
              amount,
              vault.targetMarket,
              chain.safeAddress,
              executionFee,
              minOut ? minOut.minLong : 0,
              minOut ? minOut.minShort : 0
            ),
          label: `GlvRouter.multicall(createGlvWithdrawal → ${vault.targetMarket.slice(0, 10)}…)`,
        },
      };
    })
  );
}

// extraGlpFromYak: GLP that will land in the Safe from a chained YY-fsGLP
// withdrawal earlier in the same batch (0 if none). tokenOutUsd: USD price of the
// GLP redeem token (USDC≈1 on Avax, LINK on Arb) — used to size minOut.
async function buildGlpPosition(chain, provider, extraGlpFromYak, tokenOutUsd) {
  if (!chain.glp) return [];
  const token = new ethers.Contract(chain.glp.glpToken, ERC20_ABI, provider);
  const manager = new ethers.Contract(chain.glp.glpManager, GLP_MANAGER_ABI, provider);

  const [directBalance, decimals, priceRaw] = await Promise.all([
    token.balanceOf(chain.safeAddress),
    token.decimals(),
    manager.getPrice(false).catch(() => null), // 1e30 USD per GLP (min price)
  ]);

  // Redeem the Safe's direct fsGLP PLUS whatever the chained YY-fsGLP withdrawal
  // adds. YY auto-compounds, so getDepositTokensForShares is a lower bound by
  // execution time → actual fsGLP ≥ this, so the redeem can't exceed balance.
  const yyGlp = extraGlpFromYak || ethers.BigNumber.from(0);
  const balance = directBalance.add(yyGlp);

  const price = priceRaw != null
    ? parseFloat(ethers.utils.formatUnits(priceRaw, 30))
    : null;
  const balanceFloat = parseFloat(ethers.utils.formatUnits(balance, decimals));
  const usdValue = price != null ? balanceFloat * price : null;

  // minOut in tokenOut units: GLP USD value / tokenOut price, −slippage.
  const outDec = chain.glp.tokenOutDecimals || 6;
  let minOut = null, minError = null, minSummary = null;
  if (!balance.isZero()) {
    if (priceRaw == null) {
      minError = "GlpManager.getPrice failed";
    } else {
      const glpValueUsd1e30 = balance.mul(priceRaw).div(ethers.BigNumber.from(10).pow(18)); // 1e30 USD
      const tokenOutPx1e30 = ethers.utils.parseUnits(String(tokenOutUsd || 1), 30);
      const expOut = glpValueUsd1e30.mul(ethers.BigNumber.from(10).pow(outDec)).div(tokenOutPx1e30);
      minOut = expOut.mul(10000 - MIN_OUT_SLIPPAGE_BPS).div(10000);
      minSummary =
        `≥ ${minOut.toString()} ${chain.glp.tokenOutSymbol} (−${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% vs GlpManager NAV)` +
        (yyGlp.isZero() ? "" : `  [incl. ${ethers.utils.formatUnits(yyGlp, 18)} GLP chained from YY]`);
    }
  }

  return [
    {
      kind: "GLP",
      name: `GLP → ${chain.glp.tokenOutSymbol}`,
      token: chain.glp.glpToken,
      balance,
      decimals,
      allowance: ethers.constants.MaxUint256, // RewardRouterV2 burns sGLP directly, no approve needed
      approveSpender: null,
      approveSpenderLabel: null,
      price,
      priceSource: price != null ? "GlpManager" : null,
      balanceFloat,
      usdValue,
      order: 2, // after the YY-fsGLP withdrawal (order 1) that funds it
      protected: true,
      minOut,
      minError,
      minSummary,
      fp: { t: "glp", to: chain.glp.rewardRouter.toLowerCase(), tokenOut: chain.glp.tokenOut.toLowerCase(), receiver: chain.safeAddress.toLowerCase() },
      unwind: {
        to: chain.glp.rewardRouter,
        value: ethers.BigNumber.from(0),
        buildData: (amount) =>
          encodeUnstakeAndRedeemGlp(chain.glp.tokenOut, amount, minOut || 0, chain.safeAddress),
        label: `RewardRouterV2.unstakeAndRedeemGlp(${chain.glp.tokenOutSymbol})`,
      },
    },
  ];
}

// BENQI sAVAX → USDC via a UniswapV2-style DEX router. minOut = MAX of (a) the AMM
// getAmountsOut quote − 2% and (b) an oracle floor = sAVAX→AVAX on-chain stake rate ×
// AVAX/USD oracle − 5%. Taking the higher floor keeps the honest case tight (the AMM
// floor wins) while capping loss to ~5% if the pool quote is manipulated low (the
// oracle floor wins). Far deadline so the (later-signed) Safe tx stays valid.
const SAVAX_ABI = ["function getPooledAvaxByShares(uint256 shares) view returns (uint256)"];
async function buildSavaxPosition(chain, provider, deadline, redstonePrices) {
  if (!chain.savax) return [];
  const token = new ethers.Contract(chain.savax.token, ERC20_ABI, provider);
  const [balance, decimals, allowance] = await Promise.all([
    token.balanceOf(chain.safeAddress),
    token.decimals(),
    token.allowance(chain.safeAddress, chain.savax.swapRouter),
  ]);

  let minOut = null, expOut = null, minError = null, minSummary = null, usdValue = null;
  if (!balance.isZero()) {
    try {
      const router = new ethers.Contract(chain.savax.swapRouter, DEX_ROUTER_ABI, provider);
      const amounts = await router.getAmountsOut(balance, chain.savax.swapPath);
      expOut = amounts[amounts.length - 1];
      const ammFloor = expOut.mul(10000 - MIN_OUT_SLIPPAGE_BPS).div(10000);

      // Oracle floor (manipulation-resistant): sAVAX→AVAX exact rate × AVAX/USD.
      let oracleFloor = ethers.BigNumber.from(0), oracleNote = "no AVAX oracle";
      const avaxUsd = redstonePrices && redstonePrices[chain.savax.oracleSymbol];
      const usdcUsd = (redstonePrices && redstonePrices[chain.savax.outSymbol]) || 1;
      if (avaxUsd) {
        const savax = new ethers.Contract(chain.savax.token, SAVAX_ABI, provider);
        const pooledAvax = await savax.getPooledAvaxByShares(balance); // 1e18 AVAX
        const avaxUsd8 = ethers.BigNumber.from(Math.round(avaxUsd * 1e8));
        const usdcUsd8 = ethers.BigNumber.from(Math.round(usdcUsd * 1e8));
        // → outDecimals: pooledAvax(1e18) × usd8/usd8 / 1e(18-outDec)
        const scale = ethers.BigNumber.from(10).pow(18 - chain.savax.outDecimals);
        const oracleFair = pooledAvax.mul(avaxUsd8).div(usdcUsd8).div(scale);
        oracleFloor = oracleFair.mul(10000 - SAVAX_ORACLE_FLOOR_BPS).div(10000);
        oracleNote = `oracle −${(SAVAX_ORACLE_FLOOR_BPS / 100).toFixed(2)}%`;
      }

      minOut = ammFloor.gt(oracleFloor) ? ammFloor : oracleFloor;
      const usedAmm = ammFloor.gte(oracleFloor);
      usdValue = Number(ethers.utils.formatUnits(expOut, chain.savax.outDecimals)); // USDC ≈ USD
      minSummary =
        `≥ ${ethers.utils.formatUnits(minOut, chain.savax.outDecimals)} ${chain.savax.outSymbol} ` +
        `(max of AMM −${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% [${ethers.utils.formatUnits(ammFloor, chain.savax.outDecimals)}] ` +
        `and ${oracleNote} [${ethers.utils.formatUnits(oracleFloor, chain.savax.outDecimals)}] → ${usedAmm ? "AMM floor" : "ORACLE floor"})`;
    } catch (e) {
      minError = e.message;
    }
  }

  return [
    {
      kind: "sAVAX",
      name: `sAVAX → ${chain.savax.outSymbol}`,
      token: chain.savax.token,
      balance,
      decimals,
      allowance,
      approveSpender: chain.savax.swapRouter,
      approveSpenderLabel: chain.savax.swapRouterLabel,
      price: null,
      priceSource: expOut != null ? "TJ getAmountsOut" : null,
      balanceFloat: parseFloat(ethers.utils.formatUnits(balance, decimals)),
      usdValue,
      order: 0,
      protected: true,
      minOut,
      minError,
      minSummary,
      fp: { t: "swap", to: chain.savax.swapRouter.toLowerCase(), path: chain.savax.swapPath.map((x) => x.toLowerCase()), recipient: chain.safeAddress.toLowerCase() },
      unwind: {
        to: chain.savax.swapRouter,
        value: ethers.BigNumber.from(0),
        buildData: (amount) =>
          encodeSwapExactTokensForTokens(
            amount,
            minOut || 0,
            chain.savax.swapPath,
            chain.safeAddress,
            deadline
          ),
        label: `${chain.savax.swapRouterLabel}.swapExactTokensForTokens(sAVAX→${chain.savax.outSymbol})`,
      },
    },
  ];
}

// Yield Yak YakStrategyV2 vaults: withdraw(shares) → deposit token back to Safe.
// No slippage (1:1 share→underlying), no approve (burns own YRT). The GMX-fsGLP
// vault is order 1 so it precedes the chained GLP redeem (order 2); it also
// exposes its expected GLP output (yakOut) for that chaining.
async function buildYakPositions(chain, provider) {
  if (!chain.yieldYak) return [];
  return Promise.all(
    chain.yieldYak.vaults.map(async (v) => {
      const token = new ethers.Contract(v.token, ERC20_ABI, provider);
      const strat = new ethers.Contract(v.token, YAK_STRATEGY_ABI, provider);
      const [balance, decimals] = await Promise.all([
        token.balanceOf(chain.safeAddress),
        token.decimals(),
      ]);
      let yakOut = null, outError = null;
      if (!balance.isZero()) {
        try {
          yakOut = await strat.getDepositTokensForShares(balance);
        } catch (e) {
          outError = e.message;
        }
      }
      return {
        kind: "YY",
        name: v.name,
        token: v.token,
        balance,
        decimals,
        allowance: ethers.constants.MaxUint256, // withdraw burns own shares
        approveSpender: null,
        approveSpenderLabel: null,
        price: null,
        priceSource: null,
        balanceFloat: parseFloat(ethers.utils.formatUnits(balance, decimals)),
        usdValue: null,
        order: v.isGlp ? 1 : 0,
        protected: false, // 1:1 share→underlying redemption, no slippage surface
        minOut: null,
        minError: null,
        minSummary: `withdraw → ${v.out} (1:1 share redemption, no slippage)` +
          (yakOut != null ? `  ≈ ${ethers.utils.formatUnits(yakOut, 18)} units` : ""),
        isGlp: !!v.isGlp,
        yakOut,
        outError,
        fp: { t: "yak", to: v.token.toLowerCase() },
        unwind: {
          to: v.token,
          value: ethers.BigNumber.from(0),
          buildData: (amount) => encodeYakWithdraw(amount),
          label: `YakStrategy.withdraw(${v.name})`,
        },
      };
    })
  );
}

// ─── Per-chain processor ──────────────────────────────────────────────────────

async function processChain(
  chainKey,
  { includeGlp = false, allowNoMin = false, includeSavax = true, includeYieldYak = true, swapDeadline, dustUsd = DUST_USD_DEFAULT } = {}
) {
  const chain = CHAINS[chainKey];
  const provider = new ethers.providers.JsonRpcProvider(chain.rpc);

  console.log(`\n${"=".repeat(80)}`);
  console.log(`Gnosis Safe Position Unwind — ${chain.name}`);
  console.log("=".repeat(80));
  console.log(`Safe address      : ${chain.safeAddress}`);
  console.log(`GMX V2 Router     : ${chain.router}`);
  console.log(`GMX V2 ExchRouter : ${chain.exchangeRouter}`);
  console.log(`GMX V2 WithdrawVlt: ${chain.withdrawalVault}`);
  console.log(`GMX V2 DataStore  : ${chain.dataStore}`);
  if (chain.glv) {
    console.log(`GLV Router        : ${chain.glv.glvRouter}`);
    console.log(`GLV WithdrawVault : ${chain.glv.withdrawalVault}`);
  }
  if (chain.savax) {
    console.log(`sAVAX unwind      : ${includeSavax ? `INCLUDED → swap via ${chain.savax.swapRouterLabel} → ${chain.savax.outSymbol}` : "excluded (--no-savax)"}`);
  }
  if (chain.yieldYak) {
    console.log(`Yield Yak unwind  : ${includeYieldYak ? `INCLUDED → ${chain.yieldYak.vaults.map((v) => v.name).join(", ")}` : "excluded (--no-yieldyak)"}`);
  }
  if (chain.glp) {
    console.log(`GLP redeem        : ${includeGlp ? "INCLUDED (default; redeems direct fsGLP + chained YY-fsGLP → USDC)" : "EXCLUDED (--no-glp)"}`);
    if (includeGlp) {
      console.log(`GLP RewardRouterV2: ${chain.glp.rewardRouter}`);
      console.log(`GLP token (sGLP)  : ${chain.glp.glpToken}`);
      console.log(`GLP redeem token  : ${chain.glp.tokenOutSymbol} (${chain.glp.tokenOut})`);
    }
  }
  console.log(`RedStone service  : ${chain.redstoneService}`);

  // Execution fee read live from the GMX DataStore (data reader). Falls back to
  // the hard-coded value only if the on-chain read fails.
  let fees = null;
  try {
    fees = await computeGmxExecutionFees(chain, provider);
  } catch (e) {
    console.warn(
      `⚠  Could not read GMX DataStore for dynamic execution fee (${e.message}). ` +
        `Falling back to ${ethers.utils.formatEther(chain.executionFeeFallback)} ${chain.nativeSymbol}.`
    );
  }
  const gmFee = fees ? fees.gmFee : chain.executionFeeFallback;
  const glvFeeByToken = {};
  for (const v of chain.glv ? chain.glv.vaults : []) {
    const key = v.glvToken.toLowerCase();
    glvFeeByToken[key] =
      (fees && fees.glvFeeByToken[key] && fees.glvFeeByToken[key].fee) ||
      chain.executionFeeFallback;
  }

  if (fees) {
    console.log(
      `Gas price (eff)   : ${ethers.utils.formatUnits(fees.gasPrice, 9)} gwei ` +
        `(raw ${ethers.utils.formatUnits(fees.rawGasPrice, 9)} gwei, ${EXEC_FEE_GAS_PRICE_MULTIPLIER}× headroom, floored at 2×baseFee)`
    );
    console.log(
      `Exec fee GM/GM+   : ${ethers.utils.formatEther(gmFee)} ${chain.nativeSymbol} per withdrawal  [live, refundable surplus]`
    );
    for (const v of chain.glv ? chain.glv.vaults : []) {
      const f = fees.glvFeeByToken[v.glvToken.toLowerCase()];
      if (f) {
        console.log(
          `Exec fee ${v.name.padEnd(14)}: ${ethers.utils.formatEther(f.fee)} ${chain.nativeSymbol}  (GLV holds ${f.marketCount.toString()} markets)`
        );
      }
    }
  } else {
    console.log(
      `Execution fee     : ${ethers.utils.formatEther(chain.executionFeeFallback)} ${chain.nativeSymbol} (FALLBACK)`
    );
  }
  console.log("=".repeat(80));

  // GMX Reader context (oracle tickers + market map) for exact min-out floors.
  const [redstonePrices, ctx] = await Promise.all([
    fetchRedstonePrices(chain.redstoneService),
    buildGmxMinOutContext(chain, provider),
  ]);
  console.log(
    `Min-out floor     : GMX Reader getWithdrawalAmountOut − ${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% slippage (GLV via GlvReader NAV)`
  );
  console.log(
    `Dust filter       : ${dustUsd > 0 ? `skip priced positions < $${dustUsd}` : "OFF (include all)"}`
  );

  // Build everything except the GLP redeem first (GLP needs the YY-fsGLP output
  // to size the chained redeem). sAVAX swap + Yield Yak are Avalanche-only (gated
  // by config presence) and on by default.
  const [gmPositions, glvPositions, savaxPositions, yakPositions] = await Promise.all([
    buildGmPositions(chain, provider, redstonePrices, gmFee, ctx),
    buildGlvPositions(chain, provider, glvFeeByToken, ctx),
    includeSavax ? buildSavaxPosition(chain, provider, swapDeadline, redstonePrices) : Promise.resolve([]),
    includeYieldYak ? buildYakPositions(chain, provider) : Promise.resolve([]),
  ]);

  // GLP redeem (only with --glp): chain in any GLP coming from a YY-fsGLP withdraw
  // in this same batch, so the redeem covers direct fsGLP + YY GLP. Price the
  // minOut by the ACTUAL redeem token (USDC on Avax, LINK on Arb).
  const glpTokenOutUsd = chain.glp ? (redstonePrices[chain.glp.tokenOutSymbol] || 1) : 1;
  const yyGlpOut = yakPositions
    .filter((p) => p.isGlp && p.yakOut)
    .reduce((acc, p) => acc.add(p.yakOut), ethers.BigNumber.from(0));
  const glpPositions = includeGlp
    ? await buildGlpPosition(chain, provider, yyGlpOut, glpTokenOutUsd)
    : [];

  const positions = [
    ...gmPositions,
    ...glvPositions,
    ...savaxPositions,
    ...yakPositions,
    ...glpPositions,
  ];
  // Order: independent unwinds (0) → YY-fsGLP withdraw (1) → GLP redeem (2).
  // Within an order group, rank by USD value. This guarantees the YY-fsGLP
  // withdraw is emitted BEFORE the GLP redeem it funds.
  positions.sort(
    (a, b) => (a.order ?? 0) - (b.order ?? 0) || (b.usdValue ?? -1) - (a.usdValue ?? -1)
  );

  const totalUsd = positions.reduce((sum, p) => sum + (p.usdValue ?? 0), 0);

  console.log(`\nTOTAL PRICED POSITION VALUE: ${formatUsd(totalUsd)}`);
  console.log(
    `(GM via RedStone; GLV via GlvReader; sAVAX via DEX quote; GLP via GlpManager NAV; YY=n/a.)`
  );

  const batch = [];
  const struct = []; // normalized shape for the structural fingerprint (matches verifiers)
  const skipped = [];
  const dustSkipped = [];
  let txIndex = 1;
  let unwindCount = 0;
  let totalNativeFee = ethers.BigNumber.from(0);

  for (const pos of positions) {
    console.log(`\n${"─".repeat(80)}`);
    console.log(`Position : ${pos.name}  [${pos.kind}]`);
    console.log(`Token    : ${pos.token}`);
    console.log(
      `Balance  : ${ethers.utils.formatUnits(pos.balance, pos.decimals)} (${pos.balance.toString()} raw)`
    );
    if (pos.approveSpender) {
      console.log(
        `Allowance: ${ethers.utils.formatUnits(pos.allowance, pos.decimals)} → ${pos.approveSpenderLabel} (${pos.approveSpender})`
      );
    } else {
      console.log(`Allowance: n/a (no approve needed for ${pos.kind})`);
    }
    if (pos.price != null) {
      console.log(`Price    : $${pos.price.toFixed(6)} per token  [${pos.priceSource}]`);
      console.log(`Value    : ${formatUsd(pos.usdValue)} (${pos.balanceFloat.toFixed(6)} × $${pos.price.toFixed(6)})`);
    } else if (pos.usdValue != null) {
      console.log(`Value    : ${formatUsd(pos.usdValue)}  [${pos.priceSource || "derived"} — expected long+short out]`);
    } else {
      console.log(`Price    : ⚠  no price feed for "${pos.name}"`);
    }

    if (pos.balance.isZero()) {
      console.log("⚠  Balance is 0 — skipping.");
      continue;
    }

    // Dust filter (default on): skip priced positions below the threshold —
    // unwinding cents costs more in keeper gas / exec fee than it's worth.
    // Positions with no USD value (Yield Yak 1:1 withdrawals) are never filtered.
    if (dustUsd > 0 && pos.usdValue != null && pos.usdValue < dustUsd) {
      console.log(
        `  ⏭  Below dust threshold ($${dustUsd}) — value ${formatUsd(pos.usdValue)}. ` +
          `Skipping (use --dust=0 or --include-dust to include).`
      );
      dustSkipped.push({ name: pos.name, kind: pos.kind, usd: pos.usdValue });
      continue;
    }

    // Slippage protection. Protected positions (GM/GM+/GLV/sAVAX/GLP) must have a
    // computed min or they're skipped (unless --allow-no-min). YY withdrawals are
    // 1:1 share→underlying — no slippage surface — so they're never "protected".
    if (pos.protected && pos.minError) {
      if (!allowNoMin) {
        console.log(
          `  ⚠  Min-out computation FAILED (${pos.minError}).\n` +
            `     SKIPPING this position to avoid an unprotected (min=0) unwind.\n` +
            `     Re-run with --allow-no-min to force it through with NO slippage protection.`
        );
        skipped.push({ name: pos.name, kind: pos.kind, reason: pos.minError });
        continue;
      }
      console.log(
        `  ⚠  Min-out computation FAILED (${pos.minError}). --allow-no-min set → min=0 (NO PROTECTION).`
      );
    } else if (pos.minSummary) {
      console.log(`Min out  : ${pos.minSummary}`);
    }

    // Optional approve tx
    if (pos.approveSpender && pos.allowance.lt(pos.balance)) {
      const approveData = encodeApprove(pos.approveSpender, pos.balance);
      console.log(`\n  TX #${txIndex}: Approve ${pos.approveSpenderLabel}`);
      console.log(`  ┌─ to   : ${pos.token}`);
      console.log(`  │  value: 0`);
      console.log(`  └─ data : ${approveData}`);
      txIndex++;
      batch.push({
        to: pos.token,
        value: "0",
        data: approveData,
        contractMethod: null,
        contractInputsValues: null,
      });
      struct.push({ t: "approve", token: pos.token.toLowerCase(), spender: pos.approveSpender.toLowerCase() });
    } else if (pos.approveSpender) {
      console.log(
        `\n  ✓ Existing allowance covers balance — skipping approve tx.`
      );
    }

    // Unwind tx
    const unwindData = pos.unwind.buildData(pos.balance);
    console.log(`\n  TX #${txIndex}: ${pos.unwind.label}`);
    console.log(`  ┌─ to   : ${pos.unwind.to}`);
    console.log(
      `  │  value: ${pos.unwind.value.toString()}${pos.unwind.value.isZero() ? "" : ` (${ethers.utils.formatEther(pos.unwind.value)} ${chain.nativeSymbol})`}`
    );
    console.log(`  └─ data : ${unwindData}`);
    txIndex++;
    unwindCount++;
    totalNativeFee = totalNativeFee.add(pos.unwind.value);

    batch.push({
      to: pos.unwind.to,
      value: pos.unwind.value.toString(),
      data: unwindData,
      contractMethod: null,
      contractInputsValues: null,
    });
    struct.push(pos.fp);
  }

  console.log(`\n${"─".repeat(80)}`);
  console.log("POSITIONS RANKED BY USD VALUE");
  console.log("─".repeat(80));
  for (const p of positions) {
    const valueStr =
      p.usdValue != null ? formatUsd(p.usdValue).padStart(10) : "       n/a";
    const balStr = p.balance.isZero() ? " (zero)" : "";
    console.log(`  ${valueStr}  [${p.kind.padEnd(3)}] ${p.name}${balStr}`);
  }
  console.log(`  ${"─".repeat(40)}`);
  console.log(`  ${formatUsd(totalUsd).padStart(10)}  TOTAL (priced only)`);

  if (batch.length === 0) {
    console.log("\n⚠  No non-zero balances found — no JSON generated.");
    return;
  }

  console.log(`\n${"─".repeat(80)}`);
  console.log("SUMMARY");
  console.log(`Total transactions : ${txIndex - 1}  (${unwindCount} unwind + ${txIndex - 1 - unwindCount} approve)`);
  console.log(
    `Native needed      : ${totalNativeFee.toString()} wei (${ethers.utils.formatEther(totalNativeFee)} ${chain.nativeSymbol})`
  );
  console.log(
    `  ↑ the Safe must HOLD at least this much ${chain.nativeSymbol}. The Tx Builder wraps the`
  );
  console.log(
    `    batch as a delegatecall multiSend, so each inner GM/GM+/GLV execution fee is`
  );
  console.log(
    `    drawn from the Safe's balance (the outer multiSend value is 0). Swaps, Yield`
  );
  console.log(
    `    Yak withdrawals and the GLP redeem carry 0 value.`
  );
  console.log(
    `Slippage guard     : ${(MIN_OUT_SLIPPAGE_BPS / 100).toFixed(2)}% per position — GM/GM+/GLV minLong/minShort (Reader),`
  );
  console.log(
    `                     sAVAX swap minOut (DEX quote), GLP redeem minOut (GlpManager NAV).`
  );
  console.log(
    `                     Yield Yak withdrawals are 1:1 share→underlying (no slippage).`
  );
  if (skipped.length) {
    console.log(
      `\n⚠  SKIPPED ${skipped.length} position(s) whose min-out could not be computed ` +
        `(not in the JSON — would have been unprotected):`
    );
    for (const s of skipped) console.log(`     • [${s.kind}] ${s.name} — ${s.reason}`);
    console.log(`     Re-run with --allow-no-min to include them with min=0 (NO protection).`);
  }
  if (dustSkipped.length) {
    const dustTotal = dustSkipped.reduce((a, s) => a + s.usd, 0);
    console.log(
      `\nℹ  Dust filter: skipped ${dustSkipped.length} position(s) under $${dustUsd} ` +
        `(${formatUsd(dustTotal)} total): ${dustSkipped.map((s) => `${s.name} (${formatUsd(s.usd)})`).join(", ")}`
    );
    console.log(`   Pass --dust=0 (or --include-dust) to unwind them too.`);
  }

  // Structural fingerprint — sha256 over the deterministic, security-relevant shape
  // (chain, Safe, per-tx target/method/recipient/spender/token/path/order), EXCLUDING
  // live amounts/fees/minOuts/deadline. Identical across runs; compare it with your
  // co-signer's run and with verify-safe-batch.js / verify-safe-tx.js (they recompute
  // the SAME value from the JSON and from the on-chain bytes).
  const fingerprint = crypto
    .createHash("sha256")
    .update(JSON.stringify({ chainId: chain.chainId, safe: chain.safeAddress.toLowerCase(), txs: struct }))
    .digest("hex");
  console.log(`\nStructural fingerprint : ${fingerprint}`);
  console.log(`   ↑ compare with your co-signer + the two verify-safe-*.js scripts.`);

  // Sanity: the recorded total must equal the sum of the individual tx values.
  const sumOfValues = batch.reduce(
    (acc, t) => acc.add(ethers.BigNumber.from(t.value || "0")),
    ethers.BigNumber.from(0)
  );
  if (!sumOfValues.eq(totalNativeFee)) {
    throw new Error(
      `multiSend value mismatch: sum(tx.value)=${sumOfValues} != totalNativeFee=${totalNativeFee}`
    );
  }

  const includedKinds = [...new Set(positions.filter((p) => !p.balance.isZero()).map((p) => p.kind))];
  const safeJson = {
    version: "1.0",
    chainId: chain.chainId,
    createdAt: Date.now(),
    meta: {
      name: `Unwind Safe positions — ${chain.name}`,
      description: `Unwind ${includedKinds.join(", ") || "Safe"} positions held by the Safe on ${chain.name}`,
      txBuilderVersion: "1.16.5",
    },
    // Σ of every inner tx value = the native the SAFE must hold. The Tx Builder
    // wraps this as a delegatecall multiSend, so the inner GMX execution fees are
    // drawn from the Safe's balance (the outer multiSend value is 0). Recorded here
    // as a self-consistency anchor (verify-safe-batch.js cross-checks Σ == this).
    totalValue: totalNativeFee.toString(),
    transactions: batch,
  };

  console.log(`\n${"=".repeat(80)}`);
  console.log(`SAFE TRANSACTION BUILDER JSON — ${chain.name.toUpperCase()}`);
  console.log("=".repeat(80));
  console.log(JSON.stringify(safeJson, null, 2));

  const outPath = path.join(__dirname, `unwind-gnosis-${chainKey}.json`);
  fs.writeFileSync(outPath, JSON.stringify(safeJson, null, 2));
  console.log(`\n✓ Saved Safe Transaction Builder JSON to: ${outPath}`);
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function main() {
  const rawArgs = process.argv.slice(2);
  const flags = new Set(
    rawArgs.filter((a) => a.startsWith("-")).map((a) => a.toLowerCase())
  );
  const positional = rawArgs.filter((a) => !a.startsWith("-"));
  const arg = (positional[0] || "all").toLowerCase();

  // GLP redeem is ON by default (full unwind): redeem direct fsGLP + any GLP a
  // YY-fsGLP withdrawal pulls into the Safe → USDC, chained in one batch. Opt out
  // with --no-glp. The old --glp/--with-glp/--include-glp are accepted no-ops now.
  const NOGLP_FLAGS = ["--no-glp"];
  const GLP_ALIAS_FLAGS = ["--glp", "--with-glp", "--include-glp"]; // now default; no-op
  const NOMIN_FLAGS = ["--allow-no-min"];
  const NOSAVAX_FLAGS = ["--no-savax"];
  const NOYAK_FLAGS = ["--no-yieldyak", "--no-yak"];
  const DUST_FLAGS = ["--include-dust"]; // plus --dust=<usd> (handled separately)
  const includeGlp = !NOGLP_FLAGS.some((f) => flags.has(f));
  const allowNoMin = NOMIN_FLAGS.some((f) => flags.has(f));
  const includeSavax = !NOSAVAX_FLAGS.some((f) => flags.has(f));
  const includeYieldYak = !NOYAK_FLAGS.some((f) => flags.has(f));

  // Dust threshold: default $1; --dust=<usd> overrides; --dust=0/--include-dust disables.
  let dustUsd = DUST_USD_DEFAULT;
  const dustArg = rawArgs.find((a) => /^--dust=/i.test(a));
  if (dustArg) {
    dustUsd = parseFloat(dustArg.split("=")[1]);
    if (!Number.isFinite(dustUsd) || dustUsd < 0) {
      console.error(`Invalid --dust value "${dustArg.split("=")[1]}" (expected a number ≥ 0).`);
      process.exit(1);
    }
  }
  if (flags.has("--include-dust")) dustUsd = 0;

  // Swap deadline. Default 48h: long enough for a multisig to gather signatures,
  // short enough that a lingering signed batch can't be executed against a stale
  // (absolute) minOut weeks later. Override with --deadline=<hours>.
  let deadlineHours = 48;
  const dlArg = rawArgs.find((a) => /^--deadline=/i.test(a));
  if (dlArg) {
    deadlineHours = parseFloat(dlArg.split("=")[1]);
    if (!Number.isFinite(deadlineHours) || deadlineHours <= 0) {
      console.error(`Invalid --deadline value "${dlArg.split("=")[1]}" (expected hours > 0).`);
      process.exit(1);
    }
  }
  const swapDeadline = Math.floor(Date.now() / 1000) + Math.round(deadlineHours * 3600);

  // Surface unknown flags rather than silently ignoring them (allow --dust=<n>).
  const ALL_FLAGS = [...NOGLP_FLAGS, ...GLP_ALIAS_FLAGS, ...NOMIN_FLAGS, ...NOSAVAX_FLAGS, ...NOYAK_FLAGS, ...DUST_FLAGS];
  const known = new Set(ALL_FLAGS);
  for (const f of flags) {
    if (f.startsWith("--dust=") || f.startsWith("--deadline=")) continue;
    if (!known.has(f)) {
      console.error(`Unknown flag "${f}". Valid flags: ${[...ALL_FLAGS, "--dust=<usd>"].join(", ")}`);
      process.exit(1);
    }
  }

  const targets =
    arg === "all"
      ? Object.keys(CHAINS)
      : arg in CHAINS
      ? [arg]
      : (() => {
          console.error(
            `Unknown chain "${arg}". Valid options: ${Object.keys(CHAINS).join(", ")}, all`
          );
          process.exit(1);
        })();

  for (const chainKey of targets) {
    await processChain(chainKey, {
      includeGlp,
      allowNoMin,
      includeSavax,
      includeYieldYak,
      swapDeadline,
      dustUsd,
    });
  }
}

main().catch((err) => {
  console.error("Error:", err);
  process.exit(1);
});