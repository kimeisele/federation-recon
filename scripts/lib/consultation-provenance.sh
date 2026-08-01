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
#   The quarantine sentinel anywhere in the file, where it appears the way a
#   quarantine writes it: at the start of a line. A review that QUOTES the
#   sentinel while describing this attack is not a quarantine, and the
#   committed one must keep passing. A SELFTEST marker, which records that
#   no provider was contacted; more than one provenance opener.

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

# _cp_unreadable_dirs <dir> — directories the enumeration cannot see into.
#
# `find` still lists a directory it may not read — the entry is visible from
# its parent — but it cannot descend into it, so with stderr discarded it
# prints nothing for whatever is inside and reports nothing at all. A file
# hidden that way is invisible, and invisible is the one thing this gate
# exists to prevent. Every directory the enumeration cannot look through is
# named, and a single one is a failure: the inventory is incomplete, full
# stop.
_cp_unreadable_dirs() {
  local dir="$1" d
  while IFS= read -r -d '' d; do
    if [[ ! -r "$d" || ! -x "$d" ]]; then
      printf '%s\0' "$d"
    fi
  done < <(find "$dir" -type d -print0 2>/dev/null)
}

# _cp_dir_symlinks <dir> — symlinks that are directories, outside *.md names.
#
# The file loop refuses symlinks whose names match the consultation globs; a
# symlinked DIRECTORY under any other name never reaches that loop, so it is
# refused here. A consultation must be the bytes at the consultation path,
# and a path that reaches content through a link is not that.
_cp_dir_symlinks() {
  local dir="$1" d
  while IFS= read -r -d '' d; do
    if [[ -L "$d" && -d "$d" ]]; then
      printf '%s\0' "$d"
    fi
  done < <(find "$dir" -type l ! -iname '*.md' ! -iname '*.markdown' -print0 2>/dev/null)
}

