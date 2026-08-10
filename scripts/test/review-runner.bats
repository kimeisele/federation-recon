#!/usr/bin/env bats
# review-runner.bats — the review runner (scripts/review.sh) end to end.
#
# scripts/review.sh orchestrates one review of a PR: resolve the head SHA,
# cut a disposable worktree at that SHA, run the gate in it (Tier 0), make
# one model call each for Tier 1A and Tier 1B, assemble the verdict artifact,
# and let the deterministic aggregator (scripts/review-verdict.sh) recompute
# the final word. It is inert — manually invoked only, no heartbeat wiring.
#
# These tests drive the REAL review.sh inside a disposable fixture repository
# whose HEAD carries a stand-in gate.sh, so Tier 0 is fast and offline. The
# mock gh returns the fixture's committed HEAD SHA, the mock curl returns a
# canned provider response, HOME is pointed at a sandbox so verdict artifacts
# never touch a real review history; TMPDIR is pointed at the sandbox so the
# disposable worktree can be asserted created and destroyed. The runner's own
# constraints under test:
#
#   * verdict artifacts are written OUTSIDE the repository
#   * the disposable worktree is created at the head SHA and destroyed
#   * the deterministic aggregator is called and its word is stored
#   * Tier 1A/1B record "complete" with the response's model field, or
#     "error" on a failed provider call — never a crash
#   * blocking findings are verified by executing their verification_command
#     in the worktree; only confirmed blocking findings can reject
#   * a review that cannot start (gh failure) records PARTIAL and exits 0
#   * the only non-zero exit is a usage error

# ────────────────────────────────────────────────────────────
# setup_file / teardown_file — heavy lifting once per file
# ────────────────────────────────────────────────────────────

setup_file() {
  # Tests share one fixture git repo and assert worktree counts, so they
  # must not run concurrently within this file. Cross-file parallelism is ok.
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true

  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"

  FILE_SANDBOX="$BATS_FILE_TMPDIR/shared"
  mkdir -p "$FILE_SANDBOX/mockbin"

  export FIXTURE="$FILE_SANDBOX/fixture"
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/schemas"
  cp "$REPO_ROOT/scripts/review.sh" "$FIXTURE/scripts/review.sh"
  cp "$REPO_ROOT/scripts/review-verdict.sh" "$FIXTURE/scripts/review-verdict.sh"
  cp "$REPO_ROOT/schemas/review-verdict.schema.json" "$FIXTURE/schemas/"

  cat > "$FIXTURE/scripts/gate.sh" <<'GATESCRIPT'
#!/usr/bin/env bash
echo "fixture gate: ${MOCK_GATE_STATUS:-0}"
if [ -n "${MOCK_GATE_CWD_FILE:-}" ]; then
  printf '%s\n' "$PWD" > "$MOCK_GATE_CWD_FILE"
fi
exit "${MOCK_GATE_STATUS:-0}"
GATESCRIPT
  chmod +x "$FIXTURE/scripts/gate.sh" "$FIXTURE/scripts/review.sh"

  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.email "review-fixture@test"
  git -C "$FIXTURE" config user.name "Review Fixture"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm "fixture base"
  # Two commits, because verification must be able to run the same command at
  # the base and at the head and compare (#216). A single-commit fixture makes
  # every command trivially non-discriminating and the oracle vacuous.
  export MOCK_BASE_COMMIT="$(git -C "$FIXTURE" rev-parse HEAD)"

  printf 'head\n' > "$FIXTURE/head-marker.txt"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm "fixture head"
  export MOCK_HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

  cat > "$FILE_SANDBOX/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *statusCheckRollup*)
      [ -n "${MOCK_GH_CALLS_FILE:-}" ] && printf '%s\t%s\t%s\n' "$*" "$MOCK_HEAD_SHA" "$MOCK_BASE_SHA" >> "$MOCK_GH_CALLS_FILE"
      # Tier 0 reads the CI rollup out of the same response as the head SHA
      # (#195). MOCK_PR_CHECKS drives it; the default is one green check, so
      # tests that do not care about CI keep their previous tier0: pass.
      _base="$MOCK_BASE_SHA"
      [ "${MOCK_GH_EMPTY_BASE:-0}" = "1" ] && _base=""
      printf '{"headRefOid":"%s","baseRefOid":"%s","statusCheckRollup":%s}\n' \
        "$MOCK_HEAD_SHA" "$_base" "$MOCK_PR_CHECKS"
      ;;
    *headRefOid*) printf '%s\n' "$MOCK_HEAD_SHA" ;;
    *body*) printf '%s\n' "$MOCK_PR_BODY" ;;
  esac
  exit 0
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "diff" ]; then
  printf '%s\n' "$MOCK_PR_DIFF"
  exit 0
fi
echo "mock gh: unexpected invocation: $*" >&2
exit 2
GHSCRIPT
  chmod +x "$FILE_SANDBOX/mockbin/gh"

  cat > "$FILE_SANDBOX/mockbin/curl" <<'CURLSCRIPT'
#!/usr/bin/env bash
if [ -n "${MOCK_CURL_ARGS_FILE:-}" ]; then
  printf '%s\n' "$*" >> "$MOCK_CURL_ARGS_FILE"
fi
if [ "${MOCK_CURL_FAIL:-0}" = "1" ]; then
  echo "mock curl: failing on request" >&2
  exit 7
fi
printf '%s\n' "$MOCK_CURL_RESPONSE"
exit 0
CURLSCRIPT
  chmod +x "$FILE_SANDBOX/mockbin/curl"

  export MOCKBIN="$FILE_SANDBOX/mockbin"
}

teardown_file() {
  if [ -d "${FIXTURE:-}/.git" ]; then
    git -C "$FIXTURE" worktree prune 2>/dev/null || true
  fi
}

