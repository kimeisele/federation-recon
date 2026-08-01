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

  # Wait for builder_started or process exit.
  # A generous absolute bound (60s) catches a hung runner but the
  # primary terminal conditions are the event or the exit — not a clock.
  waited=0
  MAX_WAIT=600  # 60 seconds at 0.1s sleep intervals
  while kill -0 "$RUNNER_PID" 2>/dev/null; do
    if [ -f "$EVENTS_FILE" ] && grep -q '"builder_started"' "$EVENTS_FILE" 2>/dev/null; then
      break
    fi
    sleep 0.1
    waited=$((waited + 1))
    if [ "$waited" -ge "$MAX_WAIT" ]; then
      kill "$RUNNER_PID" 2>/dev/null || true
      wait "$RUNNER_PID" 2>/dev/null || true
      false "runner neither reached builder_started nor exited within 60s"
    fi
  done

  # Distinguish the two terminal conditions
  if grep -q '"builder_started"' "$EVENTS_FILE" 2>/dev/null; then
    :  # builder_started appeared — proceed to SIGKILL
  else
    false "runner exited without writing builder_started"
  fi

  # Now SIGKILL the runner
  kill -9 "$RUNNER_PID" 2>/dev/null || true
  wait "$RUNNER_PID" 2>/dev/null || true
  sleep 0.2

  # --resume must CONTINUE the run, not report on it.
  run bash "$RUNNER" "$WO" --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"INCOMPLETE"* ]]      # it says what it found
  [[ "$output" == *"RESUMING"* ]]        # and what it is doing about it
  [ -f "$RUN_ROOT/wo-1-3/result.json" ]  # and it reaches the end

  # The builder must have run exactly once across both invocations. This is
  # the property that matters most: a builder is not idempotent — it appends,
  # commits, calls a model, spends money.
  run grep -c '"event":"builder_finished"' "$EVENTS_FILE"
  [ "$output" = "1" ]
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

# ---------------------------------------------------------------------------
# 8. WORK ORDER REACHES THE BUILDER — a builder that reads $WORK_ORDER,
#    parses it with python3, and writes the issue number into a file under
#    the worktree. Assert: the run is accepted, and the file contains the
#    issue number from the work order.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: WORK ORDER REACHES THE BUILDER" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Builder that reads $WORK_ORDER from the environment
  BUILDER_SCRIPT="$WORKDIR/builder.sh"
  cat > "$BUILDER_SCRIPT" << 'BUILDER_EOF'
#!/usr/bin/env bash
set -o nounset
WT="${1:?}"

mkdir -p "$WT/operator"
echo "marker" >> "$WT/operator/.fake-marker"

ISSUE=$(python3 -c "import json; print(json.load(open('$WORK_ORDER'))['issue'])")
echo "$ISSUE" > "$WT/operator/issue.txt"

python3 -c "
import json
print(json.dumps({
    'outcome': 'completed',
    'files_changed': ['operator/.fake-marker', 'operator/issue.txt'],
    'work_order_issue': $ISSUE
}))
"
exit 0
BUILDER_EOF
  chmod +x "$BUILDER_SCRIPT"

  WO="$WORKDIR/wo.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-8',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$BUILDER_SCRIPT'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-8/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  BUILDER_STDOUT="$RUN_ROOT/wo-1-8/builder_stdout.txt"
  REPORTED_ISSUE=$(python3 -c "import json; print(json.load(open('$BUILDER_STDOUT'))['work_order_issue'])")
  [ "$REPORTED_ISSUE" = "1" ]

  CHANGED=$(python3 -c "import json; print(json.load(open('$RESULT'))['changed_paths'])")
  [[ "$CHANGED" == *"operator/issue.txt"* ]]
}

