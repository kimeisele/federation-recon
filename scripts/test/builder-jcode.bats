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

  # The probe reads jcode's log; give the stub one of its own so the suite
  # never touches the operator's real log directory.
  export JCODE_LOG_DIR="$WORKDIR/jcode-logs"
  mkdir -p "$JCODE_LOG_DIR"

  # Create stub jcode on PATH
  cat > "$WORKDIR/jcode" <<'JCODESTUB'
#!/usr/bin/env bash
# Stub jcode for builder tests.
#
# Records every invocation to $JCODE_LOG.
# When called as 'jcode usage', prints a stub usage line.
# When called as 'jcode run ...', extracts the -C dir, optionally touches
# files listed in $JCODE_STUB_TOUCH (space-separated, relative to -C dir),
# writes to $JCODE_SCRATCH_DIR if set (otherwise simulates the literal
# \$JCODE_SCRATCH_DIR bug in C_DIR), records $JCODE_SCRATCH_DIR value to
# $JCODE_STUB_SCRATCH_RECORD if set, and exits with $JCODE_STUB_EXIT (default 0).
#
# bash 3.2 compatible.

echo "$@" >> "${JCODE_LOG:-/dev/null}"

# Profile-backed jcode puts global routing flags before the `run` subcommand,
# while the legacy form starts with `run`. Find the subcommand instead of
# assuming its position so this stub exercises both contracts.
IS_RUN=no
for arg in "$@"; do
  if [ "$arg" = "run" ]; then
    IS_RUN=yes
    break
  fi
done

# The stub simulates jcode's LOG as well as its behaviour, because the provider
# probe (#159) reads the log rather than the tool's own resolver — the resolver
# was measured saying "DeepSeek" while the runtime logged "openrouter".
# A stub that answered but wrote no log would make every run unverifiable,
# which is the correct outcome for a tool that writes no log and the wrong
# outcome for a test of something else.
if [ "$IS_RUN" = "yes" ] && [ -n "${JCODE_LOG_DIR:-}" ]; then
  mkdir -p "$JCODE_LOG_DIR"
  printf '[%s] [INFO] [ses:session_stub|prv:%s|mod:%s] API call starting\n' \
    "$(date -u +'%Y-%m-%d %H:%M:%S')" \
    "${JCODE_STUB_PROVIDER:-deepseek}" \
    "${JCODE_STUB_MODEL:-deepseek-v4-flash}" \
    >> "$JCODE_LOG_DIR/jcode-$(date -u +%Y-%m-%d).log"
  if [ -n "${JCODE_STUB_ENDPOINT:-}" ]; then
    printf '[%s] [INFO] API stream attempt 1/1 over HTTPS transport (model: %s, endpoint: %s, auth: TEST_API_KEY)\n' \
      "$(date -u +'%Y-%m-%d %H:%M:%S')" \
      "${JCODE_STUB_MODEL:-deepseek-v4-flash}" \
      "$JCODE_STUB_ENDPOINT" \
      >> "$JCODE_LOG_DIR/jcode-$(date -u +%Y-%m-%d).log"
  fi
fi

case "${1:-}" in
  usage)
    echo "stub usage output: tokens_total=42"
    exit 0
    ;;
esac

if [ "$IS_RUN" = "yes" ] && [ -n "${JCODE_STUB_TOKENS:-}" ]; then
  printf '%s\n' "$JCODE_STUB_TOKENS"
fi

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

# Simulate real jcode scratch-dir behaviour
if [ -n "${JCODE_SCRATCH_DIR:-}" ]; then
  mkdir -p "$JCODE_SCRATCH_DIR" 2>/dev/null || true
  echo "stub scratch" > "$JCODE_SCRATCH_DIR/stub_scratch.txt"
else
  # Bug: unset JCODE_SCRATCH_DIR causes literal \$JCODE_SCRATCH_DIR in CWD
  if [ -n "$C_DIR" ]; then
    mkdir -p "$C_DIR/\$JCODE_SCRATCH_DIR" 2>/dev/null || true
    echo "stub scratch" > "$C_DIR/\$JCODE_SCRATCH_DIR/stub_scratch.txt"
  fi
fi

# Record scratch dir value for test verification
if [ -n "${JCODE_STUB_SCRATCH_RECORD:-}" ]; then
  echo "${JCODE_SCRATCH_DIR:-UNSET}" > "$JCODE_STUB_SCRATCH_RECORD"
fi

exit "${JCODE_STUB_EXIT:-0}"
JCODESTUB
  chmod +x "$WORKDIR/jcode"

  export PATH="$WORKDIR:$PATH"
  export JCODE_LOG="$WORKDIR/jcode-args.txt"

  # Hermetic: unset JCODE_SCRATCH_DIR so the environment doesn't leak in
  unset JCODE_SCRATCH_DIR 2>/dev/null || true
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

# ---------------------------------------------------------------------------
# 8. SCRATCH OUTSIDE THE WORKTREE — stub writes to \$JCODE_SCRATCH_DIR;
#    after the builder runs the worktree must NOT contain a literal
#    \$JCODE_SCRATCH_DIR directory and no untracked path other than what
#    the stub deliberately changed.
# ---------------------------------------------------------------------------

@test "builder-jcode: SCRATCH OUTSIDE THE WORKTREE — no \$JCODE_SCRATCH_DIR in worktree" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]

  # The literal \$JCODE_SCRATCH_DIR directory must NOT exist in the worktree
  [ ! -d "$WT/\$JCODE_SCRATCH_DIR" ]

  # Only the stub-touched files should appear in git status
  CHANGED=$(git -C "$WT" status --porcelain --untracked-files=all)
  [[ "$CHANGED" == *"src/out.txt"* ]]
  # No \$JCODE_SCRATCH_DIR entry anywhere in git status
  [[ "$CHANGED" != *'$JCODE_SCRATCH_DIR'* ]]
  # Exactly one untracked file — no scratch leakage
  CHANGED_COUNT=$(echo "$CHANGED" | grep -c . || true)
  [ "$CHANGED_COUNT" -eq 1 ]

  # files_changed must also be exactly what the stub touched — no scratch leakage
  [[ "$output" == *'"files_changed": ["src/out.txt"]'* ]]
}

