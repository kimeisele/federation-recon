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

# ── the three findings from round 1 of this check's own review ────────────

@test "rounds: a registered legacy round that is gone is caught" {
    # The register was matched literally for files that EXIST, and nothing
    # checked the other direction: rename a registered round away and the
    # entry becomes a name for nothing. A one-command bypass of the headline
    # protection for pre-convention rounds.
    _round "9-round1.md"
    printf '9-round1.md\n' > "$FIX/ROUNDS-LEGACY"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]

    mv "$FIX/9-round1.md" "$FIX/9-part1.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not on disk"* ]]
}

@test "rounds: a comment in the register is not treated as a filename" {
    _round "9-round1.md"
    printf '# a comment\n\n9-round1.md\n' > "$FIX/ROUNDS-LEGACY"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: a renamed round is caught, not only a deleted one" {
    # `--diff-filter=D` reports a rename as R. Renaming a round away removed
    # it from every rule at once: the old path never appeared as a deletion,
    # and the new name matched neither the round pattern nor the register.
    cd "$BATS_TEST_TMPDIR"
    git init -q r2 && cd r2
    git config user.email t@t && git config user.name t
    mkdir -p gc
    printf '# Round\n\nverdict: REJECT\n' > gc/9-round1.md
    printf '# P\n\n[r1](9-round1.md)\n\nverdict: APPROVE\n' > gc/9.md
    git add -A && git commit -q -m one
    git mv gc/9-round1.md gc/9-part1.md
    printf '# P\n\nverdict: APPROVE\n' > gc/9.md
    git add -A && git commit -q -m two

    source "$REPO/scripts/lib/consultation-rounds.sh"
    run check_consultation_rounds "gc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"stays readable"* ]]
}

@test "rounds: a shallow clone is a failure, not a silent pass" {
    # The comment claimed the deletion check was "skipped when there is no
    # history to read (a shallow clone), and skipping is announced rather than
    # silent". It tested `--git-dir`, which succeeds in a shallow clone, so
    # under fetch-depth: 1 the check examined one commit, found nothing, and
    # printed OK. The announced safeguard did not exist.
    cd "$BATS_TEST_TMPDIR"
    git init -q src && cd src
    git config user.email t@t && git config user.name t
    mkdir -p gc
    printf '# Round\n\nverdict: REJECT\n' > gc/9-round1.md
    printf '# P\n\n[r1](9-round1.md)\n\nverdict: APPROVE\n' > gc/9.md
    git add -A && git commit -q -m one
    printf 'x\n' > other.txt && git add -A && git commit -q -m two

    cd "$BATS_TEST_TMPDIR"
    git clone -q --depth 1 "file://$BATS_TEST_TMPDIR/src" shallow
    cd shallow
    [ "$(git rev-parse --is-shallow-repository)" = "true" ]

    source "$REPO/scripts/lib/consultation-rounds.sh"
    run check_consultation_rounds "gc"
    [ "$status" -eq 1 ]
    [[ "$output" == *"shallow"* ]]
}

@test "rounds: a REGISTERED round emptied of its verdict still fails" {
    # The population the register exists to protect was the one the verdict
    # rule did not cover: the check ran after the register branch, behind a
    # `continue`, so a pre-convention round could be gutted to a stub in one
    # pull request while this file promised it could not be emptied.
    _round "9-round1.md"
    printf '9-round1.md\n' > "$FIX/ROUNDS-LEGACY"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]

    printf '# Round\n\n(content removed)\n' > "$FIX/9-round1.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no verdict"* ]]
}

@test "rounds: a link inside a fenced code block is an example, not a reference" {
    # The consultation gate requires a primary to embed the raw diff it was
    # judged against. That diff contains every link in every file it touches —
    # including this check's own bats fixtures. 155.md was refused for linking
    # `9-round1.md`, a name that exists only inside a test.
    _round "9-round1.md"
    printf '# P\n\n[r1](9-round1.md)\n\n```diff\n+[r2](9-round2.md)\n```\n\nverdict: APPROVE\n' \
        > "$FIX/9.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 0 ]
}

@test "rounds: a link outside the fence is still a reference" {
    # The other direction, so the fence filter cannot be a blanket excuse.
    _round "9-round1.md"
    printf '# P\n\n[r1](9-round1.md)\n\n```diff\n+x\n```\n\n[r2](9-round2.md)\n\nverdict: APPROVE\n' \
        > "$FIX/9.md"
    run check_consultation_rounds "$FIX"
    [ "$status" -eq 1 ]
    [[ "$output" == *"9-round2.md"* ]]
}
