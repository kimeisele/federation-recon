#!/usr/bin/env bats
#
# Tier 0 reads CI status instead of re-running the gate locally (#195).
#
# The measured cost of the old behaviour: review rv-20260809-009 spent 1997 of
# its 2001 seconds inside `gate.sh --full`. The gate it re-ran had already been
# run by GitHub Actions on the same commit.
#
# Two properties are asserted here, and the second is the one that makes this
# more than a speed change:
#
#   1. Tier 0's status is derived from the CI conclusion for the PR head.
#   2. `gate.sh` is not executed at all. That is what removes the class of
#      failure in #221 and #217 — a local gate inheriting the reviewer's
#      environment and locale, then reporting the result against the PR.
#
# The status rollup and the head SHA must come from ONE `gh pr view` response.
# Fetched separately they can straddle a push, and Tier 0 would then report a
# conclusion belonging to a commit that is not the one under review.

setup_file() {
  export BATS_NO_PARALLELIZE_WITHIN_FILE=true
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"

  FILE_SANDBOX="$BATS_FILE_TMPDIR/shared"
  mkdir -p "$FILE_SANDBOX/mockbin"

  export FIXTURE="$FILE_SANDBOX/fixture"
  mkdir -p "$FIXTURE/scripts" "$FIXTURE/schemas"
  cp "$REPO_ROOT/scripts/review.sh" "$FIXTURE/scripts/review.sh"
  cp "$REPO_ROOT/scripts/review-verdict.sh" "$FIXTURE/scripts/review-verdict.sh"
  cp "$REPO_ROOT/schemas/review-verdict.schema.json" "$FIXTURE/schemas/"

  # A gate that records the fact it ran. Any test that finds this file has
  # caught Tier 0 still shelling out to the local gate.
  cat > "$FIXTURE/scripts/gate.sh" <<'GATESCRIPT'
#!/usr/bin/env bash
if [ -n "${MOCK_GATE_RAN_FILE:-}" ]; then
  printf 'ran\n' >> "$MOCK_GATE_RAN_FILE"
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

  # gh mock. `pr view` answers from MOCK_PR_VIEW when the caller asks for
  # anything containing statusCheckRollup, so the runner is free to fetch the
  # rollup together with the SHAs in a single call — and the test can prove it
  # did, because MOCK_GH_VIEW_CALLS counts them.
  cat > "$FILE_SANDBOX/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  case "$*" in
    *statusCheckRollup*)
      [ -n "${MOCK_GH_VIEW_CALLS:-}" ] && printf 'view\n' >> "$MOCK_GH_VIEW_CALLS"
      printf '%s\n' "$MOCK_PR_VIEW"
      ;;
    *baseRefOid*)
      # head and base as one tab-separated row, the shape #216 introduced.
      [ -n "${MOCK_GH_VIEW_CALLS:-}" ] && printf 'view\n' >> "$MOCK_GH_VIEW_CALLS"
      printf '%s\t%s\n' "$MOCK_HEAD_SHA" "$MOCK_HEAD_SHA"
      ;;
    *headRefOid*)
      # head SHA alone, the shape on main today. Answering this correctly is
      # what stops the pre-change runner from aborting early and passing these
      # tests vacuously.
      [ -n "${MOCK_GH_VIEW_CALLS:-}" ] && printf 'view\n' >> "$MOCK_GH_VIEW_CALLS"
      printf '%s\n' "$MOCK_HEAD_SHA"
      ;;
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
printf '%s\n' "${MOCK_CURL_RESPONSE}"
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

setup() {
  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  mkdir -p "$SANDBOX/tmp" "$SANDBOX/home"

  export MOCK_CURL_RESPONSE='{"model":"deepseek-v4-flash","choices":[{"message":{"content":"{\"findings\":[],\"commentary\":\"none\"}"},"finish_reason":"stop"}]}'
  export MOCK_PR_BODY="Fixture PR body."
  export MOCK_PR_DIFF="diff --git a/f.txt b/f.txt
--- a/f.txt
+++ b/f.txt
@@ -0,0 +1 @@
+f
"
  export MOCK_GATE_RAN_FILE="$SANDBOX/gate-ran.txt"
  export MOCK_GH_VIEW_CALLS="$SANDBOX/gh-view-calls.txt"
  export REVIEWS_ROOT="$SANDBOX/home/.local/share/federation-recon/reviews"
  mkdir -p "$REVIEWS_ROOT"
  unset MOCK_GH_FAIL MOCK_GATE_STATUS
}

run_review() {
  HOME="$SANDBOX/home" PATH="$MOCKBIN:$PATH" TMPDIR="$SANDBOX/tmp" \
    bash "$FIXTURE/scripts/review.sh" "$@"
}

