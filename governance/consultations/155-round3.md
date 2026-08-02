<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Consultation — PR #155, round 3

**Reviewer:** Kimi K3 (`kimi-k3`), independent, cross-provider
**Provider:** Moonshot AI, direct API
**Response id:** `chatcmpl-6a6eff4090dcb0303fad0824`

**This round rejected code that had already been fixed, and it was right to.**
The two fixes were written, tested and gated, and then the diff was taken from
`HEAD` while they sat uncommitted in the working tree. The reviewer judged
round-2 code against round-3 release notes.

> "the submitted diff contains neither the code changes nor the tests cited as
> their evidence, while the cover note asserts both, with named tests. That is
> the precise failure class this repository exists to catch, applied one level
> up: prose claiming a mechanism the artifact does not contain."

Second time in one day that a review was dispatched against a diff that did not
contain the work — #142 round 3 was `git diff HEAD~2 HEAD`, this was
uncommitted. Kept whole, because the operator error it records is the point.

# Consultation — federation-recon PR #155, round 3

Mode: judging the submitted diff as written. The two round-2 findings concern four files — `scripts/lib/consultation-rounds.sh`, `scripts/lib/finding-retirement.sh`, and their two test files — and all four are new files in this diff, shown in their entirety. Absence is therefore verifiable, not an artifact of truncation.

**Neither fix is in the diff.** The four files are, line for line, the round-2 versions. The cover note describes changes the code does not contain.

---

## Finding 1 — the register branch still skips the verdict check: NOT FIXED

Section 3 of `consultation-rounds.sh`, as submitted:

```bash
        pr="$(_cr_pr_of "$base")"
        if [ -n "$pr" ] && [ ! -f "$dir/$pr.md" ]; then
            if [ ! -f "$register" ] || ! awk ... ; then FAIL; fi
            continue          # ← still here, still first
        fi
        # Two grammars are accepted...
        if ! grep -qE '^verdict: (APPROVE|REJECT)$' "$f" \
           && ! grep -qiE '...' "$f"; then
```

The `continue` still precedes the verdict check. The verdict check was not moved. This is the exact structure round 2 quoted as blocking. All nine `ROUNDS-LEGACY` files still take the `continue`, and a PR that rewrites `131-sol-round3.md` to a stub still passes: section 3 registers and continues, section 4 sees a content edit (neither D nor R), section 5 finds the file on disk. rc=0.

Nor were the claims struck, which was the offered alternative. The header still asserts, unqualified: "A round file cannot be emptied of its verdict." The NOT-establish section still says "Truncation to nothing is caught."

The cited regression test — "a REGISTERED round emptied of its verdict still fails" — **does not exist** in `consultation-rounds.bats`. The nearest test, `rounds: a round emptied of its verdict fails`, calls `_primary 9 ...`, giving the round a primary, so it never enters the register branch — it exercises the post-convention path only. And the tell: had the claimed test been added against this code, it would fail, because the registered path never reaches the verdict grep. The test's absence and the code's state are consistent with each other and inconsistent with the cover note.

## Finding 2 — the dead base-tree enumeration: NOT FIXED

`finding-retirement.sh`, as submitted:

```bash
    if [ -n "$base" ]; then
        standard_list="$(git ls-tree -r --name-only "$base" 2>/dev/null)"
    ...
    printf '%s' "$diff_out" | STANDARD_LIST="$standard_list" python3 -c '
import os, re, sys
```

`standard_list` is still computed, still exported, and still never read — the Python body contains no reference to `STANDARD_LIST` or `os.environ`, and `is_standard` remains shape-only. `import os` is still unused. The header still says "the standard set is enumerated from the BASE tree," and the NOT-establish section still says "Enumerating from the base tree at least stops the set from shrinking under its own pull request" — the two false-provenance sentences, both intact. The claimed test asserting that neither `STANDARD_LIST` nor `ls-tree` appears in the file is absent from `finding-retirement.bats` — and again, had it been added, it would fail on this diff, since both strings are present.

## Item 3 (non-blocking) — also not present

The `--- a/` residual is not named in finding-retirement.sh's NOT-establish section, which still lists exactly three items (split-PR honesty, deny-list completeness, observed repositories). This was explicitly non-blocking in round 2 and remains so; I note it only because the cover note claims it was done, and it was not.

## What this round is

Round 2 ended with two required changes, both small. The submitted diff contains neither the code changes nor the tests cited as their evidence, while the cover note asserts both, with named tests. That is the precise failure class this repository exists to catch, applied one level up: prose claiming a mechanism the artifact does not contain. The convention's own sentence for it is in this very diff — a safeguard whose prose contradicts its code is blocking. A review response is not exempt.

Possibility noted for fairness: the wrong diff may have been attached and the fixes may exist somewhere. I can only judge what was submitted, and what was submitted is the round-2 code with round-3 release notes. If the fixes exist, resubmit the diff that contains them; the review of that diff should take minutes, since both remedies were specified exactly.

Seven of round 1's eight findings remain closed and I am not reopening them. The two round-2 findings — the register population gutted-to-a-stub bypass while the establishes-list denies it, and the dead enumeration credited for a property shape matching produces — are open, unaddressed, and each is a five-minute fix. Third rejection, same two findings, verified against the code rather than the cover note.

verdict: REJECT
