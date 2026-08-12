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

The top-level `entrypoint_declarations` contains exactly two pinned declarations:
`agent-world = agent_world.cli:main` and `agent-internet =
agent_internet.cli:main`. `agent-city` must declare no project scripts. Each
record binds the manifest observation, repository pin, evidence record, commit
tree SHA, source path, blob SHA, byte size, and regular-file mode. The module
source is decoded and parsed with the standard-library AST parser; only a
top-level synchronous or asynchronous function definition named `main` is
accepted. No module is imported or executed, so `runtime_status` is always
`not_evaluated`. Missing, malformed, nested, syntactically invalid, or
ambiguous declarations fail closed. `--validate-only` checks the compact
cross-record bindings without network access; `--verify-source` rebuilds them
from fresh immutable source blobs.

The semantic slice records one historical, mutable declared relation in
`relations.declared_edges`. `dependencies.observed_edges` is intentionally
always empty: zero runtime and zero implementation dependency edges are
asserted by this procedure.

The index records immutable tree metadata and bounded path-name candidates for
entrypoints, contract files, and dependency manifests. A candidate is not an
observed runtime contract or dependency edge. `dependencies.observed_edges`
remains empty. Pinned content may produce at most one historical, mutable
relation under `relations.declared_edges`; this is not a runtime or
implementation dependency. The same relation set may contain bounded,
allowlisted `declared_package_dependency` records derived from the three
pinned `pyproject.toml` files; these record manifest declarations only, with
mutable targets and no claim of installation or runtime use. Each edge records
whether its target is `indexed_source` or `external_out_of_scope`, and whether
the target came from a direct VCS declaration or the package allowlist. The
target revision is unbound and target content is not verified. A dynamic
`project.dependencies` declaration is unsupported and fails closed. Any missing,
malformed, truncated, or mismatched pinned input fails the run without
replacing an existing output.
