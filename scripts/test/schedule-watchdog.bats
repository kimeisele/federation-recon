#!/usr/bin/env bats
# schedule-watchdog.bats — the control that #117 says was missing must stay wired.
#
# scripts/state-gate.sh has had an --enforce mode since it was written. Without
# that flag it prints its verdict and exits 0 — reporting mode, useful at a
# terminal and useless as a control. Dropping the flag from the workflow would
# leave a green watchdog that cannot fail, which is a worse state than the one
# #117 described: an absent control is at least visibly absent.
#
# These tests read the workflow file. They cannot prove GitHub runs it — nothing
# inside this repository can — but they can prove that what would run is a gate
# rather than a report.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WF="$REPO_ROOT/.github/workflows/schedule-watchdog.yml"
}

@test "schedule-watchdog: the workflow exists" {
  [ -f "$WF" ]
}

@test "schedule-watchdog: it invokes the state gate with --enforce" {
  # The whole of #117 in one assertion. Without --enforce the step exits 0 for
  # every verdict including STALE, and the workflow reports success forever.
  #
  # Comments are stripped BEFORE matching, and that is not tidiness. The first
  # version of this test grepped the whole file, and the file's own header
  # comment contains the words "state-gate.sh has had an --enforce mode" — so
  # deleting the flag from the actual command left the test green. Mutation
  # testing caught it. A test that can be satisfied by prose describing the
  # mechanism is a test of the prose.
  run bash -c "sed 's/#.*//' '$WF' | grep -E 'state-gate\.sh[^|]*--enforce'"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "schedule-watchdog: it is triggered by something, on a schedule" {
  run grep -E "^ *- cron:" "$WF"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "schedule-watchdog: it can read workflow history" {
  # gh run list needs actions: read. Without it the gate returns UNKNOWN, which
  # is a failure rather than a false green — but it would fail every day for a
  # permissions reason while looking like a staleness alarm.
  run grep -E "^ *actions: read" "$WF"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "schedule-watchdog: the state gate really does exit non-zero on STALE" {
  # The property the workflow depends on, exercised rather than assumed, using
  # a fixture so the test needs no network and no gh.
  fixture="$BATS_TEST_TMPDIR/stale.json"
  old="$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=96)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  cat > "$fixture" <<JSON
[{"conclusion":"success","databaseId":1,"createdAt":"$old","status":"completed","event":"schedule"}]
JSON
  run env STATE_GATE_FIXTURE="$fixture" bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  echo "status=$status output=$output"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STALE"* ]]
}

@test "schedule-watchdog: without --enforce the same input exits 0" {
  # Stated as a test so the reason --enforce matters is recorded as behaviour
  # rather than as a comment somebody can disagree with.
  fixture="$BATS_TEST_TMPDIR/stale2.json"
  old="$(python3 -c "
import datetime
print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=96)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  cat > "$fixture" <<JSON
[{"conclusion":"success","databaseId":1,"createdAt":"$old","status":"completed","event":"schedule"}]
JSON
  run env STATE_GATE_FIXTURE="$fixture" bash "$REPO_ROOT/scripts/state-gate.sh"
  echo "status=$status output=$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE"* ]]
}
