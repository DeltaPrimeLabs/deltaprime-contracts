// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {SmartLoanDiamondBeacon} from "../../../contracts/SmartLoanDiamondBeacon.sol";
import {DiamondStorageLib} from "../../../contracts/lib/DiamondStorageLib.sol";
import {ReentrancyGuardKeccak} from "../../../contracts/ReentrancyGuardKeccak.sol";
import {IDiamondCut} from "../../../contracts/interfaces/IDiamondCut.sol";
import {OwnershipFacet} from "../../../contracts/facets/OwnershipFacet.sol";
import {DeploymentChainConfig} from "../../../contracts/lib/DeploymentChainConfig.sol";

// ══════════════════════════════════════════════════════════════════════════════
// In-file helpers
// ══════════════════════════════════════════════════════════════════════════════

/**
 * @notice A cut facet WITHOUT the production hardcoded-beacon-address check,
 *         so fresh beacon deployments in tests can call diamondCut().
 *
 *         Functionally identical to DiamondCutFacet.sol except for removing:
 *           require(address(this) == 0x968f944e9c43FC8AD80F6C1629F10570a46e2651, ...)
 *
 *         Behavior pins that must stay identical to production:
 *           - diamondCut() reverts unless beacon is paused (modifier `paused`)
 *           - diamondCut() reverts unless caller is contractOwner
 *           - pause()   enforces pauseAdmin + already-active guard
 *           - unpause() enforces pauseAdmin + already-paused guard
 */
contract MockDiamondCutFacet is IDiamondCut {
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external override {
        // Must be called while beacon is paused (same invariant as production).
        DiamondStorageLib.DiamondStorage storage ds;
        bytes32 position = DiamondStorageLib.DIAMOND_STORAGE_POSITION;
        assembly { ds.slot := position }
        require(!ds._active, "ProtocolUpgrade: not paused.");

        DiamondStorageLib.enforceIsContractOwner();
        DiamondStorageLib.diamondCut(_diamondCut, _init, _calldata);
    }

    function unpause() external override {
        DiamondStorageLib.enforceIsPauseAdmin();
        DiamondStorageLib.DiamondStorage storage ds = DiamondStorageLib.diamondStorage();
        require(!ds._active, "ProtocolUpgrade: already unpaused.");
        ds._active = true;
    }

    function pause() external override {
        DiamondStorageLib.enforceIsPauseAdmin();
        DiamondStorageLib.DiamondStorage storage ds = DiamondStorageLib.diamondStorage();
        require(ds._active, "ProtocolUpgrade: already paused.");
        ds._active = false;
    }
}

/**
 * @notice Minimal SmartLoansFactory stub etched at DeploymentConstants.SMART_LOANS_FACTORY
 *         so that OwnershipFacet.proposeOwnershipTransfer / acceptOwnership can
 *         complete without calling live-chain state.
 *
 *         SMART_LOANS_FACTORY address on Arbitrum (DeploymentChainConfig.sol line 19):
 *           0xf77FaCdD1309EC6867682BcE2c93Fb94e22A0EA9
 */
contract MockSmartLoansFactory {
    /// @dev Always returns address(0) — no existing loan for any proposed owner.
    function getLoanForOwner(address) external pure returns (address) {
        return address(0);
    }

    /// @dev No-op: ownership registry update is irrelevant in tests.
    function changeOwnership(address) external {}
}

// ─── Reentrancy guard helpers ─────────────────────────────────────────────────

/**
 * @notice Concrete contract that uses ReentrancyGuardKeccak.
 *         Exposes a guarded entry point that delegates to an external Attacker.
 */
contract GuardedContract is ReentrancyGuardKeccak {
    address public attacker;

    function setAttacker(address _a) external {
        attacker = _a;
    }

    /**
     * @dev nonReentrant sets _status = _ENTERED.  While inside the guard,
     *      any re-entrant call to guardedEntry() finds _status == _ENTERED
     *      and reverts with "ReentrancyGuard: reentrant call".
     */
    function guardedEntry() external nonReentrant {
        // Call the attacker; it will try to re-enter guardedEntry().
        IAttacker(attacker).attack();
    }
}

interface IAttacker {
    function attack() external;
}

