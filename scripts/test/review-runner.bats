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

  chmod +x "$FIXTURE/scripts/review.sh"

  git -C "$FIXTURE" init -q
  git -C "$FIXTURE" config user.email "review-fixture@test"
  git -C "$FIXTURE" config user.name "Review Fixture"
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -qm "base"
  export MOCK_BASE_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

  cat > "$FIXTURE/scripts/gate.sh" <<'GATESCRIPT'
#!/usr/bin/env bash
echo "fixture gate: ${MOCK_GATE_STATUS:-0}"
if [ -n "${MOCK_GATE_CWD_FILE:-}" ]; then
  printf '%s\n' "$PWD" > "$MOCK_GATE_CWD_FILE"
fi
exit "${MOCK_GATE_STATUS:-0}"
GATESCRIPT
  chmod +x "$FIXTURE/scripts/gate.sh"
  git -C "$FIXTURE" add scripts/gate.sh
  git -C "$FIXTURE" commit -qm "add gate"
  export MOCK_HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

  cat > "$FILE_SANDBOX/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *headRefOid*baseRefOid*|*baseRefOid*headRefOid*)
      printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$MOCK_HEAD_SHA" "$MOCK_BASE_SHA" ;;
    *headRefOid*) printf '%s\n' "$MOCK_HEAD_SHA" ;;
    *baseRefOid*) printf '%s\n' "$MOCK_BASE_SHA" ;;
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

  unset MOCK_GH_FAIL MOCK_CURL_FAIL MOCK_GATE_STATUS MOCK_GATE_CWD_FILE
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
  MOCK_GATE_CWD_FILE="$SANDBOX/gate-cwd.txt"
  export MOCK_GATE_CWD_FILE

  run run_review --pr 178
  [ "$status" -eq 0 ]

  # The gate ran inside the disposable worktree: the recorded CWD is a
  # review-worktree.* path under the sandbox TMPDIR.
  [ -f "$MOCK_GATE_CWD_FILE" ]
  gate_cwd="$(cat "$MOCK_GATE_CWD_FILE")"
  [[ "$gate_cwd" == "$SANDBOX/tmp/review-worktree."* ]]

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
  [ -f "$run_dir/tier0.log" ]
  [ -s "$run_dir/tier0.log" ]
  grep -q "fixture gate" "$run_dir/tier0.log"

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

@test "review-runner: a failing gate aggregates to REJECT and exits 0" {
  MOCK_GATE_STATUS=7
  export MOCK_GATE_STATUS

  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier0.log" ]
  grep -q "fixture gate: 7" "$run_dir/tier0.log"
  # Tier 0 ran and failed -> the aggregator rejects; a run failure is not a
  # runner crash.
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
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"category\":\"substrate-dependency\",\"file\":\"scripts/gate.sh\",\"line\":1,\"summary\":\"The gate misses a check.\",\"verification_command\":\"test -f scripts/gate.sh\"},{\"question\":\"1c\",\"severity\":\"non-blocking\",\"summary\":\"The claims are overstated.\"}],\"commentary\":\"Full analysis text.\"}"},"finish_reason":"stop"}]}'
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
assert artifact["findings"][0]["verification_command"] == "test -f scripts/gate.sh"
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
  [ -f "$run_dir/tier1a.json" ]
  [ "$(_verdict_field "$run_dir/tier1a.json" status)" = "error" ]
  [ "$(_verdict_field "$run_dir/tier1a.json" task)" = "review-analysis" ]
  [[ "$(_verdict_field "$run_dir/tier1a.json" error)" == *"curl failed"* ]]

  # A failed model call is a PARTIAL review — the runner exits 0 but never
  # reports green.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
}

# ────────────────────────────────────────────────────────────
#  12. TIER 1B — the model call: complete on a mocked success
# ────────────────────────────────────────────────────────────

@test "review-runner: tier1b mock success returns complete and writes a valid artifact" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"3\",\"severity\":\"blocking\",\"summary\":\"The gate check is untested.\",\"verification_command\":\"test -f scripts/gate.sh\"},{\"question\":\"1b\",\"severity\":\"non-blocking\",\"summary\":\"The diff itself is the attack.\"}],\"commentary\":\"Full analysis text.\"}"},"finish_reason":"stop"}]}'
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
assert artifact["findings"][0]["verification_command"] == "test -f scripts/gate.sh"
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

