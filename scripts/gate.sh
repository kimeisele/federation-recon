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

# run_suite <logfile> — run the test suite, one process per .bats file.
#
# The suite is ~92% of this gate's wall clock and the gate runs it twice, which
# put a merge-time check at roughly fifteen minutes. A gate that expensive gets
# skipped, and a skipped gate is the failure this repository has catalogued most
# often. Each test file isolates its own state in `mktemp -d` and reads the
# repository without writing to it, so per-file parallelism is safe — measured
# across repeated full runs, not assumed.
#
# The exit status is the entire point of this function. The first version of it
# named the failing file, counted the failures correctly, and still returned 0,
# because its last command was a cleanup. Everything a human reads was right;
# the one thing the caller reads was wrong.
run_suite() {
  local log="$1" jobdir rc=0 p f n=0
  local pids=""

  jobdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-suite.XXXXXX")"
  for f in scripts/test/*.bats; do
    [ -f "$f" ] || continue
    n=$(( n + 1 ))
    bats "$f" >"$jobdir/$(basename "$f").log" 2>&1 &
    pids="$pids $!"
  done

  # No test files is not a pass. "Found nothing" and "ran nothing" must never
  # reach the caller as the same outcome.
  if [ "$n" = 0 ]; then
    echo "no .bats files found under scripts/test/" >"$log"
    rm -rf "$jobdir"
    return 1
  fi

  for p in $pids; do
    wait "$p" || rc=1
  done

  cat "$jobdir"/*.log >"$log" 2>/dev/null
  rm -rf "$jobdir"
  return "$rc"
}

# suite_failed <logfile> <label> — report why the suite failed.
#
# Counting `not ok` lines is not a diagnosis: a suite that never ran has zero
# of them, and reporting "0 failing" describes a green run. Distinguish the two.
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
step "0/5 dependencies"
for t in git python3 bats shasum; do
  if command -v "$t" >/dev/null 2>&1; then good "$t"; else bad "$t is required and not installed"; fi
done
[ "$fail" = 1 ] && { printf '\n\033[31mGATE: FAIL\033[0m — dependencies missing, nothing else was run\n'; exit 1; }

# ---- 1. strict artifact validation --------------------------------------
step "1/5 strict artifact validation"
if bash scripts/validate-artifacts.sh --strict >"$LOGDIR/validate.log" 2>&1; then
  good "$(grep -o 'Total validated: [0-9]*' "$LOGDIR/validate.log" | head -1)"
else
  bad "artifacts do not validate — see $LOGDIR/validate.log"
fi

# ---- 2. offline CI gate --------------------------------------------------
step "2/5 offline CI gate"
if bash scripts/ci-checks.sh >"$LOGDIR/ci.log" 2>&1; then
  good "ci-checks passed"
else
  bad "ci-checks failed"; tail -20 "$LOGDIR/ci.log" | sed 's/^/    /'
fi

# ---- 3. test suite -------------------------------------------------------
step "3/5 test suite"
if run_suite "$LOGDIR/bats.log"; then
  good "$(grep -c '^ok' "$LOGDIR/bats.log") tests"
else
  suite_failed "$LOGDIR/bats.log" "test suite"
fi

# ---- 4. suite under CI environment --------------------------------------
# Two tests once passed locally and failed on CI because GitHub Actions exports
# GITHUB_EVENT_NAME and the workflow exports CONSULTATION_PR_NUMBER. The
# environment was an unstated test input. Run the suite as CI would.
step "4/5 test suite under a CI-like environment"
# A subshell, not an assignment prefix: bash keeps variable assignments made in
# front of a *function* call in effect after the call returns, which would leak
# the CI environment into step 5.
if (
     export GITHUB_EVENT_NAME=pull_request CONSULTATION_PR_NUMBER=99 CI=true GITHUB_ACTIONS=true
     run_suite "$LOGDIR/bats-ci.log"
   ); then
  good "$(grep -c '^ok' "$LOGDIR/bats-ci.log") tests with CI variables set"
else
  suite_failed "$LOGDIR/bats-ci.log" \
    "test suite with CI variables set (if step 3 passed, the suite depends on the ambient environment)"
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
