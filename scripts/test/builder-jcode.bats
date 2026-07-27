#!/usr/bin/env bats
# builder-jcode.bats — Acceptance tests for operator/builders/jcode.sh.
#
# Tests the jcode builder against a stub jcode on PATH. Every test
# asserts an exit code and a distinctive substring. No test invokes
# a real model or reaches the network.
#
# Hermetic: each test controls its own git repo as the worktree and
# its own stub jcode on PATH.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  BUILDER="$REPO_ROOT/operator/builders/jcode.sh"

  # Each test gets its own temp directory for stubs and work orders
  WORKDIR="$(mktemp -d)"

  # Create a fake git repo as the "worktree" so git status --porcelain works
  WT="$(mktemp -d)"
  git -C "$WT" init --quiet
  git -C "$WT" config user.email "test@test"
  git -C "$WT" config user.name "Test"
  git -C "$WT" commit --allow-empty -m "init" --quiet
  export WT

  # Create stub jcode on PATH
  cat > "$WORKDIR/jcode" <<'JCODESTUB'
#!/usr/bin/env bash
# Stub jcode for builder tests.
#
# Records every invocation to $JCODE_LOG.
# When called as 'jcode usage', prints a stub usage line.
# When called as 'jcode run ...', extracts the -C dir, optionally touches
# files listed in $JCODE_STUB_TOUCH (space-separated, relative to -C dir),
# and exits with $JCODE_STUB_EXIT (default 0).

echo "$@" >> "${JCODE_LOG:-/dev/null}"

case "${1:-}" in
  usage)
    echo "stub usage output: tokens_total=42"
    exit 0
    ;;
esac

# Extract -C dir from arguments
C_DIR=""
args=("$@")
i=0
while [ $i -lt $# ]; do
  case "${args[$i]}" in
    -C)
      i=$((i + 1))
      C_DIR="${args[$i]}"
      ;;
    -C*)
      C_DIR="${args[$i]#-C}"
      ;;
  esac
  i=$((i + 1))
done

# Touch files if configured
if [ -n "${JCODE_STUB_TOUCH:-}" ] && [ -n "$C_DIR" ]; then
  for f in $JCODE_STUB_TOUCH; do
    mkdir -p "$(dirname "$C_DIR/$f")" 2>/dev/null || true
    echo "stub touch $(date -u +%s)" >> "$C_DIR/$f"
  done
fi

exit "${JCODE_STUB_EXIT:-0}"
JCODESTUB
  chmod +x "$WORKDIR/jcode"

  export PATH="$WORKDIR:$PATH"
  export JCODE_LOG="$WORKDIR/jcode-args.txt"
}

teardown() {
  if [ -n "${WT:-}" ] && [ -d "$WT" ]; then
    rm -rf "$WT"
  fi
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}

# Helper: write a valid work-order JSON file
_wo() {
  local wo_file="$1" issue="$2" allowed="$3" forbidden="$4" acceptance="$5"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-test-0',
    'issue': $issue,
    'base_sha': '0000000000000000000000000000000000000000',
    'allowed_paths': $allowed,
    'forbidden_paths': $forbidden,
    'acceptance_commands': $acceptance,
    'builder': '$BUILDER'
}
with open('$wo_file', 'w') as f:
    json.dump(wo, f)
"
}

# ---------------------------------------------------------------------------
# 1. NO WORK ORDER — \$WORK_ORDER unset -> non-zero, stdout reports outcome: "failed"
# ---------------------------------------------------------------------------

@test "builder-jcode: NO WORK ORDER — unset WORK_ORDER exits non-zero with failed" {
  run bash "$BUILDER" "$WT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'outcome'* ]]
  [[ "$output" == *'failed'* ]]
}

# ---------------------------------------------------------------------------
# 2. UNREADABLE WORK ORDER — path points at a missing file -> non-zero, outcome: "failed"
# ---------------------------------------------------------------------------

@test "builder-jcode: UNREADABLE WORK ORDER — missing file exits non-zero with failed" {
  WORK_ORDER="/no/such/work-order.json" run bash "$BUILDER" "$WT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'outcome'* ]]
  [[ "$output" == *'failed'* ]]
}

