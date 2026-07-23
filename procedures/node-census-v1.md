# Procedure Manifest — Federation Node Census v1

- **Procedure ID:** `node-census-v1`
- **Version:** `v1`
- **Scope:** Discover and census all auffindbaren Federation Nodes via the GitHub topic `agent-federation-node`. Broad, flat, deterministic: no deep drift analysis, only Presence/Liveness/Role per node. Produces a single ranked Federation Digest.
- **Claim sources:** Not applicable (Census is discovery-based, not claim-based).
- **Repository set:** Dynamic — discovered via `gh search repos "topic:agent-federation-node"` plus self-observation (`kimeisele/federation-recon`, FR-CON-011).
- **Inputs:**
  - GitHub topic `agent-federation-node` (via `gh search repos`)
  - `.well-known/agent-federation.json` per discovered node (if present)
  - Charter document `docs/authority/charter.md` per discovered node (if present)
  - Last commit date on default branch per node (liveness)
- **Required tools:** `git`, `gh` (GitHub CLI 2.x), `rg` (ripgrep), `python3` (for JSON parsing and schema validation)
- **Optional tools:** `jq` (graceful degradation per FR-CON-010)
- **Outputs:**
  - Repository Pin artifacts → `pins/<repo-slug>.json` (schema: `schemas/repository-pin.schema.json`)
  - Evidence artifacts → `evidence/<evidence-id>.json` (schema: `schemas/evidence.schema.json`)
  - Finding artifacts → `findings/<finding-id>.json` (schema: `schemas/finding.schema.json`)
  - Coverage Record artifacts → `coverage/<coverage-id>.json` (schema: `schemas/coverage-record.schema.json`)
  - Machine-readable Census Digest → `digest/state-digest.json`
  - Human-readable Census Digest → `STATE.md` (updated)
- **Failure semantics:** Each node is processed independently. A non-terminal failure for one node (network error, missing file, rate limit) produces a partial Coverage Record for that node and continues. A terminal failure (disk full, total API failure) aborts the run. The run must not silently succeed on partial data.
- **Determinism requirement:** Identical repos discovered + identical procedure version must produce identical Evidence (FR-CON-012). Discovery is deterministic given the same GitHub state at the same time window. `--reproduce` mode uses pre-pinned repository data to produce byte-identical evidence.

## Staleness threshold

Proposed: **60 days.** A node is marked `stale` if its last commit is older than 60 days relative to the run timestamp. Configurable via `RECON_STALE_DAYS` env var. Final value per operator review/decision.

## Operations

| # | Operation | Output |
|---|---|---|
| 1 | Discover nodes via GitHub topic search | Node list (internal) |
| 2 | Add self (federation-recon) per FR-CON-011 | Self in observed set |
| 3 | Resolve and pin each repository | `pins/*.json` |
| 4 | Evidence: .well-known/agent-federation.json existence | `evidence/*.json` |
| 5 | Evidence: role, tier/layer from .well-known | `evidence/*.json` |
| 6 | Evidence: charter existence (docs/authority/charter.md) | `evidence/*.json` |
| 7 | Evidence: last commit date (liveness) | `evidence/*.json` |
| 8 | Create Findings with lifecycle per node | `findings/*.json` |
| 9 | Record Coverage | `coverage/*.json` |
| 10 | Perform self-observation (FR-CON-011) | Self-Finding |
| 11 | Generate ranked census digest + STATE.md | `digest/state-digest.json`, `STATE.md` |
| 12 | Enforce budget | Budget check |

## Execution

```shell
# Full live census — discovers nodes from GitHub topic
bash scripts/node-census-run.sh

# Reproduce — use pre-pinned node data
RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce
```

## Version history

| Version | Date | Author | Changes |
|---|---|---|---|
| v1 | 2026-07-23 | Operator | Initial Federation Node Census procedure (Slice v1) |
