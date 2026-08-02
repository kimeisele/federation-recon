#!/usr/bin/env bash
# consultation-rounds.sh — a superseded review round stays readable.
#
# Source it, then call:
#   check_consultation_rounds [dir]
#
# Exit: 0 every primary artifact accounts for its rounds, 1 one does not,
#       2 the check could not run.
#
# ── The convention this enforces ───────────────────────────────────────────
#
# A consultation that goes more than one round is stored as:
#
#   governance/consultations/<pr>.md            primary — the LATEST round
#   governance/consultations/<pr>-round<N>.md   every earlier round, whole
#
# The primary carries the current verdict in its first `verdict:` line, which
# is what `check_consultation_gate` reads, and links every earlier round.
#
# ── Why it is a convention and not an accident ─────────────────────────────
#
# PR #150 was reviewed twice: REJECT, then APPROVE against a corrected diff.
# Both rounds were first written into one file, and the gate — correctly —
# read the first `verdict:` line it found, saw REJECT, and demanded a third
# provider. The structural answer is one file per round; the alternative was
# to loosen the gate, and a machine guardrail is not something to adjust
# because it is inconvenient once.
#
# ── The thing this is actually guarding against ────────────────────────────
#
# Multi-round review is a mechanism for **improving a change**. It is one
# keystroke away from being a mechanism for **outlasting a reviewer**: run
# rounds until one approves, then quietly drop the ones that did not.
#
# So a round is never deleted and never shortened. A REJECT later replaced by
# an APPROVE stays readable at full length, and the primary must link to it.
# The record of what was objected to is worth more than the verdict that
# settled it — a verdict says a decision was reached, the rounds say what it
# cost.
#
# ── What this establishes ──────────────────────────────────────────────────
#
#   - A primary cannot link a round file that is not there.
#   - A round file cannot be orphaned: if a primary exists for its PR, it must
#     be linked from it.
#   - A round file cannot be deleted — checked against git history, not
#     against the working tree.
#   - A round file cannot be emptied of its verdict.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - That the primary carries the LATEST round. Ordering rounds by their
#     content is guesswork; the number in the filename is the author's claim
#     about order, not a fact. A primary that links round 3 while carrying
#     round 2's verdict passes here and is caught only by a reader.
#   - That a round file is unedited below its verdict line. Truncation to
#     nothing is caught; a paragraph removed from the middle is not. Git
#     history shows it, and nothing here reads history for content.
#   - That the rounds are honest. This is a filing rule.
#   - **That history is evidence on an unmerged branch.** Rounds for an open
#     pull request exist only in that branch, and an unmerged branch's history
#     is the author's to rewrite: three rounds, `git rebase -i`, drop the
#     commits that added rounds 1 and 2, force-push, and every rule above is
#     green with no deletion event to find. A reviewer named this as the
#     primary realization of the threat the convention exists for. The only
#     real anchors are rounds reaching `main` individually — which merging a
#     PR does — and the consultation provenance record, which is per-dispatch
#     and could be cross-checked. Neither is done here, and the gap is stated
#     rather than implied.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

