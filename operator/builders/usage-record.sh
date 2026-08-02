#!/usr/bin/env bash
# usage-record.sh — assemble the cost record for one builder run.
#
#   usage-record.sh <out_file> <window_from> <provider_record> <usage_before_file> <usage_after_file>
#
# Exit 0 a complete record was written, 1 it could not be.
#
# ── What a run must be able to say about itself ────────────────────────────
#
# Provider, model, and what it cost. #160 found that none of it survived: the
# adapter wrote to a temp directory it then deleted, because `RUN_DIR` was set
# and never exported. That is fixed. This is the other half — what goes in the
# file now that there is a file.
#
# ── Tokens are redacted by the tool, and this says so ──────────────────────
#
# `jcode usage` reports plan windows and API-key balances, not per-run
# consumption. The log carries per-call lifecycle events, and every one of
# them reads:
#
#     input_tokens=<redacted> ... output_tokens=<redacted>
#
# So a token count is not obtainable from either source. The record states
# that in the field rather than leaving it empty, because an empty field reads
# as zero and zero is a measurement. `unavailable` is not.
#
# What IS obtainable and is recorded: the provider and model that actually
# served (measured by provider-probe.sh from the log, not from the request),
# the number of API calls in the window, the summed stream time, cache reads,
# and the provider balance before and after where the provider publishes one.
#
# ── What this establishes ──────────────────────────────────────────────────
#
# That a run has an attributable cost record, and that where a number is
# missing the record says which number and why.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - A price. A balance delta is the closest thing available and only some
#     providers publish a balance; a subscription plan publishes a percentage
#     of a window, which is not comparable across runs.
#   - That the calls counted in the window belong to this run. The window is
#     bracketed by timestamps, and a concurrent session on the same host lands
#     in it. Sessions are identifiable in the log and correlating by session
#     id is the next rung; it is not built here.
set -o nounset -o pipefail

OUT="${1:-}"
WINDOW_FROM="${2:-}"
PROVIDER_RECORD="${3:-}"
USAGE_BEFORE="${4:-}"
USAGE_AFTER="${5:-}"

if [ -z "$OUT" ] || [ -z "$WINDOW_FROM" ]; then
  echo "usage: usage-record.sh <out> <window_from> <provider_record> <before> <after>" >&2
  exit 1
fi

LOG_DIR="${JCODE_LOG_DIR:-$HOME/.jcode/logs}"
LOG_FILE="$LOG_DIR/jcode-$(date -u +%Y-%m-%d).log"

_field() {
  [ -f "$PROVIDER_RECORD" ] || { printf 'undetermined'; return; }
  sed -n "s/^$1:[[:space:]]*//p" "$PROVIDER_RECORD" | head -1
}

PROVIDER="$(_field resolved_provider)"
MODEL="$(_field resolved_model)"
[ -n "$PROVIDER" ] || PROVIDER="undetermined"
[ -n "$MODEL" ] || MODEL="undetermined"

# Per-call figures from the log window. Absent log, absent figures — and the
# record says "no log" rather than "0 calls", because those are not the same
# and only one of them is a measurement.
if [ -f "$LOG_FILE" ]; then
  STATS="$(python3 - "$LOG_FILE" "$WINDOW_FROM" <<'PY'
import re, sys
log, start = sys.argv[1], sys.argv[2]
calls = 0
elapsed = 0
cache_read = 0
redacted = 0
for line in open(log, errors="replace"):
    m = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
    if not m or m.group(1) < start:
        continue
    if "API call starting" in line:
        calls += 1
    e = re.search(r"elapsed_ms=(\d+)", line)
    if e:
        elapsed += int(e.group(1))
    c = re.search(r"cache_read=(\d+)", line)
    if c:
        cache_read += int(c.group(1))
    if "tokens=<redacted>" in line:
        redacted += 1
print("%d\t%d\t%d\t%d" % (calls, elapsed, cache_read, redacted))
PY
)"
  CALLS="$(printf '%s' "$STATS" | cut -f1)"
  ELAPSED_MS="$(printf '%s' "$STATS" | cut -f2)"
  CACHE_READ="$(printf '%s' "$STATS" | cut -f3)"
  REDACTED="$(printf '%s' "$STATS" | cut -f4)"
else
  CALLS="no log at $LOG_FILE"
  ELAPSED_MS="$CALLS"
  CACHE_READ="$CALLS"
  REDACTED=0
fi

# A balance line, where the provider publishes one at all.
_balance() {
  [ -f "$1" ] || { printf 'not captured'; return; }
  local b
  b="$(grep -iE '^Balance:' "$1" | head -1 | sed 's/^[Bb]alance:[[:space:]]*//')"
  [ -n "$b" ] && printf '%s' "$b" || printf 'not published by this provider'
}

{
  printf 'run_provider:      %s\n' "$PROVIDER"
  printf 'run_model:         %s\n' "$MODEL"
  printf 'api_calls:         %s\n' "$CALLS"
  printf 'stream_ms_total:   %s\n' "$ELAPSED_MS"
  printf 'cache_read_total:  %s\n' "$CACHE_READ"
  printf 'tokens:            unavailable — the tool redacts them\n'
  printf 'tokens_evidence:   %s log line(s) carry tokens=<redacted>\n' "$REDACTED"
  printf 'balance_before:    %s\n' "$(_balance "$USAGE_BEFORE")"
  printf 'balance_after:     %s\n' "$(_balance "$USAGE_AFTER")"
  printf 'window_from:       %s\n' "$WINDOW_FROM"
  printf 'log:               %s\n' "$LOG_FILE"
  printf 'caveat:            calls are counted by time window, not by session id;\n'
  printf 'caveat:            a concurrent session on this host lands in the count.\n'
} > "$OUT"

# The record must name a provider and a model. Everything else may be
# unavailable and say so; those two are what makes the cost attributable at
# all, and a record without them is not a cost record.
if [ "$PROVIDER" = "undetermined" ] || [ "$MODEL" = "undetermined" ]; then
  echo "usage-record: provider or model undetermined — the record is not attributable" >&2
  exit 1
fi
exit 0