# ────────────────────────────────────────────────────────────
# setup / teardown — lightweight per-test isolation
# ────────────────────────────────────────────────────────────

setup() {
  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$SANDBOX/tmp" "$SANDBOX/home"

  export MOCK_CURL_ARGS_FILE="$SANDBOX/mock-curl-args.txt"
  export MOCK_CURL_RESPONSE='{"model":"deepseek-chat","choices":[{"message":{"content":"{\"findings\":[],\"commentary\":\"No issues found.\"}"},"finish_reason":"stop"}]}'

  unset MOCK_GH_FAIL MOCK_CURL_FAIL MOCK_GATE_STATUS MOCK_GATE_CWD_FILE MOCK_GH_EMPTY_BASE
  # Tier 0 reads CI, not a local gate (#195). One green check by default, so a
  # test that says nothing about CI gets tier0: pass, as it did before.
  export MOCK_PR_CHECKS='[{"name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]'
  # Verification discriminates head against base (#216): the base SHA travels
  # in the same response as the head SHA and the rollup, so one gh pr view
  # binds all three and no later push can separate them.
  export MOCK_BASE_SHA="$MOCK_BASE_COMMIT"
  export MOCK_GH_CALLS_FILE="$SANDBOX/gh-calls.txt"
  export MOCK_PR_BODY="Fixture PR body: a stand-in description."
  export MOCK_PR_DIFF="diff --git a/fixture.txt b/fixture.txt
index 0000000..1111111 100644
--- a/fixture.txt
+++ b/fixture.txt
@@ -0,0 +1 @@
+fixture
"

  export REVIEWS_ROOT="$SANDBOX/home/.local/share/federation-recon/reviews"
  mkdir -p "$REVIEWS_ROOT"
  unset REVIEW_TIER_COMPLETION_TOKEN_CAP REVIEW_RUN_COMPLETION_TOKEN_CAP REVIEW_REASONING_EFFORT REVIEW_DEEPSEEK_THINKING_MODE
}

teardown() {
  for pid in $(jobs -pr); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

# run_review [args...] — invoke the fixture's real review.sh with the sandbox
# environment: mocked gh on PATH, HOME redirected so artifacts land in the
# sandbox, TMPDIR redirected so worktrees land where the tests look.
run_review() {
  HOME="$SANDBOX/home" PATH="$MOCKBIN:$PATH" TMPDIR="$SANDBOX/tmp" \
    bash "$FIXTURE/scripts/review.sh" "$@"
}

latest_run_dir() {
  find "$REVIEWS_ROOT" -maxdepth 1 -type d -name 'rv-*' | sort | tail -1
}

# _verdict_field <json-artifact> <dotted.path> — read a dotted field from any
# JSON artifact (the verdict, or a tier artifact).
_verdict_field() {
  python3 -c "
import json, sys
value = json.load(open(sys.argv[1]))
for part in '$2'.split('.'):
    value = value[part]
print(value)
" "$1"
}

# ────────────────────────────────────────────────────────────
#  1. USAGE — a missing or malformed --pr is a usage error
# ────────────────────────────────────────────────────────────

@test "review-runner: missing or malformed --pr is a usage error (exit 1)" {
  run run_review
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]
  [[ "$output" == *"--pr"* ]]

  run run_review --pr
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]

  run run_review --pr abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"usage:"* ]]

  run run_review --pr 0
  [ "$status" -eq 1 ]

  run run_review --bogus 5
  [ "$status" -eq 1 ]

  # A usage error is the only non-zero exit; no artifact is written.
  [ -z "$(find "$REVIEWS_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'rv-*')" ]
}

# ────────────────────────────────────────────────────────────
#  2. WORKTREE — created at the head SHA, destroyed afterwards
# ────────────────────────────────────────────────────────────

@test "review-runner: disposable worktree is created at the head SHA and destroyed" {
  # Tier 0 no longer runs the gate (#195), so the worktree is proven by the
  # thing that still needs it: a Tier 1B verification command, which executes
  # with the worktree as its CWD.
  MOCK_CURL_RESPONSE="$(python3 - "$SANDBOX/verify-cwd.txt" <<'PY'
import json, sys
inner = json.dumps({
    "findings": [{
        "severity": "blocking",
        "summary": "worktree probe",
        "verification_command": "pwd >> %s" % sys.argv[1],
    }],
    "commentary": "",
})
print(json.dumps({
    "model": "deepseek-chat",
    "choices": [{"message": {"content": inner}, "finish_reason": "stop"}],
}))
PY
)"
  export MOCK_CURL_RESPONSE

  run run_review --pr 178
  [ "$status" -eq 0 ]

  [ -f "$SANDBOX/verify-cwd.txt" ]
  # Verification runs the command at the head and then at the base (#196), so
  # the file holds two paths; the first is the head worktree.
  verify_cwd="$(head -1 "$SANDBOX/verify-cwd.txt")"
  [[ "$verify_cwd" == "$SANDBOX/tmp/review-worktree."* ]]

  # No worktree registration remains — the fixture's own worktree is all.
  run git -C "$FIXTURE" worktree list --porcelain
  [ "$(printf '%s\n' "$output" | grep -c '^worktree ')" = "1" ]

  # No worktree directory remains on disk.
  run find "$SANDBOX/tmp" -maxdepth 1 -type d -name 'review-worktree.*'
  [ -z "$output" ]
}

# ────────────────────────────────────────────────────────────
#  3. ARTIFACT LOCATION — verdict JSON outside the repository
# ────────────────────────────────────────────────────────────

