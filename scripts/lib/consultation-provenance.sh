#!/usr/bin/env bash
# consultation-provenance.sh — a consultation may not claim a provider it
# cannot prove served it.
#
#   check_consultation_provenance [dir]
#
# Exit 0 when every consultation naming a provider either carries a provenance
# block written by scripts/consult.sh, or is listed in the UNVERIFIED register
# with a reason. Exit 1 otherwise.
#
# ── Why ────────────────────────────────────────────────────────────────────
#
# On 2026-07-31 three files under governance/consultations/ named a provider in
# their filename and were produced by a different one. `jcode run -p openai`
# returned a plausible report with exit 0 while the log recorded the request
# being served by DeepSeek — the same provider as the builder whose code was
# under review. The flags are discarded whenever the configured default
# provider uses an API key.
#
# Nothing here noticed. The artifacts were named, committed, cited in a merge
# decision, and read as independent judgments. It surfaced because a human saw
# that a subscription quota was untouched.
#
# The file that already carried the rule is governance/reviewers.md:
#
#     "A tool with silent provider failover cannot be the control that
#      guarantees provider independence. Its success proves nothing about who
#      answered."
#
# It was followed for the provider called by direct API and not for the one
# called through the tool that has the failover. **A rule that has to be
# remembered is not a control**, which is the entire reason this is a gate.
#
# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

check_consultation_provenance() {
  local dir="${1:-governance/consultations}"
  local register="$dir/UNVERIFIED"
  local rc=0 checked=0 verified=0 registered=0
  local f base claimed served

  if [[ ! -d "$dir" ]]; then
    echo "FAIL — consultation directory not found: $dir" >&2
    return 1
  fi

  # EVERY .md is checked, not only those whose filename happens to contain a
  # provider token.
  #
  # The first version inferred the claim from the filename against a token
  # list, and a red-team walked straight past it: name the file
  # `137-independent-review.md` and the gate never looks at it. A gate that can
  # be evaded by choosing a filename is a naming convention.
  #
  # The filename is still used, but only to say WHICH provider is claimed when
  # a provenance block is present. A file with no block and no register entry
  # now fails whatever it is called.
  local providers="sol kimi fable claude openai deepseek moonshot anthropic"

  for f in "$dir"/*.md; do
    [[ -e "$f" ]] || continue
    base="$(basename "$f")"

    claimed=""
    local p
    for p in $providers; do
      case "$base" in *"$p"*) claimed="$p"; break ;; esac
    done

    checked=$((checked + 1))

    # Path 1: the artifact proves itself.
    if grep -q '^<!-- provenance' "$f" 2>/dev/null; then
      served="$(grep -m1 '^served_provider:' "$f" 2>/dev/null | sed 's/^served_provider: *//')"
      if [[ -z "$served" ]]; then
        echo "FAIL — $base has a provenance block with no served_provider" >&2
        rc=1
        continue
      fi
      # A self-test block records that NO provider was contacted. It exists so
      # the test path cannot masquerade as evidence, and it must not be
      # accepted as evidence here either.
      if grep -q '^verified_by:.*SELFTEST' "$f" 2>/dev/null; then
        echo "FAIL — $base carries a SELFTEST provenance block: no provider was" >&2
        echo "       contacted, so it establishes nothing." >&2
        rc=1
        continue
      fi
      # sol is a model of openai; the register maps names to providers.
      local want="$claimed"
      [[ "$want" == "sol" ]] && want="openai"
      [[ "$want" == "fable" ]] && want="claude"
      [[ "$want" == "anthropic" ]] && want="claude"
      [[ "$want" == "kimi" ]] && want="moonshot"
      if [[ -z "$claimed" ]]; then
        # A block, but the filename claims nothing to contradict. The evidence
        # is present and self-consistent; that is all this gate can say.
        verified=$((verified + 1))
        continue
      fi
      if [[ "$served" != "$want" ]]; then
        echo "FAIL — $base claims '$claimed' but its provenance says served by '$served'" >&2
        rc=1
        continue
      fi
      verified=$((verified + 1))
      continue
    fi

    # Path 2: explicitly registered as unproven. Not a loophole — the register
    # is committed, greppable, and every line has to say why. An artifact whose
    # attribution is unknown is allowed to exist and is not allowed to look
    # verified.
    # Anchored, and comments stripped first.
    #
    # This was `grep -qF "$base" "$register"`, and a red-team turned a COMMENT
    # naming a file into an allowlist entry for it. The register is meant to be
    # a list of claims the repository has stopped making; a prose mention of a
    # filename is not such a claim.
    if [[ -f "$register" ]] && \
       grep -v '^[[:space:]]*#' "$register" | grep -qx "$base"; then
      registered=$((registered + 1))
      continue
    fi

    echo "FAIL — $base has no provenance block and" >&2
    echo "       no entry in $register." >&2
    echo "       Produce it with scripts/consult.sh, which verifies from the" >&2
    echo "       tool's own log and deletes its output when attribution fails." >&2
    rc=1
  done

  if [[ "$rc" -eq 0 ]]; then
    echo "OK — $checked consultation(s) name a provider: $verified proven, $registered registered as unproven"
  fi
  return "$rc"
}
