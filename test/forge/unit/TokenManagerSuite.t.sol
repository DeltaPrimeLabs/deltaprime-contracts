// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {TokenManager} from "../../../contracts/TokenManager.sol";
import {MockTokenManager} from "../../../contracts/mock/MockTokenManager.sol";
import {OpenBorrowersRegistry} from "../../../contracts/mock/OpenBorrowersRegistry.sol";
import {LeverageTierLib} from "../../../contracts/lib/LeverageTierLib.sol";
import {TestERC20} from "../helpers/TestERC20.sol";

/**
 * @title  TokenManagerSuiteTest  (SP3 suite 3.5)
 * @notice Self-contained suite for TokenManager — asset lifecycle, removeTokenAssets
 *         regression pin, pool assets, tier caps, exposure groups, vPrimeController.
 *
 *         Fixture: MockTokenManager (overrides getSmartLoansFactoryAddress() so the
 *         onlyPrimeAccountOrOwner modifier resolves without an on-chain factory) +
 *         2 TestERC20 tokens + 1 ZeroBorrowPool.
 *
 *         Does NOT touch DeltaPrimeFixture.
 */

// ─── inline pool stubs ────────────────────────────────────────────────────────

/// @dev Minimal contract that passes Address.isContract() and returns
///      totalBorrowed()==0 so TokenManager._removePoolAsset() can complete.
contract ZeroBorrowPool {
    function totalBorrowed() external pure returns (uint256) { return 0; }
}

/// @dev Pool stub that simulates outstanding borrows; removePoolAssets must revert.
contract NonZeroBorrowPool {
    function totalBorrowed() external pure returns (uint256) { return 1 ether; }
}

// ─── main test contract ───────────────────────────────────────────────────────

