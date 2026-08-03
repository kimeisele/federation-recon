# Federation Digest

**Composed:** 2026-08-01T04:03:23Z
**Procedures:** 4 (see digest/ for per-procedure details)
**Attention items:** 4 (1 observatory)

## Procedure Summary

| Procedure | Version | Timestamp | Summary |
|---|---|---|---|
| `node-census-v1` | `v1` | 2026-08-01T04:02 | - |
| `v0-boundary-drift` | `v0` | 2026-08-01T04:03 | claims=30, coverage_records=7, drift_records=2, evidence=35, findings=5, observed_repositories=7, partial_failures=0, pins=7 |
| `v1-census` | `v1` | 2026-08-01T04:02 | coverage_records=7, error_nodes=0, evidence=60, findings=33, observed_nodes=7, ok_nodes=6, pins=7, stale_nodes=1, staleness_threshold_days=60 |
| `v2-consumption` | `v2` | 2026-08-01T04:03 | coverage_records=6, cycle=7, finding_references=0, observed_repositories=6, partial_failures=0, pins=6, repo_references=0, total_consumption_records=0 |

## Ranked Attention (needs operator decision)

| # | Target | Status | Procedure | Headline | Evidence |
|---|---|---|---|---|---|
| 1 | `kimeisele/*` | ✅ observed | `v2-consumption` | ZERO Finding consumption: No external repository references any federation-recon Finding ID. 0 repo-mentions (weaker evidence). Cycle 7 of 10 — F-02 falsifier is active if this persists across ten cycles. | consumption/ |
| 2 | `kimeisele/steward` | ✅ observed | `v0-boundary-drift` | Boundary drift: Role mismatch: REPO_BOUNDARIES.md asserts role: Autonomous Engine but steward/.well-known/agent-federation.json self-dec | findings/finding-5cd51c7f5fed.json, drift/drift-0064abff93ac.json |
| 3 | `kimeisele/agent-internet` | ✅ observed | `v0-boundary-drift` | Boundary drift: Absent self-declaration: REPO_BOUNDARIES.md asserts agent-internet role: Control Plane + Projection but agent-internet/. | findings/finding-194863fb230b.json, drift/drift-d2d7cfe7156b.json |
| 4 | `kimeisele/agent-world` | ⚠️ stale | `v0-boundary-drift` | REPO_BOUNDARIES.md last audited 2026-03-15 — boundary source may be stale | findings/, claims/ |

## Constitutional Observatory

These repositories are constitutional non-peers (§5). They are tracked for
liveness (FR-CON-011) but are not ranked as federation attention items.

| # | Target | Status | Procedure | Headline |
|---|---|---|---|---|
| 1 | `kimeisele/federation-recon` | ✅ observed | `v1-census` | Constitutional non-peer kimeisele/federation-recon — no descriptor expected (§5) |

## Budget

Per-procedure budget details are in the machine-readable digest and individual sub-digests.
See `digest/state-digest.json` and `digest/<procedure_id>.json`.

## Navigation (progressive disclosure)

```
Federation Digest (this file)
    ↓
Per-procedure sub-digests — digest/<procedure_id>.json
    ↓
Findings — findings/ (interpreted observations with lifecycle)
    ↓
Evidence — evidence/ (deterministic observations)
    ↓
Repository Pins — pins/ (exact commit references)
    ↓
Raw repository references — original GitHub repos at pinned SHAs
```

## Sub-digests

- [`census-candidates`](digest/census-candidates.json)
- [`v0-boundary-drift`](digest/v0-boundary-drift.json)
- [`v1-census`](digest/v1-census.json)
- [`v2-consumption`](digest/v2-consumption.json)

## Composition Contract

See `procedures/DIGEST_CONTRACT.md` for how procedures contribute to this digest.
