// ParaSwap v6.2 swap-calldata generator for the Arbitrum DEX-adapter fork test
// (test/forge/fork/arbitrum/ParaSwapFork.t.sol, invoked via Foundry `vm.ffi`).
//
// Arbitrum analog of tools/scripts/paraswap-avax-swapdata.js (chainId 42161 instead of
// 43114, Arbitrum FEES_TREASURY as the pinned partner). Queries the live ParaSwap API
// for a SELL route restricted to the two contract methods the DeltaPrime ParaSwapFacet
// can decode (`swapExactAmountIn` / `swapExactAmountInOnUniswapV3` → selectors
// 0xe3ead59e / 0x876a02f6), builds the tx, and writes the raw Augustus calldata (4-byte
// selector ++ swap bytes) to stdout as a 0x-hex string.
//
// No partner / partnerFee is set → the encoded `partner` decodes to address(0), which the
// facet's validateSwapParameters accepts (it only allows address(0) or the protocol
// treasury). The beneficiary is the Prime Account (userAddress) so it equals address(this)
// inside the facet.
//
// No API key required — uses the public ParaSwap SDK (constructSimpleSDK + axios).
//
// Usage:
//   node tools/scripts/paraswap-arb-swapdata.js <srcToken> <srcDecimals> <destToken> <destDecimals> <srcAmount> <userAddress> [slippageBps]

const axios = require("axios");
const { constructSimpleSDK, SwapSide } = require("@paraswap/sdk");

const CHAIN_ID = 42161; // Arbitrum One
const paraSwap = constructSimpleSDK({ chainId: CHAIN_ID, axios, version: "6.2" });

// The DeltaPrime fees treasury on Arbitrum (DeploymentChainConfig.FEES_TREASURY). The
// ParaSwapFacet's validateSwapParameters only accepts an encoded `partner` of address(0) OR
// this treasury — and the @paraswap/sdk defaults to ParaSwap's OWN partner when none is given
// (which the facet rejects with InvalidPartnerAddress). So we MUST pin the partner to the
// treasury. A 0-bps fee means the treasury receives nothing; we only need the address slot to
// validate.
const DELTAPRIME_TREASURY = "0x764a9756994f4E6cd9358a6FcD924d566fC2e666";

async function getSwapData(srcToken, srcDecimals, destToken, destDecimals, srcAmount, slippage, userAddress) {
  const priceRoute = await paraSwap.swap.getRate({
    srcToken,
    destToken,
    amount: srcAmount.toString(),
    userAddress,
    srcDecimals: srcDecimals.toString(),
    destDecimals: destDecimals.toString(),
    side: SwapSide.SELL,
    includeContractMethods: ["swapExactAmountIn", "swapExactAmountInOnUniswapV3"],
    version: "6.2",
  });

  const txParams = await paraSwap.swap.buildTx(
    {
      srcToken: priceRoute.srcToken,
      destToken: priceRoute.destToken,
      srcAmount: priceRoute.srcAmount,
      srcDecimals: priceRoute.srcDecimals,
      destDecimals: priceRoute.destDecimals,
      slippage,
      priceRoute,
      deadline: Math.floor(Date.now() / 1000) + 1200,
      userAddress,
      partnerAddress: DELTAPRIME_TREASURY,
      partnerFeeBps: 0,
      partner: "deltaprime",
    },
    { ignoreChecks: true }
  );

  return txParams.data;
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 6) {
    console.error(
      "Usage: node paraswap-arb-swapdata.js <srcToken> <srcDecimals> <destToken> <destDecimals> <srcAmount> <userAddress> [slippageBps]"
    );
    process.exit(1);
  }
  const [srcToken, srcDecimals, destToken, destDecimals, srcAmount, userAddress, slippage] = args;
  const data = await getSwapData(
    srcToken,
    srcDecimals,
    destToken,
    destDecimals,
    srcAmount,
    slippage ? Number(slippage) : 100,
    userAddress
  );
  process.stdout.write(data);
  process.exit(0);
}

main().catch((error) => {
  console.error("paraswap-arb-swapdata error:", error && error.message ? error.message : error);
  process.exit(1);
});
