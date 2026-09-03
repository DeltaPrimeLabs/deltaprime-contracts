import { embedCommitHash } from "../../tools/scripts/embed-commit-hash";
import hre from "hardhat";
const { tenderly } = require("hardhat");
const { verifyDeployment, writeManifest } = require("../../tools/scripts/verify-from-deployment");

const SLEEP_AFTER_DEPLOY_MS = 10000;
const VERIFY_TIMEOUT_MS = 180000; // 3 min hard cap per Tenderly call
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// tenderly.verify can hang indefinitely on a transient API stall. Wrap it in a
// timeout race so a single hung call cannot block the rest of the deploy.
// (Block-explorer verification has its own retry/timeout logic in
// verify-from-deployment.js.)
const withTimeout = (promise, ms, label) =>
    Promise.race([
        promise,
        new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout after ${ms}ms: ${label}`)), ms)),
    ]);

/**
 * Insolvency-snapshot re-arm fix (branch: fix/insolvency-snapshot-rearm-window) — Arbitrum redeploy.
 *
 * Source changes carried by this redeploy:
 *   - SmartLoanLiquidationFacet: snapshotInsolvency() may re-arm an EXPIRED snapshot while still
 *     insolvent (carry over cumulativeLossDollars, refresh debtSnapshotDollars); the 15-min window
 *     uses the shared DiamondStorageLib.INSOLVENCY_SNAPSHOT_VALIDITY constant.
 *   - PrimeAccountModifiers: notInLiquidation is now window-aware, and onlyOwnerOrLiquidation /
 *     onlyOwnerOrLiquidationWithNoSolvencyCheck enforce the 15-min window on the liquidator branch.
 *   - WithdrawalIntentFacet: its onlyWhitelistedLiquidatorsAndInsolvencySnapshotOrOwner modifier
 *     enforces the same window.
 *   - ParaSwapHelper.validateSwapParameters: pre-liquidation swaps are bound to the same window.
 *
 * SCOPE — only facets whose EXECUTABLE bytecode changed (metadata-stripped runtime diff vs main)
 * AND that are registered in the live Arbitrum SmartLoanDiamondBeacon
 * (0x62Cf82FB0484aF382714cD09296260edc1DC0c6c, verified via DiamondLoupe.facets()).
 * Replace via diamondCut on the beacon:
 *   - SmartLoanLiquidationFacet, WithdrawalIntentFacet, ParaSwapFacet, SwapDebtFacet,
 *     SmartLoanWrappedNativeTokenFacet, AssetsOperationsArbitrumFacet, BeefyFinanceArbitrumFacet,
 *     GLPFacetArbi, GlvFacetArbitrum, GmxV2FacetArbitrum, GmxV2PlusFacetArbitrum,
 *     TraderJoeV2ArbitrumFacet, YieldYakFacetArbi, YieldYakSwapArbitrumFacet.
 *
 * All 14 are confirmed live on-chain (BeefyFinanceArbitrumFacet / GLPFacetArbi / YieldYakFacetArbi
 * have no committed hardhat-deploy artifact but their own functions — stakeGmxBeefy, mintAndStakeGlp,
 * stakeGLPYak — resolve via the loupe, so they are genuinely registered).
 *
 * PREREQUISITE: as with every facet redeploy in this repo, the working tree must have its
 * DeploymentConstants imports pointed at Arbitrum (the standard updateConstants('arbitrum') step)
 * before running — these facets import the chain-rewritten "../lib/local/DeploymentConstants.sol".
 *
 * The script does NOT execute the diamondCut Replace calls — those are signed off-chain by the
 * protocol multisig. The summary log at the end provides the addresses to feed into those txs.
 *
 * Verification is decoupled: the deploy writes
 * deployments/arbitrum/insolvency-snapshot-rearm-facets.verify-manifest.json, and verification
 * can be re-run any time (idempotently) with:
 *   npx hardhat run tools/scripts/verify-deployments.js --network arbitrum
 */

// AssetsOperationsArbitrumFacet's bytecode carries an unresolved GmxBenchmarkMath placeholder
// (it reaches GmxBenchmarkMath via the GMX fee path), so the library must be linked in at deploy
// time. Every other target's compiled linkReferences are empty (verified against the artifacts).
const NEEDS_GMX_BENCHMARK_MATH = new Set([
    "AssetsOperationsArbitrumFacet",
]);

const TARGETS = [
    { name: "SmartLoanLiquidationFacet",        embedDir: "./contracts/facets",          contract: "contracts/facets/SmartLoanLiquidationFacet.sol:SmartLoanLiquidationFacet" },
    { name: "WithdrawalIntentFacet",            embedDir: "./contracts/facets",          contract: "contracts/facets/WithdrawalIntentFacet.sol:WithdrawalIntentFacet" },
    { name: "ParaSwapFacet",                    embedDir: "./contracts/facets",          contract: "contracts/facets/ParaSwapFacet.sol:ParaSwapFacet" },
    { name: "SwapDebtFacet",                    embedDir: "./contracts/facets",          contract: "contracts/facets/SwapDebtFacet.sol:SwapDebtFacet" },
    { name: "SmartLoanWrappedNativeTokenFacet", embedDir: "./contracts/facets",          contract: "contracts/facets/SmartLoanWrappedNativeTokenFacet.sol:SmartLoanWrappedNativeTokenFacet" },
    { name: "AssetsOperationsArbitrumFacet",    embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/AssetsOperationsArbitrumFacet.sol:AssetsOperationsArbitrumFacet" },
    { name: "BeefyFinanceArbitrumFacet",        embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/BeefyFinanceArbitrumFacet.sol:BeefyFinanceArbitrumFacet" },
    { name: "GLPFacetArbi",                     embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/GLPFacetArbi.sol:GLPFacetArbi" },
    { name: "GlvFacetArbitrum",                 embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/GlvFacetArbitrum.sol:GlvFacetArbitrum" },
    { name: "GmxV2FacetArbitrum",               embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/GmxV2FacetArbitrum.sol:GmxV2FacetArbitrum" },
    { name: "GmxV2PlusFacetArbitrum",           embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/GmxV2PlusFacetArbitrum.sol:GmxV2PlusFacetArbitrum" },
    { name: "TraderJoeV2ArbitrumFacet",         embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/TraderJoeV2ArbitrumFacet.sol:TraderJoeV2ArbitrumFacet" },
    { name: "YieldYakFacetArbi",                embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/YieldYakFacetArbi.sol:YieldYakFacetArbi" },
    { name: "YieldYakSwapArbitrumFacet",        embedDir: "./contracts/facets/arbitrum", contract: "contracts/facets/arbitrum/YieldYakSwapArbitrumFacet.sol:YieldYakSwapArbitrumFacet" },
];

// GmxBenchmarkMath (DELEGATECALL library) is deployed first so its address can be linked into
// AssetsOperationsArbitrumFacet. Its source is unchanged by this fix, so hardhat-deploy reuses the
// existing on-chain deployment when the bytecode matches (newlyDeployed=false).
const GMX_BENCHMARK_MATH_CONTRACT = "contracts/lib/GmxBenchmarkMath.sol:GmxBenchmarkMath";

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log("== Arbitrum insolvency-snapshot re-arm facet redeploy ==");
    console.log(`Deployer: ${deployer}`);
    console.log(`Targets:  ${TARGETS.length}`);

    // Stamp current commit hash into every target's source file.
    // embedCommitHash also triggers `npx hardhat compile` after each rewrite;
    // doing this up-front means every deploy() call below sees a consistent build.
    for (const t of TARGETS) {
        embedCommitHash(t.name, t.embedDir);
    }

    // GmxBenchmarkMath — unchanged source, so hardhat-deploy reuses the existing on-chain
    // deployment when the bytecode matches (newlyDeployed=false).
    console.log("\n--- deploy GmxBenchmarkMath (library) ---");
    const gmxBenchmarkMath = await deploy("GmxBenchmarkMath", {
        from: deployer,
        args: [],
    });
    console.log(`Address: ${gmxBenchmarkMath.address} (newlyDeployed=${gmxBenchmarkMath.newlyDeployed})`);

    const deployedAddrs = {};

    // Deploy every target.
    for (const t of TARGETS) {
        console.log(`\n--- deploy ${t.name} ---`);
        const deployOpts = { from: deployer, args: [], contract: t.contract };
        if (NEEDS_GMX_BENCHMARK_MATH.has(t.name)) {
            deployOpts.libraries = { GmxBenchmarkMath: gmxBenchmarkMath.address };
        }
        const result = await deploy(t.name, deployOpts);
        deployedAddrs[t.name] = result.address;
        console.log(`Deployed at: ${result.address} (newlyDeployed=${result.newlyDeployed})`);
    }

    // Write the verify manifest BEFORE verifying, so the whole batch can be re-verified later
    // even if verification below partially fails.
    const allNames = ["GmxBenchmarkMath", ...TARGETS.map((t) => t.name)];
    const manifestFile = writeManifest(hre, "insolvency-snapshot-rearm-facets", allNames);
    console.log(`\nWrote verify manifest: ${manifestFile}`);

    // Give the explorer a moment to index the freshly-deployed bytecode.
    await sleep(SLEEP_AFTER_DEPLOY_MS);

    // Block-explorer (Etherscan v2, chainid=42161) verification. verifyDeployment submits the exact
    // saved solc input as a minimal closure and reads any library link from the deployment artifact —
    // immune to working-tree drift and solc-wasm OOM.
    console.log("\n== Block-explorer verification ==");
    const verifyResults = [];
    for (const name of allNames) {
        const r = await verifyDeployment(hre, name);
        console.log(`${r.ok ? "✅" : "❌"} ${name}: ${r.detail}`);
        verifyResults.push(r);
    }

    // Tenderly verification (separate dashboard; reads working-tree artifacts).
    console.log("\n== Tenderly verification ==");
    const tenderlyTargets = [
        { name: "GmxBenchmarkMath", contract: GMX_BENCHMARK_MATH_CONTRACT, address: gmxBenchmarkMath.address },
        ...TARGETS.map((t) => ({ ...t, address: deployedAddrs[t.name] })),
    ];
    for (const t of tenderlyTargets) {
        try {
            const args = { address: t.address, name: t.contract };
            if (NEEDS_GMX_BENCHMARK_MATH.has(t.name)) {
                args.libraries = { GmxBenchmarkMath: gmxBenchmarkMath.address };
            }
            await withTimeout(tenderly.verify(args), VERIFY_TIMEOUT_MS, `Tenderly verify ${t.name}`);
            console.log(`✅ Tenderly verified ${t.name}`);
        } catch (error) {
            console.error(`❌ Tenderly verification failed for ${t.name}: ${error.message}`);
        }
    }

    console.log("\n== Deploy summary (Arbitrum insolvency-snapshot re-arm) ==");
    console.log(`${"GmxBenchmarkMath".padEnd(34)} ${gmxBenchmarkMath.address}`);
    for (const [name, addr] of Object.entries(deployedAddrs)) {
        console.log(`${name.padEnd(34)} ${addr}`);
    }

    const failed = verifyResults.filter((r) => !r.ok).map((r) => r.name);
    if (failed.length > 0) {
        console.log(`\n⚠️  Block-explorer verification failed for: ${failed.join(", ")}`);
        console.log("   Re-run (idempotent): npx hardhat run tools/scripts/verify-deployments.js --network arbitrum");
    }

    console.log("\nNext steps (protocol multisig, NOT in this script):");
    console.log("  1. diamondCut Replace on SmartLoanDiamondBeacon for each facet above");
    console.log("     (except GmxBenchmarkMath), pointing ALL of its selectors at the new address.");
    console.log("     Note: some inherited selectors are currently registered under a shared facet");
    console.log("     address — confirm the full selector set per facet against the live loupe first.");
};

module.exports.tags = ["arbitrum-insolvency-snapshot-rearm"];
