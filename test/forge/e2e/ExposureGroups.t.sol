// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {RedstoneLib} from "../helpers/RedstoneLib.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";

/**
 * @title ExposureGroups e2e — SP4.4
 *
 * Pins the protocol-exposure accounting that guards how much of any
 * "exposure group" the protocol can hold at one time.
 *
 * Architecture (read before modifying):
 *   TokenManager.setIdentifiersToExposureGroups(ids, groups)
 *     → identifierToExposureGroup[symbol] = groupKey
 *   TokenManager.setMaxProtocolsExposure(groups, maxes)
 *     → groupToExposure[groupKey].max = max
 *
 *   fund() / borrow() / repay() all call _syncExposure() (DiamondMethodsAccess.sol:231)
 *   which calls tokenManager.updateUserExposure(loan, token).
 *   updateUserExposure normalises the loan's token balance to 1e18 precision:
 *     normalised = balance * 1e18 / (10 ** decimals)
 *   and calls increaseProtocolExposure or decreaseProtocolExposure with the delta.
 *
 *   increaseProtocolExposure (TokenManager.sol:264):
 *     group = identifierToExposureGroup[symbol]
 *     if group != "":
 *       exposure.current += delta
 *       if max != 0: require(current <= max, "Max asset exposure breached")
 *
 *   decreaseProtocolExposure (TokenManager.sol:277):
 *     if group != "": exposure.current -= delta (floor at 0)
 *
 *   If the symbol has NO group mapping, the call returns early — no exposure
 *   change, no revert (the "unmapped asset" invariant, test 4).
 *
 * Normalisation:
 *   AVAX (18 dec): 100e18 tokens → 100e18 normalised units
 *   USDC  (6 dec): 100e6  tokens → 100e18 normalised units (×1e12 factor)
 *
 * Five tests:
 *   1. Fund increases group exposure (AVAX → "MAJORS" group).
 *   2. Exceeding the group cap blocks fund (reverts "Max asset exposure breached").
 *   3. Repay decreases exposure symmetrically (USDC → "MAJORS" group).
 *   4. Unmapped asset: fund with PRIME (no group) → no exposure change, no revert.
 *   5. setMaxProtocolsExposure LOWER than current: setter passes, next increase reverts.
 */
