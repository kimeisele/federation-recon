# Procedure Manifest — template

Copy this template to create a new versioned Procedure Manifest (founding package §8.7). No procedure may execute until the founding decision record is adopted (§20).

- **Procedure ID:**
- **Version:**
- **Scope:** (what this procedure observes)
- **Claim sources:** (link to entries in `docs/claim-source-inventory.md`)
- **Repository set:** (link to entries in `docs/repository-manifest.md`)
- **Inputs:**
- **Required tools:** `git`, `gh`, `rg` (baseline per §11.1)
- **Optional tools:** (per §11.2; run must degrade gracefully per FR-CON-010 if unavailable)
- **Outputs:** (Evidence / Drift Record / Finding / Coverage Record types produced)
- **Failure semantics:** (what happens on partial failure — must not silently succeed)
- **Determinism requirement:** identical pins + identical procedure version must produce identical Evidence (FR-CON-012)
