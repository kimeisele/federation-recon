# Scope Finding — Slice v0 (pre-adoption)

**Status:** preparation-only deliverable. Produced after replacing placeholders in `docs/repository-manifest.md` and `docs/claim-source-inventory.md` with verified real repositories and a narrow real claim-source list. Does **not** adopt the founding package, does not implement a procedure, and does not generate Evidence. Founding decision record (`docs/founding-decision-record.md`) is unchanged and still pending.

## What was verified

- All six candidate observed-set repositories (`steward-protocol`, `agent-world`, `agent-internet`, `steward-federation`, `steward`, `agent-city`) exist under `kimeisele/`, are non-empty, non-archived, and public — confirmed via `gh api repos/kimeisele/<repo>` on 2026-07-23.
- `federation-recon` itself is now public (visibility change made outside this scope task, at explicit operator instruction — see note below).
- A genuine cross-repository boundary document exists: `agent-world/docs/REPO_BOUNDARIES.md`, dated "last audited 2026-03-15," asserting owns/does-not-own for all six repos plus explicitly excluded ones.
- A structured, schema-identical `.well-known/agent-federation.json` descriptor exists in all six repos (and in `steward`, an extra `.well-known/agent.json`), making at least part of Slice v0 a clean JSON-diff rather than prose parsing.
- Three additional narrow constitution/boundary docs were selected (`steward-protocol/CONSTITUTION.md`, `agent-city/docs/CONSTITUTION.md`, `agent-internet/docs/PUBLIC_FEDERATION_SURFACE.md`) because they make claims not already covered by `REPO_BOUNDARIES.md`.

## Visibility note (deviation from founding package §14/FR-CON-003)

The operator explicitly instructed making `federation-recon` public now, to let an external agent/connector read it, overriding the founding package's default private MVP posture. This is a live, acknowledged deviation from §14 and FR-CON-003 ("no public projection by default... without explicit external authorization") — recorded here rather than silently absorbed. It has not been retroactively written into the founding package text; if this is meant to become the permanent posture, §14 and the founding decision record should be updated to say so explicitly rather than leaving the document and reality diverged.

## Estimated Slice v0 artifact volume (order-of-magnitude, not measured)

Based on the finalized observed set and claim-source list above, one full Slice v0 run would produce roughly:

| Artifact type | Estimated count | Est. size each | Est. total |
|---|---|---|---|
| Repository Pin | 7 (six observed + self) | ~250 B | ~1.8 KB |
| Claim Observation | ~30–40 (1 boundary-table row per repo ≈7, 6 structured descriptors, ~15–20 sub-claims from the 3 constitution/boundary docs, 1 self founding-package claim) | ~250–400 B | ~10–16 KB |
| Evidence | 1 per Claim Observation (comparison target) | ~300–500 B | ~12–20 KB |
| Drift Record | 0 to ~40 (only on mismatch; upper bound = all claims drift) | ~300 B | 0–12 KB |
| Finding | ~7–10 (roughly one per repo/domain, plus one self-observation finding) | ~400–600 B | ~4–6 KB |
| Coverage Record | 7 (one per observed repository) | ~300 B | ~2 KB |
| Digest (`STATE.md` + machine-readable) | 1 | 3–8 KB | ~5 KB |

**Total estimated per-run volume: roughly 35–65 KB**, with a pathological worst case (every claim drifts, verbose text fields) unlikely to exceed ~120 KB given the "no source excerpts" rule (FR-CON-008).

This estimate directly supports the operator's proposed tightening of §15's budgets: a 1 MB "hard" ceiling is far above any plausible Slice v0 run, so a lower **warn threshold (e.g. 250 KB)** would catch runaway behavior (e.g. an unintended full-text dump) long before the 1 MB hard-abort limit — as proposed, not yet adopted.

## Open scope questions (carried over, not resolved here)

1. Should `agent-world/docs/WORLD_CONSTITUTION.md` and/or `docs/FEDERATION_ROLES.md` be added to the claim-source list alongside `REPO_BOUNDARIES.md`, given all three live in the same repo and could assert different things?
2. `REPO_BOUNDARIES.md` is already ~4 months stale relative to today. Should Slice v0's first run treat that staleness itself as a `stale`-lifecycle Finding candidate, or is that out of scope until a real run exists?
3. Is repo-level silence (e.g. `steward-federation/README.md` and `steward/README.md` making no explicit boundary claim beyond a role name) itself worth recording as an "absence of claim" observation, or should Slice v0 only ever produce Findings where a claim exists to check?
4. `steward-gateway` and the `agent-template*` nodes are excluded as "not started" / scaffolding — should re-inclusion be automatic once they gain code, or does every observed-set change require an explicit Repository Manifest revision regardless of trigger? (Founding package implies the latter; not yet stated in the manifest itself.)
5. The public-visibility deviation above is unresolved as a durable decision — does it get written into §14 permanently, revert after Slice v0 is authorized, or stay an ad hoc, undocumented-in-the-package state?

## Explicitly not done in this task

- No change to `docs/founding-decision-record.md`.
- No Procedure Manifest instance created (only the template exists).
- No Evidence, Finding, Drift Record, or Coverage Record generated.
- No numeric budget formally adopted — the 250 KB/1 MB/50 MB figures above remain proposals pending adoption.
