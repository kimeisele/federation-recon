#!/usr/bin/env bats
# amendment-log.bats — the check that an accepted ADR is recorded.
#
# Every case builds its own fixture tree. The suite must not depend on the
# state of the real docs/ directory: a test that goes green because the
# repository happens to be tidy today tells you nothing about the check.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib/amendment-log.sh"
    FIX="$BATS_TEST_TMPDIR/fix"
    mkdir -p "$FIX/docs"
}

# write_adr <name> <status>
write_adr() {
    printf '# ADR — %s\n\n**Status:** **%s** (2026-01-01)\n\nBody.\n' \
        "$1" "$2" > "$FIX/docs/$1-adr.md"
}

write_log() {
    { printf '# Amendment log\n\n| # | Date | PR | Change |\n|---|---|---|---|\n'
      for entry in "$@"; do printf '| 1 | 2026-01-01 | #1 | %s |\n' "$entry"; done
    } > "$FIX/log.md"
}

# A log whose only reference to the path is prose, not a table row.
write_prose_log() {
    printf '# Amendment log\n\n| # | Date | PR | Change |\n|---|---|---|---|\n\nSee %s, still under review.\n' \
        "$1" > "$FIX/log.md"
}

@test "an accepted ADR that is recorded passes" {
    write_adr alpha Accepted
    write_log 'see docs/alpha-adr.md'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 0 ]
}

@test "an accepted ADR that is absent fails" {
    write_adr alpha Accepted
    write_log 'something else entirely'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"alpha-adr.md"* ]]
}

@test "a proposed ADR need not be recorded" {
    write_adr alpha PROPOSED
    write_log 'nothing relevant'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 0 ]
}

@test "status is read case-insensitively and through bold markup" {
    printf '# ADR\n\n**Status:** accepted — lowercase, unbolded\n' > "$FIX/docs/beta-adr.md"
    write_log 'nothing relevant'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
}

@test "one recorded and one absent still fails" {
    write_adr alpha Accepted
    write_adr beta Accepted
    write_log 'docs/alpha-adr.md'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"beta-adr.md"* ]]
}

@test "a nested ADR is found — a glob would have missed it" {
    mkdir -p "$FIX/docs/decisions"
    printf '# ADR\n\n**Status:** **Accepted**\n' > "$FIX/docs/decisions/nested-adr.md"
    write_log 'nothing relevant'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nested-adr.md"* ]]
}

@test "an empty inventory is a failure, not a pass" {
    mkdir -p "$FIX/empty"
    write_log 'nothing'
    run check_amendment_log "$FIX/empty" "$FIX/log.md"
    [ "$status" -eq 2 ]
    [[ "$output" == *"did not run"* ]]
}

@test "a missing log is a failure, not a pass" {
    write_adr alpha Accepted
    run check_amendment_log "$FIX/docs" "$FIX/absent.md"
    [ "$status" -eq 2 ]
}

@test "the match is on the path, not on a title that can be reworded" {
    write_adr alpha Accepted
    write_log 'Execution Core: threat model and trust boundaries'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
}

# The live tree. This is the case the check was written for; it is last so a
# failure here reads as "the repository drifted", not "the check is broken".
@test "the repository's own accepted ADRs are all recorded" {
    run check_amendment_log "$REPO/docs" "$REPO/docs/amendments.md"
    [ "$status" -eq 0 ]
}

# Regression. The first draft matched `${f#./}`, so an absolute invocation
# compared "/Users/…/docs/x-adr.md" against a log containing "docs/x-adr.md"
# and reported every accepted ADR as missing. It passed by hand from the
# repository root and would have failed from anywhere else — the failure mode
# being a check whose verdict depends on the caller's cwd.
@test "the verdict does not depend on the caller's working directory" {
    cd /
    run check_amendment_log "$REPO/docs" "$REPO/docs/amendments.md"
    [ "$status" -eq 0 ]
}

# ── The three bypasses a reviewer found in the first version ───────────────

@test "an accepted ADR not named *adr*.md is still required" {
    mkdir -p "$FIX/docs/decisions"
    printf '# Execution layer\n\n**Status:** **Accepted**\n' > "$FIX/docs/decisions/003-execution-layer.md"
    write_adr alpha PROPOSED           # keeps the inventory non-empty, as in the real tree
    write_log 'nothing relevant'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"003-execution-layer.md"* ]]
}

@test "an unbolded status label is read, not silently skipped" {
    # The first version required the line to begin with `**Status`. A plain
    # `Status: Accepted` returned failure, and the caller skipped the file
    # without a word — an accepted ADR passing CI by not being bold.
    printf '# ADR\n\nStatus: Accepted\n' > "$FIX/docs/plain-adr.md"
    write_log 'nothing relevant'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
    [[ "$output" == *"plain-adr.md"* ]]
}

@test "a prose mention is not an entry" {
    # `grep -F` anywhere in the file was satisfied by a footnote with no row,
    # no date and no PR — a mention, carrying none of the countability the log
    # exists for.
    write_adr alpha Accepted
    write_prose_log 'docs/alpha-adr.md'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 1 ]
}

@test "a file with no status line is not an ADR and is not counted as checked" {
    printf '# Just a document\n\nNo status here.\n' > "$FIX/docs/notes.md"
    write_adr alpha Accepted
    write_log 'docs/alpha-adr.md'
    run check_amendment_log "$FIX/docs" "$FIX/log.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"with a status line"* ]]
}
