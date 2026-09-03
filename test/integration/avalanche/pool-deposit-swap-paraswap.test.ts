import {ethers, waffle} from 'hardhat'
import chai, {expect} from 'chai'
import {solidity} from "ethereum-waffle";
import { constructSimpleSDK, SimpleFetchSDK, SwapSide } from '@paraswap/sdk';
import axios from 'axios';
import {WrapperBuilder} from "@redstone-finance/evm-connector";

import MockPoolDepositSwapArtifact from '../../../artifacts/contracts/mock/MockPoolDepositSwap.sol/MockPoolDepositSwap.json';
import DepositSwapMockArtifact from '../../../artifacts/contracts/mock/DepositSwapMock.sol/DepositSwapMock.json';
import MockTokenManagerArtifact from '../../../artifacts/contracts/mock/MockTokenManager.sol/MockTokenManager.json';
import SmartLoansFactoryArtifact from '../../../artifacts/contracts/SmartLoansFactory.sol/SmartLoansFactory.json';

import VariableUtilisationRatesCalculatorArtifact
    from '../../../artifacts/contracts/mock/MockVariableUtilisationRatesCalculator.sol/MockVariableUtilisationRatesCalculator.json';
import LinearIndexArtifact from '../../../artifacts/contracts/LinearIndex.sol/LinearIndex.json';

