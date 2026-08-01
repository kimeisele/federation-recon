<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Review — PR #150, the constitutional amendment

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Response id | `chatcmpl-6a6e260dac226c03a4e1a2b6` |
| Tokens | prompt 6011, completion 7326 |
| Mode | **diff mode — the reviewer executed nothing** |

**Requested despite an owner waiver.** The owner approved this PR without a
cross-provider review, on the grounds that it records a decision already made.
The consultation gate blocked the merge anyway, and switching the gate off is a
change to a machine guardrail — the OWNER-ONLY class. One review at roughly two
cents was cheaper than touching the control, so the control was left alone.

**It was worth the two cents.** The reviewer found that §5.1 asserted the
execution layer was being extracted, which is the opposite of the decision the
owner had made an hour earlier. The constitution was about to record a decision
that was declined.

## What was changed in response

| finding | disposition |
|---|---|
| §5.1 asserts an extraction that was declined | **fixed** — the section now records that the layer stays and names the import-boundary check (#151) as the compensating control |
| §5.1 is a widening, not a clarification | **fixed** — relabelled as a widening, with the reviewer's reasoning quoted |
| the carve-out contradicts orphan reconciliation | **recorded** — the contradiction is written into §5.1 rather than smoothed over; settling it is a separate act |
| `check_amendment_log` bypass: filename outside `*adr*.md` | **fixed** — every `.md` under `docs/` is now inventoried |
| bypass: unbolded `Status:` skipped in silence | **fixed** — this was the worst of the three; an accepted ADR would have passed CI by not being bold |
| bypass: a prose mention satisfies the grep | **fixed** — the path must appear in a table row |
| "the gap is now closed" overclaims | **fixed** — the note now states what remains open by design |
| split the PR into recording and settlement | **owner decision, not taken here** |

---

# Adversarial Review — federation-recon amendment PR

## 1. §5.1: clarification or widening? — WIDENING, and the PR's own test proves it

The PR offers one piece of evidence for "clarification": §5.1 forbids something previously arguable (Recon merging its own builder's patch). That test is non-dispositive. A change that narrows one point and widens another is not a clarification; it is a mixed amendment, and the net is what matters. The permitted column newly legitimates building, sandboxed execution of a builder against an order, patch production, and process supervision (lifecycle, limits, reaping, orphan reconciliation). Not one of those was clearly permitted before — by the PR's own admission, an external reviewer asked which invariant permits process supervision and "the honest answer required looking." If the boundary had been there to clarify, there would have been nothing to look for.

The kill shot is internal. The amendments.md note calls amendment 2 "the largest change of direction since founding." §5.1 constitutionalizes amendment 2. A change of direction is not a clarification of an existing heading. The PR wants it both ways: amendment 2 must be enormous (to magnify the logging failure and justify `check_amendment_log`), and §5.1 must be weightless (to avoid the adoption burden of a widening). It cannot have both. Note also the tell in row 3: "made decidable." Making decidable is legislation. A clarification discovers a line that existed; this one stipulates a line — "whose repository the effect lands in" — that appears nowhere in the prior text. Where nothing was decidable, there was no boundary to clarify; drawing one that permits a capability is a widening relative to the prior undecided state.

Methodologically, §5.1 and the FR-CON-002 carve-out use the same move in opposite directions: "everything violates the literal reading" is used in §5 to dissolve the literal reading, and in FR-CON-002 to dissolve the plain sentence. A constitution reinterpreted wherever it is inconvenient is not being interpreted; it is being drafted around.

## 2. The FR-CON-002 carve-out: the line collapses, and §5.1 collapses it

The offered distinction is *remediation* vs *modification*, enforced by artifact type: a Finding about federation-recon may not be acted on; the same defect noticed any other way may be fixed as maintenance. That line discriminates by which file the observation was recorded in, not by effect. Route the observation through a non-Finding channel and remediation becomes maintenance. An invariant that is gameable by choosing the paperwork is collapsed in practice.

Worse, the carve-out is contradicted inside the same diff. The carve-out says Recon "may not heal itself in response to its own observations." §5.1 expressly permits supervision including "orphan reconciliation." A crashed builder leaves orphans; the supervisor detects them (its own observation) and reaps them (healing its own operation). That is self-remediation in response to self-observation by any ordinary reading — permitted by §5.1, prohibited by the carve-out, two sections apart. And the clean reductio in the other direction: the census finds federation-recon's sandbox permits egress and records it as a Finding; the fix PR is now constitutionally prohibited — so it will be relabeled "maintenance," and the line dissolves on contact with the first security defect. The rationale given ("a node that repairs what it reports has no independent record") supports a narrow rule — never alter or act to suppress the *record* of a Finding — but the text enacted is a broad one ("never as remediation of one of its own Findings"), and the broad text is what will be litigated later.

## 3. `check_amendment_log`: real for the precedent, theatre for the principle

The check is honest about its limits — unusually so — and it genuinely would have caught the historical failure. But three defeats, each sufficient alone:

1. **Filename.** The finder is `find "$docs_dir" -type f -name '*adr*.md'`. Accept the next ADR as `docs/decisions/003-execution-layer.md` or `docs/rfcs/…` and it never enters the inventory. Other ADRs exist, so `found > 0`, no rc=2, CI green, nothing recorded. The check guards the door it counted as a door and leaves uncounted doors unwatched — the exact failure mode the PR's own note moralizes about.
2. **Status-line format.** `_adr_status` requires the line to begin with `**Status`. Plain `Status: Accepted` — a common ADR format — makes `_adr_status` return 1, and the loop does `|| continue`: the ADR is *silently skipped*, not flagged. The tests cover lowercase and unbolded values but never an unbolded label. A check whose verdict depends on markdown bolding is a style lint with a governance budget.
3. **Mention, not entry.** The match is `grep -Fq "$rel" "$log"` anywhere in the file. A prose footnote — "see docs/foo-adr.md, still under review" — satisfies the check with no table row, no date, no PR, no countability. The check cannot distinguish an entry from a mention, and its own header concedes the vacuous-entry variant.

So when amendments.md claims "the gap is now closed by more than intent," that overclaims. Closed for accepted ADRs named `*adr*.md` with bolded status lines. And note the largest category is untouched by design: edits to CLAUDE.md and the founding package — such as §5.1 itself — remain log-by-memory. This very PR would pass the check it adds even if row 3 were deleted. A check that would not catch its own PR is a partial control being sold as closure.

## 4. What does not belong in this PR

**The false decision record.** §5.1's closing paragraph states the section was "adopted alongside a decision to move the execution layer out of this repository entirely (#148)," and frames the clause as transitional — "once it is out, this section governs a capability Recon no longer holds." The owner's decision was the opposite: no extraction; the layer stays, guarded by an import-boundary CI check. The constitution is being amended to assert a decision that was not made, and the asserted future removal does rhetorical work — it makes the capability palatable *now* by promising its abolition later. That is not documenting a decision already made; it is documenting a decision declined. And the compensating control that decision (a) actually names — the CI check forbidding cross-boundary imports — appears nowhere in this diff. Prose describing a mechanism is not evidence the mechanism exists. The widening takes effect on merge; the guard is a rumor.

**The substantive settlement of #148.** The PR's legitimate core is one table row and a CI check. Bundled into it is amendment 3: a new constitutional test ("whose repository the effect lands in"), a permitted-capabilities table, and an invariant carve-out — i.e., the definitive settlement of the open question the external reviewer raised. Recording a prior amendment and answering the question that amendment provoked are different constitutional acts with different adoption burdens. The PR condemns #53 for walking a constitutional change "through a door nobody was watching," then walks a constitutional settlement through a door labeled "late logging fix."

**The modeled laxity.** Row 3 enters the log with consultation "pending — see PR." Owner approval per context (b) may make that permissible, but a PR whose entire moral is that constitutional machinery must not run on memory and good intentions adopts its own amendment with its own machinery incomplete, one column over from the column it polices.

Minor and acceptable: the MANIFEST comment reshuffle is cosmetic churn; the 1/6→1/7 renumbering is necessary; the amendments.md post-mortem is good faith and mostly belongs, minus the overclaim noted above.

## Summary

- Q1: Widening, by the PR's own internal contradiction (§1).
- Q2: The line collapses — on orphan reconciliation inside this very diff, and on the first security Finding (§2).
- Q3: Real for the exact historical failure, theatre for the principle; bypassable by filename, by an unbolded status line, or by mentioning the path instead of entering it (§3).
- Q4: The constitution asserts an extraction decision that was not made; the import-boundary guard that was decided is absent; and a substantive settlement of #148 rides inside a recording PR (§4).

The fix is a split: (A) the late row for amendment 2 plus the check with its three bypasses closed — approvable on its own; (B) §5.1 and the carve-out resubmitted, honestly labeled as a widening, with the extraction paragraph corrected or struck and the import-boundary check actually implemented. As one PR, the recording is right and everything built on top of it is either false, unproven, or self-exemplifying of the failure it condemns.

verdict: REJECT
