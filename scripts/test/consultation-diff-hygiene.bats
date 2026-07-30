#!/usr/bin/env bats
# Consultation diff hygiene — regression guard.
#
# Ensures that no consultation diff artifact contains diff lines that reference
# another consultation diff artifact.  When `git diff main...HEAD` is regenerated
# without the `:(exclude)governance/consultations/*.diff` pathspec, the new
# artifact includes the previous artifact's diff as part of its own diff,
# compounding the size on every regeneration (2047 lines -> 4756 lines in S1).
#
# A reviewer receiving that artifact is handed the old diff twice and the new
# work once.
#
# Current state: this test MAY fail on the existing artifact (PR #107 is under
# review with the stale diff).  The operation to resolve is:
#
#   git diff main...HEAD -- . ':(exclude)governance/consultations/*.diff'
#
# Run it, commit the regenerated artifact, and the guard passes.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "consultation diffs do not contain nested diff references" {
    local offending=0
    for f in "$REPO_ROOT"/governance/consultations/*.diff; do
        [ -f "$f" ] || continue
        if grep -q '^diff --git .*/governance/consultations/.*\.diff' "$f"; then
            echo "FAIL: $f contains lines matching itself — regenerate with exclusion pathspec:" >&2
            echo "  git diff main...HEAD -- . ':(exclude)governance/consultations/*.diff'" >&2
            # Show the offending lines for diagnosis.
            grep -n '^diff --git .*/governance/consultations/.*\.diff' "$f" | head -5 >&2
            offending=1
        fi
    done
    [ "$offending" -eq 0 ]
}
