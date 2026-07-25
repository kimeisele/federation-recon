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
