<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Review — PR #142, round 3

| | |
|---|---|
| `model` field in the response | `kimi-k3` |
| Response id | `chatcmpl-6a6e2705c6a3424af998b8ab` |
| Tokens | prompt 2635, completion 13639 |

## Operator note, before the review: the diff sent was wrong

**The rulings on C1, C3 and C4 below are void, and the fault is the
operator's.** The prompt carried `git diff HEAD~2 HEAD -- core/orders/`, which
is the freeze comment alone. The mechanisms the reviewer looked for — the
seven-category predicate, the CONTRACT.md sentence on `location`, vectors
47–55 — all landed in `ec2743d`, one commit earlier, and were not in front of
it. The reviewer judged what it was shown and judged it correctly: a comment
block is not a mechanism.

It is recorded rather than re-run because the owner froze this guard after
round 3. Re-dispatching with the right diff would be a fourth round on a
comparison of two strings the contract calls advisory.

**Section 3 survives the mistake**, because it rules on the banner text rather
than on the missing hunks, and two of its three findings were real:

- *"seven stripped categories, each one carrying its own vector"* — false by
  this PR's own mutation table. Cc has no guard-reaching vector; vector 55 dies
  at `E_SCHEMA` upstream. Corrected to six, with Cc's disclosure kept.
- *"Four rounds of adversarial review"* six lines above *"Three rounds"* — a
  self-contradiction inside a comment that was about to be frozen permanently.
  Corrected.

Its third finding (the advisory-documentation premise) falls with the diff:
that sentence is in `ec2743d`.

---

# Review — PR #142, round 3 (final): C1, C3, C4, and the freeze

The governing rule is unchanged from round 2: a condition closes only if the diff shows the mechanism. The hunk presented is `@@ -453,6 +453,35 @@` — 6 old lines, 35 new, i.e. 29 added lines. Every added line begins with `#`. The three trailing context lines (`Removed as a CLASS…`) confirm the hunk is complete: nothing below it was cut off. **The entire response to three open conditions is a comment block.** There is no code hunk, no CONTRACT.md hunk, no manifest or vector file. That decides most of what follows.

## 1. C1, C3, C4

**C1 — OPEN.** The last predicate actually shown in this review (round 2 diff) is:

```python
unicodedata.category(c) not in ('Cf','Cc','Mn')   # after unicodedata.normalize('NFKD', value)
```

No hunk in this diff touches it. The seven-category set exists in two places: the operator note, and the banner's prose ("seven stripped categories"). Round 2 already ruled on this exact evidence class — its operator note said "Fixed in `ec2743d`; every stripped category is now mutation-tested individually," and C1 stood OPEN because the *shown code* contained the holes. This round offers the same class of evidence and strictly less code. If the predicate is the round-2 one, the bypasses that ship are precisely the named ones: `"deep\u2004seek"` → NFKD → `"deep seek"` (U+2004 has `<compat> 0020`, U+0020 is Zs, unstripped) → ADMITTED; `"deep\u00A0seek"` → same path → ADMITTED; `"deep\u2028seek"` (Zl) and `"deep\u2029seek"` (Zp), no decomposition, survive → ADMITTED; `"deep\u20DDseek"` (Me, no decomposition) survives → ADMITTED. The mutation map (Cf→37,50–53; Mn→41; Me→48; Zs→47; Zl→49; Zp→54) is a description of tests, not tests.

**C3 — OPEN.** The owed artifact was one sentence in CONTRACT.md §5: `location` existence is never verified; a passing location may name nothing. This diff contains no CONTRACT.md hunk at all. There is nothing to rule on but an absence, again.

**C4 — OPEN.** No manifest entries, no vector files; vectors 47–55 exist only as prose. Two deficits hold even taking the prose at face value: (i) the five §2 insertions were required *regardless* — the map accounts for four Cf vectors (50–53) and pins Mn only with 41, the pre-existing U+0301 ordering vector; as tabulated, no vector carries U+034F; (ii) by the submission's own table, Cc has no guard-reaching vector (55 returns E_SCHEMA at the schema layer), so "every stripped category is mutation-tested individually" is not achieved even as narrated.

## 2. The freeze

**Defensible as a scope rule; not defensible as the mechanism that closes this round.** The structural claim is correct: a category refuse-list over an open repertoire cannot be closed — residual classes exist under any finite strip set, and Unicode version drift guarantees the list is permanently behind. Against an advisory string whose real control is signed attestation (#141), unbounded rounds on one comparison are a misallocation, and naming the residual holes (homoglyphs, transliteration) in a permanent comment is the honest way to stop. Nothing about the freeze *policy* must not ship.

But the freeze's own text scopes itself to "a **newly discovered** codepoint class." Zs, Zl, Zp, and Me were discovered in rounds 1–2, named, and reproduced by the operator. They are pre-freeze debt, and the freeze does not cover them by its own terms — they must land as shown code in this PR. Second, the freeze's load-bearing premise — "strings that the architecture already documents as advisory" — is precisely the artifact C3 found missing for the location sibling. A freeze invoked over unfixed named bypasses, resting on documentation the PR does not contain, is not a scope decision; it is a relabeling of three open conditions as closed.

## 3. Wrong, not incomplete

1. **"seven stripped categories, each one carrying its own vector"** — false by the PR's own mutation table: `Cc -> none` (vector 55 dies at E_SCHEMA before the guard). Round 2 accepted disclosed-unreachability as honesty; the banner chose to overclaim instead. The sentence should say six categories carry guard-reaching vectors and Cc is enforced upstream, disclosed. Fix the sentence, not the tests.
2. **"the architecture already documents as advisory"** — asserted as fact while the one contract sentence this PR owes (C3) is absent. The freeze's premise cites documentation this diff does not contain.
3. **The banner contradicts itself on the review history**: "Four rounds of adversarial review" six lines above "Three rounds of this repository's attention." The record in front of me shows three. Minor, but this is a frozen permanent comment.

Round 2 rejected a submission that showed flawed mechanism. This round shows no mechanism and a governance artifact asserting the work is done. The conditions stand exactly where round 2 left them.

verdict: REJECT