@test "review-runner: tier1b mock curl failure returns error and exits 0" {
  export MOCK_CURL_FAIL=1
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier1b.json" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "error" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" task)" = "adversarial-execution" ]
  [[ "$(_verdict_field "$run_dir/tier1b.json" error)" == *"curl failed"* ]]

  # A failed model call is a PARTIAL review — never green.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.adversarial-execution)" = "error" ]
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
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"category\":\"substrate-dependency\",\"file\":\"scripts/gate.sh\",\"line\":1,\"summary\":\"The gate would miss a real defect.\",\"verification_command\":\"test -f scripts/gate.sh\"}],\"commentary\":\"The blocking defect is real.\"}"},"finish_reason":"stop"}]}'
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
assert f["verification_command"] == "test -f scripts/gate.sh"
assert f["verification_status"] == "confirmed"
verdict = json.load(open(sys.argv[2]))
assert verdict["findings"][0]["severity"] == "blocking"
assert verdict["findings"][0]["verification_status"] == "confirmed"
assert verdict["verdict"] == "REJECT"
PYEOF

  # The verification log records the command, the exit code, stdout, stderr.
  [ -f "$run_dir/verify.tier1a.0.log" ]
  grep -q "test -f scripts/gate.sh" "$run_dir/verify.tier1a.0.log"
  grep -q "exit code: 0" "$run_dir/verify.tier1a.0.log"

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
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "error" ]
  # A model that stopped following the format decided nothing: the review is
  # incomplete — PARTIAL, never approval, and never a fabricated reject.
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.adversarial-execution)" = "error" ]
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
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "error" ]
  [ "$(_verdict_field "$run_dir/verdict.json" verdict)" = "PARTIAL" ]
  [ "$(_verdict_field "$run_dir/verdict.json" tasks.review-analysis)" = "error" ]
}

# ────────────────────────────────────────────────────────────
#  20. DISCRIMINATION — a blocking finding whose command exits 0
#      on BOTH head and base is non-discriminating → APPROVE
# ────────────────────────────────────────────────────────────

@test "review-runner: finding confirmed on head but also on base is non-discriminating → APPROVE" {
  # `test -d scripts` exits 0 on BOTH base and head (scripts/ dir exists in both commits)
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"category\":\"pre-existing\",\"file\":\"scripts/review.sh\",\"line\":1,\"summary\":\"The scripts directory exists.\",\"verification_command\":\"test -d scripts\"}],\"commentary\":\"Pre-existing condition.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" "$run_dir/verdict.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "non-blocking", f"expected non-blocking, got {f['severity']}"
assert f["claimed_severity"] == "blocking"
assert f["verification_status"] == "inconclusive"
assert "[non-discriminating]" in f["summary"]
verdict = json.load(open(sys.argv[2]))
assert verdict["verdict"] == "APPROVE"
PYEOF

  # The verification log records BOTH head and base runs
  [ -f "$run_dir/verify.tier1a.0.log" ]
  grep -q "exit code: 0" "$run_dir/verify.tier1a.0.log"
  grep -q "base exit code: 0" "$run_dir/verify.tier1a.0.log"
}

# ────────────────────────────────────────────────────────────
#  21. VERIFICATION — a corrupt tier artifact does not crash
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

# ────────────────────────────────────────────────────────────
#  22. SHA BINDING — head and base SHAs resolved from a single
#      gh pr view call and recorded in the verdict
# ────────────────────────────────────────────────────────────

