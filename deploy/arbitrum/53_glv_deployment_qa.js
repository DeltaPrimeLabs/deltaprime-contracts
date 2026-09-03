import hre from "hardhat";
import fs from 'fs';
import path from 'path';
const { ethers } = require("hardhat");

const FacetCutAction = { Add: 0, Replace: 1, Remove: 2 };

// Helper function to get specific selectors for a facet
function getSelectorsForFunctions(contract, functionNames) {
    return functionNames.map(name => {
        const fragment = contract.interface.getFunction(name);
        return contract.interface.getSighash(fragment);
    });
}

// Helper function to check if selector exists in diamond and get its current facet address
async function getSelectorInfo(diamondLoupe, selector) {
    try {
        const facetAddress = await diamondLoupe.facetAddress(selector);
        return {
            exists: facetAddress !== ethers.constants.AddressZero,
            currentAddress: facetAddress
        };
    } catch (error) {
        console.log(`Warning: Could not check selector ${selector}, assuming it doesn't exist`);
        return {
            exists: false,
            currentAddress: ethers.constants.AddressZero
        };
    }
}

// Save rollback data to JSON file
function saveRollbackData(rollbackData) {
    const rollbackPath = path.join(__dirname, 'diamond-upgrade-rollback.json');
    fs.writeFileSync(rollbackPath, JSON.stringify(rollbackData, null, 2));
    console.log(`📋 Rollback data saved to: ${rollbackPath}`);
}

// Load rollback data from JSON file
function loadRollbackData() {
    const rollbackPath = path.join(__dirname, 'diamond-upgrade-rollback.json');
    if (!fs.existsSync(rollbackPath)) {
        throw new Error(`Rollback file not found: ${rollbackPath}`);
    }
    const data = fs.readFileSync(rollbackPath, 'utf8');
    return JSON.parse(data);
}

// Check if this is a rollback operation
function isRollbackMode() {
    return process.env.ROLLBACK === 'true' || process.argv.includes('--rollback');
}

// Rollback function
async function executeRollback({ getNamedAccounts }) {
    const { deployer } = await getNamedAccounts();
    
    console.log("\n🔄 Diamond Upgrade Rollback Operation Starting");
    
    const rollbackData = loadRollbackData();
    console.log(`📋 Loaded rollback data from: ${rollbackData.timestamp}`);
    console.log(`Diamond Address: ${rollbackData.diamondAddress}`);
    
    // Get diamond contracts
    const diamondCut = await ethers.getContractAt('IDiamondCut', rollbackData.diamondAddress);
    
    console.log(`\n--- Preparing Rollback Cuts ---`);
    const rollbackCuts = [];
    
    for (const operation of rollbackData.operations) {
        if (operation.type === 'REPLACE') {
            // For rollback, we replace back to the previous addresses
            rollbackCuts.push({
                facetAddress: operation.previousAddress,
                action: FacetCutAction.Replace,
                functionSelectors: operation.selectors
            });
            console.log(`ROLLBACK REPLACE: ${operation.selectors.length} selectors back to ${operation.previousAddress}`);
        } else if (operation.type === 'ADD') {
            // For rollback, we remove the functions that were added
            rollbackCuts.push({
                facetAddress: ethers.constants.AddressZero,
                action: FacetCutAction.Remove,
                functionSelectors: operation.selectors
            });
            console.log(`ROLLBACK REMOVE: ${operation.selectors.length} selectors (were added)`);
        }
    }
    
    if (rollbackCuts.length === 0) {
        console.log(`\n⚠️  No rollback operations needed.`);
        return;
    }
    
    console.log(`\nTotal rollback operations: ${rollbackCuts.length}`);
    
    // Pause the diamond
    console.log("\n--- Pausing Diamond for Rollback ---");
    let tx = await diamondCut.pause();
    await tx.wait();
    console.log(`✅ Diamond paused (tx: ${tx.hash})`);
    
    // Execute rollback
    console.log(`\n--- Executing Rollback Diamond Cut ---`);
    tx = await diamondCut.diamondCut(rollbackCuts, ethers.constants.AddressZero, "0x", {
        gasLimit: 15000000
    });
    console.log(`Rollback tx: ${tx.hash}`);
    
    const receipt = await tx.wait();
    if (!receipt.status) {
        throw Error(`Rollback failed: ${tx.hash}`);
    }
    console.log('✅ Rollback completed successfully');
    
    // Unpause diamond
    console.log("\n--- Unpausing Diamond ---");
    tx = await diamondCut.unpause();
    await tx.wait();
    console.log(`✅ Diamond unpaused (tx: ${tx.hash})`);
    
    console.log(`\n🎉 Rollback completed successfully!`);
    console.log(`Diamond has been reverted to its previous state.`);
}

