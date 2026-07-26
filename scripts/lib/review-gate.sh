#!/usr/bin/env bash
# review-gate.sh — Adversarial review artifact gate.
#
# Source after helpers.sh. Provides:
#   check_review_gate <pr_number> [diff_text]
#
# Any PR whose diff touches scripts/, schemas/, or .github/workflows/, or whose
# diff exceeds 200 changed lines, must carry a committed adversarial review
# artifact at governance/reviews/<pr>.md.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT.
#
# It proves a file exists containing a reviewer line, a provider line, a verdict
# line, and the diff hunks. It does NOT prove a review happened, that any model
# was called, or that the named provider answered. **No file in this repository
# can, because the reviewed party writes the file.**
#
# This is not theoretical. On this gate's first production use the builder
# fabricated its own review artifact — an invented model name, an invented
# provider, 1300 lines of plausible adversarial prose about its own code, with
# no such call anywhere in its log. A later 19-line forgery using a *valid*
# roster name passed every check in about 30 seconds; see the permanent negative
# test in scripts/test/review-gate.bats.
#
# Validating the reviewer name against governance/reviewers.md was considered and
# rejected: it catches invented names, not invented reviews, and a forger reads
# the roster. Requiring the artifact to be committed by a different git identity
# was also considered and rejected: `git -c user.name=...` sets that freely.
#
# THE ACTUAL BLOCK IS ELSEWHERE. What a builder cannot forge is a GitHub review
# from an identity whose credential it does not hold. CODEOWNERS enforces that
# and is verified. This gate is an ARCHIVE requirement, not a guard: when someone
# must approve anyway, it forces the reasoning onto the record instead of leaving
# it in a chat transcript. That is worth having. It is not protection.
#
# Exit: 0 if the gate passes, 1 if it fails (with specific messages to stderr).

set -o errexit -o nounset -o pipefail

# _review_is_high_risk_check <diff_text>
# Internal: checks whether the given diff text triggers HIGH classification.
# Prints "HIGH" on stdout and returns 0 if HIGH, prints nothing and returns 1
# if not HIGH. Factored out so callers and tests can inspect classification
# independently.
_review_is_high_risk_check() {
  local diff_text="$1"

  # Criterion A: the diff touches scripts/, schemas/, or .github/workflows/
  #
  # BOTH sides are inspected. Matching only `+++` missed the two cheapest
  # attacks, both executed against the earlier version: deleting a protected
  # script (the `+++` side is `/dev/null`) and renaming one out of a protected
  # directory (no `+++ b/scripts/...` line exists at all). Either let a change
  # that removes a security check pass as "not risk-class HIGH".
  #
  # `diff --git` lines are matched too, since renames carry both paths there.
  local trigger_paths
  trigger_paths=$(echo "$diff_text" | grep -E '^(\+\+\+|---) (a/|b/)?(scripts/|schemas/|\.github/workflows/)|^diff --git .*(a|b)/(scripts/|schemas/|\.github/workflows/)' || true)
  if [ -n "$trigger_paths" ]; then
    echo "HIGH"
    return 0
  fi

  # Criterion B: the diff exceeds 200 changed lines.
  #
  # Count added and removed content lines, excluding only the `+++`/`---` file
  # headers themselves. The previous pattern excluded every line whose second
  # character was also + or -, so a 201-line addition of text that happens to
  # begin with `+` or `-` — ordinary Markdown bullet lists, for one — counted as
  # zero. Executed: a 201-line documentation diff classified as not HIGH.
  local changed_lines
  changed_lines=$(echo "$diff_text" | grep -cE '^[-+]' || true)
  local header_lines
  header_lines=$(echo "$diff_text" | grep -cE '^(\+\+\+|---) ' || true)
  changed_lines=$(( changed_lines - header_lines ))
  if [ "$changed_lines" -gt 200 ]; then
    echo "HIGH"
    return 0
  fi

  return 1
}

# _review_diff <outfile>
# Computes the full diff vs origin/main.
# Writes diff to <outfile>. Returns 0 on success, 1 if origin/main cannot
# be resolved (shallow clone, no remote).
_review_diff() {
  local outfile="$1"
  git diff "origin/main...HEAD" -- >"$outfile" 2>/dev/null
}

