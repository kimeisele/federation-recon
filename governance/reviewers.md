# Independent reviewers

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

**The `JCODE_PROVIDER=` / `JCODE_MODEL=` form recorded here until 2026-07-30 did
not work.** Those variables are not read by `jcode run`, which takes `-p` / `-m`.
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
