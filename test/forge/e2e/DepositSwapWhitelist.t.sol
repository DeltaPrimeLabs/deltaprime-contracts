// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";
import {TestERC20} from "../helpers/TestERC20.sol";
import {Pool} from "../../../contracts/Pool.sol";
import {TokenManager} from "../../../contracts/TokenManager.sol";
import {ITokenManager} from "../../../contracts/interfaces/ITokenManager.sol";
import {DepositSwapAvalanche} from "../../../contracts/DepositSwapAvalanche.sol";

/**
 * DepositSwap address (TokenManager-managed) + TokenManager-driven token/pool resolution.
 */

/// @dev Exposes DepositSwapBase's internal resolution hooks. The chain contract is unmodified.
contract DepositSwapHarness is DepositSwapAvalanche {
    function isTokenSupported(address token) external view returns (bool) {
        return _isTokenSupported(token);
    }

    function poolAddressFor(address token) external view returns (address) {
        return _getPoolAddress(token);
    }

    function symbolFor(address token) external view returns (bytes32) {
        return _tokenAddressToSymbol(token);
    }
}

contract DepositSwapWhitelistTest is DeltaPrimeFixture {
    // Mirrors of the TokenManager events (solc 0.8.17 has no `emit Contract.Event(...)`).
    event DepositSwapWhitelisted(
        address indexed performer,
        address indexed depositSwap,
        address indexed previous,
        uint256 timestamp
    );
    event DepositSwapDelisted(address indexed performer, address indexed depositSwap, uint256 timestamp);

    /// @dev The compiled-in DepositSwap for the active chain config — the only address Pool accepts.
    address internal depositSwap = DeploymentChainConfig.DEPOSIT_SWAP;
    address internal otherDepositSwap;
    address internal stranger;
    DepositSwapHarness internal harness;

    function setUp() public override {
        super.setUp();
        otherDepositSwap = makeAddr("otherDepositSwap");
        stranger = makeAddr("stranger");
        // whitelistDepositSwap requires code at the address (LOW-03).
        vm.etch(depositSwap, hex"600160005260206000f3");
        vm.etch(otherDepositSwap, hex"600160005260206000f3");
        harness = new DepositSwapHarness();
    }

    // ------------------------------------------------------------------
    // TokenManager bookkeeping
    // ------------------------------------------------------------------

    function test_depositSwap_unsetByDefault() public {
        assertEq(tokenManager.getDepositSwapAddress(), address(0));
        assertFalse(tokenManager.isDepositSwapWhitelisted(depositSwap));
        assertFalse(tokenManager.isDepositSwapWhitelisted(address(0)));
    }

    function test_whitelist_setsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit DepositSwapWhitelisted(address(this), depositSwap, address(0), block.timestamp);
        tokenManager.whitelistDepositSwap(depositSwap);

        assertEq(tokenManager.getDepositSwapAddress(), depositSwap);
        assertTrue(tokenManager.isDepositSwapWhitelisted(depositSwap));
    }

    function test_whitelist_isIdempotent() public {
        tokenManager.whitelistDepositSwap(depositSwap);

        vm.recordLogs();
        tokenManager.whitelistDepositSwap(depositSwap);
        assertEq(vm.getRecordedLogs().length, 0, "re-whitelisting must be a no-op");
        assertEq(tokenManager.getDepositSwapAddress(), depositSwap);
    }

    /// @dev Single value, not a set: a new DepositSwap retires the previous one.
    function test_whitelist_replacesPrevious() public {
        tokenManager.whitelistDepositSwap(depositSwap);

        vm.expectEmit(true, true, true, true);
        emit DepositSwapWhitelisted(address(this), otherDepositSwap, depositSwap, block.timestamp);
        tokenManager.whitelistDepositSwap(otherDepositSwap);

        assertEq(tokenManager.getDepositSwapAddress(), otherDepositSwap);
        assertFalse(tokenManager.isDepositSwapWhitelisted(depositSwap));
    }

    function test_whitelist_rejectsZeroAddress() public {
        vm.expectRevert("Invalid DepositSwap address");
        tokenManager.whitelistDepositSwap(address(0));
    }

    function test_whitelist_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        tokenManager.whitelistDepositSwap(depositSwap);
    }

    function test_delist_clearsAndEmits() public {
        tokenManager.whitelistDepositSwap(depositSwap);

        vm.expectEmit(true, true, false, true);
        emit DepositSwapDelisted(address(this), depositSwap, block.timestamp);
        tokenManager.delistDepositSwap();

        assertEq(tokenManager.getDepositSwapAddress(), address(0));
        assertFalse(tokenManager.isDepositSwapWhitelisted(depositSwap));
    }

    function test_delist_revertsWhenNoneSet() public {
        vm.expectRevert("No DepositSwap whitelisted");
        tokenManager.delistDepositSwap();
    }

    function test_delist_onlyOwner() public {
        tokenManager.whitelistDepositSwap(depositSwap);
        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        tokenManager.delistDepositSwap();
    }

    function test_whitelist_rejectsNonContract() public {
        address eoa = makeAddr("notAContract");
        assertEq(eoa.code.length, 0, "fixture: expected an EOA");

        vm.expectRevert("DepositSwap must be a contract");
        tokenManager.whitelistDepositSwap(eoa);
    }

    /// @dev The getter masks the slot to 20 bytes, so a dirty upper half cannot leak into the
    ///      address the Pool compares msg.sender against.
    function test_getDepositSwapAddress_masksDirtyUpperBits() public {
        tokenManager.whitelistDepositSwap(depositSwap);

        bytes32 slot = keccak256("deposit.swap.address.storage");
        vm.store(
            address(tokenManager),
            slot,
            bytes32(uint256(uint160(depositSwap)) | (uint256(type(uint96).max) << 160))
        );

        assertEq(tokenManager.getDepositSwapAddress(), depositSwap, "upper bits leaked into the address");
        assertTrue(tokenManager.isDepositSwapWhitelisted(depositSwap));
    }

    // ------------------------------------------------------------------
    // Pool.withdrawInstant gate
    // ------------------------------------------------------------------

    /// @dev Deposit `amount` USDC as `who` so withdrawInstant has a balance to burn.
    function _depositUsdc(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(usdcPool), amount);
        usdcPool.deposit(amount);
        vm.stopPrank();
    }

    function test_withdrawInstant_revertsWhenDepositSwapNotEnabled() public {
        _depositUsdc(depositSwap, 1_000e6);

        vm.prank(depositSwap);
        vm.expectRevert("DepositSwap disabled");
        usdcPool.withdrawInstant(100e6);
    }

    function test_withdrawInstant_revertsWhenPoolHasNoTokenManager() public {
        Pool unwired = _deployPool(payable(address(usdc)));
        _depositUsdcTo(unwired, depositSwap, 1_000e6);

        tokenManager.whitelistDepositSwap(depositSwap);

        vm.prank(depositSwap);
        vm.expectRevert("TokenManager not set");
        unwired.withdrawInstant(100e6);
    }

    function _depositUsdcTo(Pool pool, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
    }

    function test_withdrawInstant_onlyTheCompiledInDepositSwap() public {
        tokenManager.whitelistDepositSwap(depositSwap);
        _depositUsdc(stranger, 1_000e6);

        vm.prank(stranger);
        vm.expectRevert();
        usdcPool.withdrawInstant(100e6);
    }

    /// @dev THE PROPERTY MEDIUM-01 IS ABOUT: the TokenManager owner cannot grant the bypass.
    ///      Whitelisting an address that is not the compiled-in one changes nothing — granting it
    ///      needs a Pool implementation upgrade, i.e. the TUP admin timelock.
    function test_tokenManagerCannotGrantTheBypass() public {
        tokenManager.whitelistDepositSwap(otherDepositSwap);
        _depositUsdc(otherDepositSwap, 1_000e6);

        vm.prank(otherDepositSwap);
        vm.expectRevert();
        usdcPool.withdrawInstant(100e6);

        assertEq(tokenManager.getDepositSwapAddress(), otherDepositSwap, "TM state changed, privilege did not");
    }

    function test_withdrawInstant_succeedsForEnabledCompiledInDepositSwap() public {
        tokenManager.whitelistDepositSwap(depositSwap);
        _depositUsdc(depositSwap, 1_000e6);

        uint256 balanceBefore = usdc.balanceOf(depositSwap);
        vm.prank(depositSwap);
        usdcPool.withdrawInstant(400e6);

        assertEq(usdc.balanceOf(depositSwap) - balanceBefore, 400e6);
        assertEq(usdcPool.balanceOf(depositSwap), 600e6);
    }

    /// @dev Revocation stays instant — no Pool upgrade needed to close the bypass.
    function test_delist_isAnInstantKillSwitch() public {
        tokenManager.whitelistDepositSwap(depositSwap);
        _depositUsdc(depositSwap, 1_000e6);

        vm.prank(depositSwap);
        usdcPool.withdrawInstant(100e6);

        tokenManager.delistDepositSwap();

        vm.prank(depositSwap);
        vm.expectRevert("DepositSwap disabled");
        usdcPool.withdrawInstant(100e6);
    }

    // ------------------------------------------------------------------
    // TokenManager-driven token/pool resolution (replaces the hardcoded tables)
    // ------------------------------------------------------------------

    function test_resolution_registeredPoolAssetsAreSupported() public {
        assertTrue(harness.isTokenSupported(address(usdc)));
        assertEq(harness.poolAddressFor(address(usdc)), address(usdcPool));
        assertEq(harness.symbolFor(address(usdc)), bytes32("USDC"));

        assertTrue(harness.isTokenSupported(DeploymentChainConfig.NATIVE_ADDRESS));
        assertEq(harness.poolAddressFor(DeploymentChainConfig.NATIVE_ADDRESS), address(wavaxPool));
    }

    function test_resolution_unknownTokenIsUnsupported() public {
        TestERC20 rando = new TestERC20("Rando", "RND", 18);
        assertFalse(harness.isTokenSupported(address(rando)));
        assertEq(harness.poolAddressFor(address(rando)), address(0));
        assertFalse(harness.isTokenSupported(address(0)));
    }

    /// @dev PRIME is a registered token asset with no lending pool: unsupported, not a revert.
    function test_resolution_tokenAssetWithoutPoolIsUnsupported() public {
        assertEq(harness.poolAddressFor(address(prime)), address(0));
        assertFalse(harness.isTokenSupported(address(prime)));
    }

    /// @dev A pool added to the registry after deployment is swappable with no redeploy (EUROC).
    function test_resolution_newPoolAssetNeedsNoRedeploy() public {
        TestERC20 euroc = new TestERC20("Euro Coin", "EUROC", 6);
        assertFalse(harness.isTokenSupported(address(euroc)));

        Pool eurocPool = _deployPool(payable(address(euroc)));
        eurocPool.setTokenManager(ITokenManager(address(tokenManager)));

        TokenManager.Asset[] memory assets = new TokenManager.Asset[](1);
        assets[0] = TokenManager.Asset(bytes32("EUROC"), address(euroc), DEBT_COVERAGE);
        tokenManager.addTokenAssets(assets);

        TokenManager.poolAsset[] memory poolAssets = new TokenManager.poolAsset[](1);
        poolAssets[0] = TokenManager.poolAsset(bytes32("EUROC"), address(eurocPool));
        tokenManager.addPoolAssets(poolAssets);

        assertTrue(harness.isTokenSupported(address(euroc)));
        assertEq(harness.poolAddressFor(address(euroc)), address(eurocPool));
        assertEq(harness.symbolFor(address(euroc)), bytes32("EUROC"));
    }

    /// @dev Deactivating an asset closes its deposit-swap route.
    function test_resolution_deactivatedAssetIsUnsupported() public {
        assertTrue(harness.isTokenSupported(address(usdc)));

        tokenManager.deactivateToken(address(usdc));
        assertFalse(harness.isTokenSupported(address(usdc)));
        assertEq(harness.poolAddressFor(address(usdc)), address(0));

        tokenManager.activateToken(address(usdc));
        assertTrue(harness.isTokenSupported(address(usdc)));
    }
}
