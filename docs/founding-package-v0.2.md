# Federation Recon — Founding Package v0.2

**Status:** Revised founding draft
**Date:** 2026-07-22
**Repository candidate:** `federation-recon`
**Architecture judgment:** Revise complete; Boundary Drift Recon v0 is provisionally authorizable
**Implementation status:** Locked until the founding decision record accepts this package
**Primary sources:** Foundation Study and focused adversarial review by Fable

---

## 0. Purpose

This package defines the founding boundaries, artifact model, operating model, and first vertical slice for `federation-recon`.

It does not create a new federation authority.

It exists to turn reconnaissance from a session-bound agent skill into a durable, reproducible, GitHub-native system capability.

This version incorporates the five revisions required by the adversarial review:

1. constitutional self-observation,
2. a three-state MVP lifecycle,
3. removal of baseline dependency from Slice v0,
4. mandatory progressive disclosure and digest output,
5. explicit falsification and abort criteria.

---

# 1. Confirmed problem

The federation already possesses strong reconnaissance capability inside individual agent sessions.

Existing repositories contain:

- cross-repository recon documents,
- execution evidence collections,
- boundary maps,
- audit and drift modules,
- repository graph outputs,
- and manually pinned architecture studies.

The missing capability is not reconnaissance itself.

The missing capability is a durable system for:

- storing evidence in a canonical home,
- binding observations to exact commits,
- reproducing how evidence was generated,
- detecting when observations become stale,
- measuring drift between documented claims and repository reality,
- showing coverage gaps,
- and presenting federation state to expensive reasoning models without requiring them to read every repository from scratch.

The problem is therefore simultaneously:

- an evidence-residence problem,
- a decay-detection problem,
- a reproducibility problem,
- a coverage problem,
- and a token-efficiency problem.

---

# 2. Founding hypothesis

The working hypothesis is:

> `federation-recon` should be a dedicated, GitHub-native, read-only observatory that stores layered evidence and deterministic recon outputs for AI operators.

It is not a runtime node.

It is not a public federation peer.

It is not a governance authority.

It is the external memory and inspection surface through which agents can understand the federation efficiently and verify their conclusions against pinned evidence.

---

# 3. Operator model

The system has two deliberately separated layers.

## 3.1 Deterministic evidence layer

This layer:

- resolves Git repositories and commit pins,
- performs file, structure, claim, and drift observations,
- generates reproducible evidence,
- records coverage,
- and produces machine-readable outputs.

No LLM is permitted in this path.

## 3.2 Interpretation and consumption layer

This layer may use an expensive model to:

- read federation digests,
- inspect Findings,
- navigate into Evidence,
- formulate hypotheses,
- compare domains,
- and request deeper recon.

An LLM may assist in drafting Findings or summaries only when every conclusion cites deterministic Evidence.

The governing rule is:

> No LLM in the Evidence path. LLMs are permitted in the Finding and Digest path only with mandatory Evidence citation.

---

# 4. Progressive disclosure

Every recon output must be navigable from compressed federation state down to raw references.

The mandatory hierarchy is:

```text
Federation Digest
    ↓
Repository / Domain Digest
    ↓
Finding
    ↓
Evidence
    ↓
Raw repository reference
```

## 4.1 Federation Digest

A compact entry point for an operator.

It must include:

- observed repository set,
- coverage freshness,
- active Findings by severity or domain,
- stale or failed procedures,
- self-observation status,
- and links to lower layers.

The first implementation may use `STATE.md` plus a machine-readable equivalent.

## 4.2 Repository or domain digest

Summarizes one repository or architectural domain without reproducing all evidence.

## 4.3 Finding

An interpreted, evidence-backed observation.

## 4.4 Evidence

A deterministic observation bound to exact repository pins and procedure versions.

## 4.5 Raw reference

A path, line or structural reference into the original pinned Git repository.

No source copy is required inside Recon.

---

# 5. Proposed identity

`federation-recon` is:

> A bounded, read-only observatory and context compiler for reproducible understanding of federation repositories, claims, boundaries, structure, drift, provenance, and coverage.

It is not:

- a federation peer,
- a Nadi participant,
- a heartbeat-producing runtime,
- a router,
- a trust authority,
- a registry owner,
- an executor,
- a healer,
- a public projection layer,
- a legislature,
- or a canonical source of domain truth.

---

# 6. Constitutional invariants

## FR-CON-001 — No self-created authority

Recon may observe claims and differences but may not create normative federation rules.

## FR-CON-002 — No autonomous remediation

Recon may not modify observed repositories, open remediation pull requests, merge changes, or execute healing actions.

