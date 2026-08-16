# FAW/Nadi technical program record

**Recorded:** 2026-08-13  
**Status:** active; technical Programs 0/P2/P3 advanced, credentialed workflow not started

This is the durable handover for the bounded technical work derived from the
Federation Bootstrap planning artifacts. It is not a new governance system and
does not make Federation HQ part of the runtime.

## Product boundary now demonstrated

```text
signed FAW document
  -> transport-neutral NodeRunner
  -> Nadi/GitHub adapter (opaque delivery metadata)
  -> verified/admitted delegation
  -> provider-neutral RuntimeResult
  -> FAW-bound and signed terminal receipt
```

FAW owns identity, verification, replay admission, delegation/receipt binding,
and signatures. Nadi owns delivery only. A node runtime owns one bounded
execution and returns neutral result data; it does not sign FAW documents and
does not know Nadi.

## Integrated evidence

| Repository | PR | Merge SHA | Demonstrated outcome |
|---|---:|---|---|
| `kimeisele/federated-agent-web` | #46 | `2f91e450befc697c4779748876838099ba1772d9` | Operational `NodeRunner` can use the existing Nadi/GitHub transport; offline signed delegation/execution/receipt roundtrip passes. |
| `kimeisele/steward-federation` | #1199 | `3181e7b1dca4619844f5f2807519dad851786eed` | Hub heartbeat executes the reviewed checkout; mutable authenticated fetch from `main` removed. |
| `kimeisele/steward-federation` | #1200 | `606511a54e371f2eddf750b5169c014fae8a4e8d` | Partial target success acknowledges only durable messages; failed targets remain; local overflow fails closed; replay identity and trimming are deterministic. |
| `kimeisele/federated-agent-web` | #47 | `8c288c0c176a3c3ed35dd57b0d5a0dcfe1adeb0b` | Capability registry and neutral `RuntimeResult`; FAW constructs and signs receipts after verification/admission. |
| `kimeisele/agent-template` | #23 | `fee96933d94b1aa2ecc8fe8e2b26629ee2388f3a` | Standard-library headless subprocess adapter with file-only task input, process-group deadline, bounded output, JSONL normalization, and offline stub tests. |

At record time, `steward-federation/main` had already advanced to
`463f52e01ba6e43099d784a158c5461efedd0230` through normal relay commits; both
repair merge SHAs remain ancestors of that head.

## Verification actually run

- FAW PR #46: 482 local tests; two successful GitHub CI runs.
- `steward-federation` PR #1199: 19 local tests and successful CI.
- `steward-federation` PR #1200: 34 local tests, Ruff, wheel build, successful CI, and a direct partial-target failure reproduction.
- FAW PR #47: 487 local tests, `faw demo` ending `demo: OK`, two successful GitHub CI runs, and an independent Codex/Luna adversarial review. Its first review found that the public `run_once()` wrapper did not forward the registry/policy; commit `6d34435` corrected that before merge.
- `agent-template` PR #23: 285 repository tests, 5 adapter-focused tests, Ruff, and a direct stub-runtime execution proof. The repository currently has no pull-request CI workflow, so local commands are the available check evidence.

## Decisions and invalidated assumptions

1. `nadi_kit.py` is not copied into FAW and is not a protocol authority. FAW's
   existing Nadi adapter transports complete signed bytes and keeps relay
   addresses separate from FAW node IDs.
2. The runtime seam returns `RuntimeResult`, not a receipt dictionary. The
   planning text suggesting `execute(...) -> receipt_dict` conflicted with its
   own requirement that runtime adapters know nothing about FAW; repository
   evidence resolved this in favor of the neutral result boundary.
3. OpenHands is only a candidate executable configuration. It is not installed
   into the Python 3.11 node kernel. A credentialed attempt workflow must give
   the runtime its own environment (currently expected to be Python 3.12) or
   choose a compatible candidate.
4. The legacy template Nadi scripts remain separate from FAW transport. They
   must not be relabeled as a delegation bus.
5. Git remains durable control/evidence storage. Per-agent-step commits remain
   outside the target design; one attempt should produce a small semantic
   boundary plus a receipt.

## Residual risks

- `steward-federation` local JSON read/modify/write assumes a single writer.
  Concurrent local emit/sync processes would require locking or CAS.
- Local Nadi inbox growth is TTL-bounded rather than count-bounded so complete
  pulls are never silently dropped. Extremely long untrusted TTL values need a
  separate admission/compaction decision.
- Existing hub mailboxes and Git commit churn remain an unsuitable substrate
  for high-frequency runtime events. The repair prevents the proven loss modes;
  it does not turn Git into a queue.
- `agent-template` has no PR CI trigger. The adapter was fully tested locally,
  but adding an ordinary read-only PR test workflow is a repository hygiene
  task, separate from the credentialed attempt workflow.

## Next justified vertical slice

One `agent-template` mission only: connect a locally supplied, already verified
delegation to the neutral adapter through FAW's injected execution registry and
produce a schema-valid signed receipt, entirely offline with a stub runtime.

Hard constraints:

- no credentials, GitHub writes, Actions workflow, real LLM call, or Nadi hub;
- no FAW schema/canonicalization/verification changes;
- no reuse of legacy `nadi_send.py` as FAW transport;
- task content remains file input, never shell/workflow interpolation;
- deadline and output overflow must produce terminal failure results;
- replayed delegation must not invoke the stub runtime twice.

Only after that offline composition is green should a separate mission design
the credentialed Actions attempt. Credential/App/secret setup is owner-only and
was deliberately not performed in this run.
