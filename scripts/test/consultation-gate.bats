#!/usr/bin/env bats
# consultation-gate.bats — Tests for the constitutional consultation artifact gate.
#
# The gate enforces CLAUDE.md → Delegated judgment: any PR whose diff touches
# constitutional files must carry a committed consultation artifact.
#
# Every failure condition has a test that PROVES the gate rejects: construct
# the bad state, assert the gate fails, and assert the message names the
# actual problem.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/consultation-gate.sh"

  # Neutralise the ambient CI environment. GitHub Actions exports
  # GITHUB_EVENT_NAME=pull_request and this workflow exports
  # CONSULTATION_PR_NUMBER to every step, so tests that mean "no event, no PR
  # number" silently inherit real values and assert the wrong branch. That is
  # how these two tests passed locally and failed on CI — the environment was
  # an unstated input. Each test sets what it needs explicitly.
  unset GITHUB_EVENT_NAME CONSULTATION_PR_NUMBER
}

# A realistic-looking synthetic diff with two hunk headers.
VALID_DIFF='diff --git a/CLAUDE.md b/CLAUDE.md
index abc1234..def5678 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -10,4 +10,7 @@ some context line
 unchanged line
+added line
+another added line
 unchanged line
@@ -50,3 +53,5 @@ other context
 old line
-new line
+changed line
still here'

# ---------------------------------------------------------------------------
# Positive: no PR number → silent pass
# ---------------------------------------------------------------------------

@test "consultation-gate: no PR number — silent pass (no-op)" {
  run check_consultation_gate ""
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Positive: empty diff → pass
# ---------------------------------------------------------------------------

@test "consultation-gate: empty diff — pass (no constitutional files touched)" {
  run check_consultation_gate 99 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"no constitutional files touched"* ]]
}

# ---------------------------------------------------------------------------
# Positive: valid APPROVE artifact with matching diff hunks
# ---------------------------------------------------------------------------

@test "consultation-gate: APPROVE artifact with matching diff hunks — pass" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  printf '# Consultation — PR #1\n\n' > governance/consultations/1.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/consultations/1.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/consultations/1.md
  printf 'verdict: APPROVE\n\n' >> governance/consultations/1.md
  printf '## Diff under review\n\n' >> governance/consultations/1.md
  printf '```diff\n' >> governance/consultations/1.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/1.md
  printf '```\n' >> governance/consultations/1.md

  run check_consultation_gate 1 "$VALID_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=APPROVE"* ]]
  [[ "$output" == *"diff hunks verified"* ]]
}

# ---------------------------------------------------------------------------
# Positive: REJECT + second APPROVE artifact — pass
# ---------------------------------------------------------------------------

@test "consultation-gate: REJECT with second APPROVE artifact — pass" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  # Primary: REJECT
  printf '# Consultation — PR #2\n\n' > governance/consultations/2.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/consultations/2.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/consultations/2.md
  printf 'verdict: REJECT\n\n' >> governance/consultations/2.md
  printf '## Diff under review\n\n' >> governance/consultations/2.md
  printf '```diff\n' >> governance/consultations/2.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/2.md
  printf '```\n' >> governance/consultations/2.md

  # Second: APPROVE from third provider
  printf '# Second opinion — PR #2\n\n' > governance/consultations/2-third.md
  printf -- '- **Reviewer:** ThirdBot\n' >> governance/consultations/2-third.md
  printf -- '- **Provider:** ThirdCorp\n\n' >> governance/consultations/2-third.md
  printf 'verdict: APPROVE\n\n' >> governance/consultations/2-third.md
  printf '## Diff under review\n\n' >> governance/consultations/2-third.md
  printf '```diff\n' >> governance/consultations/2-third.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/2-third.md
  printf '```\n' >> governance/consultations/2-third.md

  run check_consultation_gate 2 "$VALID_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"second-approve artifact found"* ]]
}

# ---------------------------------------------------------------------------
# Negative: missing artifact
# ---------------------------------------------------------------------------