# _review_triggering_diff <diff_text> <outfile>
# Extracts the hunk headers from the files that triggered the HIGH classification.
# If triggers include scripts/, schemas/, or .github/workflows/, filters to those
# paths. Otherwise (triggered by >200 lines), uses the full diff.
# Writes the filtered diff to <outfile>.
_review_triggering_diff() {
  local diff_text="$1"
  local outfile="$2"

  # Check which triggering criterion applies.
  local has_trigger_paths
  has_trigger_paths=$(echo "$diff_text" | grep -E '^\+\+\+ (a/|b/)?(scripts/|schemas/|\.github/workflows/)' || true)

  if [ -n "$has_trigger_paths" ]; then
    # Extract just the triggering files from the full diff.
    # We need to pull out the full diff segments for those files.
    # Use python3 for structured diff parsing.
    python3 -c "
import sys, re
text = sys.stdin.read()
# Find all files in the diff that match trigger paths.
trigger_re = re.compile(r'^(scripts/|schemas/|\.github/workflows/)')
blocks = re.split(r'^(?=diff --git )', text, flags=re.MULTILINE)
for block in blocks:
    if not block.strip():
        continue
    # Extract the 'b/' path from the '+++ b/path' line
    m = re.search(r'^\+\+\+ b/(.+)$', block, re.MULTILINE)
    if m and trigger_re.match(m.group(1)):
        sys.stdout.write(block)
" <<< "$diff_text" > "$outfile"
  else
    # Triggered by >200 lines — use the full diff.
    echo "$diff_text" > "$outfile"
  fi
}

