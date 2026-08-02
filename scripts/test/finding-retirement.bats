#!/usr/bin/env bats
# finding-retirement.bats — the laundering move, as a test.
#
# The gap, from the reviewer of docs/self-remediation-adr.md: amend the
# STANDARD rather than the mechanism, leave the record untouched, then retire
# the Finding as obsolete. The record stays independent; the benchmark does
# not.
#
# Every case supplies a synthetic diff. That is deliberate: a test that built
# real commits would be testing git, and the thing under test is a rule about
# what may appear in one diff.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib/finding-retirement.sh"
    cd "$REPO"
}

_diff() { printf '%s\n' "$@"; }

@test "finding-retirement: an unrelated change passes" {
    run check_finding_retirement "$(_diff '+++ b/README.md' '+hello')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: retiring a Finding alone is permitted" {
    # This must stay possible. A rule that forbade it would forbid legitimately
    # retiring a Finding after a legitimate standard change, and the point is
    # to make the sequence visible, not impossible.
    run check_finding_retirement \
        "$(_diff '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: moving the standard alone is permitted" {
    run check_finding_retirement "$(_diff '+++ b/core/policy.json' '+  "x": 1')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: retirement plus policy change is refused" {
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"' \
        '+++ b/core/policy.json' '+  "x": 1')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"two acts"* ]]
    [[ "$output" == *"core/policy.json"* ]]
}

@test "finding-retirement: deleting a Finding counts as retiring it" {
    # The blunter shape, and the easier one to miss: a deleted file has no line
    # to grep a lifecycle state out of.
    run check_finding_retirement "$(_diff \
        'deleted file mode 100644' '--- a/findings/f-1.json' \
        '+++ b/procedures/consumption-v1.md' '+text')"
    [ "$status" -eq 1 ]
    [[ "$output" == *"deleted"* ]]
}

@test "finding-retirement: a procedure counts as a standard" {
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"' \
        '+++ b/procedures/consumption-v1.md' '+text')"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: an ADR counts as a standard" {
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"' \
        '+++ b/docs/execution-core-adr.md' '+text')"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: the founding package counts as a standard" {
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"' \
        '+++ b/docs/founding-package-v0.2.md' '+text')"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: the standard list is matched anchored" {
    # `procedures/consumption-v1.md` must not be satisfied by a path that
    # merely contains it — otherwise a file named
    # `docs/notes-on-procedures/consumption-v1.md` would trip the rule and, far
    # worse, a rename could dodge it.
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '+  "lifecycle_state": "superseded"' \
        '+++ b/docs/notes/core/policy.json.bak' '+text')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: removing a superseded state is not a retirement" {
    # The reverse direction — un-retiring — is not what this guards.
    run check_finding_retirement "$(_diff \
        '+++ b/findings/f-1.json' '-  "lifecycle_state": "superseded"' \
        '+++ b/core/policy.json' '+  "x": 1')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: an unresolvable base is a failure, not a pass" {
    # Called with no argument in a place where origin/main cannot be resolved.
    # "The check could not run" and "the check found nothing" must never be the
    # same outcome.
    run bash -c "cd '$BATS_TEST_TMPDIR' && git init -q . && \
        source '$REPO/scripts/lib/finding-retirement.sh' && \
        check_finding_retirement"
    [ "$status" -eq 2 ]
    [[ "$output" == *"did not run"* ]]
}

@test "finding-retirement: the live branch is clean" {
    # The case the rule exists for, against the actual branch. Skipped rather
    # than failed where origin/main is unavailable, and the skip is visible.
    if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
        skip "origin/main not available in this checkout"
    fi
    run check_finding_retirement
    [ "$status" -eq 0 ]
}
