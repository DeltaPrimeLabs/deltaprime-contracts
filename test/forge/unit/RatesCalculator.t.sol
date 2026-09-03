// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

import "forge-std/Test.sol";
import {WavaxVariableUtilisationRatesCalculator} from
    "../../../contracts/deployment/avalanche/WavaxVariableUtilisationRatesCalculator.sol";
import {UsdcVariableUtilisationRatesCalculator} from
    "../../../contracts/deployment/avalanche/UsdcVariableUtilisationRatesCalculator.sol";

/**
 * @title  RatesCalculatorTest
 * @notice Suite 3.3 — piecewise-linear borrow/deposit rate curves.
 *
 * Tests the WAVAX and USDC (Avalanche) VariableUtilisationRatesCalculator contracts.
 * All expected values are derived from the contract constants (file:line citations
 * below) using the piecewise formula:
 *   seg1  u ∈ [0, BP1]  : SLOPE_1 * u / 1e18 + OFFSET_1
 *   seg2  u ∈ (BP1, BP2]: SLOPE_2 * u / 1e18 - OFFSET_2
 *   seg3  u ∈ (BP2, BP3]: SLOPE_3 * u / 1e18 - OFFSET_3
 *   seg4  u ∈ (BP3, 1)  : SLOPE_4 * u / 1e18 - OFFSET_4
 *   u >= 1              : MAX_RATE
 *
 * WAVAX constants (WavaxVariableUtilisationRatesCalculator.sol:17-40):
 *   SLOPE_1=0.05e18  OFFSET_1=0    BP1=0.6e18
 *   SLOPE_2=0.20e18  OFFSET_2=0.09e18  BP2=0.8e18
 *   SLOPE_3=0.50e18  OFFSET_3=0.33e18  BP3=0.9e18
 *   SLOPE_4=29.8e18  OFFSET_4=26.7e18  MAX_RATE=3.1e18  spread=1e12
 *
 * USDC constants (UsdcVariableUtilisationRatesCalculator.sol:17-39):
 *   SLOPE_1=0.167e18  OFFSET_1=0    BP1=0.6e18
 *   SLOPE_2=0.25e18   OFFSET_2=0.05e18  BP2=0.8e18
 *   SLOPE_3=1e18      OFFSET_3=0.65e18  BP3=0.9e18
 *   SLOPE_4=6.5e18    OFFSET_4=5.6e18   MAX_RATE=0.9e18  spread=1e12
 */
