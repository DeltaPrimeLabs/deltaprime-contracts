import * as hre from "hardhat";
const ethers = hre.ethers;
import chai, { expect } from "chai";
import { solidity } from "ethereum-waffle";
import { parseUnits } from "ethers/lib/utils";
import { deployContract } from "ethereum-waffle";
import { constructSimpleSDK, SimpleFetchSDK, SwapSide } from "@paraswap/sdk";
import axios from "axios";

import SmartLoansFactoryArtifact from "../../../artifacts/contracts/SmartLoansFactory.sol/SmartLoansFactory.json";
import MockTokenManagerArtifact from "../../../artifacts/contracts/mock/MockTokenManager.sol/MockTokenManager.json";
import AddressProviderArtifact from "../../../artifacts/contracts/AddressProvider.sol/AddressProvider.json";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { WrapperBuilder } from "@redstone-finance/evm-connector";
import CACHE_LAYER_URLS from "../../../common/redstone-cache-layer-urls.json";
import TOKEN_ADDRESSES from "../../../common/addresses/avax/token_addresses.json";
import {
  addMissingTokenContracts,
  Asset,
  convertAssetsListToSupportedAssets,
  deployAndInitExchangeContract,
  deployAllFacets,
  deployPools,
  fromWei,
  getFixedGasSigners,
  getRedstonePrices,
  getTokensPricesMap,
  PoolAsset,
  PoolInitializationObject,
  recompileConstantsFile,
  toBytes32,
  toWei,
  parseParaSwapRouteData,
  fromBytes32,
  whitelistParaSwapExecutors,
} from "../../_helpers";
import { syncTime } from "../../_syncTime";
import {
  AddressProvider,
  TraderJoeIntermediary,
  PangolinIntermediary,
  MockTokenManager,
  SmartLoanGigaChadInterface,
  SmartLoansFactory,
} from "../../../typechain";
import { deployDiamond } from "../../../tools/diamond/deploy-diamond";
import { Contract, BigNumber } from "ethers";
import IERC20Artifact from "../../../artifacts/@openzeppelin/contracts/token/ERC20/IERC20.sol/IERC20.json";

chai.use(solidity);

const traderJoeRouterAddress = "0x60aE616a2155Ee3d9A68541Ba4544862310933d4";

