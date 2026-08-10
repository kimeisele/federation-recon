# Review Pipeline Specification v0

**Status:** Draft — concept only, no behavior change.
**Risk class:** The specification itself is LOW (document, no code). Adoption
requires OWNER-ONLY authorization via a separate PR, per `docs/amendments.md`.

## Problem statement

The cross-provider adversarial review process collapsed on 2026-08-02:
monolithic unbounded calls, no checkpointing, no isolation, manual
orchestration. Three of five failures were internal orchestration, not
provider availability. The system bricked itself.

## What this fixes

Five targeted improvements to the existing review process:

1. **Separate runner.** The LLM does not enter the heartbeat dispatcher.
   Heartbeat signals `REVIEW_REQUIRED`; a separate `scripts/review.sh`
   executes the review. Preserves the `CLAUDE.md` invariant: "No LLM is in
   the dispatcher."

2. **Disposable worktree.** Mutating checks (evasion, mutation testing,
   self-application) run in a temporary git worktree at the subject HEAD SHA.
   Timeout or crash destroys the worktree, not the primary checkout.

3. **HEAD-SHA binding.** Every verdict records `subject_head_sha`. A verdict
   for commit `abc123` is never applied to a later commit on the same PR.
   The merge-decision step checks `verdict.subject_head_sha == current HEAD`
   before acting.

4. **Checkpointing per phase.** A lost call destroys one phase, not the
   entire run. Each phase writes its own artifact before the next begins.
   Verdict and per-phase artifacts are written outside the reviewed branch
   and outside the fixpoint-snapshotted directories (`findings/`, `evidence/`,
   etc.) — writing a review result must never change the PR HEAD. v0 stores
   review artifacts in a local directory outside the repo (e.g.
   `~/.local/share/federation-recon/reviews/`). A CI trigger path (step 3)
   requires that PR-authored code execute without reviewer credentials.

5. **PARTIAL is never approval.** An incomplete review stays incomplete.
   No degraded-mode reinterpretation.

## Architecture

```
Heartbeat (deterministic, no LLM)
    → detects PR needs review
    → emits REVIEW_REQUIRED

Review Runner (scripts/review.sh --pr <N>)
    → creates disposable worktree at subject HEAD
    → Tier 0: runs existing gate, captures results
    → Tier 1A: review-analysis (read-only model call)
    → Tier 1B: adversarial-execution (checkout model call)
    → Tier 2: independent verification (only on escalation)
    → deterministic verdict aggregation
    → writes verdict artifact
    → destroys worktree
```

The runner is trigger-agnostic: heartbeat for unattended, GitHub workflow for
event-driven, `bash scripts/review.sh --pr 178` for development. All three
call the same script.

### Tier 0 — Deterministic (always runs)

Runs the existing `gate.sh` once and captures its phase results:

- Schema validation (pass/fail + count)
- Test suite (pass/fail + count)
- Reproduce fixpoint (match/mismatch, `--full` only)
- Tree state (clean/dirty)
- CI status via `gh` API (pass/fail/pending/error/missing)

No duplication — Tier 0 instruments the gate, not reimplements it.

### Tier 1A — Review analysis (1 read-only model call)

Covers the non-executing questions from `adversarial-review.md`:

- Intent vs. implementation (Q4, Q7)
- Claims vs. evidence (Q1c, Q4b, Q4c)
- Environment and workflows (Q2)
- Failure modes (Q5, Q6)
- Completeness (Q8)
- Prior-round conditions (Q10, follow-up rounds only)
- General hazard sweep (Q11)

The 11 questions remain as the internal checklist. They do not become 11
separate tasks or artifacts.

### Tier 1B — Adversarial execution (1 checkout model call)

Covers the executing questions:

- Evasion attempts (Q1, Q1b)
- Mutation testing (Q3)
- Self-application (Q9)

Runs in the disposable worktree.

**Independence comes from execution, not from a second vendor.** An earlier
version of this line required a model distinct from the builder, on the
reasoning that a model cannot review its own output. That requirement is
unsatisfiable here and was therefore silently violated rather than obeyed:
`deepseek-v4-flash` is the only model with usable quota on the operator's
subscription, and reviews on 2026-08-10 ran the same family that built the
change while nothing in `scripts/review.sh` noticed.

The reasoning behind it was sound for the process this pipeline replaced —
the monolithic cross-provider review that collapsed on 2026-08-02, described
in the problem statement above. In that process the model's *judgement* was
the verdict, so whose judgement it was decided everything.

Here it is not. A blocking finding must supply a `verification_command` that
**fails at the PR base and passes at the head**, executed under confinement
that cannot write to the tree it examines. A command that passes at both is
downgraded; one that cannot fail is downgraded; one that mutates the subject
is downgraded. Those are machine properties, and they hold identically whether
the model is the builder's, a competitor's, or a random number generator that
happened to emit valid JSON.

So the model's role in Tier 1B is **to propose commands**, not to decide. A
proposer with a conflict of interest is a weaker proposer, not an invalid one,
and the cost of insisting otherwise is a rule nobody can follow.

What the model must still do honestly is declare itself: provenance is
recorded from the `model` field of the API response, and a response that does
not report its model is a task error, never a silent completion.

**Stated limit.** This removes the last check on the *quality* of proposed
commands. A builder-family reviewer that proposes only commands its own change
satisfies produces an empty review, not a wrong one — the verdict degrades to
APPROVE-by-absence rather than to a false REJECT. That failure mode is real,
is not detected today, and is the price of the constraint. Re-adopting a
distinct reviewer is a prospective decision to make if the budget ever allows,
not a rule to keep on the books while breaking it.

### Tier 2 — Independent verification (escalation only)

Triggered only when:

```
risk_class == HIGH
OR blocking finding exists
OR Tier 1 reports inconclusive
```

A clean LOW-risk PR does not trigger Tier 2. Uses a model from a different
provider than Tier 1. One call, one artifact.

### Verdict schema

```json
{
  "schema": "review-verdict-v1",
  "run_id": "rv-20260803-001",
  "pr_number": 178,
  "subject_head_sha": "abc1234...",
  "risk_class": "HIGH",
  "timestamp": "2026-08-03T...",
  "tasks": {
    "tier0": "pass",
    "review-analysis": "complete",
    "adversarial-execution": "complete",
    "tier2": "complete"
  },
  "findings": [
    {
      "id": "rf-...",
      "tier": 1,
      "task": "adversarial-execution",
      "severity": "blocking",
      "summary": "...",
      "verification_status": "rejected"
    }
  ],
  "verdict": "APPROVE"
}
```

`verification_status`: `confirmed` | `rejected` | `inconclusive` | `not_run`

### Verdict aggregation (deterministic, no model)

```
subject_head_sha ≠ current PR HEAD → STALE

Tier 0 CI status pending/error/missing → PARTIAL

Any Tier 0 mandatory check FAIL → REJECT

Any finding: severity == "blocking"
  AND verification_status in ("confirmed", "inconclusive", "not_run")
    → REJECT

Any mandatory task not "complete" → PARTIAL

risk_class == HIGH AND Tier 2 not complete → PARTIAL

All mandatory tasks complete
AND no unresolved blocking findings → APPROVE
```

### Budget

Each review configures `REVIEW_TIER_COMPLETION_TOKEN_CAP` (default 8192) and
`REVIEW_RUN_COMPLETION_TOKEN_CAP` (default 16384). Values must be positive
decimal integers, and the run cap must be at least the tier cap. Model calls
reserve `min(tier cap, remaining run cap)` before dispatch, so requested
completion tokens never exceed the run cap even when provider usage is absent.
The request-side completion caps are enforced before each provider dispatch.
After a response, a tier fails closed when its reported `completion_tokens` is
equal to or greater than that tier's requested `max_tokens`, regardless of
`finish_reason`; `finish_reason: "length"` retains the stronger truncation
error. Provider usage is telemetry, not client-side enforcement of actual
provider consumption and may be incomplete. `budget.actual_known_totals` keeps
numeric sums for counters that are present, while
`budget.actual_usage_complete` is true only when every attempted provider call
reports both `prompt_tokens` and `completion_tokens`; missing counters make it
false. A missing `reasoning_tokens` counter does not make usage incomplete when
thinking is disabled.
For DeepSeek, `REVIEW_DEEPSEEK_THINKING_MODE` defaults to `disabled` and sends
`thinking: {"type":"disabled"}` without `reasoning_effort`. When enabled,
the effort defaults to `high` and only `high` or `max` is accepted; an effort
with disabled thinking is rejected. Other providers receive no DeepSeek
thinking field and retain their explicit reasoning behavior. Tier 1B is not
run after any Tier 1A error.
Verdicts may include an additive `budget` object recording configured caps,
requested and known actual token totals, thinking mode, and requested effort.

```
max_primary_calls: 2  (Tier 1A + Tier 1B)
max_tier2_calls:   1
max_retry_total:   1  (global, not per-task)
max_model_calls:   4  (hard ceiling including retries)
```

Tier 0 has its own time budget (gate runtime, ~18 min). Model call timeout:
300s per call. Budget exhaustion → `PARTIAL`.

### Merge-decision rules

1. `APPROVE` + LOW → integration-eligible under the existing protected path
2. `APPROVE` + HIGH → integration-eligible only if Tier 2 complete and no
   blocking findings with status `confirmed`, `inconclusive`, or `not_run`
3. `REJECT` → operator must not merge; findings go to builder
4. `PARTIAL` → operator must not merge; resume when conditions change
5. `STALE` → re-run review
6. Envelope/guardrail changes → OWNER-ONLY regardless of verdict

This specification grants no new merge authority. Integration eligibility
is governed by the existing Phase 4 rules and CLAUDE.md constraints.

## What this does NOT change

- Risk classes (LOW, HIGH, OWNER-ONLY/STOP)
- WIP cap (≤ 1)
- Expert-call budget (but see #171)
- Phase 4 ("reserved; v1 does not merge")
- Dispatcher invariant ("No LLM in the dispatcher")
- The 11 adversarial questions (preserved as checklist, grouped into 2 calls)

## Implementation plan

```
1. Spec PR (this document)
2. Implementation PR (inert, manually invocable only)
   - verdict schema
   - Tier 0 gate instrumentation
   - Tier 1A + 1B calls
   - optional Tier 2
   - scripts/review.sh
3. Adoption PR (OWNER-ONLY, amends governance)
```

Steps 1–2 add capability that does not hook into the live process. Step 3
activates it. Step 3 cannot be reviewed by the pipeline it creates and
requires either the restored cross-provider process or explicit owner review.

## Current rollout blockers

- **#171** (budget never resets): latent defect — counter is 2/3, not yet
  blocking, but will permanently brick the heartbeat when exhausted because
  no cycle-terminal transition resets it. Fix touches guardrails → OWNER-ONLY.
  Owner-authorized.
- **#176** (gate leaves debris in worktree): should be fixed before Tier 0
  runs in production. Owner-authorized. Dispatch first — does not touch
  guardrails.

## Parked work

- **#175** (API failure boundary): PR #178 closed, branch
  `operator/175-api-failure-boundary` preserved at `eb328d1`. Resume: reopen
  PR from existing branch when WIP slot is available. See closing comment on
  PR #178 for documented resume conditions.

## Amendment note

Accepting this spec is an amendment requiring a log entry in
`docs/amendments.md`.
