#!/usr/bin/env bash
# pin-gate.sh — Pin validation gate: "are these pins correct?"
#
# The reproduce fixpoint answers "are these artifacts reproducible from these
# pins?" It does not answer "are these pins correct?" This gate answers the
# second question with four predicates: membership, reachability, monotonicity,
# and bounded change.
#
# Source after manifest-gate.sh (which provides _manifest_adopted_slugs and
# check_pin_manifest_membership).  Provides:
#   check_pin_validity <pins_glob> <manifest_path> [previous_pins_dir]
#
# Exit: 0 green (all predicates pass)
#       1 red  (one or more predicates fail)
#       2 unknown (network-dependent check could not run — gh unavailable)
#
# Diagnostics go to stderr.  Every failure names the pin file, the predicate,
# and the observed value so a reviewer can act without opening the pin.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics. See #75.

# ---- Predicate 1: Membership ------------------------------------------------
# Reuses check_pin_manifest_membership from manifest-gate.sh.
# Pins whose repository slug is not in the manifest's adopted observed set fail.

# ---- Predicate 2: Reachability ----------------------------------------------
# _check_reachability <pin_file> <repo> <ref> <sha>
# Verifies resolved_commit_sha is reachable from requested_ref on the real repo.
# Calls: gh api repos/<repo>/compare/<ref>...<sha>
# Requires status "identical" or "behind".
# Returns 0 pass, 1 fail, 2 unknown (network unavailable).
_check_reachability() {
  local pin_file="$1" repo="$2" ref="$3" sha="$4"

  if ! command -v gh &>/dev/null; then
    echo "UNKNOWN — reachability: ${pin_file}: gh not available (cannot compare ${ref}...${sha})" >&2
    return 2
  fi

  local result
  result=$(gh api "repos/${repo}/compare/${ref}...${sha}" --jq '.status' 2>&1) || {
    # Distinguish HTTP 404 from transport/network errors.
    if echo "$result" | grep -qiE '(404|not found)'; then
      echo "FAIL — reachability: ${pin_file}: commit ${sha} is not reachable from ref ${ref} on ${repo} (HTTP 404 — commit does not exist in repository)" >&2
      return 1
    fi
    echo "UNKNOWN — reachability: ${pin_file}: cannot compare ${ref}...${sha} (network unavailable)" >&2
    return 2
  }

  if [ "$result" = "identical" ] || [ "$result" = "behind" ]; then
    return 0
  fi

  echo "FAIL — reachability: ${pin_file}: resolved_commit_sha ${sha} is not reachable from ref ${ref} (gh compare status: ${result})" >&2
  return 1
}

# ---- Predicate 3: Monotonicity ----------------------------------------------
# _check_monotonicity <pin_file> <repo> <new_sha> <old_sha>
# Verifies the new sha is the same as or a descendant of the old sha.
# Calls: gh api repos/<repo>/compare/<old_sha>...<new_sha>
# Requires status "identical" or "ahead".
# Returns 0 pass, 1 fail, 2 unknown (network unavailable).
_check_monotonicity() {
  local pin_file="$1" repo="$2" new_sha="$3" old_sha="$4"

  if ! command -v gh &>/dev/null; then
    echo "UNKNOWN — monotonicity: ${pin_file}: gh not available (cannot compare ${old_sha}...${new_sha})" >&2
    return 2
  fi

  local result
  result=$(gh api "repos/${repo}/compare/${old_sha}...${new_sha}" --jq '.status' 2>&1) || {
    # Distinguish HTTP 404 from transport/network errors.
    if echo "$result" | grep -qiE '(404|not found)'; then
      echo "FAIL — monotonicity: ${pin_file}: commit ${old_sha} → ${new_sha} comparison failed (HTTP 404 — one or both commits do not exist in repository)" >&2
      return 1
    fi
    echo "UNKNOWN — monotonicity: ${pin_file}: cannot compare ${old_sha}...${new_sha} (network unavailable)" >&2
    return 2
  }

  if [ "$result" = "identical" ] || [ "$result" = "ahead" ]; then
    return 0
  fi

  echo "FAIL — monotonicity: ${pin_file}: moved backwards from ${old_sha} to ${new_sha} (gh compare status: ${result})" >&2
  return 1
}