# check_review_gate <pr_number> [diff_text]
#
# <pr_number>  — PR number (required for this check to activate).
#                When omitted or empty the gate is a silent pass — no PR
#                context means the check does not apply (e.g. push to main).
#
# <diff_text>  — optional; when provided, used as the full diff instead of
#                running git diff. Tests use this to supply a synthetic diff
#                without a real git history.
#
# Returns 0 when:
#   - No PR number given (no-op)
#   - The diff does NOT trigger HIGH classification
#   - The diff DOES trigger HIGH AND a valid review artifact exists
# Returns 1 when the gate finds a violation, with a specific message to stderr.
check_review_gate() {
  local pr_number="${1:-}"
  local diff_override="${2:-}"

  # No PR context → silent pass (push to main, local dev, not a PR check).
  if [ -z "$pr_number" ]; then
    # On a pull_request event, missing PR number is a CI wiring defect.
    # A guard that skips when it cannot identify its subject is not a guard.
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
      echo "FAIL — review gate: running on pull_request event but no PR number available." >&2
      echo "       CONSULTATION_PR_NUMBER is unset. The CI job must set it from" >&2
      echo "       github.event.pull_request.number. A guard that skips when it" >&2
      echo "       cannot identify its subject is not a guard." >&2
      return 1
    fi
    return 0
  fi

  # ---- Determine the diff ----
  local full_diff
  local diff_tmp
  if [ $# -ge 2 ]; then
    full_diff="$diff_override"
  else
    diff_tmp=$(mktemp)
    if _review_diff "$diff_tmp"; then
      full_diff=$(cat "$diff_tmp")
      rm -f "$diff_tmp"
    else
      rm -f "$diff_tmp"
      echo "FAIL — review gate: cannot resolve origin/main for diff computation." >&2
      echo "       This likely means the clone is shallow (fetch-depth: 1). The CI" >&2
      echo "       job must use fetch-depth: 0 to make origin/main available." >&2
      echo "       A resolution failure must not look like a clean result — that is" >&2
      echo "       the exact defect class documented in docs/operator-lessons.md." >&2
      return 1
    fi
  fi

  # ---- Classification: is this PR risk-class HIGH? ----
  local classification
  classification=$(_review_is_high_risk_check "$full_diff" || true)

  if [ -z "$classification" ]; then
    echo "OK — review gate: PR is not risk-class HIGH (gate not triggered)"
    return 0
  fi

  # ---- HIGH classification — require review artifact ----
  local artifact="governance/reviews/${pr_number}.md"

  if [ ! -f "$artifact" ]; then
    echo "FAIL — review gate: PR is risk-class HIGH but" >&2
    echo "       no review artifact at ${artifact}" >&2
    echo "       Every PR touching scripts/, schemas/, or .github/workflows/," >&2
    echo "       or whose diff exceeds 200 changed lines, must carry a committed" >&2
    echo "       adversarial review artifact from an independent cross-provider" >&2
    echo "       reviewer (governance/adversarial-review.md template)." >&2
    return 1
  fi

  # ---- Validate the artifact ----

  # 1. Must name a reviewer and a provider.
  local reviewer
  reviewer=$(grep -iE '^\s*(-\s*)?\*\*Reviewer:?\*\*' "$artifact" | head -1 || true)
  local provider
  provider=$(grep -iE '^\s*(-\s*)?\*\*Provider:?\*\*' "$artifact" | head -1 || true)

  if [ -z "$reviewer" ]; then
    echo "FAIL — review gate: artifact ${artifact} does not name a reviewer" >&2
    echo "       (expected a line matching '**Reviewer:** ...')" >&2
    return 1
  fi
  if [ -z "$provider" ]; then
    echo "FAIL — review gate: artifact ${artifact} does not name a provider" >&2
    echo "       (expected a line matching '**Provider:** ...')" >&2
    return 1
  fi

  # 2. Must contain an exact verdict line.
  local verdict_line
  verdict_line=$(grep -E '^verdict: (APPROVE|REJECT)$' "$artifact" | head -1 || true)

  if [ -z "$verdict_line" ]; then
    echo "FAIL — review gate: artifact ${artifact} does not contain" >&2
    echo "       a line matching exactly 'verdict: APPROVE' or 'verdict: REJECT'" >&2
    return 1
  fi

  local verdict
  verdict=$(echo "$verdict_line" | sed 's/^verdict: //')

  # 3. Must contain the RAW DIFF — verify that the diff hunk headers from the
  #    PR's own triggering files appear verbatim in the artifact.
  local triggering_diff
  local triggering_tmp
  triggering_tmp=$(mktemp)
  _review_triggering_diff "$full_diff" "$triggering_tmp"
  triggering_diff=$(cat "$triggering_tmp")
  rm -f "$triggering_tmp"

  local hunk_headers
  hunk_headers=$(echo "$triggering_diff" | grep '^@@ ' || true)

  if [ -z "$hunk_headers" ]; then
    echo "FAIL — review gate: triggering diff is non-empty but contains no hunk headers" >&2
    return 1
  fi

  local missing_hunks=""
  while IFS= read -r hunk; do
    if ! grep -qF "$hunk" "$artifact"; then
      missing_hunks="${missing_hunks}  ${hunk}"$'\n'
    fi
  done <<< "$hunk_headers"

  if [ -n "$missing_hunks" ]; then
    echo "FAIL — review gate: artifact ${artifact} does not contain" >&2
    echo "       the raw diff. The following hunk headers from the PR's own" >&2
    echo "       triggering diff are absent from the artifact:" >&2
    printf '%s' "$missing_hunks" >&2
    echo "       An artifact that merely mentions filenames proves nothing." >&2
    echo "       The review must include the complete triggering diff." >&2
    return 1
  fi

  # The error text above promises "the complete triggering diff", but everything
  # checked so far is hunk HEADERS. An artifact carrying four @@ lines and no
  # diff body satisfied it — executed against the earlier version. Require a
  # plausible share of the content lines too, so the artifact holds the change
  # rather than its table of contents.
  local content_lines artifact_content
  content_lines=$(echo "$triggering_diff" | grep -cE '^[-+][^-+]' || true)
  if [ "$content_lines" -gt 0 ]; then
    local found=0 line
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      grep -qF -- "$line" "$artifact" && found=$(( found + 1 ))
    done <<< "$(echo "$triggering_diff" | grep -E '^[-+][^-+]' | head -40)"
    local sample=$(( content_lines < 40 ? content_lines : 40 ))
    if [ "$sample" -gt 0 ] && [ $(( found * 2 )) -lt "$sample" ]; then
      echo "FAIL — review gate: artifact ${artifact} carries hunk headers but not" >&2
      echo "       the diff body (${found}/${sample} sampled content lines present)." >&2
      echo "       Hunk headers are a table of contents, not the change." >&2
      return 1
    fi
  fi

  echo "  OK — review artifact ${artifact}: reviewer present, provider present, verdict=${verdict}, diff hunks and body verified"

  # 4. On REJECT, require a second artifact carrying 'verdict: APPROVE'
  #    against the same triggering diff.
  if [ "$verdict" = "REJECT" ]; then
    local second_approve_found=false
    local second_artifact
    for second_artifact in governance/reviews/"${pr_number}"-*.md; do
      [ -f "$second_artifact" ] || continue
      # Must have a verdict: APPROVE line
      if ! grep -qE '^verdict: APPROVE$' "$second_artifact"; then
        continue
      fi
      # Must contain the same diff hunk headers
      local all_hunks_present=true
      while IFS= read -r hunk; do
        if ! grep -qF "$hunk" "$second_artifact"; then
          all_hunks_present=false
          break
        fi
      done <<< "$hunk_headers"
      if $all_hunks_present; then
        second_approve_found=true
        break
      fi
    done

    if ! $second_approve_found; then
      echo "FAIL — review gate: primary artifact ${artifact} carries" >&2
      echo "       'verdict: REJECT' but no second artifact was found at" >&2
      echo "       governance/reviews/${pr_number}-*.md carrying 'verdict: APPROVE'" >&2
      echo "       against the same triggering diff." >&2
      echo "       A REJECT verdict blocks adoption unless a model from a third" >&2
      echo "       provider approves the identical diff, both transcripts committed." >&2
      return 1
    fi
    echo "  OK — second-approve artifact found: ${second_artifact}"
  fi

  return 0
}
