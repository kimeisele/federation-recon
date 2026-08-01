<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Review — PR #142, round 2: are C1–C5 closed?

Same reviewer as round 1, asked to rule CLOSED or OPEN on each of its own
conditions, with the instruction that a condition is closed only if the diff
shows the mechanism, not prose describing it.

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Response id | `chatcmpl-6a6e19b0f8959ed0cb46a7ee` |
| Tokens | prompt 12084, completion 13403 (reasoning 11449) |
| Mode | **diff mode — the reviewer executed nothing**, and labelled it |

**Not dispatched through `jcode`.** The first attempt was, and hung for 10 h 45 m
without emitting a token under a configured 180-second idle timeout (#149). A
review is a completion, not an agentic run; the CLI layer contributed nothing
and cost a night. The response body carrying its own `model` is also stronger
evidence than reading the audited tool's log — the objection that forced #137
to downgrade its own claim.

**Operator note, written after executing the findings:** C1's two named inputs
were verified by running them. Both were admitted, and two more of the same
class were found in the process (U+00A0, U+2028). Fixed in `ec2743d`; every
stripped category is now mutation-tested individually.

---

## C1 — `_fold_identity` category strip: **OPEN**

What the diff does show (real mechanisms, verified):

- `unicodedata.normalize('NFKD', value)` before stripping — the compose-then-strip bypass (combining acute → precomposed `é`, cat Ll) is genuinely dead. Vector 41 structurally pins this: with NFKC-first it is ADMITTED, with NFKD-first it is refused.
- Category filter `unicodedata.category(c) not in ('Cf','Cc','Mn')` — closes every named round-1 Cf/Mn vector: U+061C, U+FFF9, U+E0065, U+180E (Cf on any Python ≥3.4), U+034F (Mn).

What survives — predicted exit 0, ADMITTED, refutation would be refusal:

1. **The exact vector round 1 named.** `"deep\u2004seek"` (THREE-PER-EM SPACE, Zs, `<compat> 0020`). The reorder does not save it: **NFKD itself applies the compatibility decomposition**, so U+2004 → U+0020 *before* the strip, and U+0020 is Zs — not in `('Cf','Cc','Mn')`. Result `"deep seek"`, substring gone, ADMITTED. Same for U+00A0, U+2000–U+200A, U+3000. And U+2028 (Zl) / U+2029 (Zp) survive with no mapping at all: `"deep\u2028seek"` → ADMITTED. The fix for "NFKC opens a space" had to be adding `Zs/Zl/Zp` to the strip set; it wasn't.
2. **`Me` was demanded and is absent.** Round-1 fix text: `category(ch) in ('Cf','Mn','Me')`. Shipped: `('Cf','Cc','Mn')`. `"deep\u20DDseek"` (COMBINING ENCLOSING CIRCLE, Me, no decomposition): survives the filter, NFKC no-op, lowercase no-op → ADMITTED. `Cc` was added instead — controls are already rejected by the JSON layer in strings and change nothing here; it's the wrong category for the named threat.

The comment honesty requirement is substantively met ("does not make identity-as-text sound… theatre… real answer is signed attestation (#141)"), but the mechanism gaps are code, not prose. OPEN on (1) and (2).

## C2 — huge-integer guard: **CLOSED**

Both demanded mechanisms are in the diff, not described but present:

- `n = sys.get_int_max_str_digits()` with `return n if n > 0 else 10 ** 9` and `except AttributeError: return 4300` — runtime read, disabled-limit and pre-3.11 cases handled correctly.
- `if re.search(r'[0-9]{%d,}' % _limit, text): _refuse('E_JSON', …)` — boundary is right (`{640,}` matches the 640th digit, which is exactly what raises under `PYTHONINTMAXSTRDIGITS=640`).
- `except ValueError as exc:` placed *after* `except json.JSONDecodeError` (subclass ordering correct) → `_refuse('E_JSON', …)`.
- The round-1 "minor" (over-refusal on digit runs inside strings) is now documented in the refusal message itself and pinned by vector 46. The backstop's unreachability is disclosed in the comment rather than claimed as tested — acceptable, matches the refutation standard.

## C3 — location: **OPEN** (code closed, contract half absent)

Code — closed, both mechanisms present:

- `if os.path.normpath(location) == os.path.normpath(BUNDLE_PREFIX): _refuse(...)` — kills `bundles/`, `bundles//`, `bundles/.`, `bundles/./` in one comparison.
- `if '..' in segments or '.' in segments:` — kills `bundles/./real-bundle`.
- Vectors 44/45 are a verifiably discriminating pair: 44 (`bundles//`) has empty-string segments, is string-unequal to the prefix, so *only* normpath refuses it; 45 normpaths to a real bundle, so *only* the `.`-segment rule refuses it. Mutation-masking between the two guards is structurally covered.

Contract — **not in the diff.** Q8 required the contract to state existence is never verified. The only CONTRACT.md hunk (`@@ -127,6 +127,42 @@`) is entirely the policy-binding section; nothing under §5 states that `location` is never checked for existence, i.e. that a passing location can still name nothing. The honest answer round 1 demanded ("**always**") is not written anywhere shown. One sentence; still absent → OPEN.

## C4 — regression vectors / mutation-red: **OPEN**

Shown: manifest entries 37–46 with files; the 44/45/46 discrimination structure is real (verifiable by inspection, above); vector 37 makes "revert the fold call" go red; 41 pins NFKD-ordering; 42 pins the compat-fold step. The `ValueError` backstop has no vector *and* the code comment says so plainly — accepted as disclosed-unreachable, per C2.

Not done, per the explicit condition "my vectors from §2 must be added **regardless**":

- None of the five named Cf/Mn insertions (U+061C, U+FFF9, U+E0065, U+180E, U+034F) are vectors. They are covered by the class fix, but the condition was unconditional.
- No vector for U+2004 (or any Zs/Zl/Zp) and none for an Me mark — and these two **are admitted by the current code** (C1). The suite is green against a live bypass class, which is precisely the failure mode Q3 named: "if the suite currently passes with them, the fixes are untested against their own bypass class."
- The bats harness files are again absent from the diff. The 1–36 precedent implies a manifest-driven runner, but execution of these entries is not verifiable from what was shown.

## C5 — contract wording: **CLOSED**

The demanded sentence exists nearly verbatim and is scoped correctly: "**every verdict this validator reaches is exactly as strong as `core/policy.json`.** Limits and capabilities both." Plus the capability-specific landing: "`E_CAPABILITY_UNPROVEN` means 'the policy does not claim it', not 'the backend cannot do it'", and the `__file__`-relative / relocated-copy caveat is quoted into the document. Not scoped to `limit_reductions` alone. (The "Checked: …no gate in `scripts/ci-checks.sh`" claim is unverifiable from this diff, but C5 demanded the sentence, and the sentence is there.)

## New findings

1. **Dead code:** `_INVISIBLE` (the 13-codepoint tuple) is still defined at module scope and referenced nowhere after the `_fold_identity` rewrite. Remove it or the next reviewer treats it as the live list.
2. **Vector env-fragility (38, 46):** under `PYTHONINTMAXSTRDIGITS=0` (legal: 0 = no limit), `_max_int_digits()` → 10⁹, the pre-filter can never match a ≤64 KiB document, and the parser genuinely has no limit — *correct* code behavior, but both vectors would be ADMITTED and the suite goes red for environmental, not regression, reasons. Pin the env in test setup or mark the vectors env-dependent.
3. **Over-strip side effect:** `José` → NFKD → strip → `jose`. Refuse-list only, so the asymmetry is safe (more refusals, never fewer), but it's undocumented.
4. Verified non-regression, noting for the record: `_fold_identity` raises `TypeError` on non-str input where the old code raised `AttributeError` — same failure class, presumably gated by schema validation upstream; unchanged exposure.

## Summary

| | |
|---|---|
| C1 | **OPEN** — Zs/Zl/Zp survive (`deep\u2004seek` → ADMITTED, the exact vector round 1 named); `Me` demanded, absent (`deep\u20DDseek` → ADMITTED) |
| C2 | **CLOSED** |
| C3 | **OPEN** — code closed with discriminating vectors; "existence is never verified" sentence absent from CONTRACT.md §5 |
| C4 | **OPEN** — §2 vectors not added; the two live bypasses (U+2004, U+20DD) have no regression vector, suite green against them |
| C5 | **CLOSED** |

The C2 work is exactly what was asked, and the 44/45/46 vector design shows the mutation discipline was actually practiced. But C1 has two concrete, named, still-admitted inputs, and C3/C4 each have a demanded artifact missing from the diff.

verdict: REJECT
