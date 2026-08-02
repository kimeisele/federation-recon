#!/usr/bin/env bats
# finding-retirement.bats — the laundering move, as a test.
#
# The gap, from the reviewer of docs/self-remediation-adr.md: amend the
# STANDARD rather than the mechanism, leave the record untouched, then retire
# the Finding as obsolete. The record stays independent; the benchmark does
# not.
#
# Fixtures are shaped like real `git diff -M` output — `diff --git` headers,
# `deleted file mode`, `rename from/to`, `+++ /dev/null`. Round 1 of this
# check used flat `+++ b/` fixtures and passed while checking nothing, because
# two files collapsed into one record. A fixture that does not look like the
# input is a test of something else.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib/finding-retirement.sh"
    cd "$REPO"
}

_d() { printf '%s\n' "$@"; }

# A modified file, as git writes it.
_mod() {
    _d "diff --git a/$1 b/$1" "--- a/$1" "+++ b/$1" "+$2"
}

@test "finding-retirement: an unrelated change passes" {
    run check_finding_retirement "$(_mod README.md 'hello')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: retiring a Finding alone is permitted" {
    # Must stay possible. A rule that forbade it would forbid legitimately
    # retiring a Finding after a legitimate standard change.
    run check_finding_retirement \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: moving the standard alone is permitted" {
    run check_finding_retirement "$(_mod core/policy.json '  "x": 1')"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: retirement plus policy change is refused" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod core/policy.json '  "x": 1')")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"two acts"* ]]
    [[ "$output" == *"core/policy.json"* ]]
}

@test "finding-retirement: a procedure counts as a standard" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod procedures/consumption-v1.md 'text')")"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: an ADR counts as a standard" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod docs/execution-core-adr.md 'text')")"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: an ADR named in caps counts too" {
    # `find -name '*adr*.md'` was case-sensitive; docs/ADR-7.md escaped it.
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod docs/ADR-7.md 'text')")"
    [ "$status" -eq 1 ]
}

@test "finding-retirement: a future founding-package version counts too" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod docs/founding-package-v0.3.md 'text')")"
    [ "$status" -eq 1 ]
}

# ── the four holes a reviewer put in round 1 ──────────────────────────────

@test "finding-retirement: DELETING the standard is refused, not passed" {
    # The maximal benchmark move — abolish it. Round 1 passed this, because a
    # deleted file emits `+++ /dev/null` and nothing matched `+++ b/<path>`.
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "diff --git a/procedures/consumption-v1.md b/procedures/consumption-v1.md" \
        "deleted file mode 100644" \
        "--- a/procedures/consumption-v1.md" \
        "+++ /dev/null")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"deleted"* ]]
}

@test "finding-retirement: RENAMING the standard away is refused" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "diff --git a/procedures/consumption-v1.md b/notes/consumption-v1.md" \
        "similarity index 100%" \
        "rename from procedures/consumption-v1.md" \
        "rename to notes/consumption-v1.md")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"renamed"* ]]
}

@test "finding-retirement: RENAMING a Finding out of findings/ is a retirement" {
    # The record survives unaltered — the ADR's letter honoured — and vanishes
    # from everything that enumerates the directory. Round 1 saw nothing:
    # a rename emits no `deleted file mode` and no `+++ b/findings/...`.
    run check_finding_retirement "$(_d \
        "diff --git a/findings/f-1.json b/attic/f-1.json" \
        "similarity index 100%" \
        "rename from findings/f-1.json" \
        "rename to attic/f-1.json" \
        "$(_mod core/policy.json '  "x": 1')")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"moved out of findings/"* ]]
}

@test "finding-retirement: deleting a Finding counts as retiring it" {
    run check_finding_retirement "$(_d \
        "diff --git a/findings/f-1.json b/findings/f-1.json" \
        "deleted file mode 100644" \
        "--- a/findings/f-1.json" \
        "+++ /dev/null" \
        "$(_mod procedures/consumption-v1.md 'text')")"
    [ "$status" -eq 1 ]
    [[ "$output" == *"was deleted"* ]]
}

@test "finding-retirement: the two halves are correlated, not two greps" {
    # Round 1 tested "some file was deleted" AND "some finding line changed"
    # independently, so deleting scripts/old.sh while editing any Finding
    # reported a deleted Finding that did not exist.
    run check_finding_retirement "$(_d \
        "diff --git a/scripts/old.sh b/scripts/old.sh" \
        "deleted file mode 100755" \
        "--- a/scripts/old.sh" \
        "+++ /dev/null" \
        "$(_mod findings/f-1.json '  "severity": "low"')" \
        "$(_mod core/policy.json '  "x": 1')")"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no Finding retired"* ]]
}

@test "finding-retirement: a superseded line outside findings/ is not a retirement" {
    # A doc example or a fixture mentioning the state must not count.
    run check_finding_retirement "$(_d \
        "$(_mod docs/example.md '  "lifecycle_state": "superseded"')" \
        "$(_mod core/policy.json '  "x": 1')")"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: a path merely containing a standard path does not count" {
    run check_finding_retirement "$(_d \
        "$(_mod findings/f-1.json '  "lifecycle_state": "superseded"')" \
        "$(_mod docs/notes/core/policy.json.bak 'text')")"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: removing a superseded state is not a retirement" {
    run check_finding_retirement "$(_d \
        "diff --git a/findings/f-1.json b/findings/f-1.json" \
        "--- a/findings/f-1.json" \
        "+++ b/findings/f-1.json" \
        '-  "lifecycle_state": "superseded"' \
        "$(_mod core/policy.json '  "x": 1')")"
    [ "$status" -eq 0 ]
}

@test "finding-retirement: an unresolvable base is a failure, not a pass" {
    run bash -c "cd '$BATS_TEST_TMPDIR' && git init -q . && \
        BASE_REF=refs/heads/nope source '$REPO/scripts/lib/finding-retirement.sh' && \
        BASE_REF=refs/heads/nope check_finding_retirement"
    [ "$status" -eq 2 ]
    [[ "$output" == *"did not run"* ]]
}

@test "finding-retirement: the base ref is taken from the environment" {
    # Hardcoding origin/main gives a PR against another base an ancient
    # merge-base: every standard change since the branchpoint, plus any
    # retirement, becomes a false failure.
    run bash -c "BASE_REF=refs/heads/definitely-not-a-ref \
        source '$REPO/scripts/lib/finding-retirement.sh' && \
        BASE_REF=refs/heads/definitely-not-a-ref check_finding_retirement"
    [ "$status" -eq 2 ]
    [[ "$output" == *"definitely-not-a-ref"* ]]
}

@test "finding-retirement: the live branch is clean" {
    if ! git rev-parse --verify "${BASE_REF:-origin/main}" >/dev/null 2>&1; then
        skip "base ref not available in this checkout"
    fi
    run check_finding_retirement
    [ "$status" -eq 0 ]
}
