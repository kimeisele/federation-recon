#!/usr/bin/env bats
# state-gate.bats
#
# ── The committed fixtures carry absolute timestamps and therefore ROT ─────
#
# On 2026-07-31 at ~20:45 CEST, six tests in this file began failing. Nothing
# had changed: green-history.json's newest run had simply crossed 30 hours old,
# and 30 hours is the staleness threshold. The CI run that merged these tests
# earlier the same day passed because the fixture was younger then.
#
# So every test here that is ABOUT the conclusion — RED, GREEN, mixed — was
# silently also a test of whether the fixture was young, and would have started
# reporting a staleness verdict for a red history and called it a pass or a
# failure depending only on the clock.
#
# Those tests now pin STATE_GATE_STALE_THRESHOLD_HOURS to a value no fixture
# can outlive, so they test the thing they are named for. The tests that ARE
# about staleness keep the real threshold and use fixtures that are old on
# purpose — for them, age is the subject rather than an accident.
#
# The general shape, which this repository keeps meeting: a check that appears
# to test one property while its outcome is decided by another.
# state-gate.bats — Tests for the scheduled run state gate (#79, #92).
#
# Every test asserts a return code. A test that only greps output is not
# accepted.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE_DIR="$REPO_ROOT/scripts/test/fixtures/state-gate"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/state-gate.sh"
}

# ---------------------------------------------------------------------------
# Library: red-history
# ---------------------------------------------------------------------------

@test "state-gate: red-history returns 1 with STATE: RED and run ID" {
  # See the header: the threshold is pinned so that a fixture aging past 30
  # hours cannot turn a test about the CONCLUSION into a test about the clock.
  STATE_GATE_STALE_THRESHOLD_HOURS=1000000
  run check_scheduled_run_state "$FIXTURE_DIR/red-history.json" "node-census.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STATE: RED"* ]]
  [[ "$output" == *"30194371789"* ]]
}

@test "state-gate: red-history reports consecutive failures: 3" {
  STATE_GATE_STALE_THRESHOLD_HOURS=1000000
  run check_scheduled_run_state "$FIXTURE_DIR/red-history.json" "node-census.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"consecutive failures: 3"* ]]
}

# ---------------------------------------------------------------------------
# Library: green-history
# ---------------------------------------------------------------------------

@test "state-gate: green-history returns 0 with STATE: GREEN" {
  STATE_GATE_STALE_THRESHOLD_HOURS=1000000
  run check_scheduled_run_state "$FIXTURE_DIR/green-history.json" "node-census.yml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE: GREEN"* ]]
}

# ---------------------------------------------------------------------------
# Library: empty-history
# ---------------------------------------------------------------------------

@test "state-gate: empty-history returns 2 with UNKNOWN and not GREEN" {
  run check_scheduled_run_state "$FIXTURE_DIR/empty-history.json" "node-census.yml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" == *"no scheduled runs on record"* ]]
  [[ "$output" != *"GREEN"* ]]
}

# ---------------------------------------------------------------------------
# Library: missing file
# ---------------------------------------------------------------------------

@test "state-gate: missing file returns 2" {
  run check_scheduled_run_state "/nonexistent/path/to/history.json" "node-census.yml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]]
}

# ---------------------------------------------------------------------------
# Library: malformed JSON
# ---------------------------------------------------------------------------

@test "state-gate: malformed JSON returns 2" {
  local tmp
  tmp="$(mktemp)"
  echo "not json" > "$tmp"
  run check_scheduled_run_state "$tmp" "node-census.yml"
  rm -f "$tmp"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid JSON"* ]]
}

# ---------------------------------------------------------------------------
# Wrapper: logging mode (default)
# ---------------------------------------------------------------------------

@test "state-gate: wrapper with red fixture in logging mode exits 0 and prints RED" {
  run env STATE_GATE_STALE_THRESHOLD_HOURS=1000000 STATE_GATE_FIXTURE="$FIXTURE_DIR/red-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE: RED"* ]]
}

# ---------------------------------------------------------------------------
# Wrapper: enforce mode
# ---------------------------------------------------------------------------

@test "state-gate: wrapper with red fixture and --enforce exits 1" {
  run env STATE_GATE_STALE_THRESHOLD_HOURS=1000000 STATE_GATE_FIXTURE="$FIXTURE_DIR/red-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  [ "$status" -eq 1 ]
}

@test "state-gate: wrapper with green fixture and --enforce exits 0" {
  run env STATE_GATE_STALE_THRESHOLD_HOURS=1000000 STATE_GATE_FIXTURE="$FIXTURE_DIR/green-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  [ "$status" -eq 0 ]
}

@test "state-gate: wrapper with empty fixture and --enforce exits 2" {
  run env STATE_GATE_FIXTURE="$FIXTURE_DIR/empty-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  [ "$status" -eq 2 ]
  [[ "$output" == *"no scheduled runs on record"* ]]
}

# ---------------------------------------------------------------------------
# Library: STALE – green run that is too old
# ---------------------------------------------------------------------------