# ---------------------------------------------------------------------------
# 9. SCRATCH IS SET — stub records the value of \$JCODE_SCRATCH_DIR.
#    Assert it is non-empty and is NOT under the worktree path.
# ---------------------------------------------------------------------------

@test "builder-jcode: SCRATCH IS SET — non-empty and outside worktree" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  RECORD_FILE="$WORKDIR/scratch_value.txt"

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" \
    JCODE_STUB_SCRATCH_RECORD="$RECORD_FILE" \
    run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]
  [ -f "$RECORD_FILE" ]

  SCRATCH_VAL=$(cat "$RECORD_FILE")
  [ -n "$SCRATCH_VAL" ]
  # Must not be the literal "UNSET" placeholder
  [[ "$SCRATCH_VAL" != "UNSET" ]]
  # Must not be under the worktree
  [[ "$SCRATCH_VAL" != "$WT"/* ]]
  [[ "$SCRATCH_VAL" != "$WT" ]]
}

# ---------------------------------------------------------------------------
# 10. USAGE NOT BESIDE THE WORK ORDER — with RUN_DIR unset, assert no file
#     appears in the directory containing the work order.
# ---------------------------------------------------------------------------

@test "builder-jcode: USAGE NOT BESIDE THE WORK ORDER — WO dir clean without RUN_DIR" {
  WO_DIR="$WORKDIR/wo"
  mkdir -p "$WO_DIR"
  WO="$WO_DIR/wo.json"
  _wo "$WO" 1 '["src/"]' '[]' '["true"]'

  # Explicitly unset RUN_DIR so builder uses temp dirs
  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" \
    RUN_DIR="" \
    run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]

  # Only wo.json should be in the work order directory
  FILES=$(ls -1 "$WO_DIR" 2>/dev/null)
  [ "$(echo "$FILES" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$FILES" == "wo.json" ]]
}

# ---------------------------------------------------------------------------
# 11. NAMED PROFILE — profile and model are independent global selections.
#     This is the no-vendor-login path for any OpenAI-compatible API.
# ---------------------------------------------------------------------------

@test "builder-jcode: NAMED PROFILE — profile route is used without provider flag" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 167 '["src/"]' '[]' '["true"]'

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" \
    JCODE_PROVIDER_PROFILE="fixture-direct" \
    JCODE_EXPECTED_ENDPOINT="https://api.fixture.invalid" \
    JCODE_STUB_ENDPOINT="https://api.fixture.invalid" \
    run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]
  # Global jcode flags must precede the run subcommand. A literal provider
  # name is not a substitute for the selected profile.
  run grep -E -- '--provider-profile fixture-direct .*--model deepseek-v4-flash .* run ' "$JCODE_LOG"
  [ "$status" -eq 0 ]
  run grep -E -- '(^| )-p deepseek( |$)' "$JCODE_LOG"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 12. ENDPOINT MISMATCH — a profile label is intent; the logged endpoint is
#     route evidence. A different endpoint must stop before build mutation.
# ---------------------------------------------------------------------------

@test "builder-jcode: ENDPOINT MISMATCH — profile route fails closed before build" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 167 '["src/"]' '[]' '["true"]'

  WORK_ORDER="$WO" JCODE_STUB_TOUCH="src/out.txt" \
    JCODE_PROVIDER_PROFILE="fixture-direct" \
    JCODE_EXPECTED_ENDPOINT="https://api.expected.invalid" \
    JCODE_STUB_ENDPOINT="https://api.somewhere-else.invalid" \
    run bash "$BUILDER" "$WT"

  [ "$status" -ne 0 ]
  [[ "$output" == *'failed'* ]]
  [ ! -e "$WT/src/out.txt" ]
}

# ---------------------------------------------------------------------------
# 13. BUILD TOKENS — jcode emits exact per-run figures on stdout. They belong
#     to the build invocation, not the separate route probe, and must survive.
# ---------------------------------------------------------------------------

@test "builder-jcode: BUILD TOKENS — exact jcode token figures reach cost record" {
  WO="$WORKDIR/wo.json"
  _wo "$WO" 167 '["src/"]' '[]' '["true"]'
  export RUN_DIR="$WORKDIR/run"

  WORK_ORDER="$WO" RUN_DIR="$RUN_DIR" JCODE_STUB_TOUCH="src/out.txt" \
    JCODE_PROVIDER_PROFILE="fixture-direct" \
    JCODE_EXPECTED_ENDPOINT="https://api.fixture.invalid" \
    JCODE_STUB_ENDPOINT="https://api.fixture.invalid" \
    JCODE_STUB_TOKENS='[Tokens] upload: 123 download: 45 cache_read: 6 cache_write: 7' \
    run bash "$BUILDER" "$WT"

  [ "$status" -eq 0 ]
  [ -f "$RUN_DIR/builder_cost.txt" ]
  grep -q '^input_tokens:[[:space:]]*123$' "$RUN_DIR/builder_cost.txt"
  grep -q '^output_tokens:[[:space:]]*45$' "$RUN_DIR/builder_cost.txt"
  grep -q '^cache_read_tokens:[[:space:]]*6$' "$RUN_DIR/builder_cost.txt"
  grep -q '^cache_write_tokens:[[:space:]]*7$' "$RUN_DIR/builder_cost.txt"
}