/**
 * @notice Tries to re-enter GuardedContract.guardedEntry() when attack() is called.
 *         The inner call should revert with "ReentrancyGuard: reentrant call".
 */
contract ReentrantAttacker {
    GuardedContract public target;
    bytes  public lastRevertData;
    bool   public innerReverted;

    constructor(GuardedContract _target) {
        target = _target;
    }

    function attack() external {
        // Attempt re-entry.
        (bool ok, bytes memory data) = address(target).call(
            abi.encodeWithSelector(GuardedContract.guardedEntry.selector)
        );
        innerReverted = !ok;
        lastRevertData = data;
    }
}

// ─── OwnershipFacet interface (minimal, avoids importing full facet ABI) ─────

interface IOwnershipFacet {
    function proposeOwnershipTransfer(address _newOwner) external;
    function acceptOwnership() external;
    function owner() external view returns (address);
    function proposedOwner() external view returns (address);
    function pauseAdmin() external view returns (address);
    function proposedPauseAdmin() external view returns (address);
}

// ══════════════════════════════════════════════════════════════════════════════
// Test contract
// ══════════════════════════════════════════════════════════════════════════════

/**
 * @title  DiamondInfraTest
 * @notice Unit tests for:
 *           - ReentrancyGuardKeccak  (keccak-slotted re-entrancy protection)
 *           - SmartLoanDiamondBeacon (pause, ownership, selector dispatch)
 *           - OwnershipFacet         (two-step Prime-Account ownership via beacon)
 *
 *         All tests use a fresh beacon deployed with MockDiamondCutFacet,
 *         not the production fixture, so there are no live-chain dependencies.
 */