# ---------------------------------------------------------------------------
# 9. WORK ORDER IS THE VALIDATED ONE — invoke run.sh with a work order, and
#    have the builder record the value of $WORK_ORDER. Assert that the
#    recorded path exists and that its content parses as JSON with the same
#    work_order_id as the input.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: WORK ORDER IS THE VALIDATED ONE" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Builder script goes in WORKDIR — only needed until run.sh invokes it
  BUILDER_SCRIPT="$WORKDIR/builder.sh"
  cat > "$BUILDER_SCRIPT" << 'BUILDER_EOF'
#!/usr/bin/env bash
set -o nounset
WT="${1:?}"

mkdir -p "$WT/operator"
echo "marker" >> "$WT/operator/.fake-marker"

WO_PATH="$WORK_ORDER"
echo "$WO_PATH" > "$WT/operator/wo_path.txt"

python3 -c "
import json
print(json.dumps({
    'outcome': 'completed',
    'files_changed': ['operator/.fake-marker', 'operator/wo_path.txt'],
    'work_order_path': '$WO_PATH'
}))
"
exit 0
BUILDER_EOF
  chmod +x "$BUILDER_SCRIPT"

  # Work order goes under RUN_ROOT so it survives the RETURN trap
  WO="$RUN_ROOT/wo-1-9-workorder.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-9',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$BUILDER_SCRIPT'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-9/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  BUILDER_STDOUT="$RUN_ROOT/wo-1-9/builder_stdout.txt"
  RECORDED_PATH=$(python3 -c "import json; print(json.load(open('$BUILDER_STDOUT'))['work_order_path'])")

  # The recorded path must exist
  [ -f "$RECORDED_PATH" ]

  # Its content must parse as JSON with the same work_order_id
  RECORDED_ID=$(python3 -c "import json; print(json.load(open('$RECORDED_PATH'))['work_order_id'])")
  [ "$RECORDED_ID" = "wo-1-9" ]
}

# ---------------------------------------------------------------------------
# 10. NO LEAK — after run.sh finishes, WORK_ORDER must not be set in the
#     calling shell. Assert with a subshell check.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: NO LEAK — WORK_ORDER not set after run.sh" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" EXIT

  WO="$WORKDIR/wo-noleak.json"
  _wo "$WO" "wo-1-10" 1 '[]' '["true"]'

  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  [ "$status" -eq 0 ]

  # WORK_ORDER must not leak into the calling shell
  [ -z "${WORK_ORDER:-}" ]
}

# ---------------------------------------------------------------------------
# 11. PATCH IS SAVED — after an accepted run whose builder changed a file,
#     $RUN_DIR/changes.patch exists, is non-empty, and mentions the changed
#     file.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: PATCH IS SAVED — changes.patch exists and is non-empty" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  BUILDER_SCRIPT="$WORKDIR/builder.sh"
  cat > "$BUILDER_SCRIPT" << 'BUILDER_EOF'
#!/usr/bin/env bash
set -o nounset
WT="${1:?}"
mkdir -p "$WT/operator"
echo "patch-saved-content" > "$WT/operator/patch-test.txt"
python3 -c "import json; print(json.dumps({'outcome': 'completed', 'files_changed': ['operator/patch-test.txt']}))"
exit 0
BUILDER_EOF
  chmod +x "$BUILDER_SCRIPT"

  WO="$RUN_ROOT/wo-1-11.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-11',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$BUILDER_SCRIPT'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-11/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  PATCH="$RUN_ROOT/wo-1-11/changes.patch"
  [ -f "$PATCH" ]
  [ -s "$PATCH" ]

  # The patch must reference the file the builder created
  grep -q "operator/patch-test.txt" "$PATCH"
}

# ---------------------------------------------------------------------------
# 12. PATCH APPLIES — create a fresh worktree at base_sha, `git apply` the
#     saved patch, and assert the file the builder changed is present with
#     the expected content.  This is the real acceptance test.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: PATCH APPLIES — saved patch is applicable with git apply" {
  WORKDIR="$(mktemp -d)"

  BUILDER_SCRIPT="$WORKDIR/builder.sh"
  cat > "$BUILDER_SCRIPT" << 'BUILDER_EOF'
