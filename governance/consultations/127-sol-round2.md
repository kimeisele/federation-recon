# Round 2 — S2 order validator (PR #127), follow-up review

**Reviewed by:** independent red-team reviewer (same provider as round 1)
**Date:** 2026-07-31
**Round-1 report:** `governance/consultations/127-sol.md` (verdict: REJECT, four conditions)
**New commits since round 1:** `f08839e` ("Put the gate on the path, because a gate beside the path is a prop")

---

## 10. Were the prior conditions literally met?

### Condition 1 — approved_by builder-identity check

> "Add `approved_by` to the builder-identity check (same case-insensitive
> substring match against `BUILDER_NAMES` applied to `author`)."

**SATISFIED in letter and in substance.** `validate.py` lines 443–454 iterate over
both `('author', 'approved_by')` with the same case-insensitive substring match.
Re-running evasion 1:

```
approved_by = "jcode", author = "kimeisele"  →  E_BUNDLE_PROVENANCE  (exit 1)
approved_by = "jcode", author = "kimeisele"  →  ORDER REFUSED: E_BUNDLE_PROVENANCE  (through launcher)
```

**[EXECUTED]** — both the validator directly and the launcher refuse. The evasion
that took ~1 minute in round 1 now has zero effect. `CONTRACT.md` §5 was also
updated to state the rule on both fields with a record of how the gap was found.

### Condition 2 — test vector for builder-approved bundle

> "Add a reject vector where `approved_by` is a builder name and `author` is
> not, expecting `E_BUNDLE_PROVENANCE`."

**SATISFIED in letter and in substance.** Vector 36
(`vectors/reject/36-bundle-approved-by-builder.json`) exists with `author:
"kimeisele"`, `approved_by: "jcode"`. The manifest entry records: *"Found by an
independent red-team, which put the builder name in the field the rule did not
cover and got exit 0 with silent stderr in about a minute."* The vector is
registered in `manifest.json`, passes through `order-validator.bats` (test 2),
and passes through `launcher-order-gate.bats` (test 3 — all 39 reject vectors
pass through the launcher unchanged).

**[EXECUTED]** — `bats scripts/test/order-validator.bats`: 8/8 pass, vector 36
fires with `E_BUNDLE_PROVENANCE`. `bats scripts/test/launcher-order-gate.bats`:
5/5 pass, vector 36 fires through the launcher.

### Condition 3 — wire the validator into the execution path

> "Wire the validator into the execution path: `core/launcher.py` (or its
> successor) must call `core.orders.validate` before any workspace creation or
> backend call, and refuse the order on non-zero exit."

**SATISFIED in letter and in substance — with one note.**

The wiring is in `core/launcher.py` commit `f08839e`, exactly in the shape the
Kimi K3 ruling described. The order file is a **required** first argument, not a
flag (zero args → exit 2, extra args → exit 2). Validation runs at line 192
before the backend module is imported at line 210. The launcher re-checks the
order's capabilities itself (line 215) rather than inheriting the validator's
verdict. On refusal it prints which code, shows the validator's stderr, and
states the backend was not consulted.

`launcher-order-gate.bats` (5 tests) asserts the property directly rather than
by proxy:

- Test 1: order file is required, not optional
- Test 2: after refusal, `sys.modules` contains no backend module — the property
  is asserted by inspecting `sys.modules`, not by reading a comment
- Test 3: all 39 reject vectors pass through the launcher unchanged (same exit
  code, same refusal code)
