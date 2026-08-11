#!/usr/bin/env bats
# Focused oracle tests for the review-control audit gate.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/consultation-gate.sh"
  unset GITHUB_EVENT_NAME CONSULTATION_PR_NUMBER
  BASE_SHA=1111111111111111111111111111111111111111
  WORKDIR="$(mktemp -d)"
  cd "$WORKDIR"
}

teardown() {
  rm -rf "$WORKDIR"
}

make_diff() {
  local path="$1"
  printf 'diff --git a/%s b/%s\n--- a/%s\n+++ b/%s\n@@ -1 +1 @@\n-old\n+new\n' \
    "$path" "$path" "$path" "$path"
}

write_owner_record() {
  local pr="$1" diff_text="$2" base="${3:-$BASE_SHA}"
  local digest
  digest="$(_sha256_text "$diff_text")"
  mkdir -p governance/owner-decisions
  printf '%s\n' \
    '# Audit record — not authentication' \
    'record_version: 1' \
    'authority: AUDIT_ONLY' \
    'owner: kimeisele' \
    'decision: ADOPT' \
    'decision_date: 2026-08-11' \
    "decision_pr: ${pr}" \
    'decision_scope: review-control audit binding' \
    "base_sha: ${base}" \
    "diff_sha256: ${digest}" > "governance/owner-decisions/${pr}.md"
}

write_consultation() {
  local pr="$1" verdict="$2" diff_text="$3"
  local digest
  digest="$(_sha256_text "$diff_text")"
  mkdir -p governance/consultations
  printf '%s\n' \
    "# Consultation — PR #${pr}" \
    '- **Reviewer:** TestBot' \
    '- **Provider:** DeepSeek' \
    "verdict: ${verdict}" \
    "diff_sha256: ${digest}" \
    '```diff' \
    "$diff_text" \
    '```' > "governance/consultations/${pr}.md"
}

@test "no PR context remains a no-op" {
  run check_consultation_gate ""
  [ "$status" -eq 0 ]
}

@test "unprotected diff needs no owner record" {
  diff_text="$(make_diff docs/ordinary-note.md)"
  run check_consultation_gate 1 "$diff_text" "$BASE_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no protected"* ]]
}

@test "every protected surface class requires an audit record" {
  local path diff_text
  for path in \
    CLAUDE.md \
    RECOVERY.md \
    docs/founding-package-v0.2.md \
    docs/recovery-1-contract.md \
    docs/amendments.md \
    docs/review-pipeline-spec-v0.md \
    docs/operator-handover.md \
    governance/consultation-prompt.md \
    docs/example-adr.md \
    governance/reviewers.md \
    scripts/ci-checks.sh \
    scripts/lib/consultation-gate.sh \
    scripts/review.sh \
    scripts/review-verdict.sh \
    schemas/review-verdict.schema.json \
    governance/owner-decisions/other.md; do
    diff_text="$(make_diff "$path")"
    run check_consultation_gate 2 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "protected path bypassed: $path"
    [[ "$output" == *"audit record"* ]]
  done
}

@test "valid audit record is bound to exact base and complete diff" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 3 "$diff_text"
  run check_consultation_gate 3 "$diff_text" "$BASE_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches base SHA and complete PR diff"* ]]
}

@test "missing audit record fails closed" {
  diff_text="$(make_diff CLAUDE.md)"
  run check_consultation_gate 4 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires audit record"* ]]
}

@test "malformed audit record fails closed" {
  diff_text="$(make_diff CLAUDE.md)"
  mkdir -p governance/owner-decisions
  printf 'owner: kimeisele\ndecision: ADOPT\n' > governance/owner-decisions/5.md
  run check_consultation_gate 5 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or malformed"* ]]
}

@test "mutating the diff after recording fails digest binding" {
  original="$(make_diff CLAUDE.md)"
  mutated="$(make_diff CLAUDE.md)\n+tampered"
  write_owner_record 6 "$original"
  run check_consultation_gate 6 "$mutated" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"diff_sha256"* ]]
}

