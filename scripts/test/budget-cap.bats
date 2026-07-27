#!/usr/bin/env bats
# budget-cap.bats — End-to-end tests for budget cap enforcement.
#
# Tests that expert_calls_this_cycle is incremented when builder runs,
# that the cap STOP is enforced by dispatch.sh, and that the counter
# is never incremented on refusals or missing templates.
#
# Uses REAL heartbeat.sh and dispatch.sh. No network.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$WORKDIR/operator" "$WORKDIR/mockbin"
  chmod 0700 "$WORKDIR/operator"

  export WORKDIR
  export MOCK_PRS='[]'
  export MOCK_ISSUES='[]'
  export MOCK_GH_FAIL_ON=''
  export MOCK_GH_CWD="$REPO_ROOT"
  export MOCK_GIT_DIRTY='clean'
  export MOCK_GIT_FAIL='false'
  export HEARTBEAT_NOW='2026-07-24T12:00:00Z'

  # Mock gh — reads MOCK_PRS / MOCK_ISSUES
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

  # Mock git — intercepts status, passes through to real git for everything else
  cat > "$WORKDIR/mockbin/git" <<'GITSCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then
  # Intercept only status calls; pass everything else to real git with -C intact
  if [ "${3:-}" = "status" ]; then
    [ "$MOCK_GIT_FAIL" = "false" ] || exit 1
    [ "$MOCK_GIT_DIRTY" = "clean" ] || printf ' M operator/state.json\n'
    exit 0
  fi
  exec /usr/bin/git "$@"
fi
if [ "${1:-}" = "status" ]; then
  [ "$MOCK_GIT_FAIL" = "false" ] || exit 1
  [ "$MOCK_GIT_DIRTY" = "clean" ] || printf ' M operator/state.json\n'
  exit 0
fi
exec /usr/bin/git "$@"
GITSCRIPT
  chmod +x "$WORKDIR/mockbin/git"

  export PATH="$WORKDIR/mockbin:$PATH"
}

