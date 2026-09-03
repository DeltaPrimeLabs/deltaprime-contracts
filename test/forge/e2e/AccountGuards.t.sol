// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";
import {SmartLoansFactory} from "../../../contracts/SmartLoansFactory.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";

/**
 * @title AccountGuards e2e — SP4.2
 *
 * Pins the auth/timing/pause guard matrix for Prime Accounts (SmartLoanDiamondProxy).
 * All revert strings are sourced directly from the contract source files.
 *
 * Guard inventory and pinned strings/selectors:
 *
 *   noBorrowInTheSameBlock (PrimeAccountModifiers.sol:106)
 *     → require(_lastBorrowTimestamp != block.timestamp,
 *               "Borrowing must happen in a standalone transaction")
 *     Applies to fund() AND borrow(). Only borrow() SETS _lastBorrowTimestamp.
 *
 *   onlyOwner / onlyOwnerOrFactory → DiamondStorageLib.enforceIsContractOwner()
 *     → require(msg.sender == contractOwner,
 *               "DiamondStorageLib: Must be contract owner")
 *
 *   repay() auth (conditional, not a modifier):
 *     if (_isSolvent()) { DiamondStorageLib.enforceIsContractOwner(); }
 *     → When solvent: owner required; when insolvent: anyone may repay.
 *
 *   SmartLoansFactory.hasNoLoan (factory.sol:64)
 *     → require(!_hasLoan(msg.sender), "Only one loan per owner is allowed")
 *
 *   SmartLoansFactory.createLoan + whitelistLiquidators cross-guard:
 *     createLoan → revert OwnerIsLiquidator()  (custom error, if caller is whitelisted)
 *     whitelistLiquidators → "liquidators can't have loans" (string, if candidate has loan)
 *
 *   Beacon pause (SmartLoanDiamondBeacon.notPausedOrUpgrading)
 *     → revert("ProtocolUpgrade: paused.")
 *     pause/unpause caller = pauseAdmin = address(this) (set in beacon constructor)
 */
