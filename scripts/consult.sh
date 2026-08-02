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
# MORE THAN ONE ROUND: the output of the latest round goes to
# governance/consultations/<pr>.md and every earlier round moves to
# <pr>-round<N>.md, whole. The primary links them all. A superseded round is
# never deleted and never shortened — enforced by check_consultation_rounds,
# and spelled out in governance/consultation-prompt.md.
#
# Environment:
#   CONSULT_LOG            — override the log path (tests drive fixtures)
#   CONSULT_SKIP_RUN       — do not dispatch; only verify. Tests only.
#   CONSULT_TEST_SESSION   — name a session without running one. Tests only.
#
# ── What this does NOT defend against, stated rather than implied ─────────
#
# A red-team forged an accepted artifact using the two variables above, and
# separately wrote a provenance block by hand. Both work, and neither is closed
# here, because **anyone who can run this script can also write the file it
# would have written.** This is not a control against a dishonest operator; it
# is a control against a tool that silently substitutes a different model and
# exits 0, which is what happened on 2026-07-31 and went unnoticed for four
# days.
#
# What is done about it: using the test path stamps the artifact SELFTEST, and
# check_consultation_provenance rejects a SELFTEST block. Stripping that marker
# is hand-editing, which returns to the case above. The evidence a block cites
# — session id, log path, window — is checkable by anyone against the log, so a
# forged block is a falsifiable claim rather than an unexaminable one. That is
# the honest ceiling of a design that reads the audited tool's own log.

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

if [ -L "$OUTPUT" ]; then
  echo "consult: refusing — the output path is a symlink: $OUTPUT" >&2
  echo "  The artifact must be the bytes at the path it is cited by; writing" >&2
  echo "  through a link certifies content stored somewhere else." >&2
  exit 2
fi
if [ -d "$OUTPUT" ]; then
  echo "consult: refusing — the output path is a directory: $OUTPUT" >&2
  echo "  `mv` would succeed by writing INSIDE it and every later check would" >&2
  echo "  pass while the requested artifact did not exist." >&2
  exit 2
fi
if [ -L "${OUTPUT}.tmp" ] || { [ -e "${OUTPUT}.tmp" ] && [ ! -f "${OUTPUT}.tmp" ]; }; then
  echo "consult: refusing — ${OUTPUT}.tmp is not a regular file." >&2
  echo "  A redirect follows a symlink and overwrites whatever it points at," >&2
  echo "  certifying content stored elsewhere. Nothing is written." >&2
  exit 2
fi

LOG="${CONSULT_LOG:-$HOME/.jcode/logs/jcode-$(date '+%Y-%m-%d').log}"

# ── Which provider actually served THIS request ───────────────────────────
#
# The first version filtered the log by TIME. An independent red-team broke it
# in the most direct way available: while being reviewed it ran its own
# provider sessions, the window then contained two providers, the control
# refused — correctly by its own rules — and deleted the twenty-five-kilobyte
# review that had just found the flaw. **A time window is a claim about the
# clock, not about the request.**
#
# jcode writes ~/.jcode/streaming_pids/<session-id> containing the PID serving
# that session, and stamps every log line with `ses:<id>`. So the session
# belonging to OUR jcode process can be identified by its pid, and the log read
# for that session alone. Another session running in the same second is now
# irrelevant rather than fatal.
#
# What this still does NOT establish, and the reviewer is right about it: that
# jcode's own log is truthful. This is the audited tool reporting on itself.
# Evidence from outside the tool would be a different design. The limit is
# stated here and in governance/reviewers.md rather than papered over.

# session_for_pid <pid> <not-before-epoch>
#
# Exactly one match, or nothing. A red-team accepted a WRONG session by
# planting a second pid file with the same contents: the loop returned the
# first it happened to see, which is whatever the directory order gave it.
#
# Also rejects a stale file — one written before this run started — because a
# recycled pid would otherwise bind us to somebody else's old session, and a
# pid is a small recycled integer.
session_for_pid() {
  local pid="$1" not_before="$2" f matches="" n=0 mtime
  for f in "$HOME"/.jcode/streaming_pids/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "$pid" ] || continue

    # Shape: session_<name>_<epoch-ms>_<hex>. Anything else is not a session id
    # and must not become one by being in the directory.
    case "$(basename "$f")" in
      session_*_*_*) ;;
      *) continue ;;
    esac

    mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$mtime" -ge "$not_before" ] || continue

    matches="$matches $(basename "$f")"
    n=$((n + 1))
  done
  if [ "$n" -ne 1 ]; then
    echo "AMBIGUOUS:$n"
    return 1
  fi
  printf '%s' "${matches# }"
  return 0
}