@test "state-gate: stale-green returns 3 with STATE: STALE and run ID" {
  run check_scheduled_run_state "$FIXTURE_DIR/stale-green.json" "node-census.yml"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATE: STALE"* ]]
  [[ "$output" == *"30211552411"* ]]
}

# ---------------------------------------------------------------------------
# Library: STALE – red run that is too old
# ---------------------------------------------------------------------------

@test "state-gate: stale-red returns 3 with STATE: STALE and mentions failure" {
  run check_scheduled_run_state "$FIXTURE_DIR/stale-red.json" "node-census.yml"
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATE: STALE"* ]]
  [[ "$output" == *"failure"* ]]
}

# ---------------------------------------------------------------------------
# Library: inside threshold — green run still current
# ---------------------------------------------------------------------------

@test "state-gate: green with high threshold returns 0 with GREEN" {
  local tmp
  tmp="$(mktemp)"
  python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
ts = (now - datetime.timedelta(hours=199)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump([{
    'conclusion': 'success',
    'createdAt': ts,
    'databaseId': 30211552411,
    'event': 'schedule',
    'status': 'completed'
}], open('$tmp', 'w'))
"
  STATE_GATE_STALE_THRESHOLD_HOURS=200 \
    run check_scheduled_run_state "$tmp" "node-census.yml"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE: GREEN"* ]]
}

# ---------------------------------------------------------------------------
# Library: 26-hour-old green run — inside default 30 h threshold
# ---------------------------------------------------------------------------

@test "state-gate: 26-hour-old green run returns 0 with GREEN (inside tolerance)" {
  # Generate a fixture with a green run timestamped ~26h ago.
  local tmp
  tmp="$(mktemp)"
  python3 -c "
import json, datetime
now = datetime.datetime.now(datetime.timezone.utc)
ts_26h = (now - datetime.timedelta(hours=26)).strftime('%Y-%m-%dT%H:%M:%SZ')
json.dump([{
    'conclusion': 'success',
    'createdAt': ts_26h,
    'databaseId': 99999999999,
    'event': 'schedule',
    'status': 'completed'
}], open('$tmp', 'w'))
"
  run check_scheduled_run_state "$tmp" "node-census.yml"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE: GREEN"* ]]
}

# ---------------------------------------------------------------------------
# Wrapper: stale fixture in enforce mode
# ---------------------------------------------------------------------------

@test "state-gate: wrapper with stale-green fixture and --enforce exits 3" {
  run env STATE_GATE_FIXTURE="$FIXTURE_DIR/stale-green.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  [ "$status" -eq 3 ]
  [[ "$output" == *"STATE: STALE"* ]]
}

# ---------------------------------------------------------------------------
# Rot detection
# ---------------------------------------------------------------------------

@test "state-gate: no conclusion test can be decided by the wall clock" {
  # The defect this file was repaired for, stated as a property rather than
  # left to the header comment. On 2026-07-31 six tests here began failing
  # because a committed fixture had aged past the staleness threshold — the CI
  # run that merged them hours earlier had passed. Nothing had changed except
  # the time.
  #
  # Every invocation that uses a fixture whose subject is the CONCLUSION must
  # pin the threshold. If someone adds a red/green/mixed case without pinning
  # it, that case will pass today and start failing on a date nobody chose.
  run python3 - "$BATS_TEST_FILENAME" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
# Split into @test blocks.
blocks = re.split(r'(?=^@test )', src, flags=re.M)
bad = []
for b in blocks:
    if not b.startswith('@test '):
        continue
    name = b.split('"')[1] if '"' in b else b[:40]
    uses_conclusion_fixture = any(f in b for f in
        ("red-history.json", "green-history.json", "mixed-history.json"))
    if not uses_conclusion_fixture:
        continue
    if "STATE_GATE_STALE_THRESHOLD_HOURS" not in b:
        bad.append(name)
if bad:
    print("conclusion tests that the clock can decide:")
    for n in bad:
        print("  -", n)
    sys.exit(1)
print("every conclusion test pins the staleness threshold")
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "state-gate: the staleness tests still use the real threshold" {
  # The counterpart. Pinning everything would silently disable the staleness
  # checks, which is the failure in the other direction: a suite that cannot
  # fail is not a safer suite.
  run python3 - "$BATS_TEST_FILENAME" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
blocks = re.split(r'(?=^@test )', src, flags=re.M)
pinned = []
for b in blocks:
    if not b.startswith('@test '):
        continue
    name = b.split('"')[1] if '"' in b else b[:40]
    if any(f in b for f in ("stale-green.json", "stale-red.json")):
        # These may pin a threshold deliberately (test 13 raises it to prove
        # the opposite direction), but at least one must run at the default.
        if "STATE_GATE_STALE_THRESHOLD_HOURS" not in b:
            pinned.append(name)
if not pinned:
    print("no staleness test runs at the real threshold")
    sys.exit(1)
print("%d staleness test(s) run at the real threshold" % len(pinned))
PY
  echo "$output"
  [ "$status" -eq 0 ]
}
