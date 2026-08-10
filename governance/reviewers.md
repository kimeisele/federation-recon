# Reviewers

> The **builder** is documented separately in `governance/builders.md`. It is
> not a reviewer and must never be counted as one: it produces the work under
> review, and its output is untrusted by construction (`docs/execution-core-adr.md`
> §3.2). Both files live outside `CLAUDE.md` for the same reason — a model name
> is a vendor snapshot and will rot.

## Primary review channel: the review pipeline

The **review pipeline** (`scripts/review.sh`) is the primary review channel for
all non-constitutional PRs. It is free (uses the builder's API key), automated,
and produces structured JSON findings with mechanical verification — each
blocking finding must include a `verification_command` that is executed in the
worktree. Only findings whose command exits 0 can block merge. A finding
without a command is downgraded.

The review pipeline replaces the cross-provider consultation process for routine
work. The model is exchangeable via environment variables (`REVIEW_PROVIDER`,
`REVIEW_MODEL`, `REVIEW_API_KEY`, `REVIEW_API_BASE`); the default is DeepSeek.

Invocation: `bash scripts/review.sh --pr <N>`

The pipeline writes verdicts to `~/.local/share/federation-recon/reviews/`,
never inside the repository. The aggregator (`scripts/review-verdict.sh`)
decides APPROVE/REJECT/PARTIAL based on the findings — the model's prose essay
has zero effect on the outcome.

## Paid consultation roster (OWNER-ONLY)

> **All paid consultation calls are classified OWNER-ONLY / STOP.** The
> operator must never invoke `scripts/consult.sh`, `scripts/consult-opencode.sh`,
> or any command that calls a paid external API without explicit prior owner
> authorization. A governance requirement that demands a paid call does not
> authorize the spend — it means STOP and escalate with a cost estimate.
>
> Enforcement: both scripts refuse at entry unless `CONSULT_AUTHORIZED=1` is
> set. This guard is the control; the text here is the description.

Concrete roster for the independence requirement in `CLAUDE.md` → Delegated
judgment. Kept out of the constitution on purpose: model names are a vendor
snapshot and will rot, while the *property* they have to satisfy does not.

Required property: a frontier-class model, **from a different provider than the
operator**, which did not produce or assist the work under review, invoked with
no session context.

| Reviewer | Provider | Invocation |
|---|---|---|
| Fable 5 | Anthropic | `jcode run -p claude -m claude-fable-5` |
| Sol 5.6 | OpenAI | `jcode run -p openai -m gpt-5.6-sol` |
| Kimi K3 | Moonshot | direct API — see below. **Do not use `jcode run` for Kimi.** |
| Qwen 3.7 Max | OpenCode Go service; Qwen upstream model | `scripts/consult-opencode.sh qwen3.7-max <output.md> <prompt-file> <source-repo>` |

### Current non-JCode review channel (2026-08-02, superseded 2026-08-10)

> **This channel does not execute on the operator host and there is no
> affordable substitute. Measured 2026-08-10.**
>
> Both bundled `opencode` binaries die on exec — `opencode-darwin-x64` and
> `opencode-darwin-x64-baseline`, exit 137 — so `consult-opencode.sh` cannot
> run here at all. The section below described the adopted channel while no
> consultation could be produced through it.
>
> The catalogue is reachable directly over HTTP at
> `https://opencode.ai/zen/go/v1` with the `opencode-go` key, but only
> `deepseek-v4-flash` has usable quota; every other model exhausts almost
> immediately. Of those tried on a strict-JSON prompt, `kimi-k3` answered with
> `tool_calls` and empty content, `glm-5.2` returned empty content, and
> `grok-4.5` returned an upstream error.
>
> **So a different-provider reviewer is not purchasable on this project's
> budget.** `docs/review-pipeline-spec-v0.md` now sources Tier 1B's
> independence from executed, base-discriminating, confined verification rather
> than from provider diversity, and states what that costs. The cross-provider
> requirement for risk class HIGH in `CLAUDE.md` is **not** resolved by that
> change and is currently unmet on every change — recorded in
> `docs/enforcement-inventory.md` as unsatisfiable rather than quietly broken.
>
> The text below is kept because the mechanism it describes is sound and would
> be the right channel again if the constraint lifts.

The current operator is OpenAI and the current builder is DeepSeek. Sol and
DeepSeek therefore cannot supply the different-provider judgment for work they
authored or operated. The owner retired Claude from this operation. Moonshot is
unavailable until its exposed credential is rotated in a separate OWNER-ONLY
action.

The adopted bootstrap channel is `opencode-go/qwen3.7-max`, invoked only
through `scripts/consult-opencode.sh`. The wrapper runs the reviewer in a
disposable detached worktree, binds the JSON stream to one session, then checks
the session export for the exact OpenCode Go service provider and requested
model. A mismatch, ambiguous session, missing export, abnormal finish, crash or
missing final verdict produces no consultation.

The disposable worktree prevents reviewer edits from landing in the supplied
checkout; it is **not an OS sandbox**. The model process still has the host
capabilities granted to OpenCode. The wrapper refuses a dirty source checkout
because its detached review would otherwise silently omit uncommitted bytes.

Two facts remain separate in every artifact:

- **service provider:** `opencode-go`, established by the session export;
- **upstream model:** `qwen3.7-max`, asserted by that service's metadata. The
  upstream model provider is not independently established by this control.

This limitation is explicit because treating a service's model label as an
independent network measurement would recreate the provenance overclaim in
#135. The raw JSONL stream and full exported session remain beside the report.

**Neither the env-var form nor the flags are sufficient on their own, and the
correction recorded here on 2026-07-30 was itself wrong.** It said the fix was
to use `-p` / `-m`. Measured on 2026-07-31: those flags are **silently
discarded** whenever `[provider] default_provider` in `~/.jcode/config.toml`
names an API-key provider. Resolution slides to OpenRouter and the request is
served by the DEFAULT model — which in this repository is the builder.

```
$ jcode run -p openai -m gpt-5.6-sol …
SOLTEST_OK                              ← exit 0, plausible answer

log:  auth: DEEPSEEK_API_KEY
      endpoint: https://api.deepseek.com
      prv:OpenRouter|mod:deepseek
```

Three consultations were filed as independent cross-provider reviews on the
strength of that exit status. None were. Streams to `api.openai.com`, by day:
13 on 07-24, 0 on 07-25, 8 on 07-26, 66 on 07-27, then **0 on 07-28, 07-30 and
07-31**. Nothing here noticed for four days; the owner noticed an untouched
subscription quota.

**The working configuration**, measured both ways on 2026-07-31:

```
[provider]
default_provider = "openai"      # an OAuth provider — this is the load-bearing part
default_model    = "gpt-5.6-sol"
```

With an OAuth provider as the default, the flags are honoured:

| invocation | log says |
|---|---|
| `-p openai -m gpt-5.6-sol` | `prv:OpenAI\|mod:gpt` |
| `-p deepseek -m deepseek-v4-flash` | `endpoint: https://api.deepseek.com` |

**Every call must pass `-p` and `-m` explicitly**, including the builder — the
default now names a reviewer, so a bare `jcode run` would review with the
model meant to build.

**Do not dispatch a consultation by hand.** Use `scripts/consult.sh`, which
brackets the run with a timestamp, reads the tool's own log for that window,
and **deletes its output and exits non-zero** when the provider that answered
is not the one asked for. There is no flag to skip that check. What is written
here is a description; the script is the control, and
`check_consultation_provenance` refuses to let an unattributed consultation
reach `main`.
The Kimi entry additionally named the provider id `moonshotai`; the correct id is
`moonshot-ai`, and `jcode run -p moonshot-ai` then hangs — measured at 17
minutes, 0.0% CPU, zero network connections, zero bytes of output.

Worse: the broken invocation **failed over to Anthropic Fable 5** and surfaced
only because that model demanded credits. With credits available it would have
returned a plausible answer that would have been filed as a Kimi judgment — from
the same provider as the operator, defeating the entire requirement.

So the rule below is not about flags:

> **A tool with silent provider failover cannot be the control that guarantees
> provider independence.** Its success proves nothing about who answered.

Call the provider's endpoint directly, and record the `model` field from the
response together with the endpoint. That is evidence; a command that exited 0 is
not. For Kimi:

```bash
set -a; . ~/.config/secrets/env; set +a     # MOONSHOT_API_KEY lives here
curl -s https://api.moonshot.ai/v1/chat/completions \
  -H "Authorization: Bearer $MOONSHOT_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"kimi-k3","messages":[{"role":"user","content":"..."}]}'
```

`kimi-k3` accepts only `temperature: 1` — sending any other value returns HTTP
400. Models available on that endpoint as of 2026-07-30: `kimi-k2.6`,
`kimi-k2.7-code`, `kimi-k2.7-code-highspeed`, `kimi-k3`.

## When to call whom

| Reviewer | Cost | Use for |
|---|---|---|
| **Review pipeline** | free (builder API key) | **default.** Every routine PR review. Structured findings with verification. |
| **Sol 5.6** | subscription — effectively free | Cross-provider review when the consultation gate fires (constitutional files touched). OWNER-ONLY to invoke. |
| **Kimi K3** | per token, real money | **judgments only.** OWNER-ONLY to invoke. |
| Fable 5 | max-plan only, not available here | do not plan around it |

**Kimi is for judgments, not for rounds.** One targeted Kimi consultation caught
two errors in the operator's own reasoning — a false claim about a removed
control, and treating an accepted API parameter as an enforcing one — after four
review rounds had missed both. The same four rounds, run against Kimi, would have
cost several euro and produced less.

Its distinguishing property is not raw capability. It is that it reviews
adversarially without the caution that makes other models skip the ugly cases:
it will attack the mechanism, execute the evasion, and time it.

Budget discipline is not optional politeness. A review process nobody can afford
gets skipped, and a skipped review is the failure mode this whole file exists to
prevent — so the cheap reviewer must carry the volume.

The operator currently runs on Anthropic Opus. Fable 5 is therefore **not** an
independent provider for operator-authored constitutional changes — same
provider. It remains valid for architecture and direction red-teaming, and for
the second opinion where the first came from a third provider.

**Use the invocation verbatim. Do not reconstruct it.** On 2026-07-25 every
review recorded as Kimi K3 / Moonshot used a hand-built invocation instead of the
alias below. The reconstruction was wrong, `jcode` has cross-provider failover
enabled, and which model answered was never established. The reviews were
substantive, but an unverified provider cannot satisfy a requirement whose entire
content is which provider answered.

Asking the model to name itself is **not** the remedy. A self-report is not
evidence — in the same session a DeepSeek call confidently identified itself as
an Anthropic model, and a table was briefly built on that before provider usage
data disproved it. Use the alias, and check `jcode usage` if it matters.

Availability is not an exemption. If a reviewer's budget is exhausted the call
fails; use another. If none can be reached, the change waits.

## Consequence

With the `CONSULT_AUTHORIZED` guard in place, any PR touching constitutional
files (`CLAUDE.md`, `docs/founding-package-v0.2.md`, `docs/*-adr.md`) becomes
blocked for the operator pending owner authorization — the consultation gate
demands an artifact, and the only producers now refuse without the env var. The
owner sets `CONSULT_AUTHORIZED=1` and the path opens. This is correct: changes
to the constitution should not be autonomous.
