# Consultation — adoption of the Execution Core ADR (#105) to Accepted

- **Reviewer:** Kimi K3
- **Provider:** Moonshot — a third provider, independent of the operator
  (Anthropic) and of the reviewer of #107 (OpenAI)
- **Date:** 2026-07-30
- **Mode:** judgment only, no code, capped at 400 words. Kimi is billed per
  token and this was a decision, not a review.
- **Invocation:** direct HTTPS to `api.moonshot.ai/v1/chat/completions`,
  `model: kimi-k3`, 3167 tokens.

Sought because the owner is not technical and correctly refused to adjudicate a
question they could not check: *"asking me for an answer that would only be
misleading."* A rubber stamp is not a control. So the question went to the
provider that produced the architecture judgment this system implements.

The question was narrow: is the measured state a sound basis for **Accepted**
under the narrow wording, or must one of four explicitly unmeasured items be
measured or dropped from the claimed set first?

verdict: APPROVE

## The answer, and what was done with it

**Accept. None of the four blocks it.**

- The STOP-then-KILL protocol's unproven necessity "is not a capability claim.
  The capability — tree dies, stays dead — is demonstrated. Necessity of the
  mechanism is design rationale, and keeping a strictly stronger, free mechanism
  without proof of necessity is correct, not a gap."
- `RLIMIT_AS` and the missing disk cap are **outside the claimed set**. Both
  satisfy the project's own rule: "I don't know" becomes refusal or silence, not
  "all clear".
- The shared preservation witness between `no_network` and `fs_confinement` is
  "the only one touching the claimed set, and it's the closest call" — a real
  hole, because a profile regression that breaks legitimate work without
  breaking the `fs_confinement` workload would ship green. But: the denial
  halves are independently attested, the coupling is disclosed rather than
  implied away, and the narrow wording claims only what is demonstrated. **"Gate
  the fix, not the acceptance."**

Three conditions were given and all three are implemented in this commit:

1. The coupling is stated **inside the claimed-capability sentence** (§7.3), not
   in a caveats section.
2. An independent `no_network` preservation witness is **mandatory before any
   sandbox-profile change and before any second backend** — it gates evolution,
   not this record.
3. The `tree_kill` wording no longer implies a pending measurement: "necessity
   not established; retained because strictly stronger and free."

## Raw answer

**Accept.** None of the four blocks it.

**#1 is not a capability claim.** The capability — tree dies, stays dead — is demonstrated. Necessity of the mechanism is design rationale, and keeping a strictly stronger, free mechanism without proof of necessity is correct, not a gap.

**#2 and #3 are outside the claimed set.** Memory is refused, disk is simply unclaimed. Both satisfy your own rule: "I don't know" becomes refusal or silence, not "all clear." The narrow wording covers only demonstrated capabilities, so unclaimed limits need no measurement.

**#4 is the only one touching the claimed set, and it's the closest call.** Your pairs principle exists precisely because the dead-sandbox incident was a *preservation* failure that denial-only testing missed. A shared preservation witness means `no_network`'s pair is not independently falsifiable — a profile regression that breaks legitimate work without breaking the `fs_confinement` workload would ship green. That is a real hole.

But it still doesn't block: the denial halves are independently attested (mutations redden exactly one canary each), the coupling is disclosed rather than implied away, and the narrow wording claims only what is demonstrated. This is a disclosed limitation, not a false claim. Gate the fix, not the acceptance.

Conditions:

1. State the `no_network`/`fs_confinement` coupling inside the claimed-capability sentence itself, not in a caveats section.
2. An independent `no_network` preservation witness is mandatory before any sandbox-profile change or any second backend — it gates evolution, not this record.
3. Reword #1 as "necessity not established; retained because strictly stronger and free" — remove any implication that measurement is pending.

---
