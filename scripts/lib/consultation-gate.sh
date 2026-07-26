#!/usr/bin/env bash
# consultation-gate.sh — Constitutional consultation artifact gate.
#
# Source after helpers.sh. Provides:
#   check_consultation_gate <pr_number> [diff_text]
#
# Enforces CLAUDE.md → Delegated judgment: any PR whose diff touches
# CLAUDE.md, docs/founding-package-v0.2.md, or docs/*-adr.md must carry a
# committed consultation artifact at governance/consultations/<pr>.md.
#
# Exit: 0 if the gate passes, 1 if it fails (with specific messages to stderr).

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics. See #75.

# _consultation_const_files
# Prints the list of constitutional files that exist on disk (one per line).
# Factored out so callers and tests can inspect it.
_consultation_const_files() {
  local f
  for f in "CLAUDE.md" "docs/founding-package-v0.2.md"; do
    [ -f "$f" ] && echo "$f"
  done
  for f in docs/*-adr.md; do
    [ -f "$f" ] && echo "$f"
  done
}

# _consultation_diff <outfile>
# Computes the diff for constitutional files vs origin/main.
# Writes diff to <outfile>. Returns 0 on success, 1 if origin/main cannot
# be resolved (shallow clone, no remote).
# Factored out so callers and tests can inject a synthetic diff.
_consultation_diff() {
  local outfile="$1"
  local const_files
  const_files=()
  while IFS= read -r f; do
    const_files+=("$f")
  done < <(_consultation_const_files)
  git diff "origin/main...HEAD" -- "${const_files[@]}" >"$outfile" 2>/dev/null
}

# check_consultation_gate <pr_number> [diff_text]
#
# <pr_number>  — PR number (required for this check to activate).
#                When omitted or empty the gate is a silent pass — no PR
#                context means the check does not apply (e.g. push to main).
#
# <diff_text>  — optional; when provided, used as the constitutional-files
#                diff instead of running git diff.  Tests use this to supply
#                a synthetic diff without a real git history.
#
# Returns 0 when:
#   - No PR number given (no-op)
#   - No constitutional files are touched by the diff
#   - Constitutional files ARE touched AND a valid consultation artifact exists
# Returns 1 when the gate finds a violation, with a specific message to stderr.
check_consultation_gate() {
  local pr_number="${1:-}"
  local diff_override="${2:-}"

  # No PR context → silent pass (push to main, local dev, not a PR check).
  if [ -z "$pr_number" ]; then
    # On a pull_request event, missing PR number is a CI wiring defect.
    # A guard that skips when it cannot identify its subject is not a guard.
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
      echo "FAIL — consultation gate: running on pull_request event but no PR number available." >&2
      echo "       CONSULTATION_PR_NUMBER is unset. The CI job must set it from" >&2
      echo "       github.event.pull_request.number. A guard that skips when it" >&2
      echo "       cannot identify its subject is not a guard." >&2
      return 1
    fi
    return 0
  fi

  # ---- Determine the diff ----
  local diff_out
  local diff_tmp
  if [ $# -ge 2 ]; then
    diff_out="$diff_override"
  else
    diff_tmp=$(mktemp)
    if _consultation_diff "$diff_tmp"; then
      diff_out=$(cat "$diff_tmp")
      rm -f "$diff_tmp"
    else
      rm -f "$diff_tmp"
      echo "FAIL — consultation gate: cannot resolve origin/main for diff computation." >&2
      echo "       This likely means the clone is shallow (fetch-depth: 1). The CI" >&2
      echo "       job must use fetch-depth: 0 to make origin/main available." >&2
      echo "       A resolution failure must not look like a clean result — that is" >&2
      echo "       the exact defect class documented in docs/operator-lessons.md." >&2
      return 1
    fi
  fi

  if [ -z "$diff_out" ]; then
    echo "OK — consultation gate: no constitutional files touched"
    return 0
  fi

  # ---- Constitutional files touched — require consultation artifact ----
  local artifact="governance/consultations/${pr_number}.md"

  if [ ! -f "$artifact" ]; then
    echo "FAIL — consultation gate: constitutional files modified but" >&2
    echo "       no consultation artifact at ${artifact}" >&2
    echo "       Every PR touching CLAUDE.md, docs/founding-package-v0.2.md," >&2
    echo "       or docs/*-adr.md must carry a committed, verbatim consultation" >&2
    echo "       transcript from an independent cross-provider reviewer." >&2
    echo "       See governance/consultation-prompt.md for the template." >&2
    return 1
  fi

  # ---- Validate the artifact ----

  # 1. Must name a reviewer and a provider.
  local reviewer
  reviewer=$(grep -iE '^\s*(-\s*)?\*\*Reviewer:?\*\*' "$artifact" | head -1 || true)
  local provider
  provider=$(grep -iE '^\s*(-\s*)?\*\*Provider:?\*\*' "$artifact" | head -1 || true)

  if [ -z "$reviewer" ]; then
    echo "FAIL — consultation gate: artifact ${artifact} does not name a reviewer" >&2
    echo "       (expected a line matching '**Reviewer:** ...')" >&2
    return 1
  fi
  if [ -z "$provider" ]; then
    echo "FAIL — consultation gate: artifact ${artifact} does not name a provider" >&2
    echo "       (expected a line matching '**Provider:** ...')" >&2
    return 1
  fi

  # 2. Must contain an exact verdict line.
  local verdict_line
  verdict_line=$(grep -E '^verdict: (APPROVE|REJECT)$' "$artifact" | head -1 || true)

  if [ -z "$verdict_line" ]; then
    echo "FAIL — consultation gate: artifact ${artifact} does not contain" >&2
    echo "       a line matching exactly 'verdict: APPROVE' or 'verdict: REJECT'" >&2
    return 1
  fi

  local verdict
  verdict=$(echo "$verdict_line" | sed 's/^verdict: //')

  # 3. Must contain the RAW DIFF — verify that the diff hunk headers from the
  #    PR's own constitutional-file changes appear verbatim in the artifact.
  #    An artifact that merely mentions filenames proves nothing.
  local hunk_headers
  hunk_headers=$(echo "$diff_out" | grep '^@@ ' || true)

  if [ -z "$hunk_headers" ]; then
    # This shouldn't happen — we already checked diff_out is non-empty,
    # but if there's somehow a diff with no hunk headers, bail.
    echo "FAIL — consultation gate: diff is non-empty but contains no hunk headers" >&2
    return 1
  fi

  local missing_hunks=""
  while IFS= read -r hunk; do
    if ! grep -qF "$hunk" "$artifact"; then
      missing_hunks="${missing_hunks}  ${hunk}"$'\n'
    fi
  done <<< "$hunk_headers"

  if [ -n "$missing_hunks" ]; then
    echo "FAIL — consultation gate: artifact ${artifact} does not contain" >&2
    echo "       the raw diff. The following hunk headers from the PR's own" >&2
    echo "       constitutional-file changes are absent from the artifact:" >&2
    printf '%s' "$missing_hunks" >&2
    echo "       An artifact that merely mentions filenames proves nothing." >&2
    echo "       The consultation prompt MUST include the complete raw diff." >&2
    return 1
  fi

  echo "  OK — consultation artifact ${artifact}: reviewer present, provider present, verdict=${verdict}, diff hunks verified"

  # 4. On REJECT, require a second artifact from a third provider carrying
  #    'verdict: APPROVE' against the same diff.
  if [ "$verdict" = "REJECT" ]; then
    local second_approve_found=false
    local second_artifact
    for second_artifact in governance/consultations/"${pr_number}"-*.md; do
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
      echo "FAIL — consultation gate: primary artifact ${artifact} carries" >&2
      echo "       'verdict: REJECT' but no second artifact from a third" >&2
      echo "       provider was found at governance/consultations/${pr_number}-*.md" >&2
      echo "       carrying 'verdict: APPROVE' against the same diff." >&2
      echo "       A REJECT verdict blocks adoption unless a model from a third" >&2
      echo "       provider approves the identical diff, both transcripts committed." >&2
      return 1
    fi
    echo "  OK — second-approve artifact found: ${second_artifact}"
  fi

  return 0
}
