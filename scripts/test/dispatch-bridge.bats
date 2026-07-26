#!/usr/bin/env bats
# dispatch-bridge.bats — Acceptance tests for operator/dispatch.sh.
#
# Tests the explicit bridge between heartbeat.sh (decide) and run.sh (execute).
# Every test supplies its own HEARTBEAT_CMD stub and RUN_ROOT in a mktemp dir.
# Each asserts an EXIT CODE and a distinctive substring.
#
# Hermetic: no real heartbeat.sh is invoked, no real operator/.runs is touched.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  DISPATCH="$REPO_ROOT/operator/dispatch.sh"

  # Each test gets its own run-directory root
  RUN_ROOT="$(mktemp -d)"
  export RUN_ROOT
}

teardown() {
  # Always prune worktrees under this test's RUN_ROOT
  if [ -n "${RUN_ROOT:-}" ] && [ -d "$RUN_ROOT" ]; then
    for wt_dir in "$RUN_ROOT"/*/wt; do
      [ -d "$wt_dir" ] && git -C "$REPO_ROOT" worktree remove --force "$wt_dir" 2>/dev/null || true
    done
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    rm -rf "$RUN_ROOT"
  fi

  # Clean up any temporary templates created by tests
  if [ -n "${_TMP_TEMPLATE:-}" ] && [ -f "$_TMP_TEMPLATE" ]; then
    rm -f "$_TMP_TEMPLATE"
  fi
}

# Helper: create a stub heartbeat script that prints the given lines to stdout.
# Each argument is a line of output.
_stub_heartbeat() {
  local tmpfile
  tmpfile="$(mktemp "${TMPDIR:-/tmp}/stub.XXXXXX")"
  {
    printf '#!/usr/bin/env bash\n'
    for line in "$@"; do
      printf 'echo '\''%s'\''\n' "$line"
    done
  } > "$tmpfile"
  chmod +x "$tmpfile"
  echo "$tmpfile"
}

# ---------------------------------------------------------------------------
# 1. HOLD — non-BUILD action exits 0, prints "nothing to execute",
#    RUN_ROOT stays empty.
# ---------------------------------------------------------------------------

@test "dispatch-bridge: HOLD — non-BUILD action exits 0, does nothing" {
  STUB="$(_stub_heartbeat "ACTION: HOLD nothing to do")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to execute"* ]]

  # RUN_ROOT must be empty (no directories, no files)
  run ls -A "$RUN_ROOT"
  [ "$status" -ne 0 ] || [ -z "$output" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 2. REVIEW — non-BUILD action exits 0, prints "nothing to execute",
#    RUN_ROOT stays empty.
# ---------------------------------------------------------------------------

@test "dispatch-bridge: REVIEW — non-BUILD action exits 0, does nothing" {
  STUB="$(_stub_heartbeat "ACTION: REVIEW PR #81")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to execute"* ]]

  run ls -A "$RUN_ROOT"
  [ "$status" -ne 0 ] || [ -z "$output" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 3. NO TEMPLATE — BUILD action for an issue with no template exits 3,
#    prints "no work order template", RUN_ROOT stays empty.
# ---------------------------------------------------------------------------

@test "dispatch-bridge: NO TEMPLATE — missing template exits 3" {
  STUB="$(_stub_heartbeat "ACTION: BUILD issue #999")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  [ "$status" -eq 3 ]
  [[ "$output" == *"no work order template"* ]]

  run ls -A "$RUN_ROOT"
  [ "$status" -ne 0 ] || [ -z "$output" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 4. DRY RUN — BUILD issue #0 with --dry-run exits 0, stdout is a valid work
#    order, base_sha matches HEAD, issue is 0, no result.json anywhere.
# ---------------------------------------------------------------------------

@test "dispatch-bridge: DRY RUN — prints work order, does not invoke run.sh" {
  STUB="$(_stub_heartbeat "ACTION: BUILD issue #0")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH" --dry-run

  [ "$status" -eq 0 ]

  # stdout must be valid JSON containing the expected fields
  BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  ISSUE="$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['issue'])")"
  WO_BASE_SHA="$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['base_sha'])")"

  [ "$ISSUE" = "0" ]
  [ "$WO_BASE_SHA" = "$BASE_SHA" ]

  # No result.json anywhere under RUN_ROOT
  run find "$RUN_ROOT" -name "result.json" 2>/dev/null
  [ "$status" -ne 0 ] || [ -z "$output" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 5. END TO END — BUILD issue #0 with a real template, no --dry-run.
#    Exits 0, result.json exists with verdict "accepted".
# ---------------------------------------------------------------------------

@test "dispatch-bridge: END TO END — accepted when everything is clean" {
  STUB="$(_stub_heartbeat "ACTION: BUILD issue #0")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  [ "$status" -eq 0 ]

  # Find result.json — it's under a wo-0-* directory
  RESULT="$(find "$RUN_ROOT" -name "result.json" | head -1)"
  [ -n "$RESULT" ]
  [ -f "$RESULT" ]

  VERDICT="$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")"
  [ "$VERDICT" = "accepted" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 6. FORBIDDEN END TO END — template forbids "operator/", the fake builder
#    touches operator/.fake-marker. Exits non-zero, result.json verdict "rejected".
# ---------------------------------------------------------------------------

@test "dispatch-bridge: FORBIDDEN END TO END — rejected when builder touches forbidden path" {
  # Create a temporary template for issue 999 that forbids operator/
  _TMP_TEMPLATE="$REPO_ROOT/operator/work-orders/999.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-999-0',
    'issue': 999,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['src/'],
    'forbidden_paths': ['operator/'],
    'acceptance_commands': ['true'],
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_TEMPLATE', 'w') as f:
    json.dump(wo, f, indent=2)
"

  STUB="$(_stub_heartbeat "ACTION: BUILD issue #999")"
  HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  # Clean up immediately after dispatch runs
  rm -f "$_TMP_TEMPLATE"
  _TMP_TEMPLATE=""

  [ "$status" -ne 0 ]

  RESULT="$(find "$RUN_ROOT" -name "result.json" | head -1)"
  [ -n "$RESULT" ]
  [ -f "$RESULT" ]

  VERDICT="$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")"
  [ "$VERDICT" = "rejected" ]

  rm -f "$STUB"
}

# ---------------------------------------------------------------------------
# 7. INVALID TEMPLATE — schema violation (acceptance_commands is a string
#    instead of an array) exits 4, names the failure, does not invoke run.sh.
# ---------------------------------------------------------------------------

@test "dispatch-bridge: INVALID TEMPLATE — schema violation exits 4, no run.sh invoked" {
  # Hermetic template directory
  _TMP_WO_DIR="$(mktemp -d)"

  # acceptance_commands is the string "true" instead of the required array
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-7-1',
    'issue': 7,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': ['src/'],
    'forbidden_paths': [],
    'acceptance_commands': 'true',
    'builder': 'operator/builders/fake.sh'
}
with open('$_TMP_WO_DIR/7.json', 'w') as f:
    json.dump(wo, f, indent=2)
"

  STUB="$(_stub_heartbeat "ACTION: BUILD issue #7")"
  WORK_ORDERS_DIR="$_TMP_WO_DIR" HEARTBEAT_CMD="$STUB" run bash "$DISPATCH"

  # Clean up the temp template directory
  rm -rf "$_TMP_WO_DIR"

  [ "$status" -eq 4 ]
  [[ "$output" == *"VALIDATION ERROR"* ]]
  [[ "$output" == *"acceptance_commands"* ]]

  # run.sh was NOT invoked: no result.json anywhere under RUN_ROOT
  run find "$RUN_ROOT" -name "result.json" 2>/dev/null
  [ "$status" -ne 0 ] || [ -z "$output" ]

  rm -f "$STUB"
}
