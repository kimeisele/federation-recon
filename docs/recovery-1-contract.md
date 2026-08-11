# RECOVERY-1 Part B — Review-control contract proposal

**Status:** DRAFT PROPOSAL — NOT ADOPTED — OWNER DECISION REQUIRED (2026-08-11)

This is a prospective contract for the recovery work. It is not an amendment,
does not adopt itself, and authorizes no code, credential, permission, branch
ruleset, risk-envelope, or guardrail change. Until a separate adoption PR is
accepted, the currently committed constitution, scripts, gates, and historical
records remain in force, including their known contradictions and provider
requirements.

The contract applies to review and integration of this repository's work. It
does not alter the founding package's Slice-v0 evidence model or its rule that
Recon has no authority over observed repositories.

## 1. Architectural review independence

Review independence is a property of the execution architecture, not of a
vendor label. A review is independent only when all of the following are true:

1. The builder and reviewer are separate invocations with separate run IDs,
   sessions, worktrees, enforced capability profiles, and append-only run
   records. The orchestrator's input manifest, control-plane policy, oracle
   set, and capability profile are sealed to the run identity before execution.
   The reviewer output is hashed and sealed after the invocation completes and
   immediately before the kernel consumes it. Builder and reviewer may use the
   same provider through a credential broker, but neither invocation receives
   the raw provider credential and the reviewer receives no subject-write or
   integration capability.
2. The reviewer receives an immutable `base_sha`, `head_sha`, and complete raw
   diff captured from those identities. It does not fetch a replacement diff
   after review begins.
3. The reviewer has no ability to write the subject, select or replace the
   deciding oracles, write the final verdict, access raw credentials, or change
   integration controls. Its output is untrusted evidence data and is sealed
   with its input and run identities before the kernel consumes it. No single
   subject author, oracle author, policy author, or reviewer may be the sole
   authority for the resulting decision.
4. Review oracles predate the work being judged, are independently derived, and
   are executed by deterministic code in a disposable environment. A builder
   cannot create, edit, or select the oracle that decides its work.
5. The review has an adversarial objective and includes at least one negative
   or mutation check for every property it claims to establish.
6. Missing input, stale identity, unavailable capability, timeout, crash,
   parser failure, or inconclusive evidence produces `PARTIAL`/`HOLD`, never
   `APPROVE`.

Provider and model identity plus measured actual cost MUST be recorded from an
authoritative invocation/accounting source for attribution, cost, and later
correlation analysis. A missing budget reservation, provider, provenance, or
cost record is `HOLD`. Every provider invocation requires an atomic budget
reservation before dispatch; a crash, timeout, or ambiguous completion consumes
that reservation. No silent or paid fallback is permitted. Different-provider
or different-model diversity is optional metadata and an optional additional
signal; it is not the definition of independence and is not a routine
prerequisite. A model's self-report and a tool's exit status are not evidence
of identity.

## 2. Deterministic fail-closed trust kernel

The trust kernel is the only component allowed to map review evidence to a
verdict. It is model-free and has a small, explicit input contract. It MUST:

- validate the complete verdict against the committed schema before evaluation;
- require the exact task set, known risk class, known status values, immutable
  subject identities, and well-formed findings;
- recompute the verdict rather than trusting a stored verdict field;
- reject stale `head_sha` and any mismatch among policy, diff, worktree, and
  artifact identities;
- treat missing or malformed mandatory evidence, unavailable capability,
  `not_run`, `error`, timeout, and `inconclusive` as non-approval;
- preserve a blocking claim's severity through all serialization boundaries;
- require every mandatory review phase to complete and every required negative
  or mutation check to pass; and
- refuse to evaluate an unclassified or unsupported case instead of selecting a
  permissive default.

