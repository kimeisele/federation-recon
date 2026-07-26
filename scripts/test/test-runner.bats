#!/usr/bin/env bats
#
# Regression tests for scripts/lib/test-runner.sh.
#
# The wrapper that runs the test suite had no tests of its own. Its first
# version named the failing file, counted the failures correctly, and exited 0
# anyway; an independent review then found three further routes to a green
# verdict with a red or absent suite. Each of those routes gets a test here, so
# that the next person to touch this file cannot reintroduce one silently.
#
# `bats` is replaced by a stub on PATH. That is the point: the property under
# test is what run_suite concludes from a worker's behaviour, so the worker has
# to be able to misbehave on demand. The stub reads its instruction from the
# first line of the .bats file it is handed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$WORKDIR/tests" "$WORKDIR/mockbin"

  cat >"$WORKDIR/mockbin/bats" <<'STUB'
#!/usr/bin/env bash
# Stub bats. Behaviour is the first line of the file under test.
case "$(head -1 "$1")" in
  FAIL)  echo "not ok 1 - $1"; exit 1 ;;
  LIE)   echo "not ok 1 - $1"; exit 0 ;;   # output and status disagree
  SILENT) exit 0 ;;                        # exits clean, ran nothing, said nothing
  EMPTY) echo "1..0"; exit 0 ;;            # a plan, but no test ever ran
  *)     echo "ok 1 - $1";    exit 0 ;;
esac
STUB
  chmod +x "$WORKDIR/mockbin/bats"
  PATH="$WORKDIR/mockbin:$PATH"

  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/test-runner.sh"
}

teardown() {
  rm -rf "$WORKDIR"
}

mk() { printf '%s\n' "$2" >"$WORKDIR/tests/$1.bats"; }

@test "test-runner: all workers green — returns 0" {
  mk a PASS; mk b PASS; mk c PASS
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
}

@test "test-runner: one worker exits nonzero — returns 1" {
  mk a PASS; mk b FAIL; mk c PASS
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# The path that motivated this file. A worker that reports failure in its
# output while exiting 0 — a stale, shadowed or substituted bats — must not
# reach the caller as a pass. Status and output have to agree.
@test "test-runner: worker prints 'not ok' but exits 0 — returns 1" {
  mk a PASS; mk b LIE; mk c PASS
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

@test "test-runner: no .bats files — returns 1, does not report a pass" {
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  grep -q 'no .bats files found' "$WORKDIR/out.log"
}

# "Ran everything and it was green" and "produced no evidence" must not be the
# same outcome. An aggregate log that cannot be written is the second.
@test "test-runner: unwritable aggregate log — returns 1" {
  mk a PASS
  mkdir -p "$WORKDIR/ro"
  : >"$WORKDIR/ro/out.log"
  chmod 0444 "$WORKDIR/ro/out.log"
  chmod 0555 "$WORKDIR/ro"
  run run_suite "$WORKDIR/ro/out.log" "$WORKDIR/tests"
  chmod 0755 "$WORKDIR/ro"
  [ "$status" -eq 1 ]
}

@test "test-runner: aggregate log carries every worker's output" {
  mk a PASS; mk b PASS; mk c PASS
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ok' "$WORKDIR/out.log")" -eq 3 ]
  grep -q 'a.bats' "$WORKDIR/out.log"
  grep -q 'b.bats' "$WORKDIR/out.log"
  grep -q 'c.bats' "$WORKDIR/out.log"
}

# Rejecting `not ok` only rejects declared failure. A worker that exits clean
# while running nothing at all is the same threat with the evidence removed
# instead of contradicted, and it produced "OK — 0 tests" and a passing gate.
@test "test-runner: worker exits 0 with no output — returns 1" {
  mk a PASS; mk b SILENT; mk c PASS
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  grep -q 'produced no test results' "$WORKDIR/out.log"
}

@test "test-runner: worker emits an empty TAP plan — returns 1" {
  mk a EMPTY
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# The cap is arithmetic inside a loop condition. A non-numeric value made the
# test error and the loop never block, so the cap vanished; a value below 1
# made it block forever.
@test "test-runner: non-numeric TEST_RUNNER_MAX_JOBS — returns 1, does not run unbounded" {
  mk a PASS; mk b PASS
  TEST_RUNNER_MAX_JOBS=garbage run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  grep -q 'must be a positive integer' "$WORKDIR/out.log"
}

@test "test-runner: TEST_RUNNER_MAX_JOBS=0 — returns 1 instead of hanging" {
  mk a PASS
  TEST_RUNNER_MAX_JOBS=0 run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# Digits alone were not enough: a digit string past the shell's integer range
# made the same comparison error out and the cap disappear.
@test "test-runner: TEST_RUNNER_MAX_JOBS beyond the integer range — returns 1" {
  mk a PASS
  TEST_RUNNER_MAX_JOBS=999999999999999999999999999 run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# `[ -f ]` follows symlinks. One test file pointing at another runs the target
# twice and never runs the file it replaced, while every count still looks
# right — the gate stayed green through exactly this.
@test "test-runner: a symlinked test file — returns 1, is not run" {
  mk a PASS; mk b PASS
  rm "$WORKDIR/tests/b.bats"
  ln -s a.bats "$WORKDIR/tests/b.bats"
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  grep -q 'is not a regular file' "$WORKDIR/out.log"
}

@test "test-runner: a broken symlink — returns 1" {
  mk a PASS
  ln -s nowhere.bats "$WORKDIR/tests/z.bats"
  run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# Unbounded concurrency would track the number of test files. The cap is the
# difference between a parallel suite and a fork bomb on a small machine.
@test "test-runner: concurrency stays within TEST_RUNNER_MAX_JOBS" {
  cat >"$WORKDIR/mockbin/bats" <<STUB
#!/usr/bin/env bash
d="$WORKDIR/live"
mkdir -p "\$d"
: >"\$d/\$\$"
ls "\$d" | wc -l | tr -d ' ' >>"$WORKDIR/peak"
sleep 0.5
rm -f "\$d/\$\$"
echo "ok 1 - \$1"
STUB
  chmod +x "$WORKDIR/mockbin/bats"
  for i in 1 2 3 4 5 6; do mk "f$i" PASS; done

  TEST_RUNNER_MAX_JOBS=2 run run_suite "$WORKDIR/out.log" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
  peak="$(sort -n "$WORKDIR/peak" | tail -1)"
  [ "$peak" -le 2 ]
}
