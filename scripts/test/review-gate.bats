#!/usr/bin/env bats
# review-gate.bats — Tests for the adversarial review artifact gate.
#
# The gate enforces CLAUDE.md → risk class HIGH: any PR whose diff touches
# scripts/, schemas/, or .github/workflows/, or whose diff exceeds 200
# changed lines, must carry a committed adversarial review artifact.
#
# Every failure condition has a test that PROVES the gate rejects: construct
# the bad state, assert the gate fails, and assert the message names the
# actual problem.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/review-gate.sh"

  # Neutralise the ambient CI environment.
  unset GITHUB_EVENT_NAME CONSULTATION_PR_NUMBER
}

# ---------------------------------------------------------------------------
# Synthetic diffs used across tests
# ---------------------------------------------------------------------------

# A diff touching scripts/ — triggers HIGH via criterion A (trigger paths).
SCRIPT_DIFF='diff --git a/scripts/foo.sh b/scripts/foo.sh
index abc1234..def5678 100644
--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -1,3 +1,4 @@
 #!/usr/bin/env bash
 set -e
+echo "new line"
@@ -10,4 +11,5 @@ old stuff
 unchanged
+added
-more old'

# A diff touching only non-trigger paths, under 200 lines — NOT HIGH.
LOW_RISK_DIFF='diff --git a/docs/readme.md b/docs/readme.md
index abc1234..def5678 100644
--- a/docs/readme.md
+++ b/docs/readme.md
@@ -1,3 +1,4 @@
 # Title
+Extra line
@@ -5,2 +6,3 @@
 old
-older
+newer
+another'

# A diff exceeding 200 changed lines — triggers HIGH via criterion B (>200 lines).
# We build it programmatically in the test.

# ---------------------------------------------------------------------------
# Positive: no PR number → silent pass
# ---------------------------------------------------------------------------

@test "review-gate: no PR number — silent pass (no-op)" {
  run check_review_gate ""
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Positive: PR number but empty diff → not HIGH → pass
# ---------------------------------------------------------------------------

@test "review-gate: empty diff — pass (not HIGH)" {
  run check_review_gate 99 ""
  [ "$status" -eq 0 ]
  [[ "$output" == *"not risk-class HIGH"* ]]
}

# ---------------------------------------------------------------------------
# Positive: LOW_RISK_DIFF — not HIGH → pass
# ---------------------------------------------------------------------------

@test "review-gate: non-HIGH PR passes untouched" {
  run check_review_gate 50 "$LOW_RISK_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not risk-class HIGH"* ]]
}

# ---------------------------------------------------------------------------
# Positive: HIGH via trigger paths + valid APPROVE artifact → pass
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (scripts/) with APPROVE artifact — pass" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  printf '# Review — PR #1\n\n' > governance/reviews/1.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/1.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/1.md
  printf 'verdict: APPROVE\n\n' >> governance/reviews/1.md
  printf '## Diff under review\n\n' >> governance/reviews/1.md
  printf '```diff\n' >> governance/reviews/1.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/1.md
  printf '```\n' >> governance/reviews/1.md

  run check_review_gate 1 "$SCRIPT_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=APPROVE"* ]]
  [[ "$output" == *"diff hunks verified"* ]]
}

# ---------------------------------------------------------------------------
# Positive: REJECT + second APPROVE artifact → pass
# ---------------------------------------------------------------------------

@test "review-gate: REJECT with second APPROVE artifact — pass" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  # Primary: REJECT
  printf '# Review — PR #2\n\n' > governance/reviews/2.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/2.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/2.md
  printf 'verdict: REJECT\n\n' >> governance/reviews/2.md
  printf '## Diff under review\n\n' >> governance/reviews/2.md
  printf '```diff\n' >> governance/reviews/2.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/2.md
  printf '```\n' >> governance/reviews/2.md

  # Second: APPROVE from third provider
  printf '# Second opinion — PR #2\n\n' > governance/reviews/2-third.md
  printf -- '- **Reviewer:** ThirdBot\n' >> governance/reviews/2-third.md
  printf -- '- **Provider:** ThirdCorp\n\n' >> governance/reviews/2-third.md
  printf 'verdict: APPROVE\n\n' >> governance/reviews/2-third.md
  printf '## Diff under review\n\n' >> governance/reviews/2-third.md
  printf '```diff\n' >> governance/reviews/2-third.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/2-third.md
  printf '```\n' >> governance/reviews/2-third.md

  run check_review_gate 2 "$SCRIPT_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"second-approve artifact found"* ]]
}

