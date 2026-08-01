# The builder

Sibling of `governance/reviewers.md`, and kept out of `CLAUDE.md` for the same
reason stated there: a model name is a vendor snapshot and will rot, while the
*property* it has to satisfy does not.

Required property: a cheap, API-billed model used for bounded implementation
work that a human-written acceptance already constrains. It is **untrusted
output** (`docs/execution-core-adr.md` §3.2) regardless of which model it is.

| | |
|---|---|
| Model | `deepseek-v4-flash` |
| Provider | DeepSeek, API key in `~/.config/secrets/env` |
| How it is selected | **explicit `-p deepseek -m deepseek-v4-flash` on every call** |
| Adopted | 2026-07-31 |

**Corrected the same day it was written.** This file first said the model came
from `[provider] default_model` in `~/.jcode/config.toml` and that the config
was the single place that decided. Hours later the default had to become an
**OAuth provider** — otherwise `jcode run` silently discards `-p`/`-m` and
serves everything from the default, which is how three reviews came to be
answered by the builder's own provider (`governance/reviewers.md`). So the
default now names a *reviewer*, and a bare `jcode run` would build with the
model meant to review the build.

`operator/builders/jcode.sh` therefore passes both flags explicitly. It used to
set `JCODE_PROVIDER` as an environment variable, which `jcode run` does not
read, and to pass no model at all.

Nothing in this repository hardcodes a builder model name — the one occurrence
of `deepseek-v4-pro` under `core/orders/vectors/` is a frozen test fixture in
the acceptance oracle and must not be edited to match reality.

## Why Flash rather than Pro

Measured from the vendor's own pricing page on the day of adoption, per 1M
tokens:

| | Flash | Pro | factor |
|---|---|---|---|
| input, cache miss | $0.14 | $0.435 | **3.1×** |
| output | $0.28 | $0.87 | **3.1×** |
| input, cache hit | $0.0028 | $0.003625 | 1.3× |

Roughly 3.1× cheaper on the two lines that dominate a build, not the 4× the
change was proposed as. The direction is not in doubt; the number is, and the
measured one belongs here rather than the remembered one.

**The capability claim is not established and is recorded as a claim.** The
release notes say Flash has "significantly enhanced agent capabilities, with
benchmark results far exceeding V4-Pro-**Preview**" — a comparison against a
preview variant, published by the seller, on benchmarks the seller chose. That
is a reason to try it, not evidence that it is better at this repository's
work. What would be evidence is builds landing through the same gate at the
same rate, and that accrues over time rather than on adoption day.

**It is a public beta.** On the builder path that is a real risk and the reason
`~/.jcode/config.toml` was backed up before the change; reverting is one line.

## Verifying which model actually answered

`governance/reviewers.md` records why this matters and it applies identically
here: **a tool with silent provider failover cannot be the control that
guarantees which model ran.** jcode is configured with
`cross_provider_failover` and `same_provider_account_failover` enabled, so an
exit status of 0 proves that *something* answered.

Read the `model` field out of the response:

```bash
set -a; . ~/.config/secrets/env; set +a
curl -s https://api.deepseek.com/chat/completions \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"ping"}],"max_tokens":8}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])'
```

The models the API currently offers can be listed with
`curl -s https://api.deepseek.com/models -H "Authorization: Bearer $DEEPSEEK_API_KEY"`.
On 2026-07-31 that returned exactly `deepseek-v4-flash` and `deepseek-v4-pro`.

## Cost, and when to spend it

Announced but not yet in force at adoption: **peak/off-peak pricing, 2× during
peak hours**, 09:00–12:00 and 14:00–18:00 Beijing time. In CEST that is
**03:00–06:00 and 08:00–12:00** — which is precisely when unattended overnight
and early-morning work has been dispatched. Once it takes effect, a build
scheduled for the operator's morning costs double, and the cheap window is the
operator's afternoon and night.

Budget is checked with `jcode usage`. DeepSeek is the scarce resource in this
setup: reviewers are on subscriptions or per-token balances an order of
magnitude larger. Topping it up is a spend decision and therefore OWNER-ONLY
under `CLAUDE.md`; noticing that it is nearly empty is not.
