// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import {AvalancheGmxForkFixture} from "../../fixtures/AvalancheGmxForkFixture.sol";
import {SmartLoanViewFacet} from "../../../../contracts/facets/SmartLoanViewFacet.sol";

/**
 * SP6 W1 feasibility spike — Avalanche live-diamond GMX fork fixture.
 *
 * Proves the {AvalancheGmxForkFixture} works end-to-end on a live Avalanche fork: it
 * attaches to the real prod diamond, pranks the (separate) beacon owner + pauseAdmin to
 * Replace-cut the signer-override solvency facet, creates a Prime Account on the ungated
 * prod factory, and funds it with real WAVAX as "AVAX" collateral. The signer-override is
 * also verified inside setUp (a wrapped getPrices(AVAX) with our 5 test signers must
 * validate). The Avalanche counterpart of the Arbitrum `testFixtureFundsAccount` spike.
 *
 * Gated — SKIPS under the default test config (needs RUN_GMX_FORK=true + avalanche chain
 * config). Run:
 *   node tools/scripts/select-chain-config.js avalanche >/dev/null &&
 *   RUN_GMX_FORK=true forge test --match-path 'test/forge/fork/avalanche/GmxForkSpike.t.sol' -vvvv
 */
contract GmxForkSpikeTest is AvalancheGmxForkFixture {
    function testFixtureFundsAccount() public {
        // funded in setUp; assert AVAX collateral is present on the Prime Account.
        assertGt(SmartLoanViewFacet(loan).getBalance(bytes32("AVAX")), 0, "AVAX collateral not funded");
    }
}
