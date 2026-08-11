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

# ---- Bats recursion guard -------------------------------------------------
# The test suite lives in scripts/test/ and gate.sh runs scripts/test/.
# If we're already inside a bats test (BATS_TEST_FILENAME is set) and the
# RECON_GATE_SELFTEST marker is absent, the suite is invoking itself —
# exit non-zero rather than recursing.
if [ -n "${BATS_TEST_FILENAME:-}" ] && [ -z "${RECON_GATE_SELFTEST:-}" ]; then
  echo "ERROR: gate.sh invoked from inside a bats test without RECON_GATE_SELFTEST" >&2
  echo "       This would cause infinite recursion. Set RECON_GATE_SELFTEST=<seconds>" >&2
  exit 2
fi

FULL=false
[ "${1:-}" = "--full" ] && FULL=true

# Per-run log directory. A fixed path under /tmp is shared state: two gate runs
# at once — a worktree and the checkout it was cut from, say — overwrite each
# other's logs, so the file a FAIL line points at can describe the other run.
LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX")"

# ---- Process-group isolation & cleanup trap ----
#
# The bats suite spawns background workers. When gate.sh is interrupted
# (a tool timeout, a Ctrl-C), those workers survive — they become orphans
# in their own process group and skew the next run's timing measurements.
#
# The gate's entire work runs in a child subshell started with `set -m`
# active on the parent, making the subshell the leader of its own process
# group.  A trap on EXIT/INT/TERM kills the work group with TERM → wait →
# KILL, rather than enumerating PIDs — which is how this repository
# learned you lose one.
#
# The EXIT trap preserves the original exit status (pass/fail of the gate).
# INT and TERM exit with 128+SIGNO (130, 143) after cleanup, matching the
# convention that a signal-killed process advertises what killed it.