contract AccountGuardsTest is DeltaPrimeFixture {

    function setUp() public override {
        super.setUp();
        // Pre-fund USDC pool so borrow calls work.
        address lender = makeAddr("lender");
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();
    }

    // ─── Test 1a: second borrow in same block.timestamp reverts ──────────────

    /**
     * borrow() sets _lastBorrowTimestamp = block.timestamp.
     * noBorrowInTheSameBlock checks _lastBorrowTimestamp == block.timestamp → reverts.
     *
     * PINNED (PrimeAccountModifiers.sol:106):
     *   "Borrowing must happen in a standalone transaction"
     */
    function testSecondBorrowInSameBlockReverts() public {
        (address borrower, address loan) = _createLoanFor("sameBlock");
        _fundAvax(borrower, loan, 100e18);

        // First borrow — advance timestamp first so fund's noBorrowInTheSameBlock passes.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );
        // _lastBorrowTimestamp is now = block.timestamp.

        // Second borrow at the SAME timestamp (no warp) — must revert.
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(50e6)),
            _feeds(), _prices()
        );
        assertFalse(ok, "second borrow in same timestamp must revert");
        // PINNED: PrimeAccountModifiers.noBorrowInTheSameBlock
        assertTrue(
            _revertContains(ret, "Borrowing must happen in a standalone transaction"),
            "expected noBorrowInTheSameBlock revert"
        );
    }

    // ─── Test 1b: fund() after borrow in same block → reverts ────────────────

    /**
     * fund() also has noBorrowInTheSameBlock. After a borrow sets _lastBorrowTimestamp,
     * calling fund() in the same block also reverts with the same string.
     * PINNED: the modifier fires on both fund() and borrow() — only borrow() sets the
     * timestamp. fund() does NOT set _lastBorrowTimestamp.
     */
    function testFundAfterBorrowInSameBlockReverts() public {
        (address borrower, address loan) = _createLoanFor("sameBlockFund");
        _fundAvax(borrower, loan, 100e18);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );
        // _lastBorrowTimestamp = block.timestamp now.

        // Attempt fund in SAME timestamp → noBorrowInTheSameBlock fires.
        address wavaxAddr = address(wavax);
        uint256 extra = 10e18;
        vm.deal(borrower, extra);
        vm.startPrank(borrower);
        wavax.deposit{value: extra}();
        wavax.approve(loan, extra);
        (bool ok, bytes memory ret) = address(loan).call(
            abi.encodeWithSelector(AssetsOperationsFacet.fund.selector, NATIVE_SYMBOL, extra)
        );
        vm.stopPrank();

        assertFalse(ok, "fund() in same block as borrow must revert");
        assertTrue(
            _revertContains(ret, "Borrowing must happen in a standalone transaction"),
            "expected noBorrowInTheSameBlock revert on fund()"
        );
    }

    // ─── Test 1c: borrow succeeds after warp ──────────────────────────────────

    /**
     * After vm.warp(+1) the block.timestamp differs from _lastBorrowTimestamp.
     * Two sequential borrows with a warp between them both succeed.
     */
    function testBorrowsSucceedAfterWarp() public {
        (address borrower, address loan) = _createLoanFor("warpBorrow");
        _fundAvax(borrower, loan, 100e18);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );

        vm.warp(block.timestamp + 1); // advance again
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );

        assertEq(usdc.balanceOf(loan), 200e6, "loan must hold 200 USDC after two sequential borrows");
    }

    // ─── Test 2: fund by non-owner → revert ──────────────────────────────────

    /**
     * fund() has onlyOwnerOrFactory:
     *   if (msg.sender != factory) { DiamondStorageLib.enforceIsContractOwner(); }
     *
     * PINNED (DiamondStorageLib.sol:479):
     *   "DiamondStorageLib: Must be contract owner"
     */
    function testFundByNonOwnerReverts() public {
        (, address loan) = _createLoanFor("fundAuth");

        address rando = makeAddr("rando");
        vm.deal(rando, 10e18);
        vm.startPrank(rando);
        wavax.deposit{value: 10e18}();
        wavax.approve(loan, 10e18);
        (bool ok, bytes memory ret) = address(loan).call(
            abi.encodeWithSelector(AssetsOperationsFacet.fund.selector, NATIVE_SYMBOL, uint256(10e18))
        );
        vm.stopPrank();

        assertFalse(ok, "fund by non-owner must revert");
        // PINNED: DiamondStorageLib.enforceIsContractOwner
        assertTrue(
            _revertContains(ret, "DiamondStorageLib: Must be contract owner"),
            "expected owner guard revert on fund()"
        );
    }

    // ─── Test 3: borrow by non-owner → revert ────────────────────────────────

    /**
     * borrow() has onlyOwner modifier → DiamondStorageLib.enforceIsContractOwner().
     * PINNED: same string as fund() non-owner case.
     */
    function testBorrowByNonOwnerReverts() public {
        (address borrower, address loan) = _createLoanFor("borrowAuth");
        _fundAvax(borrower, loan, 100e18);
        vm.warp(block.timestamp + 1);

        address rando = makeAddr("rando");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );

        assertFalse(ok, "borrow by non-owner must revert");
        // PINNED: DiamondStorageLib.enforceIsContractOwner (via onlyOwner modifier)
        assertTrue(
            _revertContains(ret, "DiamondStorageLib: Must be contract owner"),
            "expected owner guard revert on borrow()"
        );
    }

    // ─── Test 4: repay auth — owner required when solvent ────────────────────

    /**
     * PINNED (AssetsOperationsFacet.repay lines 290-292):
     *   if (_isSolvent()) { DiamondStorageLib.enforceIsContractOwner(); }
     *
     * When the account is solvent, repay() enforces owner. Non-owner call reverts.
     * When the account is insolvent, repay() skips the owner check (anyone can repay).
     *
     * This test covers the solvent case only (insolvent path requires a price crash
     * scenario covered in the liquidation suite).
     *
     * Note: repay() calls _isSolvent() which uses proxyDelegateCalldata (ProxyConnector),
     * so the RedStone oracle calldata must be present — the call must be wrapped.
     */
    function testRepayOwnerRequiredWhenSolvent() public {
        (address borrower, address loan) = _createLoanFor("repayAuth");
        _fundAvax(borrower, loan, 100e18);

        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(1_000e6)),
            _feeds(), _prices()
        );

        vm.warp(block.timestamp + 1);
        address rando = makeAddr("randoRepayer");
        vm.prank(rando);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.repay.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );

        assertFalse(ok, "non-owner repay must revert when account is solvent");
        // PINNED: enforceIsContractOwner called inside repay body when _isSolvent()
        assertTrue(
            _revertContains(ret, "DiamondStorageLib: Must be contract owner"),
            "expected owner guard inside repay() when solvent"
        );
    }

    // ─── Test 5: createLoan twice same owner → revert ────────────────────────

    /**
     * PINNED (SmartLoansFactory.hasNoLoan, factory.sol:64):
     *   require(!_hasLoan(msg.sender), "Only one loan per owner is allowed")
     */
    function testCreateLoanTwiceReverts() public {
        address owner = makeAddr("doubleOwner");
        vm.startPrank(owner);
        factory.createLoan(); // first loan — succeeds
        vm.expectRevert(bytes("Only one loan per owner is allowed"));
        factory.createLoan(); // second loan — reverts
        vm.stopPrank();
    }

    // ─── Test 6a: whitelisted liquidator cannot createLoan ───────────────────

    /**
     * PINNED (SmartLoansFactory.createLoan, factory.sol:115):
     *   if (isLiquidatorWhitelisted(msg.sender)) revert OwnerIsLiquidator();
     *
     * Custom error — compared via selector, not string.
     * `liquidator` is whitelisted in DeltaPrimeFixture.setUp().
     */
    function testWhitelistedLiquidatorCannotCreateLoan() public {
        vm.prank(liquidator);
        // PINNED: SmartLoansFactory.OwnerIsLiquidator (custom error)
        vm.expectRevert(SmartLoansFactory.OwnerIsLiquidator.selector);
        factory.createLoan();
    }

    // ─── Test 6b: loan owner cannot be whitelisted as liquidator ─────────────

    /**
     * PINNED (SmartLoanLiquidationFacet.whitelistLiquidators, liquidation.sol:88):
     *   require(getLoanForOwner(_liquidators[i]) == address(0),
     *           "liquidators can't have loans")
     *
     * Caller of whitelistLiquidators is the BEACON's diamond storage owner
     * (== address(this) in the fixture, set in setUp via deployCodeTo).
     */
    function testLoanOwnerCannotBeWhitelistedAsLiquidator() public {
        (address borrower, ) = _createLoanFor("borrowerWithLoan");

        address[] memory candidates = new address[](1);
        candidates[0] = borrower;

        // Call on beacon — fixture (address(this)) is both diamond owner and pauseAdmin.
        vm.expectRevert(bytes("liquidators can't have loans"));
        SmartLoanLiquidationFacet(address(beacon)).whitelistLiquidators(candidates);
    }

    // ─── Test 7: pause blocks calls; unpause restores them ───────────────────

    /**
     * SmartLoanDiamondBeacon.notPausedOrUpgrading (beacon.sol:131-134):
     *   if (!_active) { if (!canBeExecutedWhenPaused[funcSig]) revert("ProtocolUpgrade: paused."); }
     *
     * Beacon constructor sets pauseAdmin = address(this) (fixture).
     * DiamondCutFacet.pause() enforces pauseAdmin → fixture can pause/unpause.
     * borrow() selector is NOT in canBeExecutedWhenPaused (only diamondCut + unpause are).
     * Note: IDiamondCut.pause/unpause route through the beacon's fallback → MockDiamondCutFacet.
     */
    function testPauseBlocksBorrowUnpauseRestores() public {
        (address borrower, address loan) = _createLoanFor("pauseTest");
        _fundAvax(borrower, loan, 100e18);

        // Pause the beacon — fixture is pauseAdmin.
        IDiamondCut(address(beacon)).pause();

        // Attempt borrow while paused — must revert.
        vm.warp(block.timestamp + 1);
        vm.prank(borrower);
        (bool ok, bytes memory ret) = RedstoneLib.wrap(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );
        assertFalse(ok, "borrow must revert when beacon is paused");
        // PINNED: SmartLoanDiamondBeacon.notPausedOrUpgrading
        assertTrue(_revertContains(ret, "ProtocolUpgrade: paused."), "expected paused revert");

        // Unpause — fixture is pauseAdmin.
        IDiamondCut(address(beacon)).unpause();

        // Borrow now succeeds.
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );
        assertEq(usdc.balanceOf(loan), 100e6, "loan must hold borrowed USDC after unpause");
    }
}
