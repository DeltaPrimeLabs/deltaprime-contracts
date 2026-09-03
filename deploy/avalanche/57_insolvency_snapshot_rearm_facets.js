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
 * Insolvency-snapshot re-arm fix (branch: fix/insolvency-snapshot-rearm-window) — Avalanche redeploy.
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
 * AND that are registered in the live Avalanche SmartLoanDiamondBeacon
 * (0x2916B3bf7C35bd21e63D01C93C62FB0d4994e56D, verified via DiamondLoupe.facets()).
 * Replace via diamondCut on the beacon:
 *   - SmartLoanLiquidationFacet, WithdrawalIntentFacet, ParaSwapFacet, SwapDebtFacet,
 *     SmartLoanWrappedNativeTokenFacet, AssetsOperationsAvalancheFacet, SJoeFacet, GLPFacet,
 *     GmxV2FacetAvalanche, GmxV2PlusFacetAvalanche, TraderJoeV2AvalancheFacet, WombatFacet,
 *     YieldYakFacet, YieldYakSwapFacet.
 *
 * Deliberately EXCLUDED — bytecode changed (they use the touched modifiers) but they are NOT
 * registered in the live Avalanche diamond, so there is nothing to replace:
 *   BalancerV2Facet, BeefyFinanceAvalancheFacet, GogoPoolFacet, TraderJoeV2AutopoolsFacet,
 *   UniswapV3Facet, YieldYakWombatFacet, GlvFacetAvalanche (only its inherited FEE_PERCENTAGE()
 *   selector resolves on-chain — no GLV-specific function is wired on Avalanche).
 *
 * PREREQUISITE: as with every facet redeploy in this repo, the working tree must have its
 * DeploymentConstants imports pointed at Avalanche (the standard updateConstants('avalanche') step)
 * before running — these facets import the chain-rewritten "../lib/local/DeploymentConstants.sol".
 *
 * The script does NOT execute the diamondCut Replace calls — those are signed off-chain by the
 * protocol multisig. The summary log at the end provides the addresses to feed into those txs.
 *
 * Verification is decoupled: the deploy writes
 * deployments/avalanche/insolvency-snapshot-rearm-facets.verify-manifest.json, and verification
 * can be re-run any time (idempotently) with:
 *   npx hardhat run tools/scripts/verify-deployments.js --network avalanche
 */

// AssetsOperationsAvalancheFacet's bytecode carries an unresolved GmxBenchmarkMath placeholder
// (it reaches GmxBenchmarkMath via the GMX fee path), so the library must be linked in at deploy
// time. Every other target's compiled linkReferences are empty (verified against the artifacts).
const NEEDS_GMX_BENCHMARK_MATH = new Set([
    "AssetsOperationsAvalancheFacet",
]);

const TARGETS = [
    { name: "SmartLoanLiquidationFacet",        embedDir: "./contracts/facets",           contract: "contracts/facets/SmartLoanLiquidationFacet.sol:SmartLoanLiquidationFacet" },
    { name: "WithdrawalIntentFacet",            embedDir: "./contracts/facets",           contract: "contracts/facets/WithdrawalIntentFacet.sol:WithdrawalIntentFacet" },
    { name: "ParaSwapFacet",                    embedDir: "./contracts/facets",           contract: "contracts/facets/ParaSwapFacet.sol:ParaSwapFacet" },
    { name: "SwapDebtFacet",                    embedDir: "./contracts/facets",           contract: "contracts/facets/SwapDebtFacet.sol:SwapDebtFacet" },
    { name: "SmartLoanWrappedNativeTokenFacet", embedDir: "./contracts/facets",           contract: "contracts/facets/SmartLoanWrappedNativeTokenFacet.sol:SmartLoanWrappedNativeTokenFacet" },
    { name: "AssetsOperationsAvalancheFacet",   embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/AssetsOperationsAvalancheFacet.sol:AssetsOperationsAvalancheFacet" },
    { name: "SJoeFacet",                        embedDir: "./contracts/facets",           contract: "contracts/facets/SJoeFacet.sol:SJoeFacet" },
    { name: "GLPFacet",                         embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/GLPFacet.sol:GLPFacet" },
    { name: "GmxV2FacetAvalanche",              embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/GmxV2FacetAvalanche.sol:GmxV2FacetAvalanche" },
    { name: "GmxV2PlusFacetAvalanche",          embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/GmxV2PlusFacetAvalanche.sol:GmxV2PlusFacetAvalanche" },
    { name: "TraderJoeV2AvalancheFacet",        embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/TraderJoeV2AvalancheFacet.sol:TraderJoeV2AvalancheFacet" },
    { name: "WombatFacet",                      embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/WombatFacet.sol:WombatFacet" },
    { name: "YieldYakFacet",                    embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/YieldYakFacet.sol:YieldYakFacet" },
    { name: "YieldYakSwapFacet",                embedDir: "./contracts/facets/avalanche", contract: "contracts/facets/avalanche/YieldYakSwapFacet.sol:YieldYakSwapFacet" },
];

// GmxBenchmarkMath (DELEGATECALL library) is deployed first so its address can be linked into
// AssetsOperationsAvalancheFacet. Its source is unchanged by this fix, so hardhat-deploy reuses the
// existing on-chain deployment when the bytecode matches (newlyDeployed=false).
const GMX_BENCHMARK_MATH_CONTRACT = "contracts/lib/GmxBenchmarkMath.sol:GmxBenchmarkMath";

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log("== Avalanche insolvency-snapshot re-arm facet redeploy ==");
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

    // Block-explorer (Snowtrace/Routescan) verification. verifyDeployment submits the exact saved
    // solc input as a minimal closure and reads any library link from the deployment artifact —
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

    console.log("\n== Deploy summary (Avalanche insolvency-snapshot re-arm) ==");
    console.log(`${"GmxBenchmarkMath".padEnd(34)} ${gmxBenchmarkMath.address}`);
    for (const [name, addr] of Object.entries(deployedAddrs)) {
        console.log(`${name.padEnd(34)} ${addr}`);
    }

    const failed = verifyResults.filter((r) => !r.ok).map((r) => r.name);
    if (failed.length > 0) {
        console.log(`\n⚠️  Block-explorer verification failed for: ${failed.join(", ")}`);
        console.log("   Re-run (idempotent): npx hardhat run tools/scripts/verify-deployments.js --network avalanche");
    }

    console.log("\nNext steps (protocol multisig, NOT in this script):");
    console.log("  1. diamondCut Replace on SmartLoanDiamondBeacon for each facet above");
    console.log("     (except GmxBenchmarkMath), pointing ALL of its selectors at the new address.");
    console.log("     Note: some inherited selectors are currently registered under a shared facet");
    console.log("     address — confirm the full selector set per facet against the live loupe first.");
};

module.exports.tags = ["avalanche-insolvency-snapshot-rearm"];
