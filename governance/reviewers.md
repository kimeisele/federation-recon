# Independent reviewers

> The **builder** is documented separately in `governance/builders.md`. It is
> not a reviewer and must never be counted as one: it produces the work under
> review, and its output is untrusted by construction (`docs/execution-core-adr.md`
> §3.2). Both files live outside `CLAUDE.md` for the same reason — a model name
> is a vendor snapshot and will rot.


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
| **Sol 5.6** | subscription — effectively free | **default.** Every routine cross-provider review, every HIGH-risk round, every re-review. |
| **Kimi K3** | per token, real money | **judgments only.** Decisions where the operator distrusts its own reasoning, security review, adversarial code analysis. |
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