# ---------------------------------------------------------------------------
# Positive: HIGH via >200 lines + APPROVE artifact → pass
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (>200 lines) with APPROVE artifact — pass" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  # Build a diff with >200 changed lines touching only docs/.
  BIG_DIFF="diff --git a/docs/big.md b/docs/big.md
index abc1234..def5678 100644
--- a/docs/big.md
+++ b/docs/big.md
@@ -1,0 +1,202 @@"
  for i in $(seq 1 202); do
    BIG_DIFF="${BIG_DIFF}"$'\n'"+line${i}"
  done

  mkdir -p governance/reviews
  printf '# Review — PR #3\n\n' > governance/reviews/3.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/3.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/3.md
  printf 'verdict: APPROVE\n\n' >> governance/reviews/3.md
  printf '## Diff under review\n\n' >> governance/reviews/3.md
  printf '```diff\n' >> governance/reviews/3.md
  printf '%s\n' "$BIG_DIFF" >> governance/reviews/3.md
  printf '```\n' >> governance/reviews/3.md

  run check_review_gate 3 "$BIG_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=APPROVE"* ]]
}

# ---------------------------------------------------------------------------
# Negative: HIGH, no artifact
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (scripts/) but no artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  run check_review_gate 4 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no review artifact"* ]]
  [[ "$output" == *"governance/reviews/4.md"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing reviewer
# ---------------------------------------------------------------------------

@test "review-gate: artifact missing reviewer — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/5.md <<'ARTIFACT'
# Review — PR #5

- **Provider:** SomeCorp

verdict: APPROVE

```diff
@@ -1,3 +1,4 @@
 test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/scripts/x.sh b/scripts/x.sh
--- a/scripts/x.sh
+++ b/scripts/x.sh
@@ -1,3 +1,4 @@
 test
+add'
  run check_review_gate 5 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name a reviewer"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing provider
# ---------------------------------------------------------------------------

@test "review-gate: artifact missing provider — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/6.md <<'ARTIFACT'
# Review — PR #6

- **Reviewer:** SomeBot

verdict: APPROVE

```diff
@@ -1,3 +1,4 @@
test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/scripts/x.sh b/scripts/x.sh
--- a/scripts/x.sh
+++ b/scripts/x.sh
@@ -1,3 +1,4 @@
test
+add'
  run check_review_gate 6 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not name a provider"* ]]
}

# ---------------------------------------------------------------------------
# Negative: missing verdict line
# ---------------------------------------------------------------------------

@test "review-gate: artifact missing verdict line — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/7.md <<'ARTIFACT'
# Review — PR #7

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

This artifact has no verdict line.

```diff
@@ -1,3 +1,4 @@
test
+add
```
ARTIFACT

  SIMPLE_DIFF='diff --git a/scripts/x.sh b/scripts/x.sh
--- a/scripts/x.sh
+++ b/scripts/x.sh
@@ -1,3 +1,4 @@
test
+add'
  run check_review_gate 7 "$SIMPLE_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
}

# ---------------------------------------------------------------------------
# Negative: verdict line with extra text
# ---------------------------------------------------------------------------

@test "review-gate: verdict line with extra text — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/8.md <<ARTIFACT
# Review — PR #8

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE with conditions