## FR-CON-003 — No public projection by default

Findings must not be publicly projected without explicit external authorization.

## FR-CON-004 — No registry ownership

Recon never defines which repositories, peers, cities, worlds, or agents exist.

## FR-CON-005 — No implicit truth elevation

A Finding is an evidence-backed observation, not automatically canonical truth.

Any citation of a Finding must include its lifecycle state.

## FR-CON-006 — No blocking authority in the MVP

No Recon output may block another repository during the MVP.

A future check may become blocking only when:

1. the invariant was formally established outside Recon,
2. the responsible authority or repository owner adopted it,
3. the check is deterministic and reproducible,
4. and the adoption decision is explicitly referenced.

Recon may execute such a rule but may not author it.

## FR-CON-007 — Reproducible evidence

Every material observation must record:

- repository identity,
- requested ref,
- resolved commit SHA,
- observation timestamp,
- procedure identifier and version,
- relevant paths or structural references,
- and hashes where applicable.

## FR-CON-008 — No vendored source and no excerpts in the MVP

The MVP may store only:

- repository pins,
- paths,
- hashes,
- counts,
- line or structural references,
- manifests,
- and derived records.

Source excerpts are prohibited until a numeric retention and size policy explicitly permits them.

## FR-CON-009 — Bounded storage

Retention, compaction, and size budgets must be numerically defined before automated recurring evidence generation begins.

## FR-CON-010 — Graceful capability degradation

Optional sensors must not be required for baseline recon.

If an optional tool is unavailable, the run continues and records the missing capability.

## FR-CON-011 — Constitutional self-observation

`federation-recon` must include itself in its observed set.

Every scheduled run must record:

- whether the previous expected run occurred,
- whether its outputs were complete,
- whether its procedures remain reproducible,
- and whether the current Digest and Coverage records are fresh.

A missed or failed expected run must deterministically produce an `observed` Finding about Recon itself.

Self-observation is not optional maintenance metadata. It is part of the system's constitutional survival model.

## FR-CON-012 — Deterministic Slice v0

Boundary Drift Recon v0 must be fully deterministic.

If identical pins and the same procedure version do not produce identical evidence outputs, the slice fails its founding objective.

---

# 7. Governance posture

No federation-wide audit authority is established by this package.

In particular:

- `agent-world` is not assumed to own federation-wide audit direction,
- a README claim is not treated as federation-wide constitutional legitimacy,
- and Slice v0 does not require a central audit-direction owner.

For Slice v0, audit scope is defined by the versioned Procedure Manifest.

This is sufficient because the slice only observes explicit claims and repository reality.

Questions of:

- acknowledgement,
- dispute,
- accepted deviation,
- normative audit scope,
- and blocking checks

remain deferred until a later slice requires them.

A likely future model is domain-scoped adjudication, but it is not encoded here.

---

# 8. MVP artifact model

## 8.1 Repository Pin

Identifies the exact repository state observed.

Required fields:

- repository,
- requested ref,
- resolved commit SHA,
- observation timestamp,
- acquisition method,
- and dirty-state assertion where applicable.

## 8.2 Evidence

A deterministic observation bound to a Repository Pin.

Examples:

- file existence,
- path inventory,
- file count,
- workflow presence,
- dependency occurrence,
- manifest field,
- or documented repository claim.

Evidence is not a conclusion.

## 8.3 Claim Observation

Records that a selected source asserts something.

Recon owns the observation of the claim, not the claim itself.

## 8.4 Finding

An interpreted statement derived from Evidence.

Every Finding must link to all supporting Evidence.

## 8.5 Drift Record

A structured difference between:

- a Claim Observation,
- and a deterministic current observation.

No external baseline is required for Slice v0.

## 8.6 Coverage Record

Records:

- what was inspected,
- when,
- at which commit,
- with which procedure version,
- using which capabilities,
- and with what result.

## 8.7 Procedure Manifest

Defines:

- scope,
- claim sources,
- repository set,
- version,
- inputs,
- required tools,
- optional tools,
- outputs,
- failure semantics,
- and determinism requirements.

## 8.8 Digest

Provides progressive disclosure for AI operators.

Required Slice-v0 outputs:

- `STATE.md`
- machine-readable state digest
- links to Findings, Evidence, Coverage, and self-observation status

## 8.9 Retention Record

Records whether evidence is:

- retained,
- compacted,
- superseded,
- or removed according to policy.

## 8.10 Baseline / Expectation

Reserved for future slices.

Recon may consume a formally sourced baseline but must not invent one.

Slice v0 does not require this artifact.

---