@test "changing the base SHA fails binding" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 7 "$diff_text" "$BASE_SHA"
  run check_consultation_gate 7 "$diff_text" 2222222222222222222222222222222222222222
  [ "$status" -ne 0 ]
  [[ "$output" == *"base_sha"* ]]
}

@test "owner or provider literals alone are not authority" {
  diff_text="$(make_diff CLAUDE.md)"
  mkdir -p governance/owner-decisions governance/consultations
  printf 'owner: kimeisele\nProvider: DeepSeek\ndecision: ADOPT\n' > governance/owner-decisions/8.md
  write_consultation 8 APPROVE "$diff_text"
  run check_consultation_gate 8 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing or malformed"* ]]
}

@test "optional APPROVE passes but has no authority" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 9 "$diff_text"
  write_consultation 9 APPROVE "$diff_text"
  run check_consultation_gate 9 "$diff_text" "$BASE_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPROVE is non-authoritative"* ]]
}

@test "consultation body mutation with unchanged hunks fails digest binding" {
  original="$(make_diff CLAUDE.md)"
  mutated="${original/new/changed-body}"
  write_owner_record 21 "$original"
  # The mutated body keeps every hunk header but its own exact digest changes.
  write_artifact 21 '- **Reviewer:** TestBot' '- **Provider:** DeepSeek' 'verdict: APPROVE' "$mutated"
  run check_consultation_gate 21 "$original" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"diff_sha256"* ]]
}

@test "optional consultation without a diff digest fails closed" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 22 "$diff_text"
  mkdir -p governance/consultations
  printf '%s\n' \
    '# Consultation — PR #22' \
    '- **Reviewer:** TestBot' \
    '- **Provider:** DeepSeek' \
    'verdict: APPROVE' \
    '```diff' \
    "$diff_text" \
    '```' > governance/consultations/22.md
  run check_consultation_gate 22 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs exactly one diff_sha256"* ]]
}

@test "supplied REJECT blocks without a second-provider override" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 10 "$diff_text"
  write_consultation 10 REJECT "$diff_text"
  mkdir -p governance/consultations
  printf 'verdict: APPROVE\n' > governance/consultations/10-second.md
  run check_consultation_gate 10 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"REJECT"* ]]
}

@test "git mode recomputes the exact base and complete diff" {
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'baseline\n' > CLAUDE.md
  git add CLAUDE.md
  git commit -qm baseline
  base_sha="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$base_sha"

  printf 'changed\n' > CLAUDE.md
  git add CLAUDE.md
  git commit -qm change
  digest="$(git diff --no-ext-diff --binary "$base_sha...HEAD" -- . ':(exclude)governance/owner-decisions/11.md' | shasum -a 256 | awk '{print $1}')"
  mkdir -p governance/owner-decisions
  printf '%s\n' \
    'record_version: 1' \
    'authority: AUDIT_ONLY' \
    'owner: kimeisele' \
    'decision: ADOPT' \
    'decision_date: 2026-08-11' \
    'decision_pr: 11' \
    'decision_scope: review-control audit binding' \
    "base_sha: ${base_sha}" \
    "diff_sha256: ${digest}" > governance/owner-decisions/11.md

  run check_consultation_gate 11
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches base SHA and complete PR diff"* ]]
}

# ---------------------------------------------------------------------------
# Structural consultation coverage retained from the original gate suite.
# ---------------------------------------------------------------------------

write_artifact() {
  local pr="$1" reviewer="$2" provider="$3" verdict="$4" body="$5" digest_text="${6:-$body}"
  local digest
  digest="$(_sha256_text "$digest_text")"
  mkdir -p governance/consultations
  printf '# Consultation — PR #%s\n%s\n%s\n%s\n%s\n' \
    "$pr" "$reviewer" "$provider" "$verdict" "$body" > "governance/consultations/${pr}.md"
  printf 'diff_sha256: %s\n' "$digest" >> "governance/consultations/${pr}.md"
}

