const { ethers } = require('ethers');
const { WrapperBuilder } = require("@redstone-finance/evm-connector");
const fs = require('fs').promises;
const path = require('path');

// Configuration
const CONFIG = {
  // RPC endpoints
  ARBITRUM_RPC: process.env.RPC_ARBITRUM_URL || 'https://arb1.arbitrum.io/rpc',
  AVALANCHE_RPC: process.env.RPC_AVALANCHE_URL || 'https://api.avax.network/ext/bc/C/rpc',
  
  // Factory addresses
  ARBITRUM_FACTORY: '0xFf5e3dDaefF411a1dC6CcE00014e4Bca39265c20',
  AVALANCHE_FACTORY: '0x3Ea9D480295A73fd2aF95b4D96c2afF88b21B03D',
  
  // Token addresses
  ARBITRUM_TOKENS: {
    'GM_ETH_WETH_USDC': '0x70d95587d40A2caf56bd97485aB3Eec10Bee6336',
    'GM_ARB_ARB_USDC': '0xC25cEf6061Cf5dE5eb761b50E4743c1F5D7E5407',
    'GM_LINK_LINK_USDC': '0x7f1fa204bb700853D36994DA19F830b6Ad18455C',
    'GM_UNI_UNI_USDC': '0xc7Abb2C5f3BF3CEB389dF0Eecd6120D451170B50',
    'GM_BTC_WBTC_USDC': '0x47c031236e19d024b42f8AE6780E44A573170703',
    'GM_NEAR_WETH_USDC': '0x63Dc80EE90F26363B3FCD609007CC9e14c8991BE',
    'GM_ATOM_WETH_USDC': '0x248C35760068cE009a13076D573ed3497A47bCD4',
    'GM_GMX_GMX_USDC': '0x55391D178Ce46e7AC8eaAEa50A72D1A5a8A622Da',
    'GM_SUI_WETH_USDC': '0x6Ecf2133E2C9751cAAdCb6958b9654baE198a797',
    'GM_SEI_WETH_USDC': '0xB489711B1cB86afDA48924730084e23310EB4883',
    'GM_ETH_WETH': '0x450bb6774Dd8a756274E0ab4107953259d2ac541',
    'GM_BTC_WBTC': '0x7C11F78Ce78768518D743E81Fdfa2F860C6b9A77',
    'GM_GMX_GMX': '0xbD48149673724f9cAeE647bb4e9D9dDaF896Efeb'
  },
  
  AVALANCHE_TOKENS: {
    'GM_BTC_BTCb_USDC': '0xFb02132333A79C8B5Bd0b64E3AbccA5f7fAf2937',
    'GM_ETH_WETHe_USDC': '0xB7e69749E3d2EDd90ea59A4932EFEa2D41E245d7',
    'GM_AVAX_WAVAX_USDC': '0x913C1F46b48b3eD35E7dc3Cf754d4ae8499F31CF',
    'GM_BTC_BTCb': '0x3ce7BCDB37Bf587d1C17B930Fa0A7000A0648D12',
    'GM_ETH_WETHe': '0x2A3Cf4ad7db715DF994393e4482D6f1e58a1b533',
    'GM_AVAX_WAVAX': '0x08b25A2a89036d298D6dB8A74ace9d1ce6Db15E5'
  },

  // RedStone data-service configuration.
  //
  // Both Arbitrum and Avalanche DeltaPrime have been migrated on-chain to the
  // shared RedStone primary node (`PrimaryProdDataServiceConsumerBase`), so all
  // off-chain callers must request packages signed by the primary-prod signer
  // set with `dataServiceId = redstone-primary-prod`. evm-connector 0.9.0 also
  // requires the caller to pass `authorizedSigners` and an explicit
  // `dataPackagesIds` list (the old auto-detect/`returnAllPackages` behaviour is
  // gone — see the comment on `wrapContractArbitrum`).
  //
  // These values mirror the production liquidation bots / solvency monitors in
  // aws-serverless (the same migration, already live):
  //   arbitrum/liquidatePAArbitrum/config.json
  //   avalanche/liquidatePAAvalanche/config.json
  REDSTONE: {
    DATA_SERVICE_ID: 'redstone-primary-prod',
    UNIQUE_SIGNERS_COUNT: 3,
    // PRIMARY_PROD signer set — hardcoded in PrimaryProdDataServiceConsumerBase.
    AUTHORIZED_SIGNERS: [
      '0x8BB8F32Df04c8b654987DAaeD53D6B6091e3B774',
      '0xdEB22f54738d54976C4c0fe5ce6d408E40d88499',
      '0x51Ce04Be4b3E32572C4Ec9135221d0691Ba7d202',
      '0xDD682daEC5A90dD295d14DA4b0bec9281017b5bE',
      '0x9c5AE89C4Af6aA32cE58588DBaF90d18a855B6de',
    ],
    // Explicit feed lists. These determine which prices get attached to the tx
    // payload; the on-chain solvency check (via the `remainsSolvent` modifier on
    // sweepFeesAndUpdateBenchMark) prices every supported owned asset, so the
    // list must cover them. It MUST contain only feeds primary-prod actually
    // publishes — the strict 0.9.0 SDK rejects the WHOLE request if any listed
    // feed is missing.
    ARBITRUM_DATA_PACKAGES_IDS: [
      'ETH', 'USDC', 'ARB', 'USDT', 'GMX', 'BTC', 'DAI', 'LINK', 'weETH',
      'GM_GMX_GMX', 'wstETH', 'UNI', 'GM_SUI_WETH_USDC', 'GM_SEI_WETH_USDC',
      'GM_ETH_WETH', 'GM_ETH_WETH_USDC', 'JOE', 'MOO_GMX',
      'GM_NEAR_WETH_USDC', 'GM_ATOM_WETH_USDC', 'GM_GMX_GMX_USDC',
      'GM_BTC_WBTC_USDC', 'GM_BTC_WBTC', 'GM_ARB_ARB_USDC',
      'GM_LINK_LINK_USDC', 'GM_UNI_UNI_USDC',
    ],
    AVALANCHE_DATA_PACKAGES_IDS: [
      'AVAX', 'USDC', 'BTC', 'ETH', 'USDT', 'sAVAX', 'GM_AVAX_WAVAX_USDC',
      'WOMBAT_ggAVAX_AVAX_LP_AVAX', 'WOMBAT_sAVAX_AVAX_LP_sAVAX',
      'GM_BTC_BTCb_USDC', 'WOMBAT_sAVAX_AVAX_LP_AVAX', 'EUROC',
      'GM_ETH_WETHe_USDC', 'JOE', 'GMX', 'ggAVAX',
      'WOMBAT_ggAVAX_AVAX_LP_ggAVAX', 'GM_ETH_WETHe', 'GM_BTC_BTCb',
      'GM_AVAX_WAVAX',
    ],
  },

  // Progress tracking file
  PROGRESS_FILE: './sweep-progress.json',
};