# 9. MVP lifecycle

Only automatic, non-normative states exist in the MVP.

## `observed`

A deterministic procedure produced a Finding from Evidence.

It means:

> This condition was reproducibly observed.

It does not mean:

> This interpretation has been accepted as canonical truth.

## `stale`

The Finding can no longer be relied upon because:

- its repository pins are outdated,
- its procedure version is obsolete,
- its supporting Evidence is incomplete,
- or its expected refresh did not occur.

## `superseded`

A newer Finding replaces the earlier observation or interpretation.

No `acknowledged`, `disputed`, `accepted_deviation`, or `resolved` state exists in the MVP schema.

Those states may be introduced only after a legitimate governance and ownership model exists.

---

# 10. Separation from existing repositories

## `steward-protocol`

May provide protocol and verification primitives.

Recon must not duplicate protocol authority or parser-like protocol definitions.

## `agent-world`

May be an observed source of world and boundary claims.

No federation-wide audit-direction authority is assumed.

## `agent-internet`

May later provide optional repository graph or crawl artifacts.

Slice v0 must not depend on or consume those outputs.

Reuse may be evaluated at the artifact boundary from Slice 2 onward.

## `steward`

May consume Findings and later plan remediation.

Recon must not inherit healing or orchestration responsibilities.

## `agent-city`

Is an observed local runtime and possible source of execution claims.

Recon must not become a runtime dependency.

## `steward-federation`

Is an observed transport repository.

Recon must not become another mailbox, relay, Nadi layer, or transport peer.

---

# 11. Tool policy

## 11.1 Required baseline

- `git`
- GitHub CLI (`gh`)
- `ripgrep` (`rg`)
- minimal scripting already accepted by the repository

## 11.2 Optional later sensors

- `ast-grep`
- Tree-sitter-based extractors
- `ctags`
- lightweight dependency analyzers
- external cross-repository code graphs
- selected `agent-internet` outputs

## 11.3 Excluded from Slice v0

- LLMs in evidence generation,
- graph databases,
- persistent services,
- embeddings,
- vector databases,
- Joern,
- CodeQL,
- Kythe,
- custom parsers,
- custom search engines,
- custom crawler platforms,
- and proprietary indexing services.

External tools remain replaceable sensors.

Recon-owned neutral schemas remain canonical for Recon artifacts.

---

# 12. Boundary Drift Recon v0

## 12.1 Objective

Detect drift between selected documented repository-boundary claims and deterministic observations of pinned GitHub repository states.

## 12.2 Inputs

- explicit repository manifest,
- explicit claim-source list,
- pinned or resolvable repository refs,
- versioned Procedure Manifest.

No baseline or expectation source is required.

## 12.3 Operations

1. resolve exact repository commits,
2. record Repository Pins,
3. extract selected claims,
4. run deterministic observations,
5. compare each claim with current observations,
6. create Evidence and Drift Records,
7. create or supersede Findings,
8. update Coverage,
9. perform Recon self-observation,
10. generate `STATE.md` and machine-readable Digest,
11. enforce retention and size budgets.

## 12.4 Non-goals

- full AST analysis,
- semantic code understanding,
- vulnerability scanning,
- live heartbeat analysis,
- runtime-state monitoring,
- automated remediation,
- automated PR creation,
- public publishing,
- federation-wide graph construction,
- agent-internet graph consumption,
- migration of all historical audit artifacts,
- normative acknowledgement workflow.

## 12.5 Success criteria

Another independent agent must be able to:

- clone Recon,
- inspect the Procedure Manifest,
- rerun the slice against the same commits,
- reproduce identical deterministic Evidence,
- navigate from `STATE.md` to a Finding,
- navigate from the Finding to Evidence,
- navigate from Evidence to pinned repository references,
- distinguish observation from authority,
- and verify Recon's own freshness status.

---

# 13. Consumption path

During Foundation and MVP, the primary consumption path is:

> An operator session opened inside the private `federation-recon` repository, beginning with `STATE.md`.

No API is required.

No persistent service is required.

No public projection is required.

The operator reads progressively:

1. federation state,
2. affected repository or domain,
3. Finding,
4. Evidence,
5. raw pinned repository references.

This consumption model is part of the architecture, not merely documentation convenience.

---

# 14. Visibility and security

Provisional MVP posture:

- private repository,
- read-only access to observed repositories,
- write access only to itself,
- no automatic public exports,
- no source excerpts,
- no secret copying,
- redacted procedure logs where required.

A later sanitized public projection may be considered only after the artifact model and security policy are stable.

---

# 15. Retention and size policy