latest_run_dir() {
  find "$REVIEWS_ROOT" -maxdepth 1 -type d -name 'rv-*' | sort | tail -1
}

_field() {
  python3 -c "
import json, sys
value = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    value = value[part]
print(value)
" "$1" "$2"
}

# _pr_view <sha> <check-json-array> — one gh pr view response carrying the
# head SHA, the base SHA and the rollup together.
_pr_view() {
  printf '{"headRefOid":"%s","baseRefOid":"%s","statusCheckRollup":%s}' \
    "$1" "$MOCK_HEAD_SHA" "$2"
}

_check() { printf '{"name":"%s","status":"%s","conclusion":"%s"}' "$1" "$2" "$3"; }

# ────────────────────────────────────────────────────────────
#  Status mapping
# ────────────────────────────────────────────────────────────

@test "tier0-ci: every check successful is a pass" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" \
    "[$(_check invariants COMPLETED SUCCESS),$(_check offline-tests COMPLETED SUCCESS)]")"
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "pass" ]
}

@test "tier0-ci: one failing check is a fail" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" \
    "[$(_check invariants COMPLETED SUCCESS),$(_check offline-tests COMPLETED FAILURE)]")"
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "fail" ]
}

@test "tier0-ci: a pending check is an error, never a pass" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" \
    "[$(_check invariants COMPLETED SUCCESS),$(_check offline-tests IN_PROGRESS '')]")"
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "error" ]
}

@test "tier0-ci: no checks at all is an error, not a vacuous pass" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[]")"
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "error" ]
}

@test "tier0-ci: a null rollup is an error" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "null")"
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "error" ]
}

@test "tier0-ci: a cancelled or timed-out check is not a pass" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" \
    "[$(_check invariants COMPLETED SUCCESS),$(_check offline-tests COMPLETED CANCELLED)]")"
  run run_review --pr 1
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" != "pass" ]
}

@test "tier0-ci: a neutral or skipped check does not block a pass" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" \
    "[$(_check invariants COMPLETED SUCCESS),$(_check optional COMPLETED SKIPPED)]")"
  run run_review --pr 1
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "pass" ]
}

# ────────────────────────────────────────────────────────────
#  The gate must not run
# ────────────────────────────────────────────────────────────

@test "tier0-ci: the local gate is never executed" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[$(_check invariants COMPLETED SUCCESS)]")"
  run run_review --pr 1
  [ ! -s "$MOCK_GATE_RAN_FILE" ]
}

@test "tier0-ci: a locally failing gate cannot turn a green CI into a fail" {
  # #221 and #217 in one assertion: the reviewer's own environment made the
  # local gate red and the PR was rejected for it. With CI as the source of
  # truth, a broken local gate is irrelevant to Tier 0.
  export MOCK_GATE_STATUS=1
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[$(_check invariants COMPLETED SUCCESS)]")"
  run run_review --pr 1
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "pass" ]
  [ ! -s "$MOCK_GATE_RAN_FILE" ]
}

@test "tier0-ci: the review completes fast enough to prove no gate ran" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[$(_check invariants COMPLETED SUCCESS)]")"
  local started ended
  started="$(date +%s)"
  run run_review --pr 1
  ended="$(date +%s)"
  [ "$(( ended - started ))" -lt 60 ]
}

# ────────────────────────────────────────────────────────────
#  SHA binding and transport failure
# ────────────────────────────────────────────────────────────

@test "tier0-ci: the rollup and the head SHA come from one gh pr view call" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[$(_check invariants COMPLETED SUCCESS)]")"
  run run_review --pr 1
  # Two separate fetches can straddle a push and bind a conclusion to the
  # wrong commit. One response cannot.
  [ "$(grep -c view "$MOCK_GH_VIEW_CALLS" 2>/dev/null || echo 0)" -eq 1 ]
}

@test "tier0-ci: the verdict is bound to the head SHA the rollup came with" {
  export MOCK_PR_VIEW="$(_pr_view "$MOCK_HEAD_SHA" "[$(_check invariants COMPLETED SUCCESS)]")"
  run run_review --pr 1
  [ "$(_field "$(latest_run_dir)/verdict.json" subject_head_sha)" = "$MOCK_HEAD_SHA" ]
}

@test "tier0-ci: gh failure is an error and the run still exits 0" {
  export MOCK_GH_FAIL=1
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" != "pass" ]
}

@test "tier0-ci: an unparseable rollup is an error, not a pass" {
  export MOCK_PR_VIEW='{"headRefOid":"'"$MOCK_HEAD_SHA"'","baseRefOid":"'"$MOCK_HEAD_SHA"'","statusCheckRollup":"not-an-array"}'
  run run_review --pr 1
  [ "$status" -eq 0 ]
  [ "$(_field "$(latest_run_dir)/verdict.json" tasks.tier0)" = "error" ]
}
