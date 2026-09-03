/**
 * Generate a Gnosis Safe Transaction Builder batch that seeds (or clears) the ParaSwap executor
 * whitelist on a deployed TokenManager.
 *
 * ParaSwap executors used to be hardcoded in `ParaSwapHelper` (EXECUTOR_1..EXECUTOR_5), so every
 * executor rotation meant redeploying + diamondCutting ParaSwapFacet / SwapDebtFacet and
 * redeploying DepositSwap. They now live in the TokenManager, managed by its owner via
 * `whitelistParaSwapExecutors(address[])` / `delistParaSwapExecutors(address[])`.
 *
 * IMPORTANT: after upgrading the TokenManager implementation the whitelist starts EMPTY — every
 * ParaSwap route carrying an executor reverts with `InvalidExecutor()` until this batch is
 * executed. Execute it from the TokenManager's owner (protocol Owner Multisig, or the Timelock
 * that owns it) in the SAME window as the facet upgrade.
 *
 * Usage:
 *   node tools/scripts/whitelist-paraswap-executors.js avalanche
 *   node tools/scripts/whitelist-paraswap-executors.js arbitrum --delist
 *   node tools/scripts/whitelist-paraswap-executors.js avalanche --executors 0xAbc...,0xDef...
 *   node tools/scripts/whitelist-paraswap-executors.js arbitrum --out /tmp/batch.json
 */

const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

// TokenManagerTUP per chain — mirrors tools/scripts/select-chain-config.js (the addresses the
// facets actually compile against; the deployments/arbitrum artifact is stale).
const CHAINS = {
    avalanche: { chainId: 43114, tokenManager: "0xF3978209B7cfF2b90100C6F87CEC77dE928Ed58e" },
    arbitrum: { chainId: 42161, tokenManager: "0x0a0D954d4b0F0b47a5990C0abd179A90fF74E255" },
};

// The executor set previously hardcoded in ParaSwapHelper (ParaSwap v6.2 Augustus + executors).
const DEFAULT_EXECUTORS = [
    "0xDEF171Fe48CF0115B1d80b88dc8eAB59176FEe57",
    "0x6A000F20005980200259B80c5102003040001068",
    "0x006D0E0D006109F0020F3050000A713780B7B000",
    "0x082738D007001080A00099A000004f3006152085",
    "0xa000B020C290d000020AaC04026B5306d60050F0",
];

const ABI = [
    "function whitelistParaSwapExecutors(address[] executors) external",
    "function delistParaSwapExecutors(address[] executors) external",
];

function parseArgs(argv) {
    const chain = argv[0];
    if (!chain || !CHAINS[chain]) {
        throw new Error(`First argument must be one of: ${Object.keys(CHAINS).join(", ")}`);
    }

    const opts = { chain, delist: false, executors: DEFAULT_EXECUTORS, out: null };
    for (let i = 1; i < argv.length; i++) {
        if (argv[i] === "--delist") {
            opts.delist = true;
        } else if (argv[i] === "--executors") {
            opts.executors = argv[++i].split(",").map((a) => a.trim()).filter(Boolean);
        } else if (argv[i] === "--out") {
            opts.out = argv[++i];
        } else {
            throw new Error(`Unknown argument: ${argv[i]}`);
        }
    }
    return opts;
}

function main() {
    const opts = parseArgs(process.argv.slice(2));
    const { chainId, tokenManager } = CHAINS[opts.chain];

    const executors = opts.executors.map((a) => ethers.utils.getAddress(a));
    if (executors.length === 0) throw new Error("No executors given");
    if (executors.includes(ethers.constants.AddressZero)) {
        // address(0) is the "no executor decoded" sentinel in ParaSwapHelper — the TokenManager
        // rejects it, so catch it here rather than on-chain.
        throw new Error("address(0) cannot be whitelisted as an executor");
    }

    const method = opts.delist ? "delistParaSwapExecutors" : "whitelistParaSwapExecutors";
    const data = new ethers.utils.Interface(ABI).encodeFunctionData(method, [executors]);

    const batch = {
        version: "1.0",
        chainId: String(chainId),
        createdAt: Date.now(),
        meta: {
            name: `${opts.delist ? "Delist" : "Whitelist"} ParaSwap executors — ${opts.chain}`,
            description:
                `${method}(address[]) on TokenManager ${tokenManager} for ${executors.length} executor(s). ` +
                "Must be executed by the TokenManager owner.",
            txBuilderVersion: "1.16.5",
        },
        transactions: [
            {
                to: tokenManager,
                value: "0",
                data,
                contractMethod: null,
                contractInputsValues: null,
            },
        ],
    };

    const outPath =
        opts.out ||
        path.join(__dirname, `paraswap-executors-${opts.delist ? "delist" : "whitelist"}-${opts.chain}.json`);
    fs.writeFileSync(outPath, `${JSON.stringify(batch, null, 2)}\n`);

    console.log(`${method} on ${opts.chain} TokenManager ${tokenManager}`);
    executors.forEach((e) => console.log(`  - ${e}`));
    console.log(`\nSafe batch written to ${outPath}`);
    console.log("Load it in the Safe Transaction Builder and execute from the TokenManager owner.");
}

main();