- Test 4: an admissible order gets past the gate (checks for "admitted for
  issue", not "ORDER REFUSED")
- Test 5: the refusal message says the backend was not consulted

All 5 pass. **[EXECUTED]**

**The note:** the launcher re-reads the order file at line 203 after validation
passes. The validator reads the file at line 474. Between these two `open()`
calls, a concurrent writer could replace the file with different content. The
validator passes against order A; the launcher proceeds with order B. This is a
TOCTOU window. In practice it requires a concurrent attacker on the same
filesystem, which is not the threat model this gate addresses, but it deserves
recording because the operator's own ADR §5 says *"Bytegrößen-Prüfung vor jedem
Lesen"* — and the launcher does not re-validate the bytes it reads the second
time.

This does not block approval. The gate is on the path and the backend is
unreachable without passing it. The TOCTOU is narrower than the absence of the
gate was.

### Condition 4 — _load_policy() error handling

> "Add error handling in `_load_policy()` so a missing or unreadable
> `policy.json` produces a proper reason code on stderr line one, not a Python
> traceback."

**SATISFIED in letter and in substance.** `_load_policy()` (lines 67–75) catches
`OSError` and routes through `_refuse_unreadable`, which emits the bare reason
code `E_SIZE` on stderr line one followed by a human explanation. A
`JSONDecodeError` is caught separately and emits `E_JSON`. The uncaught
`FileNotFoundError` that put `Traceback (most recent call last):` on the first
line is gone.

The code it emits is still `E_SIZE`, which is the wrong semantic category.
`_refuse_unreadable` (lines 48–65) states this explicitly: *"the reason code is
provisional — see #126."* This is the honest deferral the round-1 review
endorsed.

**[EXECUTED]** — absent `policy.json` now produces:
```
E_SIZE
Cannot read the policy: [Errno 2] No such file or directory: '.../policy.json'
  (reason code is provisional — see #126)
```
Exit 1, bare code on line one. The traceback is gone.

---

## Operator response — non-blocking rejections judged

The operator's response (`governance/consultations/127-operator-response.md`)
quotes every finding and answers each. I judge the rejections:

### 1.2 / 5.2 — self-approval (`author == approved_by`) passes

**Rejected by operator.** The operator's reasoning: two distinct strings are not
two distinct people; `kimeisele` and `kim eisele` would satisfy a difference
check while nothing changed; theatre in a provenance rule is worse than a stated
gap. `CONTRACT.md` §5 records the rejection deliberately.

**Ruling: legitimate rejection.** The operator is right that a string-comparison
rule converts "unverified" into "checked" without changing anything. The gap is
stated, not hidden. A policy decision about who may approve belongs in the
approval record, not in a character comparison. I am not being talked out of a
real finding — I am being shown that the finding, if "fixed" as proposed, would
create a worse defect (false confidence).

### 1.6 — `approved_by` of `"."` passes

**Rejected by operator.** Length and character class are all a string field can
carry; any semantic rule (minimum word count, name pattern) would be defeated by
typing `Kim E` and would convert unverified into checked.

**Ruling: legitimate rejection.** Same reasoning as self-approval. The field is
a record, not a verifier. Making the validator pretend to verify identity via
string heuristics is the failure mode, not the fix.

### 11.2 — the builder-name substring match is broad

**Rejected by operator.** Deliberately so — vector 31 exists to hold that
position: *"a provenance rule that a rename defeats is not a rule, and a
wrongly-refused order costs one edit while a wrongly-accepted one costs the
oracle."*

**Ruling: legitimate rejection.** The round-1 review itself judged this
tradeoff reasonable under §11.2. The operator is restating my own analysis, not
disputing it. The false-positive cost (one edit to rename the author to avoid
matching "Shipbuilder Industries") is bounded; the false-negative cost (oracle
compromise) is not.

### 1.4, 1.5 — digest/location format-checked not verified; created_at not compared

**Rejected by operator as defects, accepted as limits.** These are S3 concerns;
the validator never sees the bundle and the build run hasn't started.

**Ruling: legitimate.** The round-1 review under question 4 already judged this
honest scoping: *"The gap: admissibility here means 'no structural defect
detected,' not 'the order is safe to execute.'"* The operator is restating what
I wrote. No dispute.

---

## Honest deferrals

### E_SIZE for unreadable input (#126)

`_refuse_unreadable` (lines 48–65) explicitly states: *"the reason code is
provisional — see #126."* The refusal is fail-closed (exit 1), the human line
names the real problem, and the decision about which code to use is a contract
change that belongs in its own PR. This is the same deferral the round-1 review
judged honest under §11.4.

**Judgment: honest deferral, not convenient.** The function was written
specifically to make #126 a one-function change when the contract decision is
made. That is engineering discipline, not procrastination.

### CI cannot complete an admitted run

`launcher-order-gate.bats` header (lines 3–18) states: *"The admission half
stops at 'the order got past the gate', because what follows needs the
root-owned pool from docs/s1-setup.md and cannot run in CI."*

**Judgment: honest deferral, not convenient.** The gate's enforcing half — the
refusal path — is what runs in CI. That is the half that matters for correctness.
The admission half can only be completed on a machine with the root-owned
sandbox pool. The asymmetry is stated rather than papered over, and it happens
to favour the tests (the enforcing half is the one that runs everywhere).

---

## Question 1 — How do you defeat the new gate?

### Attempted: argv manipulation

The launcher requires exactly one argument. Zero args → exit 2. Extra args →
exit 2. The order path is always validated. **[EXECUTED — no bypass.]**

### Attempted: PYTHONPATH injection

`validate_order` does `sys.path.insert(0, _CORE_DIR)` before importing
`orders.validate`. `_CORE_DIR` is computed from `__file__`, not from user input.
PYTHONPATH entries are inserted after `_CORE_DIR`. **[EXECUTED — no bypass.]**

### Attempted: import the backend directly

`import backends.macos_seatbelt` works directly from Python. But this is "not
using the launcher," not bypassing a gate on the launcher. The gate cannot
prevent code that does not go through the launcher from importing a module. The
question asked for a path that "reaches the backend without a passing
validation" — importing the backend directly is such a path, but it is not a
*launcher gate* bypass. It is the absence of the launcher. **[EXECUTED — this
is "don't use the launcher," not a bypass.]**

### Attempted: call internal functions

`launcher.validate_order()` can be called with an acceptable order, returning
`(0, "")`. Then `launcher._run_canary_suite()` can be called, invoking the
backend. But `_run_canary_suite` is a private function prefixed with underscore.
This is calling internal implementation details of a module, not using its
public interface. **[EXECUTED — validate_order returns rc=0 for a valid order;
this is the function's purpose, not a bypass.]**

### Attempted: TOCTOU symlink swap

The launcher validates the order (line 192), then re-opens and reads it (line
203). Between these two `open()` calls, a concurrent writer could replace the
file. This requires a concurrent attacker on the same filesystem — not the
threat model the gate addresses, but a real window. The launcher does not
re-validate the bytes it reads the second time. **[ANALYZED — the window exists
but requires a concurrent attacker. No static argv/env/import-path bypass
exploits it.]**

### Verdict on the gate

The gate is on the path. It fires before the backend is imported. No argv,
environment, or import-path manipulation reaches the backend through the
launcher without a passing validation. The TOCTOU between validation and re-read
is a design note, not a bypass.

---

## Question 3 — Which of the wiring's checks are untested?

I analyzed each test in `launcher-order-gate.bats` and the corresponding code
path it guards:

| Check | Test | Catches removal? |
|---|---|---|
| Order file is required (len(argv) != 1 → exit 2) | Test 1 | Yes |
| Zero-arg refusal | Test 1 | Yes |
| Extra-arg refusal | Test 1 | Yes |
| Validator runs before backend import | Test 2 (sys.modules) | Yes |
| Launcher doesn't soften the verdict (all reject vectors checked) | Test 3 | Yes |
| Admissible order gets past the gate | Test 4 | Yes |
| Refusal message says backend was not consulted | Test 5 | Yes |

**No untested check found** in the existing test coverage. Every gate property
has a corresponding test.

**One untested failure mode:** if `import orders.validate` raises `ImportError`
inside `validate_order`, the exception propagates uncaught. Main() does not wrap
the call in a try/except. The result is a Python traceback on stderr and a
non-zero exit — fail-closed in status, but the traceback violates the bare-code-
on-line-one contract in the same way the missing-policy defect did (condition
4). This is not a gate bypass — the backend is never imported — but it is the
same class of defect. A `try: import ... except ImportError:` wrapper with a
clean refusal would close it.

---

## Question 9 — Run the new mechanism against the change that introduces it

The new mechanism is the wired launcher gate. The change that introduces it is
commit `f08839e`.

**Test: run every reject vector through the launcher.** Test 3 of
`launcher-order-gate.bats` does exactly this — all 39 reject vectors pass
through the launcher unchanged. **[EXECUTED — 5/5 bats tests pass.]**

**Test: run an admissible order through the launcher.** Test 4 checks that
`01-minimal.json` gets past the gate and says "admitted for issue."
**[EXECUTED — passes.]**

**Test: the change's own PR order.** An order for the wiring commit itself
(`f08839e`) would need `author` and `approved_by` not matching builder names.
Using `kimeisele` for both (self-approval, which per the operator's deliberate
decision in CONTRACT.md §5 is accepted), the validator admits it. The launcher
would then run the canary suite (and hang without root access, as acknowledged).
The gate mechanism admits its own change correctly — it checks what it is
designed to check.

---

## Question 5 — Which failure mode looks like success?

### TOCTOU between validation and re-read

The launcher validates order A, then re-reads the file (now order B). The
validator passed; the launcher proceeds with B. If B is malicious, the gate
reports success (the validator passed) while the wrong order reaches the
backend. This requires a concurrent writer — not the primary threat model, but a
failure mode where "validator passed" and "the order that reached the backend
was validated" are not the same thing.

### Validator exits 0 but writes to stderr

If the validator were modified to exit 0 while writing a warning, the launcher
would discard the stderr (it only inspects stderr when rc != 0). This is correct
per the contract (exit 0 = admissible), but it means a tampered validator emits
no signal the launcher reads.

### validate_order catches SystemExit(None)

If `sys.exit()` is called without an argument, `exc.code` is `None`.
`isinstance(None, int)` is `False`, so validate_order returns `1`. This is
fail-closed. The stderr would contain whatever the validator wrote plus the
launcher's "ORDER REFUSED" prefix. **Not a success-looking failure — it
correctly refuses.**

---

## 11. Anything else materially wrong or dangerous

### 11.1 The re-read without re-validation (TOCTOU)

Already noted under conditions and question 5. The launcher at line 203 does
`open(order_path)` followed by `json.load(f)` — a plain parse, no schema check,
no provenance check, no size check. Everything the validator verified about
order A is assumed to hold for whatever bytes are now at `order_path`. The
operator's own ADR §5 says *"Bytegrößen-Prüfung vor jedem Lesen"* — and the
launcher's second read has none.

The fix is not to re-run the full validator (expensive). It is to pass the
already-parsed order out of `validate_order` instead of re-reading the file.
`validate_order` currently returns `(rc, stderr)` — returning `(rc, stderr,
parsed_order)` would eliminate the window at zero cost, because the validator
already holds the parsed dict in memory before it exits.

**This is worth tracking but does not block approval.** The TOCTOU requires a
concurrent attacker on the same filesystem; the gate without any caller was the
larger defect by far.

### 11.2 ImportError in validate_order is uncaught

If `orders.validate` cannot be imported, the launcher crashes with a traceback.
Noted under question 3. Same class as condition 4.

### 11.3 `core/orders/__init__.py` exists

It contains only a docstring: `"""Execution Core S2 — Order validation."""`.
This is benign. If it ever gains executable code, it runs whenever
`orders.validate` is imported — which is every time the launcher validates an
order. This is not a current defect but a supply-chain surface to watch.

---

## Verdict

All four blocking conditions from round 1 are satisfied in letter and in
substance. The operator's non-blocking rejections are legitimate — each one is
either a deliberate design decision recorded in CONTRACT.md or a correct
scoping of S2 vs S3. The two deferrals (E_SIZE for unreadable input, CI
inability to complete admitted runs) are honest, stated, and tracked rather than
paper over.

The gate is on the path. The backend is unreachable through the launcher without
a passing validation. Two residual concerns — the TOCTOU between validation and
re-read, and the uncaught ImportError in validate_order — are narrower than the
defects this round fixed and do not warrant a second rejection.

verdict: APPROVE
