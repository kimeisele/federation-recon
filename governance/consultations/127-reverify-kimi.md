<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Re-review — PR #127, the S2 order validator

**The review #127 never had.** It was merged citing two cross-provider reviews
that were served by the builder's own provider (#135). A first re-review
attempt through Sol was terminated by the provider mid-run (#140).

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 5504, completion 10817 |
| Mode | **diff mode — the reviewer executed nothing**, and labelled it so |

Four of its findings were executed afterwards by the operator against `main`
and all four reproduce. See #141.

---

**Reviewed diff-only. Nothing was executed; every dynamic claim below is labeled NOT EXECUTED with the run that would settle it.**

Process note: the two "independent" reviews were same-provider, so the HIGH-risk gate was never met. This is the first cross-provider pass. The earlier gpt-5.6-sol refusal was a false positive; this is defensive audit work.

**1. How I defeat it — two admitted orders.**

**(a) Identity bypass, concrete bytes.** This order is admitted, exit 0, silent stderr:

```json
{"schema":"execution-core/order/v1","run_id":"3f6b1a2e-4c5d-4e6f-8a9b-0c1d2e3f4a5b","issue":1,"base_sha":"0123456789abcdef0123456789abcdef01234567","intent":"x","required_capabilities":["pool_integrity"],"limit_reductions":{"wall_clock_seconds":0},"acceptance_bundle":{"digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","location":"/usr/local/var/jcode-runs/bundles/b","author":"deep\u200bseek","approved_by":"deep\u200bseek","created_at":"2025-01-01T00:00:00Z"}}
```

`deep\u200bseek` is six ASCII bytes in the file; `json` decodes U+200B (zero-width space); `.lower()` leaves it; the substring `"deepseek"` never matches. Every other field passes by construction. Builder-authored, builder-approved, zero digest, possibly-nonexistent bundle — admitted. The `approved_by` gap was patched reactively; the same class (identity as text) survives. NOT EXECUTED: would run `python3 -m core.orders.validate` on this file; the author's claim is refuted if exit≠0.

**(b) The flagship claim is void at system level.** `limit_reductions` makes a looser limit inexpressible *in the order* — but the minuend lives in `core/policy.json`, an in-repo file reachable through the same PR pipeline the builder exists to use. One merged PR changes `wall_clock_seconds: 60 → 86400` and moves `mem_limit` into `claimed_capabilities`; an order requiring `mem_limit` (which the policy itself says can only "detect, not prevent") is then admitted. The validator binds order→policy; **nothing binds policy→operator**. The type-level claim is true and irrelevant. NOT EXECUTED: would edit a copy of policy.json, rerun, observe exit 0; refuted if CI blocks policy edits or the validator anchors policy integrity. No such anchor is visible in the diff.

**2. Testable only by declaration.** Digest vs. actual bundle bytes (never opened). `author`/`approved_by` as identity (self-asserted, unsigned). Policy sanity — the policy is never validated: non-numeric limit values make `policy_limits[key] - reduction` raise an uncaught `TypeError`; claimed∩unclaimable overlap silently resolves to claimed. `"issue": <5000-digit int>` raises uncaught `ValueError` on CPython ≥3.11 (int digit cap) — first stderr line becomes `Traceback…`, the exact contract breach vector 34 pinned, one field over. NOT EXECUTED: `json.loads("1"*5000)` and an order with a huge `issue`; refuted if line 1 is a bare `E_*` code. The "38 vectors / 15 mutations" claims are unverifiable from a diff; would run the suite and mutation harness.

**3. Proves vs. claims.** Proves: ≤64 KiB, UTF-8, canonical dup-free shallow JSON, schema conformance, caps ⊆ policy's claims, reductions non-negative and sub-policy, bundle fields well-formed, location syntactically under the prefix. Claims: "decides whether an order may be executed at all" and `E_BUNDLE_PROVENANCE`. The purity claim ("reads exactly two files") and the provenance claim are mutually exclusive — you cannot establish provenance of a file you refuse to read.

**4. Failure that looks like success.** Exit 0 with silent stderr is byte-identical for a sound order and for an order backed by a weakened policy, a fictional bundle, or a homoglyph author. The failure happens upstream of any log. Conversely the traceback exits (huge int, non-numeric policy limit) look like ordinary refusals to any caller keying on exit status.

**5. What nobody notices in a long session.** Policy drift via ordinary PR flow — every subsequent validation still exits 0. Replay: no state, no clock, frozen `created_at`, reusable `run_id`, reusable bundle digest across drifting `intent`/`base_sha`. And the success path is *designed* to leave no evidence: silent stderr means there is no audit record of what was admitted, ever. Also: `DATETIME_RE` uses `\d`, which matches Unicode decimal digits — Arabic-Indic `created_at` passes and crashes a downstream `strptime` far from the cause.

**6. Right thing?** As a canonicalizing boundary parser: yes — the depth pre-scan, dup hook, and fail-closed plumbing are solid. As *the* admissibility decision: no. Provenance, capability proof, and replay resistance require world state this component refuses to touch. Either verify or re-scope the contract. The `BUILDER_NAMES` substring check is theater (bypass: ZWSP/confusables; false positive: "coworker").

**7. Missing.** Policy schema + integrity anchoring + CI guard on `core/policy.json`. Bundle digest verification or a TOCTOU-safe handoff (the #128 class). An audit record on admit. A `parse_int` digit guard. An upper bound on `issue`. NFC/allowlist handling for identity fields. Vectors for: homoglyph authors, policy contradictions, huge ints, directory-as-location (`…/bundles/` passes today).

**8. Own-provider blind spots.** Shared priors with the builder: accepting the `limit_reductions` framing on its own terms and never looking at the mutable minuend; reading `policy.json` as the operator's voice because the docs say so — the validator's own refusal text *instructs* operators to edit the unauthenticated file, and a same-family reviewer reads that as remediation, not attack surface. And a reactive patch pattern: the praised `approved_by` fix pattern-matches "identity handled," leaving the zero-width sibling of the same class alive.

The component is competent and its central security claims are overstated; two concrete admissions and one contract-violating crash path stand.

verdict: REJECT
