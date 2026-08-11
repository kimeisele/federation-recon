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

make_change_diff() {
  local path="$1" kind="${2:-modify}"
  case "$kind" in
    add)
      printf 'diff --git a/%s b/%s\nnew file mode 100644\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1 @@\n+new\n' \
        "$path" "$path" "$path" ;;
    delete)
      printf 'diff --git a/%s b/%s\ndeleted file mode 100644\n--- a/%s\n+++ /dev/null\n@@ -1 +0,0 @@\n-old\n' \
        "$path" "$path" "$path" ;;
    rename)
      printf 'diff --git a/%s b/%s\nsimilarity index 100%%\nrename from %s\nrename to %s\n' \
        "$path" "governance/review-kernel-bootstrap/v2/renamed.json" "$path" \
        'governance/review-kernel-bootstrap/v2/renamed.json' ;;
    copy)
      printf 'diff --git a/%s b/%s\nsimilarity index 100%%\ncopy from %s\ncopy to %s\n' \
        "$path" "governance/review-kernel-bootstrap/v2/copied.json" "$path" \
        'governance/review-kernel-bootstrap/v2/copied.json' ;;
    *) make_diff "$path" ;;
  esac
}

make_manifest_registration_diff() {
  printf 'diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST\n--- a/scripts/test/MANIFEST\n+++ b/scripts/test/MANIFEST\n@@ -40,2 +40,3 @@\n review-runner.bats\n+review-kernel-bootstrap.bats\n review-verdict.bats\n'
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
    governance/adversarial-review.md \
    governance/consultation-prompt.md \
    governance/review-kernel-bootstrap/v2/manifest.json \
    governance/review-kernel-bootstrap/v2/vectors.json \
    governance/review-kernel-bootstrap/v2/expected.json \
    governance/review-kernel-bootstrap/v2/evaluator.py \
    scripts/test/review-kernel-bootstrap.bats \
    .github/workflows/ci.yml \
    docs/example-adr.md \
    governance/reviewers.md \
    scripts/ci-checks.sh \
    scripts/gate.sh \
    scripts/lib/consultation-gate.sh \
    scripts/lib/suite-inventory.sh \
    scripts/test/MANIFEST \
    scripts/test/consultation-gate.bats \
    scripts/review.sh \
    scripts/review-verdict.sh \
    schemas/review-verdict.schema.json \
    governance/owner-decisions/other.md; do
    diff_text="$(make_diff "$path")"
    run check_consultation_gate 2 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "protected path bypassed: $path"
    case "$path" in
      governance/review-kernel-bootstrap/v2/*|scripts/test/review-kernel-bootstrap.bats)
        [[ "$output" == *"Oracle v2"* ]]
        ;;
      *)
        [[ "$output" == *"audit record"* ]]
        ;;
    esac
  done
}

@test "bootstrap PR first-generation exception cannot reopen frozen v2" {
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  harness="$(make_diff scripts/test/review-kernel-bootstrap.bats)"
  manifest="$(make_manifest_registration_diff)"
  diff_text="$(printf '%s\n%s\n%s' "$oracle" "$harness" "$manifest")"
  write_owner_record 52 "$diff_text"
  run check_consultation_gate 52 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Oracle v2"* ]]
}

@test "bootstrap PR exception rejects any additional guard surface" {
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  harness="$(make_diff scripts/test/review-kernel-bootstrap.bats)"
  manifest="$(make_manifest_registration_diff)"
  extra="$(make_diff scripts/test/consultation-gate.bats)"
  diff_text="$(printf '%s\n%s\n%s\n%s' "$oracle" "$harness" "$manifest" "$extra")"
  write_owner_record 53 "$diff_text"
  run check_consultation_gate 53 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
}

@test "oracle paths cannot mix with any candidate guard surface" {
  local guard oracle diff_text
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  for guard in \
    scripts/review.sh \
    scripts/review-verdict.sh \
    schemas/review-verdict.schema.json \
    scripts/lib/consultation-gate.sh \
    scripts/ci-checks.sh \
    scripts/gate.sh; do
    diff_text="$(printf '%s\n%s' "$(make_diff "$guard")" "$oracle")"
    run check_consultation_gate 50 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "candidate/oracle mix bypassed: $guard"
    [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
  done
}

@test "oracle paths cannot mix with any sealing surface" {
  local sealing oracle diff_text
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  for sealing in \
    CLAUDE.md \
    RECOVERY.md \
    docs/recovery-1-contract.md \
    docs/amendments.md \
    .github/workflows/ci.yml \
    scripts/lib/suite-inventory.sh \
    scripts/test/consultation-gate.bats \
    scripts/review.sh \
    scripts/review-verdict.sh \
    schemas/review-verdict.schema.json \
    scripts/lib/consultation-gate.sh \
    scripts/ci-checks.sh \
    scripts/gate.sh; do
    diff_text="$(printf '%s\n%s' "$(make_diff "$sealing")" "$oracle")"
    run check_consultation_gate 54 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "sealing/oracle mix bypassed: $sealing"
    [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
  done
}

@test "oracle plus exact manifest registration is frozen" {
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  exact="$(make_manifest_registration_diff)"
  diff_text="$(printf '%s\n%s' "$oracle" "$exact")"
  write_owner_record 55 "$diff_text"
  run check_consultation_gate 55 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Oracle v2"* ]]

  bad="$(printf '%s\n' \
    'diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST' \
    '--- a/scripts/test/MANIFEST' '+++ b/scripts/test/MANIFEST' \
    '@@ -40,2 +40,2 @@' '-review-runner.bats' '+review-kernel-bootstrap.bats')"
  bad_diff="$(printf '%s\n%s' "$oracle" "$bad")"
  write_owner_record 56 "$bad_diff"
  run check_consultation_gate 56 "$bad_diff" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Oracle v2"* ]]
}

@test "quoted oracle diff headers fail closed" {
  diff_text='diff --git "a/governance/review-kernel-bootstrap/v2/manifest.json" "b/governance/review-kernel-bootstrap/v2/manifest.json"
--- "a/governance/review-kernel-bootstrap/v2/manifest.json"
+++ "b/governance/review-kernel-bootstrap/v2/manifest.json"
@@ -1 +1 @@
-old
+new'
  run check_consultation_gate 57 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"diff header"* ]]
}

@test "ambiguous rename path with an embedded separator fails closed" {
  diff_text='diff --git a/foo b/bar b/scripts/review.sh
similarity index 100%
rename from foo b/bar
rename to scripts/review.sh'
  run check_consultation_gate 58 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"diff header"* ]]
}

@test "oracle rejects README CODEOWNERS unknown and foreign owner paths" {
  local extra oracle diff_text
  oracle="$(make_diff governance/review-kernel-bootstrap/v2/manifest.json)"
  for extra in README.md CODEOWNERS unknown-control.txt governance/owner-decisions/other.md; do
    diff_text="$(printf '%s\n%s' "$oracle" "$(make_diff "$extra")")"
    write_owner_record 59 "$diff_text"
    run check_consultation_gate 59 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "oracle allowed disallowed path: $extra"
    [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
  done
}

@test "oracle/guard anti-mixing covers add, modify, delete, and rename" {
  local kind diff_text
  for kind in add modify delete rename; do
    diff_text="$(printf '%s\n%s' \
      "$(make_change_diff scripts/review-verdict.sh "$kind")" \
      "$(make_change_diff governance/review-kernel-bootstrap/v2/manifest.json "$kind")")"
    run check_consultation_gate 51 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "anti-mixing bypassed for $kind"
    [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
  done
}

@test "frozen v2 paths fail closed for add modify delete rename and copy" {
  local kind diff_text
  for kind in add modify delete rename; do
    diff_text="$(make_change_diff governance/review-kernel-bootstrap/v2/manifest.json "$kind")"
    run check_consultation_gate 60 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "frozen v2 path bypassed for $kind"
    [[ "$output" == *"Oracle v2"* ]]
  done
  diff_text="$(make_change_diff governance/review-kernel-bootstrap/v2/source.json copy)"
  run check_consultation_gate 61 "$diff_text" "$BASE_SHA"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Oracle v2"* ]]
}

@test "frozen harness paths fail closed for every change kind" {
  local kind diff_text
  for kind in add modify delete rename; do
    diff_text="$(make_change_diff scripts/test/review-kernel-bootstrap.bats "$kind")"
    run check_consultation_gate 62 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ] || fail "frozen harness bypassed for $kind"
    [[ "$output" == *"Oracle v2"* ]]
  done
}

@test "deleting or altering the exact MANIFEST registration is frozen" {
  local deletion alteration
  deletion='diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST
--- a/scripts/test/MANIFEST
+++ b/scripts/test/MANIFEST
@@ -40,3 +40,2 @@
 review-runner.bats
-review-kernel-bootstrap.bats
 review-verdict.bats'
  alteration='diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST
--- a/scripts/test/MANIFEST
+++ b/scripts/test/MANIFEST
@@ -40,3 +40,3 @@
 review-runner.bats
-review-kernel-bootstrap.bats
+review-kernel-bootstrap-v3.bats
 review-verdict.bats'
  for diff_text in "$deletion" "$alteration"; do
    write_owner_record 63 "$diff_text"
    run check_consultation_gate 63 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Oracle v2"* ]]
  done
}

@test "MANIFEST registration freeze normalizes CRLF and horizontal whitespace" {
  local crlf whitespace
  crlf="$(printf '%s\n' \
    'diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST' \
    '--- a/scripts/test/MANIFEST' '+++ b/scripts/test/MANIFEST' \
    '@@ -40,1 +40,1 @@' $'-review-kernel-bootstrap.bats\r' $'+review-kernel-bootstrap.bats\r')"
  whitespace="$(printf '%s\n' \
    'diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST' \
    '--- a/scripts/test/MANIFEST' '+++ b/scripts/test/MANIFEST' \
    '@@ -40,1 +40,1 @@' $'-  review-kernel-bootstrap.bats  ' $'+ review-kernel-bootstrap.bats\t')"
  for diff_text in "$crlf" "$whitespace"; do
    write_owner_record 66 "$diff_text"
    run check_consultation_gate 66 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Oracle v2"* ]]
  done
}

@test "MANIFEST registration duplication and reorder are frozen" {
  local duplicate reorder
  duplicate='diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST
--- a/scripts/test/MANIFEST
+++ b/scripts/test/MANIFEST
@@ -40,2 +40,3 @@
 review-runner.bats
 review-kernel-bootstrap.bats
+review-kernel-bootstrap.bats
 review-verdict.bats'
  reorder='diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST
--- a/scripts/test/MANIFEST
+++ b/scripts/test/MANIFEST
@@ -40,3 +40,3 @@
-review-kernel-bootstrap.bats
 review-runner.bats
+review-kernel-bootstrap.bats
 review-verdict.bats'
  for diff_text in "$duplicate" "$reorder"; do
    write_owner_record 67 "$diff_text"
    run check_consultation_gate 67 "$diff_text" "$BASE_SHA"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Oracle v2"* ]]
  done
}

@test "ordinary MANIFEST additions and guard-only changes remain possible" {
  local manifest_diff guard_diff
  manifest_diff='diff --git a/scripts/test/MANIFEST b/scripts/test/MANIFEST
--- a/scripts/test/MANIFEST
+++ b/scripts/test/MANIFEST
@@ -40,3 +40,4 @@
 review-runner.bats
 review-kernel-bootstrap.bats
+ordinary-extra.bats
 review-verdict.bats'
  write_owner_record 64 "$manifest_diff"
  run check_consultation_gate 64 "$manifest_diff" "$BASE_SHA"
  [ "$status" -eq 0 ]

  guard_diff="$(make_diff scripts/lib/consultation-gate.sh)"
  write_owner_record 65 "$guard_diff"
  run check_consultation_gate 65 "$guard_diff" "$BASE_SHA"
  [ "$status" -eq 0 ]
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
  digest="$(git diff --no-ext-diff --binary --find-renames --find-copies --find-copies-harder "$base_sha...HEAD" -- . ':(exclude)governance/owner-decisions/11.md' | shasum -a 256 | awk '{print $1}')"
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

@test "git mode anti-mixing covers add delete rename and copy" {
  local kind repo base_sha
  for kind in add delete rename copy; do
    repo="$WORKDIR/git-$kind"
    mkdir -p "$repo/governance/review-kernel-bootstrap/v2" "$repo/scripts"
    cd "$repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name Test
    printf 'candidate\n' > scripts/review.sh
    printf 'oracle\n' > governance/review-kernel-bootstrap/v2/base.json
    git add .
    git commit -qm baseline
    base_sha="$(git rev-parse HEAD)"
    git update-ref refs/remotes/origin/main "$base_sha"
    case "$kind" in
      add)
        printf 'candidate-new\n' > scripts/review-verdict.sh
        printf 'oracle-new\n' > governance/review-kernel-bootstrap/v2/added.json
        git add . ;;
      delete)
        git rm -q scripts/review.sh governance/review-kernel-bootstrap/v2/base.json ;;
      rename)
        git mv scripts/review.sh scripts/review-verdict.sh
        git mv governance/review-kernel-bootstrap/v2/base.json governance/review-kernel-bootstrap/v2/renamed.json ;;
      copy)
        cp scripts/review.sh governance/review-kernel-bootstrap/v2/copied.txt
        git add governance/review-kernel-bootstrap/v2/copied.txt ;;
    esac
    git commit -qm "$kind"
    run check_consultation_gate "$((100 + ${#kind}))"
    [ "$status" -ne 0 ] || fail "git anti-mixing bypassed for $kind"
    [[ "$output" == *"candidate kernel and bootstrap oracle"* ]]
    cd "$WORKDIR"
  done
}

@test "git mode freezes MANIFEST delete rename and copy by NUL status" {
  local kind repo base_sha digest pr
  for kind in delete rename-to rename-from copy; do
    repo="$WORKDIR/git-manifest-$kind"
    mkdir -p "$repo/scripts/test"
    cd "$repo"
    git init -q
    git config user.email test@example.invalid
    git config user.name Test
    case "$kind" in
      rename-from)
        printf 'review-kernel-bootstrap.bats\nother.bats\n' > scripts/test/OTHER-MANIFEST ;;
      *)
        printf 'review-kernel-bootstrap.bats\nother.bats\n' > scripts/test/MANIFEST ;;
    esac
    git add .
    git commit -qm baseline
    base_sha="$(git rev-parse HEAD)"
    git update-ref refs/remotes/origin/main "$base_sha"
    case "$kind" in
      delete) git rm -q scripts/test/MANIFEST ;;
      rename-to) git mv scripts/test/MANIFEST scripts/test/MANIFEST.old ;;
      rename-from) git mv scripts/test/OTHER-MANIFEST scripts/test/MANIFEST ;;
      copy) cp scripts/test/MANIFEST scripts/test/MANIFEST.copy; git add scripts/test/MANIFEST.copy ;;
    esac
    git commit -qm "$kind"
    pr=$((140 + ${#kind}))
    run check_consultation_gate "$pr"
    [ "$status" -ne 0 ] || fail "MANIFEST $kind bypassed status freeze"
    [[ "$output" == *"Oracle v2"* ]]
    cd "$WORKDIR"
  done
}

@test "git mode permits an unrelated MANIFEST entry with a valid audit record" {
  local repo base_sha digest pr=150
  repo="$WORKDIR/git-manifest-positive"
  mkdir -p "$repo/scripts/test"
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'review-kernel-bootstrap.bats\nother.bats\n' > scripts/test/MANIFEST
  git add .
  git commit -qm baseline
  base_sha="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$base_sha"
  printf 'ordinary-extra.bats\n' >> scripts/test/MANIFEST
  git add scripts/test/MANIFEST
  git commit -qm manifest-entry
  digest="$(git diff --no-ext-diff --binary --find-renames --find-copies --find-copies-harder "$base_sha...HEAD" -- . ':(exclude)governance/owner-decisions/150.md' | shasum -a 256 | awk '{print $1}')"
  mkdir -p governance/owner-decisions
  printf '%s\n' \
    'record_version: 1' \
    'authority: AUDIT_ONLY' \
    'owner: kimeisele' \
    'decision: ADOPT' \
    'decision_date: 2026-08-11' \
    'decision_pr: 150' \
    'decision_scope: review-control audit binding' \
    "base_sha: ${base_sha}" \
    "diff_sha256: ${digest}" > governance/owner-decisions/150.md
  git add governance/owner-decisions/150.md
  git commit -qm owner-record
  run check_consultation_gate "$pr"
  [ "$status" -eq 0 ]
  [[ "$output" == *"matches base SHA and complete PR diff"* ]]
  cd "$WORKDIR"
}

@test "git mode classifies an unprotected filename containing a tab" {
  local repo special
  repo="$WORKDIR/git-tab"
  special=$'notes\t[tab].txt'
  mkdir -p "$repo"
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'baseline\n' > baseline.txt
  git add .
  git commit -qm baseline
  base_sha="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$base_sha"
  printf 'unprotected\n' > "$special"
  git add -- "$special"
  git commit -qm tab-path
  run check_consultation_gate 120
  [ "$status" -eq 0 ]
  [[ "$output" == *"no protected"* ]]
  cd "$WORKDIR"
}

@test "git mode rejects a rename from a path containing b-slash to review.sh" {
  local repo
  repo="$WORKDIR/git-ambiguous-rename"
  mkdir -p "$repo/scripts" "$repo/foo b"
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'review\n' > 'foo b/bar'
  git add .
  git commit -qm baseline
  base_sha="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$base_sha"
  git mv 'foo b/bar' scripts/review.sh
  git commit -qm rename-to-guard
  run check_consultation_gate 121
  [ "$status" -ne 0 ]
  cd "$WORKDIR"
}

@test "git mode anchors every lookup to one captured HEAD SHA" {
  local repo head_calls diff_calls base_sha head_sha range
  repo="$WORKDIR/git-head-anchor"
  head_calls="$WORKDIR/head-calls"
  diff_calls="$WORKDIR/diff-calls"
  mkdir -p "$repo"
  cd "$repo"
  git init -q
  git config user.email test@example.invalid
  git config user.name Test
  printf 'baseline\n' > note.txt
  git add .
  git commit -qm baseline
  base_sha="$(git rev-parse HEAD)"
  git update-ref refs/remotes/origin/main "$base_sha"
  printf 'changed\n' > note.txt
  git commit -qam change
  head_sha="$(git rev-parse HEAD)"
  range="${base_sha}...${head_sha}"

  git() {
    if [ "$1" = "rev-parse" ] && [ "$2" = "HEAD" ]; then
      local calls
      calls="$(wc -l < "$head_calls" 2>/dev/null || true)"
      printf 'head\n' >> "$head_calls"
      if [ "${calls:-0}" -gt 0 ]; then
        printf '%040d\n' 0
        return 0
      fi
    fi
    if [ "$1" = "diff" ]; then
      printf '%s\n' "$*" >> "$diff_calls"
    fi
    command git "$@"
  }

  run check_consultation_gate 122
  unset -f git
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$head_calls")" -eq 1 ]
  [ "$(grep -cF "$range" "$diff_calls")" -eq 3 ]
  ! grep -qF '...HEAD' "$diff_calls"
  cd "$WORKDIR"
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