Phase completion also requires a finite, versioned, predeclared property
manifest. Every manifest property must have real deterministic coverage and
evidence in the run. A stub, placeholder, self-report, empty result, or
unmeasured property is `HOLD`, not completion. The manifest, evaluator version,
fixture corpus, and expected outcomes are sealed inputs; the subject, oracle,
policy, or candidate under review cannot select, alter, or regenerate them.

The schema MUST define the closed task-status enum
`{pass, complete, fail, error, not_run}` and verdict-status enum
`{APPROVE, REJECT, PARTIAL, STALE, HOLD}`, plus a deterministic precedence:
malformed/unknown/missing input → `HOLD`; stale
identity → `STALE`; failed or confirmed blocking evidence → `REJECT`; any
incomplete mandatory phase or unavailable evidence → `HOLD`; only a fully
qualified exact `APPROVE` may approve. Every other recognized status is
non-approval. `HOLD` is the normalized result for unknown or incomplete states.

`APPROVE` is possible only when every mandatory deterministic gate and every
required independent review phase completed against the same immutable subject,
with no unresolved blocking finding. A stub, empty fallback, default risk
class, missing count, or failed capability probe can never satisfy that rule.

The kernel itself has no merge authority. It emits an auditable decision and
the evidence required by the integration actor.

Review-control artifacts and run records live outside the Slice-v0
`pins/`, `claims/`, `evidence/`, `findings/`, `coverage/`, `consumption/`, and
digest artifact paths. Deterministic Slice-v0 evidence generation remains
model-free; no model call may create, complete, or certify that evidence.

## 3. Integration authority

The owner alone is the manual merge root of trust under the current contract.
The pipeline may prepare a patch, run the kernel, and open or update a PR only
within the already adopted boundaries. It must not merge its own output.

Any future integrator is outside this proposal and is incompatible with the
current FR-CON-002 boundary unless a separate, explicit constitutional
amendment authorizes it. No integrator is designed or adopted here. A later
proposal would at minimum have to exclude changes to `CLAUDE.md`,
`docs/founding-package-v0.2.md`, every `docs/*-adr.md`, credentials,
permissions, branch rulesets, required checks, the risk envelope, and the trust
kernel; it could not approve or merge any change to those excluded surfaces,
including the change that grants or expands its own authority. Two credentials
held by the same actor do not create independence.

Changes to constitution, risk envelope, machine guardrails, credentials,
permissions, or integration authority remain owner-only. A green CI result or a
kernel `APPROVE` is necessary evidence at most; neither grants authority.

## 4. Property-specific baselines

There is no single repository-wide trusted baseline. Each claimed control or
component has its own baseline record containing:

- component/property name and exact source commit or artifact identity;
- expected fields and invariant statement;
- positive preservation probe and deliberately broken negative/mutation probe;
- environment, capability assumptions, and cost/WIP limits;
- provenance, adoption event, and known uncertainty.

`UNKNOWN` is a first-class result and cannot be promoted by age, green tests,
or proximity to an older commit. A baseline change and retirement of a Finding
are separate, cited decisions. Historical incident reports, consultations,
reviews, and dispositions remain unchanged; corrections are appended as new
records.

This review-control baseline is distinct from the founding package's Slice-v0
reconnaissance baseline/evidence model. It does not introduce a Slice-v0
external expectation source.

## 5. Safe autonomous self-extension

The pipeline may propose extensions, but a model may not grant itself authority.
Every proposed replacement for a kernel, rule, oracle, or guardrail follows a
two-generation protocol:

1. The current kernel evaluates the candidate against a sealed, finite,
   versioned manifest of fixed invariants, deliberately broken fixtures, and
   expected outcomes. The evaluator version and corpus digest are committed
   before the candidate is seen.
2. The candidate runs shadow-only with no integration, credential, or policy
   authority.
3. The current and candidate decisions are compared on the same immutable
   corpus; unexplained divergence is a terminal hold.
4. Activation is currently owner-only. If later authorized, it must be
   prospective, staged/canary-based, append-only logged, bounded by budget and
   WIP limits, and reversible to the previous generation.

