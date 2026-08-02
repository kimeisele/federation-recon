#!/usr/bin/env bash
# finding-retirement.sh — retiring a Finding and moving the standard it was
# measured against are two acts, and one change may not be both.
#
# Source it, then call:
#   check_finding_retirement [diff_text]
#
# With no argument the diff is computed against the base ref: BASE_REF if the
# caller exported one, GITHUB_BASE_REF on a pull_request event, otherwise
# origin/main. Tests pass a synthetic diff.
#
# Exit: 0 clean, 1 a violation, 2 the check could not run.
#
# ── The gap this closes ────────────────────────────────────────────────────
#
# `docs/self-remediation-adr.md` (amendment 4) permits Recon to fix a defect a
# Finding describes, and forbids altering, suppressing or retracting the
# record. An independent reviewer of that ADR found the way through:
#
#   > A "fix" PR can amend the STANDARD rather than the mechanism: document
#   > that sandbox egress is sanctioned. The Finding survives untouched — the
#   > record is never altered, suppressed, or retracted — but its referent is
#   > redefined, and the Finding is then retired as obsolete. The record is
#   > independent, but the BENCHMARK is not.
#
# ── The rule ───────────────────────────────────────────────────────────────
#
# One change may not both
#   (a) retire a Finding — move it to `superseded`, delete it, or move it out
#       of `findings/` — and
#   (b) touch a file that defines what a Finding is measured against, in any
#       way: modify it, delete it, or rename it away.
#
# Either alone is fine. Together they are the laundering move.
#
# ── Round 1 of this check was refused, and the reason is worth keeping ─────
#
# The first version grepped the raw diff for `+++ b/<standard file>` and for a
# `superseded` line anywhere in it. A reviewer put four holes in it in one
# pass, and all four are the same mistake — treating a diff as text rather
# than as a structure:
#
#   * **Deleting** a standard file emits `+++ /dev/null`, so abolishing the
#     benchmark outright — the maximal move — passed.
#   * **Renaming** a Finding out of `findings/` emits `rename from/to` and no
#     `deleted file mode`, so the record survived unaltered and vanished from
#     everything that enumerates the directory. Invisible to both halves.
#   * The standard list was built from **HEAD**, so a PR that renamed a
#     procedure removed it from the watched set in the act of moving it.
#   * The two halves of the deletion test were **uncorrelated** greps: deleting
#     `scripts/old.sh` while editing any Finding reported "a Finding file was
#     deleted" when none had been.
#
# The diff is now parsed per file, and the standard set is enumerated from the
# BASE tree. A grep over a diff cannot answer "which file was this line in",
# and that question is the whole check.
#
# ── What this establishes ──────────────────────────────────────────────────
#
# That the two acts cannot ride in one diff.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - That the split PRs are honest. Land the standard change on Monday and the
#     retirement on Tuesday and this says nothing. What the split buys is two
#     independent reviews instead of one, because each PR passes the
#     consultation gate on its own. What it does NOT buy is any guarantee that
#     the pair is ever evaluated as a pair: Tuesday's diff is a bare state
#     flip, and the reason lives in Monday's. A reviewer named that precisely.
#     The next rung — requiring a retirement to cite the amendment that made
#     it obsolete — is filed, not built here.
#   - That the standard set is complete. It is a deny-list and will lag: the
#     Finding schema, `scripts/` (where half of this repository's standard is
#     executable), and `governance/` are outside it. Enumerating from the base
#     tree at least stops the set from shrinking under its own pull request.
#   - Anything about Findings in observed repositories. Recon does not write
#     those.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

_fr_base_ref() {
    if [ -n "${BASE_REF:-}" ]; then printf '%s' "$BASE_REF"; return 0; fi
    if [ -n "${GITHUB_BASE_REF:-}" ]; then printf 'origin/%s' "$GITHUB_BASE_REF"; return 0; fi
    printf 'origin/main'
}

