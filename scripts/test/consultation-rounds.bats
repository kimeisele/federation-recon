#!/usr/bin/env bats
# consultation-rounds.bats — a superseded round stays readable.
#
# Fixtures, not the live tree, except for the last case. A suite that goes
# green because the repository happens to be tidy today says nothing about the
# check.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    # shellcheck disable=SC1091
    source "$REPO/scripts/lib/consultation-rounds.sh"
    FIX="$BATS_TEST_TMPDIR/c"
    mkdir -p "$FIX"
}

_primary() {
    printf '# Consultation — PR %s\n\nEarlier: %s\n\nverdict: APPROVE\n' \
        "$1" "$2" > "$FIX/$1.md"
}

_round() {
    printf '# Round\n\nBody.\n\nverdict: REJECT\n' > "$FIX/$1"
}

@test "rounds: a primary linking an existing round passes" {
    _round "9-round1.md"
    _primary 9 "[round 1](9-round1.md)"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: a primary linking a missing round fails" {
    _primary 9 "[round 1](9-round1.md)"
    _round "9-round2.md"
    _primary 9 "[r1](9-round1.md) [r2](9-round2.md)"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"9-round1.md"* ]]
}

@test "rounds: a round the primary does not link is an orphan" {
    # The quiet drop: the file is still there, but nothing points at it, so a
    # reader following the primary never learns it exists.
    _round "9-round1.md"
    _primary 9 "no links here"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"orphaned"* ]]
}

@test "rounds: a round emptied of its verdict fails" {
    printf '# Round\n\n(content removed)\n' > "$FIX/9-round1.md"
    _primary 9 "[r1](9-round1.md)"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no verdict"* ]]
}

@test "rounds: the bolded prose verdict of a pre-convention round is accepted" {
    printf '# Round\n\nVerdict: **REJECT**. Details.\n' > "$FIX/9-round1.md"
    _primary 9 "[r1](9-round1.md)"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: a round with no primary must be in the register" {
    _round "9-round1.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ROUNDS-LEGACY"* ]]
}

@test "rounds: the register admits a pre-convention round" {
    _round "9-round1.md"
    printf '9-round1.md\n' > "$FIX/ROUNDS-LEGACY"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: the register is matched literally, not as a substring" {
    _round "9-round1.md"
    printf '9-round1\n' > "$FIX/ROUNDS-LEGACY"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
}

@test "rounds: a file that is not <pr>.md is not treated as a primary" {
    # The first draft matched `[0-9]*.md`, which made 127-kimi.md a primary for
    # PR 127 and demanded every sibling round be linked from it — four false
    # failures from one over-broad glob.
    _round "9-round1.md"
    printf '9-round1.md\n' > "$FIX/ROUNDS-LEGACY"
    printf '# not a primary\n' > "$FIX/9-kimi.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: an empty directory is a failure, not a pass" {
    mkdir -p "$FIX/empty"
    run check_consultation_rounds "$FIX/empty"
    [ "$status" -eq 2 ]
    [[ "$output" == *"did not run"* ]]
}

@test "rounds: a deleted round is caught from git history" {
    # The attack this exists for: delete the REJECT round and drop the link, so
    # the working tree looks consistent. Only history remembers.
    cd "$BATS_TEST_TMPDIR"
    git init -q repo && cd repo
    git config user.email t@t && git config user.name t
    mkdir -p gc
    printf '# Round\n\nverdict: REJECT\n' > gc/9-round1.md
    printf '# P\n\n[r1](9-round1.md)\n\nverdict: APPROVE\n' > gc/9.md
    git add -A && git commit -q -m one
    git rm -q gc/9-round1.md
    printf '# P\n\nverdict: APPROVE\n' > gc/9.md
    git add -A && git commit -q -m two

    source "$REPO/scripts/lib/consultation-rounds.sh"
    run check_consultation_rounds "gc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stays readable"* ]]
}

@test "rounds: the live consultations directory passes today" {
    run check_consultation_rounds "$REPO/governance/consultations"
    [ "$status" -eq 0 ]
}