\`\`\`diff
${SCRIPT_DIFF}
\`\`\`
ARTIFACT

  run check_review_gate 8 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact missing raw diff (no hunk headers)
# ---------------------------------------------------------------------------

@test "review-gate: artifact missing raw diff hunks — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/9.md <<'ARTIFACT'
# Review — PR #9

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

The diff looks fine. I reviewed it.
ARTIFACT

  run check_review_gate 9 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
  [[ "$output" == *"raw diff"* ]]
}

# ---------------------------------------------------------------------------
# Negative: artifact mentions filenames, no hunk headers
# ---------------------------------------------------------------------------

@test "review-gate: artifact mentions filenames, no hunk headers — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  cat > governance/reviews/10.md <<'ARTIFACT'
# Review — PR #10

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

I reviewed the changes to scripts/foo.sh and scripts/bar.sh.
Everything looks fine.
ARTIFACT

  run check_review_gate 10 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not contain"* ]]
  [[ "$output" == *"raw diff"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT without second APPROVE artifact
# ---------------------------------------------------------------------------

@test "review-gate: REJECT without second APPROVE artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  printf '# Review — PR #11\n\n' > governance/reviews/11.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/11.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/11.md
  printf 'verdict: REJECT\n\n' >> governance/reviews/11.md
  printf '## Diff under review\n\n' >> governance/reviews/11.md
  printf '```diff\n' >> governance/reviews/11.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/11.md
  printf '```\n' >> governance/reviews/11.md

  run check_review_gate 11 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT with second artifact that is also REJECT
# ---------------------------------------------------------------------------

@test "review-gate: REJECT with second artifact that is also REJECT — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  # Primary: REJECT
  printf '# Review — PR #12\n\n' > governance/reviews/12.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/12.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/12.md
  printf 'verdict: REJECT\n\n' >> governance/reviews/12.md
  printf '## Diff under review\n\n' >> governance/reviews/12.md
  printf '```diff\n' >> governance/reviews/12.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/12.md
  printf '```\n' >> governance/reviews/12.md

  # Second: also REJECT
  printf '# Second opinion — PR #12\n\n' > governance/reviews/12-third.md
  printf -- '- **Reviewer:** ThirdBot\n' >> governance/reviews/12-third.md
  printf -- '- **Provider:** ThirdCorp\n\n' >> governance/reviews/12-third.md
  printf 'verdict: REJECT\n\n' >> governance/reviews/12-third.md
  printf '## Diff under review\n\n' >> governance/reviews/12-third.md
  printf '```diff\n' >> governance/reviews/12-third.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/12-third.md
  printf '```\n' >> governance/reviews/12-third.md

  run check_review_gate 12 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: REJECT with second APPROVE missing diff hunks
# ---------------------------------------------------------------------------

@test "review-gate: REJECT with second APPROVE missing diff hunks — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  mkdir -p governance/reviews
  # Primary: REJECT with full diff
  printf '# Review — PR #13\n\n' > governance/reviews/13.md
  printf -- '- **Reviewer:** TestBot\n' >> governance/reviews/13.md
  printf -- '- **Provider:** TestCorp\n\n' >> governance/reviews/13.md
  printf 'verdict: REJECT\n\n' >> governance/reviews/13.md
  printf '## Diff under review\n\n' >> governance/reviews/13.md
  printf '```diff\n' >> governance/reviews/13.md
  printf '%s\n' "$SCRIPT_DIFF" >> governance/reviews/13.md
  printf '```\n' >> governance/reviews/13.md

  # Second: APPROVE but NO diff hunks
  cat > governance/reviews/13-third.md <<'ARTIFACT'
# Second opinion — PR #13

- **Reviewer:** ThirdBot
- **Provider:** ThirdCorp

verdict: APPROVE

Looks good to me.
ARTIFACT

  run check_review_gate 13 "$SCRIPT_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no second artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: some but not all hunk headers present (partial diff)
# ---------------------------------------------------------------------------

@test "review-gate: partial hunk headers — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  TWO_HUNK_DIFF='diff --git a/scripts/x.sh b/scripts/x.sh
--- a/scripts/x.sh
+++ b/scripts/x.sh
@@ -10,4 +10,7 @@ first hunk
 unchanged
+added
@@ -50,3 +53,5 @@ second hunk
 old
-new'

  mkdir -p governance/reviews
  # Artifact only contains one of the two hunks
  cat > governance/reviews/14.md <<'ARTIFACT'
# Review — PR #14

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

```diff
@@ -10,4 +10,7 @@ first hunk
 unchanged
+added
```
ARTIFACT

  run check_review_gate 14 "$TWO_HUNK_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"absent from the artifact"* ]]
}

