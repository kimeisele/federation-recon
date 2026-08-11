#!/usr/bin/env bash
# consultation-gate.sh — review-control surface and optional consultation gate.
#
# Source after helpers.sh. Provides:
#   check_consultation_gate <pr_number> [synthetic_diff] [synthetic_base_sha]
#
# The owner record is audit evidence only. It is not authentication and cannot
# prove who supplied it. Actual authority remains the protected manual owner
# merge / external owner instruction; the repository cannot distinguish an
# operator holding an owner token from the owner.
#
# Every change to a conservative review-control surface requires an audit record
# bound to the exact base SHA and SHA-256 of the complete PR diff, excluding only
# that PR's own owner-record file. Optional consultation is supplementary: a
# supplied APPROVE has no authority, while a supplied REJECT blocks this gate.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics.

_owner_record_path() {
  printf 'governance/owner-decisions/%s.md\n' "$1"
}

_path_is_review_control() {
  case "$1" in
    CLAUDE.md|RECOVERY.md|docs/founding-package-v0.2.md|docs/recovery-1-contract.md|docs/amendments.md|docs/review-pipeline-spec-v0.md|docs/operator-handover.md|governance/adversarial-review.md|governance/consultation-prompt.md|governance/reviewers.md|scripts/ci-checks.sh|scripts/gate.sh|scripts/lib/consultation-gate.sh|scripts/review.sh|scripts/review-verdict.sh|schemas/review-verdict.schema.json|docs/*-adr.md|governance/owner-decisions/*.md)
      return 0 ;;
    *) return 1 ;;
  esac
}

# A complete git diff is used for the digest. The only excluded path is the
# current PR's own audit record; all other owner records remain covered.
_write_complete_diff() {
  local base_sha="$1" owner_record="$2" outfile="$3"
  git diff --no-ext-diff --binary "$base_sha...HEAD" -- . ":(exclude)$owner_record" >"$outfile" 2>/dev/null
}

_sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
  else
    return 1
  fi
}

_sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(65536), b""):
        h.update(chunk)
print(h.hexdigest())
PY
  else
    return 1
  fi
}

_diff_has_review_control_path() {
  local diff_text="$1" line path other
  while IFS= read -r line; do
    case "$line" in
      "diff --git a/"*" b/"*)
        path="${line#diff --git a/}"
        other="${path#* b/}"
        path="${path%% b/*}"
        _path_is_review_control "$path" && return 0
        _path_is_review_control "$other" && return 0
        ;;
    esac
  done <<< "$diff_text"
  return 1
}

_check_owner_record() {
  local pr_number="$1" expected_base="$2" actual_digest="$3"
  local artifact version owner decision decision_date decision_pr scope authority base digest
  artifact="$(_owner_record_path "$pr_number")"

  if [ ! -f "$artifact" ]; then
    echo "FAIL — review-control surface requires audit record: ${artifact}" >&2
    return 1
  fi

  version=$(grep -cE '^record_version: 1$' "$artifact" || true)
  authority=$(grep -cE '^authority: AUDIT_ONLY$' "$artifact" || true)
  owner=$(grep -cE '^owner: kimeisele$' "$artifact" || true)
  decision=$(grep -cE '^decision: ADOPT$' "$artifact" || true)
  decision_date=$(grep -cE '^decision_date: [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$artifact" || true)
  decision_pr=$(grep -cE "^decision_pr: ${pr_number}$" "$artifact" || true)
  scope=$(grep -cE '^decision_scope: .+' "$artifact" || true)
  base=$(sed -n 's/^base_sha: //p' "$artifact")
  digest=$(sed -n 's/^diff_sha256: //p' "$artifact")

  if [ "$version" -ne 1 ] || [ "$authority" -ne 1 ] || [ "$owner" -ne 1 ] || [ "$decision" -ne 1 ] \
     || [ "$decision_date" -ne 1 ] || [ "$decision_pr" -ne 1 ] || [ "$scope" -ne 1 ] \
     || ! printf '%s' "$base" | grep -qE '^[0-9a-f]{40,64}$' \
     || ! printf '%s' "$digest" | grep -qE '^[0-9a-f]{64}$'; then
    echo "FAIL — audit record ${artifact} is missing or malformed" >&2
    echo "       owner markdown is evidence only, never authentication" >&2
    return 1
  fi

  if [ "$base" != "$expected_base" ]; then
    echo "FAIL — audit record base_sha does not match the exact PR base" >&2
    return 1
  fi
  if [ "$digest" != "$actual_digest" ]; then
    echo "FAIL — audit record diff_sha256 does not match the recomputed PR diff" >&2
    return 1
  fi

  echo "  OK — audit record matches base SHA and complete PR diff; it grants no authority"
  return 0
}

_validate_consultation() {
  local artifact="$1" diff_text="$2" pr_number="$3" expected_digest="$4"
  local reviewer provider verdict_line verdict hunk_headers missing_hunks hunk
  local digest_line consultation_digest digest_count
  reviewer=$(grep -iE '^\s*(-\s*)?\*\*Reviewer:?\*\*' "$artifact" | head -1 || true)
  provider=$(grep -iE '^\s*(-\s*)?\*\*Provider:?\*\*' "$artifact" | head -1 || true)
  [ -n "$reviewer" ] || { echo "FAIL — consultation ${artifact} has no reviewer" >&2; return 1; }
  [ -n "$provider" ] || { echo "FAIL — consultation ${artifact} has no provider" >&2; return 1; }

  verdict_line=$(grep -E '^verdict: (APPROVE|REJECT)$' "$artifact" | head -1 || true)
  [ -n "$verdict_line" ] || { echo "FAIL — consultation ${artifact} has no exact verdict" >&2; return 1; }
  verdict="${verdict_line#verdict: }"

  digest_count=$(grep -cE '^diff_sha256: [0-9a-f]{64}$' "$artifact" || true)
  if [ "$digest_count" -ne 1 ]; then
    echo "FAIL — consultation ${artifact} needs exactly one diff_sha256: <64hex>" >&2
    return 1
  fi
  digest_line=$(grep -E '^diff_sha256: [0-9a-f]{64}$' "$artifact")
  consultation_digest="${digest_line#diff_sha256: }"
  if [ "$consultation_digest" != "$expected_digest" ]; then
    echo "FAIL — consultation ${artifact} diff_sha256 does not match the recomputed complete PR diff" >&2
    return 1
  fi

  hunk_headers=$(printf '%s\n' "$diff_text" | grep '^@@ ' || true)
  [ -n "$hunk_headers" ] || { echo "FAIL — protected diff has no hunk headers" >&2; return 1; }
  missing_hunks=""
  while IFS= read -r hunk; do
    grep -qF "$hunk" "$artifact" || missing_hunks="${missing_hunks}${hunk}\n"
  done <<< "$hunk_headers"
  if [ -n "$missing_hunks" ]; then
    echo "FAIL — consultation ${artifact} does not contain the complete raw diff" >&2
    return 1
  fi

  if [ "$verdict" = "REJECT" ]; then
    echo "FAIL — supplied consultation ${artifact} is REJECT; optional evidence blocks" >&2
    return 1
  fi
  echo "  OK — optional consultation ${artifact}: APPROVE is non-authoritative"
  return 0
}

# check_consultation_gate <pr_number> [synthetic_diff] [synthetic_base_sha]
check_consultation_gate() {
  local pr_number="${1:-}" diff_override="${2:-}" base_override="${3:-}"
  local base_sha diff_text protected_text diff_file protected_file actual_digest artifact

  if [ -z "$pr_number" ]; then
    if [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ]; then
      echo "FAIL — review-control gate: pull_request event has no PR number" >&2
      return 1
    fi
    return 0
  fi
  if ! printf '%s' "$pr_number" | grep -qE '^[1-9][0-9]*$'; then
    echo "FAIL — review-control gate: malformed PR number" >&2
    return 1
  fi

  diff_file=""
  if [ "$#" -ge 2 ]; then
    # Synthetic diff/base arguments exist only for deterministic unit fixtures;
    # production CI uses the git-derived base and complete diff below.
    diff_text="$diff_override"
    base_sha="$base_override"
    if [ -z "$base_sha" ]; then
      echo "FAIL — synthetic review-control check needs an exact base SHA" >&2
      return 1
    fi
    actual_digest="$(_sha256_text "$diff_text")" || {
      echo "FAIL — cannot compute SHA-256 for synthetic diff" >&2
      return 1
    }
    protected_text="$diff_text"
  else
    base_sha=$(git merge-base origin/main HEAD 2>/dev/null) || {
      echo "FAIL — cannot resolve exact PR base SHA from origin/main and HEAD" >&2
      return 1
    }
    diff_file=$(mktemp)
    _write_complete_diff "$base_sha" "$(_owner_record_path "$pr_number")" "$diff_file" || {
      echo "FAIL — cannot compute complete PR diff from exact base SHA" >&2
      rm -f "$diff_file"
      return 1
    }
    diff_text=$(cat "$diff_file")
    actual_digest="$(_sha256_file "$diff_file")" || {
      echo "FAIL — cannot compute SHA-256 for complete PR diff" >&2
      rm -f "$diff_file"
      return 1
    }
    protected_file=$(mktemp)
    git diff --no-ext-diff --binary "$base_sha...HEAD" -- . >"$protected_file" 2>/dev/null || {
      echo "FAIL — cannot compute protected review-control diff" >&2
      rm -f "$diff_file" "$protected_file"
      return 1
    }
    protected_text=$(cat "$protected_file")
  fi

  if ! _diff_has_review_control_path "$protected_text"; then
    [ -n "$diff_file" ] && rm -f "$diff_file"
    [ -n "$protected_file" ] && rm -f "$protected_file"
    if [ -z "$diff_text" ]; then
      echo "OK — review-control gate: empty PR diff"
    else
      echo "OK — review-control gate: no protected review-control surface touched"
    fi
    return 0
  fi

  _check_owner_record "$pr_number" "$base_sha" "$actual_digest" || {
    [ -n "$diff_file" ] && rm -f "$diff_file"
    [ -n "$protected_file" ] && rm -f "$protected_file"
    return 1
  }
  [ -n "$diff_file" ] && rm -f "$diff_file"
  [ -n "$protected_file" ] && rm -f "$protected_file"

  artifact="governance/consultations/${pr_number}.md"
  if [ ! -f "$artifact" ]; then
    echo "OK — review-control gate: consultation optional; audit record matched"
    return 0
  fi
  _validate_consultation "$artifact" "$diff_text" "$pr_number" "$actual_digest"
}