@test "consultation-gate: constitutional files touched, no artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  run check_consultation_gate 3 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no consultation artifact"* ]]
  [[ "$output" == *"governance/consultations/3.md"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing reviewer
# ---------------------------------------------------------------------------

@test "consultation-gate: artifact missing reviewer — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/4.md <<'ARTIFACT'
# Consultation — PR #4

- **Provider:** SomeCorp

verdict: APPROVE

```diff
@@ -1,3 +1,4 @@
 test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/CLAUDE.md b/CLAUDE.md
@@ -1,3 +1,4 @@
 test
+add'
  run check_consultation_gate 4 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name a reviewer"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing provider
# ---------------------------------------------------------------------------

@test "consultation-gate: artifact missing provider — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/5.md <<'ARTIFACT'
# Consultation — PR #5

- **Reviewer:** SomeBot

verdict: APPROVE

```diff
@@ -1,3 +1,4 @@
test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/CLAUDE.md b/CLAUDE.md
@@ -1,3 +1,4 @@
test
+add'
  run check_consultation_gate 5 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name a provider"* ]]
}

# ---------------------------------------------------------------------------
# Negative: missing verdict line
# ---------------------------------------------------------------------------

@test "consultation-gate: artifact missing verdict line — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/6.md <<'ARTIFACT'
# Consultation — PR #6

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

This artifact has no verdict line.

```diff
@@ -1,3 +1,4 @@
test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/CLAUDE.md b/CLAUDE.md
@@ -1,3 +1,4 @@
test
+add'
  run check_consultation_gate 6 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
}

# ---------------------------------------------------------------------------
# Negative: verdict line with extra text beyond APPROVE/REJECT
# ---------------------------------------------------------------------------

@test "consultation-gate: verdict line with extra text — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/7.md <<ARTIFACT
# Consultation — PR #7

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE with edits

\`\`\`diff
${VALID_DIFF}
\`\`\`
ARTIFACT

  run check_consultation_gate 7 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing raw diff (hunk headers absent)
# ---------------------------------------------------------------------------

@test "consultation-gate: artifact missing raw diff hunks — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/8.md <<'ARTIFACT'
# Consultation — PR #8

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

The diff looks fine. I reviewed it.
ARTIFACT

  run check_consultation_gate 8 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
  [[ "$output" == *"raw diff"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact mentions filenames, no hunk headers
# ---------------------------------------------------------------------------

@test "consultation-gate: artifact mentions filenames, no hunk headers — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  cat > governance/consultations/9.md <<'ARTIFACT'
# Consultation — PR #9

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

I reviewed the changes to CLAUDE.md and docs/founding-package-v0.2.md.
Everything looks fine.
ARTIFACT

  run check_consultation_gate 9 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
  [[ "$output" == *"raw diff"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT without second APPROVE artifact
# ---------------------------------------------------------------------------

@test "consultation-gate: REJECT without second APPROVE artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  printf '# Consultation — PR #10\n\n' > governance/consultations/10.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/consultations/10.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/consultations/10.md
  printf 'verdict: REJECT\n\n' >> governance/consultations/10.md
  printf '## Diff under review\n\n' >> governance/consultations/10.md
  printf '```diff\n' >> governance/consultations/10.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/10.md
  printf '```\n' >> governance/consultations/10.md

  run check_consultation_gate 10 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT with second artifact that is also REJECT
# ---------------------------------------------------------------------------

@test "consultation-gate: REJECT with second artifact that is also REJECT — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  # Primary: REJECT
  printf '# Consultation — PR #11\n\n' > governance/consultations/11.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/consultations/11.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/consultations/11.md
  printf 'verdict: REJECT\n\n' >> governance/consultations/11.md
  printf '## Diff under review\n\n' >> governance/consultations/11.md
  printf '```diff\n' >> governance/consultations/11.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/11.md
  printf '```\n' >> governance/consultations/11.md

  # Second: also REJECT
  printf '# Second opinion — PR #11\n\n' > governance/consultations/11-third.md
  printf -- '- **Reviewer:** ThirdBot\n' >> governance/consultations/11-third.md
  printf -- '- **Provider:** ThirdCorp\n\n' >> governance/consultations/11-third.md
  printf 'verdict: REJECT\n\n' >> governance/consultations/11-third.md
  printf '## Diff under review\n\n' >> governance/consultations/11-third.md
  printf '```diff\n' >> governance/consultations/11-third.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/11-third.md
  printf '```\n' >> governance/consultations/11-third.md

  run check_consultation_gate 11 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT with second APPROVE missing diff hunks
# ---------------------------------------------------------------------------

@test "consultation-gate: REJECT with second APPROVE missing diff hunks — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/consultations
  # Primary: REJECT with full diff
  printf '# Consultation — PR #12\n\n' > governance/consultations/12.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/consultations/12.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/consultations/12.md
  printf 'verdict: REJECT\n\n' >> governance/consultations/12.md
  printf '## Diff under review\n\n' >> governance/consultations/12.md
  printf '```diff\n' >> governance/consultations/12.md
  printf '%s\n' "$VALID_DIFF" >> governance/consultations/12.md
  printf '```\n' >> governance/consultations/12.md

  # Second: APPROVE but NO diff hunks
  cat > governance/consultations/12-third.md <<'ARTIFACT'
# Second opinion — PR #12

- **Reviewer:** ThirdBot
- **Provider:** ThirdCorp

verdict: APPROVE

Looks good to me.
ARTIFACT

  run check_consultation_gate 12 "$VALID_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: some but not all hunk headers present
# ---------------------------------------------------------------------------

@test "consultation-gate: partial hunk headers — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  TWO_HUNK_DIFF='diff --git a/CLAUDE.md b/CLAUDE.md
index abc1234..def5678 100644
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -10,4 +10,7 @@ first hunk
 unchanged
+added
@@ -50,3 +53,5 @@ second hunk
 old
-new'

  mkdir -p governance/consultations
  # Artifact only contains one of the two hunks
  cat > governance/consultations/13.md <<'ARTIFACT'
# Consultation — PR #13

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

```diff
@@ -10,4 +10,7 @@ first hunk
 unchanged
+added
```
ARTIFACT

  run check_consultation_gate 13 "$TWO_HUNK_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent from the artifact"* ]]
}

