<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Review — PR #142, the fixes for four findings in merged code

**Routed to Kimi because Sol refused it.** Two attempts through gpt-5.6-sol
were terminated by the provider on a cybersecurity content policy (#140);
both had asked the reviewer to CONSTRUCT a bypass. Kimi has completed every
such request tonight.

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 6065, completion 8609 |
| Mode | **diff mode — the reviewer executed nothing**, and labelled it |

---
# Red-team review — PR #142 (federation-recon)

**Mode: diff mode, no checkout. Nothing was executed.** Every dynamic claim below is a static prediction; each carries the run that would refute it.

## 1. Do the fixes close the four findings?

Statically, yes, for the exact vectors named:

1. `deep<U+200B>seek` — U+200B is in `_INVISIBLE`; fold → `deepseek` → refused.
2. 5000-digit `issue` — `[0-9]{4300,}` fires pre-parse → `E_JSON`, no traceback.
3. Arabic-Indic `created_at` — `DATETIME_RE` uses `[0-9]`; I read every pattern in the file: **no `\d` remains** in any regex. This fix is complete.
4. `location == BUNDLE_PREFIX` (with or without trailing slashes) — caught by the `rstrip('/')` equality.

Reproduction on `main` (Q1c, first half): NOT EXECUTED — no checkout in this mode. All four are consistent with known CPython/re behavior and with 127's record, but I did not re-run them. Refutation: run the four vectors against `main` and get any refusal.

## 2. Breaking the fixes

**2a. `_fold_identity` does not remove the class it claims to.** The list has 13 codepoints; Unicode has ~160 Cf. These survive NFKC and the strip, all zero-width/format:

- `author = "deep\u061Cseek"` (ARABIC LETTER MARK, Cf)
- `author = "deep\uFFF9seek"` (Cf), `"deep\uE0065seek"` (tag chars, Cf), `"deep\u180Eseek"` (Cf since Unicode 6.3), `"deep\u034Fseek"` (CGJ, invisible Mn)

All predicted exit 0, ADMITTED. Refutation: any of them refused. Worse, NFKC itself opens one: `"deep\u2004seek"` → NFKC maps U+2004 to plain space → `"deep seek"` — substring gone, ADMITTED. And NFKC does nothing for confusables: `"d\u0435\u0435ps\u0435\u0435k"` (Cyrillic е) is visually `deepseek`, fold-stable, ADMITTED. Fix: strip by category (`unicodedata.category(ch) in ('Cf','Mn','Me')`), and the comment should admit insertion/homoglyph bypasses, not just "theatre".

**2b. Huge-integer guard.** The regex assumes the default limit. CPython honors `PYTHONINTMAXSTRDIGITS` (min 640) and `sys.set_int_max_str_digits`. With `PYTHONINTMAXSTRDIGITS=640`, `issue` = a 1000-digit integer: regex passes (< 4300), `parse_int` raises `ValueError` inside `raw_decode`, which catches only `JSONDecodeError` → "Traceback" on stderr line 1. The pinned contract breach survives, one env var away. Refutation: that run exits 1 with `E_JSON`. Fix: compute the threshold from `sys.get_int_max_str_digits()` **and** wrap `raw_decode` in `except ValueError → E_JSON`. Minor: the regex also refuses 4300+ digit runs *inside strings* (over-refusal, misclassified) — acceptable but undocumented.

**2c. `\d` audit.** Clean. (The `\d` in the comment is prose.) Note `DATETIME_RE` still admits `2025-99-99T99:99:99Z` — format-only per contract; flag as accepted risk, not a regression.

**2d. Location.** `BUNDLE_PREFIX + "."` and `BUNDLE_PREFIX + "./"` pass all three checks (prefix ✓, not equal after rstrip ✓, no `..` segment ✓) and resolve to the bundles directory itself. Predicted exit 0; refutation: refusal. Fix: `os.path.normpath(location) != BUNDLE_PREFIX.rstrip('/')` and reject `.`-only segments. And the honest answer to "can a location still name nothing while passing": **always** — existence is never checked (can't be, in a pure validator). If the contract implies otherwise, it overstates.

## Q3 — untested checks

NOT EXECUTED: the bats files were not in my diff. Method: mutate each new check in isolation (revert the fold call, the regex guard, `[0-9]`→`\d`, the directory equality), run `bats scripts/test/order-validator.bats scripts/test/order-vectors.bats`, suite must go red each time. Any green = untested. My vectors from §2 must be added as regression tests regardless — if the suite currently passes with them, the fixes are untested against their own bypass class.

## Q8 — what is missing

- Category-based invisible strip (C1); contract admission that textual identity remains advisory pending signed attestation (#141).
- Runtime int-limit read + `ValueError` catch (C2).
- `.`-segment rejection / normpath comparison (C3); contract must state existence is never verified.
- One bats vector per fix plus my bypass vectors; mutation-red confirmation (C4).
- `policy.json` has no integrity binding at all (see Q7); provisional `E_SIZE`-for-missing-file remains open as #126 — documented, fine.

## Q7 — contract wording

NOT REVIEWABLE: the CONTRACT.md change was not included in my diff. But the dependency is larger than "limit reductions": `claimed_capabilities` admission *also* rests entirely on the same unguarded, operator-writable file, read via a `__file__`-relative path (a relocated validator copy reads a different policy). If the corrected sentence only scopes the caveat to `limit_reductions`, it still overstates. Condition (C5): the sentence must say the validator's verdicts are exactly as strong as an unguarded `core/policy.json`, for limits **and** capabilities.

## Conditions

C1–C5 above, plus regression vectors. Any unmet → not approvable.

verdict: REJECT
