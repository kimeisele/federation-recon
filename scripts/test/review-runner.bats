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
#   * a review that cannot start (gh failure) records PARTIAL and exits 0
#   * the only non-zero exit is a usage error

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$SANDBOX/mockbin" "$SANDBOX/tmp" "$SANDBOX/home"

  # A disposable fixture repository that looks like a federation-recon
  # checkout: the real review.sh, the real aggregator, the real schema, and a
  # stand-in gate.sh. The worktree the runner cuts is carved from this
  # fixture, so the gate that runs inside it is the stand-in — fast and
  # offline — never the real gate (which would recurse into this very suite).
  FIXTURE="$SANDBOX/fixture"
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/schemas"
  cp "$REPO_ROOT/scripts/review.sh" "$FIXTURE/scripts/review.sh"
  cp "$REPO_ROOT/scripts/review-verdict.sh" "$FIXTURE/scripts/review-verdict.sh"
  cp "$REPO_ROOT/schemas/review-verdict.schema.json" "$FIXTURE/schemas/"

  # Stand-in gate: records the directory it ran in (which must be the
  # disposable worktree) and exits with the configured status.
  cat > "$FIXTURE/scripts/gate.sh" <<'GATESCRIPT'
#!/usr/bin/env bash
# Stand-in gate for review-runner tests: fast, offline, deterministic.
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
  git -C "$FIXTURE" commit -qm "fixture"
  export MOCK_HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"

  # Mock gh: the runner calls `pr view ... --json headRefOid` (head SHA),
  # `pr view ... --json body` (PR description) and `pr diff` (the diff).
  cat > "$SANDBOX/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
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
  chmod +x "$SANDBOX/mockbin/gh"

  # Mock curl: the runner makes one provider call per tier. The mock records
  # its arguments (so tests can assert the endpoint and timeout reached the
  # wire), fails on demand, and otherwise prints a canned chat-completions
  # response. The default response carries the requested model and a clean
  # APPROVE, so runs that are not about the provider path still aggregate.
  cat > "$SANDBOX/mockbin/curl" <<'CURLSCRIPT'
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
  chmod +x "$SANDBOX/mockbin/curl"
  export MOCK_CURL_ARGS_FILE="$SANDBOX/mock-curl-args.txt"
  export MOCK_CURL_RESPONSE='{"model":"deepseek-chat","choices":[{"message":{"content":"No blocking findings.\nverdict: APPROVE"}}]}'

  export MOCK_PR_BODY="${MOCK_PR_BODY:-Fixture PR body: a stand-in description.}"
  export MOCK_PR_DIFF="${MOCK_PR_DIFF:-diff --git a/fixture.txt b/fixture.txt
index 0000000..1111111 100644
--- a/fixture.txt
+++ b/fixture.txt
@@ -0,0 +1 @@
+fixture
}"

  export REVIEWS_ROOT="$SANDBOX/home/.local/share/federation-recon/reviews"
  mkdir -p "$REVIEWS_ROOT"
}

teardown() {
  # Safety net: stop any background review a test left behind.
  for pid in $(jobs -pr); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

# run_review [args...] — invoke the fixture's real review.sh with the sandbox
# environment: mocked gh on PATH, HOME redirected so artifacts land in the
# sandbox, TMPDIR redirected so worktrees land where the tests look.
run_review() {
  HOME="$SANDBOX/home" PATH="$SANDBOX/mockbin:$PATH" TMPDIR="$SANDBOX/tmp" \
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
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"1. The claims are overstated.\n2. The gate is untested.\nverdict: REJECT"}}]}'
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

  # Findings extraction: the numbered lines became findings, the closing
  # verdict line was read, and the full model output is preserved.
  [ "$(_verdict_field "$run_dir/tier1a.json" verdict_line)" = "REJECT" ]
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert len(artifact["findings"]) == 2
assert artifact["findings"][0]["summary"] == "1. The claims are overstated."
assert artifact["findings"][1]["summary"] == "2. The gate is untested."
assert artifact["response_text"].startswith("1. The claims are overstated.")
PYEOF

  # The request actually reached the configured endpoint with the configured
  # timeout: the mock curl recorded the invocation.
  grep -q "https://api.deepseek.com/v1/chat/completions" "$MOCK_CURL_ARGS_FILE"
  grep -q -- "--max-time 300" "$MOCK_CURL_ARGS_FILE"
  grep -q '"model": "deepseek-chat"' "$run_dir/tier1a.request.json"
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
  export MOCK_CURL_RESPONSE='{"model":"mock-reviewer-model","choices":[{"message":{"content":"1. Execute the evasion in the worktree.\n2. Mutate the gate check.\nverdict: REJECT"}}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ -f "$run_dir/tier1b.json" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" status)" = "complete" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" task)" = "adversarial-execution" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" model)" = "mock-reviewer-model" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" provider)" = "deepseek" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" verdict_line)" = "REJECT" ]
  python3 - "$run_dir/tier1b.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert len(artifact["findings"]) == 2
assert artifact["findings"][0]["summary"] == "1. Execute the evasion in the worktree."
assert artifact["findings"][1]["summary"] == "2. Mutate the gate check."
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
  export MOCK_CURL_RESPONSE='{"model":"served-by-another-provider","choices":[{"message":{"content":"No numbered findings.\nverdict: APPROVE"}}]}'
  run run_review --pr 178
  [ "$status" -eq 0 ]

  run_dir="$(latest_run_dir)"
  [ "$(_verdict_field "$run_dir/tier1a.json" model)" = "served-by-another-provider" ]
  [ "$(_verdict_field "$run_dir/tier1b.json" model)" = "served-by-another-provider" ]

  # The request asked for the configured model; who answered is recorded
  # separately. And a response with no numbered findings still parses: the
  # findings array is empty, not an error.
  grep -q '"model": "deepseek-chat"' "$run_dir/tier1a.request.json"
  python3 - "$run_dir/tier1a.json" <<'PYEOF'
import json, sys
artifact = json.load(open(sys.argv[1]))
assert artifact["findings"] == []
assert artifact["verdict_line"] == "APPROVE"
PYEOF
}
