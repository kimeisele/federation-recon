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

_path_is_bootstrap_oracle_dir() {
  case "$1" in
    governance/review-kernel-bootstrap/*)
      return 0 ;;
    *) return 1 ;;
  esac
}

_path_is_bootstrap_oracle() {
  _path_is_bootstrap_oracle_dir "$1" && return 0
  [ "$1" = "scripts/test/review-kernel-bootstrap.bats" ]
}

_path_is_sealing_guard() {
  case "$1" in
    governance/review-kernel-bootstrap/*|scripts/test/review-kernel-bootstrap.bats|governance/owner-decisions/*.md)
      return 1 ;;
    CLAUDE.md|RECOVERY.md|docs/founding-package-v0.2.md|docs/recovery-1-contract.md|docs/amendments.md|docs/review-pipeline-spec-v0.md|docs/operator-handover.md|governance/adversarial-review.md|governance/consultation-prompt.md|governance/reviewers.md|docs/*-adr.md|.github/workflows/ci.yml|scripts/ci-checks.sh|scripts/gate.sh|scripts/lib/consultation-gate.sh|scripts/lib/suite-inventory.sh|scripts/review.sh|scripts/review-verdict.sh|schemas/review-verdict.schema.json|scripts/test/*.bats)
      return 0 ;;
    *) return 1 ;;
  esac
}

_path_is_review_control() {
  _path_is_bootstrap_oracle "$1" && return 0
  _path_is_sealing_guard "$1" && return 0
  case "$1" in
    scripts/test/MANIFEST|governance/owner-decisions/*.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse every raw-diff header once.  We intentionally reject quoted headers and
# any header containing more than one literal ` b/` separator: a path such as
# `foo b/bar` would otherwise be silently split at the wrong boundary.
_extract_diff_paths() {
  local diff_text="$1" line rest old new
  DIFF_OLD_PATHS=()
  DIFF_NEW_PATHS=()
  while IFS= read -r line; do
    case "$line" in
      diff\ --git\ a\/*)
        rest="${line#diff --git a/}"
        case "$rest" in
          *" b/"*) ;;
          *) return 1 ;;
        esac
        old="${rest%% b/*}"
        new="${rest#* b/}"
        case "$new" in
          *" b/"*) return 1 ;;
        esac
        [ -n "$old" ] && [ -n "$new" ] || return 1
        DIFF_OLD_PATHS+=("$old")
        DIFF_NEW_PATHS+=("$new")
        ;;
      'diff --git "'*) return 1 ;;
      diff\ --git\ *) return 1 ;;
    esac
  done <<< "$diff_text"
  return 0
}

# Git already provides an unambiguous, NUL-delimited path stream.  Use it for
# production classification so valid tabs/spaces in filenames do not make the
# availability gate reject an otherwise unprotected change.
_load_git_diff_paths() {
  local base_sha="$1" head_sha="$2" status old new path status_file
  DIFF_OLD_PATHS=()
  DIFF_NEW_PATHS=()
  status_file=$(mktemp) || return 1
  if ! git diff --no-ext-diff --find-renames --find-copies --find-copies-harder \
      --name-status -z "$base_sha...$head_sha" -- . >"$status_file" 2>/dev/null; then
    rm -f "$status_file"
    return 1
  fi
  while IFS= read -r -d '' status; do
    case "$status" in
      R[0-9]*|C[0-9]*)
        IFS= read -r -d '' old || { rm -f "$status_file"; return 1; }
        IFS= read -r -d '' new || { rm -f "$status_file"; return 1; }
        DIFF_OLD_PATHS+=("$old")
        DIFF_NEW_PATHS+=("$new")
        ;;
      A|D|M|T|U|X|B)
        IFS= read -r -d '' path || { rm -f "$status_file"; return 1; }
        DIFF_OLD_PATHS+=("$path")
        DIFF_NEW_PATHS+=("$path")
        ;;
      *) rm -f "$status_file"; return 1 ;;
    esac
  done <"$status_file"
  rm -f "$status_file"
  return 0
}

# A complete git diff is used for the digest. The only excluded path is the
# current PR's own audit record; all other owner records remain covered.
_write_complete_diff() {
  local base_sha="$1" head_sha="$2" owner_record="$3" outfile="$4"
  git diff --no-ext-diff --binary --find-renames --find-copies --find-copies-harder "$base_sha...$head_sha" -- . ":(exclude)$owner_record" >"$outfile" 2>/dev/null
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

_diff_has_exact_manifest_registration() {
  local diff_text="$1" line in_manifest=0 added=0 removed=0 index=-1
  while IFS= read -r line; do
    case "$line" in
      diff\ --git\ *)
        index=$((index + 1))
        if [ "${DIFF_OLD_PATHS[$index]}" = "scripts/test/MANIFEST" ] || [ "${DIFF_NEW_PATHS[$index]}" = "scripts/test/MANIFEST" ]; then
          in_manifest=1
        else
          in_manifest=0
        fi
        ;;
      +++\ *|---\ *) ;;
      +*)
        [ "$in_manifest" -eq 1 ] || continue
        [ "$line" = "+review-kernel-bootstrap.bats" ] || return 1
        added=$((added + 1))
        ;;
      -*)
        [ "$in_manifest" -eq 1 ] && removed=$((removed + 1))
        ;;
    esac
  done <<< "$diff_text"
  [ "$added" -eq 1 ] && [ "$removed" -eq 0 ]
}

_classify_diff_paths() {
  local index candidate
  DIFF_HAS_ORACLE=0
  DIFF_HAS_SEALING=0
  DIFF_HAS_REVIEW_CONTROL=0
  DIFF_HAS_MANIFEST=0
  for index in "${!DIFF_OLD_PATHS[@]}"; do
    for candidate in "${DIFF_OLD_PATHS[$index]}" "${DIFF_NEW_PATHS[$index]}"; do
      _path_is_bootstrap_oracle "$candidate" && DIFF_HAS_ORACLE=1
      _path_is_sealing_guard "$candidate" && DIFF_HAS_SEALING=1
      _path_is_review_control "$candidate" && DIFF_HAS_REVIEW_CONTROL=1
      [ "$candidate" = "scripts/test/MANIFEST" ] && DIFF_HAS_MANIFEST=1
    done
  done
}

_is_narrow_bootstrap_exception() {
  local pr_number="$1" diff_text="$2" index candidate
  [ "$DIFF_HAS_ORACLE" -eq 1 ] || return 1
  if [ "$DIFF_HAS_MANIFEST" -eq 1 ]; then
    _diff_has_exact_manifest_registration "$diff_text" || return 1
  fi

  for index in "${!DIFF_OLD_PATHS[@]}"; do
    for candidate in "${DIFF_OLD_PATHS[$index]}" "${DIFF_NEW_PATHS[$index]}"; do
      _path_is_bootstrap_oracle "$candidate" && continue
      [ "$candidate" = "scripts/test/MANIFEST" ] && continue
      [ "$candidate" = "$(_owner_record_path "$pr_number")" ] && continue
      return 1
    done
  done
  return 0
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
  local base_sha head_sha diff_text protected_text diff_file protected_file actual_digest artifact synthetic=0

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
    synthetic=1
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
    # Capture HEAD once.  base_sha is the merge-base against origin/main and is
    # the diff anchor; it is not a moving current-base tip.
    head_sha=$(git rev-parse HEAD 2>/dev/null) || {
      echo "FAIL — cannot resolve exact PR head SHA" >&2
      return 1
    }
    if ! printf '%s' "$head_sha" | grep -qE '^[0-9a-f]{40,64}$'; then
      echo "FAIL — resolved PR head SHA is malformed" >&2
      return 1
    fi
    base_sha=$(git merge-base origin/main "$head_sha" 2>/dev/null) || {
      echo "FAIL — cannot resolve exact PR base SHA from origin/main and HEAD" >&2
      return 1
    }
    diff_file=$(mktemp)
    _write_complete_diff "$base_sha" "$head_sha" "$(_owner_record_path "$pr_number")" "$diff_file" || {
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
    git diff --no-ext-diff --binary --find-renames --find-copies --find-copies-harder "$base_sha...$head_sha" -- . >"$protected_file" 2>/dev/null || {
      echo "FAIL — cannot compute protected review-control diff" >&2
      rm -f "$diff_file" "$protected_file"
      return 1
    }
    protected_text=$(cat "$protected_file")
  fi

  if [ "$synthetic" -eq 1 ]; then
    if ! _extract_diff_paths "$protected_text"; then
      echo "FAIL — diff header cannot be classified safely (quoted or ambiguous path)" >&2
      return 1
    fi
  else
    if ! _load_git_diff_paths "$base_sha" "$head_sha"; then
      [ -n "$diff_file" ] && rm -f "$diff_file"
      [ -n "$protected_file" ] && rm -f "$protected_file"
      echo "FAIL — cannot classify complete Git path stream" >&2
      return 1
    fi
  fi
  _classify_diff_paths

  if [ "$DIFF_HAS_ORACLE" -eq 1 ]; then
    if [ "$DIFF_HAS_SEALING" -eq 1 ] || ! _is_narrow_bootstrap_exception "$pr_number" "$protected_text"; then
    [ -n "$diff_file" ] && rm -f "$diff_file"
    [ -n "$protected_file" ] && rm -f "$protected_file"
    echo "FAIL — candidate kernel and bootstrap oracle cannot change in one PR" >&2
    return 1
    fi
  fi

  if [ "$DIFF_HAS_REVIEW_CONTROL" -eq 0 ]; then
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
