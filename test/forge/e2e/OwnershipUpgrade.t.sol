// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {DeltaPrimeFixture} from "../fixtures/DeltaPrimeFixture.sol";
import {OwnershipFacet} from "../../../contracts/facets/OwnershipFacet.sol";
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
import {ViewFacetV2} from "../helpers/facets/ViewFacetV2.sol";

/**
 * @title OwnershipUpgrade e2e — SP4.3
 *
 * Pins the account-ownership transfer flow and beacon-wide upgrade/remove mechanics.
 * Seven tests cover:
 *
 *   1. Happy-path account ownership transfer (proposeOwnershipTransfer → acceptOwnership).
 *      Factory registry is updated; old owner has no loan; new owner has the loan.
 *      PINNED: OwnershipFacet.sol:13–29 + SmartLoansFactory.changeOwnership (factory:82–95).
 *
 *   2. Wrong acceptor reverts.
 *      PINNED (OwnershipFacet.sol:24):
 *        "Only a proposed user can accept ownership"
 *
 *   3. Propose to an address that already has a loan → revert at propose time.
 *      PINNED (OwnershipFacet.sol:16):
 *        "Can't propose an address that already has a loan"
 *
 *   4. Beacon upgrade propagates to ALL pre-existing accounts.
 *      Replace-cut SmartLoanViewFacet selectors → ViewFacetV2 + Add viewVersion().
 *      Both loans created BEFORE the cut expose viewVersion()==2 and original
 *      getters still function (Replace preserves selector routing).
 *
 *   5. Remove-cut strips viewVersion() from ALL existing accounts.
 *      PINNED (SmartLoanDiamondBeacon.sol:69):
 *        "Diamond: Function does not exist"
 *
 *   6. diamondCut while beacon is UNPAUSED → revert.
 *      PINNED (DiamondCutFacet.paused modifier, DiamondCutFacet.sol:56):
 *        "ProtocolUpgrade: not paused."
 *
 *   7. Non-owner cannot diamondCut (owner guard fires after the paused guard).
 *      PINNED (DiamondStorageLib.enforceIsContractOwner):
 *        "DiamondStorageLib: Must be contract owner"
 *
 * Selector addition discipline:
 *   OwnershipFacet selectors are NOT in the base fixture because no other suite
 *   needs them. They are added on-demand in setUp() below per the add-on-demand rule.
 *   ViewFacetV2 selectors are added inline within the individual tests that need them.
 */
