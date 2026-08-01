# Order validation contract — Execution Core S2

This document and the vectors beside it are the **oracle**. They were written
before the validator existed and by someone other than the party that builds
it. That ordering is the point: #103 recorded a run in which the builder wrote
the tests its own work was judged by, and an acceptance criterion the graded
party authored is not an acceptance criterion.

A validator is correct here when `scripts/test/order-validator.bats` passes
against these vectors **unchanged**. Changing a vector to make an
implementation pass is the failure this file exists to prevent; changing one
because it encodes the wrong requirement is legitimate and belongs in its own
pull request, argued on its own, never bundled with the implementation it
would excuse.

---

## 1. What the validator is

Pure, deterministic, no shell invocation, no network, no filesystem access
beyond reading the order file and `core/policy.json` (ADR §11.2).

```
python3 -m core.orders.validate <order-file>
```

- **exit 0** — the order is admissible. Nothing is printed to stderr.
- **exit 1** — the order is refused. The first line of stderr is the reason
  code, alone. Further lines are human explanation and are not tested.

Only the exit status and the reason code are the contract. Wording is free.

Refusal is not a judgment that the order is a bad idea. It is a statement that
the supervisor cannot establish the order is safe to run — and per ADR §6,
*"Fehlende Evidenz ist Ablehnung. 'Nicht gemessen' und 'eingehalten' dürfen nie
dasselbe Ergebnis haben."*

## 2. Reason codes

Closed set. A refusal carrying a code outside it fails the suite.

| Code | Meaning |
|---|---|
| `E_SIZE` | The file exceeds the byte limit. Detected **before** the bytes are parsed (ADR §5: "Bytegrößen-Prüfung **vor** jedem Lesen"). |
| `E_JSON` | Not canonical JSON: duplicate keys, `NaN`/`Infinity`, trailing data, a non-object root, empty input, or nesting past the depth limit. |
| `E_SCHEMA` | Well-formed JSON that does not match the fixed order schema: unknown field, missing required field, wrong type, value outside an enum, malformed identifier. |
| `E_CAPABILITY_UNPROVEN` | Every field is well-formed, but the order requires a capability this backend does not claim. |
| `E_LIMIT` | A reduction is individually well-formed but would leave a non-positive effective limit. |
| `E_BUNDLE_PROVENANCE` | The acceptance bundle is structurally present but its provenance disqualifies it (ADR §10). |

Where two codes could apply, **the earlier row wins**: size before parse,
parse before schema, schema before semantics. A validator that reports
`E_CAPABILITY_UNPROVEN` for an order that also has an unknown field has parsed
further than it should have.

## 3. Order schema v1

```json
{
  "schema": "execution-core/order/v1",
  "run_id": "3f8a1c22-9d4e-4b7a-8f01-2c5e6d7a9b03",
  "issue": 118,
  "base_sha": "aae99c48c90535ae90ecb25c6623db0393c5058c",
  "intent": "one sentence a human can check the result against",
  "required_capabilities": ["no_network", "fs_confinement"],
  "limit_reductions": {"wall_clock_seconds": 30},
  "acceptance_bundle": {
    "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
    "location": "/usr/local/var/jcode-runs/bundles/0000000000000000",
    "author": "kimeisele",
    "approved_by": "kimeisele",
    "created_at": "2026-07-31T05:00:00Z"
  }
}
```

Required: every field above except `limit_reductions`. No additional fields at
any level.

- `schema` — exactly `execution-core/order/v1`.
- `run_id` — RFC 4122 lowercase UUID, `[0-9a-f]{8}-[0-9a-f]{4}-...`. It names a
  directory, so anything that is not this shape is a path.
- `issue` — integer ≥ 1.
- `base_sha` — exactly 40 lowercase hex characters.
- `intent` — 1–200 characters, no control characters (U+0000 through U+001F).
- `required_capabilities` — non-empty array, unique items, each drawn from the
  capability names in `core/policy.json` (`claimed_capabilities` ∪
  `unclaimable_capabilities` keys). The enum is **derived from the policy, not
  copied**: a capability that exists nowhere in the policy is an invention and
  is `E_SCHEMA`, while a capability the policy names but does not claim is
  `E_CAPABILITY_UNPROVEN`. Those two are different failures and must not
  collapse into one.
- `acceptance_bundle.digest` — `sha256:` followed by 64 lowercase hex chars.
- `acceptance_bundle.location` — absolute path with the prefix
  `/usr/local/var/jcode-runs/bundles/`.
- `acceptance_bundle.author` / `approved_by` — 1–64 chars, no control
  characters.
- `acceptance_bundle.created_at` — `YYYY-MM-DDTHH:MM:SSZ`.

Depth limit 8. Size limit 65536 bytes.

## 4. The structural rule about limits

> ADR §11.2 — *"Das Auftragsschema kann gelockerte Grenzen **strukturell** nicht
> ausdrücken."*

Checking that a requested limit is below the policy limit does not satisfy
this. A check can be forgotten, inverted, or bypassed by a path that skips it;
§11.2 asks for a schema in which the looser order **cannot be written down**.

Therefore an order does not state limits. It states **reductions**:

