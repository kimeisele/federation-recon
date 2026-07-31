#!/usr/bin/env bash
# consultation-provenance.sh — a consultation may not claim a provider it
# cannot show served it.
#
#   check_consultation_provenance [dir]
#
# Exit 0 when every consultation file either carries a well-formed provenance
# record, or appears in the UNVERIFIED register with a reason. Exit 1 otherwise.
#
# ── What this establishes, stated before anything else ────────────────────
#
# **This is a consistency alarm, not a proof of independence.** The evidence it
# checks comes from jcode's own log, and jcode is the component whose
# provider-selection behaviour is under audit. An independent red-team put it
# plainly:
#
#     "jcode cannot be both the subject and sole witness."
#
# What it catches: a tool that silently serves a different model and exits 0 —
# which happened on 2026-07-31, across three consultations, unnoticed for four
# days. What it does not catch: a jcode that logs the wrong thing, or a person
# writing the record by hand. Both limits are real and neither is closed here.
#
# ── History, because the shape of the failures is the argument ────────────
#
# Round 1 of the review that produced this file walked past the gate by
# choosing a filename outside a token list, turned a comment in the register
# into an allowlist entry, and forged an artifact through the test path.
#
# Round 2 then executed, each in about a second: a nested file, a hidden file,
# an uppercase extension and a dangling symlink all skipped while the gate
# reported success; a register entry `attackXmd` admitting `attack.md` because
# the filename was used as a regex; a renamed quarantine with a provenance
# block later in its body accepted as proven; and a neutral filename whose body
# claimed one reviewer while its record named another, accepted as proven.
#
# Every one of those passed with the full suite green. That is why the rules
# below are an explicit policy rather than whatever a shell glob happens to
# match.
#
# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

# ── Policy ────────────────────────────────────────────────────────────────
#
# WHICH FILES ARE CONSULTATIONS
#   Every regular file under the directory, at any depth, whose name ends in
#   .md or .markdown in any case. Hidden files included. Symlinks are REFUSED
#   rather than followed or skipped: a consultation must be the bytes at the
#   consultation path, and the previous accidental split — live symlinks
#   followed, dangling ones silently skipped — was not a policy.
#
# WHAT COUNTS AS A RECORD
#   Exactly one provenance block, beginning on the FIRST line. A block found
#   anywhere in the body was how a renamed quarantine passed.
#
# REQUIRED FIELDS
#   served_provider, reviewer_claim, model. `reviewer_claim` must equal
#   `served_provider`: the authoritative claim lives in the record, not in the
#   filename and not in free text, because a body may mention any number of
#   models.
#
# REFUSED OUTRIGHT
#   The quarantine sentinel anywhere in the file; a SELFTEST marker, which
#   records that no provider was contacted; more than one provenance opener.

_CP_QUARANTINE_SENTINEL="UNATTRIBUTED CONSULTATION OUTPUT"

# _cp_inventory <dir> — every candidate path, NUL-separated.
#
# `find`, not a glob. The glob matched one non-recursive, case-sensitive,
# dot-excluding snapshot, and four of those five words were an executed
# evasion.
_cp_inventory() {
  local dir="$1"
  find "$dir" \( -iname '*.md' -o -iname '*.markdown' \) -print0 2>/dev/null
}

