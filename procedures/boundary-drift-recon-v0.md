# Procedure Manifest — Boundary Drift Recon v0

- **Procedure ID:** `boundary-drift-recon-v0`
- **Version:** `v0`
- **Scope:** Detect drift between documented repository-boundary claims (per `docs/claim-source-inventory.md`) and deterministic observations of pinned GitHub repository states (per `docs/repository-manifest.md`). See founding package §12.
- **Claim sources:**
  - `docs/claim-source-inventory.md` §Primary cross-repository boundary source (`agent-world/docs/REPO_BOUNDARIES.md`)
  - `docs/claim-source-inventory.md` §Per-repository structured federation descriptors (`.well-known/agent-federation.json` — 6 repos)
  - `docs/claim-source-inventory.md` §Per-repository constitution / boundary documents (`steward-protocol/CONSTITUTION.md`, `agent-city/docs/CONSTITUTION.md`, `agent-internet/docs/PUBLIC_FEDERATION_SURFACE.md`)
  - `docs/claim-source-inventory.md` §Self-observation source (`federation-recon/docs/founding-package-v0.2.md`)
- **Repository set:** `docs/repository-manifest.md` — 6 observed repos + self:
  1. `kimeisele/steward-protocol`
  2. `kimeisele/agent-world`
  3. `kimeisele/agent-internet`
  4. `kimeisele/steward-federation`
  5. `kimeisele/steward`
  6. `kimeisele/agent-city`
  7. `kimeisele/federation-recon` (self, FR-CON-011 only)
- **Inputs:**
  - `docs/repository-manifest.md` (observed set, draft SHAs)
  - `docs/claim-source-inventory.md` (explicit claim-source list)
  - Resolvable GitHub refs (default branch per repo)
  - This Procedure Manifest
- **Required tools:** `git` (2.x), `gh` (GitHub CLI 2.x), `rg` (ripgrep 13+)
- **Optional tools:** `python3` (for JSON schema validation); `jq` (for JSON processing if available). Run degrades gracefully per FR-CON-010 if unavailable — JSON output uses shell-native generation when `jq` is absent.
- **Outputs:**
  - Repository Pin artifacts → `pins/<repo-slug>.json` (schema: `schemas/repository-pin.schema.json`)
  - Claim Observation artifacts → `claims/<claim-id>.json` (schema: `schemas/claim-observation.schema.json`)
  - Evidence artifacts → `evidence/<evidence-id>.json` (schema: `schemas/evidence.schema.json`)
  - Drift Record artifacts → `drift/<drift-id>.json` (schema: `schemas/drift-record.schema.json`)
  - Finding artifacts → `findings/<finding-id>.json` (schema: `schemas/finding.schema.json`)
  - Coverage Record artifacts → `coverage/<coverage-id>.json` (schema: `schemas/coverage-record.schema.json`)
  - Machine-readable Digest → `digest/state-digest.json`
  - Human-readable Digest → `STATE.md` (updated)
- **Failure semantics:** All 11 operations (§12.3) run independently on each observed repository. A non-terminal failure in one repository (network error, missing file, tool unavailability) produces a `partial` Coverage Record and continues. A terminal failure (disk full, write error, unrecoverable tool failure) aborts the run. The run must not silently succeed on partial data.
- **Determinism requirement:** Identical pins + identical procedure version must produce identical Evidence (FR-CON-012). Timestamps are metadata only and may differ between runs; all `value`, `hashes`, path listings, and derived comparisons must be reproducible given the same resolved commit SHAs and procedure version.

## Operations

This procedure implements the 11 operations specified in founding package §12.3:

| # | Operation | Output |
|---|---|---|
| 1 | Resolve exact repository commits | Resolved SHAs (internal) |
| 2 | Record Repository Pins | `pins/*.json` |
| 3 | Extract selected claims | `claims/*.json` |
| 4 | Run deterministic observations | `evidence/*.json` |
| 5 | Compare each claim with current observations | `drift/*.json` |
| 6 | Create Evidence and Drift Records | `evidence/*.json`, `drift/*.json` |
| 7 | Create or supersede Findings | `findings/*.json` |
| 8 | Update Coverage | `coverage/*.json` |
| 9 | Perform Recon self-observation | Self-Finding, Coverage |
| 10 | Generate `STATE.md` and machine-readable Digest | `STATE.md`, `digest/state-digest.json` |
| 11 | Enforce retention and size budgets | Budget check (warn ≥ 250 KB, abort ≥ 1 MB) |

## Execution

```shell
# Full live run — resolves pins from GitHub
bash scripts/recon-run.sh

# Reproduce — use pins from a prior run
RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce
```

## Version history

| Version | Date | Author | Changes |
|---|---|---|---|
| v0 | 2026-07-23 | Operator | Initial procedure per adopted Founding Package v0.2 |