contract RatesCalculatorTest is Test {
    WavaxVariableUtilisationRatesCalculator internal wavax;
    UsdcVariableUtilisationRatesCalculator  internal usdc;

    function setUp() public {
        wavax = new WavaxVariableUtilisationRatesCalculator();
        usdc  = new UsdcVariableUtilisationRatesCalculator();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 1 — WAVAX borrowing rate at utilisation = 0
    //
    // Pin: WavaxVariableUtilisationRatesCalculator.sol:92
    //   if (totalDeposits == 0) return OFFSET_1;
    //   OFFSET_1 = 0, so rate = 0 for zero deposits.
    //   For zero loans with non-zero deposits: u = 0, seg1 = SLOPE_1 * 0 / 1e18 + 0 = 0.
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_borrowRate_zero_utilisation() public {
        // totalDeposits == 0 → early-return OFFSET_1 = 0
        assertEq(wavax.calculateBorrowingRate(0, 0), 0, "zero deposits: OFFSET_1=0");
        // totalLoans == 0 → u=0, segment-1: 0.05*0 = 0
        assertEq(wavax.calculateBorrowingRate(0, 1e18), 0, "zero loans: u=0 rate=0");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 2 — WAVAX borrowing rate at exact breakpoints
    //
    // Pin: WavaxVariableUtilisationRatesCalculator.sol:98-108
    //   u = 0.6e18 (BP1, segment 1 branch ≤BP1):  0.05*0.6 = 0.03e18
    //   u = 0.8e18 (BP2, segment 2 branch ≤BP2):  0.20*0.8 − 0.09 = 0.07e18
    //   u = 0.9e18 (BP3, segment 3 branch ≤BP3):  0.50*0.9 − 0.33 = 0.12e18
    //
    // The curve is continuous at breakpoints: both adjacent segments evaluate to
    // the same value when u equals the breakpoint exactly.
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_borrowRate_exact_breakpoints() public {
        assertEq(wavax.calculateBorrowingRate(0.6e18, 1e18), 0.03e18, "BP1=0.6: seg1 endpoint = 0.03");
        assertEq(wavax.calculateBorrowingRate(0.8e18, 1e18), 0.07e18, "BP2=0.8: seg2 endpoint = 0.07");
        assertEq(wavax.calculateBorrowingRate(0.9e18, 1e18), 0.12e18, "BP3=0.9: seg3 endpoint = 0.12");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 3 — WAVAX borrowing rate at segment midpoints
    //
    // seg1 mid u=0.30: 0.05 * 0.30 = 0.015e18
    // seg2 mid u=0.70: 0.20 * 0.70 − 0.09 = 0.14 − 0.09 = 0.05e18
    // seg3 mid u=0.85: 0.50 * 0.85 − 0.33 = 0.425 − 0.33 = 0.095e18
    // seg4 mid u=0.95: 29.8 * 0.95 − 26.7 = 28.31 − 26.7 = 1.61e18
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_borrowRate_segment_midpoints() public {
        assertEq(wavax.calculateBorrowingRate(0.30e18, 1e18), 0.015e18, "u=0.30 seg1-mid");
        assertEq(wavax.calculateBorrowingRate(0.70e18, 1e18), 0.05e18,  "u=0.70 seg2-mid");
        assertEq(wavax.calculateBorrowingRate(0.85e18, 1e18), 0.095e18, "u=0.85 seg3-mid");
        assertEq(wavax.calculateBorrowingRate(0.95e18, 1e18), 1.61e18,  "u=0.95 seg4-mid");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 4 — WAVAX borrowing rate caps at MAX_RATE for u ≥ 1
    //
    // Pin: WavaxVariableUtilisationRatesCalculator.sol:96-97
    //   if (poolUtilisation >= 1e18) return MAX_RATE;   MAX_RATE = 3.1e18
    //
    // Over-utilisation (accrued interest can push loans > deposits).
    // totalDeposits==0 is a separate early-return (OFFSET_1=0), not MAX_RATE.
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_borrowRate_over_utilisation_caps_at_max() public {
        assertEq(wavax.calculateBorrowingRate(1e18,  1e18), 3.1e18, "u=1.0: MAX_RATE=3.1e18");
        assertEq(wavax.calculateBorrowingRate(1.5e18, 1e18), 3.1e18, "u=1.5: MAX_RATE=3.1e18");
        assertEq(wavax.calculateBorrowingRate(2e18,  1e18), 3.1e18, "u=2.0: MAX_RATE=3.1e18");
        // totalDeposits==0 returns OFFSET_1=0, NOT MAX_RATE
        assertEq(wavax.calculateBorrowingRate(1e18,  0),   0,       "zero deposits: OFFSET_1=0");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 5 — WAVAX monotonicity sweep
    //
    // borrowRate(u1) ≤ borrowRate(u2) whenever u1 < u2.
    // Sweep from 0 to 1e18 in 0.05e18 steps (21 points).
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_borrowRate_monotone_sweep() public {
        uint256 prevRate = 0;
        for (uint256 u = 0; u <= 1e18; u += 0.05e18) {
            uint256 rate = wavax.calculateBorrowingRate(u, 1e18);
            assertGe(rate, prevRate, "monotone: rate must not decrease");
            prevRate = rate;
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 6 — WAVAX deposit rate — exact formula at three utilisation points
    //
    // Pin: WavaxVariableUtilisationRatesCalculator.sol:70-78
    //   if (_totalLoans >= _totalDeposits) → MAX_RATE * (1e18-spread) / 1e18
    //   else → borrowRate * (1e18-spread) * totalLoans / (totalDeposits * 1e18)
    //
    // Relationship: depositRate = borrowRate × (1−spread) × utilisation
    //   (the protocol invariant: deposits×depositRate ≈ loans×borrowRate×(1−spread))
    //
    // Verified at u=0.30, 0.60, 0.80 with deposits=1e18.
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_depositRate_exact_formula() public {
        uint256 spread = wavax.spread(); // 1e12

        // u=0.30: borrowRate=0.015e18; deposit=0.015*0.3*(1-1e-12)*1e18=4499999986500000
        _assertDepositRateEq(0.30e18, 1e18, spread);
        // u=0.60: borrowRate=0.03e18;  deposit=0.03*0.6*(1-1e-12)*1e18=17999982000000000
        _assertDepositRateEq(0.60e18, 1e18, spread);
        // u=0.80: borrowRate=0.07e18;  deposit=0.07*0.8*(1-1e-12)*1e18=55999944800000000
        _assertDepositRateEq(0.80e18, 1e18, spread);
    }

    /// Asserts depositRate equals borrowRate * (1e18-spread) * loans / (deposits * 1e18).
    function _assertDepositRateEq(uint256 loans, uint256 deposits, uint256 spread) internal {
        uint256 borrowRate  = wavax.calculateBorrowingRate(loans, deposits);
        uint256 depositRate = wavax.calculateDepositRate(loans, deposits);
        uint256 expected    = borrowRate * (1e18 - spread) * loans / (deposits * 1e18);
        assertEq(depositRate, expected, "depositRate exact formula mismatch");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 7 — WAVAX deposit rate at over-utilisation
    //
    // Pin: WavaxVariableUtilisationRatesCalculator.sol:73-74
    //   if (_totalLoans >= _totalDeposits)
    //     return MAX_RATE * (1e18 - spread) / 1e18;
    //   MAX_RATE=3.1e18, spread=1e12 → 3.1e18 * (1e18-1e12) / 1e18 = 3099996900000000000
    // ══════════════════════════════════════════════════════════════════════════
    function test_wavax_depositRate_over_utilisation() public {
        uint256 spread   = wavax.spread(); // 1e12
        uint256 expected = uint256(3.1e18) * (1e18 - spread) / 1e18;
        assertEq(expected, 3_099_996_900_000_000_000, "expected value sanity-check");

        assertEq(wavax.calculateDepositRate(1e18,  1e18), expected, "u=1.0: deposit rate = MAX_RATE*(1-spread)");
        assertEq(wavax.calculateDepositRate(2e18,  1e18), expected, "u=2.0: same cap");
        // Boundary: loans < deposits → formula, not cap
        assertLt(wavax.calculateDepositRate(0.999e18, 1e18), expected, "u<1: below cap");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 8 — USDC vs WAVAX: different constants, different curve shape
    //
    // USDC breakpoints (UsdcVariableUtilisationRatesCalculator.sol:17-39):
    //   u=0.60: 0.167 * 0.60 = 0.1002e18   (WAVAX: 0.03e18 — USDC is higher)
    //   u=0.80: 0.25*0.8 − 0.05 = 0.15e18  (WAVAX: 0.07e18)
    //   u=0.90: 1.0*0.9 − 0.65 = 0.25e18   (WAVAX: 0.12e18)
    //   MAX_RATE = 0.9e18                   (WAVAX: 3.1e18 — USDC is LOWER at max)
    // ══════════════════════════════════════════════════════════════════════════
    function test_usdc_breakpoints_and_comparison_with_wavax() public {
        // USDC exact breakpoint values
        assertEq(usdc.calculateBorrowingRate(0.60e18, 1e18), 0.1002e18, "USDC u=0.60: 0.167*0.6=0.1002");
        assertEq(usdc.calculateBorrowingRate(0.80e18, 1e18), 0.15e18,   "USDC u=0.80: 0.25*0.8-0.05=0.15");
        assertEq(usdc.calculateBorrowingRate(0.90e18, 1e18), 0.25e18,   "USDC u=0.90: 1.0*0.9-0.65=0.25");
        assertEq(usdc.calculateBorrowingRate(1e18,    1e18), 0.9e18,    "USDC MAX_RATE=0.9e18");

        // Cross-contract comparison
        assertLt(wavax.calculateBorrowingRate(0.60e18, 1e18),
                 usdc.calculateBorrowingRate(0.60e18,  1e18), "WAVAX has lower rate than USDC at 60% util");
        assertGt(wavax.calculateBorrowingRate(1e18, 1e18),
                 usdc.calculateBorrowingRate(1e18,  1e18),    "WAVAX MAX_RATE 3.1e18 > USDC 0.9e18");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Test 9 — USDC monotonicity sweep (independent of WAVAX)
    // ══════════════════════════════════════════════════════════════════════════
    function test_usdc_borrowRate_monotone_sweep() public {
        uint256 prevRate = 0;
        for (uint256 u = 0; u <= 1e18; u += 0.05e18) {
            uint256 rate = usdc.calculateBorrowingRate(u, 1e18);
            assertGe(rate, prevRate, "USDC monotone: rate must not decrease");
            prevRate = rate;
        }
    }
}
