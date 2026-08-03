# Review Pipeline Specification v0

**Status:** Draft — concept only, no behavior change.
**Risk class:** The specification itself is LOW (document, no code). Adoption
of this pipeline as a replacement for the current review process is an
**envelope change** and requires OWNER-ONLY authorization via a separate PR,
per `CLAUDE.md` and `docs/amendments.md`.

## Problem statement

The current cross-provider adversarial review process is:

1. **Provider-dependent.** Each review round requires a reachable external API
   with funded credits. When all channels are exhausted or unreachable,
   review-gated PRs are blocked indefinitely.
2. **Monolithic.** A review is one unbounded call answering 11 questions with
   executed mutations. A timeout at minute 14 loses all 14 minutes of work.
3. **Not checkpointed.** Partial review progress produces no artifact. A
   reviewer that read 8 of 11 questions before timing out leaves zero evidence.
4. **Not serialized with the gate.** Running a review and `gate.sh --full`
   concurrently in the same worktree corrupts the gate's tree-state check.
5. **Opaque.** `gate.sh --full` takes ~18 minutes with no progress signal.
6. **Manual.** The operator must invoke reviews, interpret results, commit
   responses, and re-run gates — each a failure point in an unattended session.

All six were observed in a single session (2026-08-02). Three of the five
distinct failure events were internal orchestration, not provider availability.

## Design principles

1. **Decomposition over monolith.** Review is a pipeline of bounded,
   individually-checkpointed, resumable units ("review tasks"). A timeout
   loses one task, not the pipeline.
2. **Deterministic first, LLM second.** Everything that can be checked without
   a model (schema validation, test results, CI status, artifact integrity)
   runs deterministically. The LLM tier handles only what requires judgment:
   intent-vs-spec alignment and adversarial reasoning.
3. **Existing infrastructure.** The pipeline emits `evidence/`, `findings/`,
   and verdict artifacts in the existing schema. It is a new procedure, not a
   parallel system.
4. **Graceful degradation.** When no LLM reviewer is reachable, the
   deterministic tiers still run and produce a partial verdict. The partial
   verdict is recorded as such and is not promoted to a full approval.
5. **Isolation.** Mutating checks (evasion, mutation testing, self-application)
   run in a disposable git worktree created at the subject HEAD SHA. A timeout
   or crash destroys the worktree, not the primary checkout. A lockdir
   (`mkdir`-atomic, same mechanism as `heartbeat.lock`) prevents concurrent
   pipeline runs. Model API keys are held by the runner process; PR-authored
   code executes in a child process that does not inherit secrets. This is why
   the local runner is the correct v0 — a CI workflow running untrusted PR
   code with reviewer API keys is the `pull_request_target` privilege-escalation
   shape.
6. **Machine-readable verdicts.** Each review task produces a structured
   artifact. The merge-decision layer consumes artifacts, not prose.
7. **Separation of trigger and execution.** The heartbeat dispatcher remains
   deterministic and LLM-free. It detects that review is required and emits a
   `REVIEW_REQUIRED` signal. A separate review runner executes the pipeline.

## Architecture

### Trigger model

```
Heartbeat (deterministic, no LLM)
    ↓ detects PR needs review
    ↓ emits REVIEW_REQUIRED signal
    ↓
Review Runner (separate process)
    ↓ creates disposable worktree
    ↓ executes Tier 0 → Tier 1 → Tier 2
    ↓ publishes verdict artifact
    ↓ destroys worktree
    ↓
Merge Decision (operator reads verdict)
```

The heartbeat decides **that** a review is required. It does not execute the
review. This preserves the `CLAUDE.md` invariant: "No LLM is in the
dispatcher" and "v1.2 only reports an action; it does not execute actions."

The review runner can initially be a standalone script (`scripts/review.sh`)
invoked by the operator when the heartbeat signals `REVIEW_REQUIRED`. A later
adoption PR may wire it into a GitHub Actions workflow for event-driven
execution (triggered on PR open/push), but that is not required for v0.

### Tiers

The pipeline runs in three tiers, each producing its own artifact:

```
Tier 0: Deterministic checks (no model, always available)
Tier 1: Bounded model review (3 consolidated tasks)
Tier 2: Adversarial verification (1 independent pass)
```

#### Tier 0 — Deterministic (always runs)

Instruments the existing `gate.sh` rather than duplicating its checks:

