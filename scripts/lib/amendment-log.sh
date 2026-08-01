#!/usr/bin/env bash
# amendment-log.sh — an accepted ADR must appear in the amendment log.
#
# Source it, then call:
#   check_amendment_log [docs_dir] [log_path]
#
# Exit: 0 every accepted ADR is recorded, 1 at least one is not,
#       2 the check could not run (no ADRs found, log missing).
#
# ── Why this exists ────────────────────────────────────────────────────────
#
# docs/amendments.md declares, in its own second sentence, that it holds "one
# line per adopted change to CLAUDE.md, docs/founding-package-v0.2.md, or an
# accepted ADR". On 2026-08-01 it held exactly one line, and
# docs/execution-core-adr.md had read `Status: Accepted` since 2026-07-30 —
# the largest change of direction since founding, absent from the one
# mechanism that exists to make such changes countable.
#
# Nothing was hidden. The ADR is committed, reviewed four rounds by a second
# provider, and its PR is public. What failed is that the log has to be
# remembered, and a log that has to be remembered records only the changes
# made by people who remember. That is not a discipline problem to be solved
# by resolving harder; it is a missing check.
#
# ── What this establishes, and what it does not ────────────────────────────
#
# Establishes: no file under docs/ can reach `Status: Accepted` while being
# absent from the log. That is the specific failure that occurred.
#
# Does NOT establish:
#   - that the recorded line is true, or describes the ADR honestly. A line
#     reading "| 9 | … | nothing much |" satisfies this check. The log's
#     purpose is to make drift *countable*, and a wrong entry is still a
#     count; an absent entry is not.
#   - that the amendment was validly adopted. Amendment 1 is recorded here
#     and was not (#55). Recording and legitimacy are different things and
#     this check speaks only to the first.
#   - that constitutional change outside an ADR is caught. CLAUDE.md and the
#     founding package can still be edited without a line. Extending this to
#     them means deciding which edits are constitutional, which is a judgment
#     call, and a judgment call is not what belongs in a grep.
#
# See #148.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

# _adr_status <file> — echo the status word from the ADR's first Status line.
#
# The two ADRs in the tree write it differently:
#   **Status:** **Accepted** (2026-07-30, nach S1). …
#   **Status:** PROPOSED — 2026-07-24
# so asterisks are stripped and the first word after the colon is taken.
_adr_status() {
    local line
    line="$(grep -m1 -i '^\*\*Status' "$1" 2>/dev/null)" || true
    [ -z "$line" ] && return 1
    printf '%s' "$line" \
        | sed 's/^[^:]*://' \
        | tr -d '*' \
        | awk '{print tolower($1)}'
}

check_amendment_log() {
    local docs_dir="${1:-docs}" log="${2:-docs/amendments.md}"
    local rc=0 found=0 accepted=0

    if [ ! -f "$log" ]; then
        echo "amendment-log: the log itself is missing: $log" >&2
        return 2
    fi

    # find, not a glob: a nested docs/adr/*.md must not be invisible to a
    # check whose whole subject is things nobody looked at.
    local f
    while IFS= read -r f; do
        # A symlink into the tree could point anywhere; refuse rather than
        # follow. `find -type f` already excludes them, this is the belt.
        [ -L "$f" ] && { echo "amendment-log: refusing symlink: $f" >&2; rc=1; continue; }
        found=$((found + 1))

        local adr_status
        adr_status="$(_adr_status "$f")" || continue
        [ "$adr_status" = "accepted" ] || continue
        accepted=$((accepted + 1))

        # Matched literally against the path, not against a title: titles get
        # reworded, paths are what a reader follows.
        #
        # The path is made relative to the PARENT of docs_dir, so that an
        # absolute invocation and a relative one look for the same string.
        # Without this the check silently depends on the caller's cwd: run
        # from the repository root it works, run with an absolute path every
        # accepted ADR reports as missing. A check whose verdict depends on
        # how it was invoked is a check that will one day be invoked the
        # other way.
        local parent rel
        parent="$(dirname "$docs_dir")"
        rel="${f#"$parent"/}"
        rel="${rel#./}"
        if grep -Fq "$rel" "$log"; then
            printf '  OK   %s — accepted, recorded\n' "$rel"
        else
            printf '  FAIL %s — Status: Accepted, absent from %s\n' "$rel" "$log" >&2
            rc=1
        fi
    done < <(find "$docs_dir" -type f -name '*adr*.md' 2>/dev/null | sort)

    # An empty inventory is a failure, not a pass. "No ADR reached Accepted
    # without a line" and "the finder looked in the wrong place" produce the
    # same silence, and only one of them is evidence.
    if [ "$found" -eq 0 ]; then
        echo "amendment-log: no ADR files found under $docs_dir — the check did not run" >&2
        return 2
    fi

    printf '  %d ADR(s), %d accepted\n' "$found" "$accepted"
    return "$rc"
}
