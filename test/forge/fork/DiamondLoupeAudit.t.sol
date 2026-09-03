// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {IDiamondLoupe} from "../../../contracts/interfaces/IDiamondLoupe.sol";

// Facets imported ONLY for their compile-time `.selector` constants (no deployment).
import {SmartLoanViewFacet} from "../../../contracts/facets/SmartLoanViewFacet.sol";
import {AssetsOperationsFacet} from "../../../contracts/facets/AssetsOperationsFacet.sol";
import {SmartLoanLiquidationFacet} from "../../../contracts/facets/SmartLoanLiquidationFacet.sol";
import {SolvencyFacetProd} from "../../../contracts/facets/SolvencyFacetProd.sol";

// GMX entrypoint + callback selectors come straight from the interfaces (signature-derived,
// so chain-agnostic: the Arbitrum and Avalanche facets implement these identical signatures).
import {IGmxV2Facet} from "../../../contracts/interfaces/facets/IGmxV2Facet.sol";
import {IDepositCallbackReceiver} from "../../../contracts/interfaces/gmx-v2/IDepositCallbackReceiver.sol";
import {IWithdrawalCallbackReceiver} from "../../../contracts/interfaces/gmx-v2/IWithdrawalCallbackReceiver.sol";
import {IGlvDepositCallbackReceiver} from "../../../contracts/interfaces/gmx-v2/IGlvDepositCallbackReceiver.sol";
import {IGlvWithdrawalCallbackReceiver} from "../../../contracts/interfaces/gmx-v2/IGlvWithdrawalCallbackReceiver.sol";

/**
 * @title DiamondLoupeAudit
 * @notice SP6 Task 1 — live-diamond facet & selector audit for BOTH DeltaPrime chains.
 *
 * This is the spec §6 "FacetSelectors registry + live-loupe diff" deliverable: it reads
 * the EIP-2535 DiamondLoupe off the REAL production beacons (by hardcoded address) and
 *   (a) snapshots the full facet -> selector-count map and asserts structural sanity
 *       (every registered selector resolves to exactly one non-zero facet);
 *   (b) asserts that every selector our Forge fixtures/suites RELY ON is registered and
 *       resolves to a non-zero facet (a MISSING fixture-relied selector = real drift);
 *   (c) resolves the open question of whether the GLV callback selectors
 *       (afterGlv{Deposit,Withdrawal}{Execution,Cancellation}) are cut into prod.
 *
 * READ-ONLY: only loupe view calls, no transactions, no state mutation.
 *
 * Config-agnostic: reads the beacons by LITERAL address, so it does NOT require the
 * arbitrum/avalanche hardhat chain config (DeploymentConstants is never touched).
 *
 * Gated behind RUN_FORK_AUDIT=true. Under a normal `forge test` it SKIPS (vm.skip), so
 * the default 194-test suite stays green and offline.
 *
 *   RUN_FORK_AUDIT=true forge test --match-path 'test/forge/fork/DiamondLoupeAudit.t.sol' -vv
 */