# ---------------------------------------------------------------------------
# Negative: HIGH via >200 lines, no artifact
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (>200 lines) but no artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  BIG_DIFF="diff --git a/docs/big.md b/docs/big.md
--- a/docs/big.md
+++ b/docs/big.md
@@ -1,0 +1,202 @@"
  for i in $(seq 1 202); do
    BIG_DIFF="${BIG_DIFF}"$'\n'"+line${i}"
  done

  run check_review_gate 15 "$BIG_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no review artifact"* ]]
  [[ "$output" == *"governance/reviews/15.md"* ]]
}

# ---------------------------------------------------------------------------
# Negative: HIGH via schemas/ path trigger, no artifact
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (schemas/) but no artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  SCHEMA_DIFF='diff --git a/schemas/pin.schema.json b/schemas/pin.schema.json
--- a/schemas/pin.schema.json
+++ b/schemas/pin.schema.json
@@ -1,3 +1,4 @@
 {
+  "new": "field"
 }'

  run check_review_gate 16 "$SCHEMA_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no review artifact"* ]]
  [[ "$output" == *"governance/reviews/16.md"* ]]
}

# ---------------------------------------------------------------------------
# Negative: HIGH via .github/workflows/ path trigger, no artifact
# ---------------------------------------------------------------------------

@test "review-gate: HIGH (.github/workflows/) but no artifact — fail" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  WF_DIFF='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -10,3 +10,4 @@ jobs:
   test:
+    - run: echo hello'

  run check_review_gate 17 "$WF_DIFF"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no review artifact"* ]]
  [[ "$output" == *"governance/reviews/17.md"* ]]
}

# ===========================================================================
# CLASSIFICATION UNIT TESTS — _review_is_high_risk_check
# ===========================================================================

@test "review-gate: _review_is_high_risk_check — scripts/ triggers HIGH" {
  run _review_is_high_risk_check "$SCRIPT_DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — schemas/ triggers HIGH" {
  SCHEMA_DIFF='diff --git a/schemas/x.json b/schemas/x.json
--- a/schemas/x.json
+++ b/schemas/x.json
@@ -1,1 +1,2 @@
-x
+y'
  run _review_is_high_risk_check "$SCHEMA_DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — .github/workflows/ triggers HIGH" {
  WF_DIFF='diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml
--- a/.github/workflows/ci.yml
+++ b/.github/workflows/ci.yml
@@ -1,1 +1,2 @@
-x
+y'
  run _review_is_high_risk_check "$WF_DIFF"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — >200 changed lines triggers HIGH" {
  BIG="diff --git a/docs/big.md b/docs/big.md
--- a/docs/big.md
+++ b/docs/big.md
@@ -1,0 +1,202 @@"
  for i in $(seq 1 202); do
    BIG="${BIG}"$'\n'"+line${i}"
  done
  run _review_is_high_risk_check "$BIG"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — 199 changed lines is NOT HIGH" {
  SMALL="diff --git a/docs/small.md b/docs/small.md
--- a/docs/small.md
+++ b/docs/small.md
@@ -1,0 +1,199 @@"
  for i in $(seq 1 199); do
    SMALL="${SMALL}"$'\n'"+line${i}"
  done
  run _review_is_high_risk_check "$SMALL"
  [ "$status" -ne 0 ]
}

@test "review-gate: _review_is_high_risk_check — exactly 200 lines is NOT HIGH" {
  EXACT200="diff --git a/docs/exact.md b/docs/exact.md
--- a/docs/exact.md
+++ b/docs/exact.md
@@ -1,0 +1,200 @@"
  for i in $(seq 1 200); do
    EXACT200="${EXACT200}"$'\n'"+line${i}"
  done
  run _review_is_high_risk_check "$EXACT200"
  [ "$status" -ne 0 ]
}

@test "review-gate: _review_is_high_risk_check — 201 lines IS HIGH" {
  OVER200="diff --git a/docs/big.md b/docs/big.md
--- a/docs/big.md
+++ b/docs/big.md
@@ -1,0 +1,201 @@"
  for i in $(seq 1 201); do
    OVER200="${OVER200}"$'\n'"+line${i}"
  done
  run _review_is_high_risk_check "$OVER200"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — mixed + and - lines counted correctly" {
  MIXED="diff --git a/docs/mixed.md b/docs/mixed.md
--- a/docs/mixed.md
+++ b/docs/mixed.md
@@ -1,0 +1,102 @@"
  # 102 additions and 101 deletions = 203 changed lines > 200
  for i in $(seq 1 102); do
    MIXED="${MIXED}"$'\n'"+add${i}"
  done
  for i in $(seq 1 101); do
    MIXED="${MIXED}"$'\n'"-del${i}"
  done
  run _review_is_high_risk_check "$MIXED"
  [ "$status" -eq 0 ]
  [ "$output" = "HIGH" ]
}

@test "review-gate: _review_is_high_risk_check — --- and +++ headers not counted" {
  # A diff with exactly 200 change lines but many +++ and --- headers.
  # If headers are miscounted, this would falsely trigger.
  HEADER_HEAVY="diff --git a/docs/a.md b/docs/a.md
--- a/docs/a.md
+++ b/docs/a.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/b.md b/docs/b.md
--- a/docs/b.md
+++ b/docs/b.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/c.md b/docs/c.md
--- a/docs/c.md
+++ b/docs/c.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/d.md b/docs/d.md
--- a/docs/d.md
+++ b/docs/d.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/e.md b/docs/e.md
--- a/docs/e.md
+++ b/docs/e.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/f.md b/docs/f.md
--- a/docs/f.md
+++ b/docs/f.md
@@ -1,1 +1,1 @@
-old
+new
diff --git a/docs/g.md b/docs/g.md
--- a/docs/g.md
+++ b/docs/g.md
@@ -1,1 +1,1 @@
-old
+new"
  # This has 7*2=14 change lines and 7*2=14 header lines. Total 28 non-change lines.
  # Should NOT trigger.
  run _review_is_high_risk_check "$HEADER_HEAVY"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Positive: triggering diff only filters to trigger paths for hunk checking
# ---------------------------------------------------------------------------

@test "review-gate: only trigger-path hunks verified, non-trigger paths ignored" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cd "$WORKDIR"

  # A diff with both scripts/ (trigger) and docs/ (non-trigger) files.
  MIXED_DIFF='diff --git a/docs/readme.md b/docs/readme.md
--- a/docs/readme.md
+++ b/docs/readme.md
@@ -1,1 +1,2 @@
-old
+new
diff --git a/scripts/foo.sh b/scripts/foo.sh
--- a/scripts/foo.sh
+++ b/scripts/foo.sh
@@ -10,4 +10,5 @@ script function
 unchanged
+added'

  mkdir -p governance/reviews
  # Artifact contains ONLY the scripts/ hunk header, not the docs/ one.
  cat > governance/reviews/18.md <<'ARTIFACT'
# Review — PR #18

- **Reviewer:** SomeBot
- **Provider:** SomeCorp

verdict: APPROVE

```diff
@@ -10,4 +10,5 @@ script function
 unchanged
+added
```
ARTIFACT

  run check_review_gate 18 "$MIXED_DIFF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verdict=APPROVE"* ]]
}

