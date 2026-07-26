# Consultation — operating rules in CLAUDE.md, second reviewer

- **Reviewer:** Sol 5.6
- **Provider:** OpenAI — a third provider, independent of the operator (Anthropic) and of the first reviewer (Moonshot)
- **Date:** 2026-07-26
- **Mode:** checkout, cold start

Sought because the first review returned REJECT, and a REJECT requires approval
from a third provider under the rule this section itself introduces.

It found something the first reviewer missed, and the operator had already done
it: mutation testing was unscoped. Read literally it authorises breaking a live
control, and it has an interruption window — a session that stops between
breaking and restoring leaves the control weakened while nobody is watching.
Every mutation in this session was performed in the live working tree.

verdict: REJECT

# Constitutional consultation, second review

## Scope and record checked

I reviewed the exact `origin/main...HEAD` diff to `CLAUDE.md`, the complete current `CLAUDE.md`, `docs/founding-package-v0.2.md`, the cumulative `CLAUDE.md` diff from pinned baseline `d5bd7b4`, `docs/amendments.md`, `docs/operator-lessons.md`, `governance/adversarial-review.md`, `governance/reviewers.md`, `scripts/gate.sh`, and the first consultation in `governance/consultations/66.md`. I did not execute the gate or mutation tests because this consultation is constrained to modify only this report.

The incremental diff has no rider. It adds only the described section and deletes nothing.

## 1. Length

The current section is short enough in substance. It adds 23 physical lines, 15 nonblank lines, and about 119 words to a 193-line pre-change file. That remains a noticeable constitutional allocation, but it is no longer a case history. Every paragraph is now an imperative, a rule, a command, or a pointer. Further compression would be editorial rather than a reason to reject.

The first review's length objection is therefore satisfied in substance even though the result is longer than its suggested “8 to 10 lines.” Physical line count here is largely Markdown wrapping. The important correction was removal of volatile counts, examples, and narrative premises, and that correction was made.

## 2. Claims and constraints

Two statements still promise or imply more than the text can deliver.

First, “Care does not catch the defects this repository produces. Three things do.” is an unbounded causal claim. Running, mutation testing, and independent review improve detection; none guarantees it. The same reviewer can miss a defect, a mutation can exercise the wrong oracle, and an execution can succeed for the wrong reason. A constitution should require evidence without declaring three fallible practices sufficient.

Second, “Before merging: `bash scripts/gate.sh`” requires only that the command be run. It does not require a passing exit status. The default command also exits zero while explicitly reporting that the reproduce fixpoint was not checked. Thus a failed gate, or an incomplete default gate where `--full` is required, can satisfy the sentence literally. This is particularly dangerous in an unattended session because the operator can remember the action “ran gate” and lose the result.

The different-provider review sentence does not itself claim mechanical enforcement. It states a requirement, and the repository already says prose is not enforcement. The cited procedure candidly records that no workflow triggers ordinary HIGH-risk red-team review. That is a real control gap, but the current wording does not conceal it as an enforced gate.

The phrase “which model answered — execute it” is also epistemically too loose. Executing a committed invocation can evidence what endpoint and route were requested. It cannot by itself prove which model weights served the answer. The following rule that self-report is not evidence is correct, but it does not turn execution into identity proof.

## 3. Self-interest

Most of the section binds the operator and is not self-serving. It requires work the operator might otherwise skip: execution, mutation testing, independent review, exact invocations, and a merge gate.

The opening sentence is the exception. “Care does not catch” preserves a softened version of the first draft's exculpation. It classifies defects as structurally beyond care and can excuse insufficient reading or diligence in advance. The binding formulation is that care is insufficient without evidence, not that care does not catch defects.

“Before merging” also needs a non-authorization clause. The cumulative constitution says Phase 4 is unimplemented and that standing merge authority is unresolved. This amendment does not expressly grant merge authority, but it places an operator merge procedure into auto-loaded constitutional text. In the context of an already invalidly adopted delegation amendment recorded in `docs/amendments.md`, that presupposition is unsafe. A future session could read the gate line as the missing authorization path.

## 4. Material issue missed by the first review

“Break what it guards, confirm the suite goes red, restore” is not safely scoped. It does not say disposable worktree, local fixture, or non-live system. Read literally, it can direct the operator to break a live branch rule, platform control, external integration, or other guarded property. It also has an interruption window: if the session crashes after “break” and before “restore,” the control remains weakened while the autonomous operator is absent. This is exactly a failure mode neither owner nor operator may notice during a long unattended session.

This is blocking constitutional ambiguity. Mutation testing should be confined to disposable local state, and cleanup should rely on discarding that state rather than remembering to restore a live mutation.

The change otherwise aligns with the founding intent: it converts session-bound lessons into durable, automatically loaded operating constraints and does not expand Recon's observatory scope or authority over observed repositories.

## Required replacement text

Replace:

> Care does not catch the defects this repository produces. Three things do.

with:

> Care is necessary but insufficient; claims require evidence.

Replace the `Run it` paragraph with:

> **Run it.** When a claim depends on tool behavior, execute the committed invocation in the relevant environment and inspect the result. Never reason from memory, and never treat API acceptance as proof that a control is enforcing or that a particular model answered.

Replace the `Mutate it` paragraph with:

> **Mutation-test it.** In a disposable local worktree or fixture, break the property a check guards, confirm the suite fails for the intended reason, then discard the mutation. Never perform this test against a live control or external system.

Replace the gate line with:

> Before any integration decision, `bash scripts/gate.sh` must exit 0; for changes touching the evidence path, `bash scripts/gate.sh --full` must exit 0. This prerequisite does not authorize the operator to merge.

These are blocking changes because the present wording can authorize unsafe live mutation, treats running a gate as equivalent to passing it, and can be read as normalizing merge authority that the same constitution says is unresolved.

verdict: REJECT

---

## Disposition — all four required changes applied

| Finding | Applied |
|---|---|
| "Care does not catch" reads as licence to stop being careful | replaced with "Care is necessary but insufficient; claims require evidence" |
| `Run it` did not say *which* invocation, in *which* environment | now: execute the committed invocation in the relevant environment |
| **Mutation testing unscoped** — could authorise breaking a live control, with an interruption window | now: disposable worktree or fixture only, discard rather than restore, never against a live control |
| The gate line equated *running* with *passing*, and implied merge authority the constitution calls unresolved | now: must **exit 0**, and passing "does not authorize the operator to merge" |

The third is the one that mattered. The operator wrote the rule and had spent the
session violating it — mutating production files in the live tree and restoring
by hand. Had any of those runs stopped midway, the repository would have been
left weakened with no one present to notice.