| Check | Source | Notes |
|---|---|---|
| Schema validation | `validate-artifacts.sh --strict` | pass/fail + count |
| Test suite | `bats scripts/test/` | pass/fail + count |
| Reproduce fixpoint | `gate.sh --full` fixpoint phase | match/mismatch |
| Tree state | clean worktree assertion | pass/fail |
| CI status | `gh` API read | `pass`, `fail`, `pending`, `error`, `missing` |
| PR metadata | title, body, labels, linked issues | structured extract |

Architecture drift checking against `REPO_BOUNDARIES.md` is deferred to Tier 1
because no deterministic checker currently exists; comparing against prose is
model work, not deterministic work.

The reproduce fixpoint (~18 minutes, #172) runs once per review subject
(see SHA binding below). Its result is cached in the Tier 0 artifact;
re-running is required only when `subject_head_sha` changes.

Output: `findings/review-t0-{pr_number}-{run_id}.json`

#### Tier 1 — Bounded model review (3 consolidated tasks)

The 11-question adversarial template is preserved but grouped into three
bounded tasks to reduce orchestration overhead in v0. If measurement shows
a task regularly exceeds its timeout, it can be split further.

| Task | Questions covered | Requires checkout? |
|---|---|---|
| `intent-and-claims` | Q1c, Q4, Q4b, Q4c, Q7 | No — reads PR body + diff + data |
| `environment-and-failure-modes` | Q2, Q5, Q6 | No — reads workflow files + code |
| `adversarial-execution` | Q1, Q1b, Q3, Q8, Q9 | Yes — must execute evasions, mutations, self-application |

Each task:

- Has a timeout (configurable, default 300s per task)
- Produces its own artifact on completion or timeout
- Can be retried independently (max 1 retry on transport error/timeout)
- Runs in a disposable worktree (checkout tasks) or read-only (non-checkout)
- `adversarial-execution` must use a model distinct from the builder — the
  builder's own model family cannot review its own output
  (`adversarial-review.md` founding claim; `builders.md`: builder output is
  untrusted)
- Model provenance is verified per task via the `model` field in the API
  response (method documented in `governance/builders.md`). If the readback
  shows the builder's model, the task status is `error`, never `complete` —
  `reviewers.md` records that jcode's silent failover is how three reviews
  came to be answered by the builder's own provider

Each task emits: `findings/review-t1-{task}-{pr_number}-{run_id}.json`

A task that times out emits a partial artifact marked `"status": "timeout"`.
A task that completes emits `"status": "complete"` with structured findings.

#### Tier 2 — Independent adversarial verification (1 pass)

A single independent verification pass that:

- Verifies blocking findings from Tier 1 (confirms or rejects each)
- Adversarially challenges a Tier 1 all-clear ("no findings" is a claim that
  must be tested, not a safe default — this prevents the self-sealing failure
  where a compromised Tier 1 suppresses Tier 2)
- Uses a model from a **different provider** than Tier 1 (cross-provider when
  available; cross-model-family degrades to `PARTIAL_UNVERIFIED`)
- Receives the Tier 1 task outputs + relevant code for finding verification;
  for the all-clear challenge, receives the **full diff** (not a Tier-1-selected
  excerpt) so that a Tier 1 miss does not scope Tier 2's visibility
- Bounded: 300s timeout, max 1 retry

Emits: `findings/review-t2-{pr_number}-{run_id}.json`

### Review artifact storage

Review artifacts are **not committed to the reviewed PR branch**. Committing
review results to the PR would change the PR's HEAD, invalidating the review
subject and potentially triggering an infinite review loop.

Review artifacts are stored via one of:

- GitHub Check Run annotations (v0, simplest)
- A dedicated `review-state/` directory on a separate branch or in
  `.github/review-artifacts/` (if persistence beyond the PR is needed)
- GitHub Actions Artifacts (if the runner is a workflow)

The existing `findings/` schema is used for the artifact format. The storage
location is separate from the reviewed branch's content.

### SHA-bound verdicts

Every verdict is bound to an exact review subject. A verdict for PR 178 at
commit `abc123` is never valid for a later commit on the same PR.

```json
{
  "schema": "review-verdict-v1",
  "run_id": "rv-20260803-001",
  "pr_number": 178,
  "subject_head_sha": "abc1234...",
  "base_sha": "def5678...",
  "review_input_digest": "sha256:...",
  "policy_version": "sha256:...(hash of spec + adversarial-review.md + task defs)",
  "timestamp": "2026-08-03T...",
  "verdict": "REJECT",
  "risk_class": "HIGH",
  "tasks": {
    "intent-and-claims": {"status": "complete", "findings_count": 1},
    "environment-and-failure-modes": {"status": "complete", "findings_count": 0},
    "adversarial-execution": {"status": "complete", "findings_count": 2}
  },
  "findings": [
    {
      "id": "rf-...",
      "tier": 1,
      "task": "intent-and-claims",
      "severity": "blocking",
      "summary": "...",
      "evidence": ["ev-...", "ev-..."],
      "verification_status": "confirmed"
    }
  ],
  "tier2_pass": {
    "status": "complete",
    "all_clear_challenged": true
  },
  "budget_consumed": {
    "model_calls": 4,
    "retries": 0,
    "wall_time_seconds": 847
  }
}
```

The `review_input_digest` covers: diff content, PR description, linked issues,
and `policy_version`. A change to any input invalidates the cached verdict.

`policy_version` is a hash over the review pipeline spec, the adversarial
review template (`governance/adversarial-review.md`), and the task definitions.
If the template changes, old verdicts are stale by digest — not "valid under a
different question set." This repo's history is precisely "a checklist changed
and nobody noticed which version fired."

`verification_status` per finding uses:

| Value | Meaning |
|---|---|
| `confirmed` | Tier 2 verified the finding is real |
| `rejected` | Tier 2 determined the finding is a false positive |
| `inconclusive` | Tier 2 could not determine |
| `not_run` | Tier 2 did not execute (provider unreachable or budget exhausted) |

### Deterministic verdict aggregation

The verdict is computed deterministically from task and finding states.
No model is involved in the verdict decision.

```
subject_head_sha ≠ current PR HEAD
    → verdict STALE (must re-run)

Any Tier 0 mandatory check FAIL
    → verdict REJECT

Any finding with verification_status == "confirmed" and severity == "blocking"
    → verdict REJECT

Any mandatory task status == "timeout" or "error"
    → verdict PARTIAL_INCOMPLETE

Tier 2 not_run (provider unreachable or budget exhausted)
    → verdict PARTIAL_UNVERIFIED

All mandatory tasks complete
AND no unresolved blocking findings (unresolved = verification_status is
    "confirmed", "inconclusive", or "not_run"; "rejected" = resolved)
AND Tier 2 complete
    → verdict APPROVE

Everything else
    → verdict PARTIAL_INCOMPLETE
```

A `PARTIAL` verdict of any kind is **not merge-eligible**. `PARTIAL` means
the review is incomplete, not that it is a weaker form of approval.

### Budget limits

Configurable per review run, with defaults for v0:

```
max_tier1_calls: 3
max_tier2_calls: 1
max_retries_per_task: 1 (transport error or timeout only)
max_wall_time_seconds: 1800
```

Budget exhaustion produces `PARTIAL_INCOMPLETE`, not a degraded approval.
Budget is not automatically increased. Increasing the budget is a
configuration change outside the pipeline's authority.

### Degraded modes

| Condition | Behavior |
|---|---|
| All models unreachable | Tier 0 runs, verdict = `PARTIAL_INCOMPLETE` |
| Tier 1 model unreachable | Tier 0 runs, verdict = `PARTIAL_INCOMPLETE` |
| Tier 2 model unreachable | Tier 0 + Tier 1 run, findings have `verification_status: "not_run"`, verdict = `PARTIAL_UNVERIFIED` |
| Tier 2 cross-model only (no cross-provider) | Tier 0 + Tier 1 + Tier 2 run, verdict = `PARTIAL_UNVERIFIED` (degrades from full) |
| Tier 1 task timeout | Other tasks continue, timed-out task marked, verdict = `PARTIAL_INCOMPLETE` |
| Budget exhausted | Pipeline stops, verdict = `PARTIAL_INCOMPLETE` |
| All tiers complete, cross-provider Tier 2 | Full verdict = `APPROVE` or `REJECT` |

### Merge-decision layer

The verdict artifact is consumed by the operator. Rules:

1. `verdict == "APPROVE"` AND `risk_class == "LOW"` → operator may merge
   through protected PR path (existing authority)
2. `verdict == "APPROVE"` AND `risk_class == "HIGH"` → operator may merge;
   all blocking findings must have `verification_status == "confirmed"` or
   `"rejected"` (none `"not_run"` or `"inconclusive"`)
3. `verdict == "REJECT"` → operator must not merge; findings feed back to
   builder
4. `verdict` starts with `PARTIAL_` → operator must not merge; record state
   for resumption
5. `verdict == "STALE"` → operator must re-run review
6. Envelope/guardrail changes → OWNER-ONLY regardless of verdict (existing
   requirement, unchanged)

The merge-decision layer **checks `subject_head_sha == current PR HEAD`**
before applying any verdict. A stale verdict is never applied.

## What this does NOT change

- **Risk classes.** LOW, HIGH, OWNER-ONLY/STOP remain as defined in `CLAUDE.md`.
- **WIP cap.** WIP ≤ 1 remains enforced by `heartbeat.sh`.
- **Budget caps.** Expert-call budget remains as-is (but see #171).
- **Phase 4 unimplemented.** The merge-decision layer describes rules; it does
  not implement auto-merge. Phase 4 remains "reserved; v1 does not merge."
- **Stewardship boundary.** The operator's fiduciary obligations are unchanged.
- **Dispatcher invariant.** "No LLM is in the dispatcher" is preserved.

## What this DOES change (requires adoption PR)

- **Review process.** Replaces the monolithic cross-provider adversarial review
  with a tiered, decomposed, checkpointed pipeline.
- **Review trigger.** Currently manual (operator invokes `consult-opencode.sh`).
  Becomes signal-based: heartbeat emits `REVIEW_REQUIRED`, operator or
  workflow invokes the review runner. The dispatcher remains LLM-free.
- **Degraded mode.** Currently undefined ("the change waits" is implicit).
  Becomes explicit with `PARTIAL_*` verdicts.
- **Adversarial-review.md.** The 11-question template is preserved but
  grouped into three bounded tasks. The template document becomes the reference
  for what the tasks must cover, not the prompt for a single call.

These are envelope changes. Adoption requires its own PR with OWNER
authorization per `docs/amendments.md`.

## Implementation plan

Sequenced to respect WIP ≤ 1 and the separation between spec and adoption.
Steps 2–4 add capability that is **inert and manually invocable only** — no
step hooks into the live process until the adoption PR.

1. **This document** — design spec, LOW risk, normal PR path
2. **Verdict schema + Tier 0 implementation** — deterministic only, instruments
   existing gate, emits SHA-bound artifacts, LOW risk
3. **Tier 1 tasks + Tier 2 pass** — bounded model calls with checkpointing,
   disposable worktree isolation, LOW risk (no authority change)
4. **Review runner script** — `scripts/review.sh` orchestrates Tiers 0–2,
   manually invocable, LOW risk
5. **Adoption PR** — amends governance to replace current review process,
   OWNER-ONLY, per `docs/amendments.md`. This step cannot be reviewed by
   the pipeline it creates (independence), so it requires either the
   restored cross-provider process or explicit owner review.

Each step is a separate PR.

**WIP constraint:** `heartbeat.sh` counts draft PRs toward WIP ≤ 1. #177 is
now merged. #178 remains open as draft (WIP = 1). Step 1 can become a PR only
after #178 merges or closes, or by owner authorization to temporarily exceed
WIP during the pipeline transition.

## Current rollout blockers

These are operational blockers, not permanent architectural dependencies:

- **#171** (budget never resets) blocks the heartbeat from dispatching reviews.
  Fix touches guardrails → OWNER-ONLY.
- **#176** (gate leaves debris) should be fixed before Tier 0 can rely on
  clean tree-state checks.

## Resolved defaults (owner may override)

Three questions from the initial draft, now resolved based on external review:

1. **Cross-provider vs. cross-model for Tier 2:** Cross-provider required for
   a full `APPROVE`. Cross-model-only degrades to `PARTIAL_UNVERIFIED`.
   *Rationale:* preserves the existing governance independence requirement
   rather than silently weakening it.

2. **Budget ceiling for Tier 1:** 3 Tier-1 calls + 1 Tier-2 call, max 1
   retry on transport error/timeout, 1800s total wall time. Exhaustion
   produces `PARTIAL_INCOMPLETE`.
   *Rationale:* matches the 3-task decomposition; budget is never auto-raised.

3. **PARTIAL verdicts and merge eligibility:** `PARTIAL` is never
   merge-eligible, regardless of risk class. No deterministic-only approval
   class exists in v0. If a future version introduces one, it will be a named
   class (not a reinterpretation of `PARTIAL`).
   *Rationale:* `PARTIAL` means incomplete, not "good enough."

## Amendment note

Flipping this document's status from Draft to Accepted is itself an amendment
to the governance framework and requires a log entry in `docs/amendments.md`.
This is stated here rather than assumed, per the amendment log's own note
about doors nobody counted as doors.
