#!/usr/bin/env bash
# finding-retirement.sh — retiring a Finding and moving the standard it was
# measured against are two acts, and one change may not be both.
#
# Source it, then call:
#   check_finding_retirement [diff_text]
#
# With no argument the diff is computed against origin/main. Tests pass a
# synthetic diff.
#
# Exit: 0 clean, 1 a violation, 2 the check could not run.
#
# ── The gap this closes ────────────────────────────────────────────────────
#
# `docs/self-remediation-adr.md` (amendment 4) permits Recon to fix a defect a
# Finding describes, and forbids altering, suppressing or retracting the
# record. An independent reviewer of that ADR found the way through, and it is
# narrower than the one the ADR had already named:
#
#   > A "fix" PR can amend the STANDARD rather than the mechanism: document
#   > that sandbox egress is sanctioned. The Finding survives untouched — the
#   > record is never altered, suppressed, or retracted — but its referent is
#   > redefined, and the Finding is then retired as obsolete. This attacks the
#   > rationale directly: the record is independent, but the BENCHMARK is not.
#
# The ADR answered it in prose — name the gap, note that the amendment log
# counts standard changes — and prose is what this repository has learned not
# to trust. This is the mechanical form.
#
# ── The rule ───────────────────────────────────────────────────────────────
#
# One change may not both
#   (a) move a Finding to `superseded`, or delete a Finding outright, and
#   (b) modify a file that defines what a Finding is measured against.
#
# Either alone is fine. Together they are the laundering move, and splitting
# them is cheap: two PRs, each reviewable on the question it actually raises.
# "Is this still a defect?" and "should the standard change?" are different
# questions, and a reviewer asked both at once tends to answer neither.
#
# ── What this establishes ──────────────────────────────────────────────────
#
# That the two acts cannot ride in one diff. After the split, the retirement PR
# stands alone and says, on its own, that a Finding is being retired because a
# standard moved — which is a claim someone can refuse.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - That the split PRs are honest. Land the standard change on Monday and the
#     retirement on Tuesday and this says nothing. It makes the sequence
#     visible in two diffs instead of invisible in one; it does not make it
#     impossible. A rule that made it impossible would also forbid legitimately
#     retiring a Finding after a legitimate standard change, which is a thing
#     that must remain possible.
#   - That `superseded` is the only way to neutralise a Finding. A Finding left
#     `observed` while everything around it is redefined is untouched by this.
#   - Anything about Findings in observed repositories. Recon does not write
#     those.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

# Files that define what a Finding is measured against. A change to any of them
# can move the benchmark without touching a single record.
_fr_standard_files() {
    cat <<'EOF'
core/policy.json
CLAUDE.md
docs/founding-package-v0.2.md
EOF
    # Every procedure, and every ADR, whatever they are called.
    find procedures -type f -name '*.md' 2>/dev/null | sort
    find docs -type f -name '*adr*.md' 2>/dev/null | sort
}

check_finding_retirement() {
    local diff_out
    if [ $# -ge 1 ]; then
        diff_out="$1"
    else
        if ! git rev-parse --verify origin/main >/dev/null 2>&1; then
            echo "finding-retirement: cannot resolve origin/main — the check did not run" >&2
            echo "       A shallow clone must not look like a clean result." >&2
            return 2
        fi
        diff_out="$(git diff "origin/main...HEAD" 2>/dev/null)"
    fi

    # Nothing changed — nothing to say.
    [ -z "$diff_out" ] && { echo "  no diff against origin/main"; return 0; }

    # ── (a) is a Finding being retired? ────────────────────────────────────
    #
    # Two shapes: a lifecycle_state moved to superseded, or a findings/ file
    # removed entirely. The second is the blunter one and easier to miss,
    # because a deleted file has no line to grep for a state in.
    local retired=""
    if printf '%s\n' "$diff_out" \
        | grep -qE '^\+.*"lifecycle_state"[[:space:]]*:[[:space:]]*"superseded"'; then
        retired="a Finding moved to superseded"
    fi
    if printf '%s\n' "$diff_out" | grep -qE '^deleted file mode' \
       && printf '%s\n' "$diff_out" | grep -qE '^--- a/findings/'; then
        retired="${retired:+$retired; }a Finding file was deleted"
    fi
    [ -z "$retired" ] && { echo "  no Finding retired in this change"; return 0; }

    # ── (b) did the standard move in the same change? ──────────────────────
    local moved="" sf
    while IFS= read -r sf; do
        [ -z "$sf" ] && continue
        # `+++ b/<path>` is the header of a modified or added file. Matched
        # anchored, so `procedures/x.md` cannot be satisfied by a path that
        # merely contains it.
        if printf '%s\n' "$diff_out" | grep -qxF "+++ b/$sf"; then
            moved="${moved}    $sf"$'\n'
        fi
    done < <(_fr_standard_files)

    if [ -z "$moved" ]; then
        echo "  $retired, and no standard file moved with it"
        return 0
    fi

    echo "FAIL — finding retirement: this change retires a Finding AND moves the" >&2
    echo "       standard it was measured against, in one diff." >&2
    echo "         retirement: $retired" >&2
    echo "         standard files touched:" >&2
    printf '%s' "$moved" >&2
    echo "       These are two acts. Split them: the standard change on its own," >&2
    echo "       then the retirement on its own, so that 'should the standard" >&2
    echo "       change?' and 'is this still a defect?' are each answered by" >&2
    echo "       someone who was asked only that." >&2
    echo "       See docs/self-remediation-adr.md, residual gap 2." >&2
    return 1
}
