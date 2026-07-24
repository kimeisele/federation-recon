#!/usr/bin/env bash
# Deep determinism check (FR-CON-012 / falsifier F-01).
#
# Establishes a reproduce fixpoint and proves it is stable: running the full
# --reproduce pipeline twice against the committed pins must yield a
# BYTE-IDENTICAL artifact set. This is the property that lets any independent
# agent clone the repo, re-run --reproduce, and verify the committed evidence
# was not tampered with.
#
# Also verifies ORDER INDEPENDENCE: with per-procedure pin namespaces (v2.1),
# running v0-then-v1 and v1-then-v0 must produce identical pins. This resolves
# the last-writer-wins problem documented in Issue #18.
#
# Requires network + gh (fetches pinned repository contents), so it is run
# manually or on a schedule, NOT on every PR. The fast offline PR gate is
# scripts/ci-checks.sh.
set -uo pipefail
cd "$(dirname "$0")/.."

snap() {
  find pins claims evidence drift findings coverage digest STATE.md -type f 2>/dev/null \
    | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

snap_pins() {
  find pins -name '*.json' -type f 2>/dev/null \
    | sort | xargs shasum -a 256 | shasum -a 256 | awk '{print $1}'
}

run_reproduce() {
  RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce      >/dev/null 2>&1 || return 1
  RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce >/dev/null 2>&1 || return 1
  bash scripts/compose-digest.sh                                  >/dev/null 2>&1 || return 1
}

run_reproduce_reverse() {
  RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce >/dev/null 2>&1 || return 1
  RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce      >/dev/null 2>&1 || return 1
  bash scripts/compose-digest.sh                                  >/dev/null 2>&1 || return 1
}

echo "=== Phase 1: Order-independence check (v0->v1 vs v1->v0 pins) ==="
run_reproduce || { echo "FAIL: reproduce (v0->v1) pipeline errored"; exit 1; }
A="$(snap_pins)"
echo "  v0->v1 pins hash: $A"

run_reproduce_reverse || { echo "FAIL: reproduce (v1->v0) pipeline errored"; exit 1; }
B="$(snap_pins)"
echo "  v1->v0 pins hash: $B"

if [ "$A" = "$B" ]; then
  echo "  PASS: pins are order-independent (v0->v1 == v1->v0)"
else
  echo "FAIL: pin order-dependence detected — per-procedure namespace violated"
  exit 1
fi

echo ""
echo "=== Phase 2: Reproduce stability (byte-identical artifact set) ==="

echo "Establishing reproduce fixpoint..."
run_reproduce || { echo "FAIL: reproduce pipeline errored"; exit 1; }
X="$(snap)"
echo "  fixpoint hash: $X"

echo "Verifying stability (second reproduce pass)..."
run_reproduce || { echo "FAIL: reproduce pipeline errored"; exit 1; }
Y="$(snap)"
echo "  verify hash:   $Y"

echo "Validating..."
bash scripts/validate-artifacts.sh --strict >/dev/null 2>&1 \
  && echo "  strict validation: OK" \
  || { echo "FAIL: strict validation failed"; exit 1; }

if [ "$X" = "$Y" ]; then
  echo "PASS: artifact set is byte-identical across reproduce (F-01 holds)"
  exit 0
else
  echo "FAIL: reproduce is not byte-identical — determinism (FR-CON-012) violated"
  exit 1
fi
