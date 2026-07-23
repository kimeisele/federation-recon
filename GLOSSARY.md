# Glossary

Canonical terminology for `federation-recon` (DG-10). Terms here are binding for artifact schemas and documentation in this repository.

- **Recon** — shorthand for `federation-recon` itself.
- **Federation Digest** — top-level, compact entry point for an operator (`STATE.md` plus its machine-readable equivalent). See founding package §4.1.
- **Repository / Domain Digest** — a digest summarizing one observed repository or architectural domain. See §4.2.
- **Finding** — an interpreted, evidence-backed observation with an explicit lifecycle state (`observed`, `stale`, or `superseded`). See §4.3, §8.4, §9.
- **Evidence** — a deterministic observation bound to an exact Repository Pin and Procedure Manifest version. Not a conclusion. See §4.4, §8.2.
- **Raw reference** — a path, line, or structural reference into the original pinned Git repository. Recon does not vendor source. See §4.5.
- **Repository Pin** — the exact resolved commit SHA and metadata identifying what was observed. See §8.1.
- **Claim Observation** — a record that a selected source asserts something; Recon observes the claim, not its truth. See §8.3.
- **Drift Record** — a structured difference between a Claim Observation and a current deterministic observation. See §8.5.
- **Coverage Record** — a record of what was inspected, when, at which commit, with which procedure, and with what result. See §8.6.
- **Procedure Manifest** — the versioned definition of scope, inputs, tools, outputs, and determinism requirements for a recon procedure. See §8.7.
- **Retention Record** — a record of whether evidence is retained, compacted, superseded, or removed per policy. See §8.9.
- **Baseline / Expectation** — a formally sourced external expectation; reserved for future slices, never invented by Recon. See §8.10.
- **Slice** — a bounded, versioned unit of recon capability (e.g. "Boundary Drift Recon v0"). See §12.
- **Founding decision record** — the document that formally adopts (or has not yet adopted) this founding package, unlocking implementation. See §20.
- **Falsifier** — an explicit condition (F-01, F-02, F-03) under which the Recon approach must be reconsidered or suspended. See §18.
- **Observed / Stale / Superseded** — the three MVP lifecycle states for a Finding. No `acknowledged`, `disputed`, `accepted_deviation`, or `resolved` state exists in the MVP. See §9.
