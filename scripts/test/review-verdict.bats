#!/usr/bin/env bats
# review-verdict.bats — Deterministic verdict aggregation, tested per rule.
#
# scripts/review-verdict.sh is the one piece of the review pipeline that must
# never contain a surprise: it is a pure function of the verdict JSON and the
# current PR head SHA, with no model, no git, no worktree. These tests pin each
# aggregation rule from docs/review-pipeline-spec-v0.md to a fixture so a
# reordered rule or a softened "not_run" cannot slip through green.
#
# The load-bearing properties under test:
#
#   * PARTIAL is never approval. Unreadable input exits 0 and prints PARTIAL —
#     the script's contract is "print exactly one word, exit 0 always", and an
#     incomplete review stays incomplete rather than being reinterpreted green.
#   * The stored `verdict` field is recomputed, never trusted. A hand-edited
#     verdict line cannot sway the aggregation.
#   * A blocking finding whose verification_status is "rejected" has been
#     examined and refuted; it does not block. Only confirmed, inconclusive,
#     and not_run findings do.
#
# Fully offline. No model calls, no network, no git operations.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/review-verdict.sh"
  FIXTURES="$REPO_ROOT/scripts/test/fixtures/review-verdict"
  HEAD_SHA="abc1234def5678"
}

@test "review-verdict: all tasks healthy, no findings → APPROVE" {
  run bash "$SCRIPT" "$FIXTURES/approve.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "review-verdict: subject head SHA mismatch → STALE" {
  # A verdict for commit abc1234 is never applied to a later commit on the PR.
  run bash "$SCRIPT" "$FIXTURES/stale.json" "deadbeef1234567"
  [ "$status" -eq 0 ]
  [ "$output" = "STALE" ]
}

@test "review-verdict: tier0 fail → REJECT" {
  run bash "$SCRIPT" "$FIXTURES/tier0-fail.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "REJECT" ]
}

@test "review-verdict: tier0 error → PARTIAL" {
  # An errored gate completed nothing; the review is incomplete, not rejected.
  run bash "$SCRIPT" "$FIXTURES/tier0-error.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: blocking finding confirmed → REJECT" {
  run bash "$SCRIPT" "$FIXTURES/blocking-confirmed.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "REJECT" ]
}

@test "review-verdict: blocking finding rejected → APPROVE (resolved)" {
  # verification_status "rejected" means the finding was examined and refuted.
  run bash "$SCRIPT" "$FIXTURES/blocking-rejected.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "APPROVE" ]
}

@test "review-verdict: mandatory task error → PARTIAL" {
  # Tier 1A (review-analysis) errored: a mandatory task that did not complete.
  run bash "$SCRIPT" "$FIXTURES/mandatory-error.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: non-tier0 task fail → PARTIAL, not REJECT" {
  # Only tier0 "fail" is a REJECT. A failed Tier 1 task is incomplete work,
  # and an incomplete review is PARTIAL — never a decision, never approval.
  run bash "$SCRIPT" "$FIXTURES/tier1-fail.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: HIGH risk without tier2 complete → PARTIAL" {
  # Tier 2 is mandatory for HIGH-risk work; a clean LOW PR does not need it.
  run bash "$SCRIPT" "$FIXTURES/high-no-tier2.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: the stored verdict field is recomputed, never trusted" {
  # The fixture's verdict line says APPROVE; the rules say tier0 failed. The
  # deterministic aggregator must win, or a hand-edited verdict sways the gate.
  fixture="$BATS_TEST_TMPDIR/stored-verdict-mismatch.json"
  python3 -c "
import json, sys
v = json.load(open('$FIXTURES/approve.json'))
v['verdict'] = 'APPROVE'
v['tasks']['tier0'] = 'fail'
json.dump(v, open('$fixture', 'w'), indent=2)
"
  run bash "$SCRIPT" "$fixture" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "REJECT" ]
}

@test "review-verdict: unreadable input exits 0 and prints PARTIAL" {
  # "Exit 0 always" is part of the contract; PARTIAL is never approval.
  run bash "$SCRIPT" "$FIXTURES/does-not-exist.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]

  bad="$BATS_TEST_TMPDIR/bad.json"
  printf '{not json' > "$bad"
  run bash "$SCRIPT" "$bad" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: a missing interpreter still exits 0 with PARTIAL" {
  # The contract is "print one word, exit 0 always". A review that cannot
  # even start (no python3) is incomplete, and incomplete stays PARTIAL.
  run env -i PATH=/nonexistent "$BASH" "$SCRIPT" "$FIXTURES/approve.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ "$output" = "PARTIAL" ]
}

@test "review-verdict: every fixture validates against the committed schema" {
  # The schema and the fixtures must not drift apart. Uses the same lightweight
  # structural validator the CI gate runs (scripts/lib/helpers.sh), so this
  # test asserts the repo's own definition of schema compliance.
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  for fixture in "$FIXTURES"/*.json; do
    run validate_json_schema "$fixture" "$REPO_ROOT/schemas/review-verdict.schema.json"
    echo "  $fixture: $output"
    [ "$status" -eq 0 ]
  done
}

@test "review-verdict: output is exactly one word" {
  run bash "$SCRIPT" "$FIXTURES/approve.json" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^(APPROVE|REJECT|PARTIAL|STALE)$ ]]
  [ "$(printf '%s' "$output" | wc -w | tr -d ' ')" = "1" ]
}
