#!/usr/bin/env bash
# consult.sh — dispatch a consultation and refuse to return one that cannot be
# attributed to the provider that was asked for.
#
# ── Why this exists ────────────────────────────────────────────────────────
#
# On 2026-07-31 three consultations were filed as independent cross-provider
# reviews. Zero of them were. `jcode run -p openai -m gpt-5.6-sol` returned a
# plausible report, exit 0, while the log showed
#
#     auth: DEEPSEEK_API_KEY
#     endpoint: https://api.deepseek.com
#     prv:OpenRouter|mod:deepseek
#
# The flags are silently discarded whenever [provider] default_provider in
# ~/.jcode/config.toml names an API-key provider; resolution slides to
# OpenRouter and the request is served by the DEFAULT model — which in this
# repository is the builder. So the reviewer of the code was the same provider
# as the writer of the code, and the artifact said otherwise.
#
# That is fail-open, and it is the worst shape a control can have: nothing
# looks broken. It was caught by a human noticing an untouched quota, not by
# any check here. governance/reviewers.md already carried the rule —
#
#     "A tool with silent provider failover cannot be the control that
#      guarantees provider independence. Its success proves nothing about who
#      answered."
#
# — and the rule was applied to the provider called by direct API and not to
# the one called through the tool with the failover. A rule that depends on
# remembering to apply it is not a control.
#
# ── What this does instead ────────────────────────────────────────────────
#
# The dispatch is bracketed by a timestamp. Afterwards the tool's own log is
# read for that window and the provider that ACTUALLY served is extracted. If
# it is not the one requested, or if it cannot be determined, or if more than
# one appears, the output file is DELETED and this exits non-zero.
#
# There is no flag to skip the check and no path that returns an unverified
# artifact. An unattributable consultation is worth less than none, because it
# occupies the place where a real one would have gone.
#
# Usage:
#   scripts/consult.sh <provider> <model> <output.md> <prompt-file> [workdir]
#
# Environment:
#   CONSULT_LOG       — override the log path (tests drive fixtures with it)
#   CONSULT_SKIP_RUN  — do not dispatch; only verify. For tests.

set -uo pipefail

PROVIDER="${1:-}"; MODEL="${2:-}"; OUTPUT="${3:-}"; PROMPT="${4:-}"; WORKDIR="${5:-}"
if [ -z "$PROVIDER" ] || [ -z "$MODEL" ] || [ -z "$OUTPUT" ] || [ -z "$PROMPT" ]; then
  echo "Usage: $0 <provider> <model> <output.md> <prompt-file>" >&2
  exit 2
fi
if [ ! -f "$PROMPT" ] && [ -z "${CONSULT_SKIP_RUN:-}" ]; then
  echo "consult: prompt file not found: $PROMPT" >&2
  exit 2
fi

LOG="${CONSULT_LOG:-$HOME/.jcode/logs/jcode-$(date '+%Y-%m-%d').log}"

# ── Which provider actually served, between MARK and now ──────────────────
#
# Two independent signals, because one of them is absent for OAuth providers:
# the endpoint a stream was opened to, and the provider tag on the session.
# Both are written by the tool about itself; neither is written by the model.
served_provider() {
  local log="$1" mark="$2" seen=""
  [ -r "$log" ] || { echo "unreadable-log"; return; }

  local window
  window="$(awk -v m="[$mark" '$0 >= m {print}' "$log" 2>/dev/null)"
  [ -n "$window" ] || { echo "no-log-activity"; return; }

  printf '%s\n' "$window" | grep -q "endpoint: https://api\.openai\.com"   && seen="$seen openai"
  printf '%s\n' "$window" | grep -q "endpoint: https://api\.deepseek\.com" && seen="$seen deepseek"
  printf '%s\n' "$window" | grep -q "endpoint: https://api\.anthropic\.com" && seen="$seen claude"
  printf '%s\n' "$window" | grep -q "endpoint: https://api\.moonshot\.ai"  && seen="$seen moonshot"
  # Provider tags catch the OAuth paths, which open no logged endpoint.
  printf '%s\n' "$window" | grep -qi "prv:OpenAI|"    && seen="$seen openai"
  printf '%s\n' "$window" | grep -qi "prv:Anthropic|" && seen="$seen claude"
  printf '%s\n' "$window" | grep -qi "mod:deepseek"   && seen="$seen deepseek"

  # Deduplicate, then insist on exactly one.
  seen="$(printf '%s\n' $seen | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  case "$(printf '%s\n' $seen | grep -c .)" in
    0) echo "undetermined" ;;
    1) echo "$seen" ;;
    *) echo "ambiguous:$(printf '%s' "$seen" | tr ' ' ',')" ;;
  esac
}

MARK="$(date '+%Y-%m-%d %H:%M:%S')"

if [ -z "${CONSULT_SKIP_RUN:-}" ]; then
  # shellcheck disable=SC2086
  if [ -n "$WORKDIR" ]; then
    jcode run -p "$PROVIDER" -m "$MODEL" -C "$WORKDIR" --no-update --quiet "$(cat "$PROMPT")" \
      > "${OUTPUT}.stdout" 2>&1
  else
    jcode run -p "$PROVIDER" -m "$MODEL" --no-update --quiet "$(cat "$PROMPT")" \
      > "${OUTPUT}.stdout" 2>&1
  fi
  rc=$?
else
  rc=0
fi

SERVED="$(served_provider "$LOG" "$MARK")"

if [ "$SERVED" != "$PROVIDER" ]; then
  echo "CONSULT REFUSED — the answer cannot be attributed to the provider asked for." >&2
  echo "  requested: $PROVIDER ($MODEL)" >&2
  echo "  served:    $SERVED" >&2
  echo "  log:       $LOG" >&2
  echo "  window:    from $MARK" >&2
  echo >&2
  case "$SERVED" in
    ambiguous:*)
      echo "  More than one provider appears in the window. A consultation that" >&2
      echo "  cannot be pinned to one model is not a second opinion." >&2 ;;
    undetermined|no-log-activity)
      echo "  Nothing identifiable was logged. Exit 0 from the tool proves that" >&2
      echo "  something answered, never which. See governance/reviewers.md." >&2 ;;
    unreadable-log)
      echo "  The log could not be read, so attribution is unavailable." >&2 ;;
    *)
      echo "  This is the 2026-07-31 failure: the flags were discarded and the" >&2
      echo "  DEFAULT provider served. Check [provider] default_provider in" >&2
      echo "  ~/.jcode/config.toml — it must name an OAuth provider, or -p and" >&2
      echo "  -m are silently ignored." >&2 ;;
  esac
  rm -f "$OUTPUT" "${OUTPUT}.stdout"
  echo >&2
  echo "  Output deleted. An unattributable consultation is worth less than" >&2
  echo "  none: it occupies the place a real one would have gone." >&2
  exit 1
fi

# Verified. The artifact carries its own evidence from here on.
{
  echo "<!-- provenance"
  echo "requested_provider: $PROVIDER"
  echo "served_provider: $SERVED"
  echo "model: $MODEL"
  echo "verified_by: scripts/consult.sh"
  echo "log: $LOG"
  echo "window_start: $MARK"
  echo "-->"
  echo
  [ -f "${OUTPUT}.stdout" ] && cat "${OUTPUT}.stdout"
} > "${OUTPUT}.tmp"
mv "${OUTPUT}.tmp" "$OUTPUT"
rm -f "${OUTPUT}.stdout"

echo "consult: $PROVIDER/$MODEL verified from the log — $OUTPUT"
exit $rc
