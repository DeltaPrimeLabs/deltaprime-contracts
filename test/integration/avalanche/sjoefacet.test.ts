import { ethers, waffle } from "hardhat";
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  addMissingTokenContracts,
  Asset,
  convertAssetsListToSupportedAssets,
  convertTokenPricesMapToMockPrices,
  deployAllFacets,
  erc20ABI,
  fromBytes32,
  fromWei,
  getFixedGasSigners,
  getRedstonePrices,
  getTokensPricesMap,
  toBytes32,
  toWei,
  getContractSelectors,
  deployPools,
  formatUnits,
  wavaxAbi,
  PoolAsset,
  PoolInitializationObject,
  recompileConstantsFile,
  parseParaSwapRouteData,
  whitelistParaSwapExecutors,
} from "../../_helpers";
import { syncTime } from "../../_syncTime";
import { WrapperBuilder } from "@redstone-finance/evm-connector";
import {
  AddressProvider,
  MockTokenManager,
  SmartLoanGigaChadInterface,
  SmartLoansFactory,
} from "../../../typechain";
import {
  constructSimpleSDK,
  ContractMethod,
  SimpleFetchSDK,
  SwapSide,
} from "@paraswap/sdk";
import axios from "axios";
import { BigNumber, Contract } from "ethers";
import { deployDiamond } from "../../../tools/diamond/deploy-diamond";
import { parseUnits } from "ethers/lib/utils";
import TOKEN_ADDRESSES from "../../../common/addresses/avax/token_addresses.json";

import MockTokenManagerArtifact from "../../../artifacts/contracts/mock/MockTokenManager.sol/MockTokenManager.json";
import SmartLoansFactoryArtifact from "../../../artifacts/contracts/SmartLoansFactory.sol/SmartLoansFactory.json";
import AddressProviderArtifact from "../../../artifacts/contracts/AddressProvider.sol/AddressProvider.json";

chai.use(solidity);

const { deployContract, provider } = waffle;