set -m
(
  set +m
  printf '%s' "$BASHPID" > "$LOGDIR/work-pgid"

  fail=0
  skipped=""

  step() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
  bad()  { printf '  \033[31mFAIL\033[0m — %s\n' "$1"; fail=1; }
  good() { printf '  \033[32mOK\033[0m — %s\n' "$1"; }

  # The suite runner lives in scripts/lib/ so that scripts/test/test-runner.bats
  # exercises the same definition this gate uses. A test that carries its own copy
  # of what it guards is not a test.
  # shellcheck disable=SC1091
  source "$(dirname "$0")/lib/test-runner.sh"

  # Tree-state library for attribution: which step changed the working tree.
  # shellcheck disable=SC1091
  source "$(dirname "$0")/lib/tree-state.sh"

  # If RECON_GATE_SELFTEST_PIDFILE is set (used by tests), write the work
  # PGID to that file so the test can read it without ps/pgrep.
  if [ -n "${RECON_GATE_SELFTEST_PIDFILE:-}" ]; then
    printf '%s' "$(cat "$LOGDIR/work-pgid")" > "$RECON_GATE_SELFTEST_PIDFILE"
  fi

  # ---- RECON_GATE_SELFTEST guard (must stay inside the process-group subshell) ----
  #
  # The test suite lives in scripts/test/ and gate.sh runs scripts/test/.
  # A test that invokes gate.sh will invoke the very suite it belongs to —
  # infinite recursion.
  #
  # When RECON_GATE_SELFTEST is set, skip the bats suite and run a short
  # sleep in the same process group instead.  Accept a numeric duration:
  #
  #   RECON_GATE_SELFTEST=1     → sleep 30  (long sleep for signal tests)
  #   RECON_GATE_SELFTEST=0.5   → sleep 0.5 (short, gate finishes quickly)
  #
  # A non-numeric value is a hard error.  This variable is never set in
  # production (no pipeline, config, or CI path exports it), and the leading
  # "RECON_" prefix would collide only by deliberate act.
  if [ -n "${RECON_GATE_SELFTEST:-}" ]; then
    if [ "$RECON_GATE_SELFTEST" = "1" ]; then
      sleep 30
    elif [[ "$RECON_GATE_SELFTEST" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      sleep "$RECON_GATE_SELFTEST"
    else
      echo "ERROR: RECON_GATE_SELFTEST must be a positive number (e.g. 0.5, 1, 30), got '$RECON_GATE_SELFTEST'" >&2
      exit 2
    fi
    exit 0
  fi

  # Baseline snapshot before any step runs. Only uncommitted changes (status:
  # records) indicate pre-existing dirt; registered worktrees are normal state.
  snap_start="$(tree_snapshot)"
  dirty="$(tree_status_records "$snap_start")"
  if [ -n "$dirty" ]; then
    printf 'note: the working tree was already dirty when this gate started\n'
    printf '%s\n' "$dirty" | sed 's/^/  /'
  fi

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
  snap_pre_suite="$(tree_snapshot)"
  if run_suite "$LOGDIR/bats.log"; then
    good "$(grep -c '^ok' "$LOGDIR/bats.log") tests"
  else
    suite_failed "$LOGDIR/bats.log" "test suite"
  fi
  if ! new_records="$(tree_diff "$snap_pre_suite" "$(tree_snapshot)")"; then
    bad "the test suite $(tree_change_kind "$new_records")"
    printf '%s\n' "$new_records" | sed 's/^/    /'
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
    # Baseline of the source tree before this phase creates anything. Taken
    # before the disposable worktree exists so the worktree record it would
    # add is not part of either side of the tree-diff below.
    snap_pre_reproduce="$(tree_snapshot)"
    # The reproduce fixpoint overwrites STATE.md, the digest, and
    # claims/evidence/findings in whatever tree it runs in. Running it in the
    # source checkout meant a failed reproduce left that damage behind: the
    # gate reported failure but could not restore what it had overwritten.
    # The work therefore runs in a disposable git worktree at HEAD, and the
    # source tree is only ever read. See issue #176.
    wt_dir="$(mktemp -d "${TMPDIR:-/tmp}/gate-reproduce.XXXXXX")"
    if ! git worktree add "$wt_dir" HEAD --detach --quiet 2>/dev/null; then
      bad "could not create reproduce worktree (fixpoint not checked)"
      rm -rf "$wt_dir" 2>/dev/null || true
    else
      # Remove the worktree on every exit path — pass, fail, signal. Idempotent,
      # so the explicit call before the tree check and the EXIT trap cannot
      # conflict with each other. On INT/TERM the cleanup is followed by exit
      # with 128+SIGNO: a signal-killed gate must not keep running against a
      # worktree it has already removed.
      reproduce_cleanup() {
        git worktree remove --force "$wt_dir" 2>/dev/null || {
          # The removal failed (e.g. the directory is already gone); unregister
          # whatever stale admin state the failed remove left behind.
          git worktree prune 2>/dev/null || true
        }
        rm -rf "$wt_dir" 2>/dev/null || true
      }
      trap reproduce_cleanup EXIT
      trap 'reproduce_cleanup; exit 130' INT
      trap 'reproduce_cleanup; exit 143' TERM

      snap() { find pins claims evidence drift findings coverage consumption self digest STATE.md \
                -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | awk '{print $1}'; }
      # Run with the worktree as CWD, in a subshell so the cd cannot leak:
      # the four steps write into the disposable copy, never into the source
      # checkout. Each step's log lands in LOGDIR so a failed run leaves an
      # explicit diagnostic path.
      run()  { ( cd "$wt_dir" || exit 1
                 RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce       >"$LOGDIR/reproduce-recon.log"       2>&1
                 RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce >"$LOGDIR/reproduce-census.log"     2>&1
                 RECON_PINS_DIR=pins bash scripts/consumption-run.sh --reproduce >"$LOGDIR/reproduce-consumption.log" 2>&1
                 bash scripts/compose-digest.sh                                  >"$LOGDIR/reproduce-digest.log"     2>&1 ); }
      before="$(cd "$wt_dir" && snap)"; run; a="$(cd "$wt_dir" && snap)"; run; b="$(cd "$wt_dir" && snap)"
      printf 'before %s\nrun1   %s\nrun2   %s\n' "$before" "$a" "$b" > "$LOGDIR/reproduce-hashes.txt"
      # The worktree is gone before the source tree is re-snapshot: the
      # tree-diff below must see the source as it was before this phase, not
      # the disposable copy this phase created.
      reproduce_cleanup
      if [ "$a" != "$b" ]; then
        bad "not deterministic: two consecutive runs differ"
        printf '  reproduce evidence: %s\n' "$LOGDIR"/reproduce-*.log
      elif [ "$before" != "$a" ]; then
        bad "committed artifacts are not the fixpoint — regenerate and commit"
        printf '  reproduce evidence: %s\n' "$LOGDIR"/reproduce-*.log
      elif ! new_records="$(tree_diff "$snap_pre_reproduce" "$(tree_snapshot)")"; then
        bad "the reproduce run $(tree_change_kind "$new_records")"
        printf '%s\n' "$new_records" | sed 's/^/    /'
      else
        good "committed == run1 == run2, tree clean"
      fi
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
  - that an architecturally separate adversarial review with sealed inputs,
    pre-existing oracles, and deterministic evidence has completed. That is
    required for risk class HIGH; current pipeline verdicts remain
    non-authoritative until RECOVERY-2 closes the enforcement gaps.
    See governance/adversarial-review.md and docs/recovery-1-contract.md.
NOTE

  exit "$fail"
) &
GATE_SUBSHELL_PID=$!
set +m

# Read the work PGID — the subshell writes it before doing anything real.
while [ ! -f "$LOGDIR/work-pgid" ]; do sleep 0.05; done
GATE_PGID=$(cat "$LOGDIR/work-pgid")

# Validate the work PGID — it must exist, be numeric, and not be the gate's
# own process group (which would mean no isolation — the trap would kill
# the gate itself rather than the workers).
if [ -z "$GATE_PGID" ]; then
  kill "$GATE_SUBSHELL_PID" 2>/dev/null || true
  echo "ERROR: work PGID is empty — the subshell did not write one" >&2
  exit 3
fi
if ! [[ "$GATE_PGID" =~ ^[0-9]+$ ]]; then
  kill "$GATE_SUBSHELL_PID" 2>/dev/null || true
  echo "ERROR: work PGID is not numeric: '$GATE_PGID'" >&2
  exit 3
fi
GATE_OWN_PGID=$(ps -o pgid= $$ | tr -d ' ')
if [ "$GATE_PGID" = "$GATE_OWN_PGID" ]; then
  kill "$GATE_SUBSHELL_PID" 2>/dev/null || true
  echo "ERROR: work PGID ($GATE_PGID) equals gate's own PGID — no isolation" >&2
  exit 3
fi

# Cleanup handler for the work process group.
# Idempotent: _GATE_CLEANUP prevents re-entry when exit() fires EXIT (bash
# does not re-execute EXIT in that case) or when a second signal arrives.
# Preserves the original exit status: normal completion uses $? from exit(),
# signal handling uses the trap-specific code (128+SIGNO).
GATE_EXIT=0

cleanup_gate() {
  local rc="${GATE_EXIT:-$?}"
  [ "${_GATE_CLEANUP:-0}" -eq 1 ] && exit "$rc"
  _GATE_CLEANUP=1
  trap '' EXIT INT TERM

  # TERM first so cooperating processes get a clean shutdown.
  kill -- -"$GATE_PGID" 2>/dev/null || true
  sleep 0.2
  # KILL whatever remains (subprocesses that ignore TERM).
  kill -KILL -- -"$GATE_PGID" 2>/dev/null || true

  exit "$rc"
}

trap cleanup_gate EXIT
trap 'GATE_EXIT=130; cleanup_gate' INT
trap 'GATE_EXIT=143; cleanup_gate' TERM

wait "$GATE_SUBSHELL_PID"
GATE_EXIT=$?
exit "$GATE_EXIT"
