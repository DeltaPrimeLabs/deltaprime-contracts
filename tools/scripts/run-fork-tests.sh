#!/usr/bin/env bash
#
# run-fork-tests.sh — run the DeltaPrime Forge FORK test tier, split into two
# trustworthiness classes:
#
#   GATING (deterministic)  — attach to the live diamonds and exercise facets whose
#       outcome does NOT depend on live DEX depth or an external routing API. These
#       are reproducible and SHOULD gate merges. They honour an optional pinned fork
#       block (<CHAIN>_FORK_BLOCK) for full determinism — CI sets it against an
#       archive RPC; locally it defaults to latest (public RPC always serves head).
#
#   LIVE-SWAP (non-deterministic) — ParaSwap (live API route via ffi), SwapDebt
#       (swaps via ParaSwap) and the YieldYak on-chain aggregator swaps. Their result
#       depends on live market state at the fork head, so they CANNOT be pinned and
#       are inherently flaky (a route/quote that was valid minutes ago can revert
#       SwapFailed / Insufficient amountOut). They run at LATEST with a retry and are
#       INFORMATIONAL — they must NOT gate merges (a flaky live route blocking an
#       unrelated PR is exactly what this split prevents).
#
# These tests are NETWORK-BOUND and slow; gated (RUN_GMX_FORK / RUN_FORK_AUDIT + the
# chain config) so they SKIP in the default `forge test` / default CI.
#
# EVM version: whole tier under FOUNDRY_EVM_VERSION=cancun (superset of london/
# shanghai) + --ffi (ParaSwap live route data).
#
# Usage:
#   tools/scripts/run-fork-tests.sh [chain] [tier]
#     chain : all (default) | avalanche | arbitrum | audit
#     tier  : all (default) | gating | liveswap
#   e.g.
#   tools/scripts/run-fork-tests.sh avalanche gating     # deterministic, merge-gating
#   tools/scripts/run-fork-tests.sh arbitrum  liveswap   # live-swap, informational (retry)
#   tools/scripts/run-fork-tests.sh                      # everything, both tiers (local)
#
set -uo pipefail
cd "$(dirname "$0")/../.."
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

WHICH="${1:-all}"
TIER="${2:-all}"
GATING_FAIL=0
LIVESWAP_FAIL=0

# Live-swap test files (live ParaSwap routes / live DEX quotes — non-deterministic).
# Everything ELSE under fork/<chain>/ is deterministic (gating, pinnable).
AVAX_LIVESWAP='test/forge/fork/avalanche/{ParaSwap,YieldYakSwap}Fork.t.sol'
ARB_LIVESWAP='test/forge/fork/arbitrum/{ParaSwap,SwapDebt,YieldYakSwap}Fork.t.sol'

restore_config() { node tools/scripts/select-chain-config.js test >/dev/null 2>&1 || true; }
trap restore_config EXIT

do_gating()   { [ "$TIER" = "gating" ]   || [ "$TIER" = "all" ]; }
do_liveswap() { [ "$TIER" = "liveswap" ] || [ "$TIER" = "all" ]; }

# Deterministic gating group: inherits <CHAIN>_FORK_BLOCK from the environment (CI
# pins it; unset locally → latest). A failure is FATAL (gates merge).
run_gating() {
  local config="$1"; shift
  local label="$1"; shift
  local pin="latest"
  if [ "$config" = "avalanche" ]; then pin="${AVALANCHE_FORK_BLOCK:-latest}"; fi
  if [ "$config" = "arbitrum" ]; then pin="${ARBITRUM_FORK_BLOCK:-latest}"; fi
  echo ""
  echo "======================================================================"
  echo "  GATING: $label   (config=$config, evm=cancun, ffi=on, fork-block=$pin)"
  echo "======================================================================"
  node tools/scripts/select-chain-config.js "$config" >/dev/null
  FOUNDRY_EVM_VERSION=cancun RUN_GMX_FORK=true RUN_FORK_AUDIT=true \
    forge test --ffi "$@" -vv
  local rc=$?
  if [ $rc -ne 0 ]; then echo "GATING GROUP FAILED: $label (rc=$rc)"; GATING_FAIL=1; fi
}

# Live-swap group: forced to LATEST (FORK_BLOCK unset — a pinned block would never
# match a live API route / quote) with up to 3 attempts. Result is reported but is
# NON-gating; CI runs this in a continue-on-error job behind a non-required status.
run_liveswap() {
  local config="$1"; shift
  local label="$1"; shift
  echo ""
  echo "======================================================================"
  echo "  LIVE-SWAP (informational, latest, retry): $label"
  echo "======================================================================"
  node tools/scripts/select-chain-config.js "$config" >/dev/null
  local attempt rc=1
  for attempt in 1 2 3; do
    echo "  --- live-swap attempt $attempt/3: $label ---"
    env -u ARBITRUM_FORK_BLOCK -u AVALANCHE_FORK_BLOCK \
      FOUNDRY_EVM_VERSION=cancun RUN_GMX_FORK=true RUN_FORK_AUDIT=true \
      forge test --ffi "$@" -vv
    rc=$?
    [ $rc -eq 0 ] && break
    echo "  live-swap attempt $attempt failed (rc=$rc) — live market state; retrying"
  done
  if [ $rc -ne 0 ]; then echo "LIVE-SWAP GROUP FAILED after retries: $label (rc=$rc)"; LIVESWAP_FAIL=1; fi
}

# --- Avalanche -------------------------------------------------------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "avalanche" ]; then
  do_gating && run_gating avalanche "AVALANCHE deterministic" \
    --match-path 'test/forge/fork/avalanche/*.t.sol' --no-match-path "$AVAX_LIVESWAP"
  do_liveswap && run_liveswap avalanche "AVALANCHE live-swap" \
    --match-path "$AVAX_LIVESWAP"
fi

# --- Arbitrum: SP6 fork/arbitrum/ + SP5 top-level Gmx*.t.sol ---------------------
if [ "$WHICH" = "all" ] || [ "$WHICH" = "arbitrum" ]; then
  do_gating && run_gating arbitrum "ARBITRUM deterministic (SP6)" \
    --match-path 'test/forge/fork/arbitrum/*.t.sol' --no-match-path "$ARB_LIVESWAP"
  do_gating && run_gating arbitrum "ARBITRUM GMX lifecycle (SP5)" \
    --match-path 'test/forge/fork/Gmx*.t.sol'
  do_liveswap && run_liveswap arbitrum "ARBITRUM live-swap" \
    --match-path "$ARB_LIVESWAP"
fi

# --- DiamondLoupe audit (config-agnostic; deterministic) -------------------------
if [ "$WHICH" = "audit" ]; then
  run_gating test "DiamondLoupe AUDIT (both chains)" \
    --match-path 'test/forge/fork/DiamondLoupeAudit.t.sol'
fi

restore_config
echo ""
if [ $GATING_FAIL -ne 0 ]; then
  echo "FORK TIER (gating): FAILED — see output above."
  exit 1
fi
if [ "$TIER" = "liveswap" ] && [ $LIVESWAP_FAIL -ne 0 ]; then
  # Only propagate live-swap failure when explicitly running the live-swap tier
  # (so its informational CI status reflects reality). In 'all' mode it is non-fatal.
  echo "LIVE-SWAP TIER: FAILED after retries (informational, non-gating)."
  exit 1
fi
if [ $LIVESWAP_FAIL -ne 0 ]; then
  echo "FORK TIER: gating OK; live-swap had failures (informational, non-gating)."
else
  echo "FORK TIER: OK (config restored to test)."
fi
exit 0
