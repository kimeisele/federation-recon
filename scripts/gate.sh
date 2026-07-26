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

# Per-run log directory. A fixed path under /tmp is shared state: two gate runs
# at once — a worktree and the checkout it was cut from, say — overwrite each
# other's logs, so the file a FAIL line points at can describe the other run.
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX")"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m — %s\n' "$1"; fail=1; }
good() { printf '  \033[32mOK\033[0m — %s\n' "$1"; }

# The suite runner lives in scripts/lib/ so that scripts/test/test-runner.bats
# exercises the same definition this gate uses. A test that carries its own copy
# of what it guards is not a test.
# shellcheck disable=SC1091
source "$(dirname "$0")/lib/test-runner.sh"

# suite_failed <logfile> <label> — report why the suite failed.
#
# Counting `not ok` lines is not a diagnosis: a suite that never ran has zero
# of them, and reporting "0 failing" describes a green run.
suite_failed() {
  local log="$1" label="$2" nf
  nf="$(grep -c '^not ok' "$log")"
  if [ "$nf" = 0 ]; then
    bad "$label: the suite did not run — $(head -1 "$log")"
  else
    bad "$label: $nf failing"
    grep '^not ok' "$log" | head -10 | sed 's/^/    /'
  fi
}

# ---- dependencies -------------------------------------------------------
# Asserted, not assumed. A missing binary must announce itself rather than
# turn into an empty result somewhere downstream.
step "0/4 dependencies"
for t in git python3 bats shasum; do
  if command -v "$t" >/dev/null 2>&1; then good "$t"; else bad "$t is required and not installed"; fi
done
[ "$fail" = 1 ] && { printf '\n\033[31mGATE: FAIL\033[0m — dependencies missing, nothing else was run\n'; exit 1; }

# ---- 1. strict artifact validation --------------------------------------
step "1/4 strict artifact validation"
if bash scripts/validate-artifacts.sh --strict >"$LOGDIR/validate.log" 2>&1; then
  good "$(grep -o 'Total validated: [0-9]*' "$LOGDIR/validate.log" | head -1)"
else
  bad "artifacts do not validate — see $LOGDIR/validate.log"
fi

# ---- 2. offline CI gate --------------------------------------------------
step "2/4 offline CI gate"
if bash scripts/ci-checks.sh >"$LOGDIR/ci.log" 2>&1; then
  good "ci-checks passed"
else
  bad "ci-checks failed"; tail -20 "$LOGDIR/ci.log" | sed 's/^/    /'
fi

# ---- 3. test suite -------------------------------------------------------
step "3/4 test suite"
if run_suite "$LOGDIR/bats.log"; then
  good "$(grep -c '^ok' "$LOGDIR/bats.log") tests"
else
  suite_failed "$LOGDIR/bats.log" "test suite"
fi

# ---- removed: a second suite run under a CI-like environment -------------
# This gate used to run the whole suite a second time with GITHUB_EVENT_NAME,
# CONSULTATION_PR_NUMBER, CI and GITHUB_ACTIONS exported, because two tests once
# passed locally and failed on CI when they inherited those variables. It was one
# of two identical suite runs — roughly two fifths of the gate's wall clock — and
# it was inert:
#
#   - the defect was fixed at its source — scripts/test/consultation-gate.bats
#     unsets both variables in setup(), and every test now states its inputs;
#   - the two runs' aggregate logs were byte-identical in every measured gate;
#   - the real oracle already exists and is free. GitHub Actions runs the whole
#     suite in a genuinely different environment on every pull request, which
#     four hand-picked variables can only imitate.
#
# Deleting a check needs a reason, not a schedule. This is the reason.

# ---- 5. reproduce fixpoint ----------------------------------------------
step "4/4 reproduce fixpoint (FR-CON-012)"
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
printf 'logs: %s\n' "$LOGDIR"

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
