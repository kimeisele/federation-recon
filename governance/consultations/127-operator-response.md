# Operator response to the red-team review of PR #127

`governance/adversarial-review.md` makes this response mechanical rather than
attentive: every numbered finding is quoted and answered **fixed** (with the
commit), **rejected** (with the reason), or **deferred** (with the issue). A
finding that is not quoted has not been read. The failure this replaces —
reading `verdict: APPROVE` and merging past a numbered blocking condition
beneath it — put an unratified constitutional amendment onto `main` (#55).

The review is `governance/consultations/127-sol.md`. Its verdict was **REJECT**
with four conditions.

---

## The four blocking conditions

### Condition 1 — `approved_by` unchecked for builder identities

> "Add `approved_by` to the builder-identity check (same case-insensitive
> substring match against `BUILDER_NAMES` applied to `author`)."

**FIXED.** The reviewer executed this one: `author: "kimeisele"`,
`approved_by: "jcode"` was admitted, exit 0, silent stderr, in about a minute.

The gap was in `CONTRACT.md` §5 before it was in the code — I wrote *"`author`
not a builder identity"* and *"`approved_by` present"*, so the implementation
enforced exactly what the contract asked for. The contract now requires
**neither** field to be a builder identity, with the reasoning that an approval
is not a lesser thing than authorship: it is the field that decides whether the
order proceeds, and a rule enforced on one of two adjacent fields is an
invitation to use the other.

Re-run against the fix:

```
approved_by = "jcode"        → E_BUNDLE_PROVENANCE
approved_by = "DeepSeek Ltd" → E_BUNDLE_PROVENANCE
human author + human approver → admitted
```

### Condition 2 — no vector for a builder-approved bundle

> "Add a reject vector where `approved_by` is a builder name and `author` is
> not, expecting `E_BUNDLE_PROVENANCE`."

**FIXED.** `vectors/reject/36-bundle-approved-by-builder.json`, with the
manifest entry recording that it came from an executed red-team evasion rather
than from imagination.

### Condition 3 — the validator has no caller

> "Wire the validator into the execution path: `core/launcher.py` (or its
> successor) must call `core.orders.validate` before any workspace creation or
> backend call, and refuse the order on non-zero exit."

**FIXED — after a second reviewer overruled my intention to defer it.**

My first response was going to be a deferral. My argument had three parts: that
no execution path exists yet because building and verification runs are S3/S4;
that wiring a call into `launcher.py` would create the *appearance* of
enforcement on a path that is not the execution path; and that there is
owner-accepted precedent in #116/#117, where a detector merged and "nothing
invokes it" became its own tracked issue.

I had an obvious interest in that argument being accepted, so I put it to a
third provider rather than ruling on it myself
(`governance/consultations/127-kimi.md`, Kimi K3, endpoint and `model` field
recorded). It ruled **DO NOT MERGE**, and the part that mattered was not the
verdict but a factual correction:

> "Premise (a) is false. There is [an execution path]. S1 merged an isolation
> backend, and launcher.py invokes it today to run canaries. That is a live
> execution path with a real capability at the end of it. There is exactly one
> place in this repository where backend calls happen. Wire it there."

That is true, and I was wrong. It also rejected the precedent:

> "A detector missing its cron is an operational gap; a safety gate missing its
> caller is the control not existing. That precedent is the habit to break, not
> to follow."

And it named the reason the deferral was worse than it looked: deferred, the
gate's first contact with real plumbing is S4 or S5, *"when failure is expensive
and pressure to waive is maximal."*

So the gate is wired, in the shape the ruling described. `core/launcher.py` now
takes an order file as its **required** first argument — not a flag, because an
optional gate is bypassed by omitting it, and then the thing that can be left
out is the gate rather than the order. Validation runs before the backend module
is imported, so a refused order cannot reach the backend even by accident: there
is none loaded to reach. The launcher then re-checks the order's capabilities
itself rather than inheriting the validator's verdict.

`scripts/test/launcher-order-gate.bats`, five tests, asserts the property
directly rather than by proxy — after a refusal, `sys.modules` contains no
backend module.

