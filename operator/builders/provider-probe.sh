#!/usr/bin/env bash
# provider-probe.sh — establish which provider will actually serve, by making
# one measured call and reading the tool's log, before the build is dispatched.
#
#   provider-probe.sh <requested_provider> <requested_model> <out_file> [seconds]
#
# Writes a record to <out_file> and prints the resolved provider on stdout.
# Exit 0 resolved and matching, 1 mismatch or ambiguous, 2 could not measure.
#
# ── Why a probe, and not the tool's own answer ─────────────────────────────
#
# `jcode provider current -p deepseek` reports:
#
#     requested_provider  deepseek
#     resolved_provider   DeepSeek
#     selected_model      deepseek-v4-flash
#
# and a run started with exactly those flags logs, for all 399 lines of the
# session:
#
#     ses:session_maple_178566|prv:openrouter|mod:deepseek
#
# Measured twice on 2026-08-02, once inside Slice 1b's run wo-126-2 and once
# standalone. **The tool's own resolver disagrees with the tool's runtime.**
# So the resolver is a claim about intent, not a measurement of routing, and
# the only place the routing appears is the log.
#
# ── What this costs, stated rather than hidden ─────────────────────────────
#
# One call with a one-word prompt. There is no zero-token way to learn this:
# the provider tag is written when an API call starts. The probe is the price
# of knowing, and it is paid before the build — which is the expensive part —
# rather than after.
#
# ── What this establishes ──────────────────────────────────────────────────
#
# That the provider serving the probe, at this moment, with these flags, is
# the one that was asked for.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - That the BUILD is served by the same provider. It is a separate
#     invocation and routing could differ. This narrows the window from "never
#     checked" to "checked seconds earlier with identical flags"; it does not
#     close it. Closing it would need the tool to report routing per request,
#     which is exactly what it does not do reliably.
#   - That the log is honest. It is the audited tool's own log — the same
#     ceiling `scripts/consult.sh` states about itself. A tool that lies about
#     its routing in the log defeats this, and nothing available here would
#     catch that.
#   - Anything about cost. That is #160.
set -o nounset -o pipefail

REQUESTED_PROVIDER="${1:-}"
REQUESTED_MODEL="${2:-}"
OUT_FILE="${3:-}"
TIMEOUT_SECS="${4:-180}"

if [ -z "$REQUESTED_PROVIDER" ] || [ -z "$REQUESTED_MODEL" ] || [ -z "$OUT_FILE" ]; then
  echo "usage: provider-probe.sh <provider> <model> <out_file> [seconds]" >&2
  exit 2
fi

LOG_DIR="${JCODE_LOG_DIR:-$HOME/.jcode/logs}"
LOG_FILE="$LOG_DIR/jcode-$(date -u +%Y-%m-%d).log"

_record() {
  {
    printf 'requested_provider: %s\n' "$REQUESTED_PROVIDER"
    printf 'requested_model:    %s\n' "$REQUESTED_MODEL"
    printf 'resolved_provider:  %s\n' "${1:-undetermined}"
    printf 'resolved_model:     %s\n' "${2:-undetermined}"
    printf 'requested_endpoint: %s\n' "${JCODE_EXPECTED_ENDPOINT:-not applicable}"
    printf 'resolved_endpoint:  %s\n' "${4:-not measured}"
    printf 'verdict:            %s\n' "$3"
    printf 'log:                %s\n' "$LOG_FILE"
    printf 'window_from:        %s\n' "${WINDOW_FROM:-unset}"
    printf 'measured_by:        provider-probe.sh, one call, log read afterwards\n'
  } > "$OUT_FILE"
}

# A scratch directory outside any repository: the probe must not be able to
# change anything, and a cwd inside the worktree would give it the chance.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

WINDOW_FROM="$(date -u +"%Y-%m-%d %H:%M:%S")"

PROFILE="${JCODE_PROVIDER_PROFILE:-}"
EXPECTED_ENDPOINT="${JCODE_EXPECTED_ENDPOINT:-}"

# The probe is bounded by OUR clock. #149 measured a configured
# stream_idle_timeout_secs=180 that did not fire after 10h45m, and #159
# measured 22 minutes with no socket open. A timeout we do not enforce is not
# a timeout.
if [ -n "$PROFILE" ]; then
  if [ -z "$EXPECTED_ENDPOINT" ]; then
    _record "$PROFILE" "$REQUESTED_MODEL" "profile mode requires JCODE_EXPECTED_ENDPOINT"
    echo "provider-probe: profile selected without an expected endpoint" >&2
    exit 2
  fi
  "${JCODE_BIN:-jcode}" --provider-profile "$PROFILE" --model "$REQUESTED_MODEL" \
    --quiet --no-update -C "$SCRATCH" run "Reply with the single word: ok" \
    >/dev/null 2>&1 &
else
  "${JCODE_BIN:-jcode}" run -p "$REQUESTED_PROVIDER" -m "$REQUESTED_MODEL" \
    --quiet --no-update -C "$SCRATCH" "Reply with the single word: ok" \
    >/dev/null 2>&1 &
