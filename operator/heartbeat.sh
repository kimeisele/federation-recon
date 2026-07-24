#!/usr/bin/env bash
# heartbeat.sh — Deterministic, decide-only operator dispatcher.
#
# Phases: 0_BOOTSTRAP → 1_CLASSIFY → 2_DELEGATE → 3_REVIEW → 4_INTEGRATE → 5_SWEEP
#
# v1.1 reads a validated checkpoint and read-only GitHub metadata, emits exactly
# one ACTION, and optionally advances the selected state file. It never executes
# BUILD/REVIEW/SWEEP/INTEGRATE actions.
#
# Usage:
#   bash operator/heartbeat.sh [--dry-run] [--state-file PATH]
#
# Environment:
#   OPERATOR_STATE_FILE  default state path override
#   HEARTBEAT_NOW        fixed ISO-8601 UTC time for deterministic testing

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="${OPERATOR_STATE_FILE:-$REPO_ROOT/operator/state.json}"
DRY_RUN=false
STALE_DAYS_PR=7
STALE_DAYS_ISSUE=14

usage() {
  cat <<'EOF'
Usage: bash operator/heartbeat.sh [--dry-run] [--state-file PATH]

  --dry-run          decide without modifying the state file
  --state-file PATH  use an explicit checkpoint path
EOF
}

die() { echo "FATAL: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --state-file)
      [ "$#" -ge 2 ] || die "--state-file requires a path"
      STATE_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -f "$STATE_FILE" ] || die "state file not found: $STATE_FILE"
[ ! -L "$STATE_FILE" ] || die "state file must not be a symbolic link: $STATE_FILE"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

