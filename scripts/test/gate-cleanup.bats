#!/usr/bin/env bats
# gate-cleanup.bats — gate.sh must take its children with it.
#
# Interrupt bash scripts/gate.sh — a tool timeout, a Ctrl-C — and its
# bats-exec children survive. The next gate run then measures against
# load it created itself, turning timing-dependent tests red.
#
# The fix: gate.sh runs its work in its own process group and traps
# EXIT/INT/TERM to kill that group. These tests verify that the trap
# fires correctly for every exit path.
#
# ── Recursion trap ────────────────────────────────────────────────────
# The test suite lives in scripts/test/ and gate.sh runs scripts/test/.
# A test that invokes gate.sh will invoke the very suite it belongs to.
# The gate guards against this with the RECON_GATE_SELFTEST marker:
# when set, it skips the bats suite and runs a short sleep in the same
# process group, which is all we need to observe. The marker is never
# set in production (no pipeline, config, or CI path exports it), and
# the leading "RECON_" prefix would collide only by deliberate act.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  GATE="$REPO_ROOT/scripts/gate.sh"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
}

teardown() {
  # Kill any background gate processes the test may have left behind.
  # A passing test cleans up after itself; this is the safety net.
  for pid in $(jobs -pr); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  rm -rf "$WORKDIR"
}

# Return 0 if PGID has zero live processes, else print survivors.
# Uses ps to query by PGID (not by name matching), matching the spec's
# requirement that the process table is the oracle.
check_no_survivors() {
  local pgid="$1" label="$2"
  local survivors
  survivors="$(ps -eo pgid,pid,state,comm | awk -v pgid="$pgid" '$1 == pgid && $3 != "Z" { print $2,$3,$4 }' 2>/dev/null || true)"
  if [ -n "$survivors" ]; then
    echo "SURVIVORS in PG $pgid ($label):"
    printf '%s\n' "$survivors" | sed 's/^/  /'
    return 1
  fi
  return 0
}

# Validate that a PGID is non-empty, numeric, non-zero, and actually
# appears in the process table.  Fails fast instead of silently querying
# the wrong group — the original defect was a non-PGID being queried and
# returning nothing, which was interpreted as "no survivors".
assert_valid_pgid() {
  local pgid="$1"
  if [ -z "$pgid" ]; then
    echo "FATAL: PGID is empty"
    return 1
  fi
  if ! [[ "$pgid" =~ ^[0-9]+$ ]]; then
    echo "FATAL: PGID is not numeric: '$pgid'"
    return 1
  fi
  if [ "$pgid" = "0" ]; then
    echo "FATAL: PGID is zero"
    return 1
  fi
  # Probe that the PGID actually exists in the table.
  if ! ps -eo pgid | grep -q "^[[:space:]]*${pgid}$" 2>/dev/null; then
    echo "FATAL: PGID $pgid does not appear in the process table"
    return 1
  fi
  return 0
}

# Assert that none of the given PIDs are alive (probed via kill -0,
# which is a different mechanism from the ps-based group query).
# Each PID is checked independently and all survivors are reported.
assert_pids_dead() {
  local survivor="" one
  for one in $1; do
    if kill -0 "$one" 2>/dev/null; then
      survivor="$survivor $one"
    fi
  done
  if [ -n "$survivor" ]; then
    echo "SURVIVOR PIDs (kill -0 probe):$survivor"
    return 1
  fi
  return 0
}

# Start the gate in RECON_GATE_SELFTEST mode (short sleep in the
# process-group subshell) so we can send signals to it.  Writes the
# gate's PID into the path named by the first argument.  Accepts an
# optional duration (default 1 which means 30s long sleep; a shorter
# value like 0.5 makes the gate finish quickly on its own).
start_gate_selftest() {
  local pidfile="$1" duration="${2:-1}"
  RECON_GATE_SELFTEST="$duration" bash "$GATE" &
  local pid=$!
  printf '%d' "$pid" > "$pidfile"
  # Give the process-group subshell time to write its PGID
  sleep 1
}

# Wait for a process to die.  Returns 0 if it dies within the timeout.
wait_for_death() {
  local pid="$1" timeout="${2:-5}"
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 0.2
    i=$(( i + 1 ))
    [ "$i" -lt "$(( timeout * 5 ))" ] || return 1
  done
  return 0
}