contract DiamondInfraTest is Test {
    // Factory address read from the ACTIVE chain config — never a literal, so the
    // test passes under all three CI matrix configs (test/avalanche/arbitrum).
    address internal constant FACTORY_ADDR = DeploymentChainConfig.SMART_LOANS_FACTORY;

    address internal owner;
    address internal pauseAdm;
    address internal newOwner;

    MockDiamondCutFacet internal mockCutFacet;
    SmartLoanDiamondBeacon internal beacon;

    function setUp() public {
        // setContractOwner computes block.timestamp - 24 hours; warp first to avoid underflow.
        vm.warp(1_750_000_000);

        owner     = makeAddr("owner");
        pauseAdm  = owner; // constructor sets both to _contractOwner
        newOwner  = makeAddr("newOwner");

        mockCutFacet = new MockDiamondCutFacet();
        beacon       = new SmartLoanDiamondBeacon(owner, address(mockCutFacet));

        // Etch a no-op SmartLoansFactory at the hardcoded DeploymentConstants address
        // so OwnershipFacet calls don't revert with "no code at address".
        MockSmartLoansFactory mockFactory = new MockSmartLoansFactory();
        vm.etch(FACTORY_ADDR, address(mockFactory).code);
    }

    // ─── helper: unpause beacon ───────────────────────────────────────────────

    function _unpause() internal {
        vm.prank(owner);
        IDiamondCut(address(beacon)).unpause();
        assertTrue(beacon.getStatus(), "beacon should be active after unpause");
    }

    // ─── helper: add OwnershipFacet selectors via diamondCut ─────────────────

    function _cutOwnershipFacet() internal returns (OwnershipFacet facet) {
        facet = new OwnershipFacet();

        // All six OwnershipFacet externals.
        bytes4[] memory sels = new bytes4[](6);
        sels[0] = OwnershipFacet.proposeOwnershipTransfer.selector;
        sels[1] = OwnershipFacet.acceptOwnership.selector;
        sels[2] = OwnershipFacet.owner.selector;
        sels[3] = OwnershipFacet.proposedOwner.selector;
        sels[4] = OwnershipFacet.pauseAdmin.selector;
        sels[5] = OwnershipFacet.proposedPauseAdmin.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: address(facet),
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: sels
        });

        // diamondCut requires the beacon to be paused (it is at construction).
        vm.prank(owner);
        IDiamondCut(address(beacon)).diamondCut(cut, address(0), "");
    }

    // ─── helper: read address from beacon's keccak-slotted storage ───────────

    /**
     * @dev SmartLoanStorage is stored at keccak256("diamond.standard.smartloan.storage").
     *      Field offsets (each address occupies one 32-byte slot):
     *        +0  pauseAdmin
     *        +1  contractOwner
     *        +2  proposedOwner
     *        +3  proposedPauseAdmin  (packed with _initialized bool in the same slot)
     */
    bytes32 constant SLS_BASE = keccak256("diamond.standard.smartloan.storage");

    function _readBeaconProposedOwner() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(beacon), bytes32(uint256(SLS_BASE) + 2)))));
    }

    function _readBeaconContractOwner() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(beacon), bytes32(uint256(SLS_BASE) + 1)))));
    }

    function _readBeaconProposedPauseAdmin() internal view returns (address) {
        // proposedPauseAdmin is packed with _initialized (bool) in the same 32-byte slot.
        // The address occupies the low 20 bytes; bool occupies byte 20.
        uint256 raw = uint256(vm.load(address(beacon), bytes32(uint256(SLS_BASE) + 3)));
        return address(uint160(raw)); // low-order 20 bytes
    }

    function _readBeaconPauseAdmin() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(beacon), bytes32(uint256(SLS_BASE))))));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 1. ReentrancyGuardKeccak — blocks re-entrant calls
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice A re-entrant call to a nonReentrant function reverts with
     *         "ReentrancyGuard: reentrant call".
     *
     * Behavior pin: ReentrancyGuardKeccak.sol:30 —
     *   require(rgs._status != _ENTERED, "ReentrancyGuard: reentrant call")
     *
     * Flow: test → GuardedContract.guardedEntry() → ReentrantAttacker.attack()
     *           → GuardedContract.guardedEntry() [inner, re-entrant, reverts]
     */
    function test_reentrancyGuard_preventsReentrantCall() public {
        GuardedContract guarded = new GuardedContract();
        ReentrantAttacker attacker = new ReentrantAttacker(guarded);
        guarded.setAttacker(address(attacker));

        // Outer call succeeds; the attacker's inner call should be caught by the guard.
        guarded.guardedEntry();

        // The attacker recorded whether the inner call reverted.
        assertTrue(attacker.innerReverted(), "inner re-entrant call should have reverted");

        // Decode the revert reason and check the exact string.
        bytes memory data = attacker.lastRevertData();
        // Revert data: 0x08c379a0 (Error(string)) ++ abi-encoded string.
        assertTrue(data.length >= 4, "no revert data captured");
        bytes memory decoded = abi.decode(
            slice(data, 4, data.length - 4),
            (bytes)
        );
        assertEq(
            string(decoded),
            "ReentrancyGuard: reentrant call",
            "unexpected revert message"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2. Beacon — starts in paused (inactive) state
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice SmartLoanDiamondBeacon is paused immediately after construction.
     *
     * Behavior pin: constructor does NOT set ds._active = true; default bool = false.
     *   getStatus() → DiamondStorage.ds._active == false → returns false.
     */
    function test_beacon_startsInPausedState() public {
        assertFalse(beacon.getStatus(), "beacon should start paused (_active = false)");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3. Beacon — pauseAdmin can unpause
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Calling unpause() via the beacon fallback (as pauseAdmin) sets
     *         _active = true and makes the beacon operational.
     *
     * Behavior pin: MockDiamondCutFacet.unpause() (delegated via beacon fallback)
     *   enforceIsPauseAdmin() → require(msg.sender == sls.pauseAdmin)  ← owner
     *   ds._active = true
     */
    function test_beacon_unpauseByPauseAdmin_activates() public {
        assertFalse(beacon.getStatus(), "pre: paused");
        _unpause();
        assertTrue(beacon.getStatus(), "post: active");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4. Beacon — non-pauseAdmin cannot call pause()
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice pause() called by any address other than pauseAdmin reverts.
     *
     * Behavior pin: DiamondStorageLib.enforceIsPauseAdmin (DiamondStorageLib.sol:483)
     *   require(msg.sender == sls.pauseAdmin,
     *           "DiamondStorageLib: Must be contract pauseAdmin")
     *
     * Note: beacon starts paused, so we unpause first so that pause() doesn't
     * additionally revert with "ProtocolUpgrade: already paused."
     */
    function test_beacon_pauseByNonAdmin_reverts() public {
        _unpause();

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert("DiamondStorageLib: Must be contract pauseAdmin");
        IDiamondCut(address(beacon)).pause();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 5. Beacon — non-owner cannot call diamondCut()
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice diamondCut() called by any address other than contractOwner reverts.
     *
     * Behavior pin: DiamondStorageLib.enforceIsContractOwner (DiamondStorageLib.sol:479)
     *   require(msg.sender == sls.contractOwner,
     *           "DiamondStorageLib: Must be contract owner")
     */
    function test_beacon_diamondCutByNonOwner_reverts() public {
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](0);

        address stranger = makeAddr("stranger2");
        vm.prank(stranger);
        vm.expectRevert("DiamondStorageLib: Must be contract owner");
        IDiamondCut(address(beacon)).diamondCut(cut, address(0), "");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 6. Beacon — implementation(selector) returns registered facet
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice After construction, implementation(diamondCut.selector) returns
     *         the MockDiamondCutFacet address.
     *
     * Behavior pin: SmartLoanDiamondBeacon.implementation(bytes4) (line 64)
     *   ds.selectorToFacetAndPosition[funcSignature].facetAddress
     *
     * diamondCut selector (0x1f931c1c) is in canBeExecutedWhenPaused, so the
     * notPausedOrUpgrading modifier allows the call even while paused.
     */
    function test_beacon_implementation_returnsRegisteredFacet() public {
        bytes4 sel = IDiamondCut.diamondCut.selector; // 0x1f931c1c
        address returned = beacon.implementation(sel);
        assertEq(
            returned,
            address(mockCutFacet),
            "implementation(diamondCut.selector) should return MockDiamondCutFacet"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 7. Beacon — implementation(unknownSelector) reverts
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Querying implementation() for an unregistered selector reverts.
     *
     * Behavior pin: SmartLoanDiamondBeacon.implementation(bytes4) (line 69)
     *   require(facet != address(0), "Diamond: Function does not exist")
     *
     * The beacon is unpaused first so that the notPausedOrUpgrading modifier
     * does not fire before the "does not exist" check — we want to pin the
     * "does not exist" revert, not the "paused" revert.
     */
    function test_beacon_implementation_unregisteredSelector_reverts() public {
        _unpause();
        bytes4 unknown = bytes4(keccak256("neverRegistered()"));
        vm.expectRevert("Diamond: Function does not exist");
        beacon.implementation(unknown);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 8. Beacon — two-step ownership transfer (happy path)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice proposeBeaconOwnershipTransfer + acceptBeaconOwnership completes
     *         ownership handover.
     *
     * Behavior pin: SmartLoanDiamondBeacon.sol:113-118
     *   proposeBeaconOwnershipTransfer: enforceIsContractOwner, setProposedOwner
     *   acceptBeaconOwnership: require(proposedOwner == msg.sender), setContractOwner
     */
    function test_beacon_twoStepOwnership_proposeAndAccept() public {
        vm.prank(owner);
        beacon.proposeBeaconOwnershipTransfer(newOwner);
        assertEq(_readBeaconProposedOwner(), newOwner, "proposedOwner not set");

        vm.prank(newOwner);
        beacon.acceptBeaconOwnership();
        assertEq(_readBeaconContractOwner(),  newOwner,    "contractOwner not updated");
        assertEq(_readBeaconProposedOwner(),  address(0),  "proposedOwner not cleared");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 9. Beacon — wrong acceptor cannot claim ownership
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice acceptBeaconOwnership() called by an address other than the
     *         proposed owner reverts.
     *
     * Behavior pin: SmartLoanDiamondBeacon.sol:114
     *   require(DiamondStorageLib.proposedOwner() == msg.sender,
     *           "Only a proposed user can accept ownership")
     */
    function test_beacon_twoStepOwnership_wrongAcceptor_reverts() public {
        vm.prank(owner);
        beacon.proposeBeaconOwnershipTransfer(newOwner);

        address impostor = makeAddr("impostor");
        vm.prank(impostor);
        vm.expectRevert("Only a proposed user can accept ownership");
        beacon.acceptBeaconOwnership();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 10. Beacon — two-step pauseAdmin transfer
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice proposeBeaconPauseAdminOwnershipTransfer + acceptBeaconPauseAdminOwnership
     *         hands the pauseAdmin role to a new address.
     *
     * Behavior pin: SmartLoanDiamondBeacon.sol:105-127
     *   proposeBeaconPauseAdminOwnershipTransfer: enforceIsPauseAdmin, setProposedPauseAdmin
     *   acceptBeaconPauseAdminOwnership: require(proposedPauseAdmin == msg.sender)
     */
    function test_beacon_pauseAdmin_twoStep() public {
        address newAdmin = makeAddr("newPauseAdmin");

        vm.prank(owner); // owner == pauseAdmin at construction
        beacon.proposeBeaconPauseAdminOwnershipTransfer(newAdmin);
        assertEq(_readBeaconProposedPauseAdmin(), newAdmin, "proposedPauseAdmin not set");

        vm.prank(newAdmin);
        beacon.acceptBeaconPauseAdminOwnership();
        assertEq(_readBeaconPauseAdmin(),          newAdmin,    "pauseAdmin not updated");
        assertEq(_readBeaconProposedPauseAdmin(),  address(0),  "proposedPauseAdmin not cleared");

        // New admin can now unpause (old owner cannot).
        vm.prank(newAdmin);
        IDiamondCut(address(beacon)).unpause();
        assertTrue(beacon.getStatus(), "new pauseAdmin should be able to unpause");

        vm.prank(owner);
        vm.expectRevert("DiamondStorageLib: Must be contract pauseAdmin");
        IDiamondCut(address(beacon)).pause(); // old owner is no longer pauseAdmin
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 11. OwnershipFacet — view functions return correct DiamondStorage state
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice After cutting OwnershipFacet into the beacon, the view functions
     *         owner() and proposedOwner() reflect DiamondStorageLib.SmartLoanStorage.
     *
     *         pauseAdmin() and proposedPauseAdmin() are also read-back tested.
     *
     * Behavior pin: OwnershipFacet reads DiamondStorageLib.smartLoanStorage()
     *   which shares the same keccak slot as the beacon's setContractOwner() writes.
     *   Therefore owner() == the address passed to the beacon constructor.
     */
    function test_ownershipFacet_viewFunctions_reflectBeaconStorage() public {
        _cutOwnershipFacet();
        _unpause();

        IOwnershipFacet proxy = IOwnershipFacet(address(beacon));

        assertEq(proxy.owner(),               owner,      "owner() mismatch");
        assertEq(proxy.proposedOwner(),        address(0), "proposedOwner() should be zero initially");
        assertEq(proxy.pauseAdmin(),           owner,      "pauseAdmin() mismatch");
        assertEq(proxy.proposedPauseAdmin(),   address(0), "proposedPauseAdmin() should be zero initially");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 12. OwnershipFacet — proposeOwnershipTransfer + acceptOwnership (happy path)
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Two-step Prime-Account ownership transfer via OwnershipFacet.
     *
     *         proposeOwnershipTransfer() checks getLoanForOwner(proposed) == address(0)
     *         via MockSmartLoansFactory etched at FACTORY_ADDR.
     *         acceptOwnership() calls changeOwnership() (no-op in mock).
     *
     * Behavior pin: OwnershipFacet.sol:14-29
     *   proposeOwnershipTransfer: enforceIsContractOwner, getLoanForOwner check,
     *                              setProposedOwner
     *   acceptOwnership:          require proposedOwner == msg.sender, setContractOwner
     */
    function test_ownershipFacet_proposeAndAccept() public {
        _cutOwnershipFacet();
        _unpause();

        IOwnershipFacet proxy = IOwnershipFacet(address(beacon));

        vm.prank(owner);
        proxy.proposeOwnershipTransfer(newOwner);
        assertEq(proxy.proposedOwner(), newOwner, "proposedOwner not set");

        vm.prank(newOwner);
        proxy.acceptOwnership();
        assertEq(proxy.owner(), newOwner, "owner not updated after accept");
        assertEq(proxy.proposedOwner(), address(0), "proposedOwner not cleared");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Utilities
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev Slice a bytes array: returns data[start .. start+len].
    function slice(bytes memory data, uint256 start, uint256 len)
        internal
        pure
        returns (bytes memory result)
    {
        result = new bytes(len);
        for (uint256 i; i < len; i++) {
            result[i] = data[start + i];
        }
    }
}
