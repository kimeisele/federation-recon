<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Consultation — the self-remediation ADR (amendment 4)

**Reviewer:** Kimi K3 (`kimi-k3`), independent, cross-provider
**Provider:** Moonshot AI, `https://api.moonshot.ai/v1/chat/completions`, direct API
**Response id:** `chatcmpl-6a6e3edcb9dc52abf5149d20` · tokens 2356 / 14085

The same reviewer that found the contradiction in #150 and supplied the
reductio any resolution had to answer. Verdict **APPROVE**, with defects it
called corrigible without reversing the decision. All seven were taken:

| finding | disposition |
|---|---|
| §4.2's gloss "the exempt set is precisely the set that is not committed" is **false**, and sits inside the operative grant | **fixed** — the argument runs one way only; the exempt set is the enumeration and grows only by amendment |
| the actor is never named: who opens the fix PR? | **fixed** — the operator does, through the protected path; advancing the Finding's lifecycle is a separate act and not permitted here |
| a second residual gap: baseline-amendment laundering — keep the world, change the standard | **added**, and bounded only by the amendment log, which is said to be weaker than a prohibition |
| "§5.1 already draws **exactly** this line" overclaims | **fixed** — same kind of test, new axis: §5.1's is two-way, this is three-way |
| (b) is tilted: the hybrid (b)+narrowing is never weighed | **fixed** — the matrix is exemption × narrowing; the narrowing is required in every surviving quadrant |
| "each reconcile becomes a governance event" is false | **fixed** — only reconciles that *find* an orphan; the rate is the crash rate, which is #134's rate |
| Status Accepted while under review | **answered in the header** — accepted on the owner's instruction and on this review, which the earlier revision lacked |
| the diff shown was empty; the strike of the old carve-out must be visible | **the diff below is the committed one**; the old sentence is struck, not left standing beside the new text |

Its closing note is worth keeping verbatim, because it is the standard this
repository is trying to meet:

> I note for the record that this document disclosed enough against its own
> interest for me to catch its overclaims; that is the behavior this repository
> exists to reward, and it is the only reason the overclaims are survivable.

---

# Review of ADR: Self-remediation — what Recon may repair about itself

## 1. Does it answer the reductio?

Yes, and I want to be precise about *why*, because the answer is structural rather than rhetorical. My reductio had an engine: the constitution prohibited the *needed* act (the fix PR), so pressure built to launder it as a permitted one ("maintenance"). The adopted text defuses the engine rather than relabeling it:

- The needed act is un-banned. Point 3 permits fixing the defect and routes it through the protected PR path (point 2), so there is nothing left to launder.
- The laundering label is simultaneously shrunk. Point 1 confines "maintenance" to an enumerated set of uncommitted bookkeeping, so "maintenance" cannot stretch to cover a content fix. The route is closed from both ends.
- It is stronger than my objection strictly required: "lifecycle state" is newly protected. Old FR-CON-002 said nothing about lifecycle; the amendment forbids Recon from even transitioning its own Finding to "fixed." The reductio's escape hatch is not merely closed — it is bricked over.

One hole in the answer, and it is in the decision text: **the actor is never named.** FR-CON-002 as quoted bars Recon from "open[ing] remediation pull requests." Point 3 says fixing "is permitted" and "goes through the protected PR path" — but who opens the PR? If the owner, the ADR quietly reintroduces option (b)'s per-event owner cost at exactly the security seam it was rejected for. If Recon's executor, then the PR clause has been amended for the self case and the ADR should say so in words. Silence here is an ambiguity, and ambiguity in a constitution is a gap. Not fatal — the protected path gates either way — but it must be pinned.

## 2. Is "runtime state" mechanically bounded?

Partially, and the document's own gloss on the bound is wrong in the exploitable direction.

There are three bounds on offer. The enumeration in point 1 (normative, not mechanical — the ADR concedes the path-list-in-code is future work). The `layer-boundary.bats` check — mechanical, but it is a *literal-reference tripwire*: it catches `core/` growing a reference toward the artifact tree, and cannot see a computed or config-supplied path. The ADR's own grading of this ("bounds it from the other side, which is weaker and is stated as such") is accurate and is the correct epistemic form.