#!/usr/bin/env bash
set -o nounset
WT="${1:?}"
mkdir -p "$WT/operator"
echo "apply-test-v9" > "$WT/operator/apply-test.txt"
python3 -c "import json; print(json.dumps({'outcome': 'completed', 'files_changed': ['operator/apply-test.txt']}))"
exit 0
BUILDER_EOF
  chmod +x "$BUILDER_SCRIPT"

  WO="$RUN_ROOT/wo-1-12.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-12',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$BUILDER_SCRIPT'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-12/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  PATCH="$RUN_ROOT/wo-1-12/changes.patch"
  [ -f "$PATCH" ]
  [ -s "$PATCH" ]

  # Create a fresh worktree at base_sha and apply the patch
  APPLY_WT="$(mktemp -d)"

  # Single cleanup trap for both WORKDIR and APPLY_WT
  apply_cleanup() {
    if [ -n "${APPLY_WT:-}" ] && [ -d "$APPLY_WT" ]; then
      git -C "$REPO_ROOT" worktree remove --force "$APPLY_WT" 2>/dev/null || true
      git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
      rm -rf "$APPLY_WT"
    fi
    rm -rf "$WORKDIR"
  }
  trap apply_cleanup RETURN

  git -C "$REPO_ROOT" worktree add --detach "$APPLY_WT" "$BASE_SHA" >/dev/null 2>&1 || {
    false "failed to create worktree for patch application"
  }

  git -C "$APPLY_WT" apply "$PATCH" || {
    false "git apply failed"
  }

  # The file must exist with the expected content
  [ -f "$APPLY_WT/operator/apply-test.txt" ]
  CONTENT=$(cat "$APPLY_WT/operator/apply-test.txt")
  [ "$CONTENT" = "apply-test-v9" ]
}

# ---------------------------------------------------------------------------
# 13. EMPTY IS NOT MISSING — a run where the builder changes nothing leaves
#     a patch file that exists and is empty, so "no changes" and "patch lost"
#     remain distinguishable.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: EMPTY IS NOT MISSING — no-change run leaves empty patch" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Builder that changes nothing — just reports completed and exits 0
  BUILDER_SCRIPT="$WORKDIR/noop-builder.sh"
  cat > "$BUILDER_SCRIPT" << 'BUILDER_EOF'
#!/usr/bin/env bash
python3 -c "import json; print(json.dumps({'outcome': 'completed', 'files_changed': []}))"
exit 0
BUILDER_EOF
  chmod +x "$BUILDER_SCRIPT"

  WO="$RUN_ROOT/wo-1-13.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-13',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$BUILDER_SCRIPT'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-13/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "accepted" ]

  PATCH="$RUN_ROOT/wo-1-13/changes.patch"
  [ -f "$PATCH" ]
  [ ! -s "$PATCH" ]
}

# ---------------------------------------------------------------------------
# 14. PATCH FAILURE REJECTS — make the patch file unwritable so the save
#     fails, and assert the run is rejected with the reason named in
#     result.json.
# ---------------------------------------------------------------------------

@test "execution-slice-1a: PATCH FAILURE REJECTS — unwritable patch rejects the run" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  WO="$RUN_ROOT/wo-1-14.json"
  python3 -c "
import json
wo = {
    'work_order_id': 'wo-1-14',
    'issue': 1,
    'base_sha': '$BASE_SHA',
    'allowed_paths': ['operator/'],
    'forbidden_paths': [],
    'acceptance_commands': ['true'],
    'builder': '$FAKE_BUILDER'
}
with open('$WO', 'w') as f:
    json.dump(wo, f)
