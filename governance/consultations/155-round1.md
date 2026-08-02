<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Consultation — PR #155, round 1

**Reviewer:** Kimi K3 (`kimi-k3`), independent, cross-provider
**Provider:** Moonshot AI, direct API
**Response id:** `chatcmpl-6a6eebbf4a9ebb58963bcbbf`

Eight findings, two blocking, all against the first version of both checks.
Superseded by round 2, not withdrawn — this is the round that found four
holes in `check_finding_retirement` in a single pass, and every one of them
was the same mistake.

# Consultation — self-remediation gap closure (check_finding_retirement, check_consultation_rounds)

Mode: judging the diff as written. The question is never "is this better than prose" — it is — but "does the mechanism do what its own comments claim."

---

## 1. Does check_finding_retirement close the laundering route?

**No. It closes one grammatical form of it — modify — and is blind to delete and rename, in the same single diff, no Monday/Tuesday required.**

The standard-side detector enumerates files from the PR's *own tree at HEAD* (`find procedures ...` runs in the checkout) and matches only `+++ b/<path>` headers. Two consequences:

**(a) Delete the standard, retire the Finding, one PR — green.**

```
deleted file mode 100644
--- a/procedures/consumption-v1.md
+++ /dev/null
+++ b/findings/f-1.json
+  "lifecycle_state": "superseded"
```

Retirement fires. Standard-moved does not: the deleted file no longer exists at HEAD so `_fr_standard_files` never lists it, and even if it did, the diff's added-side header is `+++ /dev/null`. The referent isn't amended, it's abolished — the maximal benchmark move — and the check passes. This violates the rule as the file itself states it ("(b) modify a file that defines what a Finding is measured against"; deletion is a modification).

**(b) Rename the Finding out of `findings/` — invisible.** With rename detection on by default, a pure rename emits `similarity index` / `rename from` / `rename to` and *no* `deleted file mode`, no `--- a/`, no `+++ b/` lines at all. `git mv findings/f-1.json attic/f-1.json` plus any standard edit, one diff: neither detector sees anything. The record survives unaltered — the ADR's letter is honored — and it is gone from everything that enumerates `findings/`. A rename *with* edits fares no better: it emits `--- a/findings/f-1.json` but no `deleted file mode`, and your deletion branch requires both.

The watched set is also self-shrinking: because the list is built from HEAD, a PR that renames `procedures/x.md` to `notes/x.md` removes it from the benchmark set in the act of moving it. The enumeration must come from the *base* tree (`git ls-tree "$BASE_REF"`), and the matcher must handle `--- a/`, `/dev/null`, and `rename from/to` headers. Parsing diff headers means owning the whole header grammar.

## 2. Is the standard-file list the right set?

Incomplete in ways that matter:

- **The Finding schema.** Wherever the lifecycle vocabulary and severity rubric are defined, amending *it* redefines what `superseded` and `observed` mean. Not watched.
- **The executable benchmark.** `scripts/lib/*.sh`, `scripts/validate-artifacts.sh`, the workflows. In this repository half the standard is code that verifies the standard; a Finding operationalized by a validator can be laundered by editing the validator, not `policy.json`. `scripts/` is entirely absent.
- **`governance/`** (for governance-measured Findings) and **`docs/repository-manifest.md`** (for inventory-measured Findings).
- The three literals don't auto-discover: `founding-package-v0.3.md` and a new uppercase `docs/ADR-*.md` (the find is case-sensitive) escape silently.

Deny-listing "the standard" will always lag; that makes (1a) worse, because the list is both incomplete and enumerated from the wrong tree.

## 3. Monday/Tuesday: admitted — enough, or theatre?

Not theatre, but oversold by its own justification. Two things are true at once:

- Each split PR passes the consultation gate independently, so the split genuinely buys two external reviews. That is the real mechanism, and it keeps the check honest.
- But the ADR's claim — "the retirement PR stands on its own and says, on its own, that a Finding is being retired because a standard moved" — is not what the Tuesday diff contains. Tuesday's diff contains a bare state flip; the causal claim lives in Monday's PR, and nothing mechanically links them. **The check guarantees the acts are separated; nothing guarantees the pair is ever evaluated as a pair.** That is the precise residual, and the ADR's candor section, which names subtler limits, does not name it.