teardown() {
  # Clean up worktrees created under any RUN_ROOT from this test
  if [ -n "${_RUN_ROOT:-}" ] && [ -d "$_RUN_ROOT" ]; then
    for wt_dir in "$_RUN_ROOT"/*/wt; do
      [ -d "$wt_dir" ] && git -C "$REPO_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
    done
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    rm -rf "$_RUN_ROOT"
  fi

  # Clean up temporary template directory
  if [ -n "${_TMP_WO_DIR:-}" ] && [ -d "$_TMP_WO_DIR" ]; then
    rm -rf "$_TMP_WO_DIR"
  fi

  rm -rf "$WORKDIR"
}

# ────────────────────────────────────────────────────────────
#  Helpers
# ────────────────────────────────────────────────────────────

# Write a schema-v2 state file with given expert_calls_this_cycle and max_expert_calls
_state() {
  local used="${1:-0}" maximum="${2:-1}"
  printf '{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":%s,"max_expert_calls":%s},"last_heartbeat":"2026-07-24T00:00:00Z","notes":"","previous_checkpoint":null}' \
    "$used" "$maximum"
}

_write_state() {
  local content="$1" path="${2:-$WORKDIR/operator/state.json}"
  printf '%s\n' "$content" > "$path"
  chmod 0600 "$path"
}

_field() {
  python3 -c "import json; print(json.load(open('$1'))['budget']['expert_calls_this_cycle'])"
}

# Run dispatch with mocked gh/git, pointing heartbeat at our test state file.
_run_dispatch() {
  HEARTBEAT_CMD="bash $REPO_ROOT/operator/heartbeat.sh --dry-run --state-file $WORKDIR/operator/state.json" \
  HEARTBEAT_RECORD_CMD="bash $REPO_ROOT/operator/heartbeat.sh --record-expert-call --state-file $WORKDIR/operator/state.json" \
  WORK_ORDERS_DIR="${_TMP_WO_DIR:-$REPO_ROOT/operator/work-orders}" \
  RUN_ROOT="$_RUN_ROOT" \
    run bash "$REPO_ROOT/operator/dispatch.sh" "$@"
}

# ────────────────────────────────────────────────────────────
#  1. FIRST RUN — dispatch completes, counter incremented
# ────────────────────────────────────────────────────────────

@test "budget-cap: FIRST RUN — dispatch exits 0, counter becomes 1" {
  _write_state "$(_state 0 1)"
  _RUN_ROOT="$(mktemp -d)"

  # Template for issue 42 (approved)
  _TMP_WO_DIR="$(mktemp -d)"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-42-0',
    'issue': 42,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_WO_DIR/42.json', 'w') as f:
    json.dump(wo, f, indent=2)
"

  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  _run_dispatch

  [ "$status" -eq 0 ]

  # result.json must exist with verdict "accepted"
  RESULT="$(find "$_RUN_ROOT" -name "result.json" | head -1)"
  [ -n "$RESULT" ]
  [ -f "$RESULT" ]
  VERDICT="$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")"
  [ "$VERDICT" = "accepted" ]

  # Counter must be 1
  [ "$(_field "$WORKDIR/operator/state.json")" = "1" ]
}

# ────────────────────────────────────────────────────────────
#  2. SECOND RUN — cap reached, dispatch refuses
# ────────────────────────────────────────────────────────────

@test "budget-cap: SECOND RUN — dispatch exits 5 on budget cap STOP" {
  _write_state "$(_state 1 1)"
  _RUN_ROOT="$(mktemp -d)"

  _TMP_WO_DIR="$(mktemp -d)"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-42-0',
    'issue': 42,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_WO_DIR/42.json', 'w') as f:
    json.dump(wo, f, indent=2)
"

  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  _run_dispatch

  [ "$status" -eq 5 ]
  [[ "$output" == *"refused"* ]]
  [[ "$output" == *"budget cap"* ]]

  # run.sh was NOT invoked — no run directories created
  run find "$_RUN_ROOT" -name "result.json" 2>/dev/null
  [ "$status" -ne 0 ] || [ -z "$output" ]
}

# ────────────────────────────────────────────────────────────
#  3. RECORDER — --record-expert-call increments and prints
# ────────────────────────────────────────────────────────────

@test "budget-cap: RECORDER — increments counter from 0 to 1, prints 1/" {
  _write_state "$(_state 0 1)"

  run bash "$REPO_ROOT/operator/heartbeat.sh" --record-expert-call --state-file "$WORKDIR/operator/state.json"

  [ "$status" -eq 0 ]
  [[ "$output" == *"expert calls: 1/1"* ]]
  [ "$(_field "$WORKDIR/operator/state.json")" = "1" ]
}

# ────────────────────────────────────────────────────────────
#  4. DRY RUN — --record-expert-call with --dry-run refused
# ────────────────────────────────────────────────────────────

@test "budget-cap: DRY RUN — record-expert-call with --dry-run exits non-zero, counter unchanged" {
  _write_state "$(_state 0 1)"

  run bash "$REPO_ROOT/operator/heartbeat.sh" --record-expert-call --dry-run --state-file "$WORKDIR/operator/state.json"

  [ "$status" -ne 0 ]
  [ "$(_field "$WORKDIR/operator/state.json")" = "0" ]
}

# ────────────────────────────────────────────────────────────
#  5. NO RECORD ON REFUSAL — STOP does not consume budget
# ────────────────────────────────────────────────────────────

@test "budget-cap: NO RECORD ON REFUSAL — counter stays 1 after STOP" {
  _write_state "$(_state 1 1)"
  _RUN_ROOT="$(mktemp -d)"

  _TMP_WO_DIR="$(mktemp -d)"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-42-0',
    'issue': 42,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_WO_DIR/42.json', 'w') as f:
    json.dump(wo, f, indent=2)
"

  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  _run_dispatch

  [ "$status" -eq 5 ]
  # Counter must still be 1 — refusal must not consume budget
  [ "$(_field "$WORKDIR/operator/state.json")" = "1" ]
}

# ────────────────────────────────────────────────────────────
#  6. NO RECORD ON MISSING TEMPLATE — exit 3, counter unchanged
# ────────────────────────────────────────────────────────────

@test "budget-cap: NO RECORD ON MISSING TEMPLATE — exit 3, counter unchanged" {
  _write_state "$(_state 0 1)"
  _RUN_ROOT="$(mktemp -d)"

  _TMP_WO_DIR="$(mktemp -d)"
  # No template for issue 999 — _TMP_WO_DIR is empty

  export MOCK_ISSUES='[{"number":999,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  _run_dispatch

  [ "$status" -eq 3 ]
  [[ "$output" == *"no work order template"* ]]
  # Counter unchanged
  [ "$(_field "$WORKDIR/operator/state.json")" = "0" ]
}

# ────────────────────────────────────────────────────────────
#  7. COMPOSITION — first dispatch consumes budget, second refused
# ────────────────────────────────────────────────────────────

@test "budget-cap: COMPOSITION — one state file, two dispatches, second refused by first's record" {
  _write_state "$(_state 0 1)"
  _RUN_ROOT="$(mktemp -d)"

  _TMP_WO_DIR="$(mktemp -d)"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-42-0',
    'issue': 42,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_WO_DIR/42.json', 'w') as f:
    json.dump(wo, f, indent=2)
"

  export MOCK_ISSUES='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z","labels":[{"name":"approved"}]}]'

  # First dispatch: exits 0 and increments the counter
  _run_dispatch
  [ "$status" -eq 0 ]
  [ "$(_field "$WORKDIR/operator/state.json")" = "1" ]

  # Second dispatch: re-reads the same state file (NOT rewritten)
  # and must be refused because the first dispatch consumed the budget
  _run_dispatch
  [ "$status" -eq 5 ]
  [[ "$output" == *"budget cap"* ]]

  # No second run directory was created
  [ ! -d "$_RUN_ROOT/wo-42-2" ]

  # Counter is still 1 — refusal did not consume budget
  [ "$(_field "$WORKDIR/operator/state.json")" = "1" ]
}
