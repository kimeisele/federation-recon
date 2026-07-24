#!/usr/bin/env bash
# heartbeat.sh — Deterministic operator dispatcher (stateless, no LLM).
#
# Phases: 0_BOOTSTRAP → 1_CLASSIFY → 2_DELEGATE → 3_REVIEW → 4_INTEGRATE → 5_SWEEP
#
# Reads state.json + queries GitHub (gh read-only), applies deterministic rules,
# outputs the next ACTION and advances state.json. In v1: decides + writes state,
# does NOT execute the action itself.
#
# Usage: bash operator/heartbeat.sh
# Output: one line "ACTION: <action> <detail>" + rationale on stdout.
#
# Escalation triggers (Opus instead of DeepSeek):
#   - Risk class HIGH in Envelope §4
#   - Diff > 200 lines (large change = warrants expert review)
#   - CI red (gates failed)
#   - Review conflict (two reviewers disagree)
#   Otherwise: DeepSeek default.

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$REPO_ROOT/operator/state.json"
STALE_DAYS_PR=7
STALE_DAYS_ISSUE=14

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo "FATAL: $*" >&2; exit 1; }

# Read a field from state.json using python3.
# Supports dotted paths like 'budget.expert_calls_this_cycle'.
state_field() {
  python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    d = json.load(f)
key = '$1'
for k in key.split('.'):
    if isinstance(d, dict):
        d = d.get(k, '')
    else:
        d = ''
        break
if d is None:
    d = ''
print(d)
"
}

# Write updated state.json. All fields except updated_at/phase/cycle/budget/
# last_heartbeat are preserved via a merge with the existing file.
write_state() {
  local phase="$1" cycle="$2" expert_calls="$3" last_heartbeat="$4" notes="$5"

  # Build JSON values inline: numbers as-is, empty → null, strings via env.
  local ec_json lhb_json
  ec_json="${expert_calls:-null}"
  if [ "$last_heartbeat" = "null" ] || [ -z "$last_heartbeat" ]; then
    lhb_json="null"
  else
    lhb_json="\"$last_heartbeat\""
  fi

  # Pass notes via env to avoid quoting hell in -c string.
  export _HB_PHASE="$phase"
  export _HB_CYCLE="$cycle"
  export _HB_EC="$ec_json"
  export _HB_LHB="$lhb_json"
  export _HB_NOTES="$notes"
  export _HB_STATE="$STATE_FILE"

  python3 -c "
import json, os
d = json.load(open(os.environ['_HB_STATE']))
d['updated_at'] = __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
d['phase'] = os.environ['_HB_PHASE']
d['cycle'] = int(os.environ['_HB_CYCLE'])
if 'budget' in d:
    d['budget']['expert_calls_this_cycle'] = json.loads(os.environ['_HB_EC'])
d['last_heartbeat'] = json.loads(os.environ['_HB_LHB'])
d['notes'] = os.environ['_HB_NOTES']
json.dump(d, open(os.environ['_HB_STATE'],'w'), indent=2)
open(os.environ['_HB_STATE'],'a').write('\n')
" 2>/dev/null || die "Failed to write state.json"
}

# gh helpers — return empty on failure (graceful).
gh_pr_list()  { gh pr list --state open --json number,title,createdAt,labels 2>/dev/null || echo '[]'; }
gh_pr_count() { gh pr list --state open --limit 200 --json number 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo '0'; }
gh_issue_list() { gh issue list --state open --label approved --json number,title,createdAt 2>/dev/null || echo '[]'; }

# Check number of open PRs (WIP count).
wip_count() { gh_pr_count; }

# Check if a given issue number already has an open PR (via title convention "Closes #N").
issue_has_open_pr() {
  local issue="$1"
  gh pr list --state open --search "Closes #${issue}" --limit 5 --json number 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d))" 2>/dev/null || echo '0'
}

# ---------------------------------------------------------------------------
# Deterministic rules — ordered by priority
# ---------------------------------------------------------------------------

emit_action() {
  echo "ACTION: $*"
}

