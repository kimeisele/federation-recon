# Independent reviewers

Concrete roster for the independence requirement in `CLAUDE.md` → Delegated
judgment. Kept out of the constitution on purpose: model names are a vendor
snapshot and will rot, while the *property* they have to satisfy does not.

Required property: a frontier-class model, **from a different provider than the
operator**, which did not produce or assist the work under review, invoked with
no session context.

| Reviewer | Provider | Invocation |
|---|---|---|
| Fable 5 | Anthropic | `JCODE_PROVIDER=claude JCODE_MODEL=claude-fable-5 jcode run` |
| Sol 5.6 | OpenAI | `JCODE_PROVIDER=openai JCODE_MODEL=gpt-5.6-sol jcode run` |
| Kimi K3 | Moonshot | `JCODE_PROVIDER=moonshotai JCODE_MODEL=kimi-k3 jcode run` |

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

<!-- enforcement probe -->
