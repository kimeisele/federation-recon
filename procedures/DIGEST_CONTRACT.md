# DIGEST_CONTRACT.md — Federation Digest Composition Contract

**Version:** 1.0
**Adopted:** slice-v2/composed-digest

## Purpose

`STATE.md` is the single Federation Digest entry point (§4.1). It must aggregate
outputs from all procedures without any procedure overwriting another.

This document defines the **composition contract** through which every procedure
contributes to the composed digest without requiring changes to the composer or
to other procedures.

## Contract

### 1. Each procedure writes a machine sub-digest

Every procedure writes exactly one sub-digest file at:

```
digest/<procedure_id>.json
```

The file uses this **common shape**:

```json
{
  "procedure_id": "<unique procedure identifier>",
  "procedure_version": "<semantic version tag>",
  "run_timestamp": "<ISO-8601 UTC, deterministic when pins are identical>",
  "attention_items": [
    {
      "target": "kimeisele/<repo>",
      "status": "observed|stale|superseded",
      "attention_rank": 0,
      "headline": "<single-line summary for the operator>",
      "refs": ["findings/<finding_id>.json"]
    }
  ],
  "summary": {
    "<procedure-specific key>": "<procedure-specific value>"
  }
}
```

### 2. Field semantics

| Field | Required | Description |
|-------|----------|-------------|
| `procedure_id` | yes | Unique, stable identifier. Must match the sub-digest filename stem. |
| `procedure_version` | yes | Version tag of the procedure that produced this digest. |
| `run_timestamp` | yes | ISO-8601 UTC timestamp. Must be deterministic for identical pins (FR-CON-012). |
| `attention_items` | yes | Array of items ranked by `attention_rank` (lower = higher priority). May be empty. |
| `attention_items[].target` | yes | Fully qualified repository slug. |
| `attention_items[].status` | yes | One of: `observed`, `stale`, `superseded` (§9 lifecycle). |
| `attention_items[].attention_rank` | yes | Integer; `0` = highest attention. Non-negative. |
| `attention_items[].headline` | yes | Single-line operator-facing summary. |
| `attention_items[].refs` | yes | Array of paths relative to repo root, pointing to Findings or Evidence. |
| `attention_items[].non_peer` | no | Boolean, default `false`. Set `true` when the target is a constitutional non-peer (no descriptor expected per design). Composer groups these separately. |
| `summary` | yes | Flat object with procedure-specific counts. Keys must be snake_case. |

### 3. Composer contract

The composer (`scripts/compose-digest.sh`) reads **all** `digest/*.json` files
and produces:

- `STATE.md` — human-readable ranked attention table
- `digest/state-digest.json` — machine-readable merged digest

The composer:

1. Reads every `digest/*.json` file except itself (`state-digest.json` is excluded).
2. Collects all `attention_items` across all procedures.
3. Sorts globally by `attention_rank` (ascending), then by procedure group.
4. Separates `non_peer: true` items into a "Constitutional Observatory" section
   (not ranked with peer attention items).
5. Produces output that is a **pure function** of the sub-digests (FR-CON-012).

### 4. Extension: adding a future procedure

A new procedure (e.g., hypothetical `v3-dependency-audit`) plugs in with **zero
composer changes**:

1. Write a sub-digest at `digest/v3-dependency-audit.json` using the common shape.
2. Populate `attention_items` with dependency findings (outdated deps, license
   conflicts, etc.), ranked by severity.
3. Populate `summary` with procedure-specific counts (e.g., `deps_scanned`,
   `vulnerabilities_found`, `license_issues`).

The composer automatically picks it up on the next run. No other procedure or
config file needs updating.

### 5. Constitutional non-peers

Repositories that are deliberately not federation peers (§5) must not be flagged
as "needs attention" for missing a `.well-known/agent-federation.json` descriptor.

Procedures that enumerate federation nodes mark such items with `"non_peer": true`
in their attention items. The composer renders these in a separate section
titled "Constitutional Observatory" rather than in the main ranked attention table.

Current known constitutional non-peers:

- `kimeisele/federation-recon` — observatory, not a peer (§5)

### 6. Determinism (FR-CON-012)

- Every procedure sub-digest must be byte-identical when run against identical
  repository pins.
- The composer output must be byte-identical when all input sub-digests are
  byte-identical.
- Run timestamps must be derived from pinned commits, not wall clock.