@test "optional artifact missing reviewer is rejected" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 12 "$diff_text"
  write_artifact 12 '' '- **Provider:** TestCorp' 'verdict: APPROVE' "$diff_text" "$diff_text"
  run check_consultation_gate 12 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no reviewer"* ]]
}

@test "optional artifact missing provider is rejected" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 13 "$diff_text"
  write_artifact 13 '- **Reviewer:** TestBot' '' 'verdict: APPROVE' "$diff_text" "$diff_text"
  run check_consultation_gate 13 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no provider"* ]]
}

@test "optional artifact missing verdict is rejected" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 14 "$diff_text"
  write_artifact 14 '- **Reviewer:** TestBot' '- **Provider:** TestCorp' '' "$diff_text" "$diff_text"
  run check_consultation_gate 14 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no exact verdict"* ]]
}

@test "optional artifact extra-text verdict is rejected" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 15 "$diff_text"
  write_artifact 15 '- **Reviewer:** TestBot' '- **Provider:** TestCorp' 'verdict: APPROVE with edits' "$diff_text" "$diff_text"
  run check_consultation_gate 15 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no exact verdict"* ]]
}

@test "optional artifact missing raw diff is rejected" {
  diff_text="$(make_diff CLAUDE.md)"
  write_owner_record 16 "$diff_text"
  write_artifact 16 '- **Reviewer:** TestBot' '- **Provider:** TestCorp' 'verdict: APPROVE' 'I reviewed the file name only.' "$diff_text"
  run check_consultation_gate 16 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"complete raw diff"* ]]
}

@test "filename-only artifact with a no-hunk diff is rejected" {
  diff_text='diff --git a/CLAUDE.md b/CLAUDE.md'
  write_owner_record 17 "$diff_text"
  write_artifact 17 '- **Reviewer:** TestBot' '- **Provider:** TestCorp' 'verdict: APPROVE' 'CLAUDE.md was reviewed.' "$diff_text"
  run check_consultation_gate 17 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no hunk headers"* ]]
}

@test "optional artifact with partial hunk coverage is rejected" {
  diff_text='diff --git a/CLAUDE.md b/CLAUDE.md
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -1 +1 @@
-old
+new
@@ -9 +9 @@
-old2
+new2'
  write_owner_record 18 "$diff_text"
  partial='@@ -1 +1 @@
-old
+new'
  write_artifact 18 '- **Reviewer:** TestBot' '- **Provider:** TestCorp' 'verdict: APPROVE' "$partial" "$diff_text"
  run check_consultation_gate 18 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"complete raw diff"* ]]
}

@test "malformed PR number fails closed" {
  diff_text="$(make_diff CLAUDE.md)"
  run check_consultation_gate 'not-a-pr' "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"malformed PR number"* ]]
}

@test "pull_request event without PR number fails closed" {
  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number"* ]]
}

@test "pull_request event with empty consultation number fails closed" {
  CONSULTATION_PR_NUMBER='' GITHUB_EVENT_NAME=pull_request run check_consultation_gate ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number"* ]]
}

@test "detached pull_request context still fails without subject identity" {
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  touch CLAUDE.md
  git add CLAUDE.md
  git commit -qm init
  git checkout --detach -q
  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number"* ]]
}

@test "branch without a numeric PR cannot silently run in pull_request context" {
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  git checkout -qb fix/security-patch
  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ''
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number"* ]]
}

@test "git resolution without origin/main fails closed" {
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  touch CLAUDE.md
  git add CLAUDE.md
  git commit -qm init
  run check_consultation_gate 19
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve exact PR base SHA"* ]]
}

@test "push context without a PR number remains a no-op" {
  GITHUB_EVENT_NAME=push run check_consultation_gate ''
  [ "$status" -eq 0 ]
}

@test "explicit empty diff remains a pass" {
  run check_consultation_gate 20 '' "$BASE_SHA"
  [ "$status" -eq 0 ]
  [[ "$output" == *"empty PR diff"* ]]
}
