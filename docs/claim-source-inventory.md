# Claim-Source Inventory — Slice v0

**Status:** verified real paths, narrow selection. Still preparation only (founding package §20) — inclusion here does not authorize any observation run, and inclusion does **not** elevate a document to truth. Every entry carries `authority_status: asserted_not_adjudicated` — Recon observes that the source asserts something, per §8.3; it does not adjudicate whether the assertion is correct.

Selection principle (per founding recommendation): register only explicit boundary/constitution documents and structured federation-descriptor files — not every README or Markdown file in the six repositories. A broad selection would turn Slice v0 into a semantic document-analysis project instead of a narrow, deterministic boundary-drift check.

## Primary cross-repository boundary source

```yaml
repository: kimeisele/agent-world
path: docs/REPO_BOUNDARIES.md
claim_scope: cross_repository_boundaries
selection_reason: >
  Single explicit table asserting role, code-reality summary, "owns", and
  "does not own" for all six Slice v0 repositories plus excluded ones
  (agent-template, agent-research, steward-gateway). This is the closest
  thing the federation has to a canonical boundary claim, and is the
  primary drift-check target for Slice v0.
authority_status: asserted_not_adjudicated
last_audited_per_document: 2026-03-15
```

## Per-repository structured federation descriptors

Machine-readable, present in an identical location in every repository — ideal for deterministic, low-volume observation (structured JSON diff, not prose parsing).

```yaml
- repository: kimeisele/steward-protocol
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: structured self-declaration of role/owner_boundary, identical schema across all six repos
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-world
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: same as above; owner_boundary field observed as "world_governance_surface"
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-internet
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: same as above
  authority_status: asserted_not_adjudicated

- repository: kimeisele/steward-federation
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: same as above
  authority_status: asserted_not_adjudicated

- repository: kimeisele/steward
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: same as above
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-city
  path: .well-known/agent-federation.json
  claim_scope: self_declared_repo_role
  selection_reason: same as above
  authority_status: asserted_not_adjudicated
```

## Per-repository constitution / boundary documents (narrow, one each)

Registered only where a repository has its own explicit constitution or scope document that could drift from `REPO_BOUNDARIES.md`'s summary of it. Not every doc in every `docs/` folder — see exclusions below.

```yaml
- repository: kimeisele/steward-protocol
  path: CONSTITUTION.md
  claim_scope: substrate_authority_and_invariants
  selection_reason: >
    Self-titled "SUPREME LAW", asserts substrate/root-of-trust role for the
    whole federation — directly relevant to whether steward-protocol's
    actual repository contents still match its claimed substrate-only role.
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-city
  path: docs/CONSTITUTION.md
  claim_scope: city_runtime_governance
  selection_reason: >
    Asserts agent-city's own governance model (MURALI cycle, article
    structure) independent of REPO_BOUNDARIES.md's external summary of it.
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-internet
  path: docs/PUBLIC_FEDERATION_SURFACE.md
  claim_scope: public_projection_boundary
  selection_reason: >
    agent-internet is documented as the control-plane/projection repo;
    this file specifically asserts what it projects publicly, which is
    the boundary most likely to drift (scope creep into publishing).
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-world
  path: docs/WORLD_CONSTITUTION.md
  claim_scope: world_governance_principles
  selection_reason: >
    Asserts foundational constitutional principles for world-level
    coordination (world truth vs city truth, substrate vs governance,
    projection vs authority). Explicitly registers initial offices and
    deferred powers. Directly relevant as a governance anchor alongside
    REPO_BOUNDARIES.md and FEDERATION_ROLES.md.
  authority_status: asserted_not_adjudicated

- repository: kimeisele/agent-world
  path: docs/FEDERATION_ROLES.md
  claim_scope: federation_role_definitions
  selection_reason: >
    Authoritative role definitions for every node in the federation.
    Contains role architecture diagram, per-repo role definitions with
    owns/does-not-own assertions, trust hierarchy, and maturity assessment.
    The most comprehensive single source of federation topology claims
    and a natural complement to REPO_BOUNDARIES.md's summary table.
  authority_status: asserted_not_adjudicated
```

## Self-observation source (FR-CON-011 only — not a federation-boundary claim)

```yaml
repository: kimeisele/federation-recon
path: docs/founding-package-v0.2.md
claim_scope: self_constitutional_invariants
selection_reason: >
  Used only to check Recon against its own constitutional invariants
  (FR-CON-001..012), never as a claim about another repository's boundary.
authority_status: asserted_not_adjudicated
```

## Explicitly not registered (and why)

- Every other `.md` file under each repo's `docs/` (e.g. `steward-protocol/docs/*`, `agent-city/docs/FEDERATION_DELEGATION_*`, `steward/docs/FEDERATION_*`) — these are implementation status reports, ADRs, and design notes, not boundary/constitution claims. Registering them would make Slice v0 a general document-drift scanner instead of a boundary check.
- `agent-world/docs/CROSS_REPO_ROADMAP.md` — plausible future candidate, deliberately deferred to keep the first source-count small; revisit once Slice v0's real run volume is known.
- READMEs of all six repos — none currently make an explicit cross-repository boundary claim distinct from `REPO_BOUNDARIES.md` or their own constitution/surface doc above; adding them now would be claim-source sprawl without a stated reason.

## Open scope questions

1. ~~Should `agent-world/docs/WORLD_CONSTITUTION.md` and `docs/FEDERATION_ROLES.md` be included alongside `REPO_BOUNDARIES.md`?~~ Resolved: both registered in v0 per Issue #20.
2. `REPO_BOUNDARIES.md` is dated "last audited 2026-03-15" — over four months stale relative to today (2026-07-23). Is a manually-dated claim source itself already a drift candidate before Slice v0 even runs?
3. `steward/README.md` and `steward-federation/README.md` are one-liners with no explicit boundary claim beyond role name — is repo-level silence itself worth an "absence of claim" record, or out of scope for v0?
