#!/usr/bin/env bash
# state-gate.sh — Scheduled run state gate (STATE gate, not DIFF gate).
#
# Source it, then call:
#   check_scheduled_run_state <history_json_path> [workflow_label]
#
# Evaluates whether the latest scheduled workflow run succeeded.
# Exit: 0 green, 1 red, 2 unknown.
# See issue #79.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.

check_scheduled_run_state() {
  local history_json_path="$1"
  local workflow_label="${2:-unknown workflow}"

  # 1. File missing or unreadable.
  if [[ ! -r "$history_json_path" ]]; then
    echo "STATE: UNKNOWN - cannot read ${history_json_path}" >&2
    return 2
  fi

  # Use python3 for JSON parsing. Pass the path as a positional argument so
  # the filename never appears quoted inside the inline script.
  local _sg_result
  _sg_result=$(python3 -c '
import json, sys
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
print(newest["createdAt"])
print(newest["databaseId"])
print(newest.get("conclusion", ""))
print(count)
print(oldest_id or "")
print(oldest_ts or "")
' "$history_json_path" 2>/dev/null) || {
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

  # Parse the 6-line structured output.
  local _sg_newest_ts _sg_newest_id _sg_newest_conclusion
  local _sg_consecutive _sg_oldest_id _sg_oldest_ts
  {
    read _sg_newest_ts
    read _sg_newest_id
    read _sg_newest_conclusion
    read _sg_consecutive
    read _sg_oldest_id
    read _sg_oldest_ts
  } <<< "$_sg_result"

  # 3. Newest entry concluded "success".
  if [[ "$_sg_newest_conclusion" == "success" ]]; then
    echo "STATE: GREEN - ${workflow_label} last scheduled run ${_sg_newest_id} succeeded"
    return 0
  fi

  # 4. Otherwise: red.
  {
    echo "STATE: RED - ${workflow_label} last scheduled run ${_sg_newest_id} concluded ${_sg_newest_conclusion}"
    echo "  consecutive failures: ${_sg_consecutive}"
    echo "  oldest in that streak: ${_sg_oldest_id} at ${_sg_oldest_ts}"
  } >&2
  return 1
}
