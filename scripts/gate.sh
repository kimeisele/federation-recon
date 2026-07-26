#!/usr/bin/env bash
# gate.sh — the operator's merge gate, as a command rather than as prose.
#
# docs/operator-handover.md describes what must pass before anything merges.
# A description has to be read and remembered. This repository has documented
# ten defects that survived exactly that step, so the description is executable
# here and the document points at it.
#
#   bash scripts/gate.sh              # offline checks
#   bash scripts/gate.sh --full       # adds the reproduce fixpoint (needs network)
#
# Exit 0 only if every check that ran passed AND nothing was silently skipped.
# A check that cannot run is a failure, not an omission: "tool missing" and
# "found nothing" must never be the same outcome.

set -uo pipefail
cd "$(dirname "$0")/.."

FULL=false
[ "${1:-}" = "--full" ] && FULL=true

fail=0
skipped=""

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m — %s\n' "$1"; fail=1; }
good() { printf '  \033[32mOK\033[0m — %s\n' "$1"; }

# ---- dependencies -------------------------------------------------------
# Asserted, not assumed. A missing binary must announce itself rather than
# turn into an empty result somewhere downstream.
step "0/5 dependencies"
for t in git python3 bats shasum; do
  if command -v "$t" >/dev/null 2>&1; then good "$t"; else bad "$t is required and not installed"; fi
done
[ "$fail" = 1 ] && { printf '\n\033[31mGATE: FAIL\033[0m — dependencies missing, nothing else was run\n'; exit 1; }

# ---- 1. strict artifact validation --------------------------------------
step "1/5 strict artifact validation"
if bash scripts/validate-artifacts.sh --strict >/tmp/gate-validate.log 2>&1; then
  good "$(grep -o 'Total validated: [0-9]*' /tmp/gate-validate.log | head -1)"
else
  bad "artifacts do not validate — see /tmp/gate-validate.log"
fi

# ---- 2. offline CI gate --------------------------------------------------
step "2/5 offline CI gate"
if bash scripts/ci-checks.sh >/tmp/gate-ci.log 2>&1; then
  good "ci-checks passed"
else
  bad "ci-checks failed"; tail -20 /tmp/gate-ci.log | sed 's/^/    /'
fi

# ---- 3. test suite -------------------------------------------------------
step "3/5 test suite"
if bats scripts/test/ >/tmp/gate-bats.log 2>&1; then
  good "$(grep -c '^ok' /tmp/gate-bats.log) tests"
else
  bad "$(grep -c '^not ok' /tmp/gate-bats.log) failing"; grep '^not ok' /tmp/gate-bats.log | head -10 | sed 's/^/    /'
fi

# ---- 4. suite under CI environment --------------------------------------
# Two tests once passed locally and failed on CI because GitHub Actions exports
# GITHUB_EVENT_NAME and the workflow exports CONSULTATION_PR_NUMBER. The
# environment was an unstated test input. Run the suite as CI would.
step "4/5 test suite under a CI-like environment"
if GITHUB_EVENT_NAME=pull_request CONSULTATION_PR_NUMBER=99 CI=true GITHUB_ACTIONS=true \
   bats scripts/test/ >/tmp/gate-bats-ci.log 2>&1; then
  good "$(grep -c '^ok' /tmp/gate-bats-ci.log) tests with CI variables set"
else
  bad "suite depends on the ambient environment"; grep '^not ok' /tmp/gate-bats-ci.log | head -10 | sed 's/^/    /'
fi

# ---- 5. reproduce fixpoint ----------------------------------------------
step "5/5 reproduce fixpoint (FR-CON-012)"
if ! $FULL; then
  printf '  \033[33mSKIPPED\033[0m — needs network; re-run with --full\n'
  skipped="the reproduce fixpoint"
elif ! command -v gh >/dev/null 2>&1; then
  bad "gh is required for --full and is not installed"
else
  snap() { find pins claims evidence drift findings coverage consumption self digest STATE.md \
            -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
  run()  { RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce       >/dev/null 2>&1
           RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce >/dev/null 2>&1
           RECON_PINS_DIR=pins bash scripts/consumption-run.sh --reproduce >/dev/null 2>&1
           bash scripts/compose-digest.sh                                  >/dev/null 2>&1; }
  before="$(snap)"; run; a="$(snap)"; run; b="$(snap)"
  if [ "$a" != "$b" ]; then
    bad "not deterministic: two consecutive runs differ"
  elif [ "$before" != "$a" ]; then
    bad "committed artifacts are not the fixpoint — regenerate and commit"
  elif [ -n "$(git status --porcelain)" ]; then
    bad "working tree dirty after reproduce"
  else
    good "committed == run1 == run2, tree clean"
  fi
fi

# ---- verdict -------------------------------------------------------------
printf '\n'
if [ "$fail" = 0 ] && [ -z "$skipped" ]; then
  printf '\033[32mGATE: PASS\033[0m\n'
elif [ "$fail" = 0 ]; then
  printf '\033[33mGATE: PASS, with %s not checked\033[0m\n' "$skipped"
else
  printf '\033[31mGATE: FAIL\033[0m\n'
fi

# What this gate does NOT establish. Stated because a gate that implies more
# than it proves invites the trust it cannot carry — the failure this
# repository has catalogued most often.
cat <<'NOTE'

Not established by this gate:
  - that a test fails when the thing it guards breaks. Run the mutation
    yourself: break the check, confirm the suite goes red, restore.
  - that the change is the right thing rather than a correct thing.
  - that an independent reviewer of a different provider has seen it —
    required for risk class HIGH. See governance/adversarial-review.md.
NOTE

exit "$fail"
