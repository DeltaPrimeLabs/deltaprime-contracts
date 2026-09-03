// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";
import {TestERC20} from "../helpers/TestERC20.sol";
import {Pool} from "../../../contracts/Pool.sol";
import {LinearIndex} from "../../../contracts/LinearIndex.sol";
import {MockVariableUtilisationRatesCalculator} from "../../../contracts/mock/MockVariableUtilisationRatesCalculator.sol";
import {TokenManager} from "../../../contracts/TokenManager.sol";
import {SmartLoansFactory} from "../../../contracts/SmartLoansFactory.sol";
import {LeverageTierLib} from "../../../contracts/lib/LeverageTierLib.sol";
import {ITokenManager} from "../../../contracts/interfaces/ITokenManager.sol";
import {IRatesCalculator} from "../../../contracts/interfaces/IRatesCalculator.sol";
import {IBorrowersRegistry} from "../../../contracts/interfaces/IBorrowersRegistry.sol";
import {IIndex} from "../../../contracts/interfaces/IIndex.sol";
import {IPoolRewarder} from "../../../contracts/interfaces/IPoolRewarder.sol";
// Diamond beacon + cut
import {SmartLoanDiamondBeacon} from "../../../contracts/SmartLoanDiamondBeacon.sol";
import {MockDiamondCutFacet} from "../../../contracts/facets/mock/MockDiamondCutFacet.sol";
import {DiamondInit} from "../../../contracts/facets/DiamondInit.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
// Facets
import {DiamondLoupeFacet} from "../../../contracts/facets/DiamondLoupeFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";
import {WithdrawalIntentFacet} from "../../../contracts/facets/WithdrawalIntentFacet.sol";
import {SolvencyFacetTestAvalanche} from "../helpers/facets/SolvencyFacetTestAvalanche.sol";
import {SolvencyFacetProd} from "../../../contracts/facets/SolvencyFacetProd.sol";
import {ParaSwapFacet} from "../../../contracts/facets/ParaSwapFacet.sol";
import {SwapDebtFacet} from "../../../contracts/facets/SwapDebtFacet.sol";

// WAVAX mock — pragma ^0.8.4, no constructor
// solhint-disable-next-line no-global-import
interface IWAVAX {
    function deposit() external payable;
    function withdraw(uint256) external;
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

abstract contract DeltaPrimeFixture is Test {
    uint256 internal constant DEBT_COVERAGE = 0.833333333333333333e18;
    // Native asset symbol follows the ACTIVE chain config ("AVAX" on test/avalanche,
    // "ETH" on arbitrum) so the fixture works on every CI matrix leg.
    bytes32 internal constant NATIVE_SYMBOL = DeploymentChainConfig.NATIVE_TOKEN_SYMBOL;

    IWAVAX internal wavax;
    TestERC20 internal usdc;
    TestERC20 internal prime;
    Pool internal wavaxPool;
    Pool internal usdcPool;
    TokenManager internal tokenManager;
    SmartLoansFactory internal factory;
    SmartLoanDiamondBeacon internal beacon;
    address internal liquidator;

    function setUp() public virtual {
        vm.warp(1_750_000_000);

        // --- WAVAX at the fixed test address (no constructor args) ---
        // ADAPTATION: using fully-qualified artifact path per plan ADAPTATION NOTES.
        deployCodeTo("contracts/mock/WAVAX.sol:WAVAX", DeploymentChainConfig.NATIVE_ADDRESS);
        wavax = IWAVAX(DeploymentChainConfig.NATIVE_ADDRESS);

        usdc = new TestERC20("USD Coin", "USDC", 6);
        prime = new TestERC20("Prime", "PRIME", 18);

        // --- protocol singletons at the addresses the facets compile against ---
        // ADAPTATION: using fully-qualified artifact paths for clarity.
        deployCodeTo("contracts/TokenManager.sol:TokenManager", DeploymentChainConfig.TOKEN_MANAGER);
        tokenManager = TokenManager(DeploymentChainConfig.TOKEN_MANAGER);

        deployCodeTo("contracts/SmartLoansFactory.sol:SmartLoansFactory", DeploymentChainConfig.SMART_LOANS_FACTORY);
        factory = SmartLoansFactory(DeploymentChainConfig.SMART_LOANS_FACTORY);

        // --- pools (regular deploys; their addresses are not compile-time constants) ---
        wavaxPool = _deployPool(payable(DeploymentChainConfig.NATIVE_ADDRESS));
        usdcPool  = _deployPool(payable(address(usdc)));

        // --- TokenManager wiring ---
        // ADAPTATION: TokenManager.initialize takes TokenManager.Asset[] / TokenManager.poolAsset[],
        // NOT ITokenManager.Asset[] — using TokenManager's own struct namespace since these are
        // declared in the concrete contract, not the interface (ITokenManager.Asset and
        // TokenManager.Asset are distinct Solidity types even though ABI-identical).
        // PRIME registration is mandatory: LeverageTierLib.sol:69 reads it to compute leverage tier.
        TokenManager.Asset[] memory assets = new TokenManager.Asset[](3);
        assets[0] = TokenManager.Asset(NATIVE_SYMBOL,  DeploymentChainConfig.NATIVE_ADDRESS, DEBT_COVERAGE);
        assets[1] = TokenManager.Asset(bytes32("USDC"),  address(usdc),   DEBT_COVERAGE);
        assets[2] = TokenManager.Asset(bytes32("PRIME"), address(prime),   0);

        TokenManager.poolAsset[] memory poolAssets = new TokenManager.poolAsset[](2);
        poolAssets[0] = TokenManager.poolAsset(NATIVE_SYMBOL, address(wavaxPool));
        poolAssets[1] = TokenManager.poolAsset(bytes32("USDC"), address(usdcPool));

        tokenManager.initialize(assets, poolAssets);

        // Tiered debt coverage: without this the weighted collateral value is zero → nothing borrows.
        address[3] memory tiered = [DeploymentChainConfig.NATIVE_ADDRESS, address(usdc), address(prime)];
        for (uint256 i; i < tiered.length; i++) {
            tokenManager.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC,   tiered[i], DEBT_COVERAGE);
            tokenManager.setTieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, tiered[i], DEBT_COVERAGE);
        }

