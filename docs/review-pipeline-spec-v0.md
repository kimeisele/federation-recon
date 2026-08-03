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

All six were observed in a single session (2026-08-02). Three of five failures
were internal orchestration, not provider availability.

## Design principles

1. **Decomposition over monolith.** Review is a pipeline of bounded,
   individually-checkpointed, resumable units ("review tasks"). A timeout
   loses one task, not the pipeline.
2. **Deterministic first, LLM second.** Everything that can be checked without
   a model (schema validation, test results, CI status, architecture drift,
   artifact integrity) runs deterministically. The LLM tier handles only what
   requires judgment: intent-vs-spec alignment and adversarial reasoning.
3. **Existing infrastructure.** The pipeline emits `evidence/`, `findings/`,
   and verdict artifacts in the existing schema. It is a new procedure, not a
   parallel system.
4. **Graceful degradation.** When no LLM reviewer is reachable, the
   deterministic tiers still run and produce a partial verdict. The partial
   verdict is recorded as such and is not promoted to a full approval.
5. **Serialization.** Review and gate never run concurrently in the same
   worktree. The pipeline owns the sequencing, enforced by a lockdir
   (same `mkdir`-atomic mechanism as `heartbeat.lock`).
6. **Machine-readable verdicts.** Each review task produces a structured
   artifact. The merge-decision layer consumes artifacts, not prose.

## Architecture

### Tiers

The pipeline runs in three tiers, each producing its own artifact:

```
Tier 0: Deterministic checks (no model, always available)
Tier 1: Bounded model review (cheap model, decomposed tasks)
Tier 2: Adversarial verification (independent model, checkout tasks + critical findings)
```

#### Tier 0 — Deterministic (always runs)

Reuses existing infrastructure:

| Check | Source | Artifact |
|---|---|---|
| Schema validation | `validate-artifacts.sh --strict` | pass/fail + count |
| Test suite | `bats scripts/test/` | pass/fail + count |
| Reproduce fixpoint | `gate.sh --full` fixpoint phase | match/mismatch |
| Architecture drift | `REPO_BOUNDARIES.md` boundary check | violations list |
| Tree state | clean worktree assertion | pass/fail |
| CI status | `gh` API read | pass/fail per check |
| PR metadata | title, body, labels, linked issues | structured extract |