# _cp_register_reason <register> <name> — true when the entry, or the run of
# entries it belongs to, is followed by prose of at least 40 characters.
_cp_register_reason() {
  local register="$1" name="$2"
  awk -v want="$name" '
    /^[[:space:]]*#/ { next }
    {
      if ($0 == want) { seen = 1; run = 1; next }
      if (seen) {
        if ($0 ~ /\.(md|markdown)$/) { next }        # a shared reason follows the run
        if ($0 ~ /^[[:space:]]*$/) { if (got) exit; next }
        prose = prose $0 " "
        got = 1
      }
    }
    END { exit (length(prose) >= 40) ? 0 : 1 }
  ' "$register"
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

  # The enumeration must be complete before its emptiness or its success can
  # be believed. find cannot see into a directory it may not read, and a
  # symlink to a directory is refused, not traversed. Either makes the
  # inventory incomplete, and an incomplete inventory reporting success is
  # the defect this file exists to catch.
  local d
  while IFS= read -r -d '' d; do
    echo "FAIL — cannot read directory ${d#"$dir"/}. Whatever it holds is" >&2
    echo "       invisible to the enumeration, and invisible is not a pass." >&2
    rc=1
  done < <(_cp_unreadable_dirs "$dir")
  while IFS= read -r -d '' d; do
    echo "FAIL — ${d#"$dir"/} is a symlink to a directory. A consultation" >&2
    echo "       must be the bytes at the consultation path; following a" >&2
    echo "       link certifies content stored elsewhere." >&2
    rc=1
  done < <(_cp_dir_symlinks "$dir")

  # The inventory must be a STABLE SNAPSHOT, not one streaming `find`.
  #
  # Round 3 executed it and round 4 kept it blocking: 1,200 files were checked
  # while `late.md` was created mid-scan, and the gate exited 0 having never
  # looked at it. A single `find` is a snapshot of a moment that ends before
  # the loop does; a file that arrives while the gate runs is omitted from a
  # green run — the defect this gate exists for. So the enumeration is taken
  # twice and the sets compared: if the tree changed while it was being
  # checked, the gate refuses rather than reporting success about a set it did
  # not finish observing. Nothing is locked; the second observation is the
  # check. (Only the first snapshot is processed, so the second `find` runs
  # after every file has been examined — a change that lands anywhere during
  # the loop shows up in the comparison.)
  local inventory inventory2
  inventory="$(mktemp "${TMPDIR:-/tmp}/cp-inventory.XXXXXX")" || return 1
  inventory2="$(mktemp "${TMPDIR:-/tmp}/cp-inventory2.XXXXXX")" || return 1
  _cp_inventory "$dir" | sort -z > "$inventory"

  while IFS= read -r -d '' f; do
    base="${f#"$dir"/}"
    checked=$((checked + 1))

    # ── a path with a newline in it is refused, not split ────────────────
    #
    # find -print0 and `read -d ''` carry the name whole, but every reader
    # downstream of this loop is line-based: the register is one name per
    # line, and a multi-line name handed to grep arrives split into separate
    # patterns — a register entry for the first half of the name admits the
    # file. A path that splits mid-name either escapes the check or produces
    # a nonsense one, and both are worse than an error, so this is an error.
    if [[ "$base" == *$'\n'* ]]; then
      echo "FAIL — $base: the filename contains a newline. It cannot be" >&2
      echo "       enumerated, registered or named as one path, so it is" >&2
      echo "       refused rather than split." >&2
      rc=1
      continue
    fi

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
    # Policy: the sentinel anywhere in the file. The check used to look at the
    # first three lines, and Round 3 put the sentinel on line five, past it.
    # The sentinel is now refused anywhere in the file in the form a quarantine
    # writes it: as the start of a line. Prose that QUOTES the sentinel while
    # describing this very attack is not a header — the committed review in
    # governance/consultations/137-sol-round2.md quotes it mid-sentence and
    # must keep passing — so the match is anchored to the start of a line,
    # not to any substring.
    if awk -v s="$_CP_QUARANTINE_SENTINEL" '
        { line = $0; sub(/^[[:space:]]+/, "", line); if (index(line, s) == 1) found = 1 }
        END { exit !found }
      ' "$f" 2>/dev/null; then
      echo "FAIL — $base carries the quarantine sentinel. It is a body whose" >&2
      echo "       provider could not be determined; renaming it does not" >&2
      echo "       change that." >&2
      rc=1
      continue
    fi

    # Read the file once, into a variable. `tr … | grep -q` reports 141 under
    # `set -o pipefail` because grep exits at its first match and tr takes
    # SIGPIPE — the THIRD instance of that defect in one day, and this one made
    # the gate reject two reports whose closers were present on line 10.
    local text; text="$(tr -d '\r' < "$f")"
    openers="$(grep -c '^<!-- provenance' <<< "$text" || true)"
    if [[ "$openers" -gt 1 ]]; then
      echo "FAIL — $base has $openers provenance blocks. One record, or none." >&2
      rc=1
      continue
    fi

    if [[ "$openers" -eq 1 ]]; then
      # ── the record must OPEN the file ─────────────────────────────────
      if [[ "$(head -1 <<< "$text")" != '<!-- provenance' ]]; then
        echo "FAIL — $base has a provenance block that does not start the file." >&2
        echo "       A block further down was how a renamed quarantine passed." >&2
        rc=1
        continue
      fi

      # ── the record is the block, not the file ─────────────────────────
      #
      # Round 3 executed four ways past the previous parser: required fields
      # supplied by BODY lines after the block had closed; a block with no
      # closing `-->` at all; a duplicated field where `head -1` silently chose
      # the first; and CRLF line endings whose carriage returns survived into
      # the values. Each passed.
      #
      # The block is now extracted first — opener to closer, closer required —
      # and every field is read only from within it. Carriage returns are
      # stripped. A duplicated field is a malformed record rather than a
      # question of which copy wins.
      local block
      block="$(awk '/^<!-- provenance/{f=1;next} /^-->/{f=0;exit} f' <<< "$text")"
      if ! grep -q '^-->' <<< "$text"; then
        echo "FAIL — $base has a provenance block that is never closed. Without" >&2
        echo "       a closer, every line of the body is inside the record." >&2
        rc=1
        continue
      fi
      local dup
      dup="$(printf '%s\n' "$block" | sed -n 's/^\([a-z_]*\):.*/\1/p' | sort | uniq -d)"
      if [[ -n "$dup" ]]; then
        echo "FAIL — $base repeats provenance field(s): $(printf '%s' "$dup" | tr '\n' ' ')" >&2
        echo "       Which copy counts is not a question a record should raise." >&2
        rc=1
        continue
      fi
      served="$(printf '%s\n' "$block" | sed -n 's/^served_provider:[[:space:]]*//p')"
      claim="$(printf '%s\n' "$block" | sed -n 's/^reviewer_claim:[[:space:]]*//p')"
      model="$(printf '%s\n' "$block" | sed -n 's/^model:[[:space:]]*//p')"

      if grep -q '^\(consistency_check\|verified_by\):.*SELFTEST' <<< "$block"; then
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
    # The match is whole-line and literal: awk compares $0 == want, with no
    # regex anywhere. It was `grep -qx` — the filename as a basic regular
    # expression, so a register line `attackXmd` admitted `attack.md` — and
    # then `grep -Fqx` in a pipeline, which is grep -q under pipefail. The
    # lookup is also where a multi-line name would split into alternatives,
    # which is why names containing a newline are refused before this point.
    # An entry must carry a reason. Round 3 registered an unproven file with no
    # reason at all and the gate admitted it — the register is a list of claims
    # the repository has stopped making, and a bare filename makes no claim
    # about anything. The grammar is checked here rather than only in a test
    # over today's register, because a test over today's data is not a rule.
    if [[ -f "$register" ]] && \
       awk -v want="$base" '
         /^[[:space:]]*#/ { next }
         $0 == want { found = 1; exit }
         END { exit !found }
       ' "$register"; then
      if ! _cp_register_reason "$register" "$base"; then
        echo "FAIL — $base is listed in $register with no reason." >&2
        echo "       An entry without one is an allowlist, which is what the" >&2
        echo "       register exists not to be." >&2
        rc=1
        continue
      fi
      registered=$((registered + 1))
      continue
    fi

    echo "FAIL — $base has no provenance record and no entry in $register." >&2
    echo "       Produce it with scripts/consult.sh, or register it with a" >&2
    echo "       reason if its attribution is not establishable." >&2
    rc=1
  done < "$inventory"

  # ── the second observation ────────────────────────────────────────────────
  #
  # The loop above examined the first snapshot. A file created while it ran
  # was never in that snapshot, so every check passed and the gate would have
  # reported success about a set it did not finish observing. Enumerate again
  # and compare: any difference means the tree changed mid-scan, and the
  # answer is a refusal, not a summary.
  _cp_inventory "$dir" | sort -z > "$inventory2"
  if ! cmp -s "$inventory" "$inventory2"; then
    echo "FAIL — the consultation inventory changed while it was being checked." >&2
    echo "       A file was added, removed or renamed mid-scan; the gate will" >&2
    echo "       not report success about a set it did not finish observing." >&2
    rc=1
  fi
  rm -f "$inventory" "$inventory2"

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