# ---------------------------------------------------------------------------
# Positive: PR touching no constitutional file — gate passes
# ---------------------------------------------------------------------------

@test "consultation-gate: PR with no constitutional files in diff — pass" {
  run check_consultation_gate 15 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"no constitutional files touched"* ]]
}

# ===========================================================================
# CI-LIKE CONDITION TESTS — The existing tests all supply a PR number
# explicitly, so the entire class of defect where the gate receives no PR
# number in CI is untested. These tests exercise the conditions the gate
# actually encounters in GitHub Actions: detached HEAD, branch name with no
# digits, CONSULTATION_PR_NUMBER unset on a pull_request event, shallow clone
# without origin/main.
# ===========================================================================

# ---------------------------------------------------------------------------
# Negative: pull_request event with no PR number
# ---------------------------------------------------------------------------

@test "consultation-gate: pull_request event, no PR number — fail" {
  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
  [[ "$output" == *"CONSULTATION_PR_NUMBER is unset"* ]]
}

# ---------------------------------------------------------------------------
# Negative: pull_request event with CONSULTATION_PR_NUMBER empty
# ---------------------------------------------------------------------------

@test "consultation-gate: pull_request event, CONSULTATION_PR_NUMBER empty — fail" {
  CONSULTATION_PR_NUMBER="" GITHUB_EVENT_NAME=pull_request run check_consultation_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
}

# ---------------------------------------------------------------------------
# Negative: detached HEAD on pull_request — fail (branch fallback yields HEAD)
# ---------------------------------------------------------------------------

@test "consultation-gate: detached HEAD on pull_request — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  touch CLAUDE.md
  git add CLAUDE.md
  git commit -m "init" -q
  git checkout --detach -q

  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
}

# ---------------------------------------------------------------------------
# Negative: branch name with no digits on pull_request — fail
# ---------------------------------------------------------------------------

@test "consultation-gate: branch with no digits on pull_request — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  git checkout -b fix/security-patch -q

  GITHUB_EVENT_NAME=pull_request run check_consultation_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
}

# ---------------------------------------------------------------------------
# Negative: shallow clone without origin/main — fail
# ---------------------------------------------------------------------------

@test "consultation-gate: shallow clone without origin/main — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  touch CLAUDE.md
  git add CLAUDE.md
  git commit -m "init" -q

  # No origin remote at all — _consultation_diff will fail.
  # Gate gets a PR number but no diff override, so it must compute the diff.
  run check_consultation_gate 99
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot resolve origin/main"* ]]
  [[ "$output" == *"fetch-depth: 0"* ]]
}

# ---------------------------------------------------------------------------
# Positive: push event (not pull_request), no PR number — silent pass
# ---------------------------------------------------------------------------

@test "consultation-gate: push event, no PR number — silent pass" {
  GITHUB_EVENT_NAME=push run check_consultation_gate ""
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Positive: no GITHUB_EVENT_NAME, no PR number — silent pass (local dev)
# ---------------------------------------------------------------------------

@test "consultation-gate: local dev (no GITHUB_EVENT_NAME), no PR number — silent pass" {
  run check_consultation_gate ""
  [ "$status" -eq 0 ]
}