contract ExposureGroupsTest is DeltaPrimeFixture {

    bytes32 internal constant GROUP_MAJORS = bytes32("MAJORS");

    function setUp() public override {
        super.setUp();
        // Pre-fund USDC pool for test 3 (borrow → repay path).
        address lender = makeAddr("lender");
        usdc.mint(lender, 1_000_000e6);
        vm.startPrank(lender);
        usdc.approve(address(usdcPool), 1_000_000e6);
        usdcPool.deposit(1_000_000e6);
        vm.stopPrank();
    }

    // ── Test 1: fund() increases group exposure ────────────────────────────────

    /**
     * Mapping AVAX → "MAJORS" and funding 100 AVAX must increase
     * groupToExposure["MAJORS"].current by exactly 100e18 (1e18 normalised units
     * per AVAX, since AVAX has 18 decimals).
     *
     * Path: fund() → _syncExposure() → updateUserExposure() → increaseProtocolExposure()
     *
     * PINNED: TokenManager.increaseProtocolExposure (TokenManager.sol:264)
     *         exposure delta = normalised balance diff = 100e18
     */
    function testFundIncreasesGroupExposure() public {
        // Wire AVAX symbol → "MAJORS" group.
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = NATIVE_SYMBOL;
        groups[0] = GROUP_MAJORS;
        tokenManager.setIdentifiersToExposureGroups(ids, groups);

        // Set a generous cap (no ceiling hit in this test).
        bytes32[] memory gids = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        gids[0] = GROUP_MAJORS;
        maxs[0] = 1_000e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);

        // Baseline: no exposure yet.
        (uint256 currentBefore, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(currentBefore, 0, "MAJORS exposure must start at 0");

        // Create loan and fund 100 AVAX.
        (address borrower, address loan) = _createLoanFor("expFunder");
        _fundAvax(borrower, loan, 100e18);

        // Exposure must have increased by exactly 100e18 (normalised).
        (uint256 currentAfter, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(
            currentAfter, 100e18,
            "MAJORS exposure must increase by 100e18 after funding 100 AVAX"
        );
    }

    // ── Test 2: Exceeding the group cap blocks fund() ─────────────────────────

    /**
     * With max = 50e18, funding 100 AVAX pushes current to 100e18 > 50e18.
     * increaseProtocolExposure reverts before the state settles.
     *
     * PINNED (TokenManager.sol:270):
     *   "Max asset exposure breached"
     */
    function testExceedingGroupCapBlocksFund() public {
        // Map AVAX → "MAJORS".
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = NATIVE_SYMBOL;
        groups[0] = GROUP_MAJORS;
        tokenManager.setIdentifiersToExposureGroups(ids, groups);

        // Cap at 50e18 — less than the 100e18 we will try to fund.
        bytes32[] memory gids = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        gids[0] = GROUP_MAJORS;
        maxs[0] = 50e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);

        (address borrower, address loan) = _createLoanFor("capTest");

        // Attempt fund — must revert inside increaseProtocolExposure.
        uint256 amount = 100e18;
        vm.deal(borrower, amount);
        vm.startPrank(borrower);
        wavax.deposit{value: amount}();
        wavax.approve(loan, amount);
        (bool ok, bytes memory ret) = address(loan).call(
            abi.encodeWithSelector(AssetsOperationsFacet.fund.selector, NATIVE_SYMBOL, amount)
        );
        vm.stopPrank();

        assertFalse(ok, "fund beyond group cap must revert");
        // PINNED: TokenManager.increaseProtocolExposure require string
        assertTrue(
            _revertContains(ret, "Max asset exposure breached"),
            "expected exposure-cap revert"
        );
    }

    // ── Test 3: Repay decreases exposure symmetrically ────────────────────────

    /**
     * Map USDC → "MAJORS". Borrow 100 USDC → MAJORS.current = 100e18.
     * Repay 50 USDC → MAJORS.current = 50e18 (decrease of 50e18 normalised).
     *
     * AVAX is NOT mapped to "MAJORS" in this test, so collateral funding
     * produces no exposure change and the arithmetic is unambiguous.
     *
     * Path:
     *   borrow() → pool.borrow() → _syncExposure() → updateUserExposure()
     *             → increaseProtocolExposure("USDC", 100e18)
     *   repay()  → pool.repay()  → _syncExposure() → updateUserExposure()
     *             → decreaseProtocolExposure("USDC", 50e18)
     *
     * Normalisation for USDC (6 dec):
     *   100e6 tokens × 1e18 / 1e6 = 100e18 normalised units
     *   50e6  tokens × 1e18 / 1e6 = 50e18  normalised units
     *
     * PINNED: TokenManager.decreaseProtocolExposure (TokenManager.sol:277)
     */
    function testRepayDecreasesExposureSymmetrically() public {
        // Map USDC → "MAJORS" (AVAX left unmapped).
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = bytes32("USDC");
        groups[0] = GROUP_MAJORS;
        tokenManager.setIdentifiersToExposureGroups(ids, groups);

        bytes32[] memory gids = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        gids[0] = GROUP_MAJORS;
        maxs[0] = 1_000e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);

        (address borrower, address loan) = _createLoanFor("repayExp");

        // Fund AVAX (unmapped → no MAJORS exposure change).
        _fundAvax(borrower, loan, 100e18);

        // Advance past noBorrowInTheSameBlock guard.
        vm.warp(block.timestamp + 1);

        // Borrow 100 USDC → MAJORS.current = 100e18.
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.borrow.selector, bytes32("USDC"), uint256(100e6)),
            _feeds(), _prices()
        );

        (uint256 afterBorrow, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(afterBorrow, 100e18, "MAJORS must be 100e18 after borrowing 100 USDC");

        // Advance past noBorrowInTheSameBlock guard for repay.
        vm.warp(block.timestamp + 1);

        // Repay 50 USDC (owner required when solvent — wrapped with oracle payload).
        vm.prank(borrower);
        RedstoneLib.wrapExpectSuccess(
            vm, loan,
            abi.encodeWithSelector(AssetsOperationsFacet.repay.selector, bytes32("USDC"), uint256(50e6)),
            _feeds(), _prices()
        );

        // Exposure must have decreased by exactly 50e18.
        (uint256 afterRepay, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(afterRepay, 50e18, "MAJORS must drop to 50e18 after repaying 50 USDC");
    }

    // ── Test 4: Unmapped asset — no exposure change, no revert ────────────────

    /**
     * PRIME is registered in TokenManager (asset added) but has NO
     * identifierToExposureGroup mapping in this test. Fund with PRIME:
     *   _syncExposure() → updateUserExposure() → increaseProtocolExposure("PRIME", delta)
     *   → group = identifierToExposureGroup["PRIME"] = ""
     *   → function returns early (TokenManager.sol:265-266)
     * No revert, no exposure delta in any group.
     *
     * AVAX is mapped to "MAJORS" as a witness: MAJORS.current stays 0 because
     * PRIME never touches it.
     *
     * PINNED: TokenManager.increaseProtocolExposure early-return on empty group
     *         (TokenManager.sol:266): if(group != ""){...}
     */
    function testUnmappedAssetNoExposureChange() public {
        // Map AVAX → "MAJORS" as a witness group (PRIME intentionally NOT mapped).
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = NATIVE_SYMBOL;
        groups[0] = GROUP_MAJORS;
        tokenManager.setIdentifiersToExposureGroups(ids, groups);

        bytes32[] memory gids = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        gids[0] = GROUP_MAJORS;
        maxs[0] = 1_000e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);

        (address borrower, address loan) = _createLoanFor("unmapped");

        // Mint PRIME and fund the loan with it.
        uint256 primeAmount = 500e18;
        prime.mint(borrower, primeAmount);
        vm.startPrank(borrower);
        prime.approve(loan, primeAmount);
        // fund() must succeed — no group mapping means no exposure check.
        AssetsOperationsFacet(loan).fund(bytes32("PRIME"), primeAmount);
        vm.stopPrank();

        // Loan holds the PRIME.
        assertEq(prime.balanceOf(loan), primeAmount, "loan must hold funded PRIME");

        // MAJORS exposure untouched (PRIME is not in MAJORS or any other group).
        (uint256 currentMajors, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(
            currentMajors, 0,
            "MAJORS exposure must remain 0 -- unmapped PRIME must not affect it"
        );

        // Also confirm PRIME's own identifier has no group.
        assertEq(
            tokenManager.identifierToExposureGroup(bytes32("PRIME")), bytes32(0),
            "PRIME must have no exposure group mapping"
        );
    }

    // ── Test 5: setMaxProtocolsExposure below current: setter passes, ──────────
    //           next increaseProtocolExposure reverts ─────────────────────────

    /**
     * _setMaxProtocolExposure (TokenManager.sol:305) stores the new max without
     * validating against the current exposure. The invariant is only enforced
     * LAZILY on the next increaseProtocolExposure call.
     *
     * Sequence:
     *   1. Map AVAX → "MAJORS", set max = 1000e18.
     *   2. Fund 100 AVAX → MAJORS.current = 100e18.
     *   3. Set max = 50e18 (BELOW current) → setter succeeds (no check).
     *   4. Fund 1 more AVAX:
     *        current += 1e18 → 101e18 > 50e18 = max → revert.
     *
     * PINNED: _setMaxProtocolExposure does NOT check current (TokenManager.sol:305-311)
     *         increaseProtocolExposure require (TokenManager.sol:270):
     *           "Max asset exposure breached"
     */
    function testSetMaxLowerThanCurrentThenNextIncreaseFails() public {
        // Map AVAX → "MAJORS".
        bytes32[] memory ids    = new bytes32[](1);
        bytes32[] memory groups = new bytes32[](1);
        ids[0]    = NATIVE_SYMBOL;
        groups[0] = GROUP_MAJORS;
        tokenManager.setIdentifiersToExposureGroups(ids, groups);

        bytes32[] memory gids = new bytes32[](1);
        uint256[] memory maxs = new uint256[](1);
        gids[0] = GROUP_MAJORS;
        maxs[0] = 1_000e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);

        (address borrower, address loan) = _createLoanFor("lowMax");

        // Step 2: fund 100 AVAX → MAJORS.current = 100e18.
        _fundAvax(borrower, loan, 100e18);
        (uint256 afterFirstFund, ) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(afterFirstFund, 100e18, "MAJORS must be 100e18 after first fund");

        // Step 3: set max = 50e18 (below current = 100e18) → must NOT revert.
        maxs[0] = 50e18;
        tokenManager.setMaxProtocolsExposure(gids, maxs);
        (uint256 stillAt100, uint256 newMax) = tokenManager.groupToExposure(GROUP_MAJORS);
        assertEq(stillAt100, 100e18, "current must remain 100e18 after setter");
        assertEq(newMax,      50e18, "max must now be 50e18");

        // Step 4: any additional fund triggers the lazy breach check.
        uint256 extra = 1e18;
        vm.deal(borrower, extra);
        vm.startPrank(borrower);
        wavax.deposit{value: extra}();
        wavax.approve(loan, extra);
        (bool ok, bytes memory ret) = address(loan).call(
            abi.encodeWithSelector(AssetsOperationsFacet.fund.selector, NATIVE_SYMBOL, extra)
        );
        vm.stopPrank();

        assertFalse(ok, "fund must revert when current would exceed the lowered max");
        // PINNED: TokenManager.increaseProtocolExposure lazy breach check
        assertTrue(
            _revertContains(ret, "Max asset exposure breached"),
            "expected exposure-cap revert after max lowered below current"
        );
    }
}