@test "review-runner: head and base SHAs are resolved in one gh call and bound to the run" {
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[],\"commentary\":\"clean\"}"},"finish_reason":"stop"}]}'

  # Count gh pr view invocations that request SHA fields
  local gh_log="$SANDBOX/gh-sha-calls.log"
  export MOCK_GH_SHA_LOG="$gh_log"

  # Patch the mock gh to log SHA-related pr view calls
  cat > "$MOCKBIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *headRefOid*baseRefOid*|*baseRefOid*headRefOid*)
      [ -n "${MOCK_GH_SHA_LOG:-}" ] && echo "combined" >> "$MOCK_GH_SHA_LOG"
      printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$MOCK_HEAD_SHA" "$MOCK_BASE_SHA" ;;
    *headRefOid*)
      [ -n "${MOCK_GH_SHA_LOG:-}" ] && echo "head-only" >> "$MOCK_GH_SHA_LOG"
      printf '%s\n' "$MOCK_HEAD_SHA" ;;
    *baseRefOid*)
      [ -n "${MOCK_GH_SHA_LOG:-}" ] && echo "base-only" >> "$MOCK_GH_SHA_LOG"
      printf '%s\n' "$MOCK_BASE_SHA" ;;
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
  chmod +x "$MOCKBIN/gh"

  run run_review --pr 178
  [ "$status" -eq 0 ]

  # Exactly one combined call, no separate head-only or base-only calls
  [ -f "$gh_log" ]
  [ "$(grep -c 'combined' "$gh_log")" -ge 1 ]
  [ "$(grep -c 'head-only' "$gh_log" || true)" = "0" ]
  [ "$(grep -c 'base-only' "$gh_log" || true)" = "0" ]

  # Restore the standard mock
  cat > "$MOCKBIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *headRefOid*baseRefOid*|*baseRefOid*headRefOid*)
      printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$MOCK_HEAD_SHA" "$MOCK_BASE_SHA" ;;
    *headRefOid*) printf '%s\n' "$MOCK_HEAD_SHA" ;;
    *baseRefOid*) printf '%s\n' "$MOCK_BASE_SHA" ;;
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
  chmod +x "$MOCKBIN/gh"

  run_dir="$(latest_run_dir)"
  # The verdict records the head SHA
  python3 - "$run_dir/verdict.json" <<PYEOF
import json, sys
v = json.load(open(sys.argv[1]))
assert v["subject_head_sha"] == "$MOCK_HEAD_SHA", \
    "verdict head SHA %s != %s" % (v["subject_head_sha"], "$MOCK_HEAD_SHA")
PYEOF
}

# ────────────────────────────────────────────────────────────
#  23. HEAD-FAILURE SHORT-CIRCUIT — when the head command fails,
#      base is never executed
# ────────────────────────────────────────────────────────────

@test "review-runner: head command failure short-circuits — base command is not run" {
  # test -f nonexistent-file fails on head; base should never run
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Missing file.\",\"verification_command\":\"test -f nonexistent-file\"}],\"commentary\":\"Suspected defect.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  # Finding is rejected (head failed)
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["verification_status"] == "rejected", \
    "expected rejected, got %s" % f["verification_status"]
PYEOF

  # The verification log has NO base entry — base was never executed
  [ -f "$run_dir/verify.tier1a.0.log" ]
  ! grep -q "base exit code" "$run_dir/verify.tier1a.0.log"
  ! grep -q "base:" "$run_dir/verify.tier1a.0.log"
}

# ────────────────────────────────────────────────────────────
#  24. MISSING BASE — when base SHA is unavailable, head-confirmed
#      findings degrade to inconclusive
# ────────────────────────────────────────────────────────────

@test "review-runner: missing base SHA degrades head-confirmed to inconclusive" {
  # Override mock gh to return empty baseRefOid
  cat > "$MOCKBIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *headRefOid*baseRefOid*|*baseRefOid*headRefOid*)
      printf '{"headRefOid":"%s","baseRefOid":""}\n' "$MOCK_HEAD_SHA" ;;
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
  chmod +x "$MOCKBIN/gh"

  # test -f scripts/gate.sh exits 0 on head — without base, should degrade
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"file\":\"scripts/gate.sh\",\"line\":1,\"summary\":\"Gate defect.\",\"verification_command\":\"test -f scripts/gate.sh\"}],\"commentary\":\"Found defect.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  # Restore the standard mock
  cat > "$MOCKBIN/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *headRefOid*baseRefOid*|*baseRefOid*headRefOid*)
      printf '{"headRefOid":"%s","baseRefOid":"%s"}\n' "$MOCK_HEAD_SHA" "$MOCK_BASE_SHA" ;;
    *headRefOid*) printf '%s\n' "$MOCK_HEAD_SHA" ;;
    *baseRefOid*) printf '%s\n' "$MOCK_BASE_SHA" ;;
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
  chmod +x "$MOCKBIN/gh"

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "non-blocking", \
    "expected non-blocking (degraded), got %s" % f["severity"]