A mechanical rung exists and is cheap: require a retirement diff to add a `superseded_by`/reason field citing a commit or amendment-log entry, and grep for it. Not blocking this round; blocking that the ADR's prose currently claims more visibility than the diff provides.

## 4. Can a reviewer still be outlasted?

**Yes, three ways.**

**(a) Rebase erasure — the primary realization of the named threat.** The deletion check reads history, but rounds for an unmerged PR exist only in that PR's branch, and an unmerged branch's history is the author's to rewrite. Run three rounds, `git rebase -i`, drop the commits that added rounds 1–2, force-push: no addition events, no deletion events, working tree consistent, all four sections green. The threat the convention names is "run rounds until one approves, then quietly drop the ones that did not" — and the check's "What it does NOT establish" list, which is otherwise admirably candid, does not state that history-of-a-rebasable-branch is not evidence. The only real anchor is rounds entering `main`'s history individually, or cross-checking against the consult provenance log (which exists — `consult-provenance.bats` — and is not wired in).

**(b) Shallow clone — the comment claims a safeguard the code does not contain.** The comment says the deletion check is "skipped when there is no history to read (a shallow clone), and skipping is announced rather than silent." The code tests `git rev-parse --git-dir`, which *succeeds* in a shallow clone. Under `fetch-depth: 1`, §4 examines one commit, finds nothing, prints OK, no note. The announced safeguard does not exist; `git rev-parse --is-shallow-repository` is the test the comment describes.

**(c) Rename-away of legacy rounds.** `git log --diff-filter=D` reports renames as R, not D. Rename `131-sol-round3.md` to `131-sol-part3.md`: the old path never appears as a deletion, the new file matches neither `_cr_is_round` nor anything else, and — the compounding defect — **nothing verifies that ROUNDS-LEGACY entries still exist on disk.** The register is matched literally for *existing* orphan files, but presence is never checked. The headline protection for pre-convention rounds has a one-command bypass.

## 5. Wrong, rather than incomplete

1. §1(a) above — standard-file deletion in the combined diff passes; contradicts the check's own stated rule. **Blocking.**
2. §4(b) — shallow-clone comment contradicts code on the anti-outlasting feature. **Blocking** (this repository fails builds for exactly this class of claim).
3. `check_finding_retirement` hardcodes `origin/main` while `ci-checks.sh` computes and exports `BASE_REF`/`GITHUB_BASE_REF` four gates earlier for the same purpose. A PR targeting a non-main base gets an ancient merge-base: every standard change since branchpoint plus any retirement → false FAIL, or rc=2 red. Use the exported base.
4. Register entries never verified present (§4(c)).
5. The deletion conjunction is two un-correlated global greps: delete `scripts/old.sh` while *modifying* any finding, and the check reports "a Finding file was deleted" when none was. Fail-closed, but misreporting.
6. Superseded-line detection is not path-scoped to `findings/` — a fixture or doc example adding `"lifecycle_state": "superseded"` counts as a retirement. Same direction, same sloppiness.
7. Dead variable: `seen_primary_for` is assigned and never read.
8. Unanswered question: the register cites PR #150 as the motivating case, and #150 appears nowhere in the register or any primary's link list. Where do its two rounds live, and what does the merge gate read for it today?

---

The fail-closed rc=2 posture, the literal register matching, the refusal to pass on an empty inventory, and the test suite — including the live-tree test and the deletion-from-history test — are all the right instincts, well executed. But this PR's claim is that a named gap is closed *mechanically*, and the delete and rename realizations of that exact move pass inside a single diff, while the anti-outlasting check's shallow-clone safeguard is prose its own code contradicts. Per the standard this repository holds others to: the mechanism must exist, not be described. One more round.

verdict: REJECT