The third bound is the problem. Point 2 states the safety argument as: **"the exempt set is precisely the set that is not committed."** That is false as written. The exempt set is a strict *subset* of the uncommitted set — the operator's uncommitted notes, drafts, and scratch are not committed and are not Recon's to delete. The true statement is one-directional: the exempt set *contains nothing committed* and is exactly the enumeration of point 1. As drafted, the gloss sits inside the operative decision and points outward — it is precisely the "phrase that can grow" failure, written into the document that claims to avoid it. One sentence fixes it; unfixed, it is the first citation in a future dispute.

Growth *within* uncommitted space (e.g., an observation-derived cache quietly reclassified as bookkeeping) escapes the tripwire entirely and rides on FR-CON-007's reproducibility discipline. That is a discipline-dependent bound, stated, and I accept it — for directories the same program created in the same run.

## 3. The record/defect line — and is the named gap the only one?

The line is drawable, and critically it is *path*-discriminated (`findings/` and evidence versus everything else), which makes it CI-checkable rather than intent-checkable. That is a categorical improvement over the line that collapsed, which discriminated by observation channel. Nor does it collapse the same way: the old line banned an act someone needed; the new line bans an act no one needs (record-tampering) while permitting the necessary one. Collapse requires pressure; there is none.

The named residual gap — fix the defect, then retire the Finding as obsolete — is real and correctly identified as the owner ceiling. **It is not the only one.**

- **Baseline-amendment laundering.** A "fix" PR can amend the *standard* rather than the mechanism: document that sandbox egress is sanctioned. The Finding survives untouched — the record is never altered, suppressed, or retracted — but its referent is redefined, and the Finding is then retired as obsolete. This attacks the rationale directly: the record is independent, but the *benchmark* is not. It terminates at "retire as obsolete" through a route the named gap does not describe (the named gap changes the world and keeps the standard; this keeps the world and changes the standard). It is arguably unforbiddable — no ADR should bind the owner's amendment power — which is exactly why it must be *named*. A document whose entire authority is candor about its own ceiling does not get to say "the residual honest gap," singular.
- **The actor ambiguity** from §1 above is also a residual gap, unlisted.
- Minor: nothing requires a self-fix PR to cite the Finding it answers. Process, not constitution — but worth a sentence.

## 4. Is (b) treated fairly?

Tilted, not strawmanned. The ADR gives (b) its best case with citations: the #134 precedent "has held," reviewability is conceded outright, facial safety is conceded. That is not how one strawmans.

But the weighing is loaded in two places. First, the reductio row bundles the narrowing with (a). The narrowing is logically separable: **(b) + narrowing answers the reductio too.** The honest matrix is exemption × narrowing, and only the diagonal is weighed; the hybrid never gets a paragraph. Second, the cost row converts "reconcile() runs at startup and after every run" into "each becomes a governance event." False as stated — only reconciliations that *find* orphans become events, and that rate is the crash rate, i.e., the #134 rate that the ADR itself says has held. Correcting both tilts, (a) still wins — the gameability row is decisive and genuinely transfers to any fassung carrying the narrowing, and self-created scratch directories are not #134's processes — but the margin is thinner than presented, and an ADR whose warrant is "weighed two fassungen" should be caught doing it cleanly.

## 5. Wrong rather than incomplete

1. **Point 2's gloss** ("precisely the set that is not committed") — per §2. This is the one defect that lives inside the operative grant.
2. **The diff is empty.** I am asked to ratify an amendment whose central mechanical act I cannot verify: is the old carve-out sentence *struck*? If it survives alongside new point 3, the contradiction this ADR exists to resolve persists as a precedence ambiguity between two live texts. Prose describing the amendment is not the amendment. §4 reads as the replacement text and is adequate as such — but execution must show the strike, and re-review must confirm it.
3. "§5.1 already draws **exactly** this line… (a) applies the same test one section down." Overclaim. §5.1's test is two-way (whose repository); (a)'s is three-way (other / self-content / self-runtime). Same *kind* of test along a new axis — say that, not "exactly."
4. Status "**Accepted**" on a document still under review. "Proposed" until ratified. Minor, but constitutions are built out of such niceties.

## Disposition

The settlement is correct on the question I set, the decisive mechanism (protect the record, permit the repair, bound maintenance by enumeration) is sound, and every defect I found is corrigible without reversing the decision — while the alternative to acceptance is a contradiction remaining in force. I note for the record that this document disclosed enough against its own interest for me to catch its overclaims; that is the behavior this repository exists to reward, and it is the only reason the overclaims are survivable. Two items are re-review triggers, not suggestions: the strike of the old carve-out sentence, and the point-2 gloss.

verdict: APPROVE