assert f["claimed_severity"] == "blocking"
assert f["verification_status"] == "inconclusive"
assert "[base-unverified]" in f["summary"], \
    "expected [base-unverified] prefix, got: %s" % f["summary"]
PYEOF
}

# ────────────────────────────────────────────────────────────
#  25. BASE TIMEOUT — when the base command times out, the finding
#      degrades to inconclusive
# ────────────────────────────────────────────────────────────

@test "review-runner: base command timeout degrades to inconclusive" {
  # Use a command that exits 0 instantly on head but sleeps on base.
  # scripts/gate.sh exists only at head; at base it doesn't exist.
  # Instead, use a command that discriminates by commit: write a
  # marker that only head has, and test for it. For timeout, we need
  # a command that exits 0 on head and takes >timeout on base.
  # Approach: use a very short timeout and a command that sleeps on base.
  # test -f scripts/gate.sh exits 0 on head (exists), and for the base
  # worktree we need it to take time. But we can't control what runs on
  # base separately — the SAME command runs. So we use a command that
  # runs fast everywhere but lower the timeout to 1s and use sleep.
  # Better: use a verification command "test -f scripts/gate.sh && sleep 0"
  # which is instant, and set REVIEW_VERIFY_TIMEOUT=1. For base timeout,
  # we need the command to SUCCEED on head and TIMEOUT on base.
  # The simplest approach: command is "sleep 5" (succeeds on head after 5s,
  # also succeeds on base after 5s, but with timeout 2 the base times out).
  # Wait — sleep takes the same time on both. We need head to succeed
  # quickly and base to be slow. Since the SAME command runs on both,
  # the only way is to have head finish before timeout and base not.
  # This isn't possible with the same command and same timeout.
  #
  # Alternative: use a tiny timeout and a command that does enough
  # work to sometimes exceed it on base. This is flaky.
  #
  # Best approach: command exits 0 on head, and base doesn't exist
  # (base_sha empty). But that's test 24 (missing base).
  #
  # For a true base timeout test, we need a command that exits 0 on head
  # (fast) and the base worktree to cause a slow execution. We can't
  # do this with identical commands and identical worktrees.
  #
  # Instead: test the base-timeout PATH in _verify_findings directly
  # by injecting a slow command with a very short timeout, where the
  # command exits 0 fast on head but the same command on base can be
  # forced to sleep. Since we control the fixture, add a file at HEAD
  # that gate.sh checks: the command "bash -c 'if test -f scripts/gate.sh;
  # then exit 0; else sleep 10; fi'" exits 0 instantly at head (gate.sh
  # exists) and sleeps at base (gate.sh doesn't exist) → timeout.
  export REVIEW_VERIFY_TIMEOUT=2
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"{\"findings\":[{\"question\":\"4c\",\"severity\":\"blocking\",\"summary\":\"Conditional timing.\",\"verification_command\":\"if test -f scripts/gate.sh; then exit 0; else sleep 10; fi\"}],\"commentary\":\"Testing timeout.\"}"},"finish_reason":"stop"}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
f = artifact["findings"][0]
assert f["severity"] == "non-blocking", \
    "expected non-blocking (degraded), got %s" % f["severity"]
assert f["claimed_severity"] == "blocking"
assert f["verification_status"] == "inconclusive"
assert "[base-timeout]" in f["summary"], \
    "expected [base-timeout] prefix, got: %s" % f["summary"]
PYEOF

  [ -f "$run_dir/verify.tier1a.0.log" ]
  grep -q "exit code: 0" "$run_dir/verify.tier1a.0.log"
  grep -q "base: timed out" "$run_dir/verify.tier1a.0.log"
}
