#!/usr/bin/env bash
# test-runner.sh — run the bats suite as one process per file.
#
# Source it, then call:
#   run_suite <logfile> [testdir]      # default testdir: scripts/test
#
# Returns 0 only if every worker exited 0, every worker's log was aggregated
# whole, and the aggregate contains no `not ok` line.
#
# Deliberately no `set -o errexit` here. This file is sourced, and `set` acts
# on the sourcing shell: scripts/gate.sh runs without errexit on purpose, and a
# library must not change its caller's failure semantics behind its back.
#
# Why this exists at all: the suite is the bulk of the gate's wall clock, and a
# gate expensive enough to skip is the failure this repository has catalogued
# most often. Every test file isolates the state it mutates under its own
# `mktemp -d` and reads the repository without writing to it, so the files can
# run concurrently.
#
# Why it is written defensively: the first version of this wrapper printed the
# failing file, counted the failures correctly, and still returned 0, because
# its last command was a cleanup. An independent review then found three more
# paths to the same shape — an unreadable log, a `cat` that fails, and a `bats`
# that reports `not ok` while exiting 0 — each of which produced a green
# verdict with no evidence behind it. Every one of them now fails closed.

# Maximum concurrent workers. Bounded because the count would otherwise track
# the number of test files, and a suite that grows turns the gate into a fork
# bomb on a small machine.
: "${TEST_RUNNER_MAX_JOBS:=8}"

run_suite() {
  local log="$1" testdir="${2:-scripts/test}"
  local jobdir rc=0 p f n=0 i

  jobdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-suite.XXXXXX")" || return 1
  : >"$log" || { rm -rf "$jobdir"; return 1; }

  local pids=""
  for f in "$testdir"/*.bats; do
    [ -f "$f" ] || continue
    n=$(( n + 1 ))

    # Hold at the concurrency cap. `wait -n` would be the natural tool and does
    # not exist in bash 3.2, which is what macOS ships and what this gate runs
    # on most often.
    while [ "$(jobs -pr | wc -l)" -ge "$TEST_RUNNER_MAX_JOBS" ]; do sleep 0.2; done

    bats "$f" >"$jobdir/$n.log" 2>&1 &
    pids="$pids $!"
  done

  # Zero test files is a failure. "Found nothing" and "ran nothing" must never
  # reach the caller as the same outcome.
  if [ "$n" = 0 ]; then
    echo "no .bats files found under $testdir" >"$log"
    rm -rf "$jobdir"
    return 1
  fi

  for p in $pids; do
    wait "$p" || rc=1
  done

  # Aggregate one file at a time, by index rather than by glob: an empty glob
  # on bash 3.2 leaves the literal `*.log`, and a large suite would exceed
  # ARG_MAX. Both were demonstrated to return a green verdict with an empty
  # aggregate log. A missing or unreadable log is now a failure in itself,
  # because a passing verdict with no evidence behind it is worse than a red one.
  i=1
  while [ "$i" -le "$n" ]; do
    if [ ! -r "$jobdir/$i.log" ]; then
      echo "not ok - worker $i left no readable log" >>"$log"
      rc=1
    elif ! cat "$jobdir/$i.log" >>"$log"; then
      echo "not ok - could not aggregate the log of worker $i" >>"$log"
      rc=1
    fi
    i=$(( i + 1 ))
  done

  # The worker's exit status and the worker's output must agree. A `bats` that
  # prints `not ok` and exits 0 — a stale build, a shadowing wrapper, a
  # deliberate substitution — otherwise passes the gate. The dependency check
  # establishes only that something named `bats` is on PATH.
  if grep -q '^not ok' "$log"; then
    rc=1
  fi

  rm -rf "$jobdir"
  return "$rc"
}