import {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {deployDiamond} from '../../../tools/diamond/deploy-diamond';

import {
    fromWei,
    getFixedGasSigners,
    getRedstonePrices,
    getTokensPricesMap,
    parseParaSwapRouteData,
    toWei,
    wavaxAbi, 
    convertAssetsListToSupportedAssets,
    Asset,
    PoolAsset,
    toBytes32,
    convertTokenPricesMapToMockPrices,
    recompileConstantsFile,
    deployAllFacets,
    whitelistParaSwapExecutors
} from "../../_helpers";
import {
    MockPoolDepositSwap,
    DepositSwapMock,
    MockVariableUtilisationRatesCalculator,
    SmartLoansFactory,
    LinearIndex,
    MockTokenManager
} from "../../../typechain";
import {BigNumber, Contract} from "ethers";
import TOKEN_ADDRESSES from "../../../common/addresses/avax/token_addresses.json";
import { formatUnits } from 'ethers/lib/utils';

import AVAX_TOKEN_ADDRESSES from '../../../common/addresses/avax/token_addresses.json';


chai.use(solidity);

const {deployContract} = waffle;

describe('Deposit Swap Mock', () => {
    let wavaxPool: MockPoolDepositSwap,
        usdcPool: MockPoolDepositSwap,
        wavaxContract: Contract,
        usdcContract: Contract,
        depositSwapContract: DepositSwapMock,
        wrappedDepositSwapContract: Contract,
        mockVariableUtilisationRatesCalculatorWavax: Contract,
        mockVariableUtilisationRatesCalculatorUsdc: Contract,
        smartLoansFactory: Contract,
        depositIndexWavax: Contract,
        borrowIndexWavax: Contract,
        depositIndexUsdc: Contract,
        borrowIndexUsdc: Contract,
        owner: SignerWithAddress,
        depositor: SignerWithAddress,
        tokensPrices: Map<string, number>,
        MOCK_PRICES: any,
        supportedAssets: Array<Asset>,
        lendingPools: Array<PoolAsset> = [],
        paraSwapMin: SimpleFetchSDK;

        const getSwapData = async (userAddress: string, srcToken: keyof typeof TOKEN_ADDRESSES, destToken: keyof typeof TOKEN_ADDRESSES, srcAmount: any) => {
        console.log("getSwapData called with args:", {
            userAddress,
            srcToken,
            destToken,
            srcAmount,
            srcTokenAddress: TOKEN_ADDRESSES[srcToken],
            destTokenAddress: TOKEN_ADDRESSES[destToken]
        });
    
        const priceRoute = await paraSwapMin.swap.getRate({
            srcToken: TOKEN_ADDRESSES[srcToken],
            destToken: TOKEN_ADDRESSES[destToken],
            amount: srcAmount.toString(),
            userAddress,
            side: SwapSide.SELL,
        });
        
        const txParams = await paraSwapMin.swap.buildTx({
            srcToken: priceRoute.srcToken,
            destToken: priceRoute.destToken,
            srcAmount: priceRoute.srcAmount,
            slippage: 300,
            priceRoute,
            userAddress,
            partner: 'anon',
        }, {
            ignoreChecks: true,
        });
        
        const swapData = parseParaSwapRouteData(txParams);
        return swapData;
    };

    before(async () => {
        [owner, depositor] = await getFixedGasSigners(10000000);
        let assetsList = ['AVAX', 'USDC'];

        let diamondAddress = await deployDiamond();

        // Get token prices
        tokensPrices = await getTokensPricesMap(assetsList, "avalanche", getRedstonePrices, []);
        MOCK_PRICES = convertTokenPricesMapToMockPrices(tokensPrices);

        console.log(`MOCK_PRICES: ${JSON.stringify(MOCK_PRICES)}`)

        smartLoansFactory = await deployContract(owner, SmartLoansFactoryArtifact) as SmartLoansFactory;

        let tokenManager = await deployContract(
            owner,
            MockTokenManagerArtifact,
            []
        ) as MockTokenManager;
        
        // WAVAX pool
        wavaxPool = (await deployContract(owner, MockPoolDepositSwapArtifact)) as MockPoolDepositSwap;
        lendingPools.push(new PoolAsset(toBytes32("AVAX"), wavaxPool.address));

        mockVariableUtilisationRatesCalculatorWavax = (await deployContract(owner, VariableUtilisationRatesCalculatorArtifact)) as MockVariableUtilisationRatesCalculator;
        depositIndexWavax = (await deployContract(owner, LinearIndexArtifact, [])) as LinearIndex;
        await depositIndexWavax.initialize(wavaxPool.address);
        borrowIndexWavax = (await deployContract(owner, LinearIndexArtifact, [])) as LinearIndex;
        await borrowIndexWavax.initialize(wavaxPool.address);

        await wavaxPool.initialize(
            mockVariableUtilisationRatesCalculatorWavax.address,
            smartLoansFactory.address,
            depositIndexWavax.address,
            borrowIndexWavax.address,
            AVAX_TOKEN_ADDRESSES["AVAX"], 
            ethers.constants.AddressZero, // No pool rewarder
            toWei("1000000") // 1M token supply cap
        );
        await wavaxPool.setTokenManager(tokenManager.address);
        

        
        // USDC pool
        usdcPool = (await deployContract(owner, MockPoolDepositSwapArtifact)) as MockPoolDepositSwap;
        lendingPools.push(new PoolAsset(toBytes32("USDC"), usdcPool.address));

        mockVariableUtilisationRatesCalculatorUsdc = (await deployContract(owner, VariableUtilisationRatesCalculatorArtifact)) as MockVariableUtilisationRatesCalculator;
        depositIndexUsdc = (await deployContract(owner, LinearIndexArtifact, [])) as LinearIndex;
        await depositIndexUsdc.initialize(usdcPool.address);
        borrowIndexUsdc = (await deployContract(owner, LinearIndexArtifact, [])) as LinearIndex;
        await borrowIndexUsdc.initialize(usdcPool.address);
        
        await usdcPool.initialize(
            mockVariableUtilisationRatesCalculatorUsdc.address,
            smartLoansFactory.address,
            depositIndexUsdc.address,
            borrowIndexUsdc.address,
            AVAX_TOKEN_ADDRESSES["USDC"], 
            ethers.constants.AddressZero, // No pool rewarder
            ethers.utils.parseUnits("1000000", 6) // 1M USDC supply cap (6 decimals)
        );
        await usdcPool.setTokenManager(tokenManager.address);

        supportedAssets = convertAssetsListToSupportedAssets(assetsList, {});
        await tokenManager.connect(owner).initialize(supportedAssets, lendingPools);
        await tokenManager.connect(owner).setFactoryAddress(smartLoansFactory.address);
        // ParaSwap executors are TokenManager-whitelisted (no longer hardcoded in ParaSwapHelper)
        await whitelistParaSwapExecutors(tokenManager, owner);

        // Deploy deposit swap contract
        // 1. Deploy the contract using your helper, but pass an empty array for constructor args
        depositSwapContract = (await deployContract(
            owner, 
            DepositSwapMockArtifact, 
            [] // No constructor arguments needed
        )) as DepositSwapMock;

        // 2. Call the initialize function on the deployed contract instance
        await depositSwapContract.initialize(
            toWei("1000") // 1000 USD slippage threshold
        );

        wrappedDepositSwapContract =  WrapperBuilder
        // @ts-ignore
        .wrap(depositSwapContract.connect(depositor))
        .usingSimpleNumericMock({
            mockSignersCount: 10,
            dataPoints: MOCK_PRICES
        });

        // Console log the deposit swap address for easy replacement in mock contracts
        console.log("DepositSwap Contract Address:", depositSwapContract.address);

        // Set token addresses in deposit swap contract
        await depositSwapContract.setTokenAddresses(
            AVAX_TOKEN_ADDRESSES["AVAX"], // WAVAX
            AVAX_TOKEN_ADDRESSES["USDC"],  // USDC
            AVAX_TOKEN_ADDRESSES["ETH"],  // ETH
            AVAX_TOKEN_ADDRESSES["BTC"],  // BTC
            AVAX_TOKEN_ADDRESSES["USDT"]  // USDT
        );

        // Set pool addresses in deposit swap contract
        await depositSwapContract.setPoolAddresses(
            wavaxPool.address,  // WAVAX pool
            usdcPool.address,   // USDC pool
            ethers.constants.AddressZero, // ETH pool (not used in this test)
            ethers.constants.AddressZero, // BTC pool (not used in this test)
            ethers.constants.AddressZero  // USDT pool (not used in this test)
        );

        // Set deposit swap address in pools
        await wavaxPool.setDepositSwapAddress(depositSwapContract.address);
        await usdcPool.setDepositSwapAddress(depositSwapContract.address);

        // Get token contracts
        wavaxContract = new ethers.Contract(AVAX_TOKEN_ADDRESSES["AVAX"], wavaxAbi, depositor);
        usdcContract = new ethers.Contract(AVAX_TOKEN_ADDRESSES["USDC"], [
            "function balanceOf(address) view returns (uint256)",
            "function approve(address,uint256) returns (bool)",
            "function transfer(address,uint256) returns (bool)"
        ], depositor);


        await recompileConstantsFile(
                        'local',
                        "DeploymentConstants",
                        [],
                        tokenManager.address,
                        ethers.constants.AddressZero,
                        diamondAddress,
                        smartLoansFactory.address,
                        'lib'
                    );
        await deployAllFacets(diamondAddress)
        

        // Initialize ParaSwap SDK
        paraSwapMin = constructSimpleSDK({chainId: 43114, axios});

        // Make initial deposits to set up the pools
        await setupInitialDeposits();
    });

    const setupInitialDeposits = async () => {
        // Deposit AVAX to get WAVAX
        await wavaxContract.connect(depositor).deposit({value: toWei("20.0")});
        console.log("Depositor WAVAX balance after wrapping:", fromWei(await wavaxContract.balanceOf(depositor.address)));

        // Deposit 10 WAVAX to wavaxPool for the test
        await wavaxContract.connect(depositor).approve(wavaxPool.address, toWei("15.0"));
        await wavaxPool.connect(depositor).deposit(toWei("15.0"));
        console.log("Depositor pool balance after deposit:", fromWei(await wavaxPool.balanceOf(depositor.address)));

        // Add some liquidity to USDC pool as well (if available)
        const usdcBalance = await usdcContract.balanceOf(depositor.address);
        if (usdcBalance.gt(0)) {
            const depositAmount = usdcBalance.div(2); // Use half of available USDC
            await usdcContract.connect(depositor).approve(usdcPool.address, depositAmount);
            await usdcPool.connect(depositor).deposit(depositAmount);
            console.log("USDC pool initial deposit:", formatUnits(depositAmount, 6));
        }
    };

    it("should verify mock setup", async () => {
        // Verify deposit swap address is set correctly
        expect((await wavaxPool.getDepositSwapAddressPublic()).toLowerCase()).to.equal(depositSwapContract.address.toLowerCase());
        expect((await usdcPool.getDepositSwapAddressPublic()).toLowerCase()).to.equal(depositSwapContract.address.toLowerCase());
        
        // Verify token addresses in deposit swap
        expect((await depositSwapContract.WAVAX()).toLowerCase()).to.equal(AVAX_TOKEN_ADDRESSES["AVAX"].toLowerCase());
        expect((await depositSwapContract.USDC()).toLowerCase()).to.equal(AVAX_TOKEN_ADDRESSES["USDC"].toLowerCase());
        
        // Verify pool addresses in deposit swap
        expect((await depositSwapContract.WAVAX_POOL_TUP()).toLowerCase()).to.equal(wavaxPool.address.toLowerCase());
        expect((await depositSwapContract.USDC_POOL_TUP()).toLowerCase()).to.equal(usdcPool.address.toLowerCase());
        
        console.log("Mock setup verification passed");
    });

    it("should deposit AVAX to WAVAX", async () => {
        const initialBalance = await wavaxContract.balanceOf(depositor.address);
        await wavaxContract.connect(depositor).deposit({value: toWei("10.0")});
        const finalBalance = await wavaxContract.balanceOf(depositor.address);
        
        expect(finalBalance.sub(initialBalance)).to.equal(toWei("10.0"));
    });

    it("should deposit requested value to pool", async () => {
        const initialPoolBalance = await wavaxPool.balanceOf(depositor.address);
        
        await wavaxContract.connect(depositor).approve(wavaxPool.address, toWei("5.0"));
        await wavaxPool.connect(depositor).deposit(toWei("5.0"));

        const finalPoolBalance = await wavaxPool.balanceOf(depositor.address);
        expect(finalPoolBalance.sub(initialPoolBalance)).to.equal(toWei("5.0"));
    });

    it("should swap deposits from AVAX to USDC", async () => {
        const initialWavaxPoolBalance = await wavaxPool.balanceOf(depositor.address);
        const initialUsdcPoolBalance = await usdcPool.balanceOf(depositor.address);
        
        console.log("Initial WAVAX pool balance:", fromWei(initialWavaxPoolBalance));
        console.log("Initial USDC pool balance:", formatUnits(initialUsdcPoolBalance, 6));
        
        expect(initialWavaxPoolBalance).to.be.gte(toWei("10.0")); // Should have at least 10 WAVAX from setup

        const swapAmount = toWei("10.0");
        const swapData = await getSwapData(depositSwapContract.address, 'AVAX', 'USDC', swapAmount);

        await wavaxPool.connect(depositor).approve(depositSwapContract.address, swapAmount);
        
        await wrappedDepositSwapContract.depositSwapParaSwapV6(
            swapData.selector,
            swapData.data,
            TOKEN_ADDRESSES['AVAX'],
            swapAmount,
            TOKEN_ADDRESSES['USDC'],
            1 // Minimum 1 USDC
        );

        const finalWavaxPoolBalance = await wavaxPool.balanceOf(depositor.address);
        const finalUsdcPoolBalance = await usdcPool.balanceOf(depositor.address);
        
        console.log("Final WAVAX pool balance:", fromWei(finalWavaxPoolBalance));
        console.log("Final USDC pool balance:", formatUnits(finalUsdcPoolBalance, 6));

        // Verify the swap worked
        expect(finalWavaxPoolBalance).to.be.closeTo(
            initialWavaxPoolBalance.sub(swapAmount), 
            toWei("0.01") // Allow small difference due to rounding
        );
        
        const expectedUsdcValue = tokensPrices.get("AVAX")! * 10; // 10 AVAX worth of USDC
        expect(parseFloat(formatUnits(finalUsdcPoolBalance.sub(initialUsdcPoolBalance), 6)))
            .to.be.closeTo(expectedUsdcValue, expectedUsdcValue * 0.05); // 5% tolerance for slippage
    });
});