contract OwnershipUpgradeTest is DeltaPrimeFixture {

    function setUp() public override {
        super.setUp();

        // --- On-demand: cut OwnershipFacet selectors into the beacon. ---
        // Needed by tests 1-3. Not included in the base fixture.
        // Pattern: pause → cut → unpause (beacon is unpaused after super.setUp()).
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory ownerCuts = new IDiamondCut.FacetCut[](1);
        ownerCuts[0] = IDiamondCut.FacetCut(
            address(new OwnershipFacet()),
            IDiamondCut.FacetCutAction.Add,
            _ownershipSelectors()
        );
        IDiamondCut(address(beacon)).diamondCut(ownerCuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();
    }

    // ── Test 1: Happy-path account ownership transfer ──────────────────────────

    /**
     * proposeOwnershipTransfer (owner-only, on the loan) → acceptOwnership (proposed user) →
     * factory updates ownersToLoans and loansToOwners.
     *
     * PINNED:
     *   OwnershipFacet.proposeOwnershipTransfer  (OwnershipFacet.sol:13)
     *   OwnershipFacet.acceptOwnership           (OwnershipFacet.sol:23)
     *   SmartLoansFactory.changeOwnership        (SmartLoansFactory.sol:82)
     */
    function testAccountOwnershipTransfer() public {
        (address oldOwner, address loan) = _createLoanFor("oldOwner");
        address newOwner = makeAddr("newOwner");

        // Propose transfer — must be called by current owner.
        vm.prank(oldOwner);
        OwnershipFacet(loan).proposeOwnershipTransfer(newOwner);

        // proposedOwner() reflects the intent before acceptance.
        assertEq(
            OwnershipFacet(loan).proposedOwner(), newOwner,
            "proposedOwner must be set after proposal"
        );

        // Accept — only the proposed user may call this.
        vm.prank(newOwner);
        OwnershipFacet(loan).acceptOwnership();

        // getContractOwner() (SmartLoanViewFacet) and owner() (OwnershipFacet)
        // both reflect newOwner (both read DiamondStorageLib.contractOwner()).
        assertEq(
            SmartLoanViewFacet(loan).getContractOwner(), newOwner,
            "getContractOwner must return newOwner after accept"
        );
        assertEq(
            OwnershipFacet(loan).owner(), newOwner,
            "owner() must return newOwner after accept"
        );

        // Factory registry: old owner cleared, new owner registered.
        assertEq(
            factory.getLoanForOwner(oldOwner), address(0),
            "old owner must have no loan in factory after transfer"
        );
        assertEq(
            factory.getLoanForOwner(newOwner), loan,
            "new owner must have the loan in factory after transfer"
        );
    }

    // ── Test 2: Wrong acceptor reverts ────────────────────────────────────────

    /**
     * PINNED (OwnershipFacet.sol:24):
     *   "Only a proposed user can accept ownership"
     */
    function testWrongAcceptorReverts() public {
        (address oldOwner, address loan) = _createLoanFor("propOwner");
        address intended = makeAddr("intended");
        address rando   = makeAddr("rando");

        vm.prank(oldOwner);
        OwnershipFacet(loan).proposeOwnershipTransfer(intended);

        vm.prank(rando);
        (bool ok, bytes memory ret) = address(loan).call(
            abi.encodeWithSelector(OwnershipFacet.acceptOwnership.selector)
        );
        assertFalse(ok, "wrong acceptor must revert");
        // PINNED: OwnershipFacet.acceptOwnership require string
        assertTrue(
            _revertContains(ret, "Only a proposed user can accept ownership"),
            "expected wrong-acceptor revert"
        );
    }

    // ── Test 3: Propose to an address that already has a loan → reverts ───────

    /**
     * proposeOwnershipTransfer checks getLoanForOwner(_newOwner) == address(0) and
     * reverts if the proposed new owner already has a loan.
     *
     * PINNED (OwnershipFacet.sol:16):
     *   "Can't propose an address that already has a loan"
     */
    function testProposeToAddressWithExistingLoanReverts() public {
        (address owner1, address loan1) = _createLoanFor("owner1");
        (address owner2,             ) = _createLoanFor("owner2");

        // owner2 already has a loan — proposing them must fail.
        vm.prank(owner1);
        (bool ok, bytes memory ret) = address(loan1).call(
            abi.encodeWithSelector(OwnershipFacet.proposeOwnershipTransfer.selector, owner2)
        );
        assertFalse(ok, "propose to existing-loan owner must revert");
        // PINNED: OwnershipFacet.proposeOwnershipTransfer require string
        assertTrue(
            _revertContains(ret, "Can't propose an address that already has a loan"),
            "expected already-has-loan revert"
        );
    }

    // ── Test 4: Beacon upgrade (Replace+Add) propagates to ALL accounts ───────

    /**
     * Two loans exist BEFORE the upgrade cut. After a Replace of the existing
     * SmartLoanViewFacet selectors → ViewFacetV2 + Add of viewVersion(), BOTH
     * pre-existing loans immediately expose viewVersion()==2 (they share the
     * beacon's selector→facet table). Original getters still work because
     * ViewFacetV2 inherits SmartLoanViewFacet verbatim.
     *
     * This pins the "beacon upgrade is instantaneous and global — no per-loan
     * action needed" invariant of the Diamond beacon architecture.
     *
     * ViewFacetV2 is etched (not deployed with `new`) because its bytecode
     * exceeds EIP-170 (>24 KB) due to the inherited facet chain.
     */
    function testBeaconUpgradeAffectsAllAccounts() public {
        // Two loans created BEFORE the upgrade.
        (, address loan1) = _createLoanFor("borrower1");
        (, address loan2) = _createLoanFor("borrower2");

        // Deploy ViewFacetV2 via etch (same pattern as SolvencyFacetTestAvalanche).
        address v2Addr = makeAddr("viewFacetV2");
        vm.etch(v2Addr, type(ViewFacetV2).runtimeCode);

        // Pause → Replace existing view selectors (→ V2) + Add viewVersion() → Unpause.
        IDiamondCut(address(beacon)).pause();

        IDiamondCut.FacetCut[] memory upgradeCuts = new IDiamondCut.FacetCut[](2);
        // Replace: 7 existing SmartLoanViewFacet selectors now route to ViewFacetV2.
        upgradeCuts[0] = IDiamondCut.FacetCut(
            v2Addr,
            IDiamondCut.FacetCutAction.Replace,
            _upgradeTestViewSelectors()
        );
        // Add: new viewVersion() selector (not present before).
        bytes4[] memory newSel = new bytes4[](1);
        newSel[0] = ViewFacetV2.viewVersion.selector;
        upgradeCuts[1] = IDiamondCut.FacetCut(
            v2Addr,
            IDiamondCut.FacetCutAction.Add,
            newSel
        );
        IDiamondCut(address(beacon)).diamondCut(upgradeCuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();

        // Both pre-existing loans expose viewVersion()==2 immediately (no per-loan action).
        assertEq(
            ViewFacetV2(loan1).viewVersion(), 2,
            "loan1 must expose viewVersion()==2 after beacon upgrade"
        );
        assertEq(
            ViewFacetV2(loan2).viewVersion(), 2,
            "loan2 must expose viewVersion()==2 after beacon upgrade"
        );

        // Original getters still work — Replace preserves semantics via inheritance.
        assertNotEq(
            SmartLoanViewFacet(loan1).getContractOwner(), address(0),
            "loan1 getContractOwner() must still return non-zero owner"
        );
        assertNotEq(
            SmartLoanViewFacet(loan2).getContractOwner(), address(0),
            "loan2 getContractOwner() must still return non-zero owner"
        );
    }

    // ── Test 5: Remove-cut strips viewVersion() from all accounts ─────────────

    /**
     * After the same Add-cut as test 4, a Remove-cut eliminates the selector.
     * Both pre-existing loans revert with "Diamond: Function does not exist"
     * because the beacon's selector table has no entry for viewVersion().
     *
     * PINNED (SmartLoanDiamondBeacon.sol:69):
     *   "Diamond: Function does not exist"
     */
    function testRemoveCutRevertsOnBothLoans() public {
        (, address loan1) = _createLoanFor("remove1");
        (, address loan2) = _createLoanFor("remove2");

        address v2Addr = makeAddr("viewFacetV2b");
        vm.etch(v2Addr, type(ViewFacetV2).runtimeCode);

        bytes4[] memory addSel = new bytes4[](1);
        addSel[0] = ViewFacetV2.viewVersion.selector;

        // First: Add viewVersion() so it exists in the beacon.
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory addCuts = new IDiamondCut.FacetCut[](1);
        addCuts[0] = IDiamondCut.FacetCut(v2Addr, IDiamondCut.FacetCutAction.Add, addSel);
        IDiamondCut(address(beacon)).diamondCut(addCuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();

        // Pre-condition: viewVersion() callable before removal.
        assertEq(ViewFacetV2(loan1).viewVersion(), 2, "pre-condition: viewVersion must work");

        // Remove the selector.
        IDiamondCut(address(beacon)).pause();
        IDiamondCut.FacetCut[] memory removeCuts = new IDiamondCut.FacetCut[](1);
        removeCuts[0] = IDiamondCut.FacetCut(
            address(0),
            IDiamondCut.FacetCutAction.Remove,
            addSel
        );
        IDiamondCut(address(beacon)).diamondCut(removeCuts, address(0), "");
        IDiamondCut(address(beacon)).unpause();

        // Both loans revert — beacon table has no entry for viewVersion().
        (bool ok1, bytes memory ret1) = address(loan1).call(
            abi.encodeWithSelector(ViewFacetV2.viewVersion.selector)
        );
        assertFalse(ok1, "loan1 viewVersion must revert after remove-cut");
        assertTrue(
            _revertContains(ret1, "Diamond: Function does not exist"),
            "expected function-not-exist revert on loan1"
        );

        (bool ok2, bytes memory ret2) = address(loan2).call(
            abi.encodeWithSelector(ViewFacetV2.viewVersion.selector)
        );
        assertFalse(ok2, "loan2 viewVersion must revert after remove-cut");
        assertTrue(
            _revertContains(ret2, "Diamond: Function does not exist"),
            "expected function-not-exist revert on loan2"
        );
    }

    // ── Test 6: diamondCut while beacon is UNPAUSED → revert ──────────────────

    /**
     * The `paused` modifier on MockDiamondCutFacet.diamondCut requires the beacon
     * to be paused (_active == false). After setUp() the beacon is unpaused.
     *
     * Note: diamondCut selector (0x1f931c1c) IS in canBeExecutedWhenPaused
     * (SmartLoanDiamondBeacon.sol:37), so the beacon's notPausedOrUpgrading check
     * passes. The revert comes from the paused modifier INSIDE MockDiamondCutFacet.
     *
     * PINNED (DiamondCutFacet.sol:56 — paused modifier):
     *   "ProtocolUpgrade: not paused."
     */
    function testDiamondCutWhileUnpausedReverts() public {
        // Beacon is unpaused after setUp().
        IDiamondCut.FacetCut[] memory noop = new IDiamondCut.FacetCut[](0);
        (bool ok, bytes memory ret) = address(beacon).call(
            abi.encodeWithSelector(IDiamondCut.diamondCut.selector, noop, address(0), bytes(""))
        );
        assertFalse(ok, "diamondCut while unpaused must revert");
        // PINNED: DiamondCutFacet.paused modifier
        assertTrue(
            _revertContains(ret, "ProtocolUpgrade: not paused."),
            "expected not-paused revert on diamondCut while active"
        );
    }

    // ── Test 7: Non-owner cannot diamondCut ───────────────────────────────────

    /**
     * Even after pausing, DiamondStorageLib.enforceIsContractOwner() fires for
     * any caller that is not the beacon's contractOwner (== address(this) in tests).
     *
     * PINNED (DiamondStorageLib.enforceIsContractOwner):
     *   "DiamondStorageLib: Must be contract owner"
     */
    function testNonOwnerCannotDiamondCut() public {
        // Pause the beacon first (required for diamondCut to reach the owner check).
        IDiamondCut(address(beacon)).pause();

        address rando = makeAddr("randoCutter");
        IDiamondCut.FacetCut[] memory noop = new IDiamondCut.FacetCut[](0);

        vm.prank(rando);
        (bool ok, bytes memory ret) = address(beacon).call(
            abi.encodeWithSelector(IDiamondCut.diamondCut.selector, noop, address(0), bytes(""))
        );
        assertFalse(ok, "non-owner diamondCut must revert");
        // PINNED: DiamondStorageLib.enforceIsContractOwner
        assertTrue(
            _revertContains(ret, "DiamondStorageLib: Must be contract owner"),
            "expected owner guard on non-owner diamondCut"
        );

        // Restore unpaused state for test hygiene.
        IDiamondCut(address(beacon)).unpause();
    }

    // ---------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------

    /// @dev OwnershipFacet selectors cut on-demand in setUp().
    ///      Add-on-demand rule: not in the base fixture because no other suite needs them.
    function _ownershipSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = OwnershipFacet.proposeOwnershipTransfer.selector;
        s[1] = OwnershipFacet.acceptOwnership.selector;
        s[2] = OwnershipFacet.owner.selector;
        s[3] = OwnershipFacet.proposedOwner.selector;
        s[4] = OwnershipFacet.pauseAdmin.selector;
        s[5] = OwnershipFacet.proposedPauseAdmin.selector;
    }

    /// @dev Mirrors DeltaPrimeFixture._viewSelectors() (which is private and not
    ///      accessible here). Used by the Replace-cut in testBeaconUpgradeAffectsAllAccounts
    ///      to redirect ALL existing SmartLoanViewFacet selectors → ViewFacetV2.
    ///      MUST stay in sync with the fixture's cut list.
    function _upgradeTestViewSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](7);
        s[0] = SmartLoanViewFacet.initialize.selector;
        s[1] = SmartLoanViewFacet.getAllOwnedAssets.selector;
        s[2] = SmartLoanViewFacet.getBalance.selector;
        s[3] = SmartLoanViewFacet.getContractOwner.selector;
        s[4] = SmartLoanViewFacet.getAllAssetsBalances.selector;
        s[5] = SmartLoanViewFacet.getDebts.selector;
        s[6] = SmartLoanViewFacet.getPercentagePrecision.selector;
    }
}
