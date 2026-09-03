import { embedCommitHash } from "../../tools/scripts/embed-commit-hash";
import hre from "hardhat";
const { tenderly } = require("hardhat");
const { verifyDeployment, writeManifest } = require("../../tools/scripts/verify-from-deployment");

const SLEEP_AFTER_DEPLOY_MS = 10000;
const VERIFY_TIMEOUT_MS = 180000; // 3 min hard cap per Tenderly call
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const withTimeout = (promise, ms, label) =>
    Promise.race([
        promise,
        new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout after ${ms}ms: ${label}`)), ms)),
    ]);

/**
 * MINIMAL unblock for stuck liquidations (branch: fix/insolvency-snapshot-rearm-window) — Arbitrum.
 *
 * Ships ONLY SmartLoanLiquidationFacet — the single facet needed to clear the deadlock where an
 * insolvency snapshot expires while the account is still insolvent (liquidate() reverts "expired",
 * snapshotInsolvency() reverts "already being liquidated", clearInsolvencySnapshot() reverts because
 * the account is not solvent).
 *
 * Why this one facet is sufficient:
 *   - The whole snapshot lifecycle (snapshotInsolvency / clearInsolvencySnapshot / liquidate) lives
 *     in SmartLoanLiquidationFacet, and it now carries the RE-ARM: a whitelisted liquidator can take
 *     a fresh snapshot on an expired-but-still-insolvent account, then liquidate() within the new
 *     15-minute window. That clears any currently-stuck account.
 *   - The INSOLVENCY_SNAPSHOT_VALIDITY constant it references is inlined (DiamondStorageLib is not a
 *     deployed contract), and the facet has no external library link — so it is fully self-contained
 *     and works against the existing (old) versions of every other facet.
 *
 * This intentionally does NOT include the broader consistency sweep (pre-liquidation-swap / unwind
 * window enforcement, and owner self-cure via window-aware notInLiquidation). That ships separately
 * in 58_insolvency_snapshot_rearm_facets.js and is not required to unblock liquidations.
 *
 * PREREQUISITE: the working tree must have its DeploymentConstants imports pointed at Arbitrum
 * (the standard updateConstants('arbitrum') step) before running — this facet imports the
 * chain-rewritten "../lib/local/DeploymentConstants.sol".
 *
 * The script does NOT execute the diamondCut Replace — that is signed off-chain by the protocol
 * multisig (Replace SmartLoanLiquidationFacet's selectors with the new address).
 *
 * Re-verify any time (idempotent):
 *   npx hardhat run tools/scripts/verify-deployments.js --network arbitrum
 */
const TARGETS = [
    { name: "SmartLoanLiquidationFacet", embedDir: "./contracts/facets", contract: "contracts/facets/SmartLoanLiquidationFacet.sol:SmartLoanLiquidationFacet" },
];

module.exports = async ({ getNamedAccounts, deployments }) => {
    const { deploy } = deployments;
    const { deployer } = await getNamedAccounts();

    console.log("== Arbitrum minimal liquidation-unblock redeploy (SmartLoanLiquidationFacet) ==");
    console.log(`Deployer: ${deployer}`);

    for (const t of TARGETS) {
        embedCommitHash(t.name, t.embedDir);
    }

    const deployedAddrs = {};
    for (const t of TARGETS) {
        console.log(`\n--- deploy ${t.name} ---`);
        const result = await deploy(t.name, { from: deployer, args: [], contract: t.contract });
        deployedAddrs[t.name] = result.address;
        console.log(`Deployed at: ${result.address} (newlyDeployed=${result.newlyDeployed})`);
    }

    const allNames = TARGETS.map((t) => t.name);
    const manifestFile = writeManifest(hre, "liquidation-facet-unblock", allNames);
    console.log(`\nWrote verify manifest: ${manifestFile}`);

    await sleep(SLEEP_AFTER_DEPLOY_MS);

    console.log("\n== Block-explorer verification ==");
    const verifyResults = [];
    for (const name of allNames) {
        const r = await verifyDeployment(hre, name);
        console.log(`${r.ok ? "✅" : "❌"} ${name}: ${r.detail}`);
        verifyResults.push(r);
    }

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

    console.log("\n== Deploy summary (Arbitrum minimal liquidation-unblock) ==");
    for (const [name, addr] of Object.entries(deployedAddrs)) {
        console.log(`${name.padEnd(28)} ${addr}`);
    }

    const failed = verifyResults.filter((r) => !r.ok).map((r) => r.name);
    if (failed.length > 0) {
        console.log(`\n⚠️  Block-explorer verification failed for: ${failed.join(", ")}`);
        console.log("   Re-run (idempotent): npx hardhat run tools/scripts/verify-deployments.js --network arbitrum");
    }

    console.log("\nNext steps (protocol multisig, NOT in this script):");
    console.log("  1. diamondCut Replace on SmartLoanDiamondBeacon, pointing SmartLoanLiquidationFacet's");
    console.log("     selectors at the new address.");
};

module.exports.tags = ["arbitrum-liquidation-facet-unblock"];