# Validate the checkpoint before any GitHub query or mutation. Booleans do not
# count as integers in Python even though bool subclasses int.
validate_state() {
  _HB_STATE="$STATE_FILE" python3 - <<'PY'
import datetime
import json
import os
import sys

path = os.environ["_HB_STATE"]
try:
    with open(path) as handle:
        state = json.load(handle)
except Exception as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

phases = {
    "0_BOOTSTRAP", "1_CLASSIFY", "2_DELEGATE",
    "3_REVIEW", "4_INTEGRATE", "5_SWEEP",
}

def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

def valid_timestamp(value, nullable=False):
    if nullable and value is None:
        return True
    if not isinstance(value, str):
        return False
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value.endswith("Z")
    except ValueError:
        return False

errors = []
if state.get("schema_version") != 1:
    errors.append("schema_version must equal 1")
if state.get("phase") not in phases:
    errors.append("phase is missing or unsupported")
if not is_int(state.get("cycle")) or state["cycle"] < 0:
    errors.append("cycle must be a non-negative integer")
if not valid_timestamp(state.get("updated_at")):
    errors.append("updated_at must be an ISO-8601 UTC timestamp")
if not valid_timestamp(state.get("last_heartbeat"), nullable=True):
    errors.append("last_heartbeat must be null or an ISO-8601 UTC timestamp")
if not isinstance(state.get("notes"), str):
    errors.append("notes must be a string")

budget = state.get("budget")
if not isinstance(budget, dict):
    errors.append("budget must be an object")
else:
    used = budget.get("expert_calls_this_cycle")
    maximum = budget.get("max_expert_calls")
    if not is_int(used) or used < 0:
        errors.append("budget.expert_calls_this_cycle must be a non-negative integer")
    if not is_int(maximum) or maximum < 1:
        errors.append("budget.max_expert_calls must be a positive integer")

if errors:
    print("; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
}

if ! validation_error="$(validate_state 2>&1)"; then
  die "invalid state file: $validation_error"
fi

state_field() {
  local key="$1"
  _HB_STATE="$STATE_FILE" _HB_KEY="$key" python3 - <<'PY'
import json
import os

with open(os.environ["_HB_STATE"]) as handle:
    value = json.load(handle)
for part in os.environ["_HB_KEY"].split("."):
    value = value[part]
if value is None:
    print("")
else:
    print(value)
PY
}

now_iso="${HEARTBEAT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
runtime_tmp="$(mktemp -d)"
trap 'rm -rf "$runtime_tmp"' EXIT
if ! _HB_NOW="$now_iso" python3 - > "$runtime_tmp/now-epoch" 2>/dev/null <<'PY'
import datetime
import os

value = os.environ["_HB_NOW"]
parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
if not value.endswith("Z") or parsed.tzinfo is None:
    raise ValueError("HEARTBEAT_NOW must be ISO-8601 UTC")
print(int(parsed.timestamp()))
PY
then
  die "invalid HEARTBEAT_NOW: $now_iso"
fi
now_epoch="$(cat "$runtime_tmp/now-epoch")"

write_state() {
  local phase="$1" cycle="$2" expert_calls="$3" last_heartbeat="$4" notes="$5"
  $DRY_RUN && return 0

  _HB_STATE="$STATE_FILE" \
  _HB_PHASE="$phase" \
  _HB_CYCLE="$cycle" \
  _HB_EXPERT_CALLS="$expert_calls" \
  _HB_LAST_HEARTBEAT="$last_heartbeat" \
  _HB_NOTES="$notes" \
  _HB_UPDATED_AT="$now_iso" \
  python3 - <<'PY' || die "failed to write state file"
import json
import os
import stat
import tempfile

path = os.environ["_HB_STATE"]
original_mode = stat.S_IMODE(os.stat(path).st_mode)
with open(path) as handle:
    state = json.load(handle)
state["updated_at"] = os.environ["_HB_UPDATED_AT"]
state["phase"] = os.environ["_HB_PHASE"]
state["cycle"] = int(os.environ["_HB_CYCLE"])
state["budget"]["expert_calls_this_cycle"] = int(os.environ["_HB_EXPERT_CALLS"])
state["last_heartbeat"] = os.environ["_HB_LAST_HEARTBEAT"] or None
state["notes"] = os.environ["_HB_NOTES"]

directory = os.path.dirname(os.path.abspath(path))
fd, temporary = tempfile.mkstemp(prefix=".heartbeat-state-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(state, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, original_mode)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

emit_action() {
  echo "ACTION: $*"
}

stop_action() {
  local reason="$1" note="$2"
  write_state "$phase" "$cycle" "$expert_calls" "$now_iso" "$note"
  emit_action "STOP" "$reason"
}

visibility_stop() {
  local reason="$1"
  emit_action "STOP" "$reason"
}

phase="$(state_field phase)"
cycle="$(state_field cycle)"
expert_calls="$(state_field budget.expert_calls_this_cycle)"
max_expert="$(state_field budget.max_expert_calls)"

# Bootstrap is local-only. It does not require GitHub visibility.
if [ "$phase" = "0_BOOTSTRAP" ]; then
  if ! git_status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal 2>/dev/null)"; then
    stop_action "local repository status unavailable — cannot run heartbeat" "STOP: git status failed"
    exit 2
  fi
  if [ -n "$git_status" ]; then
    stop_action "uncommitted changes in working tree — cannot run heartbeat" "STOP: dirty git tree"
    exit 0
  fi

  write_state "1_CLASSIFY" "$((cycle + 1))" "$expert_calls" "$now_iso" "bootstrap OK, advancing"
  emit_action "ADVANCE" "bootstrap clean → 1_CLASSIFY"
  exit 0
fi

# GitHub is the read-only control plane. Any incomplete or malformed view must
# stop the dispatcher rather than masquerade as an empty backlog.
command -v gh >/dev/null 2>&1 || {
  visibility_stop "GitHub visibility unavailable: gh not found"
  exit 2
}

if ! prs_json="$(cd "$REPO_ROOT" && gh pr list --state open --limit 1000 --json number,updatedAt 2>/dev/null)"; then
  visibility_stop "GitHub visibility unavailable: open PR query failed"
  exit 2
fi
if ! issues_json="$(cd "$REPO_ROOT" && gh issue list --state open --limit 1000 --json number,updatedAt,labels 2>/dev/null)"; then
  visibility_stop "GitHub visibility unavailable: open issue query failed"
  exit 2
fi

printf '%s' "$prs_json" > "$runtime_tmp/prs.json"
printf '%s' "$issues_json" > "$runtime_tmp/issues.json"

# Output is five integers, so untrusted GitHub text never becomes shell syntax:
# WIP_COUNT STALE_PR STALE_ISSUE REVIEW_PR BUILD_ISSUE. Zero means none.
if ! _HB_PRS="$runtime_tmp/prs.json" \
  _HB_ISSUES="$runtime_tmp/issues.json" \
  _HB_NOW_EPOCH="$now_epoch" \
  _HB_STALE_PR="$STALE_DAYS_PR" \
  _HB_STALE_ISSUE="$STALE_DAYS_ISSUE" \
  python3 - > "$runtime_tmp/decision" 2>/dev/null <<'PY'
import datetime
import json
import os

with open(os.environ["_HB_PRS"]) as handle:
    prs = json.load(handle)
with open(os.environ["_HB_ISSUES"]) as handle:
    issues = json.load(handle)
if not isinstance(prs, list) or not isinstance(issues, list):
    raise ValueError("GitHub list responses must be arrays")

def parse_time(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("updatedAt must be an ISO-8601 UTC string")
    return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())

def validate_number(value):
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError("number must be a positive integer")
    return value

normalized_prs = []
for pr in prs:
    if not isinstance(pr, dict):
        raise ValueError("PR entries must be objects")
    number = validate_number(pr.get("number"))
    updated = parse_time(pr.get("updatedAt"))
    normalized_prs.append((updated, number))

normalized_issues = []
for issue in issues:
    if not isinstance(issue, dict):
        raise ValueError("issue entries must be objects")
    number = validate_number(issue.get("number"))
    updated = parse_time(issue.get("updatedAt"))
    labels = issue.get("labels")
    if not isinstance(labels, list):
        raise ValueError("issue labels must be an array")
    names = []
    for label in labels:
        if not isinstance(label, dict) or not isinstance(label.get("name"), str):
            raise ValueError("issue labels must contain string names")
        names.append(label["name"])
    normalized_issues.append((updated, number, names))

normalized_prs.sort(key=lambda item: (item[0], item[1]))
normalized_issues.sort(key=lambda item: (item[0], item[1]))
now = int(os.environ["_HB_NOW_EPOCH"])
pr_cutoff = now - int(os.environ["_HB_STALE_PR"]) * 86400
issue_cutoff = now - int(os.environ["_HB_STALE_ISSUE"]) * 86400

stale_pr = next((number for updated, number in normalized_prs if updated < pr_cutoff), 0)
stale_issue = next((number for updated, number, _ in normalized_issues if updated < issue_cutoff), 0)
review_pr = normalized_prs[0][1] if normalized_prs else 0

build_issue = 0
for _, number, labels in normalized_issues:
    if "approved" in labels:
        build_issue = number
        break

print(len(normalized_prs), stale_pr, stale_issue, review_pr, build_issue)
PY
then
  visibility_stop "GitHub visibility unavailable: malformed list response"
  exit 2
fi

decision_tuple="$(cat "$runtime_tmp/decision")"

case "$decision_tuple" in
  ""|*[!0-9\ ]*)
    visibility_stop "GitHub visibility unavailable: invalid decision data"
    exit 2
    ;;
esac

set -- $decision_tuple
if [ "$#" -ne 5 ]; then
  visibility_stop "GitHub visibility unavailable: invalid decision data"
  exit 2
fi
wip="$1"
stale_pr="$2"
stale_issue="$3"
review_pr="$4"
build_issue="$5"

if [ "$wip" -gt 1 ]; then
  stop_action "WIP cap violated: $wip open PRs (limit 1)" "STOP: WIP cap ($wip open PRs)"
  exit 0
fi

if [ "$expert_calls" -ge "$max_expert" ]; then
  stop_action "budget cap: $expert_calls/$max_expert expert calls used" "STOP: budget cap"
  exit 0
fi

if [ "$stale_pr" -gt 0 ]; then
  write_state "5_SWEEP" "$cycle" "$expert_calls" "$now_iso" "SWEEP: stale PR #$stale_pr"
  emit_action "SWEEP" "PR #$stale_pr — no activity for >${STALE_DAYS_PR} days"
  exit 0
fi

if [ "$stale_issue" -gt 0 ]; then
  write_state "5_SWEEP" "$cycle" "$expert_calls" "$now_iso" "SWEEP: stale issue #$stale_issue"
  emit_action "SWEEP" "issue #$stale_issue — no activity for >${STALE_DAYS_ISSUE} days"
  exit 0
fi

if [ "$review_pr" -gt 0 ]; then
  write_state "3_REVIEW" "$cycle" "$expert_calls" "$now_iso" "REVIEW: PR #$review_pr"
  emit_action "REVIEW" "PR #$review_pr"
  exit 0
fi

if [ "$build_issue" -gt 0 ]; then
  write_state "2_DELEGATE" "$cycle" "$expert_calls" "$now_iso" "BUILD: issue #$build_issue"
  emit_action "BUILD" "issue #$build_issue"
  exit 0
fi

write_state "$phase" "$cycle" "$expert_calls" "$now_iso" "HOLD: no work"
emit_action "HOLD" "nothing to do — WIP=$wip, no approved issues without PR, no stale items"
