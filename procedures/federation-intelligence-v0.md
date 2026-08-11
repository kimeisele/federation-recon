# Federation Intelligence v0

- **Procedure ID:** `federation-intelligence-v0`
- **Version:** `1`
- **Scope:** `agent-world`, `agent-internet`, and `agent-city` only.
- **Input:** committed `pins/v1-census/<node>.json` records.
- **Read boundary:** for each pin, read `git/commits/<resolved_commit_sha>` first, then the recursive Git tree at the returned tree SHA. No current branch lookup and no source excerpts.
- **Output:** `digest/federation-intelligence-v0.json`; `schemas/federation-intelligence.schema.json` is its machine-readable structural interface, while the executable `--validate-only` mode is the canonical offline structure/relations contract.
- **Invocation:** `python3 scripts/federation-intelligence.py`.
- `--validate-only` checks offline structure, relations, and canonical digest integrity; it does not prove source membership.
- `--verify-source` additionally performs fresh immutable commit-then-tree reads and compares the complete canonical index, including paths, modes, sizes, and blob SHAs.

The index records immutable tree metadata and bounded path-name candidates for
entrypoints, contract files, and dependency manifests. A candidate is not an
observed runtime contract or dependency edge. The output has zero dependency
edges until pinned content evidence supports one. Any missing, malformed,
truncated, or mismatched pinned input fails the run without replacing an
existing output.