contract DiamondLoupeAuditTest is Test {
    // ---- live production beacons (DiamondLoupe is exposed on the beacon) ----
    address internal constant ARB_BEACON = 0x62Cf82FB0484aF382714cD09296260edc1DC0c6c;
    address internal constant AVAX_BEACON = 0x2916B3bf7C35bd21e63D01C93C62FB0d4994e56D;

    // Current production facet counts (recon 2026-06-18). Pinned EXACT via assertEq: ANY drift
    // — a facet ADD or REMOVAL — fails the test loudly and surfaces the actual count in the log,
    // so a future diamondCut that changes the diamond shape is caught on the next audit run.
    uint256 internal constant ARB_FACET_COUNT = 27;
    uint256 internal constant AVAX_FACET_COUNT = 26;

    string internal constant AVAX_DEFAULT_RPC = "https://api.avax.network/ext/bc/C/rpc";

    function _forkAuditActive() internal returns (bool) {
        return vm.envOr("RUN_FORK_AUDIT", false);
    }

    // ---------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------

    function testArbitrumDiamondAudit() public {
        if (!_forkAuditActive()) {
            vm.skip(true);
            return;
        }
        // Symmetric with the Avalanche audit: default to the public endpoint so the
        // audit runs without a secret (CI sets a dedicated archive RPC).
        vm.createSelectFork(vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc")));
        IDiamondLoupe loupe = IDiamondLoupe(ARB_BEACON);

        _auditStructure("Arbitrum", loupe, ARB_FACET_COUNT);
        _auditFixtureSelectors("Arbitrum", loupe);

        // (c) GLV-callback resolution. RESOLVED 2026-06-18: all FOUR GLV callbacks ARE cut
        //     into the live Arbitrum diamond (same facet that serves the GM deposit/withdrawal
        //     callbacks). Locked to that observed prod state — partial/total removal = drift.
        uint256 glvPresent = _auditGlvCallbacks("Arbitrum", loupe);
        assertEq(glvPresent, 4, "ARBITRUM GLV-callback drift: expected all 4 GLV callbacks registered on prod");
    }

    function testAvalancheDiamondAudit() public {
        if (!_forkAuditActive()) {
            vm.skip(true);
            return;
        }
        string memory rpc = vm.envOr("AVALANCHE_RPC_URL", AVAX_DEFAULT_RPC);
        vm.createSelectFork(rpc);
        IDiamondLoupe loupe = IDiamondLoupe(AVAX_BEACON);

        _auditStructure("Avalanche", loupe, AVAX_FACET_COUNT);
        _auditFixtureSelectors("Avalanche", loupe);

        // (c) GLV-callback resolution. RESOLVED 2026-06-18: NONE of the four GLV callbacks are
        //     cut into the live Avalanche diamond (they resolve to address(0)) — even though
        //     GmxV2CallbacksFacetAvalanche/GlvFacetAvalanche exist in source. This is a real
        //     per-chain divergence from Arbitrum (which has all four). Locked: a future GLV cut
        //     on Avalanche flips this to a visible, reviewable drift.
        uint256 glvPresent = _auditGlvCallbacks("Avalanche", loupe);
        assertEq(glvPresent, 0, "AVALANCHE GLV-callback drift: GLV callbacks now registered (were absent at audit time)");
    }

    // ---------------------------------------------------------------------------
    // (a) structural snapshot + sanity
    // ---------------------------------------------------------------------------

    function _auditStructure(string memory chain, IDiamondLoupe loupe, uint256 expected) internal {
        console2.log("==================================================================");
        console2.log(string.concat("DIAMOND LOUPE AUDIT  chain=", chain, "  block=", vm.toString(block.number)));
        console2.log(string.concat("beacon=", vm.toString(address(loupe))));
        console2.log("==================================================================");

        address[] memory addrs = loupe.facetAddresses();
        console2.log(string.concat("facetAddresses().length = ", vm.toString(addrs.length), "  (expected=", vm.toString(expected), ")"));
        // EXACT pin: a facet ADD or REMOVAL both fail here. The actual count is logged above so
        // the drift is visible in the failure output (do NOT relax this to a floor to make it pass).
        assertEq(addrs.length, expected, string.concat(chain, ": live facet count != recon baseline (diamond shape drifted)"));

        IDiamondLoupe.Facet[] memory fs = loupe.facets();
        assertEq(fs.length, addrs.length, string.concat(chain, ": facets() / facetAddresses() length mismatch"));

        uint256 totalSelectors;
        for (uint256 i = 0; i < fs.length; i++) {
            address fa = fs[i].facetAddress;
            bytes4[] memory sels = fs[i].functionSelectors;

            // Sanity: a registered facet is never the zero address and always serves >=1 selector.
            assertTrue(fa != address(0), string.concat(chain, ": zero-address facet registered"));
            assertGt(sels.length, 0, string.concat(chain, ": facet with zero selectors registered"));

            // Sanity: every selector resolves back to EXACTLY this non-zero facet.
            for (uint256 j = 0; j < sels.length; j++) {
                address resolved = loupe.facetAddress(sels[j]);
                assertTrue(resolved != address(0), string.concat(chain, ": registered selector resolves to address(0)"));
                assertEq(resolved, fa, string.concat(chain, ": selector resolves to a different facet than facets() reports"));
            }
            totalSelectors += sels.length;

            // Snapshot line: index | facet address | selector count | first selector (sample).
            console2.log(
                string.concat(
                    "facet[",
                    vm.toString(i),
                    "] ",
                    vm.toString(fa),
                    "  selectors=",
                    vm.toString(sels.length),
                    "  sample=",
                    vm.toString(abi.encodePacked(sels[0]))
                )
            );
        }
        console2.log(string.concat("TOTAL registered selectors = ", vm.toString(totalSelectors)));
        console2.log("------------------------------------------------------------------");
    }

    // ---------------------------------------------------------------------------
    // (b) fixture-relied selectors MUST be present
    // ---------------------------------------------------------------------------

    function _auditFixtureSelectors(string memory chain, IDiamondLoupe loupe) internal {
        console2.log(string.concat("[", chain, "] fixture-relied selectors (must all resolve non-zero):"));

        // SmartLoanViewFacet
        _mustResolve(chain, loupe, "SmartLoanViewFacet.initialize", SmartLoanViewFacet.initialize.selector);
        _mustResolve(chain, loupe, "SmartLoanViewFacet.getAllOwnedAssets", SmartLoanViewFacet.getAllOwnedAssets.selector);
        _mustResolve(chain, loupe, "SmartLoanViewFacet.getBalance", SmartLoanViewFacet.getBalance.selector);
        _mustResolve(chain, loupe, "SmartLoanViewFacet.getContractOwner", SmartLoanViewFacet.getContractOwner.selector);

        // AssetsOperationsFacet (Avalanche serves these via AssetsOperationsAvalancheFacet —
        // identical signatures, so identical selectors).
        _mustResolve(chain, loupe, "AssetsOperationsFacet.fund", AssetsOperationsFacet.fund.selector);
        _mustResolve(chain, loupe, "AssetsOperationsFacet.borrow", AssetsOperationsFacet.borrow.selector);
        _mustResolve(chain, loupe, "AssetsOperationsFacet.repay", AssetsOperationsFacet.repay.selector);

        // SmartLoanLiquidationFacet
        _mustResolve(chain, loupe, "SmartLoanLiquidationFacet.liquidate", SmartLoanLiquidationFacet.liquidate.selector);
        _mustResolve(chain, loupe, "SmartLoanLiquidationFacet.snapshotInsolvency", SmartLoanLiquidationFacet.snapshotInsolvency.selector);
        _mustResolve(chain, loupe, "SmartLoanLiquidationFacet.whitelistLiquidators", SmartLoanLiquidationFacet.whitelistLiquidators.selector);

        // SolvencyFacetProd (Avalanche serves these via SolvencyFacetProdAvalanche — identical sigs).
        _mustResolve(chain, loupe, "SolvencyFacetProd.getPrices", SolvencyFacetProd.getPrices.selector);
        _mustResolve(chain, loupe, "SolvencyFacetProd.isSolvent", SolvencyFacetProd.isSolvent.selector);
        _mustResolve(chain, loupe, "SolvencyFacetProd.getHealthRatio", SolvencyFacetProd.getHealthRatio.selector);
        _mustResolve(chain, loupe, "SolvencyFacetProd.getDebt", SolvencyFacetProd.getDebt.selector);
        _mustResolve(chain, loupe, "SolvencyFacetProd.getTotalValue", SolvencyFacetProd.getTotalValue.selector);

        // GMX V2 — ETH/USDC GM market exists on BOTH chains; callbacks are the async seam our
        // SP5 keeper-sim fork tests drive end-to-end.
        _mustResolve(chain, loupe, "IGmxV2Facet.depositEthUsdcGmxV2", IGmxV2Facet.depositEthUsdcGmxV2.selector);
        _mustResolve(chain, loupe, "IGmxV2Facet.withdrawEthUsdcGmxV2", IGmxV2Facet.withdrawEthUsdcGmxV2.selector);
        _mustResolve(chain, loupe, "IDepositCallbackReceiver.afterDepositExecution", IDepositCallbackReceiver.afterDepositExecution.selector);
        _mustResolve(chain, loupe, "IWithdrawalCallbackReceiver.afterWithdrawalExecution", IWithdrawalCallbackReceiver.afterWithdrawalExecution.selector);

        console2.log("------------------------------------------------------------------");
    }

    function _mustResolve(string memory chain, IDiamondLoupe loupe, string memory name, bytes4 sel) internal {
        address a = loupe.facetAddress(sel);
        console2.log(
            string.concat("  [", a == address(0) ? "MISSING" : "OK", "] ", name, " (", vm.toString(abi.encodePacked(sel)), ") -> ", vm.toString(a))
        );
        assertTrue(a != address(0), string.concat(chain, ": MISSING fixture-relied selector: ", name));
    }

    // ---------------------------------------------------------------------------
    // (c) GLV-callback resolution — returns how many of the four GLV callbacks resolve.
    // ---------------------------------------------------------------------------

    function _auditGlvCallbacks(string memory chain, IDiamondLoupe loupe) internal view returns (uint256 presentCount) {
        console2.log(string.concat("[", chain, "] GLV callback resolution:"));
        if (_probe(loupe, "afterGlvDepositExecution", IGlvDepositCallbackReceiver.afterGlvDepositExecution.selector)) presentCount++;
        if (_probe(loupe, "afterGlvDepositCancellation", IGlvDepositCallbackReceiver.afterGlvDepositCancellation.selector)) presentCount++;
        if (_probe(loupe, "afterGlvWithdrawalExecution", IGlvWithdrawalCallbackReceiver.afterGlvWithdrawalExecution.selector)) presentCount++;
        if (_probe(loupe, "afterGlvWithdrawalCancellation", IGlvWithdrawalCallbackReceiver.afterGlvWithdrawalCancellation.selector)) presentCount++;
        console2.log(
            string.concat(
                "  GLV VERDICT [",
                chain,
                "]: ",
                presentCount == 4
                    ? "ALL 4 PRESENT (GLV callbacks fully cut in)"
                    : presentCount == 0 ? "ABSENT (no GLV callbacks registered)" : "PARTIAL (some GLV callbacks registered)"
            )
        );
        console2.log("------------------------------------------------------------------");
    }

    function _probe(IDiamondLoupe loupe, string memory name, bytes4 sel) internal view returns (bool present) {
        address a = loupe.facetAddress(sel);
        present = a != address(0);
        console2.log(
            string.concat("  ", name, " (", vm.toString(abi.encodePacked(sel)), ") -> ", present ? "PRESENT " : "ABSENT  ", vm.toString(a))
        );
    }
}
