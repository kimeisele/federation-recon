<!-- provenance
requested_provider: moonshot-ai (api.moonshot.ai, direct HTTPS, no wrapper)
served_model: kimi-k3
finish_reason: stop
prompt_tokens: 1237
completion_tokens: 8028
consistency_check: the model field of the response is the evidence; no tool with provider failover was involved
-->

# Independent architecture review — #233, sandbox placement

**Reviewer:** kimi-k3 (Moonshot), called directly against `https://api.moonshot.ai/v1/chat/completions`.
**Subject:** where the review runner's verification confinement belongs, given `layer-boundary.bats`.
**Authorised by:** the owner, 2026-08-10, explicitly and for this consultation.

The operator favoured option (2). The reviewer rejects it and picks (1).

---

1. Option (1). The boundary's rationale is directional — core must not learn where artifacts live — while the check is symmetric; an evidence-to-core exception concedes nothing the threat model cares about. What the operator doesn't see: preferring (2) is sunk cost defending the inline detour. (2) keeps the third hardcoded call site, keeps commands running as the operator's uid — the actual defect, since one profile bug there is operator compromise — and makes the repo's most security-critical file a shared artifact serving two threat models. "Artifacts, not code" is fiction: fs_confinement.py is executable Python. Moving code until the check stops seeing it is precisely the listing-over-inferring weakness the check file confesses.

2. It protects one narrow, real thing: core must not embed artifact paths, so a hijacked supervisor or escaped worker is not handed directions to the evidence. That invariant governs information flowing out of core. A reviewer importing the backend is flow into core — the worker already executes inside core and knows it exists; it learns nothing and gains no write path. The threat model is unchanged. Here the boundary is cited to avoid deciding: the check has become the invariant, replacing the rationale it encodes. The tell is that option (2) is only attractive if satisfying the text match matters more than the property the text approximates.

3. The Linux CI path. Today the runner fails closed there by accident: sandbox-exec is absent, so nothing runs. After (1), review.sh needs a backend that claims capabilities; on Linux none does, and no designed fail-closed branch exists — every findings PR goes red. The single affordable model will then propose the cheapest fix, a stub null backend that reports success. If that merges, review commands run unconfined exactly where the operator never watches, silently: findings "confirmed" by commands with no sandbox at all. First concrete breakage is CI red; the worse one is the null-backend PR turning it green. Fail-closed was never an interface, only missing software.

4. Yes: a second implementation is the only differential oracle the budget allows. One model authored the backend, the canaries, and the inline profile, so the canaries may be fitted to the backend's known behaviour rather than to confinement itself. Running the same suite against a mechanistically different confinement — operator-uid seatbelt versus separate-uid wrapper — exposes that overfitting, and exposes seatbelt drift after macOS updates when one implementation breaks and the other doesn't. That argues for (3)'s discipline, not its code: diversity is worth keeping only if both implementations are held to §7.3. The operator hasn't stated this because it treats the inline work as an embarrassment rather than an instrument.

5. Run the existing canary suite and the §7.3 no_network preservation probe against the shipped inline profile — today, locally, no merge required; the canaries are already executable. That converts an unproven assertion into evidence, and fs_confinement will likely fail, since no allow line has a paired negative test. Then open two PRs: the (1) allowlist exception, and one adding the missing negative tests so main is honest meanwhile. Do not revert: weak confinement still stops lazy commands. The tension being rationalised: the operator calls main "confined" to avoid saying "untested". The cheapest risk removal available is proof, not more code — and it may reveal current confinement is decorative.

---

## Operator response, measured

**Point 5 is partly refuted.** The reviewer expected `fs_confinement` to fail against the shipped inline profile because no `allow` line carries a paired negative test. Run against the profile on `main`, both halves hold:

```
preservation   read worktree file      ALLOWED
               write scratch           ALLOWED
               grep in worktree        ALLOWED
denial         read ~/.config/secrets/env   BLOCKED
               list $HOME                   BLOCKED
               list /Library/Keychains      BLOCKED
               list /private/tmp            BLOCKED
               write into the worktree      BLOCKED
```

The preservation half was run because a profile that fails to parse blocks everything and passes every denial test — the corpse the ADR names in §7.3. An earlier run of this check included a stray heredoc terminator in the profile and would have reported a false pass on denial alone.

So `main` is confined, not merely asserted to be. What remains true from point 5 is the narrower claim: the `allow` lines still have no *paired* negative tests as §7.3 requires, and this ad-hoc run is not the canary suite.

**Points 1–4 stand, and the one that matters most was not in the operator's list at all:** the inline confinement runs as the operator's own uid, while `core/backends/macos_seatbelt.py` runs work as `_jcode_w01`–`_jcode_w08` through a root-owned wrapper. The operator uid owns the evidence tree. A profile gap there is not a contained failure.
