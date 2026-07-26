#!/usr/bin/env bash
# consumption-patterns.sh — single source of truth for F-02 detection patterns.
#
# These live in their own file so the production search and its tests read the
# SAME string. The first version of this procedure shipped a pattern written in
# grep BRE syntax (`finding-[0-9a-f]\{12\}`) inside a ripgrep call, where an
# escaped brace matches a literal brace — so it could never match a real Finding
# ID, and `finding_references` was pinned to zero forever. The test written to
# catch that had its own copy of the pattern, so it passed regardless of what
# production did. A test that duplicates the string it is meant to guard is not
# a test.
#
# ripgrep uses Rust regex syntax. Braces are NOT escaped.

# Genuine consumption: another repository cites a specific Finding by ID.
CONSUMPTION_PATTERN_FINDING_ID='finding-[0-9a-f]{12}'

# Weaker evidence: a repository mentions this repository without citing a
# Finding. Counted separately and never summed into the Finding-consumption
# number — F-02 asks whether Findings are consumed, not whether the repository
# is known to exist.
CONSUMPTION_PATTERN_REPO_SLUG='federation-recon'

# ---- Shared search functions ------------------------------------------------
# These are the single source of truth for the rg invocation and classification
# logic. production (consumption-run.sh) and the test suite (consumption.bats)
# both call them so the flags, -e list, --hidden, and -g cannot drift apart.

# search_dir_for_consumption <dir>
# Runs ripgrep with the F-02 detection patterns against the given directory.
# Outputs raw rg matches (one per line: path:line_num:text).
# Returns 0 always — finding nothing is a legitimate result, not an error.
search_dir_for_consumption() {
  local dir="$1"
  rg -n --no-heading --sort path --hidden -g '!.git/' \
    -e "$CONSUMPTION_PATTERN_FINDING_ID" \
    -e "$CONSUMPTION_PATTERN_REPO_SLUG" \
    "$dir" 2>/dev/null || true
}

# classify_consumption_match <match_text>
# Classifies a line of matched text as "finding_id" or "repo_reference".
# finding_id wins when both patterns match the same line (primary signal
# classification must never be downgraded by a co-occurring slug mention).
# Outputs the classification or empty string if neither matches.
classify_consumption_match() {
  local match_text="$1"
  if printf '%s' "$match_text" | rg -q "$CONSUMPTION_PATTERN_FINDING_ID"; then
    printf '%s\n' "finding_id"
  elif printf '%s' "$match_text" | rg -q "$CONSUMPTION_PATTERN_REPO_SLUG"; then
    printf '%s\n' "repo_reference"
  fi
}