module.exports = async ({ getNamedAccounts, deployments }) => {
    // Check if this is a rollback operation
    if (isRollbackMode()) {
        return executeRollback({ getNamedAccounts });
    }

    const { deployer } = await getNamedAccounts();

    // REPLACE THIS WITH ACTUAL DIAMOND ADDRESS
    const DIAMOND_ADDRESS = "0x968f944e9c43FC8AD80F6C1629F10570a46e2651";

    // Facet upgrade configurations - REPLACE WITH YOUR DEPLOYED ADDRESSES
    const facetUpgrades = [
        {
            name: "GlvFacetArbitrum",
            address: "0x11847eE581f524C29a54541A9D91587B941D22f3", // REPLACE WITH DEPLOYED ADDRESS
            functions: [
                'depositWethUsdcGlv',
                'withdrawWethUsdcGlv',
                'sweepFeesAndUpdateGlvBenchMark',
                'getGlvPerformance',
                'depositBtcUsdcGlv',
                'withdrawBtcUsdcGlv'
            ]
        },
        // {
        //     name: "AssetsOperationsArbitrumFacet",
        //     address: "0x242D26478569075497A548169839141f272AFE07", // REPLACE WITH DEPLOYED ADDRESS
        //     functions: [
        //         'removeUnsupportedOwnedAsset',
        //         'removeUnsupportedStakedPosition',
        //         'fund',
        //         'addOwnedAsset',
        //         'fundGLP',
        //         'borrow',
        //         'repay',
        //         'withdrawUnsupportedToken',
        //         'unfreezeAccount'
        //     ]
        // },
        // {
        //     name: "GmxV2CallbacksFacetArbitrum",
        //     address: "0x587D6891a8a3CD1C058bf7e213cBFe85a6B05645", // REPLACE WITH DEPLOYED ADDRESS
        //     functions: [
        //         'afterDepositExecution',
        //         'afterDepositCancellation',
        //         'afterWithdrawalExecution',
        //         'afterWithdrawalCancellation',
        //         'refundExecutionFee',
        //         'afterGlvDepositExecution',
        //         'afterGlvDepositCancellation',
        //         'afterGlvWithdrawalExecution',
        //         'afterGlvWithdrawalCancellation',
        //     ]
        // },

        {
            name: "GmxV2FacetArbitrum",
            address: "0x6c2df7892BD5Af7CD9B739E262a504C9De921AC8", // REPLACE WITH DEPLOYED ADDRESS
            functions: [
                'depositArbUsdcGmxV2',
                'depositAtomUsdcGmxV2',
                'depositBtcUsdcGmxV2',
                'depositEthUsdcGmxV2',
                'depositGmxUsdcGmxV2',
                'depositLinkUsdcGmxV2',
                'depositNearUsdcGmxV2',
                'depositSeiUsdcGmxV2',
                'depositSolUsdcGmxV2',
                'depositSuiUsdcGmxV2',
                'depositUniUsdcGmxV2',
                'getGmPerformance',
                'withdrawArbUsdcGmxV2',
                'withdrawAtomUsdcGmxV2',
                'withdrawBtcUsdcGmxV2',
                'withdrawEthUsdcGmxV2',
                'withdrawGmxUsdcGmxV2',
                'withdrawLinkUsdcGmxV2',
                'withdrawNearUsdcGmxV2',
                'withdrawSeiUsdcGmxV2',
                'withdrawSolUsdcGmxV2',
                'withdrawSuiUsdcGmxV2',
                'withdrawUniUsdcGmxV2'
            ]
        },
        {
            name: "GmxV2PlusFacetArbitrum",
            address: "0xbCfBEb8Ef1491110E6C82470C878aA6511B76173", // REPLACE WITH DEPLOYED ADDRESS
            functions: [
                'depositBtcGmxV2Plus',
                'depositEthGmxV2Plus',
                'depositGmxGmxV2Plus',
                'getGmPlusPerformance',
                'withdrawBtcGmxV2Plus',
                'withdrawEthGmxV2Plus',
                'withdrawGmxGmxV2Plus'
            ]
        },
        // {
        //     name: "SolvencyFacetProdArbitrum",
        //     address: "0x8f27FCBa1Eb1f2Baf09A079803C7c6D3815D3641", // REPLACE WITH DEPLOYED ADDRESS
        //     functions: [
        //         'getPricesFromRedstoneAndChainlink',
        //         'isSolvent',
        //         'isSolventPayable',
        //         'isSolventWithPrices',
        //         'getStakedPositionsPrices',
        //         'getDebtAssets',
        //         'getDebtAssetsPrices',
        //         'getOwnedAssetsWithNativePrices',
        //         'getPrices',
        //         'getPrice',
        //         'getThresholdWeightedValue',
        //         'getThresholdWeightedValuePayable',
        //         'getThresholdWeightedValueWithPrices',
        //         'getDebt',
        //         'getDebtPayable',
        //         'getDebtWithPrices',
        //         'getTotalAssetsValue',
        //         'getTotalAssetsValueWithPrices',
        //         'getOwnedAssetsWithNative',
        //         'getTotalTraderJoeV2',
        //         'getStakedValueWithPrices',
        //         'getStakedValue',
        //         'getTotalValue',
        //         'getFullLoanStatus',
        //         'getHealthRatio',
        //         'getHealthRatioWithPrices',
        //         'canRepayDebtFully',
        //         'getAllPricesForLiquidation'
        //     ]
        // },
        // {
        //     name: "WithdrawalIntentFacet",
        //     address: "0xEFeB67F85ec889C08bFE9A20093635EaD8AB194c", // REPLACE WITH DEPLOYED ADDRESS
        //     functions: [
        //         'createWithdrawalIntent',
        //         'executeWithdrawalIntent',
        //         'cancelWithdrawalIntent',
        //         'clearExpiredIntents',
        //         'getUserIntents',
        //         'getTotalIntentAmount',
        //         'getAvailableBalance',
        //         'getAvailableBalancePayable'
        //     ]
        // }
    ];

    console.log("\n🔄 Diamond Facet Upgrade Starting");
    console.log(`Diamond Address: ${DIAMOND_ADDRESS}`);
    console.log(`Facets to upgrade: ${facetUpgrades.length}`);

    // Validate that all addresses are set
    const unsetAddresses = facetUpgrades.filter(f => f.address === "0x0000000000000000000000000000000000000000");
    if (unsetAddresses.length > 0) {
        throw new Error(`Please set deployed addresses for: ${unsetAddresses.map(f => f.name).join(', ')}`);
    }

    // Initialize rollback data
    const rollbackData = {
        timestamp: new Date().toISOString(),
        diamondAddress: DIAMOND_ADDRESS,
        operations: []
    };

    // Phase 1: Prepare Diamond Cuts (BEFORE pausing)
    console.log("\n" + "=".repeat(50));
    console.log("PHASE 1: ANALYZING DIAMOND STATE & PREPARING CUTS");
    console.log("=".repeat(50));

    // Get diamond contracts
    const diamondCut = await ethers.getContractAt('IDiamondCut', DIAMOND_ADDRESS);
    const diamondLoupe = await ethers.getContractAt('IDiamondLoupe', DIAMOND_ADDRESS);

    // Prepare all cuts with automatic Add/Replace detection BEFORE pausing
    console.log("\n--- Analyzing Current Diamond State ---");
    const allCuts = [];

    for (const facetConfig of facetUpgrades) {
        console.log(`\nProcessing ${facetConfig.name}...`);
        console.log(`  Address: ${facetConfig.address}`);
        
        const facetContract = await ethers.getContractAt(facetConfig.name, facetConfig.address);
        const selectors = getSelectorsForFunctions(facetContract, facetConfig.functions);
        
        console.log(`  Functions: ${facetConfig.functions.length}`);
        console.log(`  Selectors: ${selectors.length}`);

        // Check each selector to determine Add/Replace/Skip
        const selectorsToAdd = [];
        const selectorsToReplace = [];
        const selectorsSkipped = [];
        const replacementInfo = []; // For rollback data

        for (let i = 0; i < selectors.length; i++) {
            const selector = selectors[i];
            const functionName = facetConfig.functions[i];
            
            // Get current selector info BEFORE pausing the diamond
            const selectorInfo = await getSelectorInfo(diamondLoupe, selector);
            
            if (!selectorInfo.exists) {
                // Function doesn't exist -> Add
                selectorsToAdd.push(selector);
                console.log(`    ${functionName} (${selector}): ADD (new function)`);
            } else if (selectorInfo.currentAddress.toLowerCase() === facetConfig.address.toLowerCase()) {
                // Function exists and points to the same address -> Skip
                selectorsSkipped.push(selector);
                console.log(`    ${functionName} (${selector}): SKIP (same address: ${selectorInfo.currentAddress})`);
            } else {
                // Function exists but points to different address -> Replace
                selectorsToReplace.push(selector);
                replacementInfo.push({
                    selector: selector,
                    functionName: functionName,
                    previousAddress: selectorInfo.currentAddress,
                    newAddress: facetConfig.address
                });
                console.log(`    ${functionName} (${selector}): REPLACE (${selectorInfo.currentAddress} -> ${facetConfig.address})`);
            }
        }

        // Store rollback information for this facet
        if (selectorsToAdd.length > 0) {
            rollbackData.operations.push({
                facetName: facetConfig.name,
                type: 'ADD',
                selectors: selectorsToAdd,
                newAddress: facetConfig.address,
                functionNames: facetConfig.functions.filter((_, i) => selectorsToAdd.includes(selectors[i]))
            });
        }

        if (selectorsToReplace.length > 0) {
            rollbackData.operations.push({
                facetName: facetConfig.name,
                type: 'REPLACE',
                selectors: selectorsToReplace,
                newAddress: facetConfig.address,
                previousAddress: replacementInfo[0].previousAddress, // All selectors in this facet should have same previous address
                functionNames: replacementInfo.map(info => info.functionName),
                replacementDetails: replacementInfo
            });
        }

        // Create cuts for Add and Replace separately (skip the skipped ones)
        if (selectorsToAdd.length > 0) {
            allCuts.push({
                facetAddress: facetConfig.address,
                action: FacetCutAction.Add,
                functionSelectors: selectorsToAdd
            });
        }

        if (selectorsToReplace.length > 0) {
            allCuts.push({
                facetAddress: facetConfig.address,
                action: FacetCutAction.Replace,
                functionSelectors: selectorsToReplace
            });
        }

        console.log(`  Operations: ${selectorsToAdd.length} Add, ${selectorsToReplace.length} Replace, ${selectorsSkipped.length} Skip`);
        
        if (selectorsSkipped.length > 0) {
            console.log(`  ⚠️  Skipped functions (already pointing to same address): ${selectorsSkipped.length}`);
        }
    }

    console.log(`\nTotal cut operations prepared: ${allCuts.length}`);

    if (allCuts.length === 0) {
        console.log(`\n⚠️  No diamond cuts needed - all functions are already up to date!`);
        console.log(`🎉 Upgrade completed - no changes required.`);
        
        // Save empty rollback data
        rollbackData.operations = [];
        saveRollbackData(rollbackData);
        return;
    }

    // Save rollback data before executing cuts
    saveRollbackData(rollbackData);

    // Phase 2: Diamond operations (NOW we can pause safely)
    console.log("\n" + "=".repeat(50));
    console.log("PHASE 2: EXECUTING DIAMOND UPGRADE");
    console.log("=".repeat(50));

    // Pause the diamond
    console.log("\n--- Pausing Diamond ---");
    let tx = await diamondCut.pause();
    await tx.wait();
    console.log(`✅ Diamond paused (tx: ${tx.hash})`);

    // Execute all diamond cuts in one transaction
    console.log(`\n--- Executing Diamond Cut ---`);
    console.log(`Total cut operations: ${allCuts.length}`);
    
    tx = await diamondCut.diamondCut(allCuts, ethers.constants.AddressZero, "0x", {
        gasLimit: 15000000
    });
    console.log(`Diamond cut tx: ${tx.hash}`);
    
    const receipt = await tx.wait();
    if (!receipt.status) {
        throw Error(`Diamond cut failed: ${tx.hash}`);
    }
    console.log('✅ Diamond cut completed successfully');

    // Unpause diamond
    console.log("\n--- Unpausing Diamond ---");
    tx = await diamondCut.unpause();
    await tx.wait();
    console.log(`✅ Diamond unpaused (tx: ${tx.hash})`);

    // Phase 3: Summary
    console.log("\n" + "=".repeat(50));
    console.log("UPGRADE SUMMARY");
    console.log("=".repeat(50));
    
    console.log(`\nDiamond Address: ${DIAMOND_ADDRESS}`);
    console.log(`Total Facets Upgraded: ${facetUpgrades.length}`);
    console.log(`Total Cut Operations: ${allCuts.length}`);
    
    console.log(`\n--- Upgraded Facets ---`);
    for (const facetConfig of facetUpgrades) {
        console.log(`${facetConfig.name}:`);
        console.log(`  Address: ${facetConfig.address}`);
        console.log(`  Functions: ${facetConfig.functions.length}`);
        console.log(`  Methods: ${facetConfig.functions.join(', ')}`);
        console.log('');
    }

    console.log(`\n--- Cut Operations Summary ---`);
    let totalAdded = 0;
    let totalReplaced = 0;
    
    for (const cut of allCuts) {
        const actionName = cut.action === FacetCutAction.Add ? 'ADD' : 'REPLACE';
        console.log(`${actionName}: ${cut.functionSelectors.length} selectors at ${cut.facetAddress}`);
        
        if (cut.action === FacetCutAction.Add) {
            totalAdded += cut.functionSelectors.length;
        } else {
            totalReplaced += cut.functionSelectors.length;
        }
    }
    
    console.log(`\nTotal Functions Added: ${totalAdded}`);
    console.log(`Total Functions Replaced: ${totalReplaced}`);
    console.log(`\n📋 Rollback data saved - use 'ROLLBACK=true' or '--rollback' to revert this upgrade`);
    console.log(`\n🎉 Facet upgrade completed successfully!`);
    console.log(`Diamond is unpaused and ready with all updated facets.`);
};

module.exports.tags = ["upgrade-diamond-facets"];