The reproduce fixpoint (`gate.sh --full`) is the expensive check (~18 minutes,
#172). It runs once per PR version, not per update. Its result is cached in the
Tier 0 artifact; re-running is only required when the PR's HEAD changes.

Output: `findings/review-t0-{pr_number}.json` — machine-readable, no
judgment required.

#### Tier 1 — Bounded model review (decomposed)

The current 11-question monolith is decomposed into independent review tasks.
Each task:

- Has a bounded scope (one question or a small group)
- Has a timeout (configurable, default 300s)
- Produces its own artifact on completion
- Can be retried independently on failure
- Must use a model distinct from the builder for checkout tasks
  (`evasion-analysis`, `mutation-testing`, `completeness`) — the builder's own
  model family cannot review its own output (`adversarial-review.md` founding
  claim; `builders.md` classifies builder output as untrusted)
- Read-only tasks (`claim-verification`, `environment-check`, `proof-vs-claim`,
  `failure-modes`, `fitness-judgment`) may use any available model
- Model provenance is verified per task via the `model` field in the API
  response (method documented in `governance/builders.md`)

Proposed decomposition:

| Task | Questions covered | Requires checkout? |
|---|---|---|
| `evasion-analysis` | Q1, Q1b | Yes — must attempt evasions |
| `claim-verification` | Q1c, Q4b | No — reads PR body + data |
| `environment-check` | Q2 | No — reads workflow files |
| `mutation-testing` | Q3 | Yes — must break and restore |
| `proof-vs-claim` | Q4, Q4c | No — reads diff + substrate |
| `failure-modes` | Q5, Q6 | No — reads code paths |
| `fitness-judgment` | Q7 | No — reads diff + context |
| `completeness` | Q8, Q9 | Yes — runs mechanism against itself |

Each task emits: `findings/review-t1-{task}-{pr_number}.json`

A task that times out emits a partial artifact marked `"status": "timeout"`.
A task that completes emits `"status": "complete"` with structured findings.

#### Tier 2 — Adversarial verification (on escalation only)

Triggered on **task completion** for checkout tasks (`evasion-analysis`,
`mutation-testing`, `completeness`), and on **critical findings** for read-only
tasks. This avoids a self-sealing failure: if Tier 2 only triggers on critical
findings and Tier 1 is compromised (same model family as builder), an
all-clear from Tier 1 would suppress Tier 2 entirely.

- Uses a model from a different provider than Tier 1 (cross-provider when
  available, different model-family when not)
- Receives only the specific task output + relevant code, not the full review
- Bounded: one task per call, 300s timeout
- Emits: `findings/review-t2-{task}-{pr_number}.json`

### Degraded modes

| Condition | Behavior |
|---|---|
| All models unreachable | Tier 0 runs, verdict = `PARTIAL_DETERMINISTIC` |
| Tier 1 model unreachable | Tier 0 runs, verdict = `PARTIAL_DETERMINISTIC` |
| Tier 2 model unreachable | Tier 0 + Tier 1 run, critical findings marked `"tier2_verified": false`, verdict = `PARTIAL_UNVERIFIED` |
| Tier 1 task timeout | Other tasks continue, timed-out task marked, verdict includes `"incomplete_tasks": [...]` |
| All tiers complete | Full verdict = `APPROVE` or `REJECT` with findings |

**The decision the current system does not make:** when no independent verifier
is reachable, the pipeline records `PARTIAL_UNVERIFIED` and the PR **does not
merge autonomously**. This is the same behavior as today ("the change waits")
but with two differences: (a) the deterministic evidence is captured rather
than lost, and (b) the degraded state is machine-readable, so the operator
can resume when a channel becomes available without re-running Tier 0.

### Verdict schema

```json
{
  "schema": "review-verdict-v1",
  "pr_number": 178,
  "timestamp": "2026-08-03T...",
  "tiers_completed": [0, 1, 2],
  "verdict": "REJECT",
  "risk_class": "HIGH",
  "findings": [
    {
      "id": "rf-...",
      "tier": 1,
      "task": "claim-verification",
      "severity": "critical",
      "summary": "...",
      "evidence": ["ev-...", "ev-..."],
      "tier2_verified": true
    }
  ],
  "incomplete_tasks": [],
  "degraded": false
}
```

### Merge-decision layer

The verdict artifact is consumed by the operator's Phase 4 (INTEGRATE). Rules:

1. `verdict == "APPROVE"` AND `risk_class == "LOW"` → operator may merge
   through protected PR path (existing authority)
2. `verdict == "APPROVE"` AND `risk_class == "HIGH"` → merge requires Tier 2
   verification of all critical findings (existing requirement, now enforced
   by artifact rather than prose)
3. `verdict == "REJECT"` → operator must not merge; findings feed back to
   builder
4. `verdict` starts with `PARTIAL_` → operator must not merge; record state
   for resumption
5. Envelope/guardrail changes → OWNER-ONLY regardless of verdict (existing
   requirement, unchanged)

## What this does NOT change

- **Risk classes.** LOW, HIGH, OWNER-ONLY/STOP remain as defined in `CLAUDE.md`.
- **WIP cap.** WIP ≤ 1 remains enforced by `heartbeat.sh`.
- **Budget caps.** Expert-call budget remains as-is (but see #171).
- **Phase 4 unimplemented.** The merge-decision layer describes rules; it does
  not implement auto-merge. Phase 4 remains "reserved; v1 does not merge."
- **Stewardship boundary.** The operator's fiduciary obligations are unchanged.

## What this DOES change (requires adoption PR)

- **Review process.** Replaces the monolithic cross-provider adversarial review
  with a tiered, decomposed, checkpointed pipeline.
- **Review trigger.** Currently manual (operator invokes `consult-opencode.sh`).
  Becomes automatic on PR creation/update, within the heartbeat loop. This
  inverts a stated dispatcher invariant: `CLAUDE.md` says "No LLM is in the
  dispatcher" and "v1.2 only reports an action; it does not execute actions."
  Placing model calls in the heartbeat is a fundamental change to the
  dispatcher's design, not just a process adjustment.
- **Degraded mode.** Currently undefined ("the change waits" is implicit).
  Becomes explicit with `PARTIAL_*` verdicts.
- **Adversarial-review.md.** The 11-question template is preserved but
  decomposed into bounded tasks. The template document becomes the reference
  for what the tasks must cover, not the prompt for a single call.

These are envelope changes. Adoption requires its own PR with OWNER
authorization per `docs/amendments.md`.

## Implementation plan

Sequenced to respect WIP ≤ 1 and the separation between spec and adoption:

1. **This document** — design spec, LOW risk, normal PR path
2. **Verdict schema + Tier 0 implementation** — deterministic only, emits
   artifacts in existing schema, LOW risk
3. **Tier 1 task decomposition** — bounded model calls with checkpointing,
   LOW risk (no authority change)
4. **Tier 2 verification** — adversarial check on critical findings, LOW risk
5. **Adoption PR** — amends governance to replace current review process,
   OWNER-ONLY, per `docs/amendments.md`. This step cannot be reviewed by
   the pipeline it creates (independence), so it requires either the
   restored cross-provider process or explicit owner review.

Each step is a separate PR. Steps 2–4 add capability without changing
authority. Step 5 is the governance change.

**WIP constraint on sequencing:** `heartbeat.sh` counts draft PRs toward
WIP ≤ 1. With #177 and #178 both open, no new PR can be opened. #177 must
merge or close before step 1 can become a PR. This is a hard sequencing
constraint, not a footnote.

## Prerequisite issues

Before implementation can begin:

- **#177** (census observation) must merge or close to restore WIP ≤ 1. This
  is an owner merge decision — the operator cannot merge.
- **#171** (budget never resets) blocks the heartbeat from dispatching reviews.
  Fix touches guardrails → OWNER-ONLY.
- **#176** (gate leaves debris) should be fixed before Tier 0 can rely on
  clean tree-state checks.

## Open questions for owner

1. Should Tier 2 (adversarial verification) require cross-provider independence,
   or is cross-model (different model family, same provider) sufficient?
2. What is the budget ceiling for Tier 1 model calls per review cycle?
3. Should `PARTIAL_DETERMINISTIC` verdicts on LOW-risk PRs be sufficient for
   merge (i.e., can a fully-deterministic review approve a LOW-risk change)?

## Amendment note

Flipping this document's status from Draft to Accepted is itself an amendment
to the governance framework and requires a log entry in `docs/amendments.md`.
This is stated here rather than assumed, per the amendment log's own note
about doors nobody counted as doors.
