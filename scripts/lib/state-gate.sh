#!/usr/bin/env bash
# state-gate.sh — Scheduled run state gate (STATE gate, not DIFF gate).
#
# Source it, then call:
#   check_scheduled_run_state <history_json_path> [workflow_label]
#
# Evaluates whether the latest scheduled workflow run is current and
# successful. Adds a STALE state: a schedule that stopped firing keeps its
# last verdict forever and that verdict may be green, so staleness is checked
# first by age, then by conclusion.
#
# Exit: 0 GREEN, 1 RED, 2 UNKNOWN, 3 STALE.
# See issues #79, #92.
#
# ── What this gate does NOT establish ──────────────────────────────────────
#
# This gate makes staleness *detectable*. It does not make it *noticed*.
# A gate nobody invokes is as silent as no gate. Who invokes it on a
# schedule is an open question and belongs in its own issue — do not
# confuse detection with vigilance.
# ────────────────────────────────────────────────────────────────────────────

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

# ── Staleness threshold ──────────────────────────────────────────────────
#
# Measured on this repository, workflow node-census.yml, cron 0 6 * * *:
#   2026-07-30T08:15:22Z    +2h15
#   2026-07-29T08:31:04Z    +2h31
#   2026-07-28T08:25:00Z    +2h25
#   2026-07-27T09:40:35Z    +3h40
#   2026-07-26T08:18:03Z    +2h18
#
# GitHub delays scheduled workflows by 2–4 hours consistently. A 24-hour
# threshold would produce a false STALE every single day. Derived:
# cadence (24 h) + max observed delay (3h40) + margin = 30 h.
# Override via STATE_GATE_STALE_THRESHOLD_HOURS.
: "${STATE_GATE_STALE_THRESHOLD_HOURS:=30}"

check_scheduled_run_state() {
  local history_json_path="$1"
  local workflow_label="${2:-unknown workflow}"

  # 1. File missing or unreadable.
  if [[ ! -r "$history_json_path" ]]; then
    echo "STATE: UNKNOWN - cannot read ${history_json_path}" >&2
    return 2
  fi

  # Use python3 for JSON parsing. Pass the path and threshold as positional
  # arguments so values never appear quoted inside the inline script.
  local _sg_result
  _sg_result=$(python3 -c '
import json, sys, datetime

threshold_hours = float(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc)

try:
    data = json.load(open(sys.argv[1]))
except Exception:
    print("INVALID_JSON")
    sys.exit(0)
if not isinstance(data, list) or len(data) == 0:
    print("EMPTY")
    sys.exit(0)
# Newest first
data.sort(key=lambda x: x["createdAt"], reverse=True)
newest = data[0]
# Count consecutive non-success runs
count = 0
oldest_id = None
oldest_ts = None
for entry in data:
    if entry.get("conclusion") != "success":
        count += 1
        oldest_id = entry["databaseId"]
        oldest_ts = entry["createdAt"]
    else:
        break

ts = newest["createdAt"].replace("Z", "+00:00")
newest_dt = datetime.datetime.fromisoformat(ts)
age_hours = (now - newest_dt).total_seconds() / 3600.0

print(newest["createdAt"])
print(newest["databaseId"])
print(newest.get("conclusion", ""))
print(count)
print(oldest_id or "")
print(oldest_ts or "")
# Stale marker: age in hours if stale, empty string otherwise
if age_hours > threshold_hours:
    print(f"{age_hours:.1f}")
else:
    print("")
' "$history_json_path" "$STATE_GATE_STALE_THRESHOLD_HOURS" 2>/dev/null) || {
    echo "STATE: UNKNOWN - failed to parse ${history_json_path}" >&2
    return 2
  }

  if [[ -z "$_sg_result" ]]; then
    echo "STATE: UNKNOWN - failed to parse ${history_json_path}" >&2
    return 2
  fi

  case "$_sg_result" in
    INVALID_JSON)
      echo "STATE: UNKNOWN - ${history_json_path} is not valid JSON" >&2
      return 2
      ;;
    EMPTY)
      echo "STATE: UNKNOWN - no scheduled runs on record" >&2
      return 2
      ;;
  esac

  # Parse the 7-line structured output.
  local _sg_newest_ts _sg_newest_id _sg_newest_conclusion
  local _sg_consecutive _sg_oldest_id _sg_oldest_ts _sg_stale_age
  {
    read _sg_newest_ts
    read _sg_newest_id
    read _sg_newest_conclusion
    read _sg_consecutive
    read _sg_oldest_id
    read _sg_oldest_ts
    read _sg_stale_age
  } <<< "$_sg_result"

  # 3. Staleness check (takes precedence over conclusion).
  if [[ -n "$_sg_stale_age" ]]; then
    if [[ "$_sg_newest_conclusion" != "success" ]]; then
      echo "STATE: STALE - ${workflow_label} last run ${_sg_newest_id} is ${_sg_stale_age}h old (threshold: ${STATE_GATE_STALE_THRESHOLD_HOURS}h); last run also failed (${_sg_newest_conclusion})" >&2
    else
      echo "STATE: STALE - ${workflow_label} last run ${_sg_newest_id} is ${_sg_stale_age}h old (threshold: ${STATE_GATE_STALE_THRESHOLD_HOURS}h)" >&2
    fi
    return 3
  fi

  # 4. Newest entry concluded "success".
  if [[ "$_sg_newest_conclusion" == "success" ]]; then
    echo "STATE: GREEN - ${workflow_label} last scheduled run ${_sg_newest_id} succeeded"
    return 0
  fi

  # 5. Otherwise: red.
  {
    echo "STATE: RED - ${workflow_label} last scheduled run ${_sg_newest_id} concluded ${_sg_newest_conclusion}"
    echo "  consecutive failures: ${_sg_consecutive}"
    echo "  oldest in that streak: ${_sg_oldest_id} at ${_sg_oldest_ts}"
  } >&2
  return 1
}