check_finding_retirement() {
    local diff_out base standard_list
    if [ $# -ge 1 ]; then
        diff_out="$1"
        base=""
    else
        base="$(_fr_base_ref)"
        if ! git rev-parse --verify "$base" >/dev/null 2>&1; then
            echo "finding-retirement: cannot resolve $base — the check did not run" >&2
            echo "       A shallow clone must not look like a clean result." >&2
            return 2
        fi
        # Rename detection on, explicitly: without it a rename is a delete plus
        # an add, and telling those apart is the point below.
        diff_out="$(git diff -M "$base...HEAD" 2>/dev/null)"
    fi

    [ -z "$diff_out" ] && { echo "  no diff against the base"; return 0; }

    if [ -n "$base" ]; then
        standard_list="$(git ls-tree -r --name-only "$base" 2>/dev/null)"
    else
        standard_list=""
    fi

    printf '%s' "$diff_out" | STANDARD_LIST="$standard_list" python3 -c '
import os, re, sys

diff = sys.stdin.read()


def is_standard(path):
    """A file that defines what a Finding is measured against.

    By shape rather than by a list read from a tree: a list read from HEAD
    shrinks under the very PR being judged, and a list read from the base
    still has to answer questions about paths that are not in it.
    """
    if path in ("core/policy.json", "CLAUDE.md"):
        return True
    if path.startswith("procedures/") and path.endswith(".md"):
        return True
    if path.startswith("docs/"):
        low = path.lower()
        # Case-insensitive and version-agnostic: docs/ADR-7.md and
        # founding-package-v0.3.md must not escape a check whose subject is
        # people renaming things.
        if low.endswith(".md") and ("adr" in low or "founding-package" in low):
            return True
    return False


def is_finding(path):
    return path.startswith("findings/") and path.endswith(".json")


# ── parse the diff into per-file records ──────────────────────────────────
files = []
cur = None


def start(old, new):
    global cur
    cur = {"old": old, "new": new, "deleted": False, "renamed": False,
           "added": [], "plus_seen": False}
    files.append(cur)
    return cur


for line in diff.split("\n"):
    m = re.match(r"^diff --git a/(.*) b/(.*)$", line)
    if m:
        start(m.group(1), m.group(2))
        continue
    # A diff with no `diff --git` header — what a hand-written fixture looks
    # like, and what `git diff` never emits. The `plus_seen` flag is what makes
    # a second `+++ b/` start a NEW record instead of renaming the previous
    # one: without it, two files in a synthetic diff collapsed into one and
    # four tests of this check went green while checking nothing.
    if line.startswith("--- a/") and (cur is None or cur.get("plus_seen")):
        start(line[len("--- a/"):], line[len("--- a/"):])
        continue
    if line.startswith("+++ b/"):
        p = line[len("+++ b/"):]
        if cur is None or cur.get("plus_seen"):
            c = start(p, p)
            c["plus_seen"] = True
        else:
            cur["new"] = p
            cur["plus_seen"] = True
        continue
    if cur is None:
        continue
    if line.startswith("deleted file mode"):
        cur["deleted"] = True
    elif line.startswith("+++ /dev/null"):
        cur["deleted"] = True
    elif line.startswith("rename from "):
        cur["renamed"] = True
        cur["old"] = line[len("rename from "):]
    elif line.startswith("rename to "):
        cur["renamed"] = True
        cur["new"] = line[len("rename to "):]
    elif line.startswith("+") and not line.startswith("+++"):
        cur["added"].append(line[1:])

# ── (a) retirement, decided per file, never across files ──────────────────
retired = []
for f in files:
    if f["deleted"] and is_finding(f["old"]):
        retired.append("%s was deleted" % f["old"])
    elif f["renamed"] and is_finding(f["old"]) and not is_finding(f["new"]):
        retired.append("%s was moved out of findings/ (to %s)"
                       % (f["old"], f["new"]))
    elif is_finding(f["new"]) and not f["deleted"]:
        for a in f["added"]:
            if re.search(r"\"lifecycle_state\"\s*:\s*\"superseded\"", a):
                retired.append("%s moved to superseded" % f["new"])
                break

if not retired:
    print("  no Finding retired in this change")
    sys.exit(0)

# ── (b) the standard, touched in ANY way ──────────────────────────────────
moved = []
for f in files:
    if f["deleted"] and is_standard(f["old"]):
        moved.append("%s (deleted)" % f["old"])
    elif f["renamed"] and is_standard(f["old"]):
        moved.append("%s (renamed to %s)" % (f["old"], f["new"]))
    elif is_standard(f["new"]) and not f["deleted"]:
        moved.append("%s (modified)" % f["new"])
moved = sorted(set(moved))

if not moved:
    print("  %s, and no standard file moved with it" % "; ".join(retired))
    sys.exit(0)

sys.stderr.write(
    "FAIL — finding retirement: this change retires a Finding AND touches the\n"
    "       standard it was measured against, in one diff.\n")
for r in retired:
    sys.stderr.write("         retirement: %s\n" % r)
sys.stderr.write("         standard files touched:\n")
for m in moved:
    sys.stderr.write("           %s\n" % m)
sys.stderr.write(
    "       These are two acts. Split them: the standard change on its own,\n"
    "       then the retirement on its own, so that each is reviewed by\n"
    "       someone who was asked only that question.\n"
    "       See docs/self-remediation-adr.md, residual gap 2.\n")
sys.exit(1)
'
}
