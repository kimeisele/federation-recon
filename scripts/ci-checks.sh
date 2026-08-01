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
#   6. Pin validation gate: verifies every pin is correct — membership in the
#      manifest's adopted set, reachability from the requested ref, monotonic
#      movement (no backwards steps), and bounded change in the pin set. The
#      reproduce fixpoint answers "are artifacts reproducible from these pins?",
#      not "are these pins correct?" — this section answers the second question.
#      Network-dependent predicates (reachability, monotonicity) return UNKNOWN
#      and fail the run when gh is unavailable.
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

echo "== [1/7] strict artifact validation =="
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
echo "== [2/7] pin → manifest membership =="
if check_pin_manifest_membership "docs/repository-manifest.md" "pins/*/*.json"; then
  echo "  OK"
else
  fail=1
fi

echo
echo "== [3/7] composed digest idempotency =="
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
echo "== [4/7] consultation artifact gate =="
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

# ---- Consultation provenance -----------------------------------------------
# A consultation may not claim a provider it cannot prove served it. On
# 2026-07-31 three artifacts named a provider that had not answered, and the
# repository read them as independent judgments through a merge decision. See
# scripts/lib/consultation-provenance.sh.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/consultation-provenance.sh"

echo
echo "== [4b/6] consultation provenance =="
if check_consultation_provenance "governance/consultations"; then
  :
else
  fail=1
fi

# ---- Suite inventory --------------------------------------------------------
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/suite-inventory.sh"

echo
echo "== [5/7] test suite inventory =="
if check_suite_inventory "scripts/test/MANIFEST" "scripts/test"; then
  echo "  OK"
else
  fail=1
fi

# ---- Pin validation gate ----------------------------------------------------
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/pin-gate.sh"

# When no previous_pins_dir is given, pin-gate.sh reads the previous pin
# version from git history, comparing against BASE_REF (default origin/main).
# In GitHub Actions CI, GITHUB_BASE_REF carries the PR target branch name.
BASE_REF="${BASE_REF:-${GITHUB_BASE_REF:-origin/main}}"
export BASE_REF

echo
echo "== [6/7] pin validation gate =="
if check_pin_validity "pins/*/*.json" "docs/repository-manifest.md"; then
  echo "  OK"
else
  rc=$?
  if [ "$rc" -eq 2 ]; then
    echo "  UNKNOWN — network-dependent predicates could not run (gh unavailable)"
  fi
  fail=1
fi

# ---- Amendment log gate ------------------------------------------------------
#
# An accepted ADR that is absent from docs/amendments.md. The log declares
# accepted ADRs to be its own subject matter and went two days without the
# largest one (#148). A log that depends on being remembered records only the
# changes made by people who remember.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/amendment-log.sh"

echo
echo "== [7/7] amendment log =="
check_amendment_log "docs" "docs/amendments.md"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  OK"
else
  [ "$rc" -eq 2 ] && echo "  the check could not run — that is a failure, not an omission"
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