served_provider() {
  local log="$1" mark="$2" session="${3:-}" seen=""
  [ -r "$log" ] || { echo "unreadable-log"; return; }

  local window
  if [ -z "$session" ]; then
    echo "no-session-binding"
    return
  fi

  # The log truncates the session id, and the truncation length is NOT a thing
  # to assume. This used a hardcoded 24 and matched zero lines on every real
  # run, because the log writes 20 — two full reviews refused for an off-by-four
  # in a control whose entire subject is not assuming things. Both were
  # attributable; the script could not see it.
  #
  # So the length is measured: try the full id, then shorter prefixes, and take
  # the first that matches anything. A floor of 16 keeps the prefix long enough
  # to identify one session rather than a family of them. If nothing matches at
  # any length the run is unattributable and is refused — the same answer as
  # before, now for a reason that is true.
  local n
  for n in "${#session}" 28 24 20 16; do
    [ "$n" -le "${#session}" ] || continue
    window="$(grep -F "ses:${session:0:$n}" "$log" 2>/dev/null)"
    [ -n "$window" ] && break
  done
  [ -n "$window" ] || { echo "no-log-activity"; return; }

  # HERESTRINGS, not pipes. `... | grep -q` under `set -o pipefail` reports 141
  # when grep exits early on a large input, so the `&&` never fires. That
  # shipped, matched nothing on every real log, and every unit test passed
  # because the fixtures were one or two lines.
  grep -q  "endpoint: https://api\.openai\.com"    <<< "$window" && seen="$seen openai"
  grep -q  "endpoint: https://api\.deepseek\.com"  <<< "$window" && seen="$seen deepseek"
  grep -q  "endpoint: https://api\.anthropic\.com" <<< "$window" && seen="$seen claude"
  grep -q  "endpoint: https://api\.moonshot\.ai"   <<< "$window" && seen="$seen moonshot"
  grep -qi "prv:OpenAI|"    <<< "$window" && seen="$seen openai"
  grep -qi "prv:Anthropic|" <<< "$window" && seen="$seen claude"
  grep -qi "mod:deepseek"   <<< "$window" && seen="$seen deepseek"

  seen="$(printf '%s\n' $seen | sort -u | tr '\n' ' ' | sed 's/ *$//')"
  local n_seen; n_seen="$(printf '%s\n' $seen | grep -c . || true)"
  case "$n_seen" in
    0) echo "undetermined" ;;
    1) echo "$seen" ;;
    *) echo "ambiguous:$(printf '%s' "$seen" | tr ' ' ',')" ;;
  esac
}

# ── Quarantine, not deletion ──────────────────────────────────────────────
#
# The first version deleted the output on refusal, on the reasoning that "an
# unattributable consultation is worth less than none: it occupies the place a
# real one would have gone." The reasoning about CITATION is right. The
# conclusion about DESTRUCTION was wrong, and it cost a twenty-five-kilobyte
# red-team report whose findings had to be reconstructed from the fragment that
# had already been read.
#
# A refused body is not worthless. It is unattributable, which is a different
# thing. It goes to <output>.unattributed, outside the *.md the provenance gate
# and every reader look at, with a header saying what it is. It cannot be cited
# as a consultation and it is not thrown away.

