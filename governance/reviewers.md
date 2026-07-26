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

The operator currently runs on Anthropic Opus. Fable 5 is therefore **not** an
independent provider for operator-authored constitutional changes — same
provider. It remains valid for architecture and direction red-teaming, and for
the second opinion where the first came from a third provider.

**Verify the invocation, not the intent.** On 2026-07-25 every review recorded
as Kimi K3 / Moonshot was in fact served by an Anthropic model: the invocation
carried a misconfigured provider setting, and nothing checked. The reviews were
substantive and found real defects, but they were Anthropic reviewing Anthropic,
which is precisely what this file exists to prevent. Use the aliases below
verbatim rather than reconstructing an equivalent invocation by hand.

Asking the model to name itself is not the fix — a model's self-report is not
evidence. The fix is to invoke it correctly.

Availability is not an exemption. If a reviewer's budget is exhausted the call
fails; use another. If none can be reached, the change waits.
