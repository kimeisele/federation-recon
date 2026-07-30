#!/usr/bin/env bats
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
  run check_scheduled_run_state "$FIXTURE_DIR/red-history.json" "node-census.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"STATE: RED"* ]]
  [[ "$output" == *"30194371789"* ]]
}

@test "state-gate: red-history reports consecutive failures: 3" {
  run check_scheduled_run_state "$FIXTURE_DIR/red-history.json" "node-census.yml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"consecutive failures: 3"* ]]
}

# ---------------------------------------------------------------------------
# Library: green-history
# ---------------------------------------------------------------------------

@test "state-gate: green-history returns 0 with STATE: GREEN" {
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
  run env STATE_GATE_FIXTURE="$FIXTURE_DIR/red-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATE: RED"* ]]
}

# ---------------------------------------------------------------------------
# Wrapper: enforce mode
# ---------------------------------------------------------------------------

@test "state-gate: wrapper with red fixture and --enforce exits 1" {
  run env STATE_GATE_FIXTURE="$FIXTURE_DIR/red-history.json" \
    bash "$REPO_ROOT/scripts/state-gate.sh" --enforce
  [ "$status" -eq 1 ]
}

@test "state-gate: wrapper with green fixture and --enforce exits 0" {
  run env STATE_GATE_FIXTURE="$FIXTURE_DIR/green-history.json" \
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
  STATE_GATE_STALE_THRESHOLD_HOURS=200 \
    run check_scheduled_run_state "$FIXTURE_DIR/green-history.json" "node-census.yml"
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