describe("Smart loan", () => {
  before("Synchronize blockchain time", async () => {
    await syncTime();
  });

  describe("A loan with SJoe staking operations", () => {
    let smartLoansFactory: SmartLoansFactory,
      loan: SmartLoanGigaChadInterface,
      wrappedLoan: any,
      nonOwnerWrappedLoan: any,
      tokenContracts: Map<string, Contract> = new Map(),
      supportedAssets: Array<Asset>,
      tokensPrices: Map<string, number>,
      owner: SignerWithAddress,
      nonOwner: SignerWithAddress,
      paraSwapMin: SimpleFetchSDK,
      MOCK_PRICES: any,
      diamondAddress: any;

    const getSwapData = async (
      srcToken: keyof typeof TOKEN_ADDRESSES,
      destToken: keyof typeof TOKEN_ADDRESSES,
      srcAmount: any,
      slippage: any = 100, // default to 1%
      srcDecimals: number = 18,
      destDecimals: number = 18
    ) => {
      console.log(`USING SLIIPAGE: ${slippage}`);
      const priceRoute = await paraSwapMin.swap.getRate({
        srcToken: TOKEN_ADDRESSES[srcToken],
        destToken: TOKEN_ADDRESSES[destToken],
        amount: srcAmount.toString(),
        userAddress: wrappedLoan.address,
        side: SwapSide.SELL,
        srcDecimals: srcDecimals,
        destDecimals: destDecimals,
        // excludeContractMethods: ["swapExactAmountIn", "swapExactAmountInOnUniswapV3"],  swapExactAmountIn, uniV3 v6.2: swapExactAmountInOnUniswapV3
        includeContractMethods: [
          "swapExactAmountIn",
          "swapExactAmountInOnUniswapV3",
        ],
        // version specification
        // https://github.com/paraswap/paraswap-sdk/blob/17c2c2162fac8a5cb18aaa9588c44c0c6545f8f7/src/methods/swap/rates.ts#L129
        version: 6.2,
      });
      const txParams = await paraSwapMin.swap.buildTx(
        {
          srcToken: priceRoute.srcToken,
          destToken: priceRoute.destToken,
          srcAmount: priceRoute.srcAmount,
          slippage: slippage,
          priceRoute,
          deadline: Math.floor(Date.now() / 1000) + 300, // 500 minutes deadline
          userAddress: wrappedLoan.address,
          partnerAddress: "0x8995d790169023Ee4fF67621948EBDFe7383f59e",
          partnerFeeBps: 1,
          partner: "deltaprime",
        },
        {
          ignoreChecks: true,
        }
      );

      const swapData = parseParaSwapRouteData(txParams);
      return swapData;
    };

    const JOE_TOKEN_ADDRESS = TOKEN_ADDRESSES["JOE"]; // Make sure JOE is in your token_addresses.json
    const SJOE_ADDRESS = "0x1a731B2299E22FbAC282E7094EdA41046343Cb51";
    const USDC_ADDRESS = TOKEN_ADDRESSES["USDC"]; // Assuming USDC is in token_addresses.json

    before("deploy factory and pool", async () => {
      [owner, nonOwner] = await getFixedGasSigners(10000000);
      let assetsList = ["AVAX", "JOE", "USDC"]; // Include JOE and USDC in the assets list

      diamondAddress = await deployDiamond();

      smartLoansFactory = (await deployContract(
        owner,
        SmartLoansFactoryArtifact
      )) as SmartLoansFactory;

      let tokenManager = (await deployContract(
        owner,
        MockTokenManagerArtifact,
        []
      )) as MockTokenManager;

      tokensPrices = await getTokensPricesMap(
        assetsList,
        "avalanche",
        getRedstonePrices
      );
      MOCK_PRICES = convertTokenPricesMapToMockPrices(tokensPrices);
      addMissingTokenContracts(tokenContracts, assetsList, "AVAX");
      supportedAssets = convertAssetsListToSupportedAssets(
        assetsList,
        [],
        "AVAX"
      );

      await tokenManager.connect(owner).initialize(supportedAssets, []);
      await tokenManager
        .connect(owner)
        .setFactoryAddress(smartLoansFactory.address);
      // ParaSwap executors are TokenManager-whitelisted (no longer hardcoded in ParaSwapHelper)
      await whitelistParaSwapExecutors(tokenManager, owner);

      await smartLoansFactory.initialize(diamondAddress, tokenManager.address);

      let addressProvider = (await deployContract(
        owner,
        AddressProviderArtifact,
        []
      )) as AddressProvider;

      await recompileConstantsFile(
        'local',
        "DeploymentConstants",
        [],
        tokenManager.address,
        addressProvider.address,
        diamondAddress,
        smartLoansFactory.address,
        'lib',
        5000,
        "1.042e18",
        200,
        "AVAX",
        "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"
      );


      await deployAllFacets(diamondAddress, true, "AVAX");
      paraSwapMin = constructSimpleSDK({ chainId: 43114, axios });

      // After deploying all facets, verify SJoeFacet is properly added
      const diamondContract = await ethers.getContractAt(
        "DiamondLoupeFacet",
        diamondAddress
      );
      const facets = await diamondContract.facets();

      // Check specifically for stakeJoe function selector
      const stakeJoeSelector = ethers.utils
        .id("stakeJoe(uint256)")
        .slice(0, 10);
      console.log("stakeJoe selector:", stakeJoeSelector);

      const hasFacet = facets.some((facet) =>
        facet.functionSelectors.some(
          (selector) => selector === stakeJoeSelector
        )
      );

      console.log("Has stakeJoe function:", hasFacet);
    });

    it("should deploy a smart loan", async () => {
      await smartLoansFactory.connect(owner).createLoan();
      const loan_proxy_address = await smartLoansFactory.getLoanForOwner(
        owner.address
      );
      loan = await ethers.getContractAt(
        "SmartLoanGigaChadInterface",
        loan_proxy_address,
        owner
      );

      wrappedLoan = WrapperBuilder.wrap(loan).usingSimpleNumericMock({
        mockSignersCount: 3,
        dataPoints: MOCK_PRICES,
      });

      nonOwnerWrappedLoan = WrapperBuilder.wrap(
        loan.connect(nonOwner)
      ).usingSimpleNumericMock({
        mockSignersCount: 3,
        dataPoints: MOCK_PRICES,
      });
    });

    it("should fund a loan", async () => {
      await tokenContracts
        .get("AVAX")!
        .connect(owner)
        .deposit({ value: toWei("100") });
      await tokenContracts
        .get("AVAX")!
        .connect(owner)
        .approve(wrappedLoan.address, toWei("100"));
      await wrappedLoan.fund(toBytes32("AVAX"), toWei("100"));
    });

    it("should swap funds: AVAX -> JOE", async () => {
      let initialTotalValue = fromWei(await wrappedLoan.getTotalValue());
      let initialHR = fromWei(await wrappedLoan.getHealthRatio());
      let initialTWV = fromWei(await wrappedLoan.getThresholdWeightedValue());

      expect(await loanOwnsAsset("JOE")).to.be.false;
      console.log("Loan does not own JOE yet");

      let minOut = parseUnits(
        (tokensPrices.get("AVAX")! * 9.7).toFixed(18),
        18
      );
      const swapData = await getSwapData("AVAX", "JOE", toWei("10"), 300);
      console.log("MinOut for AVAX -> JOE: ", minOut);
      await wrappedLoan.paraSwapV6(swapData.selector, swapData.data);

      expect(await loanOwnsAsset("JOE")).to.be.true;

      expect(fromWei(await wrappedLoan.getTotalValue())).to.be.closeTo(
        initialTotalValue,
        0.01 * initialTotalValue
      );
      expect(fromWei(await wrappedLoan.getHealthRatio())).to.be.closeTo(
        initialHR,
        0.01 * initialHR
      );
      expect(
        fromWei(await wrappedLoan.getThresholdWeightedValue())
      ).to.be.closeTo(initialTWV, 0.01 * initialTWV);
    });

    it("should stake JOE tokens", async () => {
      // Check initial balances
      const joeContract = new ethers.Contract(
        JOE_TOKEN_ADDRESS,
        erc20ABI,
        owner
      );
      const sJoeContract = new ethers.Contract(SJOE_ADDRESS, erc20ABI, owner);
      const usdcContract = new ethers.Contract(USDC_ADDRESS, erc20ABI, owner);

      const initialJoeBalance = await joeContract.balanceOf(
        wrappedLoan.address
      );
      console.log(`Initial JOE balance: ${fromWei(initialJoeBalance)}`);
      const initialUsdcBalance = await usdcContract.balanceOf(
        wrappedLoan.address
      );

      // Determine amount to stake (half of balance)
      const stakeAmount = initialJoeBalance.div(2);
      console.log(`Trying to Stake ${fromWei(stakeAmount)} JOE tokens`);

      // Get total value before staking for comparison
      let initialTotalValue = fromWei(await wrappedLoan.getTotalValue());
      let initialHR = fromWei(await wrappedLoan.getHealthRatio());

      // Stake JOE using the wrapped loan (with Redstone price data)
      try {
        await wrappedLoan.stakeJoe(stakeAmount);
        console.log("Gotten Past stakeJoe function");
      } catch (error) {
        console.error("Error staking JOE:", error.message);
      }

      // Check balances after staking
      const finalJoeBalance = await joeContract.balanceOf(wrappedLoan.address);
      console.log(`Final JOE balance: ${fromWei(finalJoeBalance)}`);

      // JOE balance should decrease by the staked amount
      expect(finalJoeBalance).to.equal(
        initialJoeBalance.sub(stakeAmount),
        "JOE balance should decrease by the staked amount"
      );

      // Check staked position through helper method
      const joeBalanceInSJoe = await wrappedLoan.joeBalanceInSJoe();
      console.log(`JOE balance in sJOE: ${fromWei(joeBalanceInSJoe)}`);
      expect(joeBalanceInSJoe).to.be.gte(
        stakeAmount.mul(95).div(100), // Allow for 5% slippage or difference
        "Staked JOE balance should be at least 95% of the amount staked"
      );

      // Verify staked position in list of staked positions
      const stakedPositions = await wrappedLoan.getStakedPositions();
      const sJoePositionExists = stakedPositions.some(
        (position) => fromBytes32(position.identifier) === "sJOE"
      );
      expect(sJoePositionExists).to.be.true;

      // Total value should remain approximately the same (within 1% tolerance)
      const finalTotalValue = fromWei(await wrappedLoan.getTotalValue());
      expect(finalTotalValue).to.be.closeTo(
        initialTotalValue,
        0.01 * initialTotalValue,
        "Total value should remain approximately the same"
      );

      // Health ratio should not decrease significantly
      const finalHR = fromWei(await wrappedLoan.getHealthRatio());
      console.log(`Health ratio before: ${initialHR}, after: ${finalHR}`);
      expect(finalHR).to.be.gte(
        initialHR * 0.99,
        "Health ratio should not decrease by more than 5%"
      );
    });

    it("should claim rewards from sJOE staking", async () => {
      // Get initial USDC balance
      const usdcContract = new ethers.Contract(USDC_ADDRESS, erc20ABI, owner);
      const initialUsdcBalance = await usdcContract.balanceOf(
        wrappedLoan.address
      );

      // Check initial pending rewards
      const initialRewards = await wrappedLoan.rewardsInSJoe();
      console.log(`Initial pending rewards: ${fromWei(initialRewards)}`);

      // Fast forward some blocks to accrue rewards (may need more time in real tests)
      for (let i = 0; i < 10; i++) {
        await ethers.provider.send("evm_mine", []);
      }

      // Claim rewards
      await wrappedLoan.claimSJoeRewards();

      // Check final USDC balance
      const finalUsdcBalance = await usdcContract.balanceOf(
        wrappedLoan.address
      );
      console.log(`USDC balance after claiming: ${fromWei(finalUsdcBalance)}`);

      // Note: In a test environment, it's possible that no rewards are generated
      if (initialRewards.gt(0)) {
        expect(finalUsdcBalance).to.be.gte(
          initialUsdcBalance,
          "USDC balance should greater than or equal to initial balance"
        );
      }
    });

    it("should unstake JOE tokens", async () => {
      // Get initial balances
      const joeContract = new ethers.Contract(
        JOE_TOKEN_ADDRESS,
        erc20ABI,
        owner
      );
      const initialJoeBalance = await joeContract.balanceOf(
        wrappedLoan.address
      );
      const sJoeBalance = await wrappedLoan.joeBalanceInSJoe();

      // Unstake half of the sJOE balance
      const unstakeAmount = sJoeBalance.div(2);
      await wrappedLoan.unstakeJoe(unstakeAmount);

      // Check final JOE balance
      const finalJoeBalance = await joeContract.balanceOf(wrappedLoan.address);

      expect(finalJoeBalance).to.equal(
        initialJoeBalance.add(unstakeAmount),
        "final JOE balance should be equal to the sum of unstakeAmound and initial balance"
      );

      // Check remaining staked balance
      const finalSJoeBalance = await wrappedLoan.joeBalanceInSJoe();
      expect(finalSJoeBalance).to.be.lt(
        sJoeBalance,
        "Staked JOE balance should decrease after unstaking"
      );
      expect(finalSJoeBalance).to.be.closeTo(
        sJoeBalance.sub(unstakeAmount),
        1,
        "Staked JOE balance should decrease by approximately the unstaked amount"
      );
    });

    it("should prevent non-owner from staking JOE", async () => {
      // Try to stake JOE from non-owner account
      const joeContract = new ethers.Contract(
        JOE_TOKEN_ADDRESS,
        erc20ABI,
        owner
      );
      const joeBalance = await joeContract.balanceOf(wrappedLoan.address);

      await expect(nonOwnerWrappedLoan.stakeJoe(joeBalance)).to.be.reverted;
    });

    it("should maintain solvency throughout staking operations", async () => {
      // Check loan is solvent after all operations
      const isSolvent = await wrappedLoan.isSolvent();
      expect(isSolvent).to.be.true;
    });

    async function loanOwnsAsset(asset: string) {
      let ownedAssets = await wrappedLoan.getAllOwnedAssets();
      for (const ownedAsset of ownedAssets) {
        if (fromBytes32(ownedAsset) == asset) {
          return true;
        }
      }
      return false;
    }
  });
});