"

  # Pre-create the run dir with changes.patch as a directory so the write fails
  mkdir -p "$RUN_ROOT/wo-1-14/changes.patch"

  FAKE_TOUCH_FILE=operator/.fake-marker \
  FAKE_OUTCOME=completed \
  FAKE_EXIT=0 \
    run bash "$RUNNER" "$WO"

  [ "$status" -eq 0 ]

  RESULT="$RUN_ROOT/wo-1-14/result.json"
  VERDICT=$(python3 -c "import json; print(json.load(open('$RESULT'))['verdict'])")
  [ "$VERDICT" = "rejected" ]

  PATCH_ERROR=$(python3 -c "import json; print(json.load(open('$RESULT'))['patch_error'])")
  [ -n "$PATCH_ERROR" ]
}

# ---------------------------------------------------------------------------
# RESUME — the three properties the owner asked for, each as its own case.
# All three run against the fake builder; no model call anywhere.
# ---------------------------------------------------------------------------

# _kill_at <events-file> <pid> <grep-pattern> [min-count]
# Wait until the ledger shows the pattern at least min-count times, then
# SIGKILL. Terminates on process exit too, so a run that finishes early fails
# the caller's assertion rather than hanging here.
_kill_at() {
  local ev="$1" pid="$2" pat="$3" want="${4:-1}" waited=0 n
  while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$ev" ]; then
      n="$(grep -c "$pat" "$ev" 2>/dev/null || true)"
      [ -z "$n" ] && n=0
      if [ "$n" -ge "$want" ]; then break; fi
    fi
    sleep 0.05
    waited=$((waited + 1))
    if [ "$waited" -ge 1200 ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      false "never reached $want x $pat within 60s"
    fi
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 0.2
}

@test "execution-slice-1a: RESUME — a killed run runs to completion" {
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-20" 1 '[]' '["true", "sleep 30"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-20/events.jsonl"

  bash "$RUNNER" "$WO" & RUNNER_PID=$!
  _kill_at "$EVENTS_FILE" "$RUNNER_PID" '"event":"acceptance_command_finished"' 1

  [ ! -f "$RUN_ROOT/wo-1-20/result.json" ]   # the crash was real

  run bash "$RUNNER" "$WO" --resume
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$RUN_ROOT/wo-1-20/result.json" ]

  # Both commands ran, across the two invocations.
  run grep -c '"event":"acceptance_command_finished"' "$EVENTS_FILE"
  [ "$output" = "2" ]
}

@test "execution-slice-1a: RESUME — a completed step is not run a second time" {
  # Five acceptance commands, killed after the second. Exactly three may run
  # on the resume, and the builder none.
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-21" 1 '[]' '["true", "true", "sleep 30", "true", "true"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-21/events.jsonl"

  bash "$RUNNER" "$WO" & RUNNER_PID=$!
  _kill_at "$EVENTS_FILE" "$RUNNER_PID" '"event":"acceptance_command_finished"' 2

  BEFORE="$(grep -c '"event":"acceptance_command_finished"' "$EVENTS_FILE")"
  [ "$BEFORE" -ge 2 ]

  # The fake builder appends a line every time it runs, so a second invocation
  # is visible in the work itself and not only in the ledger. The worktree is
  # removed when the resumed run completes, so the evidence is taken from the
  # saved patch afterwards rather than from the file.
  MARKER="$RUN_ROOT/wo-1-21/wt/operator/.fake-marker"
  [ "$(wc -l < "$MARKER" | tr -d ' ')" = "1" ]

  run bash "$RUNNER" "$WO" --resume
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"acceptance command(s) already done"* ]]

  run grep -c '"event":"builder_finished"' "$EVENTS_FILE"
  [ "$output" = "1" ]

  # Exactly one line was added to the marker across both invocations. Two
  # would mean the builder ran again.
  run grep -c '^+fake builder touched this file' "$RUN_ROOT/wo-1-21/changes.patch"
  [ "$output" = "1" ]

  # Five commands total, not five-plus-the-repeats.
  run grep -c '"event":"acceptance_command_finished"' "$EVENTS_FILE"
  [ "$output" = "5" ]
}

