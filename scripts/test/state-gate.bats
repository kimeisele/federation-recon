#!/usr/bin/env bats
# state-gate.bats — Tests for the scheduled run state gate (#79).
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
