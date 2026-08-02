<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Consultation — PR #155, round 2

**Reviewer:** Kimi K3 (`kimi-k3`), independent, cross-provider
**Provider:** Moonshot AI, direct API
**Response id:** `chatcmpl-6a6ef5d5f1ac6b519f50d288`

Seven of round 1's eight findings closed and traced. Two new ones, both of the
same class as the round-1 blocker — a comment claiming more than its code:

- a **registered** legacy round could be emptied of its verdict, because the
  check ran behind the register branch's `continue`, while the file promised
  it could not be. The nine files the register exists to protect were exactly
  the population the promise did not cover.
- the base-tree enumeration was computed, exported, and never read, while two
  comments credited it for a property that comes from shape matching.

Both fixed in the commit that follows this artifact. Superseded by the primary
(`155.md`), not withdrawn.

# Consultation — federation-recon PR #155, round 2

Mode: judging the corrected diff as written. The question per finding is not "did the author respond" — all eight were responded to — but "does the mechanism now exist in the code, and do the claims still exceed it."

---

## What is genuinely fixed, verified against the code

**§1(a) delete/rename holes — closed.** The Python parser builds per-file records from `diff --git` headers, applies `deleted file mode`, `+++ /dev/null`, and `rename from/to` to the record they belong to, and decides retirement and standard-movement per file. I traced all three attacks from round 1 through it: deleted standard (`deleted` + `is_standard(old)` → moved), renamed standard (`renamed` + `is_standard(old)` → moved), Finding renamed out of `findings/` (`renamed` + `is_finding(old)` + `¬is_finding(new)` → retired). The rename-with-edits case does not split the record, because `--- a/` only starts a new record when `plus_seen` is set, and `rename to` has already run by then. The fixtures are now shaped like real `git diff -M` output and the tests assert the specific failures. This is a mechanism, not a description of one.

**§2 list completeness — adequately addressed for what round 1 asked.** Round 1's blocking items were the delete hole and the shallow-clone comment, not the list. Shape matching (case-insensitive `adr`, version-agnostic `founding-package`) closes the two enumerated escapes, tree-independence closes the self-shrinking realization, and the residual — schema, `scripts/`, `governance/` outside the set — is now stated in the NOT-establish section rather than implied away.

**§3 base ref — fixed.** `_fr_base_ref` honors `BASE_REF`/`GITHUB_BASE_REF`, `ci-checks.sh` exports `BASE_REF` at gate 6, three gates before the consumer, and rc=2 fails the build. Tested.

**§4(b) shallow clone — fixed, and this one I checked hardest, because it was blocking.** `--is-shallow-repository` is the test the comment always described, shallow is now rc=1 rather than a note, and the test builds an actual `git clone --depth 1` and asserts the failure. The safeguard now exists.

**§4(c) rename-away + register presence — partially fixed.** `--diff-filter=DR` with `--name-status` and `awk '{print $2}'` on R-records names the *old* path, which is the one that disappeared; the comment's explanation of why `--name-only` was wrong is correct. Section 5 verifies register entries exist on disk. Both tested. Partially — see the blocking finding below.

**§4(a) rebase erasure — the agreed remedy was candor, and the candor is present.** The NOT-establish section now names rebase-and-force-push as the primary realization of the threat, names the two real anchors, and states neither is done. Round 1 did not ask for a mechanism here; it asked that the list stop implying one.

**Monday/Tuesday overclaim — corrected.** The ADR now says precisely "two independent reviews instead of one," states that nothing links the pair, and names the citation rung as filed-not-built. One residual tension: the earlier paragraph still says the retirement PR "says, on its own, that a Finding is being retired because a standard moved," which the correction paragraph two below contradicts. The correction is explicit and proximate, so this is tolerable — but the first paragraph is the one a skimmer reads.