quarantine_output() {
  [ -f "${OUTPUT}.stdout" ] || return 0
  local q="${OUTPUT}.unattributed"
  # A red-team planted a symlink at the quarantine path. `> "$q"` follows it,
  # writes the header and body wherever it points, the size check passes, and
  # then the ONLY copy of the body is deleted under "Body kept". Refuse before
  # the redirect: a quarantine must be the bytes at the quarantine path, and a
  # finding must not be deleted for a quarantine that was never written.
  if [ -L "$q" ] || { [ -e "$q" ] && [ ! -f "$q" ]; }; then
    echo "  QUARANTINE FAILED — $q is not a regular file; refusing to write through it" >&2
    echo "  The body is left at ${OUTPUT}.stdout rather than deleted." >&2
    return 1
  fi
  {
    echo "UNATTRIBUTED CONSULTATION OUTPUT — NOT A CONSULTATION"
    echo
    echo "Requested provider: $PROVIDER ($MODEL)"
    echo "Determined:         ${SERVED:-not reached}"
    echo "Session:            ${SESSION:-none}"
    echo "Log:                $LOG"
    echo "Window from:        $MARK"
    echo
    echo "This body was produced by SOMETHING. Which model, this run could not"
    echo "establish. It is kept because destroying a finding is a worse error"
    echo "than being unable to attribute it, and it carries this extension so"
    echo "that no gate, glob or reader mistakes it for a consultation."
    echo
    echo "----------------------------------------------------------------"
    echo
    cat "${OUTPUT}.stdout"
  } > "$q"
  # A red-team made <output>.unattributed a directory. The redirection failed,
  # the script deleted the only copy of the body anyway and printed "Body
  # kept". That is the round-1 destruction defect on a different branch, so the
  # delete now happens only after the quarantine is a non-empty regular file.
  # Non-empty is not enough: the header alone is non-empty, so a failed `cat`
  # left a quarantine that passed the check while containing no findings, and
  # the body was deleted anyway. The quarantine must be LARGER than its own
  # header before the only copy is removed.
  local hdr_bytes body_bytes q_bytes
  body_bytes="$(wc -c < "${OUTPUT}.stdout" 2>/dev/null | tr -d ' ')"
  q_bytes="$(wc -c < "$q" 2>/dev/null | tr -d ' ')"
  if [ -f "$q" ] && [ -n "$q_bytes" ] && [ -n "$body_bytes" ] \
     && [ "$q_bytes" -gt "$body_bytes" ]; then
    rm -f "${OUTPUT}.stdout"
    echo "  Body kept, unattributed: $q" >&2
  else
    echo "  QUARANTINE FAILED — could not write $q" >&2
    echo "  The body is left at ${OUTPUT}.stdout rather than deleted." >&2
  fi
}

MARK="$(date '+%Y-%m-%d %H:%M:%S')"
START_EPOCH="$(date +%s)"
AMBIG=""

SESSION=""
SELFTEST=0
if [ -z "${CONSULT_SKIP_RUN:-}" ]; then
  if [ -n "$WORKDIR" ]; then
    jcode run -p "$PROVIDER" -m "$MODEL" -C "$WORKDIR" --no-update --quiet \
      "$(cat "$PROMPT")" > "${OUTPUT}.stdout" 2>&1 &
  else
    jcode run -p "$PROVIDER" -m "$MODEL" --no-update --quiet \
      "$(cat "$PROMPT")" > "${OUTPUT}.stdout" 2>&1 &
  fi
  JPID=$!

  # Bind to the session BEFORE it can end. jcode removes the pid file when the
  # session finishes, so a lookup afterwards would find nothing and the run
  # would be unattributable for a reason that has nothing to do with which
  # provider answered.
  for _ in $(seq 1 60); do
    SESSION="$(session_for_pid "$JPID" "$START_EPOCH" || true)"
    case "$SESSION" in AMBIGUOUS:*) AMBIG="$SESSION"; SESSION="" ;; esac
    [ -n "$SESSION" ] && break
    sleep 1
  done

  wait "$JPID"
  rc=$?
else
  # Test-only path. CONSULT_TEST_SESSION lets the suite name a session without
  # a provider; it is refused below unless CONSULT_SKIP_RUN is also set, so it
  # cannot be used to forge an artifact in ordinary operation.
  rc=0
  SESSION="${CONSULT_TEST_SESSION:-}"
  SELFTEST=1
fi

if [ -z "$SESSION" ]; then
  echo "CONSULT REFUSED — could not bind the run to a jcode session." >&2
  [ -n "$AMBIG" ] && echo "  ${AMBIG/AMBIGUOUS:/pid files matching this run: } (exactly one is required)" >&2
  echo "  Without a session id the log can only be filtered by time, and a" >&2
  echo "  concurrent session then makes the answer ambiguous or wrong. That is" >&2
  echo "  how the first version of this script deleted the review that found" >&2
  echo "  the flaw." >&2
  rm -f "$OUTPUT"
  quarantine_output
  exit 1
fi

SERVED="$(served_provider "$LOG" "$MARK" "$SESSION")"

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
  rm -f "$OUTPUT"
  quarantine_output
  echo >&2
  echo "  No consultation was produced. An unattributable one is worth less" >&2
  echo "  than none, because it occupies the place a real one would have gone" >&2
  echo "  — but the body is kept, because a destroyed finding is worse than an" >&2
  echo "  unattributed one." >&2
  exit 1
