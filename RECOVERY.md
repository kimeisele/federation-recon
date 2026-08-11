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
general different-model and different-provider requirements from the operating
contract. Specify architectural review independence and the two-generation
trust-kernel protocol instead. Adopt constitutional changes prospectively only
through an explicit owner decision, not a technical PR.

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

---

## RECOVERY-0 — forensic classification — READY FOR OWNER SIGN-OFF (2026-08-10)

Detailed evidence and per-PR records: issue #236 (comments of 2026-08-10). Durable conclusions:

**Quarantine range `5b964a4..2cc5bfb`:** 14 changed files; five touch `scripts/review.sh`. Full list and per-PR semantic records in #236.

**Reconnaissance core — scope verified; reproduction evidence is environment-specific.** An earlier revision claimed reproduction from a CI run at `2cc5bfb`; that was a **push** run where `reproduce-fixpoint` is skipped (`.github/workflows/ci.yml:78`, gated on `pull_request`). Linux `reproduce-fixpoint` completed successfully on PR #247 at `2b4ee0c`, proving that the committed artifacts equal the workflow's fresh `--reproduce` result in that run. An independent macOS attempt at `a93babb` did not complete: several GitHub reads became partial and `scripts/recon-run.sh` exited at line 1060 with an unbound `CLAIM_FILES["rb-agent-world"]`; the chained census, consumption, composer, and final diff never ran. This is evidence that `--reproduce` is not offline and that its failure semantics still need disposition. **Property-specific:** the quarantine did not change the recon paths, and one Linux workflow reached the committed-artifact fixpoint. There is no repository-wide trust claim, global trusted baseline, or independently confirmed macOS fixpoint.

**Baseline `5b964a4` — REJECTED as a clean recovery base.** The approval fail-open is present there in full: `scripts/review.sh:350-360` downgrades a blocking finding to `non-blocking/inconclusive` keeping `claimed_severity`, and `scripts/review-verdict.sh:67` keys Rule 4 on `severity`. The disease predates the quarantine range. Rolling back to `5b964a4` reinstates the fail-open; the correct recovery is forward.

**Per-PR dispositions** (evidence in #236; discrimination mutations for #223/#224/#229/#231/#232 run first-hand by the operator):

| PR | disposition |
|---|---|
| #215 token caps | rebuild (intent appears bounded but is not independently verified; shares the quarantined file; RECOVERY-3) |
| #223 provider-probe clock | retain (audit zone, not review control) |
| #224 Tier 0 from CI | rebuild (verdict input; re-express fail-closed) |
| #229 thinking-by-model | retain-with-audit (request shaping only) |
| #231 base discrimination | rebuild (its downgrade feeds the fail-open) |
| #232 confinement | rebuild (same coupling; runs as operator uid, #233) |

**RECOVERY-0 is ready for owner sign-off as a forensic classification, not as a repair or global trust decision.** The evidence supports rejecting the proposed baseline and using the quarantine dispositions for recovery planning, but the owner has not yet adopted that status transition in a durable repository artifact. The macOS reproduction failure is a confirmed residual with proposed disposition `REBUILD` in issue #248. Recon artifacts retain only the property-specific Linux fixpoint evidence stated above; all broader semantic trust remains out of scope.


### Correction 2026-08-10 (independent review)

- RECOVERY-0 reopened to IN PROGRESS; the reproduction claim is corrected above with both the successful Linux workflow and the failed independent macOS attempt.
- PR #238 is **REBUILD**: its aggregator keys on `claimed_severity`, which the verdict schema forbids (`additionalProperties: false`), so the field never reaches the aggregator in production — a vacuous-green oracle; the fail-open remains. Needs a true end-to-end test through `write_verdict()`.
- PR #242 is **REBUILD**: missing/unparseable diff counts default to LOW (fail-open); booleans/negatives not rejected. Invalid counts must be terminal PARTIAL/UNKNOWN, never LOW.
- Both candidates rejected, not reopened; branches kept as evidence. RECOVERY-2 re-derived fresh.
- Owner decisions (#236): independence procedurally mandatory (other provider optional); owner is root-of-trust and merges manually until a least-privilege integrator exists; baselines are component/property-specific.

### Proposed RECOVERY-0 sign-off

- `5b964a4` is rejected as a clean control-plane baseline.
- There is no repository-wide trusted baseline.
- The six incident PR dispositions above are proposed only as recovery routing decisions, not proof that retained code is semantically correct.
- Environment-dependent reproduction and the partial-read crash are routed to #248 as `REBUILD`; no fix was attempted in RECOVERY-0.
- PR #238 and #242 remain rejected candidates and must be re-derived in RECOVERY-2.
- Next workstream: RECOVERY-1 Part B, prospective adoption of the executable trust contract.

### RECOVERY-1 Part B — OWNER-ADOPTED PROSPECTIVELY — 2026-08-11

The owner-adopted prospective contract is recorded in
[`docs/recovery-1-contract.md`](docs/recovery-1-contract.md). It defines
architectural review independence, the deterministic fail-closed trust kernel,
owner-alone manual merge; any future integrator is outside this adopted
contract and requires a separate constitutional amendment; it also defines
property-specific baselines and safe two-generation self-extension. Provider
diversity is optional metadata, not the independence property.

The owner decision is evidenced by
[`governance/owner-decisions/251.md`](governance/owner-decisions/251.md) and
the appended amendment entry. This adopts the normative contract prospectively
only; RECOVERY-2 kernel/runner implementation remains unadopted, and this
decision authorizes no credentials, permissions, branch-ruleset, or merge-
authority change. Historical records remain unchanged.

The owner record is audit evidence only, bound to the exact base SHA and
complete PR-diff digest by the review-control gate; it is not authentication.
Actual authority remains the protected manual owner merge or external owner
instruction, which the repository cannot distinguish from an operator holding
an owner token.