// ABIs
const ERC20_ABI = [
  "function balanceOf(address owner) view returns (uint256)"
];

const FACTORY_ABI = [
  "function getAllLoans() external view returns (address[])"
];

const PRIME_ACCOUNT_ABI = [
  "function sweepFeesAndUpdateBenchMark(address gmToken) external",
  "function owner() external view returns (address)"
];

class FeeSweeper {
  // Retry helper with exponential backoff
  async withRetry(fn, { maxRetries = 5, baseDelay = 3000, label = 'operation' } = {}) {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        return await fn();
      } catch (error) {
        if (attempt === maxRetries) throw error;
        const delay = baseDelay * Math.pow(2, attempt - 1) + Math.random() * 1000;
        console.log(`    Retry ${attempt}/${maxRetries} for ${label} after error: ${error.message?.slice(0, 120)}`);
        console.log(`    Waiting ${(delay / 1000).toFixed(1)}s before retry...`);
        await new Promise(resolve => setTimeout(resolve, delay));
      }
    }
  }

  constructor() {
    // Check for private key
    if (!process.env.LIQUIDATOR_PRIVATE_KEY) {
      throw new Error('LIQUIDATOR_PRIVATE_KEY environment variable is required');
    }

    // Initialize providers
    this.arbitrumProvider = new ethers.providers.JsonRpcProvider(CONFIG.ARBITRUM_RPC);
    this.avalancheProvider = new ethers.providers.JsonRpcProvider(CONFIG.AVALANCHE_RPC);

    // Initialize wallets
    this.arbitrumWallet = new ethers.Wallet(process.env.LIQUIDATOR_PRIVATE_KEY, this.arbitrumProvider);
    this.avalancheWallet = new ethers.Wallet(process.env.LIQUIDATOR_PRIVATE_KEY, this.avalancheProvider);

    this.progress = {
      processed: [],
      noBalance: [],
      insolvent: [],
      lastRun: null
    };
  }

  // RedStone wrapper functions.
  //
  // evm-connector 0.9.0 changed the `usingDataService` API: it takes a SINGLE
  // config object (the old second `urls` positional arg is gone), and
  // `requestDataPackages` now requires `authorizedSigners` plus an explicit
  // `dataPackagesIds` (or `returnAllPackages`). Calling it the old 0.2.5 way
  // throws `Cannot read properties of undefined (reading 'length')` from inside
  // the SDK while building the payload — before any tx is sent. We pass the
  // primary-prod signer set + the per-chain feed list (see CONFIG.REDSTONE).
  wrapContractArbitrum(contract) {
    return WrapperBuilder.wrap(contract).usingDataService({
      dataServiceId: CONFIG.REDSTONE.DATA_SERVICE_ID,
      uniqueSignersCount: CONFIG.REDSTONE.UNIQUE_SIGNERS_COUNT,
      authorizedSigners: CONFIG.REDSTONE.AUTHORIZED_SIGNERS,
      dataPackagesIds: CONFIG.REDSTONE.ARBITRUM_DATA_PACKAGES_IDS,
      disablePayloadsDryRun: true
    });
  }

  wrapContractAvalanche(contract) {
    return WrapperBuilder.wrap(contract).usingDataService({
      dataServiceId: CONFIG.REDSTONE.DATA_SERVICE_ID,
      uniqueSignersCount: CONFIG.REDSTONE.UNIQUE_SIGNERS_COUNT,
      authorizedSigners: CONFIG.REDSTONE.AUTHORIZED_SIGNERS,
      dataPackagesIds: CONFIG.REDSTONE.AVALANCHE_DATA_PACKAGES_IDS,
      disablePayloadsDryRun: true
    });
  }

  // Load progress from file
  async loadProgress() {
    try {
      const data = await fs.readFile(CONFIG.PROGRESS_FILE, 'utf-8');
      this.progress = JSON.parse(data);
      console.log(`Loaded progress: ${this.progress.processed.length} processed, ${this.progress.noBalance.length} with no balance, ${this.progress.insolvent.length} insolvent positions`);
    } catch (error) {
      console.log('No existing progress file found, starting fresh');
      this.progress = {
        processed: [],
        noBalance: [],
        insolvent: [],
        lastRun: null
      };
    }
  }

  // Save progress to file
  async saveProgress() {
    try {
      this.progress.lastRun = new Date().toISOString();
      await fs.writeFile(CONFIG.PROGRESS_FILE, JSON.stringify(this.progress, null, 2));
    } catch (error) {
      console.error('Error saving progress:', error.message);
    }
  }

  // Check if account/token combination was already processed
  isProcessed(chain, account, gmToken) {
    const key = `${chain}-${account}-${gmToken}`;
    return this.progress.processed.includes(key);
  }

  // Check if account/token combination is insolvent
  isInsolvent(chain, account, gmToken) {
    const key = `${chain}-${account}-${gmToken}`;
    return this.progress.insolvent.includes(key);
  }

  // Check if account/token combination has no balance
  hasNoBalance(chain, account, gmToken) {
    const key = `${chain}-${account}-${gmToken}`;
    return this.progress.noBalance.includes(key);
  }

  // Mark account/token as having no balance
  async markNoBalance(chain, account, gmToken) {
    const key = `${chain}-${account}-${gmToken}`;
    if (!this.progress.noBalance.includes(key)) {
      this.progress.noBalance.push(key);
      await this.saveProgress();
    }
  }

  // Mark account/token as insolvent
  async markInsolvent(chain, account, gmToken) {
    const key = `${chain}-${account}-${gmToken}`;
    if (!this.progress.insolvent.includes(key)) {
      this.progress.insolvent.push(key);
      console.log(`  Marked as insolvent: ${key}`);
      await this.saveProgress();
    }
  }

  // Mark as processed
  async markProcessed(chain, account, gmToken, txHash) {
    const key = `${chain}-${account}-${gmToken}`;
    if (!this.progress.processed.includes(key)) {
      this.progress.processed.push(key);
      console.log(`  Marked as processed: ${key}`);
      console.log(`  TX: ${txHash}`);
      await this.saveProgress();
    }
  }

  // Get all prime accounts from factory
  async getPrimeAccounts(factoryAddress, provider, chainName) {
    console.log(`\nFetching prime accounts from ${chainName} factory...`);
    
    try {
      const factory = new ethers.Contract(factoryAddress, FACTORY_ABI, provider);
      const primeAccounts = await this.withRetry(
        () => factory.getAllLoans(),
        { maxRetries: 5, baseDelay: 5000, label: `${chainName} getAllLoans` }
      );
      console.log(`Found ${primeAccounts.length} prime accounts on ${chainName}`);
      return primeAccounts;
    } catch (error) {
      console.error(`Error fetching prime accounts from ${chainName}:`, error.message);
      return [];
    }
  }

  // Check if account has balance for a specific token
  async checkBalance(account, tokenAddress, provider) {
    try {
      const tokenContract = new ethers.Contract(tokenAddress, ERC20_ABI, provider);
      const balance = await tokenContract.balanceOf(account);
      return balance.gt(0);
    } catch (error) {
      // Silent fail for balance check
      return false;
    }
  }

  // Check balance for multiple tokens in parallel
  async checkBalancesParallel(account, tokensToCheck, provider) {
    const balancePromises = tokensToCheck.map(async ({ tokenKey, tokenAddress }) => {
      try {
        const hasBalance = await this.checkBalance(account, tokenAddress, provider);
        return { tokenKey, tokenAddress, hasBalance };
      } catch (error) {
        return { tokenKey, tokenAddress, hasBalance: false, error: error.message };
      }
    });

    return await Promise.all(balancePromises);
  }

  // Sweep fees for a specific account/token
  async sweepFees(chain, account, gmTokenAddress, gmTokenKey, wallet, wrapFunction) {
    console.log(`\n  Processing: ${account}`);
    console.log(`    Token: ${gmTokenKey} (${gmTokenAddress})`);

    // Create contract instance
    const primeContract = new ethers.Contract(account, PRIME_ACCOUNT_ABI, wallet);
    const wrappedContract = wrapFunction(primeContract);

    // Send transaction ONCE — do NOT retry submission to avoid duplicates
    console.log(`    Sending transaction...`);
    const tx = await wrappedContract.sweepFeesAndUpdateBenchMark(gmTokenAddress);

    console.log(`    TX submitted: ${tx.hash}`);
    console.log(`    Waiting for confirmation...`);

    // Wait for receipt with retries (TX already sent, safe to retry wait)
    let receipt;
    try {
      receipt = await this.withRetry(
        () => tx.wait(1),
        { maxRetries: 10, baseDelay: 10000, label: 'tx receipt' }
      );
    } catch (error) {
      // Receipt fetch failed after all retries, but TX was sent — mark as processed
      // to avoid re-sending on next run
      console.log(`    Could not get receipt after retries, but TX was sent.`);
      console.log(`    Marking as processed to avoid duplicate TX.`);
      await this.markProcessed(chain, account, gmTokenAddress, tx.hash);
      return { success: true, txHash: tx.hash, blockNumber: null };
    }

    if (receipt.status === 1) {
      console.log(`    Success! Block: ${receipt.blockNumber}`);
      await this.markProcessed(chain, account, gmTokenAddress, tx.hash);
      return { success: true, txHash: tx.hash, blockNumber: receipt.blockNumber };
    } else {
      throw new Error('Transaction failed');
    }
  }

  // Process all accounts on a chain
  async processChain(chainName, factory, tokens, wallet, provider, wrapFunction) {
    console.log(`\n${'='.repeat(60)}`);
    console.log(`PROCESSING ${chainName.toUpperCase()}`);
    console.log('='.repeat(60));

    const accounts = await this.getPrimeAccounts(factory, provider, chainName);
    
    if (accounts.length === 0) {
      console.log(`No accounts found on ${chainName}`);
      return;
    }

    let processed = 0;
    let skippedCache = 0;
    let skippedNoBalance = 0;

    for (let i = 0; i < accounts.length; i++) {
      const account = accounts[i];
      console.log(`\n[${i + 1}/${accounts.length}] Account: ${account}`);

      // FIRST: Filter tokens that need balance checking (not in cache)
      const tokensToCheck = [];
      const tokensWithBalance = [];

      for (const [tokenKey, tokenAddress] of Object.entries(tokens)) {
        if (this.isProcessed(chainName, account, tokenAddress)) {
          console.log(`  Skipping ${tokenKey} (already processed)`);
          skippedCache++;
          continue;
        }

        if (this.isInsolvent(chainName, account, tokenAddress)) {
          console.log(`  Skipping ${tokenKey} (insolvent)`);
          skippedCache++;
          continue;
        }

        if (this.hasNoBalance(chainName, account, tokenAddress)) {
          console.log(`  Skipping ${tokenKey} (no balance in cache)`);
          skippedCache++;
          continue;
        }

        // Token needs balance checking
        tokensToCheck.push({ tokenKey, tokenAddress });
      }

      // SECOND: Check balances for all tokens in parallel
      if (tokensToCheck.length > 0) {
        console.log(`  Checking balances for ${tokensToCheck.length} tokens in parallel...`);
        const balanceResults = await this.checkBalancesParallel(account, tokensToCheck, provider);

        // Process balance results
        for (const result of balanceResults) {
          if (result.hasBalance) {
            console.log(`  Found balance for ${result.tokenKey}`);
            tokensWithBalance.push(result);
          } else {
            console.log(`  No balance for ${result.tokenKey}${result.error ? ` (${result.error})` : ''}`);
            await this.markNoBalance(chainName, account, result.tokenAddress);
            skippedNoBalance++;
          }
        }
      }

      // THIRD: Process tokens with balance sequentially for fee sweeping
      for (const { tokenKey, tokenAddress } of tokensWithBalance) {
        try {
          const result = await this.sweepFees(
            chainName,
            account,
            tokenAddress,
            tokenKey,
            wallet,
            wrapFunction
          );

          if (result.success) {
            processed++;
          }
        } catch (error) {
          // Check if error is due to insolvency
          if (error.message && error.message.includes('The action may cause an account to become insolvent')) {
            console.log(`    ⚠️  Insolvency error for ${tokenKey}, marking and continuing...`);
            await this.markInsolvent(chainName, account, tokenAddress);
            // Continue processing other tokens
          } else {
            console.error(`    Error processing ${tokenKey}: ${error.message?.slice(0, 200)}`);
            console.log(`    Continuing to next token...`);
          }
        }

        // Small delay between transactions
        await new Promise(resolve => setTimeout(resolve, 2000));
      }
    }

    console.log(`\n${chainName} Summary:`);
    console.log(`  Processed: ${processed}`);
    console.log(`  Skipped (cache): ${skippedCache}`);
    console.log(`  Skipped (no balance): ${skippedNoBalance}`);
  }

  async run() {
    console.log('Fee Sweeper Starting...\n');
    console.log(`Liquidator Address: ${this.arbitrumWallet.address}\n`);

    // Load previous progress
    await this.loadProgress();

    // Process Arbitrum
    await this.processChain(
      'Arbitrum',
      CONFIG.ARBITRUM_FACTORY,
      CONFIG.ARBITRUM_TOKENS,
      this.arbitrumWallet,
      this.arbitrumProvider,
      this.wrapContractArbitrum.bind(this)
    );

    // Process Avalanche
    await this.processChain(
      'Avalanche',
      CONFIG.AVALANCHE_FACTORY,
      CONFIG.AVALANCHE_TOKENS,
      this.avalancheWallet,
      this.avalancheProvider,
      this.wrapContractAvalanche.bind(this)
    );

    console.log('\n' + '='.repeat(60));
    console.log('SWEEP COMPLETE');
    console.log('='.repeat(60));
    console.log(`Total processed: ${this.progress.processed.length}`);
  }
}

async function main() {
  const sweeper = new FeeSweeper();
  await sweeper.run();
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = { FeeSweeper, CONFIG };