run_heartbeat() {
  local now ts
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  now="$(date -u +%s)"

  # Read current state
  local phase cycle expert_calls max_expert
  phase="$(state_field phase)"
  cycle="$(state_field cycle)"
  expert_calls="$(state_field 'budget.expert_calls_this_cycle')"
  max_expert="$(state_field 'budget.max_expert_calls')"

  local wip open_pr_count
  wip="$(wip_count)"
  open_pr_count="$wip"

  # ---- Phase 0: BOOTSTRAP ----
  # Validate prerequisites. If anything is wrong, STOP.
  if [ "$phase" = "0_BOOTSTRAP" ]; then
    # git clean check — are there uncommitted changes?
    if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null || \
       ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then
      emit_action "STOP" "uncommitted changes in working tree — cannot run heartbeat"
      write_state "0_BOOTSTRAP" "$cycle" "$expert_calls" "$ts" "STOP: dirty git tree"
      return 1
    fi

    # Move to CLASSIFY on next beat
    write_state "1_CLASSIFY" "$((cycle + 1))" "$expert_calls" "$ts" "bootstrap OK, advancing"
    emit_action "ADVANCE" "bootstrap clean → 1_CLASSIFY"
    return 0
  fi

  # ---- HARD LIMITS ----
  # WIP cap: ≤ 1 open PR.
  if [ "$wip" -gt 1 ]; then
    emit_action "STOP" "WIP cap violated: $wip open PRs (limit 1)"
    write_state "$phase" "$cycle" "$expert_calls" "$ts" "STOP: WIP cap ($wip open PRs)"
    return 0
  fi

  # Budget cap: expert calls.
  if [ "$expert_calls" -ge "$max_expert" ]; then
    emit_action "STOP" "budget cap: $expert_calls/$max_expert expert calls used"
    write_state "$phase" "$cycle" "$expert_calls" "$ts" "STOP: budget cap"
    return 0
  fi

  # ---- Phase 5: SWEEP (stale detection) ----
  # Check for stale open PRs (older than STALE_DAYS_PR, no activity).
  local stale_pr
  stale_pr="$(gh pr list --state open --json number,createdAt --jq "
    (map(select(
      ((now - ( .createdAt | fromdateiso8601)) / 86400) > $STALE_DAYS_PR
    )) | .[0].number // empty)
  " 2>/dev/null || echo '')"
  # Use python3 for date math since jq --jq may not be available
  if command -v python3 &>/dev/null; then
    stale_pr="$(python3 -c "
import json, subprocess, sys, datetime
try:
    out = subprocess.check_output(['gh','pr','list','--state','open','--json','number,createdAt'], stderr=subprocess.DEVNULL)
    prs = json.loads(out)
    now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
    for p in prs:
        created = datetime.datetime.fromisoformat(p['createdAt'].replace('Z','+00:00'))
        if (now - created).days > $STALE_DAYS_PR:
            print(p['number'])
            sys.exit(0)
    print('')
except: pass
" 2>/dev/null)"
  fi
  if [ -n "$stale_pr" ]; then
    emit_action "SWEEP" "PR #${stale_pr} — stale (>${STALE_DAYS_PR} days, no progress)"
    write_state "5_SWEEP" "$cycle" "$expert_calls" "$ts" "SWEEP: stale PR #${stale_pr}"
    return 0
  fi

  # Stale issues
  local stale_issue
  stale_issue="$(python3 -c "
import json, subprocess, sys, datetime
try:
    out = subprocess.check_output(['gh','issue','list','--state','open','--json','number,createdAt'], stderr=subprocess.DEVNULL)
    issues = json.loads(out)
    now = datetime.datetime.utcnow().replace(tzinfo=datetime.timezone.utc)
    for i in issues:
        created = datetime.datetime.fromisoformat(i['createdAt'].replace('Z','+00:00'))
        if (now - created).days > $STALE_DAYS_ISSUE:
            print(i['number'])
            sys.exit(0)
    print('')
except: pass
" 2>/dev/null)"
  if [ -n "$stale_issue" ]; then
    emit_action "SWEEP" "issue #${stale_issue} — stale (>${STALE_DAYS_ISSUE} days)"
    write_state "5_SWEEP" "$cycle" "$expert_calls" "$ts" "SWEEP: stale issue #${stale_issue}"
    return 0
  fi

  # ---- Phase 3: REVIEW ----
  # If there is an open PR, review it.
  if [ "$open_pr_count" -gt 0 ]; then
    local pr_num
    pr_num="$(gh pr list --state open --json number --jq '.[0].number' 2>/dev/null || \
              python3 -c "
import json, subprocess
out = subprocess.check_output(['gh','pr','list','--state','open','--json','number'], stderr=subprocess.DEVNULL)
prs = json.loads(out)
print(prs[0]['number']) if prs else print('')
" 2>/dev/null)"
    if [ -n "$pr_num" ]; then
      emit_action "REVIEW" "PR #${pr_num}"
      write_state "3_REVIEW" "$cycle" "$expert_calls" "$ts" "REVIEW: PR #${pr_num}"
      return 0
    fi
  fi

  # ---- Phase 2: DELEGATE ----
  # WIP < 1 AND there's an issue labeled 'approved' without an open PR.
  if [ "$wip" -lt 1 ]; then
    local issue_num
    issue_num="$(python3 -c "
import json, subprocess, sys
try:
    out = subprocess.check_output(['gh','issue','list','--state','open','--label','approved','--json','number,title'], stderr=subprocess.DEVNULL)
    issues = json.loads(out)
    if issues:
        # Check if any approved issue already has a PR
        for i in issues:
            pr_out = subprocess.check_output(['gh','pr','list','--state','open','--search','Closes #'+str(i['number']),'--json','number'], stderr=subprocess.DEVNULL)
            prs = json.loads(pr_out)
            if len(prs) == 0:
                print(i['number'])
                sys.exit(0)
        print('')
    else:
        print('')
except: pass
" 2>/dev/null)"
    if [ -n "$issue_num" ]; then
      emit_action "BUILD" "issue #${issue_num}"
      write_state "2_DELEGATE" "$cycle" "$expert_calls" "$ts" "BUILD: issue #${issue_num}"
      return 0
    fi
  fi

  # ---- Terminal: HOLD ----
  emit_action "HOLD" "nothing to do — WIP=${wip}, no approved issues without PR, no stale items"
  write_state "$phase" "$cycle" "$expert_calls" "$ts" "HOLD: no work"
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Validate state.json exists
if [ ! -f "$STATE_FILE" ]; then
  die "state.json not found at $STATE_FILE"
fi

run_heartbeat