describe("Smart loan", () => {
  before("Synchronize blockchain time", async () => {
    await syncTime();
  });

  describe("Swap debt", () => {
    let smartLoansFactory: SmartLoansFactory,
      exchange: TraderJoeIntermediary,
      loan: SmartLoanGigaChadInterface,
      wrappedLoan: any,
      owner: SignerWithAddress,
      borrower: SignerWithAddress,
      depositor: SignerWithAddress,
      paraSwapMin: SimpleFetchSDK,
      poolContracts: Map<string, Contract> = new Map(),
      tokenContracts: Map<string, Contract> = new Map(),
      lendingPools: Array<PoolAsset> = [],
      supportedAssets: Array<Asset>,
      tokensPrices: Map<string, number>;

    const getSwapData = async (
      srcToken: keyof typeof TOKEN_ADDRESSES,
      destToken: keyof typeof TOKEN_ADDRESSES,
      srcAmount: any
    ) => {
      const priceRoute = await paraSwapMin.swap.getRate({
        srcToken: TOKEN_ADDRESSES[srcToken],
        destToken: TOKEN_ADDRESSES[destToken],
        amount: srcAmount.toString(),
        userAddress: wrappedLoan.address,
        side: SwapSide.SELL,
        // @ts-ignore - ParaSwap API accepts this property even if it's not in the type definition
        includeContractMethods: [
          "swapExactAmountIn",
          "swapExactAmountInOnUniswapV3",
        ],
        version: 6.2,
      });
      const txParams = await paraSwapMin.swap.buildTx(
        {
          srcToken: priceRoute.srcToken,
          destToken: priceRoute.destToken,
          srcAmount: priceRoute.srcAmount,
          slippage: 300,
          priceRoute,
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

    const logLoanDetails = async (
      wrappedLoan: any,
      tokenContracts: Map<string, Contract>,
      tokensPrices: Map<string, number>,
      supportedAssets: Array<Asset>,
      label: string = ""
    ) => {
      console.log(`\n=== LOAN DETAILS ${label ? "- " + label : ""} ===`);
      
      // Log asset balances
      console.log("\nASSET BALANCES:");
      let totalAssetValueUSD = 0;
      
      for (const asset of supportedAssets) {
        const symbol = fromBytes32(asset.asset);
        const tokenContract = tokenContracts.get(symbol);
        const balance = await tokenContract!.balanceOf(wrappedLoan.address);
        const decimals = await tokenContract!.decimals();
        const balanceFormatted = parseFloat(ethers.utils.formatUnits(balance, decimals));
        const valueUSD = balanceFormatted * tokensPrices.get(symbol)!;
        totalAssetValueUSD += valueUSD;
        
        console.log(
          `${symbol}: ${balanceFormatted.toFixed(6)} tokens ($${valueUSD.toFixed(2)})`
        );
      }
      
      // Log debt balances
      console.log("\nDEBT BALANCES:");
      let totalDebtValueUSD = 0;
      
      for (const asset of supportedAssets) {
        const symbol = fromBytes32(asset.asset);
        const poolContract = poolContracts.get(symbol);
        const tokenContract = tokenContracts.get(symbol);
        const decimals = await tokenContract!.decimals();
        const debt = await poolContract?.getBorrowed(wrappedLoan.address);
        if (debt && debt.gt(0)) {
          const debtFormatted = parseFloat(ethers.utils.formatUnits(debt, decimals));
          const valueUSD = debtFormatted * tokensPrices.get(symbol)!;
          totalDebtValueUSD += valueUSD;
          
          console.log(
            `${symbol}: ${debtFormatted.toFixed(6)} tokens ($${valueUSD.toFixed(2)})`
          );
        }
      }
      
      const totalDebt = await wrappedLoan.getDebt();
      console.log(`\nTotal debt: $${fromWei(totalDebt).toFixed(2)}`);
      console.log(`Total assets: $${totalAssetValueUSD.toFixed(2)}`);
      console.log(`Net worth: $${(totalAssetValueUSD - fromWei(totalDebt)).toFixed(2)}`);
      console.log("====================\n");
    };

    before(
      "deploy factory, wrapped native token pool and USD pool",
      async () => {
        [owner, depositor, borrower] = await getFixedGasSigners(10000000);

        let assetsList = ["AVAX", "USDC"];
        let poolNameAirdropList: Array<PoolInitializationObject> = [
          { name: "AVAX", airdropList: [borrower, depositor, owner] },
          { name: "USDC", airdropList: [] },
        ];

        smartLoansFactory = (await deployContract(
          owner,
          SmartLoansFactoryArtifact
        )) as SmartLoansFactory;

          let tokenManager = (await deployContract(
              owner,
              MockTokenManagerArtifact,
              []
          )) as MockTokenManager;

        await deployPools(
          smartLoansFactory,
          poolNameAirdropList,
          tokenContracts,
          poolContracts,
          lendingPools,
          owner,
          depositor,
            1000, 'AVAX', [], tokenManager.address
        );

        tokensPrices = await getTokensPricesMap(
          assetsList,
          "avalanche",
          getRedstonePrices,
          []
        );
        supportedAssets = convertAssetsListToSupportedAssets(assetsList);
        addMissingTokenContracts(tokenContracts, assetsList);

        // Pass true as the second parameter to deployDiamond to use MockDiamondCutFacet
        let diamondAddress = await deployDiamond(undefined, true);

        await tokenManager
          .connect(owner)
          .initialize(supportedAssets, lendingPools);
        await tokenManager
          .connect(owner)
          .setFactoryAddress(smartLoansFactory.address);
        // ParaSwap executors are TokenManager-whitelisted (no longer hardcoded in ParaSwapHelper)
        await whitelistParaSwapExecutors(tokenManager, owner);

        let addressProvider = (await deployContract(
          owner,
          AddressProviderArtifact,
          []
        )) as AddressProvider;

        await recompileConstantsFile(
          "local",
          "DeploymentConstants",
          [],
          tokenManager.address,
          addressProvider.address,
          diamondAddress,
          smartLoansFactory.address,
          "lib"
        );

        exchange = (await deployAndInitExchangeContract(
          owner,
          traderJoeRouterAddress,
          tokenManager.address,
          supportedAssets,
          "TraderJoeIntermediary"
        )) as TraderJoeIntermediary;

        await smartLoansFactory.initialize(
          diamondAddress,
          tokenManager.address
        );

        await recompileConstantsFile(
          "local",
          "DeploymentConstants",
          [
            {
              facetPath: "./contracts/facets/avalanche/TraderJoeDEXFacet.sol",
              contractAddress: exchange.address,
            },
          ],
          tokenManager.address,
          addressProvider.address,
          diamondAddress,
          smartLoansFactory.address,
          "lib"
        );

        await deployAllFacets(diamondAddress, false);

        paraSwapMin = constructSimpleSDK({ chainId: 43114, axios });
      }
    );

    it("should check Pool ERC20Details methods", async () => {
      expect(await poolContracts.get("USDC")!.name()).to.be.eq(
        "DeltaPrimeUSDCoin"
      );
      expect(await poolContracts.get("USDC")!.symbol()).to.be.eq("DPUSDC");
      expect(await poolContracts.get("USDC")!.decimals()).to.be.eq(6);
    });

    it("should deploy a smart loan", async () => {
      await smartLoansFactory.connect(borrower).createLoan();

      const loan_proxy_address = await smartLoansFactory.getLoanForOwner(
        borrower.address
      );
      loan = await ethers.getContractAt(
        "SmartLoanGigaChadInterface",
        loan_proxy_address,
        borrower
      );

      // @ts-ignore
      wrappedLoan = WrapperBuilder.wrap(loan).usingDataService({
        dataServiceId: "redstone-avalanche-prod",
        uniqueSignersCount: 3,
        dataFeeds: ["AVAX", "ETH", "USDC", "BTC"],
        // @ts-ignore
        disablePayloadsDryRun: true,
      });
    });

    it("should fund and borrow", async () => {
      await tokenContracts
        .get("AVAX")!
        .connect(borrower)
        .deposit({ value: toWei("100") });
      await tokenContracts
        .get("AVAX")!
        .connect(borrower)
        .approve(wrappedLoan.address, toWei("100"));
      await wrappedLoan.fund(toBytes32("AVAX"), toWei("100"));

      const usdcDeposited = parseUnits("600", BigNumber.from("6"));
      const amountSwapped = toWei("50");
      await tokenContracts
        .get("AVAX")!
        .connect(depositor)
        .deposit({ value: amountSwapped });
      await tokenContracts
        .get("AVAX")!
        .connect(depositor)
        .approve(exchange.address, amountSwapped);
      await tokenContracts
        .get("AVAX")!
        .connect(depositor)
        .transfer(exchange.address, amountSwapped);

      await exchange
        .connect(depositor)
        .swap(
          TOKEN_ADDRESSES["AVAX"],
          TOKEN_ADDRESSES["USDC"],
          amountSwapped,
          usdcDeposited
        );
      const usdcPool = poolContracts.get("USDC");
      await tokenContracts
        .get("USDC")!
        .connect(depositor)
        .approve(usdcPool?.address, usdcDeposited);
      await usdcPool!.connect(depositor).deposit(usdcDeposited);

      const borrowAmount = parseUnits("400", BigNumber.from("6"));
      await wrappedLoan.borrow(toBytes32("USDC"), borrowAmount);

      expect(await usdcPool?.getBorrowed(wrappedLoan.address)).to.be.eq(
        borrowAmount
      );
      expect(
        await poolContracts.get("AVAX")?.getBorrowed(wrappedLoan.address)
      ).to.be.eq(0);
      expect(fromWei(await wrappedLoan.getDebt())).to.be.closeTo(400, 0.2);
      
      // Log loan details after setup
      await logLoanDetails(wrappedLoan, tokenContracts, tokensPrices, supportedAssets, "AFTER LOAN SETUP");
    });

    it("should fail to swap debt as a non-owner", async () => {
      let nonOwnerWrappedLoan = WrapperBuilder
        // @ts-ignore
        .wrap(loan.connect(depositor))
        .usingDataService({
          dataServiceId: "redstone-avalanche-prod",
          uniqueSignersCount: 3,
          dataFeeds: ["AVAX", "ETH", "USDC", "BTC"],
          // @ts-ignore
          disablePayloadsDryRun: true,
        });
      
      // Instead of getting real swap data which might fail due to API issues,
      // just use a dummy selector and data that will reach the ownership check
      const dummySelector = "0xe3ead59e"; // SWAP_EXACT_AMOUNT_IN_SELECTOR
      const dummyData = "0x"; // Empty data
      
      await expect(
        nonOwnerWrappedLoan.swapDebtParaSwap(
          toBytes32("USDC"),
          toBytes32("AVAX"),
          parseUnits("400", BigNumber.from("6")),
          toWei("1"),
          dummySelector,
          dummyData
        )
      ).to.be.revertedWith("DiamondStorageLib: Must be contract owner");
    });

    it("should fail to swap debt when dollar value difference is too high", async () => {
      let AVAX_PRICE = tokensPrices.get("AVAX")!;
      
      // Calculate amount to repay (the entire USDC debt)
      const usdcDebt = await poolContracts.get("USDC")?.getBorrowed(wrappedLoan.address);
      const repayAmount = usdcDebt;
      
      // Set borrow amount much higher than needed (>5% difference)
      // This should trigger the "Dollar value diff too high" error
      const usdDebtValue = fromWei(await wrappedLoan.getDebt());
      const borrowAmount = toWei((usdDebtValue / AVAX_PRICE * 1.06).toString()); // 6% higher
      
      const swapData = await getSwapData("AVAX", "USDC", borrowAmount);
      
      await expect(
        wrappedLoan.swapDebtParaSwap(
          toBytes32("USDC"),
          toBytes32("AVAX"),
          repayAmount,
          borrowAmount,
          swapData.selector,
          swapData.data
        )
      ).to.be.revertedWith("Dollar value diff too high");
    });

    it("should swap debt", async () => {
      let AVAX_PRICE = tokensPrices.get("AVAX")!;
      
      // Calculate amount to repay (the entire USDC debt plus a small buffer for interest accrual)
      const usdcDebt = await poolContracts.get("USDC")?.getBorrowed(wrappedLoan.address);
      // Add a 1% buffer to account for any interest accrual during the process
      const repayAmount = usdcDebt?.mul(101).div(100); // 1% more than the current debt
      
      // Calculate equivalent amount of AVAX to borrow based on current price
      // Add 1% buffer to account for slippage and interest accrual
      const usdDebtValue = fromWei(await wrappedLoan.getDebt());
      const borrowAmount = toWei((usdDebtValue / AVAX_PRICE * 1.01).toString());
      
      const swapData = await getSwapData("AVAX", "USDC", borrowAmount);
      
      // Log loan details before debt swap
      await logLoanDetails(wrappedLoan, tokenContracts, tokensPrices, supportedAssets, "BEFORE DEBT SWAP");
      
      await wrappedLoan.swapDebtParaSwap(
        toBytes32("USDC"),
        toBytes32("AVAX"),
        repayAmount,
        borrowAmount,
        swapData.selector,
        swapData.data
      );

      // Log loan details after debt swap
      await logLoanDetails(wrappedLoan, tokenContracts, tokensPrices, supportedAssets, "AFTER DEBT SWAP");

      // Verify USDC debt is fully repaid with no dust
      expect(
        await poolContracts.get("USDC")?.getBorrowed(wrappedLoan.address)
      ).to.be.eq(0);
      
      // Verify AVAX debt is created with approximately same USD value
      // Allow a small margin due to slippage and fees
      const avaxDebt = await poolContracts.get("AVAX")?.getBorrowed(wrappedLoan.address);
      const avaxDebtValue = fromWei(avaxDebt) * AVAX_PRICE;
      
      expect(avaxDebtValue).to.be.closeTo(usdDebtValue, usdDebtValue * 0.05); // Allow 5% margin
      
      // Verify total debt dollar value remains approximately the same
      const newTotalDebt = fromWei(await wrappedLoan.getDebt());
      expect(newTotalDebt).to.be.closeTo(usdDebtValue, usdDebtValue * 0.05); // Allow 5% margin
    });
  });
});