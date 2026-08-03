#!/usr/bin/env bats
# budget-cycle-reset.bats — Issue #171 regression tests.
#
# The expert-call budget (budget.expert_calls_this_cycle) is a per-cycle
# counter. The 0_BOOTSTRAP -> 1_CLASSIFY transition advances the cycle number
# AND resets the counter to 0 in a single crash-safe write. Before #171 the
# counter was preserved across the advance, so once max_expert was reached the
# budget cap STOP at heartbeat.sh:1079 blocked REVIEW forever.
#
# Uses REAL heartbeat.sh with mocked gh/git. No network.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$WORKDIR/operator" "$WORKDIR/mockbin"
  chmod 0700 "$WORKDIR/operator"
  cp "$REPO_ROOT/operator/heartbeat.sh" "$WORKDIR/operator/heartbeat.sh"
  chmod +x "$WORKDIR/operator/heartbeat.sh"

  export WORKDIR
  export MOCK_PRS='[]'
  export MOCK_ISSUES='[]'
  export MOCK_GH_FAIL_ON=''
  export MOCK_GH_CWD="$WORKDIR"
  export MOCK_GIT_DIRTY='clean'
  export MOCK_GIT_FAIL='false'
  export HEARTBEAT_NOW='2026-07-24T12:00:00Z'

  cat > "$WORKDIR/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ -n "${MOCK_GH_CWD:-}" ] && [ "$PWD" != "$MOCK_GH_CWD" ]; then
  exit 4
fi
if [ -n "${GH_REPO:-}" ]; then
  exit 5
fi
if [ -n "${GH_HOST:-}" ]; then
  exit 6
fi
if [ "$MOCK_GH_FAIL_ON" = "all" ] || [ "$MOCK_GH_FAIL_ON" = "${1:-}" ]; then
  exit 1
fi
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "$MOCK_PRS" ;;
  "issue list") printf '%s\n' "$MOCK_ISSUES" ;;
  *) exit 2 ;;
esac
GHSCRIPT
  chmod +x "$WORKDIR/mockbin/gh"

  cat > "$WORKDIR/mockbin/git" <<'GITSCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
if [ "${1:-}" = "status" ]; then
  [ "$MOCK_GIT_FAIL" = "false" ] || exit 1
  [ "$MOCK_GIT_DIRTY" = "clean" ] || printf ' M operator/state.json\n'
  exit 0
fi
exec /usr/bin/git "$@"
GITSCRIPT
  chmod +x "$WORKDIR/mockbin/git"
}

teardown() {
  rm -rf "$WORKDIR"
}

_state() {
  local phase="${1:-1_CLASSIFY}" cycle="${2:-1}" used="${3:-0}" maximum="${4:-3}"
  printf '{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"%s","cycle":%s,"budget":{"expert_calls_this_cycle":%s,"max_expert_calls":%s},"last_heartbeat":"2026-07-24T00:00:00Z","notes":"","previous_checkpoint":null}' \
    "$phase" "$cycle" "$used" "$maximum"
}

_write_state() {
  local content="$1" path="${2:-$WORKDIR/operator/state.json}"
  printf '%s\n' "$content" > "$path"
  chmod 0600 "$path"
}

_field() {
  python3 -c "
import json, sys
value = json.load(open(sys.argv[1]))
for part in '$2'.split('.'):
    value = value[part]
print(value)
" "$1"
}

_run_heartbeat() {
  PATH="$WORKDIR/mockbin:$PATH" \
    HEARTBEAT_NOW="$HEARTBEAT_NOW" \
    /bin/bash "$WORKDIR/operator/heartbeat.sh" "$@" 2>&1
}

# ────────────────────────────────────────────────────────────
#  1. CYCLE ADVANCE — 0_BOOTSTRAP -> 1_CLASSIFY resets the budget
# ────────────────────────────────────────────────────────────

@test "budget-cycle-reset: cycle advance resets fully consumed budget to 0" {
  _write_state "$(_state 0_BOOTSTRAP 2 3 3)"

  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
  [ "$(_field "$WORKDIR/operator/state.json" phase)" = "1_CLASSIFY" ]
  [ "$(_field "$WORKDIR/operator/state.json" cycle)" = "3" ]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "0" ]
}

# ────────────────────────────────────────────────────────────
#  2. BUDGET CAP — still blocks within a cycle
# ────────────────────────────────────────────────────────────

@test "budget-cycle-reset: budget cap still STOPs within a cycle" {
  _write_state "$(_state 1_CLASSIFY 3 3 3)"
  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"budget cap"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
  # Counter untouched by the refusal
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "3" ]
}

# ────────────────────────────────────────────────────────────
#  3. AFTER RESET — expert calls work again
# ────────────────────────────────────────────────────────────

@test "budget-cycle-reset: after cycle advance the budget cap no longer blocks" {
  _write_state "$(_state 0_BOOTSTRAP 2 3 3)"

  # Cycle terminal transition: cycle advances, budget resets
  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "0" ]

  # Same cycle now has room: approved work dispatches instead of STOP
  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'
  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: BUILD issue #42"* ]]
  [[ "$output" != *"budget cap"* ]]
}

@test "budget-cycle-reset: --record-expert-call works from the reset counter" {
  _write_state "$(_state 0_BOOTSTRAP 2 3 3)"

  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"
  [ "$status" -eq 0 ]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "0" ]

  run _run_heartbeat --record-expert-call --state-file "$WORKDIR/operator/state.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"expert calls: 1/3"* ]]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "1" ]
}

# ────────────────────────────────────────────────────────────
#  4. AUDIT — previous_checkpoint preserves the pre-reset state
# ────────────────────────────────────────────────────────────

@test "budget-cycle-reset: previous_checkpoint preserves pre-reset budget and cycle" {
  _write_state "$(_state 0_BOOTSTRAP 4 2 3)"

  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"

  [ "$status" -eq 0 ]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "0" ]
  [ "$(_field "$WORKDIR/operator/state.json" cycle)" = "5" ]
  # Pre-reset state is the audit snapshot
  [ "$(_field "$WORKDIR/operator/state.json" previous_checkpoint.phase)" = "0_BOOTSTRAP" ]
  [ "$(_field "$WORKDIR/operator/state.json" previous_checkpoint.cycle)" = "4" ]
  [ "$(_field "$WORKDIR/operator/state.json" previous_checkpoint.expert_calls_this_cycle)" = "2" ]
  [ "$(_field "$WORKDIR/operator/state.json" previous_checkpoint.max_expert_calls)" = "3" ]
}

# ────────────────────────────────────────────────────────────
#  5. NO TICK RESET — HOLD within a cycle preserves the budget
# ────────────────────────────────────────────────────────────

@test "budget-cycle-reset: HOLD tick within a cycle does not reset the budget" {
  _write_state "$(_state 1_CLASSIFY 3 1 3)"

  run _run_heartbeat --state-file "$WORKDIR/operator/state.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
  [ "$(_field "$WORKDIR/operator/state.json" cycle)" = "3" ]
  [ "$(_field "$WORKDIR/operator/state.json" budget.expert_calls_this_cycle)" = "1" ]
}
