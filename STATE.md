# Federation Digest

**Composed:** 2026-07-23T18:15:03Z
**Procedures:** 2 (see digest/ for per-procedure details)
**Attention items:** 2 (2 observatory)

## Procedure Summary

| Procedure | Version | Timestamp | Summary |
|---|---|---|---|
| `v0-boundary-drift` | `v0` | 2026-07-23T18:14 | claims=28, coverage_records=14, drift_records=0, evidence=69, findings=19, observed_repositories=7, partial_failures=0, pins=14 |
| `v1-census` | `v1` | 2026-07-23T18:15 | coverage_records=14, error_nodes=0, evidence=69, findings=19, observed_nodes=14, ok_nodes=12, pins=14, stale_nodes=2, staleness_threshold_days=60 |

## Ranked Attention (needs operator decision)

| # | Target | Status | Procedure | Headline | Evidence |
|---|---|---|---|---|---|
| 1 | `kimeisele/agent-world` | ⚠️ stale | `v0-boundary-drift` | REPO_BOUNDARIES.md last audited 2026-03-15 — boundary source may be stale | findings/, claims/ |
| 2 | `kimeisele/*` | ✅ observed | `v0-boundary-drift` | No boundary drift detected across all observed repositories | findings/ |

## Constitutional Observatory

These repositories are constitutional non-peers (§5). They are tracked for
liveness (FR-CON-011) but are not ranked as federation attention items.

| # | Target | Status | Procedure | Headline |
|---|---|---|---|---|
| 1 | `kimeisele/agent-village` | ✅ observed | `v1-census` | Constitutional non-peer kimeisele/agent-village — no descriptor expected (§5) |
| 2 | `kimeisele/federation-recon` | ✅ observed | `v1-census` | Constitutional non-peer kimeisele/federation-recon — no descriptor expected (§5) |

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

- [`v0-boundary-drift`](digest/v0-boundary-drift.json)
- [`v1-census`](digest/v1-census.json)

## Composition Contract

See `procedures/DIGEST_CONTRACT.md` for how procedures contribute to this digest.