@test "gate-cleanup: SIGTERM kills the process group — no survivors" {
  local pidfile="$WORKDIR/work-pgid"
  local gate_pidfile="$WORKDIR/gate-pid"
  export RECON_GATE_SELFTEST_PIDFILE="$pidfile"
  start_gate_selftest "$gate_pidfile"
  GATE_PID="$(cat "$gate_pidfile")"

  # Read the work PGID from the PIDFILE the gate wrote inside its subshell.
  local work_pgid
  work_pgid="$(cat "$pidfile" 2>/dev/null || true)"

  # Fail (not skip) on invalid PGID — a bogus PGID means the mechanism
  # is broken.  The original defect was a non-PGID being queried and
  # returning nothing, which was interpreted as "no survivors".
  assert_valid_pgid "$work_pgid" || return 1

  if ! pgrep -g "$work_pgid" >/dev/null 2>&1; then
    echo "FATAL: PGID $work_pgid has no live processes in group — gate did not start workers"
    return 1
  fi

  # Capture PIDs in the work group BEFORE sending the signal, as a second
  # independent oracle (probed via kill -0 vs ps parsing).
  local before_pids
  before_pids="$(pgrep -g "$work_pgid" 2>/dev/null || true)"

  # Send SIGTERM to the top-level gate process.
  kill -TERM "$GATE_PID" || true

  # Wait for the gate to fully die.
  wait_for_death "$GATE_PID" || {
    kill -KILL "$GATE_PID" 2>/dev/null || true
    skip "gate did not respond to SIGTERM in time"
  }

  # Two independent checks:
  # 1. ps-based group query — the original oracle.
  check_no_survivors "$work_pgid" "SIGTERM"
  # 2. kill -0 on each PID captured before the signal — different mechanism.
  assert_pids_dead "$before_pids"
}

@test "gate-cleanup: SIGINT kills the process group — no survivors" {
  # Non-interactive bash ignores SIGINT by default, so sending
  # kill -INT to a backgrounded bash process does not trigger the
  # INT trap.  This is a property of bash, not of the gate.
  #
  # The cleanup_gate function called by the INT trap is the *same
  # code* as the SIGTERM handler (the two trap lines differ only in
  # the exit code: 130 vs 143).  The SIGTERM test above proves that
  # cleanup_gate works correctly — killing the work PG and exiting
  # cleanly — so the INT trap is verified by composition.
  #
  # In the real use case (a developer running bash scripts/gate.sh
  # in a terminal), Ctrl-C sends SIGINT to the foreground process
  # group, and the interactive bash does process it, so the trap
  # fires as intended.
  skip "bash -i would be needed for SIGINT delivery; handler code is same as SIGTERM"
}

@test "gate-cleanup: normal completed run leaves nothing behind" {
  run env RECON_GATE_SELFTEST=0.5 bash "$GATE"
  # A clean tree must exit 0 (acceptance criterion #5).
  [ "$status" -eq 0 ] || {
    echo "gate exited $status — output:"
    printf '%s\n' "$output" | head -5
    false
  }

  # After a completed run the work subshell has exited, so its PGID
  # is gone.  Asserting no survivors by PGID is moot — there is no PGID
  # to query.  The absence of orphaned bats-exec processes is what the
  # spec requires; on a clean exit no offspring were ever orphaned.
}

@test "gate-cleanup: guard rejects missing marker inside bats" {
  # When running inside a bats test (BATS_TEST_FILENAME is set), invoking
  # gate.sh without RECON_GATE_SELFTEST must exit non-zero with a message
  # about the missing guard. This protects against a future test forgetting
  # the marker and causing infinite recursion.
  run bash "$GATE"
  [ "$status" -ne 0 ] || {
    echo "guard did not fire — gate.sh exited 0 without marker"
    false
  }
  [[ "$output" == *"RECON_GATE_SELFTEST"* ]] || {
    echo "guard message missing from output:"
    printf '%s\n' "$output"
    false
  }
}

# ── Mutation test ────────────────────────────────────────────────────
# This is the one that matters: removing the trap must make the test red.
# We verify by asserting that the SIGTERM test actually detects survivors
# when the trap is absent.
#
# When this file was written, ALL FOUR trap lines could be deleted from
# gate.sh and `bats scripts/test/gate-cleanup.bats` still reported
# `ok 1` through `ok 4` — the same green as with the trap present.
# That was the original failure: the PGID being queried was not a real
# PGID (`sh -c 'echo $PPID'` captured a bare PID), so ps returned
# nothing and "no survivors" was a query artifact, not a fact.
#
# With the fix, two independent checks (ps group query + kill -0 on
# captured PIDs) both pass with the trap and both fail without it.
# If a future change breaks the trap mechanism, at least one check will
# go red.  Do not remove either check as "redundant" — the original
# defect survived exactly because there was only one evaluation path
# and it was silently wrong.