check_consultation_provenance() {
  local dir="${1:-governance/consultations}"
  local register="$dir/UNVERIFIED"
  local rc=0 checked=0 proven=0 registered=0
  local f base served claim model openers

  if [[ ! -d "$dir" ]]; then
    echo "FAIL — consultation directory not found: $dir" >&2
    return 1
  fi

  while IFS= read -r -d '' f; do
    base="${f#"$dir"/}"
    checked=$((checked + 1))

    # ── symlinks are refused, not followed and not skipped ───────────────
    if [[ -L "$f" ]]; then
      echo "FAIL — $base is a symlink. A consultation must be the bytes at the" >&2
      echo "       consultation path; following one certifies content stored" >&2
      echo "       elsewhere, and skipping a dangling one hides it." >&2
      rc=1
      continue
    fi
    if [[ ! -f "$f" ]]; then
      echo "FAIL — $base is not a regular file" >&2
      rc=1
      continue
    fi

    # ── a quarantined body must never be admitted by renaming it ─────────
    #
    # Anchored to the first lines, where the quarantine writer puts its header.
    # Searching the whole file rejected a review that QUOTED the sentinel while
    # describing this very attack — the same shape as a test satisfied by a
    # comment explaining the mechanism, met three times in one day.
    if head -3 "$f" 2>/dev/null | grep -qF "$_CP_QUARANTINE_SENTINEL"; then
      echo "FAIL — $base carries the quarantine sentinel. It is a body whose" >&2
      echo "       provider could not be determined; renaming it does not" >&2
      echo "       change that." >&2
      rc=1
      continue
    fi

    openers="$(grep -c '^<!-- provenance' "$f" 2>/dev/null || true)"
    if [[ "$openers" -gt 1 ]]; then
      echo "FAIL — $base has $openers provenance blocks. One record, or none." >&2
      rc=1
      continue
    fi

    if [[ "$openers" -eq 1 ]]; then
      # ── the record must OPEN the file ─────────────────────────────────
      if [[ "$(head -1 "$f")" != '<!-- provenance' ]]; then
        echo "FAIL — $base has a provenance block that does not start the file." >&2
        echo "       A block further down was how a renamed quarantine passed." >&2
        rc=1
        continue
      fi

      served="$(sed -n 's/^served_provider:[[:space:]]*//p' "$f" | head -1)"
      claim="$(sed -n 's/^reviewer_claim:[[:space:]]*//p' "$f" | head -1)"
      model="$(sed -n 's/^model:[[:space:]]*//p' "$f" | head -1)"

      if grep -q '^\(consistency_check\|verified_by\):.*SELFTEST' "$f" 2>/dev/null; then
        echo "FAIL — $base carries a SELFTEST record: no provider was contacted," >&2
        echo "       so it establishes nothing." >&2
        rc=1
        continue
      fi
      if [[ -z "$served" || -z "$claim" || -z "$model" ]]; then
        echo "FAIL — $base has an incomplete provenance record" >&2
        echo "       (served_provider=${served:-missing}" \
             "reviewer_claim=${claim:-missing} model=${model:-missing})" >&2
        rc=1
        continue
      fi
      if [[ "$claim" != "$served" ]]; then
        echo "FAIL — $base claims reviewer '$claim' and records served" >&2
        echo "       '$served'. The record must not contradict itself." >&2
        rc=1
        continue
      fi
      proven=$((proven + 1))
      continue
    fi

    # ── no record: the register may admit it, literally ──────────────────
    #
    # `grep -Fqx --`. It was `grep -qx`, which treats the filename as a basic
    # regular expression, so a register line `attackXmd` admitted `attack.md`.
    if [[ -f "$register" ]] && \
       grep -v '^[[:space:]]*#' "$register" | grep -Fqx -- "$base"; then
      registered=$((registered + 1))
      continue
    fi

    echo "FAIL — $base has no provenance record and no entry in $register." >&2
    echo "       Produce it with scripts/consult.sh, or register it with a" >&2
    echo "       reason if its attribution is not establishable." >&2
    rc=1
  done < <(_cp_inventory "$dir")

  if [[ "$checked" -eq 0 ]]; then
    echo "FAIL — no consultation files found under $dir. An empty inventory is" >&2
    echo "       not a pass: it is the answer a broken enumeration also gives." >&2
    return 1
  fi

  if [[ "$rc" -eq 0 ]]; then
    echo "OK — $checked consultation(s): $proven with a provenance record," \
         "$registered registered as unproven"
  fi
  return "$rc"
}