fi
PROBE_PID=$!
waited=0
while kill -0 "$PROBE_PID" 2>/dev/null; do
  sleep 1
  waited=$((waited + 1))
  if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
    kill -9 "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    _record "" "" "probe did not return within ${TIMEOUT_SECS}s"
    echo "provider-probe: no answer within ${TIMEOUT_SECS}s — provider unverified" >&2
    exit 2
  fi
done
wait "$PROBE_PID" 2>/dev/null || true

if [ ! -f "$LOG_FILE" ]; then
  _record "" "" "log file not found"
  echo "provider-probe: no log at $LOG_FILE — cannot measure" >&2
  exit 2
fi

if [ -n "$PROFILE" ]; then
  # Named OpenAI-compatible profiles use a generic transport tag. Measure the
  # route tuple that JCode logs for the request instead: model plus endpoint.
  ROUTES="$(python3 - "$LOG_FILE" "$WINDOW_FROM" <<'PY'
import re, sys
log, start = sys.argv[1], sys.argv[2]
seen = set()
for line in open(log, errors="replace"):
    stamp = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
    if not stamp or stamp.group(1) < start:
        continue
    route = re.search(
        r"model:\s*([^,\s)]+),\s*endpoint:\s*([^\s,)]+)", line
    )
    if route:
        seen.add("%s\t%s" % route.groups())
for item in sorted(seen):
    print(item)
PY
)"
  COUNT="$(printf '%s' "$ROUTES" | grep -c . || true)"

  if [ "${COUNT:-0}" -eq 0 ]; then
    _record "$PROFILE" "" "no model and endpoint route logged in the window"
    echo "provider-probe: no model/endpoint route logged — profile unverified" >&2
    exit 2
  fi
  if [ "${COUNT:-0}" -gt 1 ]; then
    _record "$PROFILE" "AMBIGUOUS" "more than one route logged in the window"
    echo "provider-probe: more than one model/endpoint route in the window" >&2
    exit 1
  fi

  RESOLVED_MODEL="$(printf '%s' "$ROUTES" | cut -f1)"
  RESOLVED_ENDPOINT="$(printf '%s' "$ROUTES" | cut -f2)"
  if [ "$RESOLVED_MODEL" != "$REQUESTED_MODEL" ] || \
     [ "$RESOLVED_ENDPOINT" != "$EXPECTED_ENDPOINT" ]; then
    _record "$PROFILE" "$RESOLVED_MODEL" "MISMATCH" "$RESOLVED_ENDPOINT"
    echo "provider-probe: REFUSED — named profile resolved to an unexpected model or endpoint" >&2
    exit 1
  fi

  _record "$PROFILE" "$RESOLVED_MODEL" "match" "$RESOLVED_ENDPOINT"
  printf '%s\n' "$PROFILE"
  exit 0
fi

# Every distinct provider tag written since the window opened.
TAGS="$(python3 - "$LOG_FILE" "$WINDOW_FROM" <<'PY'
import re, sys
log, start = sys.argv[1], sys.argv[2]
seen = set()
for line in open(log, errors="replace"):
    m = re.match(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
    if not m or m.group(1) < start:
        continue
    t = re.search(r"prv:([A-Za-z0-9_-]+)\|mod:([A-Za-z0-9._-]+)", line)
    if t:
        seen.add("%s\t%s" % t.groups())
for s in sorted(seen):
    print(s)
PY
)"

COUNT="$(printf '%s' "$TAGS" | grep -c . || true)"

if [ "${COUNT:-0}" -eq 0 ]; then
  _record "" "" "no provider tag logged in the window"
  echo "provider-probe: nothing identifiable was logged — provider undetermined" >&2
  echo "  Exit 0 from the tool proves that something answered, never which." >&2
  exit 2
fi

if [ "${COUNT:-0}" -gt 1 ]; then
  _record "AMBIGUOUS" "AMBIGUOUS" "more than one provider logged in the window"
  echo "provider-probe: more than one provider in the window — ambiguous:" >&2
  printf '%s\n' "$TAGS" | sed 's/^/    /' >&2
  exit 1
fi

RESOLVED_PROVIDER="$(printf '%s' "$TAGS" | cut -f1)"
RESOLVED_MODEL="$(printf '%s' "$TAGS" | cut -f2)"

# Normalise for comparison only: lowercase, drop non-alphanumerics. `moonshot`
# and `moonshotai` are the same provider spelled two ways; `deepseek` and
# `openrouter` are not, and that is the case this exists for.
_norm() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]'; }
WANT="$(_norm "$REQUESTED_PROVIDER")"
GOT="$(_norm "$RESOLVED_PROVIDER")"

case "$GOT" in
  "$WANT"*) MATCH=yes ;;
  *) case "$WANT" in "$GOT"*) MATCH=yes ;; *) MATCH=no ;; esac ;;
esac

if [ "$MATCH" != "yes" ]; then
  _record "$RESOLVED_PROVIDER" "$RESOLVED_MODEL" "MISMATCH"
  echo "provider-probe: REFUSED — requested '$REQUESTED_PROVIDER', served by '$RESOLVED_PROVIDER'" >&2
  echo "  A silently substituted provider is a budget and attribution failure," >&2
  echo "  not a detail: the run's cost lands somewhere nobody chose. See #159." >&2
  exit 1
fi

_record "$RESOLVED_PROVIDER" "$RESOLVED_MODEL" "match"
printf '%s\n' "$RESOLVED_PROVIDER"
