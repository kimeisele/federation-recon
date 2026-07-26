#!/usr/bin/env bash
# CI gate — fast, offline invariants that must hold for every commit.
#
#   1. Every committed artifact validates against schemas/*.json (strict).
#      Catches the class of defect where invalid JSON or a schema violation
#      ships because strict validation was not run before the merge claim.
#   2. Every pin under pins/*/ must correspond to a repository listed in the
#      manifest's adopted observed set (docs/repository-manifest.md). A pin for
#      an unlisted repository is a drift from the authorized scope and must
#      not ship silently — the manifest is the single source of truth.
#   3. The composed Federation Digest is idempotent: STATE.md and
#      digest/state-digest.json must be a pure function of the per-procedure
#      sub-digests (digest/<id>.json). If re-running the composer changes them,
#      the committed digest is stale or hand-edited — reject it.
#   4. Consultation artifact gate: any PR whose diff touches CLAUDE.md,
#      docs/founding-package-v0.2.md, or docs/*-adr.md must carry a committed,
#      verbatim consultation transcript from an independent cross-provider
#      reviewer at governance/consultations/<pr>.md. Enforces CLAUDE.md →
#      Delegated judgment.
#
#   5. Suite inventory: the .bats files present must match the committed list
#      in scripts/test/MANIFEST. The runner reports what it ran; nothing else
#      records what was supposed to run, so a deleted test file leaves the
#      remaining ones green.
#
# Full end-to-end --reproduce determinism (which requires network + gh to fetch
# pinned repository contents) is intentionally NOT run here so the PR gate stays
# fast and offline. See scripts/verify-determinism.sh for that deeper check.
set -uo pipefail

# The environment can pre-empt shell builtins. An exported function named
# `read` or `return` is already defined before this script's first line runs,
# and a reviewer used exactly that to make this gate print its failure and then
# report PASS. Removing them is free and closes the accidental case — a stray
# export in somebody's shell profile.
#
# It is not a defence against a hostile environment. A shell whose `unset` is
# itself a function owns everything downstream, and no check running inside that
# shell survives it. That boundary belongs to CI, where the environment is
# provisioned rather than inherited.
unset -f read return printf echo cat grep source unset 2>/dev/null || true
unset GLOBIGNORE BASH_ENV 2>/dev/null || true

cd "$(dirname "$0")/.."
fail=0

echo "== [1/5] strict artifact validation =="
if bash scripts/validate-artifacts.sh --strict; then
  echo "  OK"
else
  echo "  FAIL — artifacts do not validate against schemas/*.json"
  fail=1
fi

# ---- Pin → manifest membership gate --------------------------------------
# Source the shared library so the logic has a single definition that both
# ci-checks.sh and the bats tests can exercise directly (operator-lessons.md:
# "A test that duplicates what it guards is not a test").
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/manifest-gate.sh"

echo
echo "== [2/5] pin → manifest membership =="
if check_pin_manifest_membership "docs/repository-manifest.md" "pins/*/*.json"; then
  echo "  OK"
else
  fail=1
fi

echo
echo "== [3/5] composed digest idempotency =="
tmp="$(mktemp -d)"
cp STATE.md "$tmp/STATE.md"
cp digest/state-digest.json "$tmp/state-digest.json"
composer_status=0
bash scripts/compose-digest.sh >/dev/null 2>&1 || composer_status=$?
if [ "$composer_status" -ne 0 ]; then
  echo "  FAIL — compose-digest.sh exited ${composer_status}; the digest was not regenerated"
  cp "$tmp/STATE.md" STATE.md
  cp "$tmp/state-digest.json" digest/state-digest.json
  fail=1
elif diff -q "$tmp/STATE.md" STATE.md >/dev/null 2>&1 \
   && diff -q "$tmp/state-digest.json" digest/state-digest.json >/dev/null 2>&1; then
  echo "  OK — STATE.md and machine digest reproduce exactly from sub-digests"
else
  echo "  FAIL — composed digest is stale or non-deterministic."
  echo "         Run 'bash scripts/compose-digest.sh' and commit the result."
  # Restore committed versions so the runner's tree is left clean.
  cp "$tmp/STATE.md" STATE.md
  cp "$tmp/state-digest.json" digest/state-digest.json
  fail=1
fi
rm -rf "$tmp"

# ---- Consultation artifact gate --------------------------------------------
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/consultation-gate.sh"

echo
echo "== [4/5] consultation artifact gate =="
# PR number: env var (CI) takes priority, else try to extract from branch name.
pr="${CONSULTATION_PR_NUMBER:-}"
if [ -z "$pr" ]; then
  pr=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)
fi
if check_consultation_gate "$pr"; then
  echo "  OK"
else
  fail=1
fi

# ---- Suite inventory --------------------------------------------------------
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/suite-inventory.sh"

echo
echo "== [5/5] test suite inventory =="
if check_suite_inventory "scripts/test/MANIFEST" "scripts/test"; then
  echo "  OK"
else
  fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "CI checks: PASS"
  exit 0
else
  echo "CI checks: FAIL"
  exit 1
fi
