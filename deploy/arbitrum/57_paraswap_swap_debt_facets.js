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
 * ParaSwapFacet + SwapDebtFacet redeploy — Arbitrum.
 *
 * Deploys fresh implementations of both ParaSwap-related facets, then writes a
 * verify manifest and runs block-explorer (Etherscan v2) + Tenderly verification
 * for each one.
 *
 * Scope (replace via diamondCut on SmartLoanDiamondBeacon):
 *   - ParaSwapFacet
 *   - SwapDebtFacet
 *
 * Both facets inherit ParaSwapHelper (an abstract base — inlined at compile time,
 * not an externally-linked library), and their compiled artifacts carry no
 * linkReferences, so no library deploy/linking step is required here.
 *
 * The script does NOT execute the diamondCut Replace calls — those are signed
 * off-chain by the protocol multisig. The summary log at the end provides the
 * addresses to feed into those txs.
 *
 * Verification is decoupled: the deploy writes
 * deployments/arbitrum/paraswap-swap-debt-facets.verify-manifest.json, and
 * verification can be re-run any time (idempotently) with:
 *   npx hardhat run tools/scripts/verify-deployments.js --network arbitrum
 */
const TARGETS = [
    { name: "ParaSwapFacet", embedDir: "./contracts/facets", contract: "contracts/facets/ParaSwapFacet.sol:ParaSwapFacet" },
    { name: "SwapDebtFacet", embedDir: "./contracts/facets", contract: "contracts/facets/SwapDebtFacet.sol:SwapDebtFacet" },
];

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log("== Arbitrum ParaSwapFacet + SwapDebtFacet redeploy ==");
    console.log(`Deployer: ${deployer}`);
    console.log(`Targets:  ${TARGETS.length}`);

    // Stamp current commit hash into every target's source file.
    // embedCommitHash also triggers `npx hardhat compile` after each rewrite;
    // doing this up-front means every deploy() call below sees a consistent build.
    for (const t of TARGETS) {
        embedCommitHash(t.name, t.embedDir);
    }

    const deployedAddrs = {};

    // Deploy every target.
    for (const t of TARGETS) {
        console.log(`\n--- deploy ${t.name} ---`);
        const result = await deploy(t.name, {
            from: deployer,
            args: [],
            contract: t.contract,
        });
        deployedAddrs[t.name] = result.address;
        console.log(`Deployed at: ${result.address} (newlyDeployed=${result.newlyDeployed})`);
    }

    // Write the verify manifest BEFORE verifying, so the whole batch can be
    // re-verified later even if verification below partially fails.
    const allNames = TARGETS.map((t) => t.name);
    const manifestFile = writeManifest(hre, "paraswap-swap-debt-facets", allNames);
    console.log(`\nWrote verify manifest: ${manifestFile}`);

    // Give the explorer a moment to index the freshly-deployed bytecode.
    await sleep(SLEEP_AFTER_DEPLOY_MS);

    // Block-explorer (Etherscan v2) verification. verifyDeployment submits the
    // exact saved solc input as a minimal closure and reads any library link
    // from the deployment artifact — immune to working-tree drift and solc-wasm OOM.
    console.log("\n== Block-explorer verification ==");
    const verifyResults = [];
    for (const name of allNames) {
        const r = await verifyDeployment(hre, name);
        console.log(`${r.ok ? "✅" : "❌"} ${name}: ${r.detail}`);
        verifyResults.push(r);
    }

    // Tenderly verification (separate dashboard; reads working-tree artifacts).
    console.log("\n== Tenderly verification ==");
    for (const t of TARGETS) {
        try {
            await withTimeout(
                tenderly.verify({ address: deployedAddrs[t.name], name: t.contract }),
                VERIFY_TIMEOUT_MS,
                `Tenderly verify ${t.name}`,
            );
            console.log(`✅ Tenderly verified ${t.name}`);
        } catch (error) {
            console.error(`❌ Tenderly verification failed for ${t.name}: ${error.message}`);
        }
    }

    console.log("\n== Deploy summary (Arbitrum ParaSwapFacet + SwapDebtFacet) ==");
    for (const [name, addr] of Object.entries(deployedAddrs)) {
        console.log(`${name.padEnd(28)} ${addr}`);
    }

    const failed = verifyResults.filter((r) => !r.ok).map((r) => r.name);
    if (failed.length > 0) {
        console.log(`\n⚠️  Block-explorer verification failed for: ${failed.join(", ")}`);
        console.log("   Re-run (idempotent): npx hardhat run tools/scripts/verify-deployments.js --network arbitrum");
    }

    console.log("\nNext steps (protocol multisig, NOT in this script):");
    console.log("  1. diamondCut Replace on SmartLoanDiamondBeacon for each facet above,");
    console.log("     pointing its selectors at the new address.");
};

module.exports.tags = ["arbitrum-paraswap-swap-debt-facets"];
