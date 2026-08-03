#!/usr/bin/env bats
# review-runner.bats — the review runner (scripts/review.sh) end to end.
#
# scripts/review.sh orchestrates one review of a PR: resolve the head SHA,
# cut a disposable worktree at that SHA, run the gate in it (Tier 0), record
# the stub tiers, assemble the verdict artifact, and let the deterministic
# aggregator (scripts/review-verdict.sh) recompute the final word. It is
# inert — manually invoked only, no heartbeat wiring — and reads no reviewer
# credential and makes no model call.
#
# These tests drive the REAL review.sh inside a disposable fixture repository
# whose HEAD carries a stand-in gate.sh, so Tier 0 is fast and offline. The
# mock gh returns the fixture's committed HEAD SHA; HOME is pointed at a
# sandbox so verdict artifacts never touch a real review history; TMPDIR is
# pointed at the sandbox so the disposable worktree can be asserted created
# and destroyed. The runner's own constraints under test:
#
#   * verdict artifacts are written OUTSIDE the repository
#   * the disposable worktree is created at the head SHA and destroyed
#   * the deterministic aggregator is called and its word is stored
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

  # Mock gh: the runner only calls `pr view ... --json headRefOid`.
  cat > "$SANDBOX/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ "${MOCK_GH_FAIL:-0}" = "1" ]; then
  echo "mock gh: failing on request" >&2
  exit 1
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '%s\n' "$MOCK_HEAD_SHA"
  exit 0
fi
echo "mock gh: unexpected invocation: $*" >&2
exit 2
GHSCRIPT
  chmod +x "$SANDBOX/mockbin/gh"

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

  # The stubs record their placeholder status in per-phase artifacts.
  [ -f "$run_dir/tier1a.json" ]
  [ -f "$run_dir/tier1b.json" ]
  grep -q '"not_run"' "$run_dir/tier1a.json"
  grep -q '"not_run"' "$run_dir/tier1b.json"
  # No escalation, so Tier 2 did not run and left no artifact.
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