@test "review-runner: verdict JSON is written outside the repository" {
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -n "$run_dir" ]
  [ -f "$run_dir/verdict.json" ]

  # The artifact lives under the sandbox review root, never inside the repo.
  [[ "$run_dir" == "$REVIEWS_ROOT"/* ]]
  [[ "$run_dir" != "$FIXTURE"/* ]]

  # The fixture repository is untouched: no new files, no modified files.
  run git -C "$FIXTURE" status --porcelain
  [ -z "$output" ]
}

# ────────────────────────────────────────────────────────────
#  4. SCHEMA — the verdict artifact conforms to the committed schema
# ────────────────────────────────────────────────────────────

@test "review-runner: verdict JSON validates against the schema" {
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_schema "$run_dir/verdict.json" "$REPO_ROOT/schemas/review-verdict.schema.json"
  [ "$status" -eq 0 ]

  # The stored shape matches the spec: run_id format, LOW risk, empty findings.
  [ "$(_verdict_field "$run_dir/verdict.json" run_id)" = "$(basename "$run_dir")" ]
  [[ "$(_verdict_field "$run_dir/verdict.json" run_id)" =~ ^rv-[0-9]{8}-[0-9]{3}$ ]]
  [ "$(_verdict_field "$run_dir/verdict.json" risk_class)" = "LOW" ]
  [ "$(_verdict_field "$run_dir/verdict.json" subject_head_sha)" = "$MOCK_HEAD_SHA" ]
}

# ────────────────────────────────────────────────────────────
#  5. AGGREGATION — the deterministic aggregator is called and
#     its word is stored in the artifact
# ────────────────────────────────────────────────────────────

@test "review-runner: aggregator is called and its verdict word is stored" {
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # The runner writes a placeholder verdict, then the aggregator recomputes
  # it. A green gate with no findings and LOW risk aggregates to APPROVE; if
  # the runner skipped the aggregator the stored field would still be the
  # PARTIAL placeholder.
  stored="$(_verdict_field "$run_dir/verdict.json" verdict)"
  [[ "$stored" =~ ^(APPROVE|REJECT|PARTIAL|STALE)$ ]]
  [ "$stored" = "APPROVE" ]

  # Re-running the aggregator against the artifact yields the same word —
  # the runner called it with the artifact and the head SHA.
  run bash "$FIXTURE/scripts/review-verdict.sh" "$run_dir/verdict.json" "$MOCK_HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "$stored" ]
}

# ────────────────────────────────────────────────────────────
#  6. TIER ARTIFACTS — gate log and stub tier files after a run
# ────────────────────────────────────────────────────────────

@test "review-runner: tier0.log and stub tier artifacts exist after a run" {
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # Tier 0 reads CI (#195). tier0.log survives as the evidence trail, but it
  # records the rollup the conclusion came from instead of the output of a
  # gate that ran locally.
  [ -f "$run_dir/tier0.log" ]
  [ -s "$run_dir/tier0.log" ]
  grep -q "CI status rollup" "$run_dir/tier0.log"
  grep -q "statusCheckRollup" "$run_dir/tier0.log"
  ! grep -q "fixture gate" "$run_dir/tier0.log"
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.tier0)" = "pass" ]

  # Tier 1A and 1B ran their model calls (against the mocked provider) and
  # recorded "complete" in their per-phase artifacts.
  [ -f "$run_dir/tier1a.json" ]
  [ -f "$run_dir/tier1b.json" ]
  grep -q '"complete"' "$run_dir/tier1a.json"
  grep -q '"complete"' "$run_dir/tier1b.json"
  # No escalation (LOW risk, no findings wired into the verdict), so Tier 2
  # did not run and left no artifact.
  [ ! -e "$run_dir/tier2.json" ]

  # The summary names the run, the PR, and the artifact directory.
  [[ "$output" == *"Review rv-"*" for PR #178 "* ]]
  [[ "$output" == *"Artifacts: $run_dir/"* ]]
}

# ────────────────────────────────────────────────────────────
#  7. GATE FAIL — a failing gate is a REJECT, still exit 0
# ────────────────────────────────────────────────────────────

@test "review-runner: a failing CI check aggregates to REJECT and exits 0" {
  export MOCK_PR_CHECKS='[{"name":"ci","status":"COMPLETED","conclusion":"FAILURE"}]'

  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # CI ran and rejected the commit -> the aggregator rejects; a failing
  # subject is not a runner crash.
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.tier0)" = "fail" ]
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "REJECT" ]
}

# ────────────────────────────────────────────────────────────
#  8. GH FAILURE — an unresolvable PR records PARTIAL, exits 0
# ────────────────────────────────────────────────────────────

@test "review-runner: gh failure writes a PARTIAL verdict and exits 0" {
  MOCK_GH_FAIL=1
  export MOCK_GH_FAIL

  run run_review --pr 178
  [ "$status" -eq 0 ]
  local review_output="$output"
  # The summary says PARTIAL — the review did not complete, and did not claim
  # otherwise.
  [[ "$review_output" == *"PARTIAL"* ]]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/verdict.json" ]
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.tier0)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" subject_head_sha)" = "unresolved" ]

  # The review never started: no worktree was ever created.
  run git -C "$FIXTURE" worktree list --porcelain
  [ "$(printf '%s\n' "$output" | grep -c '^worktree ')" = "1" ]
}

# ────────────────────────────────────────────────────────────
#  9. RUN ID — the sequence continues from existing runs
# ────────────────────────────────────────────────────────────

@test "review-runner: run ID sequence continues from existing runs" {
  today="$(date +%Y%m%d)"
  mkdir -p "$REVIEWS_ROOT/rv-${today}-001"

  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  run_id="$(_verdict_field "$run_dir/verdict.json" run_id)"
  [ "$run_id" = "rv-${today}-002" ]
  [[ "$run_id" =~ ^rv-[0-9]{8}-[0-9]{3}$ ]]
}

# ────────────────────────────────────────────────────────────
#  10. TIER 1A — the model call: complete on a mocked success
# ────────────────────────────────────────────────────────────

@test "review-runner: tier1a mock success returns complete and writes a valid artifact" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"category\":\"substrate-dependency\",\"file\":\"scripts/gate.sh\",\"line\":1,\"summary\":\"The gate misses a check.\",\"verification_command\":\"test -f head-marker.txt\"},{\"question\":\"1c\",\"severity\":\"non-blocking\",\"summary\":\"The claims are overstated.\"}],\"commentary\":\"Full analysis text.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier1a.json" ]
  [ "$(_verdict_field "$run_dir/tier1a.json" status)" = "complete" ]
  [ "$(_verdict_field "$run_dir/tier1a.json" task)" = "review-analysis" ]

  # Model provenance: the model field from the provider RESPONSE is recorded
  # verbatim, for the future reviewer-differs-from-builder verification.
  [ "$(_verdict_field "$run_dir/tier1a.json" model)" = "mock-reviewer-model" ]
  [ "$(_verdict_field "$run_dir/tier1a.json" provider)" = "deepseek" ]

  # Structured findings: severity and verification_command come from the
  # model's JSON, the blocking finding was executed in the worktree and
  # confirmed, the non-blocking finding was never run, and the full analysis
  # is preserved as commentary plus the parsed response_json. There is no
  # verdict_line and no raw response_text anymore.
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert len(artifact["findings"]) == 2
assert artifact["findings"][0]["severity"] == "blocking"
assert artifact["findings"][0]["verification_command"] == "test -f head-marker.txt"
assert artifact["findings"][0]["verification_status"] == "confirmed"
assert artifact["findings"][1]["severity"] == "non-blocking"
assert artifact["findings"][1]["verification_status"] == "not_run"
assert artifact["commentary"] == "Full analysis text."
assert artifact["response_json"]["findings"][0]["question"] == "4c"
assert "verdict_line" not in artifact
assert "response_text" not in artifact
PYEOF

  # The request actually reached the configured endpoint with the configured
  # timeout, asked for the configured model, and advertised the JSON output
  # contract via response_format.
  grep -q "https://api.deepseek.com/v1/chat/completions" "$MOCK_CURL_ARGS_FILE"
  grep -q -- "--max-time 300" "$MOCK_CURL_ARGS_FILE"
  grep -q '"model": "deepseek-v4-flash"' "$run_dir/tier1a.request.json"
  grep -q '"max_tokens": 8192' "$run_dir/tier1a.request.json"
  grep -q '"thinking": {' "$run_dir/tier1a.request.json"
  grep -q '"type": "disabled"' "$run_dir/tier1a.request.json"
  ! grep -q '"reasoning_effort"' "$run_dir/tier1a.request.json"
  grep -q '"response_format"' "$run_dir/tier1a.request.json"
  grep -q '"json_object"' "$run_dir/tier1a.request.json"
}

# ────────────────────────────────────────────────────────────
#  11. TIER 1A — a failed provider call is an error, never a crash
# ────────────────────────────────────────────────────────────

@test "review-runner: tier1a mock curl failure returns error and exits 0" {
  export MOCK_CURL_FAIL=1
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["status"] == "error"
assert a["task"] == "review-analysis"
assert "curl failed" in a["error"]
assert a["provider"] == "deepseek"
assert a["requested_model"] == "deepseek-v4-flash"
assert a["response_model"] is None
assert a["requested_max_tokens"] == 8192
PYEOF
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "not_run" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" reason)" = "Tier 1A error" ]

  # A failed model call is a PARTIAL review — the runner exits 0 but never
  # reports green.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.adversarial-execution)" = "not_run" ]
}

@test "review-runner: provider exact-cap completion fails closed" {
  export REVIEW_TIER_COMPLETION_TOKEN_CAP=10 REVIEW_RUN_COMPLETION_TOKEN_CAP=20
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","usage":{"prompt_tokens":1,"completion_tokens":10},"choices":[{"message":{"content":"{\"findings\":[]}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir" <<'PYEOF'
import json, sys
run_dir = sys.argv[1]
a = json.load(open(run_dir + "/tier1a.json"))
assert a["status"] == "error"
assert a["timing"]["finish_reason"] == "stop"
assert a["timing"]["completion_tokens"] == 10
assert a["requested_max_tokens"] == 10
assert "completion usage reached requested maximum" in a["error"]
assert json.load(open(run_dir + "/tier1b.json"))["status"] == "not_run"
assert json.load(open(run_dir + "/verdict.json"))["verdict"] == "PARTIAL"
PYEOF
  [ "$(wc -l < "$MOCK_CURL_ARGS_FILE" | tr -d ' ')" -eq 1 ]
}

@test "review-runner: provider over-cap completion fails closed" {
  export REVIEW_TIER_COMPLETION_TOKEN_CAP=10 REVIEW_RUN_COMPLETION_TOKEN_CAP=20
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","usage":{"prompt_tokens":1,"completion_tokens":11},"choices":[{"message":{"content":"{\"findings\":[]}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir" <<'PYEOF'
import json, sys
run_dir = sys.argv[1]
a = json.load(open(run_dir + "/tier1a.json"))
assert a["status"] == "error"
assert a["timing"]["completion_tokens"] == 11
assert a["requested_max_tokens"] == 10
assert "completion usage reached requested maximum" in a["error"]
assert json.load(open(run_dir + "/tier1b.json"))["status"] == "not_run"
assert json.load(open(run_dir + "/verdict.json"))["verdict"] == "PARTIAL"
PYEOF
  [ "$(wc -l < "$MOCK_CURL_ARGS_FILE" | tr -d ' ')" -eq 1 ]
}

@test "review-runner: missing provider usage is incomplete telemetry" {
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/verdict.json" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))["budget"]
assert b["actual_known_totals"] == {"prompt_tokens": 0, "completion_tokens": 0, "reasoning_tokens": 0}
assert b["actual_usage_complete"] is False
PYEOF
}

@test "review-runner: complete provider usage is complete telemetry" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","usage":{"prompt_tokens":2,"completion_tokens":3},"choices":[{"message":{"content":"{\"findings\":[]}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/verdict.json" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))["budget"]
assert b["actual_known_totals"] == {"prompt_tokens": 4, "completion_tokens": 6, "reasoning_tokens": 0}
assert b["actual_usage_complete"] is True
PYEOF
}

# ────────────────────────────────────────────────────────────
#  12. TIER 1B — the model call: complete on a mocked success
# ────────────────────────────────────────────────────────────

@test "review-runner: tier1b mock success returns complete and writes a valid artifact" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"3\",\"severity\":\"blocking\",\"summary\":\"The gate check is untested.\",\"verification_command\":\"test -f head-marker.txt\"},{\"question\":\"1b\",\"severity\":\"non-blocking\",\"summary\":\"The diff itself is the attack.\"}],\"commentary\":\"Full analysis text.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier1b.json" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "complete" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" task)" = "adversarial-execution" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" model)" = "mock-reviewer-model" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" provider)" = "deepseek" ]
  python3 - "$run_dir/tier1b.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert len(artifact["findings"]) == 2
assert artifact["findings"][0]["severity"] == "blocking"
assert artifact["findings"][0]["verification_command"] == "test -f head-marker.txt"
assert artifact["findings"][0]["verification_status"] == "confirmed"
assert artifact["findings"][1]["severity"] == "non-blocking"
assert artifact["findings"][1]["verification_status"] == "not_run"
assert artifact["commentary"] == "Full analysis text."
assert "verdict_line" not in artifact
PYEOF
}

# ────────────────────────────────────────────────────────────
#  13. TIER 1B — a failed provider call is an error, never a crash
# ────────────────────────────────────────────────────────────

@test "review-runner: tier1a failure prevents tier1b and exits 0" {
  export MOCK_CURL_FAIL=1
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier1b.json" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "not_run" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" task)" = "adversarial-execution" ]
  [ "$(wc -l < "$MOCK_CURL_ARGS_FILE" | tr -d ' ')" -eq 1 ]

  # A failed model call is a PARTIAL review — never green.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.adversarial-execution)" = "not_run" ]
}

@test "review-runner: configured caps reserve the remaining run budget" {
  export REVIEW_TIER_COMPLETION_TOKEN_CAP=6000 REVIEW_RUN_COMPLETION_TOKEN_CAP=10000
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  grep -q '"max_tokens": 6000' "$run_dir/tier1a.request.json"
  grep -q '"max_tokens": 4000' "$run_dir/tier1b.request.json"
  python3 - "$run_dir/verdict.json" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))["budget"]
assert b["requested_total"] == 10000
assert b["configured_tier_completion_token_cap"] == 6000
assert b["configured_run_completion_token_cap"] == 10000
PYEOF
}

@test "review-runner: invalid cap makes zero provider calls" {
  export REVIEW_TIER_COMPLETION_TOKEN_CAP=bad
  run run_review --pr 178
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]

}

@test "review-runner: invalid DeepSeek effort makes zero provider calls" {
  export REVIEW_DEEPSEEK_THINKING_MODE=enabled REVIEW_REASONING_EFFORT=low
  run run_review --pr 178
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
}

@test "review-runner: invalid DeepSeek thinking mode makes zero provider calls" {
  export REVIEW_DEEPSEEK_THINKING_MODE=invalid
  run run_review --pr 178
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
}

@test "review-runner: other provider preserves arbitrary reasoning effort" {
  # The model, not the route, decides the thinking contract (#227), so this
  # passthrough has to be pinned with a model that is genuinely not DeepSeek.
  # It used to set only REVIEW_PROVIDER=other and inherit the default DeepSeek
  # model, which made "no thinking field" and "deepseek model" true at once —
  # a contradiction the builder could only resolve by weakening the guard,
  # because scripts/test/ is forbidden to it.
  export REVIEW_PROVIDER=other REVIEW_MODEL=qwen3.7-plus REVIEW_REASONING_EFFORT=medium
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  ! grep -q '"thinking"' "$run_dir/tier1a.request.json"
  grep -q '"reasoning_effort": "medium"' "$run_dir/tier1a.request.json"
  python3 - "$run_dir/verdict.json" <<'PYEOF'
import json, sys
b = json.load(open(sys.argv[1]))["budget"]
assert b["thinking_mode"] is None
assert b["reasoning_effort"] == "medium"
PYEOF
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_schema "$run_dir/verdict.json" "$REPO_ROOT/schemas/review-verdict.schema.json"
  [ "$status" -eq 0 ]
}

@test "review-runner: enabled DeepSeek high effort sends thinking fields" {
  export REVIEW_DEEPSEEK_THINKING_MODE=enabled REVIEW_REASONING_EFFORT=high
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  grep -q '"thinking": {' "$run_dir/tier1a.request.json"
  grep -q '"type": "enabled"' "$run_dir/tier1a.request.json"
  grep -q '"reasoning_effort": "high"' "$run_dir/tier1a.request.json"
}

@test "review-runner: disabled DeepSeek effort makes zero provider calls" {
  export REVIEW_REASONING_EFFORT=high
  run run_review --pr 178
  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
}

# ────────────────────────────────────────────────────────────
#  Thinking is a property of the MODEL, not of the route (#227)
# ────────────────────────────────────────────────────────────
#
# Measured on 2026-08-10, same review request, deepseek-v4-pro through
# https://opencode.ai/zen/go/v1:
#
#   as sent today:            finish=length  completion=8192   reasoning=7953
#   + thinking: disabled:     finish=stop    completion=1203   reasoning=0
#
# A tenth of the tokens and the more complete answer. The guard existed and
# silently did not apply, because it was keyed on REVIEW_PROVIDER while the
# contract belongs to the model at the end of the route.

@test "review-runner: a deepseek model keeps the thinking contract off-provider" {
  export REVIEW_PROVIDER=opencode-go REVIEW_MODEL=deepseek-v4-pro
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  grep -q '"thinking": {' "$run_dir/tier1a.request.json"
  grep -q '"type": "disabled"' "$run_dir/tier1a.request.json"
}

@test "review-runner: enabled thinking off-provider still sends effort" {
  export REVIEW_PROVIDER=opencode-go REVIEW_MODEL=deepseek-v4-flash
  export REVIEW_DEEPSEEK_THINKING_MODE=enabled REVIEW_REASONING_EFFORT=high
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  grep -q '"type": "enabled"' "$run_dir/tier1a.request.json"
  grep -q '"reasoning_effort": "high"' "$run_dir/tier1a.request.json"
}

@test "review-runner: a non-deepseek model on any route sends no thinking field" {
  export REVIEW_PROVIDER=opencode-go REVIEW_MODEL=qwen3.7-plus
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  ! grep -q '"thinking"' "$run_dir/tier1a.request.json"
}

@test "review-runner: an invalid thinking mode fails closed off-provider too" {
  export REVIEW_PROVIDER=opencode-go REVIEW_MODEL=deepseek-v4-pro
  export REVIEW_DEEPSEEK_THINKING_MODE=sometimes
  run run_review --pr 178
  [ "$status" -eq 0 ]
  # A misconfigured contract must stop before the provider is called at all.
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
}

@test "review-runner: parse errors retain response usage and provenance" {
  export MOCK_CURL_RESPONSE='{"model":"served-model","usage":{"prompt_tokens":11,"completion_tokens":7,"completion_tokens_details":{"reasoning_tokens":3}},"choices":[{"message":{"content":"{\"findings\":[]}"},"finish_reason":"length"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
a = json.load(open(sys.argv[1]))
assert a["status"] == "error"
assert a["provider"] == "deepseek" and a["requested_model"] == "deepseek-v4-flash"
assert a["response_model"] == "served-model" and a["requested_max_tokens"] == 8192
assert a["timing"]["finish_reason"] == "length"
assert a["error"] == "truncated response (finish_reason: length)"
assert a["timing"]["prompt_tokens"] == 11 and a["timing"]["completion_tokens"] == 7 and a["timing"]["reasoning_tokens"] == 3
b = json.load(open(sys.argv[1].replace("tier1a.json", "verdict.json")))["budget"]
assert b["actual_known_totals"] == {"prompt_tokens": 11, "completion_tokens": 7, "reasoning_tokens": 3}
assert b["requested_total"] == 8192
PYEOF
}

# ────────────────────────────────────────────────────────────
#  14. MODEL PROVENANCE — the recorded model is who answered,
#     not who was asked
# ────────────────────────────────────────────────────────────

@test "review-runner: model provenance records the response model, not the requested model" {
  # The provider answers with a different model than the request asked for;
  # the artifact must record the response's model. Bootstrapping records only,
  # no enforcement — but the record is the evidence a future check reads.
  export MOCK_CURL_RESPONSE='{"model":"served-by-another-provider","choices":[{"message":{"content":"{\"findings\":[],\"commentary\":\"No issues found.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/tier1a.json" model)" = "served-by-another-provider" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" model)" = "served-by-another-provider" ]

  # The request asked for the configured model; who answered is recorded
  # separately. And an empty findings array is a valid, complete response:
  # the tier is complete with no findings, not an error.
  grep -q '"model": "deepseek-v4-flash"' "$run_dir/tier1a.request.json"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert artifact["findings"] == []
assert artifact["commentary"] == "No issues found."
assert artifact["status"] == "complete"
PYEOF
}

# ────────────────────────────────────────────────────────────
#  15. VERIFICATION — a blocking finding whose command exits 0
#      is confirmed and rejects
# ────────────────────────────────────────────────────────────

@test "review-runner: blocking finding verified by its command aggregates to REJECT" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"category\":\"substrate-dependency\",\"file\":\"scripts/gate.sh\",\"line\":1,\"summary\":\"The gate would miss a real defect.\",\"verification_command\":\"test -f head-marker.txt\"}],\"commentary\":\"The blocking defect is real.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # The verification command ran in the worktree and exited 0, so the
  # finding is confirmed — and a confirmed blocking finding rejects.
  python3 - "$run_dir/tier1a.json" "$run_dir/verdict.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "blocking"
assert f["verification_command"] == "test -f head-marker.txt"
assert f["verification_status"] == "confirmed"
verdict = json.load(open(sys.argv[2]))
assert verdict["findings"][0]["severity"] == "blocking"
assert verdict["findings"][0]["verification_status"] == "confirmed"
assert verdict["verdict"] == "REJECT"
PYEOF

  # The verification log records the command, the exit code, stdout, stderr.
  [ -f "$run_dir/verify.tier1a.0.log" ]
  grep -q "test -f head-marker.txt" "$run_dir/verify.tier1a.0.log"
  grep -q "exit code (head): 0" "$run_dir/verify.tier1a.0.log"

  # A confirmed blocking finding is an escalation trigger: Tier 2 ran (stub).
  [ -f "$run_dir/tier2.json" ]
  [ "$(_verdict_field "$run_dir/tier2.json" status)" = "not_run" ]
}

# ────────────────────────────────────────────────────────────
#  16. VERIFICATION — a blocking finding whose command exits 1
#      is refuted and does not reject
# ────────────────────────────────────────────────────────────

@test "review-runner: blocking finding refuted by its command aggregates to APPROVE" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"A file that must exist does not.\",\"verification_command\":\"test -f nonexistent-file\"}],\"commentary\":\"Suspected defect.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" "$run_dir/verdict.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "blocking"
assert f["verification_status"] == "rejected"
verdict = json.load(open(sys.argv[2]))
assert verdict["findings"][0]["severity"] == "blocking"
assert verdict["findings"][0]["verification_status"] == "rejected"
assert verdict["verdict"] == "APPROVE"
PYEOF

  # The refuted finding is not an escalation trigger: Tier 2 stayed a stub
  # and left no artifact.
  [ ! -e "$run_dir/tier2.json" ]
}

# ────────────────────────────────────────────────────────────
#  17. VERIFICATION — a blocking finding without a command is
#      downgraded to non-blocking and cannot reject
# ────────────────────────────────────────────────────────────

@test "review-runner: blocking finding without a verification command is downgraded" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"1c\",\"severity\":\"blocking\",\"summary\":\"The claims are overstated.\"}],\"commentary\":\"Suspected but unverifiable.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" "$run_dir/verdict.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "non-blocking"
assert f["claimed_severity"] == "blocking"
assert f["verification_status"] == "inconclusive"
assert f["summary"].startswith("[unverified] ")
verdict = json.load(open(sys.argv[2]))
assert verdict["findings"][0]["severity"] == "non-blocking"
assert verdict["verdict"] == "APPROVE"
PYEOF

  # An inconclusive finding IS an escalation trigger: the model made a
  # blocking claim it couldn't back up, so Tier 2 should investigate.
  [ -f "$run_dir/tier2.json" ]
  [ "$(_verdict_field "$run_dir/tier2.json" status)" = "not_run" ]
}

# ────────────────────────────────────────────────────────────
#  18. PARSING — non-JSON model content is a tier error, never
#      empty findings, and the review is PARTIAL
# ────────────────────────────────────────────────────────────

@test "review-runner: non-JSON model content is a tier error, never empty findings" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"No blocking findings. verdict: APPROVE"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/tier1a.json" status)" = "error" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "not_run" ]
  [ "$(wc -l < "$MOCK_CURL_ARGS_FILE" | tr -d ' ')" -eq 1 ]
  # A model that stopped following the format decided nothing: the review is
  # incomplete — PARTIAL, never approval, and never a fabricated reject.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.adversarial-execution)" = "not_run" ]
}

# ────────────────────────────────────────────────────────────
#  19. PARSING — a truncated completion (finish_reason length)
#      is a tier error, and the review is PARTIAL
# ────────────────────────────────────────────────────────────

@test "review-runner: a truncated model response (finish_reason length) is a tier error" {
  # The content would parse fine; the truncation alone makes the tier error.
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[]}"},"finish_reason":"length"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/tier1a.json" status)" = "error" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "not_run" ]
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
}

# ────────────────────────────────────────────────────────────
#  20. VERIFICATION — a corrupt tier artifact does not crash
#      the runner (exit 0 always)
# ────────────────────────────────────────────────────────────

@test "review-runner: corrupt tier artifact does not crash the runner" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"real finding\",\"verification_command\":\"true\"}],\"commentary\":\"ok\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # Corrupt the tier artifact before verification would have run —
  # but since verification already ran inline, we corrupt and re-run
  # _verify_findings manually by writing garbage to the artifact and
  # checking the runner didn't crash on the first run.
  # Instead: prove the property directly — corrupt the JSON and invoke
  # the function, confirming it does not crash.
  echo "NOT JSON" > "$run_dir/tier1a.json"
  (
    cd "$REPO_ROOT"
    export run_dir
    export REVIEW_VERIFY_TIMEOUT=5
    export REVIEW_VERIFY_MAX=20
    # Source the function and call it; set -e is on by default.
    set -euo pipefail
    eval "$(sed -n '/_verify_findings()/,/^}/p' scripts/review.sh)"
    _verify_findings "$FIXTURE" 2>/dev/null
  )
  # If we get here, the function did not crash under set -e.
}

@test "review-runner: head success and base success is inconclusive and non-blocking" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Same result in both revisions.\",\"verification_command\":\"test -f scripts/gate.sh\"}],\"commentary\":\"Check both revisions.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["severity"] == "non-blocking"
assert f["verification_status"] == "inconclusive"
assert f["summary"].startswith("[non-discriminating] ")
PYEOF
}

@test "review-runner: head failure rejects and does not run the base command" {
  export VERIFY_SHA_FILE="$SANDBOX/verify-shas"
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Head command rejects.\",\"verification_command\":\"printf \\\"%s\\\\n\\\" \\\"$(git rev-parse HEAD)\\\" >> \\\"$VERIFY_SHA_FILE\\\"; false\"}],\"commentary\":\"Head must reject.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "rejected"
PYEOF
  [ "$(sort -u "$VERIFY_SHA_FILE" | tr -d '\n')" = "$MOCK_HEAD_SHA" ]
}

# ────────────────────────────────────────────────────────────
#  Verification must not be able to change what it verifies (#228)
# ────────────────────────────────────────────────────────────
#
# Run rv-20260810-004 confirmed five blocking findings. Two of their commands
# ran `git checkout -- <file under review>` and `sed -i` on it inside the
# shared worktree, then ran the suite and reported on the result. Commands
# execute in order in one tree, so a finding silently changed the subject that
# every later command was measured against.
#
# Base discrimination (#196) does not help: a mutating command corrupts the
# base run too.

_finding_response() {
  python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
inner = json.dumps({'findings': findings, 'commentary': ''})
print(json.dumps({'model': 'm', 'choices': [{'message': {'content': inner}, 'finish_reason': 'stop'}]}))
" "$1"
}

@test "review-runner: a command that writes to the tree is inconclusive, not confirmed" {
  # Passes at head and fails at base, so discrimination alone would confirm it.
  # It also rewrites a tracked file, which has to override that.
  MOCK_CURL_RESPONSE="$(_finding_response '[{"severity":"blocking","summary":"writes to the subject","verification_command":"printf x >> head-marker.txt; test -f head-marker.txt"}]')"
  export MOCK_CURL_RESPONSE
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'MUTEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "inconclusive", f["verification_status"]
assert f["severity"] == "non-blocking"
assert f["summary"].startswith("[mutating-verification] "), f["summary"]
MUTEOF
}

@test "review-runner: an untracked file left behind is also a mutation" {
  # `git checkout -- .` is a no-op in a freshly checked-out worktree, so a
  # revert alone is not a distinct case. What is distinct: contamination does
  # not need to touch a tracked file. A command that drops a scratch file into
  # the tree changes the ground every later command stands on, so any change
  # to the worktree counts — tracked or not.
  MOCK_CURL_RESPONSE="$(_finding_response '[{"severity":"blocking","summary":"leaves a scratch file","verification_command":"touch scratch-evidence.txt; test -f head-marker.txt"}]')"
  export MOCK_CURL_RESPONSE
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'UNTEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "inconclusive", f["verification_status"]
assert f["summary"].startswith("[mutating-verification] "), f["summary"]
UNTEOF
}


@test "review-runner: one finding's command cannot change another finding's result" {
  MOCK_CURL_RESPONSE="$(_finding_response '[{"severity":"blocking","summary":"deletes the marker","verification_command":"rm -f head-marker.txt; true"},{"severity":"blocking","summary":"needs the marker","verification_command":"test -f head-marker.txt"}]')"
  export MOCK_CURL_RESPONSE
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  # The second finding discriminates on its own: the marker exists at the head
  # and not at the base. It must reach that result whatever the first command
  # did to the tree.
  python3 - "$run_dir/tier1a.json" <<'ISOEOF'
import json, sys
findings = json.load(open(sys.argv[1]))["findings"]
assert findings[1]["verification_status"] == "confirmed", findings[1]["verification_status"]
ISOEOF
}

@test "review-runner: a read-only command is unaffected by the isolation" {
  MOCK_CURL_RESPONSE="$(_finding_response '[{"severity":"blocking","summary":"reads only","verification_command":"test -f head-marker.txt"}]')"
  export MOCK_CURL_RESPONSE
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'ROEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "confirmed", f["verification_status"]
assert f["severity"] == "blocking"
ROEOF
}

@test "review-runner: unavailable base SHA is inconclusive and marked base-unverified" {
  # Present but unusable: a well-formed SHA that is not in the repository, so
  # the base worktree cannot be created. Distinct from a missing baseRefOid,
  # which fails metadata resolution before any model call — see the test
  # below. Collapsing the two onto an empty string makes them contradictory.
  export MOCK_BASE_SHA="0000000000000000000000000000000000000000"
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Base cannot be checked.\",\"verification_command\":\"test -f head-marker.txt\"}],\"commentary\":\"Base is unavailable.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "inconclusive"
assert f["severity"] == "non-blocking"
assert f["summary"].startswith("[base-unverified] ")
PYEOF
}

@test "review-runner: base verification timeout is inconclusive and marked base-timeout" {
  export REVIEW_VERIFY_TIMEOUT=1
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Base command hangs.\",\"verification_command\":\"test -f head-marker.txt || sleep 5\"}],\"commentary\":\"Bounded timeout case.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
f = json.load(open(sys.argv[1]))["findings"][0]
assert f["verification_status"] == "inconclusive"
assert f["summary"].startswith("[base-timeout] ")
PYEOF
}

@test "review-runner: one metadata call carries and binds head and base SHAs" {
  run run_review --pr 178
  [ "$status" -eq 0 ]
  [ "$(grep -F 'headRefOid,baseRefOid' "$MOCK_GH_CALLS_FILE" | wc -l | tr -d ' ')" -eq 1 ]
  metadata_call="$(grep -F 'headRefOid,baseRefOid' "$MOCK_GH_CALLS_FILE")"
  [[ "$metadata_call" == *"$MOCK_HEAD_SHA"*"$MOCK_BASE_SHA"* ]]
  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/verdict.json" subject_head_sha)" = "$MOCK_HEAD_SHA" ]
}

@test "review-runner: missing base SHA fails metadata resolution closed" {
  export MOCK_GH_EMPTY_BASE=1
  before_worktrees="$(git -C "$FIXTURE" worktree list --porcelain)"
  run run_review --pr 178
  [ "$status" -eq 0 ]
  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.tier0)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" subject_head_sha)" = "$MOCK_HEAD_SHA" ]
  [ "$(grep -F 'headRefOid,baseRefOid' "$MOCK_GH_CALLS_FILE" | wc -l | tr -d ' ')" -eq 1 ]
  [ ! -s "$MOCK_CURL_ARGS_FILE" ]
  [ "$(git -C "$FIXTURE" worktree list --porcelain)" = "$before_worktrees" ]
  [ "$(find "$SANDBOX/tmp" -maxdepth 1 -type d -name 'review-worktree.*' | wc -l | tr -d ' ')" -eq 0 ]
}
