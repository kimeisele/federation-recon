# federation-recon

**Status:** Founding package **adopted** 2026-07-23. Slices v0, v1, v2 implemented and running.

A GitHub-native, self-observing, read-only observatory and context compiler that lets AI operators understand federation state through layered, reproducible evidence — without becoming a runtime, governor, healer, registry, or public membrane.

**Visibility:** this repository is **public** (adopted posture, §14), so external operators and connectors can read federation state directly. It stores only metadata — pins, paths, hashes, counts, manifests, and derived records — never source excerpts or secrets (FR-CON-008).

## Start here

- **[`STATE.md`](STATE.md)** — the composed **Federation Digest**. One ranked "what needs attention" view across every procedure. This is the entry point for any operator session; read it first, then navigate down.
- [`docs/founding-package-v0.2.md`](docs/founding-package-v0.2.md) — the constitution (invariants FR-CON-001..012, artifact model, lifecycle, falsifiers).
- [`docs/founding-decision-record.md`](docs/founding-decision-record.md) — the adoption record (numeric budgets, visibility posture, falsifiers).
- [`GLOSSARY.md`](GLOSSARY.md) — canonical terminology.

## Progressive disclosure (§4)

```text
STATE.md  (composed Federation Digest — ranked attention)
    |  digest/<procedure>.json   (per-procedure sub-digests)
    |  findings/                 (interpreted, evidence-backed; lifecycle: observed/stale/superseded)
    |  evidence/ , drift/        (deterministic observations bound to a pin)
    |  claims/                   (what a source asserts)
    |  pins/                     (exact repo + commit SHA observed)
    v  raw GitHub repositories at the pinned SHAs
```

Every `repository_pin` in a claim or evidence record resolves to a real file in `pins/`, so the chain is navigable end to end.

## Slices

| Slice | What it does | Runner |
|---|---|---|
| **v0 — Boundary Drift Recon** | Drift between documented boundary claims (`REPO_BOUNDARIES.md`, `.well-known/agent-federation.json`, constitutions) and pinned repository reality, across the 6 core repos + self. | `scripts/recon-run.sh` |
| **v1 — Node Census** | Broad, shallow liveness/presence inventory of every node discoverable via the `agent-federation-node` topic (descriptor? charter? last commit? role/tier?). | `scripts/node-census-run.sh` |
| **v2 — Composed Digest** | Composes all procedures' sub-digests into the single ranked `STATE.md` + machine digest. | `scripts/compose-digest.sh` |

Adding a future slice requires **no change to the composer** — it just emits a `digest/<id>.json` sub-digest in the shape documented in [`procedures/DIGEST_CONTRACT.md`](procedures/DIGEST_CONTRACT.md).

## Run it

```bash
# Full live run (resolves current HEADs, observes, composes)
bash scripts/recon-run.sh          # v0 boundary drift
bash scripts/node-census-run.sh    # v1 node census
bash scripts/compose-digest.sh     # build STATE.md + digest/state-digest.json

# Deterministic re-run against the committed pins (no live resolution)
RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce
RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce
bash scripts/compose-digest.sh
```

Requires `git`, `gh` (authenticated), `rg`, `python3` (§11.1). No LLM is ever involved in generating evidence (§3.1).

## Determinism (FR-CON-012 / F-01)

Given identical pins and the same procedure version, `--reproduce` produces a **byte-identical** artifact set — so any independent agent can re-run it and verify the evidence was not tampered with. In reproduce mode all observation timestamps derive from the frozen pin state; live runs use wall-clock time.

```bash
bash scripts/validate-artifacts.sh --strict   # schema + pin-reference resolution
bash scripts/verify-determinism.sh            # two --reproduce passes must be byte-identical
```

## CI

| Workflow | Trigger | Checks |
|---|---|---|
| `ci.yml` (`invariants`) | every PR + push to master | strict schema validation, composed-digest idempotency, pin-reference resolution — fast, offline |
| `nightly-determinism.yml` | daily 05:30 UTC + manual | reproduce-stability: two full `--reproduce` passes must be byte-identical |
| `node-census.yml` | daily 06:00 UTC + manual | live run of all procedures + compose; commits the fresh Federation Digest |

## What this is not

Not a federation peer, Nadi participant, heartbeat-producing runtime, router, trust authority, registry owner, executor, healer, public projection layer, legislature, or canonical source of domain truth (founding package §5). It observes; it does not adjudicate, remediate, or actively project findings (FR-CON-001..006).

## Repository layout

```text
STATE.md                    composed Federation Digest (operator entry point)
docs/                       founding documents, manifests, glossary, decision records
schemas/                    JSON schemas for the artifact types (evidence-layer contracts)
procedures/                 versioned Procedure Manifests + DIGEST_CONTRACT.md
scripts/                    runners (recon, census, compose) + validators + libs
.github/workflows/          CI gate, nightly determinism, daily census
pins/ claims/ evidence/     generated artifacts (a committed reproduce fixpoint)
drift/ findings/ coverage/
digest/                     per-procedure sub-digests + composed state-digest.json
```
