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
