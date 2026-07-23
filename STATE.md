# Federation Digest

**Generated:** 2026-07-23T16:51:46Z
**Procedure:** `boundary-drift-recon-v0` / `v0`
**Run result:** success
**Self-observation status:** OK — run completed with all repositories observed

## Observed repositories

| Repository | Commit | Pin |
|---|---|---|
| `kimeisele/steward-protocol` | `34a8a0efc25c` | `pins/steward-protocol.json` |
| `kimeisele/agent-world` | `6771524abef2` | `pins/agent-world.json` |
| `kimeisele/agent-internet` | `dcd0206434b2` | `pins/agent-internet.json` |
| `kimeisele/steward-federation` | `b6f1379914f5` | `pins/steward-federation.json` |
| `kimeisele/steward` | `7134341ff292` | `pins/steward.json` |
| `kimeisele/agent-city` | `8694d81e545d` | `pins/agent-city.json` |
| `kimeisele/federation-recon` | `61dc947c8b66` | `pins/federation-recon.json` |


## Findings summary

- No drift detected in this run
- 1 self-observation finding(s)

## Drift summary

**No drift detected.** All observed claims match current repository state.

## Budget

22908B total (warn: 256000B, abort: 1048576B)

## Navigation (progressive disclosure)

```
Federation Digest (this file)
    ↓
Repository Pins — pins/ (one per observed repo)
    ↓
Claim Observations — claims/ (extracted from claim sources)
    ↓
Evidence — evidence/ (deterministic observations)
    ↓
Drift Records — drift/ (where claim ≠ observation)
    ↓
Findings — findings/ (interpreted observations)
    ↓
Coverage — coverage/ (what was inspected)
    ↓
Raw repository references — original GitHub repos at pinned SHAs
```

## Links

| Artifact | Directory | Schema |
|---|---|---|
| Repository Pins | `pins/` | `schemas/repository-pin.schema.json` |
| Claim Observations | `claims/` | `schemas/claim-observation.schema.json` |
| Evidence | `evidence/` | `schemas/evidence.schema.json` |
| Drift Records | `drift/` | `schemas/drift-record.schema.json` |
| Findings | `findings/` | `schemas/finding.schema.json` |
| Coverage Records | `coverage/` | `schemas/coverage-record.schema.json` |
| Machine-readable Digest | `digest/state-digest.json` | — |

## Procedure Manifest

See `procedures/boundary-drift-recon-v0.md` for the full procedure definition.