fi

# Verified. The artifact carries its own evidence from here on.
# NOT "verified_by". A red-team's third blocking condition:
#
#   "The right architecture puts the oracle outside the component whose
#    provider-selection behaviour is being audited. […] jcode cannot be both
#    the subject and sole witness. Keep the log check as defense in depth […]
#    Do not let it mint the repository's assertion that an independent provider
#    answered."
#
# Moving the oracle outside jcode is a different design and a larger change.
# The reviewer offered the alternative explicitly: downgrade this to a
# non-authoritative consistency alarm and say so. This field is that sentence,
# in the artifact, where anyone reading the record sees it.
verified_by="scripts/consult.sh — CONSISTENCY CHECK against jcode's own log, not proof of independence"
if [ "$SELFTEST" = "1" ]; then
  # The test path did not dispatch anything. Say so IN the artifact, where the
  # gate can see it, rather than letting a self-test look like evidence.
  verified_by="scripts/consult.sh SELFTEST — no provider was contacted, NOT EVIDENCE"
fi

# In checkout mode the reviewing agent writes the artifact ITSELF, at the path
# it was told to use. The first version always rebuilt $OUTPUT from the console
# transcript and moved it into place — clobbering the agent's report with a log
# of thinking-tokens and tool calls. Two clean reports were destroyed that way
# before it was noticed, and the findings had to be read out of the transcript.
#
# So: if the file exists after the run, the provenance record is PREPENDED to
# it and the transcript is kept beside it as evidence. Only when the agent
# wrote nothing is the artifact built from stdout.
AGENT_WROTE=0
if [ -f "$OUTPUT" ] && [ -s "$OUTPUT" ]; then
  AGENT_WROTE=1
  cp "$OUTPUT" "${OUTPUT}.agent"
fi

if ! {
  echo "<!-- provenance"
  echo "requested_provider: $PROVIDER"
  echo "served_provider: $SERVED"
  echo "reviewer_claim: $SERVED"
  echo "model: $MODEL"
  echo "consistency_check: $verified_by"
  echo "session: $SESSION"
  echo "log: $LOG"
  echo "window_start: $MARK"
  echo "-->"
  echo
  if [ "$AGENT_WROTE" = "1" ]; then
    cat "${OUTPUT}.agent"
  else
    [ -f "${OUTPUT}.stdout" ] && cat "${OUTPUT}.stdout"
  fi
} > "${OUTPUT}.tmp"; then
  # A red-team found that a failed write printed success and exited 0. A
  # control that reports having recorded something it did not record is the
  # same defect as one that reports the wrong provider.
  echo "CONSULT FAILED — could not write $OUTPUT.tmp" >&2
  rm -f "${OUTPUT}.tmp"
  quarantine_output
  exit 1
fi

if ! mv "${OUTPUT}.tmp" "$OUTPUT"; then
  echo "CONSULT FAILED — could not move ${OUTPUT}.tmp into place" >&2
  quarantine_output
  exit 1
fi

# `mv file dir/` SUCCEEDS by putting the file inside the directory, and
# `[ -s dir ]` is true because a directory has a size. A red-team pointed the
# output at a directory: mv returned 0, the size test passed, the script
# deleted the body, printed success and exited 0 — with the requested artifact
# existing only as <output>/<output>.tmp.
#
# So the check is on the final state at the exact path, and a directory is
# refused before anything is written at all.
if [ -L "$OUTPUT" ] || [ ! -f "$OUTPUT" ] || [ ! -s "$OUTPUT" ]; then
  echo "CONSULT FAILED — $OUTPUT is not a non-empty regular file after writing" >&2
  quarantine_output
  exit 1
fi
rm -f "${OUTPUT}.agent"
if [ "$AGENT_WROTE" = "1" ]; then
  # The transcript is kept: it is the record of what the agent actually did,
  # and it is not the report.
  mv "${OUTPUT}.stdout" "${OUTPUT}.transcript" 2>/dev/null || true
  echo "  transcript kept beside it: ${OUTPUT}.transcript" >&2
else
  rm -f "${OUTPUT}.stdout"
fi

# "consistent with", not "verified". The word verified is what a red-team
# rejected: this reads the audited tool's own log, so it can show the log
# does not contradict the request. It cannot show an independent provider
# answered.
echo "consult: $PROVIDER/$MODEL consistent with the log (session $SESSION) — $OUTPUT"
exit $rc
