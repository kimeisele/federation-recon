# Recovery control record

**Opened:** 2026-08-10
**Status:** containment and planning; no recovery implementation authorized
**Forensic head:** `2cc5bfb` (`origin/main` when this record was opened)
**Quarantine range:** `5b964a4..2cc5bfb`
**Baseline candidate:** `5b964a4` (a quarantine boundary, not yet a trusted baseline)
**Umbrella issue:** `#236`

This is the temporary source of truth for recovery from the 2026-08-09/10
review-control incident. It exists so a later operator can continue without
reconstructing the incident from chat. Delete it after the recovery is closed
and its durable conclusions have been moved to the appropriate contracts.

## Current decision

The repository is recoverable. The deterministic reconnaissance core was not
materially changed in the quarantine range. The review and execution control
plane is not trusted and must not authorize integration.

Until this record is superseded:

- do not merge or treat a generated review verdict as authority;
- do not run model-written verification commands outside proven confinement;
- do not merge PR #234 or #235;
- keep PR #226 outside recovery; it is an observation PR;
- keep WIP at one recovery workstream;
- do not rewrite history or mass-revert the quarantine range;
- do not change the constitution, risk envelope, credentials, permissions, or
  spending rules without an explicit owner decision;
- treat tests as evidence only for the property they were observed to measure.

The deterministic heartbeat currently reports `STOP` because three PRs are
open and WIP is limited to one.

## Why the control plane is quarantined

Confirmed semantic failures include:

1. A missing or failed sandbox changes a blocking finding to
   `non-blocking/inconclusive`. The verdict aggregator then ignores it and can
   return `APPROVE`.
2. Other inconclusive paths, including missing base data and timeouts, can take
   the same approval-compatible downgrade.
3. Review risk is hard-coded to `LOW`, so documented HIGH-risk triggers cannot
   operate.
4. Tier 2 is a `not_run` stub, not independent verification.
5. Builder/reviewer provider independence is recorded in prose but not enforced.
6. PR metadata is loaded once, while model-facing diffs are fetched again later;
   the analyzed diff is not reliably bound to the verdict SHA.
7. Multiple tests and oracles were green for the wrong reason: early abort,
   shared UTC assumptions, contradictory fixtures, and Python import failure
   instead of demonstrated network denial.

Affected merged work is PR #215 and PRs #223, #224, #229, #231, and #232.
The history is linear and preserved; this is a trust failure, not data loss.

## Trust zones

### Preserve and verify independently

- reconnaissance procedures and runners;
- pins, evidence, findings, schemas, digest composition, and fixpoint behavior;
- committed seed state and deterministic artifact reproduction.

### Audit before reuse

- `operator/heartbeat.sh`;
- `operator/run.sh` and `operator/dispatch.sh`;
- builder adapters and work-order parsing;
- execution-core capabilities and canaries.

### Quarantined

- `scripts/review.sh` and `scripts/review-verdict.sh`;
- review verdicts produced by the current pipeline;
- review work orders and provider claims not independently measured;
- inline sandbox profiles and tests that have not been observed to fail for the
  intended reason.

## Affordable trust contract to design toward

The founding package does not require a second model to rebuild code. It
requires deterministic Evidence to be reproducible without an LLM. There is no
general requirement for a different model or provider. Trust must come from the
architecture of the review process, not from an unaffordable vendor roster.

Keep these activities separate:

1. **Deterministic reproduction:** model-free and routine.
2. **Cheap untrusted work:** Flash/Luna/DeepSeek may perform reconnaissance,
   bounded builds, and review reasoning; their output is never self-authorizing.
3. **Architecturally independent review:** builder and reviewer use separate
   invocations, immutable inputs, fresh environments, independently derived
   oracles, and adversarial objectives. Deterministic controls decide whether
   the resulting evidence is sufficient.
4. **Optional external consultation:** another provider may add evidence when it
   is available and explicitly authorized, but is never a general prerequisite
   for review or operation.

Provider and model identity must still be measured for attribution and cost.
Neither identity grants authority. The same affordable model may build and
review when the process separation above is enforced; correlated model blind
spots are mitigated by mutation, differential checks, canaries, reproduction,
small diffs, staged activation, and rollback.

### Trust kernel and autonomous extension

The autonomous pipeline needs a small deterministic trust kernel that owns only
policy evaluation, immutable subject identity, capability checks, verdict state,
and bounded integration. Models propose patches, findings, and verification
ideas; they do not decide their own authority.