Numeric values must be accepted before recurring automation begins.

Recommended starting limits:

- target repository size: at most 50 MB,
- maximum growth per completed run: 1 MB,
- raw evidence retention: 90 days,
- durable retention: Findings, Digests, Procedure Manifests, pins, and decision records,
- budget breach: fail the run and create a self-Finding,
- no silent deletion to make a run appear successful.

These numbers are provisional until formally adopted.

---

# 16. Legacy policy

Slice v0 performs inventory only.

Existing recon and audit artifacts remain in their source repositories.

Recon may record:

- repository,
- commit,
- path,
- artifact class,
- and possible future migration status.

No mass migration or deletion is permitted in the MVP.

---

# 17. Scaling posture

## Approximately 10 repositories

Scheduled full or mostly full scans are acceptable.

## Approximately 100 repositories

The design must support:

- SHA-based skip logic,
- independent per-repository jobs,
- sharding,
- separate aggregation,
- and manifests instead of copies.

## Approximately 1000 repositories

A mandatory architecture review is required before operation at this scale.

No claim is made that one Git repository remains the correct storage medium.

---

# 18. Founding falsifiers and abort criteria

The recommendation to continue with `federation-recon` is falsified or requires architectural suspension if any of the following occurs.

## F-01 — Reproducibility failure

An independent agent cannot reproduce identical Slice-v0 Evidence from:

- the same repository pins,
- the same Procedure Manifest,
- and the same tool versions.

Consequence:

- stop expansion,
- classify the evidence model or procedure design as invalid,
- and revise before any further slice.

## F-02 — No governance consumer

Across ten completed operational cycles, no relevant domain owner or operator ever consumes, references, or acts upon any Finding.

Consequence:

- reassess whether a separate repository is justified,
- compare against the simpler convention-only architecture,
- and suspend feature expansion.

This criterion does not require normative acknowledgement states in the MVP. Consumption may be measured through explicit references or downstream work records.

## F-03 — Storage-model failure

The repository exceeds its adopted size or growth budget despite:

- manifest-only storage,
- no source excerpts,
- and enforced retention.

Consequence:

- stop recurring writes,
- reassess Git as the evidence-store architecture,
- and do not solve the problem by silently increasing budgets.

---

# 19. Remaining decision gates

The following questions remain open but do not block Slice v0 unless explicitly stated.

## DG-01 — Future acknowledgement governance

Required before introducing normative lifecycle states.

## DG-02 — Federation-wide audit direction

Not required for Slice v0.

Must be revisited only if federation-wide normative audit scope is proposed.

## DG-03 — Future blocking checks

Categorically excluded in the MVP.

## DG-04 — Long-term visibility

Private for MVP; later architecture remains open.

## DG-05 — Live state

Excluded from Foundation and Slice v0.

## DG-06 — Numeric budget adoption

Must be resolved before recurring automation begins.

## DG-07 — Agent Internet reuse

Deferred until Slice 2 or later.

## DG-08 — Legacy migration

Inventory-only in MVP.

## DG-09 — Survival model

Resolved structurally for MVP through FR-CON-011 self-observation.

## DG-10 — Canonical terminology

A founding `GLOSSARY.md` is required before implementation completes.

---

# 20. Founding implementation lock

Before Slice v0 is authorized, the founding decision must explicitly adopt:

- this package,
- numeric size and retention limits,
- the private MVP posture,
- the three falsifiers,
- and the fully deterministic requirement.

Until then, agents must not:

- build a generalized CLI,
- integrate AST or graph systems,
- create cross-repository write permissions,
- add required checks to other repositories,
- consume `agent-internet` graph outputs,
- migrate historical audit artifacts,
- or publish Recon findings.

Allowed preparation:

- repository manifest drafting,
- claim-source inventory,
- Procedure Manifest design,
- schema examples,
- glossary drafting,
- and deterministic tool feasibility probes.

---

# 21. Decision recommendation

**Recommendation: GO after founding adoption.**

The required adversarial revisions have been incorporated.

Boundary Drift Recon v0 is a sufficiently narrow and deterministic first slice because it:

- solves a verified current problem,
- requires no new authority,
- requires no baseline owner,
- has no live-state overlap,
- needs no heavy analysis stack,
- demonstrates progressive disclosure,
- tests self-observation,
- and contains explicit conditions under which the entire approach must be reconsidered.

The authorized interpretation of `federation-recon` is:

> A private, GitHub-native, self-observing, read-only observatory and context compiler that allows AI operators to understand federation state through layered, reproducible evidence without becoming a runtime, governor, healer, registry, or public membrane.
