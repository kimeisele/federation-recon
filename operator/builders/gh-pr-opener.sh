#!/usr/bin/env bash
# gh-pr-opener.sh — open a DRAFT pull request for a completed run, and nothing
# else.
#
# Invoked as: gh-pr-opener.sh <run_dir>
# Prints the pull request URL on stdout; run.sh measures that, not the exit
# status.
#
# ── This is the first outward-facing act in the pipeline ───────────────────
#
# Everything before it happens inside operator/.runs/ and a detached worktree.
# This creates something other people see, in a repository, with the owner's
# credentials. The limits below are the owner's (2026-08-02) and are checked
# here rather than assumed:
#
#   1. **This repository only.** The slug is read from `gh repo view` and
#      compared literally. A run in a different checkout, or with a different
#      `gh` default, refuses.
#   2. **Draft only.** `--draft` is passed unconditionally and the created PR
#      is read back to confirm `isDraft: true`. A flag that was accepted and
#      ignored is not a limit.
#   3. **Never onto main.** The head branch must not be `main`, and the base
#      must be `main` — a PR from main to main is not a proposal, it is a
#      no-op that looks like one.
#   4. **Never a merge.** This script contains no merge path. That is checked
#      by a canary rather than asserted here, because "the word does not
#      appear in the file" is a property a test can hold and a comment cannot.
#
# Every refusal exits non-zero AND prints nothing on stdout, so a violation
# cannot be mistaken for a reference.
#
# ── What this does NOT establish ───────────────────────────────────────────
#
# That the pull request is any good. It is a draft precisely because nothing
# here has judged the content — the verifier judged the run, and a draft is
# how that distinction is written down where a human will see it.
set -o errexit -o nounset -o pipefail

ALLOWED_REPO="kimeisele/federation-recon"
BASE_BRANCH="main"

RUN_DIR="${1:-}"
if [ -z "$RUN_DIR" ] || [ ! -d "$RUN_DIR" ]; then
  echo "gh-pr-opener: no run directory" >&2
  exit 1
fi

_refuse() {
  echo "gh-pr-opener: REFUSED — $1" >&2
  exit 1
}

command -v gh >/dev/null 2>&1 || _refuse "gh is not installed"

# ---- limit 1: this repository only ------------------------------------------
REPO_SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[ -n "$REPO_SLUG" ] || _refuse "cannot determine the repository"
[ "$REPO_SLUG" = "$ALLOWED_REPO" ] \
  || _refuse "repository is $REPO_SLUG, not $ALLOWED_REPO"

# ---- limit 3: never onto main, always from a branch -------------------------
HEAD_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$HEAD_BRANCH" ] || _refuse "cannot determine the current branch"
[ "$HEAD_BRANCH" != "HEAD" ] \
  || _refuse "detached HEAD — a pull request needs a branch"
[ "$HEAD_BRANCH" != "$BASE_BRANCH" ] \
  || _refuse "head branch is $BASE_BRANCH; a pull request onto itself is not a proposal"

# ---- the run must have been accepted ----------------------------------------
RESULT="$RUN_DIR/result.json"
[ -f "$RESULT" ] || _refuse "no result.json in $RUN_DIR"
VERDICT="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('verdict', ''))" "$RESULT")"
[ "$VERDICT" = "accepted" ] || _refuse "verdict is '$VERDICT', not accepted"

ISSUE="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('issue', ''))" "$RESULT")"
WO_ID="$(python3 -c "
import json, sys
print(json.load(open(sys.argv[1])).get('work_order_id', ''))" "$RESULT")"

# ---- limit 2: draft only ----------------------------------------------------
BODY_FILE="$RUN_DIR/pr_body.md"
{
  printf 'Opened by the Slice 1b execution layer for work order `%s` (issue #%s).\n\n' \
    "$WO_ID" "$ISSUE"
  printf '**Draft, and it stays a draft.** Nothing in the pipeline has judged '
  printf 'whether this change is a good idea — the verifier established that '
  printf 'the run did what the work order said, which is a different claim.\n\n'
  printf 'The run record is at `%s`: `result.json` for the verdict the operator\n' "$RUN_DIR"
  printf 'measured itself, `events.jsonl` for what happened in order, and\n'
  printf '`changes.patch` for the diff as it left the worktree.\n\n'
  printf 'Builder self-report and measured result are both in `result.json`, '
  printf 'under `builder_reported_outcome` and `acceptance_results`. Where they '
  printf 'disagree, `builder_claim_contradicted` says so.\n'
} > "$BODY_FILE"

TITLE="$(python3 -c "
import json, sys
wo = json.load(open(sys.argv[1]))
print('Slice 1b: %s (issue #%s)' % (wo.get('work_order_id'), wo.get('issue')))" "$RESULT")"

PR_URL="$(gh pr create \
  --draft \
  --base "$BASE_BRANCH" \
  --head "$HEAD_BRANCH" \
  --title "$TITLE" \
  --body-file "$BODY_FILE" 2>&1)" || _refuse "creation failed: $PR_URL"

case "$PR_URL" in
  https://github.com/"$ALLOWED_REPO"/pull/*) ;;
  *) _refuse "gh returned something that is not a pull request URL in $ALLOWED_REPO: $PR_URL" ;;
esac

# ---- limit 2, verified rather than requested --------------------------------
IS_DRAFT="$(gh pr view "$PR_URL" --json isDraft -q .isDraft 2>/dev/null || echo unknown)"
[ "$IS_DRAFT" = "true" ] \
  || _refuse "the created pull request is not a draft (isDraft=$IS_DRAFT): $PR_URL"

printf '%s\n' "$PR_URL"