# _cr_is_round <basename> — does this filename claim to be a numbered round?
_cr_is_round() {
    case "$1" in
        *round[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

# _cr_pr_of <basename> — the leading PR number, or empty.
_cr_pr_of() {
    printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\)[-.].*/\1/p'
}

check_consultation_rounds() {
    local dir="${1:-governance/consultations}"
    local rc=0 primaries=0 rounds=0

    if [ ! -d "$dir" ]; then
        echo "consultation-rounds: no such directory: $dir" >&2
        return 2
    fi

    # ── 1. every round a primary links to must exist ───────────────────────
    local f base pr link target
    while IFS= read -r f; do
        base="$(basename "$f")"
        # A primary is exactly <pr>.md. The first draft matched `[0-9]*.md`,
        # which made 127-kimi.md a primary for PR 127 and then demanded that
        # every sibling round be linked from it — four false failures from one
        # over-broad glob.
        pr="${base%.md}"
        case "$pr" in
            ''|*[!0-9]*) continue ;;
        esac
        [ -z "$pr" ] && continue
        primaries=$((primaries + 1))

        # Markdown links of the form [text](name.md) or (./name.md), outside
        # fenced code blocks.
        #
        # The fence filter is not cosmetic. A primary that embeds the raw diff
        # it was judged against — which the consultation gate requires — will
        # contain every link in every file that diff touches, including this
        # check's own bats fixtures. 155.md was refused for linking
        # `9-round1.md`, a name that exists only inside a test. A link in a
        # code block is an example, not a reference.
        while IFS= read -r link; do
            [ -z "$link" ] && continue
            target="$dir/$(basename "$link")"
            if [ ! -f "$target" ]; then
                printf '  FAIL %s links to %s, which does not exist\n' \
                    "$base" "$link" >&2
                rc=1
            fi
        done < <(awk '/^```/ {fence = !fence; next} !fence' "$f" 2>/dev/null \
                 | grep -oE '\]\([^)]*[0-9]+-[^)]*\.md\)' \
                 | sed 's/^](//; s/)$//' | sort -u)

        # ── 2. every round file for this PR must be linked from it ─────────
        # find, not a glob: an unmatched glob is a literal in bash and a hard
        # error in zsh, and this file is sourced by both a bash gate and a
        # human at a zsh prompt.
        local r rbase
        while IFS= read -r r; do
            [ -f "$r" ] || continue
            rbase="$(basename "$r")"
            _cr_is_round "$rbase" || continue
            if ! grep -qF "$rbase" "$f"; then
                printf '  FAIL %s exists but %s does not link it — an orphaned round is a dropped one\n' \
                    "$rbase" "$base" >&2
                rc=1
            fi
        done < <(find "$dir" -maxdepth 1 -type f -name "$pr-*.md" 2>/dev/null | sort)
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' | sort)

    # ── 3. a round must still carry its verdict, and belong to a primary ───
    local register="$dir/ROUNDS-LEGACY"
    while IFS= read -r f; do
        base="$(basename "$f")"
        _cr_is_round "$base" || continue
        rounds=$((rounds + 1))

        # The verdict check runs FIRST, before the register branch, and the
        # order is the whole point.
        #
        # It used to run after, behind a `continue`, so a registered
        # pre-convention round could be gutted to a stub in one pull request
        # and pass every rule — while this file's own "what this establishes"
        # promised that a round cannot be emptied of its verdict. The nine
        # files the register exists to protect were the exact population the
        # promise did not cover. Same claim-versus-code mismatch as the
        # shallow-clone comment, one section down.
        #
        # Two grammars are accepted. `verdict: REJECT` at line start is what
        # the consultation gate reads and what new rounds must carry; the
        # bolded prose form is what several pre-convention rounds use, and
        # rejecting those would be enforcing the convention retroactively on
        # files that predate it. Either proves the round still ends in a
        # judgment, which is what this rule is about.
        if ! grep -qE '^verdict: (APPROVE|REJECT)$' "$f" \
           && ! grep -qiE '^[[:space:]]*\**Verdict:?\**[[:space:]]*\**(APPROVE|REJECT)' "$f"; then
            printf '  FAIL %s carries no verdict line — a round emptied of its verdict is a deleted one\n' \
                "$base" >&2
            rc=1
        fi

        # A round whose PR has no primary predates the convention. Those are
        # named in a register with a reason, the same way UNVERIFIED names
        # consultations whose provider was never established. Silence would
        # let the convention lapse for anything filed before someone thought
        # to check.
        pr="$(_cr_pr_of "$base")"
        if [ -n "$pr" ] && [ ! -f "$dir/$pr.md" ]; then
            if [ ! -f "$register" ] || ! awk -v want="$base" '$0 == want {found=1} END {exit !found}' "$register"; then
                printf '  FAIL %s has no primary %s.md and no entry in %s\n' \
                    "$base" "$pr" "$register" >&2
                rc=1
            fi
            continue
        fi
    done < <(find "$dir" -maxdepth 1 -type f -name '*.md' | sort)

    # ── 4. a round is never deleted or renamed away ────────────────────────
    #
    # Against git history, not the working tree: the working tree cannot tell
    # you about a file that is not in it.
    #
    # `--git-dir` was the wrong test and the comment above it claimed a
    # safeguard the code did not contain. A shallow clone HAS a git dir, so
    # under `fetch-depth: 1` this examined one commit, found nothing, and
    # printed OK — the announced skip never happening because the condition
    # never fired. `--is-shallow-repository` is the test the comment described.
    # Only for a directory that is actually under version control here. A
    # fixture in a tmpdir has no history and never did, so asking git about it
    # answers a question nobody posed — and in a shallow CI checkout it turned
    # every fixture test red, including the ones asserting a clean pass.
    local dir_tracked=false
    if git ls-files --error-unmatch "$dir" >/dev/null 2>&1 \
       || [ -n "$(git ls-files -- "$dir" 2>/dev/null | head -1)" ]; then
        dir_tracked=true
    fi

    if ! $dir_tracked; then
        :
    elif [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
        echo "  note: shallow clone — the deletion check did not run; use fetch-depth: 0" >&2
        rc=1
    elif git rev-parse --git-dir >/dev/null 2>&1; then
        # D and R, with --name-status rather than --name-only.
        #
        # Two corrections in one line, both found by testing rather than by
        # reading: `--diff-filter=D` reports a rename as R, so renaming
        # 131-sol-round3.md to 131-sol-part3.md removed it from every rule at
        # once. And `--name-only` prints only the NEW path of a rename, which
        # is the one name that is not the round — the old path, the thing that
        # disappeared, never appears at all.
        local gone
        gone="$(git log --diff-filter=DR -M --name-status --format= -- \
                    "$dir" 2>/dev/null \
                | awk -F'\t' '/^D/ {print $2} /^R/ {print $2}' \
                | sort -u || true)"
        local d dbase
        while IFS= read -r d; do
            [ -z "$d" ] && continue
            dbase="$(basename "$d")"
            _cr_is_round "$dbase" || continue
            # Back on disk under its own name: a revert, or a rename that was
            # undone. Nothing was lost.
            [ -f "$dir/$dbase" ] && continue
            printf '  FAIL %s was removed (%s) — a superseded round stays readable\n' \
                "$dbase" "$d" >&2
            rc=1
        done <<< "$gone"
    else
        echo "  note: not a git repository — the deletion check did not run" >&2
    fi

    # ── 5. every registered legacy round must still be on disk ─────────────
    #
    # The register was matched literally for files that exist, and nothing
    # checked the other direction: rename a registered round away and the
    # entry becomes a name for nothing, silently. The headline protection for
    # pre-convention rounds had a one-command bypass.
    if [ -f "$register" ]; then
        local entry
        while IFS= read -r entry; do
            case "$entry" in ''|'#'*) continue ;; esac
            if [ ! -f "$dir/$entry" ]; then
                printf '  FAIL %s is registered in ROUNDS-LEGACY but is not on disk\n' \
                    "$entry" >&2
                rc=1
            fi
        done < "$register"
    fi

    # An empty inventory is a failure, not a pass — but "the check could not
    # run" must not overwrite a violation the check already found. Renaming
    # the last registered round away empties the inventory AND is the
    # violation, and returning 2 there reported the weaker of the two truths.
    if [ "$primaries" -eq 0 ] && [ "$rounds" -eq 0 ] && [ "$rc" -eq 0 ]; then
        echo "consultation-rounds: no consultation files found in $dir — the check did not run" >&2
        return 2
    fi

    printf '  %d primary artifact(s), %d round(s)\n' "$primaries" "$rounds"
    return "$rc"
}