Ordinary repository work may eventually flow autonomously through that kernel.
Changes to the kernel itself use a two-generation protocol:

1. the old kernel evaluates the proposed new kernel against fixed invariants and
   deliberately broken fixtures;
2. the new kernel runs in shadow mode without integration authority;
3. old and new decisions are compared and unexplained divergence stops adoption;
4. activation is prospective, bounded, logged, and reversible.

No change may simultaneously redefine a rule, replace its oracle, and authorize
itself under the replacement.

## Serial recovery workstreams

Only one workstream may be active at a time.

### RECOVERY-0 — Forensic baseline and quarantine

Inventory `5b964a4..2cc5bfb` per PR: changed paths, claims, known false oracles,
measured behavior, and disposition (`retain`, `rebuild`, `discard`, `unknown`).
Verify that the reconnaissance core is outside the changed set. Do not repair
code in this workstream.

Done when the candidate baseline and every quarantined path have an evidenced
disposition. `5b964a4` must not be called trusted merely because it predates the
incident.

### RECOVERY-1 — Reconcile the normative and affordable contract

Complete the normative inventory started by PR #234. For each rule record its
source, actual behavior, enforcement, observed negative evidence, cost, and
status (`enforced`, `unenforced`, `contradictory`, `owner decision`). Separate
deterministic reproduction, model reasoning, and deterministic authority. Remove
general different-model and different-provider requirements from the proposed
operating contract. Specify architectural review independence and the
two-generation trust-kernel protocol instead. Draft constitutional changes
prospectively; do not adopt them in a technical PR.

Relevant existing work: #55, #220, PR #234.

### RECOVERY-2 — Rebuild the verdict boundary fail-closed

Design the smallest model-independent verdict contract first. No
`inconclusive`, missing dependency, stale SHA, parser failure, timeout, or
unsupported confinement state may produce `APPROVE`. The runner must not lower
the claimed severity. Bind policy, diff, worktrees, and verdict to immutable
identities.

Relevant existing work: #217, #218, #221 and the residuals from #196/#228.

### RECOVERY-3 — Authoritative spend reservation

Resolve #219 before any routine provider-backed review is restored. Reserve
budget atomically before a call; crash and concurrency remain conservatively
charged; the committed seed stays immutable. This workstream may not raise a
budget or buy/change credentials.

### RECOVERY-4 — Builder boundary and accounting

Resolve #225 and #230. Parse JSON as data, never through interpolated program
text. A parse failure must not empty path restrictions. Measure changes against
the base SHA so committed builder work is still visible.

### RECOVERY-5 — Measured confinement capability

Treat #233 and PR #235 as evidence, not as a ready solution. Put confinement
behind a measured capability contract. Unsupported platforms stop; they never
run unconfined. Every allow rule needs a negative canary and preservation half,
including a standalone `no_network` preservation probe.

## Universal acceptance rules

A recovery change is not complete unless:

- its claim is stated independently of its implementation;
- the relevant command was executed in the relevant environment;
- a disposable mutation makes the check fail for the intended reason;
- production and test do not carry independent copies of the same oracle;
- missing tools/data are distinguishable from a clean result;
- the subject SHA and diff identity are immutable;
- the diff is small enough to explain semantically;
- required cost and WIP records are correct;
- the handover records evidence, remaining uncertainty, and the next exact step.

Stop immediately if a mutation remains green, an unverified state can approve,
a verifier can mutate its subject, a provider identity is assumed rather than
measured, or prose claims a control that does not execute.

## Handover protocol

At the end of every recovery session append one short entry below with:

- UTC timestamp and branch/HEAD;
- active workstream;
- commands actually run and their outcomes;
- files or external state changed;
- confirmed findings and open uncertainty;
- exact next action and explicit blockers.

### 2026-08-10 — containment and plan

- Forensic head: `2cc5bfb`; worktree was clean.
- Heartbeat dry-run: `STOP`, WIP cap violated by three open PRs.
- Confirmed an approval fail-open in the review verdict path.
- Confirmed hard-coded LOW risk, Tier-2 stub, missing enforced independence, and
  diff/SHA TOCTOU.
- Corrected the target architecture: review independence is procedural and
  technical, not a mandatory different-provider requirement; autonomous
  self-extension is rooted in a deterministic two-generation trust kernel.
- No recovery code, merge, credential, permission, or constitutional change was
  made.
- Opened umbrella issue #236; no PR was opened.
- Next action: execute RECOVERY-0 only.