No candidate may simultaneously redefine a rule, replace its oracle, and
authorize itself under the replacement. The current kernel, constitution,
credentials, permissions, and kill switch remain outside autonomous adoption.

## Executable acceptance criteria

The implementation sequence is not eligible for activation as complete until
all of these produce the stated result in a disposable checkout or fixture.
The proposal/adoption PR defines these criteria but does not falsely claim to
execute code that does not yet exist:

1. **Identity binding:** mutate the PR head after capture; the kernel returns
   `STALE`/`PARTIAL` and cannot return `APPROVE`.
2. **Missing evidence:** delete or corrupt each mandatory task, finding, risk
   class, and capability record; the kernel returns `PARTIAL`/`HOLD`.
3. **Severity preservation:** inject a blocking finding through the complete
   runner/serializer path; the final kernel input still contains blocking
   severity and cannot approve it as non-blocking.
4. **Oracle independence:** make the builder create or edit its oracle; the
   runner refuses the order or returns a rejected result.
5. **Architectural separation:** make the reviewer worktree or subject mutable;
   the run fails without changing the subject checkout.
6. **Provider irrelevance:** freeze one identical evidence bundle and run the
   kernel twice with only provider/model attribution metadata varied. The
   verdict and all authority-relevant inputs must be identical; attribution
   metadata is recorded but is not an authority input.
7. **Budget accounting:** omit the atomic reservation, actual provider/model,
   provenance, or measured cost; the run returns `HOLD`. Force a crash,
   timeout, or ambiguous completion; the reservation is consumed and no silent
   or paid fallback occurs.
8. **Complete-stub rejection:** mark a phase `complete` while supplying only a
   stub, placeholder, self-report, or absent property-manifest evidence; the
   kernel returns `HOLD`.
9. **Owner boundary:** present a green, approved verdict to the pipeline; no
   merge occurs without the owner. Any future integrator remains out of scope
   until a separate constitutional amendment.
10. **Baseline mutation:** remove a required baseline property or mutate its
   preservation probe; the check fails, rather than treating the property as a
   first observation.
11. **Two generations:** mutate the candidate kernel or its sealed corpus; the
   old kernel rejects or
   holds it, shadow mode has no integration effect, and rollback restores the
   old decision.
12. **Historical immutability:** an implementation PR changes no existing
    historical consultation/review text; a new correction is append-only.

Each criterion must cite the exact committed invocation, its observed output,
and the disposable mutation used. A test that merely duplicates the production
oracle does not satisfy the criterion.

## Sequenced implementation map

The following order is normative for subsequent work; each item is a separate
reviewable PR or explicitly linked recovery record:

1. **Adoption PR:** owner adopts or rejects this contract prospectively. No
   implementation code is included. This draft PR may become that adoption PR
   only after the explicit owner decision is recorded and the status in this
   same diff is changed from proposal to adopted.
2. **Kernel contract PR:** make the verdict schema and deterministic aggregator
   exact, fail-closed, SHA-bound, and mutation-tested. Keep integration inert.
3. **Runner isolation PR:** capture immutable diff/identities once, separate
   builder/reviewer runs, pre-existing oracles, capability checks, and durable
   run records. Provider identity remains attribution only.
4. **Baseline PR:** add property-specific baseline records, falsifiers,
   provenance, and separate Finding-retirement references.
5. **Shadow-extension PR:** implement two-generation candidate evaluation,
   shadow comparison, staged activation, rollback, and bounded audit logging;
   no self-adoption.
6. **Out-of-scope option:** a future integrator and its constitutional
   amendment are deliberately not designed or authorized by this proposal; the
   owner remains the only merge authority meanwhile.
7. **Activation decision:** run the complete acceptance matrix and the ordinary
   or full gate required by the touched paths. A failed, unavailable, or
   inconclusive check stops the sequence; it does not get downgraded.

This map is a plan, not authorization to execute any step.