        wavaxPool.setTokenManager(ITokenManager(address(tokenManager)));
        usdcPool.setTokenManager(ITokenManager(address(tokenManager)));

        // -------------------------------------------------------------------
        // Diamond beacon at the fixed compile-time constant address.
        // Owner = this fixture; mock cut facet bypasses the hardcoded
        // Arbitrum address check in the prod DiamondCutFacet.
        // -------------------------------------------------------------------
        MockDiamondCutFacet cutFacet = new MockDiamondCutFacet();
        deployCodeTo(
            "contracts/SmartLoanDiamondBeacon.sol:SmartLoanDiamondBeacon",
            abi.encode(address(this), address(cutFacet)),
            DeploymentChainConfig.DIAMOND_BEACON
        );
        beacon = SmartLoanDiamondBeacon(payable(DeploymentChainConfig.DIAMOND_BEACON));

        // --- One diamondCut WHILE PAUSED (beacon starts paused); DiamondInit.init carries ---
        // --- ERC-165 support flags and re-sets _active = false (still paused after cut).   ---
        DiamondInit dInit = new DiamondInit();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](8);
        cuts[0] = IDiamondCut.FacetCut(
            address(new DiamondLoupeFacet()),
            IDiamondCut.FacetCutAction.Add,
            _loupeSelectors()
        );
        cuts[1] = IDiamondCut.FacetCut(
            address(new SmartLoanViewFacet()),
            IDiamondCut.FacetCutAction.Add,
            _viewSelectors()
        );
        cuts[2] = IDiamondCut.FacetCut(
            address(new AssetsOperationsFacet()),
            IDiamondCut.FacetCutAction.Add,
            _assetsOpsSelectors()
        );
        cuts[3] = IDiamondCut.FacetCut(
            address(new SmartLoanLiquidationFacet()),
            IDiamondCut.FacetCutAction.Add,
            _liquidationSelectors()
        );
        cuts[4] = IDiamondCut.FacetCut(
            _etchSolvencyFacet(),
            IDiamondCut.FacetCutAction.Add,
            _solvencySelectors()
        );
        // WithdrawalIntentFacet: getAvailableBalance is delegate-called from
        // AssetsOperationsFacet.borrow / repay via _getAvailableBalance() in
        // DiamondMethodsAccess. Without this cut, borrow() always reverts with
        // "Diamond: Function does not exist" when it tries to check intent-locked
        // balance. In tests with no intents, getAvailableBalance simply returns
        // the full token balance (getTotalIntentAmount == 0).
        cuts[5] = IDiamondCut.FacetCut(
            address(new WithdrawalIntentFacet()),
            IDiamondCut.FacetCutAction.Add,
            _withdrawalIntentSelectors()
        );
        // ParaSwap + SwapDebt facets: needed by the GM/GLV swap-guard (DPSC-457/469)
        // and swap-debt token-binding (DPSC-460) e2e tests. Both prod facets fit
        // EIP-170 (13.3KB / 14.8KB), so a plain `new` deploy is fine (no etch).
        cuts[6] = IDiamondCut.FacetCut(
            address(new ParaSwapFacet()),
            IDiamondCut.FacetCutAction.Add,
            _paraSwapSelectors()
        );
        cuts[7] = IDiamondCut.FacetCut(
            address(new SwapDebtFacet()),
            IDiamondCut.FacetCutAction.Add,
            _swapDebtSelectors()
        );
        IDiamondCut(address(beacon)).diamondCut(
            cuts,
            address(dInit),
            abi.encodeWithSelector(DiamondInit.init.selector)
        );

        // Unpause: beacon is now fully cut and active.
        IDiamondCut(address(beacon)).unpause();

        // --- factory.initialize AFTER beacon is cut + unpaused ---
        // createLoan() creates a BeaconProxy that calls SmartLoanViewFacet.initialize
        // via the beacon — requires the beacon to be unpaused first.
        factory.initialize(payable(address(beacon)), address(tokenManager));

        // --- Whitelist the test liquidator (called ON the beacon address, as per
        //     the production deploy pattern — the beacon routes through diamond storage).
        liquidator = makeAddr("liquidator");
        address[] memory liqs = new address[](1);
        liqs[0] = liquidator;
        SmartLoanLiquidationFacet(DeploymentChainConfig.DIAMOND_BEACON).whitelistLiquidators(liqs);
    }

    // ---------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------

    function _deployPool(address payable token) internal returns (Pool pool) {
        pool = new Pool();
        LinearIndex di = new LinearIndex();
        LinearIndex bi = new LinearIndex();
        // ADAPTATION: LinearIndex.initialize owner = pool (not the fixture), because
        // pool.initialize calls _updateRates() which calls depositIndex.setRate()/borrowIndex.setRate()
        // (onlyOwner on LinearIndex). Pool must own its indices.
        di.initialize(address(pool));
        bi.initialize(address(pool));
        pool.initialize(
            IRatesCalculator(address(new MockVariableUtilisationRatesCalculator())),
            IBorrowersRegistry(DeploymentChainConfig.SMART_LOANS_FACTORY),
            IIndex(address(di)),
            IIndex(address(bi)),
            token,
            IPoolRewarder(address(0)),
            0  // totalSupplyCap = 0 (uncapped)
        );
        // pool.initialize uses __Ownable_init() → caller (this fixture) becomes pool owner,
        // so setTokenManager (onlyOwner) can be called from setUp().
    }

    /// @dev Deploy SolvencyFacetTestAvalanche via vm.etch — the bytecode exceeds EIP-170
    ///      (>24KB), so `new SolvencyFacetTestAvalanche()` would revert in a sandboxed EVM.
    ///      vm.etch bypasses the limit; the facet is stateless (no constructor, no immutables),
    ///      so runtimeCode etch is safe.
    function _etchSolvencyFacet() internal returns (address target) {
        target = makeAddr("solvencyFacetTestAvalanche");
        vm.etch(target, type(SolvencyFacetTestAvalanche).runtimeCode);
    }

    /// @dev Whitelist `gmMarket` as a GMX market token in the TokenManager (fixture is TM owner).
    function _whitelistGmxMarket(address gmMarket) internal {
        tokenManager.setGmxMarket(gmMarket, true, false);
    }

    /// @dev Whitelist `glvToken` as a GLV token in the TokenManager (fixture is TM owner).
    function _whitelistGlvToken(address glvToken) internal {
        tokenManager.setGlvTokenWhitelisting(glvToken, true);
    }

    /// @dev Create a loan for a named address; returns (borrower, loan).
    function _createLoanFor(string memory name) internal returns (address borrower, address loan) {
        borrower = makeAddr(name);
        vm.prank(borrower);
        factory.createLoan();
        loan = factory.getLoanForOwner(borrower);
    }

    /// @dev Fund a loan with `amount` of native AVAX (wrapped to wAVAX before funding).
    ///      No oracle payload needed — fund() has no solvency check.
    function _fundAvax(address borrower, address loan, uint256 amount) internal {
        vm.deal(borrower, amount);
        vm.startPrank(borrower);
        wavax.deposit{value: amount}();
        wavax.approve(loan, amount);
        AssetsOperationsFacet(loan).fund(NATIVE_SYMBOL, amount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------
    // Selector helpers — use .selector references only, never string hashing.
    // Only specific selectors from each facet that the e2e paths reach.
    // ---------------------------------------------------------------------------

    function _loupeSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = DiamondLoupeFacet.facets.selector;
        s[1] = DiamondLoupeFacet.facetFunctionSelectors.selector;
        s[2] = DiamondLoupeFacet.facetAddresses.selector;
        s[3] = DiamondLoupeFacet.facetAddress.selector;
        s[4] = DiamondLoupeFacet.supportsInterface.selector;
    }

    function _viewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = SmartLoanViewFacet.initialize.selector;
        s[1] = SmartLoanViewFacet.getAllOwnedAssets.selector;
        s[2] = SmartLoanViewFacet.getBalance.selector;
        s[3] = SmartLoanViewFacet.getContractOwner.selector;
        s[4] = SmartLoanViewFacet.getAllAssetsBalances.selector;
        s[5] = SmartLoanViewFacet.getDebts.selector;
        s[6] = SmartLoanViewFacet.getPercentagePrecision.selector;
    }

    function _assetsOpsSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = AssetsOperationsFacet.fund.selector;
        s[1] = AssetsOperationsFacet.borrow.selector;
        s[2] = AssetsOperationsFacet.repay.selector;
    }

    function _liquidationSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](9);
        s[0] = SmartLoanLiquidationFacet.liquidate.selector;
        s[1] = SmartLoanLiquidationFacet.snapshotInsolvency.selector;
        s[2] = SmartLoanLiquidationFacet.whitelistLiquidators.selector;
        s[3] = SmartLoanLiquidationFacet.delistLiquidators.selector;
        s[4] = SmartLoanLiquidationFacet.isLiquidatorWhitelisted.selector;
        s[5] = SmartLoanLiquidationFacet.getLastInsolventTimestamp.selector;
        // SP2-liq-expansion: snapshot-recovery + tier-fee + snapshot-HR views needed by
        // the full Liquidation.t.sol matrix (clearInsolvencySnapshot lifecycle,
        // getLiquidationFeePercent tier branch, getHealthRatioSnapshot assertion).
        s[6] = SmartLoanLiquidationFacet.clearInsolvencySnapshot.selector;
        s[7] = SmartLoanLiquidationFacet.getHealthRatioSnapshot.selector;
        s[8] = SmartLoanLiquidationFacet.getLiquidationFeePercent.selector;
    }

    function _withdrawalIntentSelectors() private pure returns (bytes4[] memory s) {
        // SP4.1 add-on: createWithdrawalIntent + executeWithdrawalIntent are needed by
        // HealthAndRepay.t.sol (withdrawal-intent-under-debt test). These are the two
        // lifecycle selectors; the helper selectors (getAvailableBalance, getTotalIntentAmount)
        // are called internally within the same facet delegation and do not need separate cuts.
        // getAvailableBalancePayable is kept for _getAvailableBalancePayable calls.
        s = new bytes4[](6);
        s[0] = WithdrawalIntentFacet.getAvailableBalance.selector;
        s[1] = WithdrawalIntentFacet.getAvailableBalancePayable.selector;
        s[2] = WithdrawalIntentFacet.createWithdrawalIntent.selector;
        s[3] = WithdrawalIntentFacet.executeWithdrawalIntent.selector;
        // cancelWithdrawalIntent + getTotalIntentAmount: needed by the liquidator-cancel
        // regression test (WithdrawalIntentLiquidatorCancel.t.sol).
        s[4] = WithdrawalIntentFacet.cancelWithdrawalIntent.selector;
        s[5] = WithdrawalIntentFacet.getTotalIntentAmount.selector;
    }

    function _paraSwapSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = ParaSwapFacet.paraSwapV6.selector;
        s[1] = ParaSwapFacet.paraSwapBeforeLiquidation.selector;
    }

    function _swapDebtSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = SwapDebtFacet.swapDebtParaSwap.selector;
    }

    function _solvencySelectors() private pure returns (bytes4[] memory s) {
        // SP2 minimal set — the selectors the e2e liquidation/borrow paths reach.
        // Note: SolvencyFacetTestAvalanche inherits these from SolvencyFacetProd via
        // a multi-inheritance chain; Solidity 0.8.17's type-level member lookup for
        // inherited (non-redeclared) functions is brittle in complex hierarchies.
        // Using SolvencyFacetProd directly for selector resolution — the selectors
        // are identical since SolvencyFacetTestAvalanche only overrides the signer set.
        // If a future test reverts with "Diamond: Function does not exist" on a
        // solvency selector, add it here from SolvencyFacetProd's public API.
        s = new bytes4[](10);
        s[0] = SolvencyFacetProd.isSolvent.selector;
        s[1] = SolvencyFacetProd.getDebt.selector;
        s[2] = SolvencyFacetProd.getTotalValue.selector;
        s[3] = SolvencyFacetProd.getHealthRatio.selector;
        s[4] = SolvencyFacetProd.getPrices.selector;
        s[5] = SolvencyFacetProd.getDebtAssets.selector;
        s[6] = SolvencyFacetProd.getDebtAssetsPrices.selector;
        s[7] = SolvencyFacetProd.getAllPricesForLiquidation.selector;
        s[8] = SolvencyFacetProd.canRepayDebtFully.selector;
        s[9] = SolvencyFacetProd.getFullLoanStatus.selector;
    }

    // ---------------------------------------------------------------------------
    // Oracle payload helpers — used by Borrow.t.sol and Liquidation.t.sol.
    // ---------------------------------------------------------------------------

    /// @dev The three feeds that all solvency paths in the fixture tests read.
    function _feeds() internal pure returns (bytes32[] memory f) {
        f = new bytes32[](3);
        f[0] = NATIVE_SYMBOL;
        f[1] = bytes32("USDC");
        f[2] = bytes32("PRIME");
    }

    /// @dev Canonical prices: AVAX $30, USDC $1, PRIME $0.20 (8-decimal oracle format).
    function _prices() internal pure returns (uint256[] memory p) {
        p = new uint256[](3);
        p[0] = 30e8;  // AVAX $30
        p[1] = 1e8;   // USDC $1
        p[2] = 2e7;   // PRIME $0.20
    }

    /// @dev Like _prices() but with a custom AVAX price for crash scenarios.
    function _pricesWithAvax(uint256 avaxPrice8) internal pure returns (uint256[] memory p) {
        p = _prices();
        p[0] = avaxPrice8;
    }

    // ---------------------------------------------------------------------------
    // Revert-reason helpers
    // ---------------------------------------------------------------------------

    /// @dev Decode an ABI-encoded Error(string) revert and search for needle.
    ///      Returns false if the selector is not 0x08c379a0 (not a string revert).
    function _revertContains(bytes memory ret, string memory needle) internal pure returns (bool) {
        if (ret.length < 4 || bytes4(ret) != bytes4(0x08c379a0)) return false;
        bytes memory data = new bytes(ret.length - 4);
        for (uint256 i; i < data.length; i++) data[i] = ret[i + 4];
        string memory reason = abi.decode(data, (string));
        return _contains(bytes(reason), bytes(needle));
    }

    function _contains(bytes memory haystack, bytes memory needle) private pure returns (bool) {
        if (needle.length > haystack.length) return false;
        for (uint256 i; i <= haystack.length - needle.length; i++) {
            bool found = true;
            for (uint256 j; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) { found = false; break; }
            }
            if (found) return true;
        }
        return false;
    }
}
