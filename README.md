# federation-recon

**Status:** Founding phase — not yet adopted. Implementation is locked (see [`docs/founding-package-v0.2.md`](docs/founding-package-v0.2.md), Section 20).

A private, GitHub-native, self-observing, read-only observatory and context compiler that lets AI operators understand federation state through layered, reproducible evidence — without becoming a runtime, governor, healer, registry, or public membrane.

## Start here

- [`STATE.md`](STATE.md) — Federation Digest (entry point for any operator session)
- [`docs/founding-package-v0.2.md`](docs/founding-package-v0.2.md) — the founding document (constitutional invariants, artifact model, MVP lifecycle, falsifiers)
- [`GLOSSARY.md`](GLOSSARY.md) — canonical terminology (required before implementation completes, DG-10)
- [`docs/founding-decision-record.md`](docs/founding-decision-record.md) — adoption record; Slice v0 is not authorized until this is filled in

## What this is not

Not a federation peer, Nadi participant, heartbeat-producing runtime, router, trust authority, registry owner, executor, healer, public projection layer, legislature, or canonical source of domain truth. See founding package §5.

## Repository layout

```text
docs/                       founding documents, manifests, glossary, decision records
schemas/                    JSON schemas for Recon artifact types (evidence layer contracts)
procedures/                 versioned Procedure Manifests (empty until Slice v0 is authorized)
evidence/ findings/          generated artifacts (empty until Slice v0 is authorized)
coverage/ digest/
```

## Rules while founding is unadopted (§20)

Until the founding decision record accepts the package, no one may: build a generalized CLI, integrate AST/graph systems, create cross-repository write access, add required checks to other repositories, consume `agent-internet` graph outputs, migrate historical audit artifacts, or publish findings.

Allowed now: repository manifest drafting, claim-source inventory, Procedure Manifest design, schema examples, glossary drafting, deterministic tool feasibility probes.
