# Repository Manifest — Slice v0 Observed Set

**Status:** verified real slugs, resolvable refs pinned at draft time. Still preparation only (founding package §20) — no procedure may run against this list until the founding decision record is adopted.

Verified via `gh api repos/kimeisele/<repo>` on 2026-07-23. All six candidate repositories exist, are non-empty, non-archived, and public (visibility no longer blocks read access for an external operator).

Recon includes itself per FR-CON-011, for self-observation only — never as a source of federation-boundary claims about others.

| Repository | Role (observed, not authoritative) | Default branch | HEAD commit at draft time (2026-07-23) | In Slice v0 observed set |
|---|---|---|---|---|
| `kimeisele/federation-recon` | self-observation (FR-CON-011) | `master` | `d316e9a34a29cf95d735ecc387d58b75e590765a` | yes — self only |
| `kimeisele/steward-protocol` | substrate: identity, capability types, Nadi protocol spec, federation descriptor schema | `main` | `34a8a0efc25c15ef7c07dd4fb50aeb2510c071e8` | yes |
| `kimeisele/agent-world` | world governance: registry, policy, constitution, heartbeat, authority exports, campaigns | `main` | `6771524abef20ef4f9b98ad366ba4bfa0968111a` | yes |
| `kimeisele/agent-internet` | control plane + projection: routing, trust, city registration, wiki/search/crawling, bundle projection | `main` | `dcd0206434b21d8c0ec2fac81e2aafc856401831` | yes |
| `kimeisele/steward-federation` | Nadi mailbox: git-backed message drop-box (transport logic lives in `steward`, not here) | `main` | `6c42bfc946c4ca2a6106b2ae2f13ffbdb6c103a2` | yes |
| `kimeisele/steward` | autonomous engine: CLI/REPL/daemon/bot/API execution, self-healing, federation participation, multi-LLM orchestration | `main` | `4b48a72073928baf2a23fdd3f8d603c2592fd90b` | yes |
| `kimeisele/agent-city` | city runtime: mayor, council, economy, immigration, local campaigns | `main` | `9e16df3d5891c934568c634e0034c0cb8c40e443` | yes |

These pins are **draft observations for scope-review purposes**, not Repository Pin artifacts (§8.1) — those are only created by an authorized, running procedure.

## Explicitly excluded from Slice v0

Kept out to keep the first slice narrow and proven, per the founding recommendation ("prove the central federation boundary, don't inventory the whole account"). All exist in the account as of 2026-07-23 but are excluded for the stated reason:

| Repository | Exclusion reason |
|---|---|
| `agent-village` | not one of the six core architecture domains named in the founding boundary table (`agent-world/docs/REPO_BOUNDARIES.md`) |
| `agent-template`, `agent-template-acceptance-node-0[2-5]`, `agent-template-proof-node-01` | scaffolding / node-acceptance artifacts, not a federation architecture domain |
| `agent-research` | day-zero research faculty per `REPO_BOUNDARIES.md`; no stable boundary claims yet to drift-check |
| `steward-gateway` | "Not Started" per `REPO_BOUNDARIES.md` — 0 code, no claims to observe |
| `steward-protocol-backup`, `steward-test` | non-canonical / test copies, would produce false drift against the canonical repo |
| everything else in the account (music, spiritual, personal, unrelated projects) | outside the federation-recon architecture domain entirely |

Any of these may be added to a later slice's observed set through an explicit Repository Manifest revision — never silently.

## Open scope question

`steward-gateway` and `agent-template*` nodes may become relevant once they leave "not started" / scaffolding status. Recon should not infer this itself; re-inclusion requires a manifest revision, not an automatic rule.
