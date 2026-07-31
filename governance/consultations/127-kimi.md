<!-- provenance
requested_provider: moonshot
served_provider: moonshot
model: kimi-k3
verified_by: direct API call, model field read from the response body
log: not applicable — no tool with failover in the path
-->

# Judgment — Kimi K3 on red-team condition 3 (PR #127)

**Question put:** should S2 merge with the missing caller tracked as an issue and
the red-team's condition 3 formally deferred, or must it not merge until
something on a real path calls the validator?

**Why a third provider:** the operator had an obvious interest in the deferral
being accepted and said so in the prompt. `governance/reviewers.md` reserves Kimi
for judgments rather than rounds — decisions where the operator distrusts its own
reasoning.

**Provider independence, as evidence rather than as a claim** (see the failover
lesson in `governance/reviewers.md`):

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 1113, completion 5055 (reasoning 4375) |
| Temperature | 1 (the only value `kimi-k3` accepts) |
| Session context | none — single call, no history |

The full question as sent is reproduced after the ruling.

---

## Ruling

**Do not merge as proposed. The deferral itself is the defect, and the fix is cheaper than the argument against it.**

**1. Governance settles this before engineering does.** Your governing document makes independent red-team concurrence a precondition for merging HIGH-risk work. Condition 3 is a numbered blocking condition from that gate. "Formally deferred by the operator" means the operator deciding which numbered conditions count — the same decision structure as your APPROVE incident, differing only in that this time the memo is longer. The control exists because interested parties misjudge their own work; you disclosed the interest yourself. The legitimate escape valve is to carry arguments (a)–(c) back to the red-team and get condition 3 withdrawn or revised in writing. Not to defer it unilaterally.

**2. Premise (a) is false.** "There is no execution path." There is. S1 merged an isolation backend, and launcher.py invokes it today to run canaries. That is a live execution path with a real capability at the end of it. The validator's job is to refuse before workspace creation and backend calls. There is exactly one place in this repository where backend calls happen. Wire it there.

**3. The smallest real caller:** launcher.py takes an order file as its only entry, calls `core.orders.validate` before any workspace creation or backend call, refuses on non-zero exit without touching the backend, and on exit 0 runs the canary suite as the order's payload. CI supplies a standing canary order. This is tens of lines, no S3 machinery, no acceptance bundle. It satisfies condition 3 literally, and objection (b) collapses: the gated capability is real, so the enforcement is real, not decorative.

**4. This is also the cure for the actual pathology.** Issue #77 and the "convention, not a control" template share one property: first live exercise was scheduled for later, which meant never. Wired into the canary path, this gate is exercised on every CI run from merge day — exit-code propagation, refusal handling, and path resolution get integration-tested continuously at zero risk, because canaries are fake by design. Deferred, the gate's first contact with real plumbing is S4/S5, when failure is expensive and pressure to waive is maximal. A gate never exercised at a real boundary is a prop whether or not its unit tests are green. And stop citing #116/#117 as precedent: a detector missing its cron is an operational gap; a safety gate missing its caller is the control not existing. That precedent is the habit to break, not to follow.

**5. S2 and S3 should not be one slice.** S3's immutable acceptance bundle and verification run are separate, substantial work. The missing piece is thin wiring against S1's existing backend. It belongs in S2 because a gate and its first live call are one control — and because slicing that always places wiring in the next slice is how this repository accumulated its uninvoked mechanisms.

Merge when the launcher is wired or the red-team formally withdraws condition 3. Both are cheap. Self-deferral is not an option the governing document gives the operator.

RULING: DO NOT MERGE

---

## The question as sent



---

## The question as sent

```
You are being asked for a judgment, not a review. One question. Be blunt, and rule.

CONTEXT

Repository `kimeisele/federation-recon`. It is building an "Execution Core": a
supervisor that will one day let an AI builder run inside an isolated sandbox
and verify the result. The repository's governing document requires an
independent red-team from a different provider before merging risk-class HIGH
work, and its own history includes a case where an operator read "verdict:
APPROVE", merged past a numbered blocking condition beneath it, and put an
unratified constitutional amendment onto the main branch.

The ADR fixes the build order explicitly:

  S0  the ADR itself                                   [done, Accepted]
  S1  isolation backend + canary suite, no real model  [done, merged]
  S2  supervisor: order validation, capability check,
      refusal of orders the backend cannot cover       [THIS CHANGE]
  S3  verification run with an immutable acceptance bundle
  S4  end-to-end with a deliberately malicious fake attacker
  S5  a real model
  "No real model before S1-S4 acceptance passes."

THE CHANGE UNDER REVIEW (S2)

A pure, deterministic, 500-line order validator. Given an order file it exits 0
(admissible) or 1 with a refusal code. No shell, no network, no clock, reads
exactly two files. 38 adversarial vectors written by the operator BEFORE the
implementation existed and merged first, so the builder could not author its own
acceptance. 15 mutations, each caught by the intended vector.

An independent red-team (different provider) reviewed it and returned REJECT
with four conditions. Three are fixed and verified. This is the fourth:

  "Condition 3: Wire the validator into the execution path: core/launcher.py
   (or its successor) must call core.orders.validate before any workspace
   creation or backend call, and refuse the order on non-zero exit."

Its reasoning: "No production code invokes the validator. Without one, the
entire mechanism is inert. A correct mechanism that nothing invokes is a prop."

THE OPERATOR'S POSITION - and note that the operator has an obvious interest in
this being accepted, which is why the question is being put to you

There is no execution path yet. Nothing in the repository creates a workspace,
invokes a builder, or runs an order - those are S3 and S4, which do not exist.
`core/launcher.py` today only runs the canary suite and exits; it never receives
an order. So the operator argues:

 (a) The caller cannot be built in S2 because the thing that would call it is S3.
 (b) Adding a call from launcher.py now would put a validation step on a path
     that is not the execution path, producing the APPEARANCE of enforcement
     where there is none - which the operator believes is worse than a stated
     absence.
 (c) There is direct precedent, accepted by the owner one week ago: PR #116
     added a "stale schedule" detector, and the fact that nothing invoked it on
     a schedule was split into its own tracked issue (#117) rather than being
     papered over inside the same PR. The detector merged; the gap stayed
     visible and tracked.

THE COUNTER-ARGUMENT, stated as strongly as I can

This repository's single most-cited failure is exactly this shape. Its issue #77
is titled "the observatory loop has never made an observation". Its own red-team
template carries a "Known gap" section admitting that nothing triggers the
template, making it "a convention, not a control". Merging a validator nothing
calls adds one more correct, tested, green mechanism to a system whose
distinguishing pathology is producing correct, tested, green mechanisms that
are never on any live path. The precedent in (c) may be precedent for a bad
habit rather than a good one. And "the caller is the next slice" is what
everyone says about every uninvoked mechanism.

THE QUESTION

Should S2 merge now, with the missing caller tracked as an issue and the
red-team's condition 3 formally deferred - or is the red-team right that it
must not merge until something on a real path calls it?

If you rule "merge", state what must be true of the tracking so it does not
become the twelfth uninvoked mechanism.
If you rule "do not merge", state the smallest thing that would count as a real
caller given that S3 does not exist, and say plainly whether that means S2 and
S3 should simply be one slice.

Answer in at most 500 words. End with a line reading exactly
RULING: MERGE  or  RULING: DO NOT MERGE
```
