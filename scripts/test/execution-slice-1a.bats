#!/usr/bin/env bats
# execution-slice-1a.bats — Acceptance tests for Slice 1a execution layer.
#
# Tests the verifier against a deliberately lying builder. The builder is not
# the product; the verifier is. Every test asserts an exit code AND the
# distinctive field(s) in result.json.
#
# Hermetic: builds work orders in mktemp dirs, uses the real repository as
# git source (base_sha = current HEAD).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  FAKE_BUILDER="$REPO_ROOT/operator/builders/fake.sh"
  RUNNER="$REPO_ROOT/operator/run.sh"
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

# ---------------------------------------------------------------------------
# 1. FORBIDDEN PATH — builder touches a forbidden file and reports completed.
#    The verifier must reject it and name the forbidden file.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: FORBIDDEN PATH — catches forbidden file touch" {
  WORKDIR="$(mktemp -d)"

  WO="$WORKDIR/wo-forbidden.json"
  _wo "$WO" "wo-1-1" 1 '["CLAUDE.md"]' '["true"]'

  # Set trap AFTER _wo returns, so _wo's return doesn't trigger cleanup
  trap "rm -rf $WORKDIR" RETURN

  FAKE_TOUCH_FILE=CLAUDE.md \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  # Runner itself exits 0 (run completed, just rejected)
  [ "$status" -eq 0 ]

  # Verdict must be rejected
  RESULT="$REPO_ROOT/operator/.runs/wo-1-1/result.json"
  [ -f "$RESULT" ]

  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "rejected" ]

  # Must name CLAUDE.md in forbidden_hits
  FORBIDDEN_HITS=$(python3 -c "import json; print(json.load(open('$RESULT'))['forbidden_hits'])")
  [[ "$FORBIDDEN_HITS" == *"CLAUDE.md"* ]]

  # builder_claim_contradicted must be true
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

  RESULT="$REPO_ROOT/operator/.runs/wo-1-2/result.json"
  [ -f "$RESULT" ]

  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "rejected" ]

  # builder_claim_contradicted must be true
  BCC=$(python3 -c "import json; print(json.load(open('$RESULT'))['builder_claim_contradicted'])")
  [ "$BCC" = "True" ]

  # The failing command must be recorded with non-zero exit status
  ACC_RESULTS=$(python3 -c "import json; print(json.load(open('$RESULT'))['acceptance_results'])")
  [[ "$ACC_RESULTS" == *"false"* ]]
  # exit_status must be non-zero (not 0)
  [[ ! "$ACC_RESULTS" =~ "exit_status\": 0" ]]

  # contradiction reason must be present
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

  EVENTS_FILE="$REPO_ROOT/operator/.runs/wo-1-3/events.jsonl"

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

  RESULT="$REPO_ROOT/operator/.runs/wo-1-4/result.json"
  [ -f "$RESULT" ]

  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  # builder_claim_contradicted must NOT be present or must be false
  BCC=$(python3 -c "
import json
d = json.load(open('$RESULT'))
print(d.get('builder_claim_contradicted', 'absent'))
")
  [ "$BCC" = "absent" ] || [ "$BCC" = "False" ]
}