contract TokenManagerSuiteTest is Test {

    // ── custom errors mirrored from TokenManager (for expectRevert selector) ──
    error MaxDebtCoverageExceeded();
    error InvalidDebtCoverageTier();

    // ── cap constants — mirror TokenManager.sol:453 (flat) and :476/:482 (tiered) ──
    uint256 constant BASIC_CAP   = 0.833333333333333333e18;
    uint256 constant PREMIUM_CAP = 0.909090909090909090e18;

    // ── fixture ───────────────────────────────────────────────────────────────
    MockTokenManager     internal tm;
    OpenBorrowersRegistry internal registry;
    TestERC20            internal tokenA;
    TestERC20            internal tokenB;
    ZeroBorrowPool       internal poolA;

    bytes32 constant SYM_A      = bytes32("TOKA");
    bytes32 constant SYM_B      = bytes32("TOKB");
    bytes32 constant SYM_POOL_A = bytes32("POOL_A");

    address internal alice; // non-owner

    function setUp() public {
        vm.warp(1_750_000_000);

        alice = makeAddr("alice");

        tokenA  = new TestERC20("Token A", "TOKA", 18);
        tokenB  = new TestERC20("Token B", "TOKB", 6);
        poolA   = new ZeroBorrowPool();
        registry = new OpenBorrowersRegistry();

        tm = new MockTokenManager();
        // Wire mock factory so onlyPrimeAccountOrOwner modifier resolves cleanly.
        tm.setFactoryAddress(address(registry));

        TokenManager.Asset[] memory assets = new TokenManager.Asset[](2);
        assets[0] = TokenManager.Asset({
            asset:        SYM_A,
            assetAddress: address(tokenA),
            debtCoverage: 0.5e18
        });
        assets[1] = TokenManager.Asset({
            asset:        SYM_B,
            assetAddress: address(tokenB),
            debtCoverage: 0.6e18
        });

        // addPoolAssets requires Address.isContract() — ZeroBorrowPool passes.
        TokenManager.poolAsset[] memory pools = new TokenManager.poolAsset[](1);
        pools[0] = TokenManager.poolAsset({
            asset:       SYM_POOL_A,
            poolAddress: address(poolA)
        });

        tm.initialize(assets, pools);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  1. ASSET LIFECYCLE — initialize, add, duplicate, status
    // ════════════════════════════════════════════════════════════════════════

    /// @notice initialize() registers both assets with status _ACTIVE (==2).
    function test_initialize_registersAssetsActive() public {
        assertEq(tm.getAssetAddress(SYM_A, false), address(tokenA));
        assertEq(tm.getAssetAddress(SYM_B, false), address(tokenB));
        assertEq(tm.tokenToStatus(address(tokenA)), 2, "tokenA not ACTIVE");
        assertEq(tm.tokenToStatus(address(tokenB)), 2, "tokenB not ACTIVE");
    }

    /// @notice addTokenAssets() post-init is onlyOwner — non-owner reverts.
    function test_addTokenAssets_postInit_onlyOwner() public {
        TestERC20 tokenC = new TestERC20("Token C", "TOKC", 18);
        TokenManager.Asset[] memory extra = new TokenManager.Asset[](1);
        extra[0] = TokenManager.Asset({
            asset:        bytes32("TOKC"),
            assetAddress: address(tokenC),
            debtCoverage: 0.3e18
        });

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.addTokenAssets(extra);
    }

    /// @notice Re-adding the same symbol (bytes32 key) reverts: "Asset's token already exists"
    function test_addTokenAssets_duplicateSymbol_reverts() public {
        TestERC20 tokenC = new TestERC20("Token C2", "TOKC2", 18);
        TokenManager.Asset[] memory dup = new TokenManager.Asset[](1);
        dup[0] = TokenManager.Asset({
            asset:        SYM_A,                // same symbol as tokenA
            assetAddress: address(tokenC),
            debtCoverage: 0.3e18
        });

        vm.expectRevert("Asset's token already exists");
        tm.addTokenAssets(dup);
    }

    /// @notice Re-adding the same token address (different symbol) reverts:
    ///         "Asset address is already in use"
    function test_addTokenAssets_duplicateAddress_reverts() public {
        TokenManager.Asset[] memory dup = new TokenManager.Asset[](1);
        dup[0] = TokenManager.Asset({
            asset:        bytes32("TOKX"),
            assetAddress: address(tokenA),      // tokenA address already registered under SYM_A
            debtCoverage: 0.3e18
        });

        vm.expectRevert("Asset address is already in use");
        tm.addTokenAssets(dup);
    }

    /// @notice getAssetAddress with allowInactive=false returns address for ACTIVE asset.
    function test_getAssetAddress_active_allowInactiveFalse() public {
        address addr = tm.getAssetAddress(SYM_A, false);
        assertEq(addr, address(tokenA));
    }

    /// @notice getAssetAddress with allowInactive=false reverts "Asset inactive" for INACTIVE.
    function test_getAssetAddress_inactive_allowInactiveFalse_reverts() public {
        tm.deactivateToken(address(tokenA));

        vm.expectRevert("Asset inactive");
        tm.getAssetAddress(SYM_A, false);
    }

    /// @notice getAssetAddress with allowInactive=true returns address even when INACTIVE.
    function test_getAssetAddress_inactive_allowInactiveTrue_succeeds() public {
        tm.deactivateToken(address(tokenA));
        assertEq(tm.getAssetAddress(SYM_A, true), address(tokenA));
    }

    /// @notice getAssetAddress for an unknown bytes32 reverts with "Asset not supported."
    ///         Exact string verified against TokenManager.sol:169 (note trailing period).
    function test_getAssetAddress_unknown_reverts() public {
        vm.expectRevert("Asset not supported.");
        tm.getAssetAddress(bytes32("UNKNOWN"), false);
    }

    /// @notice deactivateToken and activateToken drive correct _INACTIVE/_ACTIVE transitions.
    function test_deactivateActivate_transitions() public {
        // ACTIVE (2) → INACTIVE (1)
        tm.deactivateToken(address(tokenA));
        assertEq(tm.tokenToStatus(address(tokenA)), 1, "should be INACTIVE");

        // INACTIVE (1) → ACTIVE (2)
        tm.activateToken(address(tokenA));
        assertEq(tm.tokenToStatus(address(tokenA)), 2, "should be ACTIVE again");
    }

    /// @notice deactivateToken on an already-INACTIVE token reverts: "Must be active"
    function test_deactivateToken_alreadyInactive_reverts() public {
        tm.deactivateToken(address(tokenA));
        vm.expectRevert("Must be active");
        tm.deactivateToken(address(tokenA));
    }

    /// @notice activateToken on an already-ACTIVE token reverts: "Must be inactive"
    function test_activateToken_alreadyActive_reverts() public {
        vm.expectRevert("Must be inactive");
        tm.activateToken(address(tokenA)); // tokenA is still ACTIVE from setUp
    }

    // ════════════════════════════════════════════════════════════════════════
    //  2. removeTokenAssets REGRESSION — PR #109/#110 (commit 8bb1bbce)
    // ════════════════════════════════════════════════════════════════════════

    /**
     * @notice REGRESSION PIN — tieredDebtCoverage zeroed for both tiers on removal.
     *
     *   Bug: before commit 8bb1bbce (PR #109/#110), _removeTokenAsset() cleared
     *   debtCoverage[token] and debtCoverageStaked[symbol] but did NOT clear
     *   tieredDebtCoverage[BASIC][token] or tieredDebtCoverage[PREMIUM][token].
     *   Stale values remained, granting phantom leverage headroom if the token
     *   was re-added or the mapping was read externally.
     *
     *   Fix: TokenManager.sol:420-423 explicitly zeros both tiers (BASIC + PREMIUM)
     *   and both staked-tier mappings on every removal.  This test exercises
     *   exactly those four lines.
     */
    function test_removeTokenAssets_regression_tieredCoverageCleared() public {
        // Pre-condition: set tiered coverage for both tiers
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC,   address(tokenA), 0.5e18);
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA), 0.7e18);

        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC,   address(tokenA)), 0.5e18);
        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA)), 0.7e18);
        // flat debtCoverage was set to 0.5e18 during initialize
        assertEq(tm.debtCoverage(address(tokenA)), 0.5e18);

        // Action: remove the asset
        bytes32[] memory toRemove = new bytes32[](1);
        toRemove[0] = SYM_A;
        tm.removeTokenAssets(toRemove);

        // REGRESSION PIN — TokenManager.sol:420-421: both tiers must be zero
        assertEq(
            tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, address(tokenA)),
            0,
            "REGRESSION: BASIC tieredDebtCoverage not cleared (TokenManager.sol:420)"
        );
        assertEq(
            tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA)),
            0,
            "REGRESSION: PREMIUM tieredDebtCoverage not cleared (TokenManager.sol:421)"
        );

        // Supporting: flat debtCoverage and status also cleared (lines 413-414)
        assertEq(tm.debtCoverage(address(tokenA)), 0, "flat debtCoverage not cleared");
        assertEq(tm.tokenToStatus(address(tokenA)), 0, "tokenToStatus not reset to NOT_SUPPORTED");
    }

    /// @notice After removal, re-adding the same token starts from clean tiered state.
    function test_removeTokenAssets_readdAfterRemoval_startsClean() public {
        // Setup: set tiered coverage then remove
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC,   address(tokenA), 0.5e18);
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA), 0.7e18);

        bytes32[] memory toRemove = new bytes32[](1);
        toRemove[0] = SYM_A;
        tm.removeTokenAssets(toRemove);

        // Re-add with different flat coverage
        TokenManager.Asset[] memory readd = new TokenManager.Asset[](1);
        readd[0] = TokenManager.Asset({
            asset:        SYM_A,
            assetAddress: address(tokenA),
            debtCoverage: 0.3e18
        });
        tm.addTokenAssets(readd);

        // Asset is ACTIVE again with new flat coverage
        assertEq(tm.getAssetAddress(SYM_A, false), address(tokenA));
        assertEq(tm.debtCoverage(address(tokenA)),  0.3e18, "wrong flat debtCoverage after re-add");
        assertEq(tm.tokenToStatus(address(tokenA)), 2,      "should be ACTIVE after re-add");

        // Tiered coverage starts at zero (was cleared on removal, never re-set)
        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC,   address(tokenA)), 0);
        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA)), 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  3. POOL ASSETS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice addPoolAssets is onlyOwner — non-owner reverts.
    function test_addPoolAssets_onlyOwner() public {
        ZeroBorrowPool pool2 = new ZeroBorrowPool();
        TokenManager.poolAsset[] memory pools = new TokenManager.poolAsset[](1);
        pools[0] = TokenManager.poolAsset({
            asset:       bytes32("POOL_B"),
            poolAddress: address(pool2)
        });

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.addPoolAssets(pools);
    }

    /// @notice getPoolAddress for unregistered symbol reverts: "Pool asset not supported."
    ///         Exact string from TokenManager.sol:183.
    function test_getPoolAddress_unregistered_reverts() public {
        vm.expectRevert("Pool asset not supported.");
        tm.getPoolAddress(bytes32("UNKNOWN_POOL"));
    }

    /// @notice removePoolAssets succeeds when totalBorrowed()==0.
    function test_removePoolAssets_zeroBorrows_succeeds() public {
        bytes32[] memory pools = new bytes32[](1);
        pools[0] = SYM_POOL_A;
        tm.removePoolAssets(pools);

        vm.expectRevert("Pool asset not supported.");
        tm.getPoolAddress(SYM_POOL_A);
    }

    /// @notice removePoolAssets reverts when pool has outstanding borrows.
    function test_removePoolAssets_nonZeroBorrows_reverts() public {
        NonZeroBorrowPool nonZeroPool = new NonZeroBorrowPool();
        TokenManager.poolAsset[] memory pools = new TokenManager.poolAsset[](1);
        pools[0] = TokenManager.poolAsset({
            asset:       bytes32("POOL_NZ"),
            poolAddress: address(nonZeroPool)
        });
        tm.addPoolAssets(pools);

        bytes32[] memory toRemove = new bytes32[](1);
        toRemove[0] = bytes32("POOL_NZ");
        vm.expectRevert("Pool must have no outstanding borrows");
        tm.removePoolAssets(toRemove);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  4. TIER CONFIG — setTieredDebtCoverage caps
    // ════════════════════════════════════════════════════════════════════════

    /// @notice BASIC tier accepts value at exact cap (0.833333333333333333e18).
    ///         Cap from TokenManager.sol:476 comment "LTV must be lower than 5".
    function test_tieredDebtCoverage_basic_atCap_succeeds() public {
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, address(tokenA), BASIC_CAP);
        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, address(tokenA)), BASIC_CAP);
    }

    /// @notice BASIC tier reverts MaxDebtCoverageExceeded when 1 wei over cap.
    function test_tieredDebtCoverage_basic_overCap_reverts() public {
        vm.expectRevert(MaxDebtCoverageExceeded.selector);
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, address(tokenA), BASIC_CAP + 1);
    }

    /// @notice PREMIUM tier accepts value at exact cap (0.909090909090909090e18).
    ///         Cap from TokenManager.sol:482 comment "LTV must be lower than 10".
    function test_tieredDebtCoverage_premium_atCap_succeeds() public {
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA), PREMIUM_CAP);
        assertEq(tm.tieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA)), PREMIUM_CAP);
    }

    /// @notice PREMIUM tier reverts MaxDebtCoverageExceeded when 1 wei over cap.
    function test_tieredDebtCoverage_premium_overCap_reverts() public {
        vm.expectRevert(MaxDebtCoverageExceeded.selector);
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.PREMIUM, address(tokenA), PREMIUM_CAP + 1);
    }

    /// @notice _NON_EXISTENT tier reverts InvalidDebtCoverageTier.
    ///         Check: tier >= _NON_EXISTENT (==2) triggers before BASIC/PREMIUM branches.
    function test_tieredDebtCoverage_nonExistentTier_reverts() public {
        vm.expectRevert(InvalidDebtCoverageTier.selector);
        tm.setTieredDebtCoverage(
            LeverageTierLib.LeverageTier._NON_EXISTENT,
            address(tokenA),
            0.5e18
        );
    }

    /// @notice setTieredDebtCoverage is onlyOwner.
    function test_tieredDebtCoverage_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setTieredDebtCoverage(LeverageTierLib.LeverageTier.BASIC, address(tokenA), 0.5e18);
    }

    /// @notice setTieredDebtCoverageStaked is onlyOwner.
    function test_tieredDebtCoverageStaked_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setTieredDebtCoverageStaked(LeverageTierLib.LeverageTier.BASIC, SYM_A, 0.5e18);
    }

    /// @notice setTieredPrimeStakingRatio is onlyOwner.
    function test_setTieredPrimeStakingRatio_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setTieredPrimeStakingRatio(LeverageTierLib.LeverageTier.BASIC, 1e18);
    }

    /// @notice setTieredPrimeDebtRatio is onlyOwner.
    function test_setTieredPrimeDebtRatio_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setTieredPrimeDebtRatio(LeverageTierLib.LeverageTier.PREMIUM, 2e18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //  5. EXPOSURE GROUPS
    // ════════════════════════════════════════════════════════════════════════

    /// @notice setIdentifiersToExposureGroups stores the mapping correctly.
    function test_exposureGroups_setAndGet() public {
        bytes32[] memory ids    = new bytes32[](2);
        bytes32[] memory groups = new bytes32[](2);
        ids[0]    = SYM_A;
        ids[1]    = SYM_B;
        groups[0] = bytes32("BTC_GROUP");
        groups[1] = bytes32("ETH_GROUP");

        tm.setIdentifiersToExposureGroups(ids, groups);

        assertEq(tm.identifierToExposureGroup(SYM_A), bytes32("BTC_GROUP"));
        assertEq(tm.identifierToExposureGroup(SYM_B), bytes32("ETH_GROUP"));
    }

    /// @notice setIdentifiersToExposureGroups is onlyOwner.
    function test_exposureGroups_onlyOwner() public {
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = SYM_A;
        groups[0] = bytes32("GRP");

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setIdentifiersToExposureGroups(ids, groups);
    }

    /// @notice setMaxProtocolsExposure sets groupToExposure.max correctly.
    function test_setMaxProtocolsExposure_stateEffect() public {
        bytes32[] memory ids  = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        ids[0]  = bytes32("BTC_GROUP");
        maxs[0] = 1_000e18;

        tm.setMaxProtocolsExposure(ids, maxs);

        (, uint256 maxExposure) = tm.groupToExposure(bytes32("BTC_GROUP"));
        assertEq(maxExposure, 1_000e18);
    }

    /// @notice setMaxProtocolsExposure is onlyOwner.
    function test_setMaxProtocolsExposure_onlyOwner() public {
        bytes32[] memory ids  = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        ids[0]  = bytes32("GRP");
        maxs[0] = 100e18;

        vm.prank(alice);
        vm.expectRevert("Ownable: caller is not the owner");
        tm.setMaxProtocolsExposure(ids, maxs);
    }

    /// @notice increaseProtocolExposure from owner is a no-op when identifier has
    ///         no mapped exposure group (identifierToExposureGroup returns bytes32(0)).
    ///         The function silently returns early — no revert, no state change.
    ///         (increaseProtocolExposure/decreaseProtocolExposure mutator paths
    ///          exercised end-to-end in suite 4.4 via PrimeAccount; here we pin
    ///          the no-group no-op behaviour and confirm owner can call.)
    function test_increaseProtocolExposure_unmappedIdentifier_noOp() public {
        // SYM_A has no exposure group mapping; call must not revert
        bytes32 unmapped = bytes32("UNMAPPED_SYM");
        tm.increaseProtocolExposure(unmapped, 1e18); // owner calling, onlyPrimeAccountOrOwner OK
        // groupToExposure for any group remains unchanged
        (uint256 current,) = tm.groupToExposure(bytes32(""));
        assertEq(current, 0);
    }

}
