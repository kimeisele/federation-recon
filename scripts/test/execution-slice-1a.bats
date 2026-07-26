#!/usr/bin/env bats
# execution-slice-1a.bats — Acceptance tests for Slice 1a execution layer.
#
# Tests the verifier against a deliberately lying builder. The builder is not
# the product; the verifier is. Every test asserts an exit code AND the
# distinctive field(s) in result.json.
#
# Hermetic: each test controls its own RUN_ROOT in a mktemp dir, uses the real
# repository as git source (base_sha = current HEAD).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  FAKE_BUILDER="$REPO_ROOT/operator/builders/fake.sh"
  RUNNER="$REPO_ROOT/operator/run.sh"

  # Each test gets its own run-directory root
  RUN_ROOT="$(mktemp -d)"
  export RUN_ROOT
}

teardown() {
  # Always prune worktrees under this test's RUN_ROOT
  if [ -n "${RUN_ROOT:-}" ] && [ -d "$RUN_ROOT" ]; then
    for wt_dir in "$RUN_ROOT"/*/wt; do
      [ -d "$wt_dir" ] && git worktree remove --force "$wt_dir" 2>/dev/null || true
    done
    git worktree prune 2>/dev/null || true
    rm -rf "$RUN_ROOT"
  fi
}

# Helper: build a work-order JSON file
_wo() {
  local wo_file="$1" wo_id="$2" issue="$3" forbidden="$4" acceptance="$5"
  python3 -c "
import json
wo = {
    'work_order_id': '$wo_id',
    'issue': $issue,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': $forbidden,
    'acceptance_commands': $acceptance,
    'builder': '$FAKE_BUILDER'
}
with open('$wo_file', 'w') as f:
    json.dump(wo, f)
"
}

# Helper: run the runner and assert exit code + verdict
_run_and_assert() {
  local wo_id="$1" expected_verdict="$2" extra_check_fn="$3"

  RESULT="$RUN_ROOT/$wo_id/result.json"
  [ -f "$RESULT" ]

  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "$expected_verdict" ]

  if [ -n "$extra_check_fn" ]; then
    "$extra_check_fn"
  fi
}

# ---------------------------------------------------------------------------
# 1. FORBIDDEN PATH — builder touches a forbidden file and reports completed.
#    The verifier must reject it and name the forbidden file.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: FORBIDDEN PATH — catches forbidden file touch" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-forbidden.json"
  _wo "$WO" "wo-1-1" 1 '["CLAUDE.md"]' '["true"]'

  trap "rm -rf $WORKDIR" RETURN

  FAKE_TOUCH_FILE=CLAUDE.md \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  [ "$status" -eq 0 ]

  _run_and_assert "wo-1-1" "rejected" _check_forbidden
}

_check_forbidden() {
  FORBIDDEN_HITS=$(python3 -c "import json; print(json.load(open('$RESULT'))['forbidden_hits'])")
  [[ "$FORBIDDEN_HITS" == *"CLAUDE.md"* ]]

  BCC=$(python3 -c "import json; print(json.load(open('$RESULT'))['builder_claim_contradicted'])")
  [ "$BCC" = "True" ]
}

# ---------------------------------------------------------------------------
# 2. THE LIE — builder touches allowed file, reports "completed", but the
#    acceptance command is `false`. The verifier must catch the contradiction.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: THE LIE — catches builder lying about acceptance" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-lie.json"
  _wo "$WO" "wo-1-2" 1 '[]' '["false"]'

  trap "rm -rf $WORKDIR" RETURN

  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  [ "$status" -eq 0 ]

  _run_and_assert "wo-1-2" "rejected" _check_lie
}

_check_lie() {
  BCC=$(python3 -c "import json; print(json.load(open('$RESULT'))['builder_claim_contradicted'])")
  [ "$BCC" = "True" ]

  ACC_RESULTS=$(python3 -c "import json; print(json.load(open('$RESULT'))['acceptance_results'])")
  [[ "$ACC_RESULTS" == *"false"* ]]
  [[ ! "$ACC_RESULTS" =~ "exit_status\": 0" ]]

  REASON=$(python3 -c "import json; print(json.load(open('$RESULT'))['builder_claim_contradicted_reason'])")
  [[ "$REASON" == *"acceptance"* ]] || [[ "$REASON" == *"false"* ]]
}

# ---------------------------------------------------------------------------
# 3. CRASH — kill the runner mid-run (after builder_started), then --resume.
#    Must report INCOMPLETE and exit 2.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: CRASH — --resume detects incomplete run after SIGKILL" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-crash.json"
  _wo "$WO" "wo-1-3" 1 '[]' '["true"]'

  trap "rm -rf $WORKDIR" RETURN

  EVENTS_FILE="$RUN_ROOT/wo-1-3/events.jsonl"

  # Start runner in background
  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    bash "$RUNNER" "$WO" &
  RUNNER_PID=$!

  # Wait for builder_started to appear in events (with timeout)
  for i in $(seq 1 50); do
    if [ -f "$EVENTS_FILE" ] && grep -q '"builder_started"' "$EVENTS_FILE" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done

  # Verify we actually saw builder_started
  grep -q '"builder_started"' "$EVENTS_FILE" 2>/dev/null || {
    kill "$RUNNER_PID" 2>/dev/null || true
    false "builder_started never appeared in events"
  }

  # Now SIGKILL the runner
  kill -9 "$RUNNER_PID" 2>/dev/null || true
  wait "$RUNNER_PID" 2>/dev/null || true
  sleep 0.2

  # --resume must exit 2 and print INCOMPLETE
  run bash "$RUNNER" "$WO" --resume
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCOMPLETE"* ]]
}

# ---------------------------------------------------------------------------
# 4. HAPPY PATH — allowed file, acceptance `true`, builder reports completed.
#    Verdict must be "accepted", exit 0.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: HAPPY PATH — accepted when everything is clean" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-happy.json"
  _wo "$WO" "wo-1-4" 1 '[]' '["true"]'

  trap "rm -rf $WORKDIR" RETURN

  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  [ "$status" -eq 0 ]

  _run_and_assert "wo-1-4" "accepted" _check_happy
}

_check_happy() {
  BCC=$(python3 -c "
import json
d = json.load(open('$RESULT'))
print(d.get('builder_claim_contradicted', 'absent'))
")
  [ "$BCC" = "absent" ] || [ "$BCC" = "False" ]
}

# ---------------------------------------------------------------------------
# 5. IDEMPOTENCE — running the same work order twice must succeed both times
#    with the same verdict. The second run must not fail due to stale
#    registrations.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: IDEMPOTENCE — second run of same work order succeeds" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-idem.json"
  _wo "$WO" "wo-1-5" 1 '[]' '["true"]'

  trap "rm -rf $WORKDIR" RETURN

  # ---- first run ----
  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    bash "$RUNNER" "$WO"
  STATUS1=$?

  [ "$STATUS1" -eq 0 ]

  RESULT1="$RUN_ROOT/wo-1-5/result.json"
  VERDICT1=$(python3 -c "import json; print(json.load(open('$RESULT1'))['verdict'])")

  # ---- second run (same work order, same RUN_ROOT) ----
  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    bash "$RUNNER" "$WO"
  STATUS2=$?

  [ "$STATUS2" -eq 0 ]

  RESULT2="$RUN_ROOT/wo-1-5/result.json"
  VERDICT2=$(python3 -c "import json; print(json.load(open('$RESULT2'))['verdict'])")

  # Both must be accepted
  [ "$VERDICT1" = "accepted" ]
  [ "$VERDICT2" = "accepted" ]
}