**#5, #6, #7, #8 — closed.** Correlation is per-file with a test; superseded detection is path-scoped with a test; `seen_primary_for` is gone; the #150 account is internally consistent with the register's stated purpose and the live-tree test will enforce it.

## Blocking: the register path skips the verdict check, and the establishes-list says it doesn't

Round 1 §4(c) was the finding that the legacy-round protection had a one-command bypass. The remediation closed delete, rename, and presence — and left the *content* rule unenforced for exactly the register population. Section 3:

```
pr="$(_cr_pr_of "$base")"
if [ -n "$pr" ] && [ ! -f "$dir/$pr.md" ]; then
    if [ ! -f "$register" ] || ! awk ... ; then FAIL; fi
    continue          # ← registered legacy rounds exit here
fi
# verdict-presence check — never runs for them
```

All nine files in `ROUNDS-LEGACY` have no primary by the register's own definition, so all nine take the `continue`. Trace the attack: a PR rewrites `131-sol-round3.md` to a one-line stub — or an empty file. Section 1–2: no primary exists, unaffected. Section 3: registered, `continue`. Section 4: a content edit is neither D nor R, silent. Section 5: the file exists. Inventory non-empty, rc=0. **Gate 8 green.**

The file's own "What this establishes" claims "A round file cannot be emptied of its verdict," and the NOT-establish section claims "Truncation to nothing is caught." For the nine files the register exists to protect — the headline population of round 1 §4(c) — neither is true. The bolded-prose verdict grammar even exists, per its own comment, to accept what "several pre-convention rounds use" — and the code path for registered rounds never reaches it. The convention's one rule is "never deleted and never shortened"; deletion and renaming are now checked, and shortening-with-verdict-removed passes for precisely the files that motivated the register.

The fix is small: run the verdict check before the register branch (every registered round carries a verdict; the live-tree test will confirm), or strike the two claims. Per the standard applied in round 1 — a safeguard whose prose contradicts its code is blocking — this blocks. It is not a new line of hardening; it is the unfinished half of §4(c), wearing the same claim/code mismatch as round 1's blocking #2.

## Required nit: the dead base-tree enumeration, and two sentences that misattribute the mechanism

`standard_list="$(git ls-tree -r --name-only "$base")"` is computed, exported into the Python process as `STANDARD_LIST`, and **never read** — `is_standard` is shape-only, and `import os` is unused. That is survivable. What is not, in this repository, is that the header says "the standard set is enumerated from the BASE tree" and the NOT-establish section says "Enumerating from the base tree at least stops the set from shrinking" — the non-shrinking property is real, but it comes from shape matching, and nothing is enumerated from anything. Round 1 finding #7 was a dead variable; the fix deleted it and grew a dead pipeline with two false provenance sentences. Delete the `ls-tree`, the env var, and the import, and make the sentences say "matched by shape." Five minutes.

## Residuals, noted and explicitly not blocking

- The `--- a/` fixture branch fires on any *content* line beginning `-- a/` once `plus_seen` is set, which would misattribute subsequent added lines to a spurious record. Exploiting it against the Finding half requires a line starting `-- a/` at column 0 of a strictly-validated JSON file, so it is not reachable in-repo today. The standard half is immune because it never reads added lines. Parsing diff headers means owning the whole grammar; this is the remaining un-owned corner.
- The `diff --git a/(.*) b/(.*)` regex is greedy and misparses paths containing spaces; the `rename from/to` headers rescue renames, and finding filenames are constrained by strict validation. A `diff.noprefix` config would break the parser entirely, but no version-controlled vector sets it for CI.

## Summary

Seven of eight round-1 findings are closed with mechanisms I traced and tests that assert the right failures; the eighth (rebase) got the candor that was the agreed remedy. But the register population — the files round 1 §4(c) made the headline — can still be gutted to a stub in one PR while the establishes-list claims they cannot be emptied, and the retirement check carries a dead enumeration its comments credit for a property it does not produce. Same class, same standard, one more round — a short one.

verdict: REJECT