@test "execution-slice-1a: RESUME — resumable after verification, before the result" {
  # The last window in Slice 1a: the verdict is decided and result.json is not
  # yet written. Slice 1a stops before the PR, so this is the equivalent seam.
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-22" 1 '[]' '["true"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-22/events.jsonl"

  bash "$RUNNER" "$WO" & RUNNER_PID=$!
  _kill_at "$EVENTS_FILE" "$RUNNER_PID" '"event":"verdict"' 1

  run tail -1 "$EVENTS_FILE"
  [[ "$output" == *'"verdict"'* ]]
  [ ! -f "$RUN_ROOT/wo-1-22/result.json" ]

  run bash "$RUNNER" "$WO" --resume
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$RUN_ROOT/wo-1-22/result.json" ]

  run grep -c '"event":"builder_finished"' "$EVENTS_FILE"
  [ "$output" = "1" ]
  run grep -c '"event":"acceptance_command_finished"' "$EVENTS_FILE"
  [ "$output" = "1" ]
}

@test "execution-slice-1a: RESUME — a finished run is reported, not re-run" {
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-23" 1 '[]' '["true"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-23/events.jsonl"

  run bash "$RUNNER" "$WO"
  [ "$status" -eq 0 ]
  BEFORE="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"

  run bash "$RUNNER" "$WO" --resume
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPLETE"* ]]

  AFTER="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"
  [ "$BEFORE" = "$AFTER" ]      # it appended nothing
}

@test "execution-slice-1a: RESUME — an event without its output file re-runs the step" {
  # The event is a claim the crashed run made about itself; the file is the
  # thing. A step interrupted between writing its output and recording the
  # event must re-run, and so must one whose output was lost — the safe
  # direction, since these steps are idempotent and the builder is guarded
  # separately by its own file check.
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-24" 1 '[]' '["sleep 30"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-24/events.jsonl"

  bash "$RUNNER" "$WO" & RUNNER_PID=$!
  _kill_at "$EVENTS_FILE" "$RUNNER_PID" '"event":"acceptance_started"' 1

  # The ledger says the snapshot was taken. Remove the file it wrote.
  grep -q '"event":"before_snapshot"' "$EVENTS_FILE"
  rm -f "$RUN_ROOT/wo-1-24/before_snapshot.json"

  run bash "$RUNNER" "$WO" --resume
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"before-snapshot already done"* ]]   # it did NOT skip
  [ -f "$RUN_ROOT/wo-1-24/before_snapshot.json" ]       # it rebuilt it
}

@test "execution-slice-1a: RESUME — the ledger of a crashed run is never truncated" {
  # Truncating on resume would destroy the record the resume is reading, and a
  # crash would become invisible after one retry.
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-25" 1 '[]' '["sleep 30"]'
  EVENTS_FILE="$RUN_ROOT/wo-1-25/events.jsonl"

  bash "$RUNNER" "$WO" & RUNNER_PID=$!
  _kill_at "$EVENTS_FILE" "$RUNNER_PID" '"event":"acceptance_started"' 1

  FIRST_LINE="$(head -1 "$EVENTS_FILE")"
  BEFORE="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"

  run bash "$RUNNER" "$WO" --resume
  [ "$status" -eq 0 ]

  [ "$(head -1 "$EVENTS_FILE")" = "$FIRST_LINE" ]
  AFTER="$(wc -l < "$EVENTS_FILE" | tr -d ' ')"
  [ "$AFTER" -gt "$BEFORE" ]
  run grep -c '"event":"run_resumed"' "$EVENTS_FILE"
  [ "$output" = "1" ]
}

@test "execution-slice-1a: RESUME — with no ledger at all, it refuses" {
  WORKDIR="$BATS_TEST_TMPDIR"
  WO="$WORKDIR/wo.json"
  _wo "$WO" "wo-1-26" 1 '[]' '["true"]'

  run bash "$RUNNER" "$WO" --resume
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing to resume"* ]]
}