# ===========================================================================
# CI-LIKE CONDITION TESTS
# ===========================================================================

# ---------------------------------------------------------------------------
# Negative: pull_request event with no PR number
# ---------------------------------------------------------------------------

@test "review-gate: pull_request event, no PR number — fail" {
  GITHUB_EVENT_NAME=pull_request run check_review_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
  [[ "$output" == *"CONSULTATION_PR_NUMBER is unset"* ]]
}

# ---------------------------------------------------------------------------
# Negative: pull_request event with CONSULTATION_PR_NUMBER empty
# ---------------------------------------------------------------------------

@test "review-gate: pull_request event, CONSULTATION_PR_NUMBER empty — fail" {
  CONSULTATION_PR_NUMBER="" GITHUB_EVENT_NAME=pull_request run check_review_gate ""
  [ "$status" -ne 0 ]
  [[ "$output" == *"no PR number available"* ]]
}

# ---------------------------------------------------------------------------
# Positive: push event (not pull_request), no PR number — silent pass
# ---------------------------------------------------------------------------

@test "review-gate: push event, no PR number — silent pass" {
  GITHUB_EVENT_NAME=push run check_review_gate ""
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Positive: local dev (no GITHUB_EVENT_NAME), no PR number — silent pass
# ---------------------------------------------------------------------------

@test "review-gate: local dev, no GITHUB_EVENT_NAME, no PR number — silent pass" {
  run check_review_gate ""
  [ "$status" -eq 0 ]
}