# ---------------------------------------------------------------------------
# 3. PROMPT CARRIES THE CONTRACT — stub jcode records its arguments;
#    assert the prompt contains the issue number, every allowed_paths entry,
#    and every forbidden_paths entry.
# ---------------------------------------------------------------------------

@test "builder-jcode: PROMPT CARRIES THE CONTRACT — prompt has issue, allowed, forbidden" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 42 '["app/", "pkg/"]' '["vendor/", "third_party/"]' '["true"]'

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="app/out.txt" run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]

  # The stub recorded every jcode invocation in JCODE_LOG
  [ -f "$JCODE_LOG" ]

  ARGS="$(cat "$JCODE_LOG")"

  # Assert issue number in prompt
  [[ "$ARGS" == *"#42"* ]]

  # Assert allowed_paths entries in prompt
  [[ "$ARGS" == *"app/"* ]]
  [[ "$ARGS" == *"pkg/"* ]]

  # Assert forbidden_paths entries in prompt
  [[ "$ARGS" == *"vendor/"* ]]
  [[ "$ARGS" == *"third_party/"* ]]

  # Assert the prohibition itself — a distinctive phrase from the instruction,
  # so that deleting the sentence while leaving the paths still reddens the test
  [[ "$ARGS" == *"stop and report failure"* ]]
}

# ---------------------------------------------------------------------------
# 4. NOTHING CHANGED — stub makes no change -> files_changed is empty AND
#    outcome is NOT "completed".
# ---------------------------------------------------------------------------

@test "builder-jcode: NOTHING CHANGED — empty changes reports failed not completed" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  # No JCODE_STUB_TOUCH set, so jcode stub does not touch any files
  WORK_ORDER="$WO" run bash "$BUILDER" "$WT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'outcome'* ]]
  [[ "$output" == *'failed'* ]]
  # Must NOT claim completed
  [[ "$output" != *'"completed"'* ]]
}

# ---------------------------------------------------------------------------
# 5. CHANGED FILES REPORTED — stub touches two files under allowed_paths ->
#    both appear in files_changed.
# ---------------------------------------------------------------------------

@test "builder-jcode: CHANGED FILES REPORTED — both touched files in files_changed" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/a.txt src/b.txt" run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]
  [[ "$output" == *'outcome'* ]]
  [[ "$output" == *'"completed"'* ]]

  # Both files must appear in files_changed
  [[ "$output" == *'src/a.txt'* ]]
  [[ "$output" == *'src/b.txt'* ]]
}

# ---------------------------------------------------------------------------
# 6. STUB FAILS — stub jcode exits non-zero -> outcome: "failed", non-zero exit
# ---------------------------------------------------------------------------

@test "builder-jcode: STUB FAILS — jcode exit non-zero reports failed" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  # JCODE_STUB_TOUCH is set so files would change, but JCODE_STUB_EXIT=1
  # makes the stub exit non-zero first
  WORK_ORDER="$WO" JCODE_STUB_EXIT=1 JCODE_STUB_TOUCH="src/out.txt" run bash "$BUILDER" "$WT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'outcome'* ]]
  [[ "$output" == *'failed'* ]]
}

# ---------------------------------------------------------------------------
# 7. USAGE RECORDED — builder_usage.txt exists after a run and is non-empty
# ---------------------------------------------------------------------------

@test "builder-jcode: USAGE RECORDED — builder_usage.txt exists and is non-empty" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  export RUN_DIR="$WORKDIR/run"

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" RUN_DIR="$RUN_DIR" run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]

  USAGE_FILE="$RUN_DIR/builder_usage.txt"
  [ -f "$USAGE_FILE" ]
  [ -s "$USAGE_FILE" ]

  # Should contain both BEFORE and AFTER sections
  [[ "$(cat "$USAGE_FILE")" == *"BEFORE"* ]]
  [[ "$(cat "$USAGE_FILE")" == *"AFTER"* ]]
}
