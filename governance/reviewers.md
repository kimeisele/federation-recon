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
| Kimi K3 | Moonshot | `JCODE_PROVIDER=openai-compatible JCODE_MODEL=kimi-k3 OPENAI_API_KEY=$KIMI_API_KEY OPENAI_BASE_URL=https://api.moonshot.ai/v1 jcode run` |

The operator currently runs on Anthropic Opus. Fable 5 is therefore **not** an
independent provider for operator-authored constitutional changes — same
provider. It remains valid for architecture and direction red-teaming, and for
the second opinion where the first came from a third provider.

Availability is not an exemption. If a reviewer's budget is exhausted the call
fails; use another. If none can be reached, the change waits.