# ---- Predicate 4: Bounded change --------------------------------------------
# _check_bounded_change <pins_glob> <manifest_path> <previous_pins_dir>
# Reports the number of pins whose sha changed and validates that no pin files
# were added or removed unless the manifest changed in the same diff.
# Returns 0 pass, 1 fail (pins added/removed without manifest change).
_check_bounded_change() {
  local pins_glob="$1" manifest_path="$2" previous_pins_dir="$3"
  local changed=0 total=0 fail_flag=0
  local added="" removed=""

  # Use associative arrays for sha lookups by slug.
  # bash 4+ required; declare -A is available on macOS (bash 3 users must upgrade).
  local -A cur_sha_of=()
  local -A prev_sha_of=()
  local -a cur_slugs=()
  local -a prev_slugs=()
  local f slug sha
  for f in $pins_glob; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .json)"
    sha="$(jq -r '.resolved_commit_sha // empty' "$f" 2>/dev/null || true)"
    cur_slugs+=("$slug")
    cur_sha_of["${slug}"]="$sha"
    total=$((total + 1))
  done

  # Get previous pin slugs.
  for f in "${previous_pins_dir}"/*.json; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .json)"
    sha="$(jq -r '.resolved_commit_sha // empty' "$f" 2>/dev/null || true)"
    prev_slugs+=("$slug")
    prev_sha_of["${slug}"]="$sha"
  done

  # Count how many pins changed sha.
  local s
  for s in "${cur_slugs[@]}"; do
    local prev_sha="${prev_sha_of[$s]:-}"
    local cur_sha="${cur_sha_of[$s]:-}"
    if [ -n "$prev_sha" ] && [ -n "$cur_sha" ] && [ "$prev_sha" != "$cur_sha" ]; then
      changed=$((changed + 1))
    fi
  done

  echo "  Report — changed pins: ${changed}/${total}" >&2

  # Detect added/removed pin files.
  local tmp_cur tmp_prev
  tmp_cur="$(mktemp)" && tmp_prev="$(mktemp)"
  {
    for s in "${cur_slugs[@]}"; do echo "$s"; done
  } | sort > "$tmp_cur"
  {
    for s in "${prev_slugs[@]}"; do echo "$s"; done
  } | sort > "$tmp_prev"

  added="$(comm -13 "$tmp_prev" "$tmp_cur")"
  removed="$(comm -23 "$tmp_prev" "$tmp_cur")"
  rm -f "$tmp_cur" "$tmp_prev"

  if [ -z "$added" ] && [ -z "$removed" ]; then
    return 0
  fi

  # Pin files added or removed — check whether the manifest changed in the same diff.
  # Run git from the manifest's directory so the check works regardless of CWD.
  local manifest_changed=false
  local manifest_dir manifest_file
  manifest_dir="$(cd "$(dirname "$manifest_path")" && pwd 2>/dev/null || echo "")"
  manifest_file="$(basename "$manifest_path")"
  if [ -n "$manifest_dir" ]; then
    # manifest_changed=true only when a real diff exists against HEAD.
    # If git fails (no HEAD, not a repo, untracked file), it produces no
    # output → manifest_changed stays false → added pins fail (conservative).
    if git -C "$manifest_dir" diff HEAD -- "$manifest_file" 2>/dev/null | grep -q .; then
      manifest_changed=true
    fi
  fi

  if $manifest_changed; then
    # Manifest changed — allow but still report.
    if [ -n "$added" ]; then
      echo "  Note — bounded change: pin files added (manifest also changed): $(echo "$added" | tr '\n' ' ')" >&2
    fi
    if [ -n "$removed" ]; then
      echo "  Note — bounded change: pin files removed (manifest also changed): $(echo "$removed" | tr '\n' ' ')" >&2
    fi
    return 0
  fi

  # Manifest did NOT change — pin drift is a failure.
  if [ -n "$added" ]; then
    local added_list
    added_list=""
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      added_list="${added_list}${s}.json "
    done <<< "$added"
    echo "FAIL — bounded change: pin file(s) added without manifest change: ${added_list}" >&2
    fail_flag=1
  fi
  if [ -n "$removed" ]; then
    local removed_list
    removed_list=""
    while IFS= read -r s; do
      [ -z "$s" ] && continue
      removed_list="${removed_list}${s}.json "
    done <<< "$removed"
    echo "FAIL — bounded change: pin file(s) removed without manifest change: ${removed_list}" >&2
    fail_flag=1
  fi

  return "$fail_flag"
}

# ---- Main gate --------------------------------------------------------------
# check_pin_validity <pins_glob> <manifest_path> [previous_pins_dir]
#
# Evaluates all four predicates.  Returns 0 when all pass, 1 when any fail,
# 2 when a network-dependent predicate cannot run (gh unavailable).
check_pin_validity() {
  local pins_glob="$1"
  local manifest_path="$2"
  local previous_pins_dir="${3:-}"

  local fail=0
  local unknown=0
  local total_pins=0

  # ---- Predicate 1: Membership ----
  if ! check_pin_manifest_membership "$manifest_path" "$pins_glob"; then
    fail=1
  fi

  # Count pins for the report.
  for f in $pins_glob; do
    [ -f "$f" ] || continue
    total_pins=$((total_pins + 1))
  done

  # ---- Iterate pins for reachability and monotonicity ----
  local pin_file slug repo ref sha
  for pin_file in $pins_glob; do
    [ -f "$pin_file" ] || continue

    slug="$(basename "$pin_file" .json)"
    repo="kimeisele/${slug}"
    ref="$(jq -r '.requested_ref // "main"' "$pin_file" 2>/dev/null || echo "main")"
    sha="$(jq -r '.resolved_commit_sha // empty' "$pin_file" 2>/dev/null || true)"

    [ -z "$sha" ] && continue

    # ---- Predicate 2: Reachability ----
    _check_reachability "$pin_file" "$repo" "$ref" "$sha"
    case $? in
      1) fail=1 ;;
      2) unknown=1 ;;
    esac

    # ---- Predicate 3: Monotonicity ----
    local prev_sha=""
    if [ -n "$previous_pins_dir" ]; then
      local prev_pin="${previous_pins_dir}/${slug}.json"
      if [ -f "$prev_pin" ]; then
        prev_sha="$(jq -r '.resolved_commit_sha // empty' "$prev_pin" 2>/dev/null || true)"
      fi
    else
      # No explicit previous_pins_dir — read the previous version of this pin
      # from git history.  In CI the base ref is what matters (PR target branch);
      # fall back to HEAD locally.
      local base_ref="${BASE_REF:-origin/main}"
      # pin_file may be relative (e.g. "pins/v1-census/steward.json") or
      # absolute.  Git requires paths relative to the repo root after the colon,
      # so resolve the repo root and strip the prefix.
      local repo_root git_content=""
      repo_root=$(git -C "$(dirname "$pin_file")" rev-parse --show-toplevel 2>/dev/null || true)
      if [ -n "$repo_root" ]; then
        local abs_pin relative_path
        abs_pin="$(cd -P "$(dirname "$pin_file")" && pwd)/$(basename "$pin_file")"
        relative_path="${abs_pin#"${repo_root}/"}"
        if [ "$relative_path" != "$abs_pin" ]; then
          git_content=$(git -C "$repo_root" show "${base_ref}:${relative_path}" 2>/dev/null) || \
            git_content=$(git -C "$repo_root" show "HEAD:${relative_path}" 2>/dev/null) || true
        fi
      fi
      if [ -n "$git_content" ]; then
        prev_sha=$(echo "$git_content" | jq -r '.resolved_commit_sha // empty' 2>/dev/null || true)
      fi
    fi

    if [ -n "$prev_sha" ] && [ "$prev_sha" != "$sha" ]; then
      _check_monotonicity "$pin_file" "$repo" "$sha" "$prev_sha"
      case $? in
        1) fail=1 ;;
        2) unknown=1 ;;
      esac
    fi
  done

  # ---- Predicate 4: Bounded change ----
  if [ -n "$previous_pins_dir" ] && [ -d "$previous_pins_dir" ]; then
    _check_bounded_change "$pins_glob" "$manifest_path" "$previous_pins_dir"
    case $? in
      1) fail=1 ;;
      2) unknown=1 ;;
    esac
  fi

  # UNKNOWN takes precedence: a check that could not run must not look like green.
  if [ "$unknown" -gt 0 ]; then
    return 2
  fi
  return "$fail"
}
