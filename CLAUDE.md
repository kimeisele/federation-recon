# CLAUDE.md — federation-recon Operator

Constitution for the autonomous operator running the `federation-recon` node.
**Lean bootstrap**: read this, then execute `operator/heartbeat.sh` for the
deterministic dispatch decision. State lives in GitHub (control/audit plane),
not in runtime memory. No LLM in the dispatcher — only at measurable judgment
triggers.

## Operator Loop (6 phases)

The operator is a deterministic state machine. Phases are numbered, Western:

```
0_BOOTSTRAP → 1_CLASSIFY → 2_DELEGATE → 3_REVIEW → 4_INTEGRATE → 5_SWEEP
```

Executable form: `operator/heartbeat.sh` (deterministic dispatcher, reads
`operator/state.json` + `gh` queries, emits `ACTION: <…>` and advances state).
Offline except for `gh` read — no LLM, no network dependencies.

| Phase | Rule | Action |
|---|---|---|
| **0 BOOTSTRAP** | git clean? last run clean? | ADVANCE or STOP |
| **1 CLASSIFY** | Categorize work; enforce WIP≤1, budget caps | ADVANCE or STOP |
| **2 DELEGATE** | WIP<1 AND approved issue without PR | `BUILD issue #N` |
| **3 REVIEW** | Open PR exists | `REVIEW PR #N` |
| **4 INTEGRATE** | PR approved + CI green | merge (operator judgment) |
| **5 SWEEP** | Stale PR (>7d) or issue (>14d), no progress | `SWEEP #N` |
| *(none)* | No actionable work | `HOLD` |

**Escalation triggers** (Opus instead of DeepSeek): risk class HIGH, diff >200
lines, CI red, review conflict. Otherwise DeepSeek default.

Hard limits enforced: WIP ≤ 1, expert calls ≤ budget.max_expert_calls.
Violation → STOP (terminal hold).

## Session Bootstrap

Every fresh session: `git pull`, read `CLAUDE.md`, check `operator/state.json`,
run `operator/heartbeat.sh` for the next action. Never trust memory.

## Model Economy

- **DeepSeek** = worker (cheap, API). Default for builds.
- **Opus / Fable 5** = judgment only, on escalation triggers.
- **Sol** = direction review, red-team.
- Frontier chat sparingly — long sessions are the most expensive mode.

## Limits & Enforcement

- GitHub branch ruleset `federation-recon-baseline`: PR-only, CI-required, no force-push.
- CI gates: `validate-artifacts.sh --strict`, `bats scripts/test/`, reproduce fixpoint.
- WIP ≤ 1, concurrency ≤ 1. Retry ≤ 2 on red builds.
- Terminal hold: approved backlog empty → STOP, escalate direction question.

## Key references

- `STATE.md` — Federation Digest (entry point for any operator session).
- `operator/state.json` — compact checkpoint (phase, cycle, budget, last heartbeat).
- `operator/heartbeat.sh` — deterministic dispatcher.
- Issue #29 — operator bootstrap (compact state, not whole history).
- `docs/founding-package-v0.2.md` — constitution + invariants.