```json
"limit_reductions": {"wall_clock_seconds": 30}
```

meaning *policy limit minus 30*. Effective limit = `policy[key] - reduction`.

Each value is an integer with `minimum: 0`. A looser limit needs a negative
reduction, and a negative reduction is not a member of the type. The
impossibility is in the type, not in a comparison — which is why vector
`07-absolute-limits` (an order carrying a plain `limits` object) is `E_SCHEMA`
for the unremarkable reason that `limits` is not a field, not because anyone
compared numbers.

`E_LIMIT` remains for the case reductions cannot express away: a reduction
large enough to leave an effective limit of zero or less. That is defence in
depth, not the primary mechanism.

### What this does NOT establish, added after a cross-provider re-review

The impossibility is about the **order**, and the sentence above was written as
though it were about the system. It is not.

> "`limit_reductions` makes a looser limit inexpressible *in the order* — but
> the minuend lives in `core/policy.json`, an in-repo file reachable through
> the same PR pipeline the builder exists to use. One merged PR changes
> `wall_clock_seconds: 60 → 86400` […] The validator binds order→policy;
> **nothing binds policy→operator**. The type-level claim is true and
> irrelevant."

Checked: `core/policy.json` is a plain committed file with no gate in
`scripts/ci-checks.sh`, no integrity anchor, and no check anywhere that greps
for it. So an order cannot ask for a looser limit than the policy allows, and
the policy is exactly as hard to change as any other file in the repository.

**And this is not only about limits.** A second reviewer widened it:

> "`claimed_capabilities` admission *also* rests entirely on the same
> unguarded, operator-writable file, read via a `__file__`-relative path (a
> relocated validator copy reads a different policy). If the corrected
> sentence only scopes the caveat to `limit_reductions`, it still overstates."

So, plainly: **every verdict this validator reaches is exactly as strong as
`core/policy.json`.** Limits and capabilities both. `E_CAPABILITY_UNPROVEN`
means "the policy does not claim it", not "the backend cannot do it", and
moving a name into `claimed_capabilities` is one line in an unguarded file.

The validator is a faithful reader of a document nothing protects.

Both earlier reviews of this design praised the reduction encoding. Neither
asked where the number it subtracts from comes from — and both were served, it
turned out, by the same provider as the builder. What binds the policy is
open as #141 and is not decided here.

Keys are restricted to those present in `policy.json`'s `limits` object.

## 5. Bundle provenance

ADR §10 binds the acceptance bundle: created before the build run, outside the
patch tree, digest bound before the run, **never produced or altered by the
builder under test**, author and approval recorded.

Three of those the validator can decide from the order alone:

- `location` outside the patch tree — enforced by the required absolute prefix.
- **Neither `author` nor `approved_by` is a builder identity** — either field
  matching `jcode`, `deepseek`, `builder`, or `worker` (case-insensitive
  substring) is `E_BUNDLE_PROVENANCE`.

  This said `author` alone until 2026-07-31, when an independent red-team put
  a builder name in `approved_by`, left everything else impeccable, and was
  admitted with exit 0 and silent stderr in about a minute. An approval is not
  a lesser thing than authorship — it is the field that decides whether the
  order proceeds — and a rule enforced on one of two adjacent fields is an
  invitation to use the other.

**Deliberately not required: that `author` and `approved_by` differ.** The same
review noted self-approval passes. It is not adopted, because two distinct
strings are not two distinct people: `kimeisele` and `kim eisele` would satisfy
it while nothing changed. That is theatre, and theatre in a provenance rule is
worse than a stated gap — it converts "unverified" into "checked". Who may
approve is a policy question for the owner and belongs in the run record's
approval, not in a string comparison.

**What it cannot decide, and must not appear to:** that the digest matches the
bytes at `location`, that those bytes predate the build run, or that the
approval is genuine. Those belong to S3, where the supervisor has the bundle in
hand. A green validator establishes that the order *claims* a well-formed
provenance — per ADR §3.3, a claim, not a finding.

**`location` is never checked for existence, and never can be.** The question
"can a location still name nothing while passing?" has one honest answer:
**always.** This validator is pure — it reads the order and `core/policy.json`
and touches no other path — so `location` is checked for *shape* only: the
required absolute prefix, not equal to the bundles directory itself after
`normpath`, and no `.` or `..` segment. A syntactically perfect path to a file
that was never written passes every one of those and is admitted.

The shape rules exist to stop a `location` from *denoting* something outside
the bundle tree, not to establish that it denotes anything at all. Reading the
bytes is S3's job, and until S3 exists, "the order passed validation" says
nothing whatever about whether an acceptance bundle is on disk.

## 6. The vectors

`vectors/reject/` — each file must be refused with the code recorded for it in
`vectors/manifest.json`. Both the refusal *and the specific code* are tested; a
validator that refuses everything with one code fails.

`vectors/accept/` — each file must be accepted, exit 0, silent stderr. These
carry the suite: without them, `sys.exit(1)` on line one is a passing
implementation.

Vector files are raw bytes, not generated. Some are deliberately not
loadable by `json.load` (duplicate keys, `NaN`), which is exactly what they
test, and is why they are stored as text rather than built from Python objects.
