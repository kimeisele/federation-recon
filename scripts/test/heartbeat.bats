#!/usr/bin/env bats
# heartbeat.bats — Unit tests for operator/heartbeat.sh
#
# Tests: HOLD on clean state, REVIEW on open PR, WIP cap enforcement.
# Fully offline — mocks `gh` and `git` via PATH-based wrapper scripts.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

  # Create a temporary workspace with operator/ and mockbin/
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/operator" "$WORKDIR/mockbin"

  # Copy heartbeat.sh into the workspace
  cp "$REPO_ROOT/operator/heartbeat.sh" "$WORKDIR/operator/heartbeat.sh"
  chmod +x "$WORKDIR/operator/heartbeat.sh"

  # Export WORKDIR for _write_state helper
  export WORKDIR
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'
}

teardown() {
  rm -rf "$WORKDIR"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_write_state() {
  local content="$1"
  printf '%s\n' "$content" > "$WORKDIR/operator/state.json"
}

# Build mock scripts in mockbin/ and run heartbeat.sh under that PATH.
# If a mock gh already exists (specialized test), it is preserved.
_heartbeat_with_mocks() {
  local state_json="$1"
  _write_state "$state_json"

  # Only create default mock gh if none exists yet.
  if [ ! -f "$WORKDIR/mockbin/gh" ]; then
    cat > "$WORKDIR/mockbin/gh" << 'GHSCRIPT'
#!/usr/bin/env bash
echo "$MOCK_GH_OUTPUT"
GHSCRIPT
    chmod +x "$WORKDIR/mockbin/gh"
  fi

  # Always (re)create mock git.
  cat > "$WORKDIR/mockbin/git" << 'GITSCRIPT'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
  if [ "$1" = "-C" ]; then
    shift 2
  else
    shift
  fi
done
if [ "${1:-}" = "diff" ] && [ "${2:-}" = "--quiet" ]; then
  test "$MOCK_GIT_DIRTY" = "clean" && exit 0 || exit 1
fi
/usr/bin/git "$@"
GITSCRIPT
  chmod +x "$WORKDIR/mockbin/git"

  PATH="$WORKDIR/mockbin:$PATH" bash "$WORKDIR/operator/heartbeat.sh" 2>&1
}

# ---------------------------------------------------------------------------
# Test: HOLD on clean state (no PRs, no issues, post-bootstrap)
# ---------------------------------------------------------------------------

@test "heartbeat: HOLD on clean state (no PRs, no issues, post-bootstrap)" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"HOLD"* ]]
}

# ---------------------------------------------------------------------------
# Test: ADVANCE from bootstrap when git is clean
# ---------------------------------------------------------------------------

@test "heartbeat: ADVANCE from bootstrap when git is clean" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"0_BOOTSTRAP","cycle":0,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ADVANCE"* ]]
}

# ---------------------------------------------------------------------------
# Test: STOP on dirty git tree during bootstrap
# ---------------------------------------------------------------------------

@test "heartbeat: STOP on dirty git tree during bootstrap" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='dirty'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"0_BOOTSTRAP","cycle":0,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
  [[ "$output" == *"STOP"* ]]
}

# ---------------------------------------------------------------------------
# Test: REVIEW when an open PR exists
# ---------------------------------------------------------------------------

@test "heartbeat: REVIEW when an open PR exists" {
  export MOCK_GH_OUTPUT='[{"number":42,"title":"Test PR","createdAt":"2026-07-24T00:00:00Z","labels":[]}]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"REVIEW"* ]]
  [[ "$output" == *"42"* ]]
}

# ---------------------------------------------------------------------------
# Test: WIP cap — STOP when >1 open PR
# ---------------------------------------------------------------------------

@test "heartbeat: STOP when WIP cap violated (>1 open PR)" {
  export MOCK_GH_OUTPUT='[{"number":1},{"number":2}]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"STOP"* ]]
  [[ "$output" == *"WIP"* ]]
}

# ---------------------------------------------------------------------------
# Test: BUILD when approved issue exists and WIP=0
# ---------------------------------------------------------------------------

@test "heartbeat: BUILD when approved issue exists and WIP=0" {
  # gh returns approved issues list; the python3 DELEGATE logic makes subprocess
  # calls to gh, so we need the mock to handle those too.
  # The python3 subprocess also calls gh, so the mock sees those calls.
  # Strategy: the mock returns empty for search queries (issue_has_open_pr check)
  # and approved issues for issue list.
  cat > "$WORKDIR/mockbin/gh" << 'GHSCRIPT'
#!/usr/bin/env bash
if [[ "$*" == *"search"* ]]; then
  echo '[]'
elif [[ "$*" == *"issue"* ]] && [[ "$*" == *"approved"* ]]; then
  echo '[{"number":29,"title":"OPERATOR BOOTSTRAP","createdAt":"2026-07-24T00:00:00Z"}]'
elif [[ "$*" == *"pr list"* ]] && [[ "$*" == *"limit"* ]]; then
  echo '[]'
else
  echo '[]'
fi
GHSCRIPT
  chmod +x "$WORKDIR/mockbin/gh"
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"BUILD"* ]]
  [[ "$output" == *"29"* ]]
}

# ---------------------------------------------------------------------------
# Test: STOP on budget cap (expert calls exhausted)
# ---------------------------------------------------------------------------

@test "heartbeat: STOP when expert calls budget is exhausted" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":3,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"STOP"* ]]
  [[ "$output" == *"budget"* ]]
}

# ---------------------------------------------------------------------------
# Test: state.json advances phase field after bootstrap
# ---------------------------------------------------------------------------

@test "heartbeat: advances state.json phase field after bootstrap" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'

  run _heartbeat_with_mocks \
    '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"0_BOOTSTRAP","cycle":0,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
  [ "$status" -eq 0 ]

  # After bootstrap advance, state should now have phase 1_CLASSIFY
  local new_phase
  new_phase="$(python3 -c "import json; print(json.load(open('$WORKDIR/operator/state.json'))['phase'])" 2>/dev/null)"
  [ "$new_phase" = "1_CLASSIFY" ]
}

# ---------------------------------------------------------------------------
# Test: determinism — same inputs produce same output
# ---------------------------------------------------------------------------

@test "heartbeat: deterministic — same state produces same action" {
  export MOCK_GH_OUTPUT='[]'
  export MOCK_GIT_DIRTY='clean'

  local state='{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'

  run1="$(_heartbeat_with_mocks "$state")"
  # Reset state for second run
  _write_state "$state"
  run2="$(_heartbeat_with_mocks "$state")"

  # Both should contain HOLD
  [[ "$run1" == *"HOLD"* ]]
  [[ "$run2" == *"HOLD"* ]]
}
