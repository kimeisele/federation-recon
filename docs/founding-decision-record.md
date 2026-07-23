# Founding Decision Record

**Status:** ADOPTED — 2026-07-23.

Per founding package §20, Slice v0 (Boundary Drift Recon) is authorized by this record. This record adopts `docs/founding-package-v0.2.md` in full, subject to the visibility revision recorded below.

## Required for adoption

- [x] Adopt `docs/founding-package-v0.2.md` in full (with the §14 / FR-CON-003 visibility revision below)
- [x] Adopt numeric size and retention limits (§15) — recorded below
- [x] Adopt the visibility posture (§14) — **revised from private to public metadata-only**, see below
- [x] Adopt the three falsifiers F-01, F-02, F-03 (§18) — unchanged
- [x] Adopt the fully deterministic requirement for Slice v0 (FR-CON-012) — unchanged

## Visibility revision (deviation from the original §14 private posture)

The original founding package proposed a **private** MVP repository (§14) and "no public projection by default" (FR-CON-003). The operator explicitly decided, on 2026-07-23, that `federation-recon` is and remains **public**, so that external operators and connectors can read federation state directly.

This is adopted as the **public metadata-only observatory** posture, not left as an ad-hoc deviation:

- The repository is public; external access is read-only.
- **No source excerpts** (FR-CON-008), **no secret copying**, no sensitive raw evidence are ever published.
- Recon stores and exposes only pins, paths, hashes, counts, manifests, derived records, and redacted logs.
- **No active external projection or distribution** of Findings (revised FR-CON-003) — passive repository readability only.

§14 and FR-CON-003 in `docs/founding-package-v0.2.md` were updated to reflect this. Document and reality are now reconciled (closes scope-finding open question #5).

## Adopted numeric limits

| Parameter | Provisional value (§15) | Adopted value | Adopted on |
|---|---|---|---|
| Target repository size | ≤ 50 MB | ≤ 50 MB | 2026-07-23 |
| Warning threshold per completed run | (not previously defined) | 250 KB | 2026-07-23 |
| Max growth per completed run (hard abort) | ≤ 1 MB | ≤ 1 MB | 2026-07-23 |
| Raw evidence retention | 90 days | 90 days | 2026-07-23 |

Additional adopted budget rules (§15):

- **No silent deletion** to make a run appear successful.
- A **budget breach fails the run and creates a self-Finding** (per FR-CON-011).
- Durable retention (never subject to the 90-day raw-evidence expiry): Findings, Digests, Procedure Manifests, pins, and decision records.

The 250 KB warning threshold is evidence-backed: `docs/scope-finding-slice-v0.md` estimates a full Slice v0 run at roughly 35–65 KB, so 250 KB gives ~4–5× headroom to catch runaway behavior well before the 1 MB hard abort.

## Falsifiers and determinism

- **F-01** (reproducibility failure), **F-02** (no governance consumer), **F-03** (storage-model failure) — adopted **unchanged** (§18).
- **FR-CON-012** (Slice v0 must be fully deterministic) — adopted **unchanged**.

## Decision

**ADOPTED.** Founding Package v0.2 is adopted with the public metadata-only visibility revision above. Boundary Drift Recon v0 (Slice v0) is formally authorized to be implemented, subject to the founding implementation lock (§20): no generalized CLI, no AST/graph systems, no cross-repository write permissions, no required checks on other repositories, no `agent-internet` graph consumption, no legacy migration, and no publishing of Findings beyond passive public readability.

Slice v0 is authorized but **not yet implemented**. Implementation is a separate, subsequent engineering task.

## Adopted by / date

Adopted by the operator (`kimeisele`), on the recommendation of the acting tech lead architecture review (GO after the single visibility reconciliation). **Date: 2026-07-23.**