**Stated rather than papered over:** these tests cover the *refusal* half, which
needs no sandbox host. The admission half stops at "the order got past the
gate", because what follows needs the root-owned pool from `docs/s1-setup.md`
and cannot run in CI. The asymmetry happens to favour the tests — the enforcing
half is the one that runs everywhere — but it is a real limit and it is in the
test file's header, not only here.

### Condition 4 — `_load_policy()` raises instead of refusing

> "Add error handling in `_load_policy()` so a missing or unreadable
> `policy.json` produces a proper reason code on stderr line one, not a Python
> traceback."

**FIXED.** A missing `policy.json` used to put `Traceback (most recent call
last):` where a caller reads the reason code — fail-closed in status, unusable
in content, and the same defect vector 34 was added to prevent.

Both unreadable-input paths — the order and the policy — now funnel through one
function, `_refuse_unreadable`. The code it emits is still `E_SIZE`, which is
the wrong category and is #126; putting the decision in one place is what makes
#126 a one-function change rather than a hunt.

---

## Non-blocking findings

**1.3 / 2 / 8.1 — "no production caller", "does not fire in the environment it
was built for".** Same finding as condition 3. Fixed.

**1.4 — bundle digest and location are format-checked, not verified.**
**Rejected as a defect, accepted as a limit.** The validator never sees the
bundle; verifying the digest against bytes is S3, where the supervisor has the
bundle in hand. `CONTRACT.md` §5 says so before the code does, and the review
agrees under question 4 that this is honest scoping rather than overclaiming.

**1.5 — `created_at` is format-checked, not compared.** Same answer. There is
nothing to compare it against at validation time; the build run has not started.

**1.6 / 5.6 — `approved_by` of `"."` passes.** **Rejected.** Length and
character class are all a string field can carry. Any semantic rule I could add
here — a minimum word count, a name pattern — would be defeated by typing
`"Kim E"` and would convert *unverified* into *checked*, which is the failure
mode this whole document is about.

**1.2 / 5.2 — self-approval (`author == approved_by`) passes.**
**Rejected, deliberately, and recorded in `CONTRACT.md` §5.** Two distinct
strings are not two distinct people: `kimeisele` and `kim eisele` would satisfy
a difference check while nothing changed. That is theatre, and theatre in a
provenance rule is worse than a stated gap. Who may approve is a policy question
for the owner and belongs in the approval itself, not in a string comparison.

**5.4 — missing `policy.json` produces a traceback.** Fixed under condition 4.

**5.3 / 11.4 — unreadable input reports `E_SIZE`.** **Deferred to #126**, which
the review independently judged an honest deferral. The behaviour is
fail-closed and the human-readable line names the real problem; only the
category is wrong, and fixing it means changing a published contract.

**11.1 — the depth pre-scan accepts unbalanced input.** **Rejected as
harmless**, as the review itself concludes: `_check_depth` is a resource limit,
not a grammar, and unbalanced input is rejected by the parser immediately after.

**11.2 — the builder-name substring match is broad.** **Rejected**, and
deliberately so — vector 31 exists to hold that position: *"a provenance rule
that a rename defeats is not a rule, and a wrongly-refused order costs one edit
while a wrongly-accepted one costs the oracle."*

**11.3 — vectors 34 and 35 written after seeing the implementation.** The review
judged the disclosure adequate and the oracle uncompromised. Recorded, not
argued with; the disclosure stands in the commit message either way.

**8.6 — no CI job runs the validator against a sample order.** **Partially
fixed, partially deferred.** `launcher-order-gate.bats` runs 39 real orders
through the launcher on every CI run, so the gate now fires in CI. What CI still
cannot do is complete an admitted run, because that needs the root-owned pool.
Tracked with the S3 work rather than claimed as done.

---

## What the review changed, in one line

The verdict changed the code twice: once for a hole I had written into the
contract and not noticed, and once for a deferral I had reasoned my way into
and would have taken. The second is the one worth the money.
