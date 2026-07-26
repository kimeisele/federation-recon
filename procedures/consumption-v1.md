# Procedure Manifest — F-02 Consumption Measurement v1

- **Procedure ID:** `v2-consumption`
- **Version:** `v2`
- **Scope:** Measure whether federation-recon Findings are actually consumed by observed repositories. Implements falsifier F-02 from founding package §18. Searches observed repositories at their pinned commits for references to federation-recon Findings. Produces Consumption Record artifacts.
- **Claim sources:** Not applicable (measurement is discovery-based, not claim-based).
- **Repository set:** All federation nodes discovered by v0 (recon) and v1 (census), excluding self (federation-recon).
- **Inputs:**
  - Existing repository pins from `pins/v0-boundary-drift/` and `pins/v1-census/` (for discovering the observed repo set and their pinned SHAs)
  - Git repositories at pinned commits (shallow-cloned read-only for search)
  - `digest/v2-consumption.json` (for cycle counting in reproduce mode)
- **Required tools:** `git`, `gh` (GitHub CLI 2.x), `rg` (ripgrep), `python3`
- **Optional tools:** `jq`
- **Outputs:**
  - Repository Pin artifacts → `pins/v2-consumption/<repo-slug>.json` (schema: `schemas/repository-pin.schema.json`)
  - Consumption Record artifacts → `consumption/<consumption-id>.json` (schema: `schemas/consumption-record.schema.json`)
  - Coverage Record artifacts → `coverage/<coverage-id>.json` (schema: `schemas/coverage-record.schema.json`)
  - Sub-digest → `digest/v2-consumption.json` (composition contract)
- **Failure semantics:** Each repository is processed independently. Clone failure or network error for one repo produces a partial Coverage Record and continues. Terminal failure aborts the run.
- **Determinism requirement:** Identical repository pins + identical procedure version must produce byte-identical Consumption Records (FR-CON-012). Search is deterministic at pinned commits. `--reproduce` mode uses pre-pinned repository data.

## Detection

For each observed repository at its pinned commit, search the tree for references to federation-recon Findings:

1. `finding-<hex>` — a Finding ID prefix match (12 hex chars). This is the primary signal: a specific, unambiguous citation of one of our Findings.
2. `federation-recon` — a repository name mention. This is weaker evidence (mentioning the repo ≠ citing a Finding) and is classified separately as `repo_reference`. It is never summed into the Finding-consumption number.

Unqualified substrings like `findings/`, `drift/`, or `evidence/` are intentionally excluded: they match coincidental vocabulary in unrelated repositories and destroy the falsifier (see PR #46 review, Blocker 1).

Self-references (federation-recon referencing its own Findings) are excluded.

### Ignore policy

ripgrep skips hidden files and directories (dot-prefixed) and gitignored files by default. This federation stores machine-readable descriptors in `.well-known/`, a hidden directory. The search uses `--hidden` to include dot-prefixed files. It does **not** use `--no-ignore`: gitignored files (build artifacts, `node_modules/`, vendored dependencies, etc.) are not meaningful consumption signals and would introduce noise and nondeterminism from uncommitted build outputs.

## Consumption Record

Metadata only: referencing repository slug, file path, line number, referenced Finding ID (null for repo_reference), reference type (`finding_id` or `repo_reference`), repository pin, and cycle. No source excerpts (FR-CON-008).

The two reference types MUST be reported distinctly in all outputs:
- `finding_references` — count of `finding_id` records (actual Finding consumption)
- `repo_references` — count of `repo_reference` records (weaker signal)
- `total_consumption_records` — sum of both

If the honest result is zero Finding references, zero MUST be committed plainly. A zero here is the falsifier's actual signal and is the single most important number this procedure produces.

## Cycle counting

F-02 is defined over "ten completed operational cycles." A **cycle** is one complete execution of this procedure against the current pin set, producing a committed sub-digest. Each cycle corresponds to one run of the daily census workflow (`.github/workflows/node-census.yml`). The procedure runs as part of that workflow alongside census and recon.

Each Consumption Record stores which cycle it belongs to. The cycle number is derived from committed artifacts: previous sub-digest's cycle + 1, or 1 if this is the first run. In reproduce mode, the cycle is frozen from the committed sub-digest.

### Cycle ledger

An append-only per-cycle ledger at `consumption/cycle-ledger.json` records each cycle's results in a JSON array, one entry per completed cycle. This makes F-02 evaluable directly from a checkout without git archaeology:

```json
[
  {
    "cycle": 1,
    "finding_references": 0,
    "repo_references": 0,
    "observed_repositories": 13,
    "timestamp": "2026-07-25T06:00:00Z",
    "trigger": "schedule"
  }
]
```

The ledger is an append-only log. When a new cycle completes, a new entry is appended. No entry is ever modified or removed. Each entry records `cycle`, `finding_references`, `repo_references`, `observed_repositories`, `timestamp` (the actual measurement time, never frozen by `--reproduce`), and `trigger` (the event that initiated the run: `schedule` for the daily cron, `workflow_dispatch` for manual triggers, or `manual` when the trigger source is not available such as local runs).

## Operations

| # | Operation | Output |
|---|---|---|
| 1 | Discover repo set from committed pins (v0 + v1) | Repo list (internal) |
| 2 | Resolve and pin each repository | `pins/v2-consumption/*.json` |
| 3 | Search each repo for Finding references | `consumption/*.json` |
| 4 | Record Coverage | `coverage/*.json` |
| 5 | Perform self-observation (FR-CON-011) | Self-Finding |
| 6 | Generate sub-digest (composition contract) | `digest/v2-consumption.json` |
| 7 | Enforce budget | Budget check |

## Execution

The sub-digest `run_timestamp` is frozen in `--reproduce` mode so the artifact set reproduces byte-identically (FR-CON-012). In live mode it is the wall-clock time at run start. The cycle-ledger `timestamp` field is the authoritative record of when a measurement was actually performed: it is always the wall-clock time and is never frozen by `--reproduce`. A digest regenerated after a sensor fix will carry the original frozen `run_timestamp`, but a fresh cycle-ledger entry (or the existing entry's `timestamp` if the cycle is unchanged) records the actual measurement time.

```shell
# Full live run
bash scripts/consumption-run.sh

# Reproduce — use pre-pinned data
RECON_PINS_DIR=pins bash scripts/consumption-run.sh --reproduce
```

## Version history

| Version | Date | Author | Changes |
|---|---|---|---|
| v2 | 2026-07-25 | Operator | Initial F-02 Consumption Measurement procedure |
