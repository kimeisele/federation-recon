#!/usr/bin/env bash
# run.sh — Slice 1a execution layer. Invokes a builder in a detached worktree
# and independently verifies every claim it makes. The builder is assumed to be
# wrong, slow, or lying; this runner catches that mechanically.
#
# Usage:
#   bash operator/run.sh <work-order.json> [--resume]
#
# Exit codes:
#   0 — run completed (verdict may be "accepted" or "rejected"; see result.json)
#   1 — usage or pre-flight error
#   2 — --resume and the run is incomplete
#
# Boundaries: MUST NOT push, open a PR, merge, or write outside operator/.runs/
# and its own worktree. Slice 1a stops at result.json.
#
# Environment:
#   RUN_ROOT  override run-directory root (default: operator/.runs)
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/operator/.runs}"

# ---- argument parsing ------------------------------------------------------
WO_FILE="${1:-}"
RESUME=false
[ "${2:-}" = "--resume" ] && RESUME=true

if [ -z "$WO_FILE" ]; then
  echo "Usage: bash operator/run.sh <work-order.json> [--resume]" >&2
  exit 1
fi

# Resolve to absolute path early so cd below doesn't break it
case "$WO_FILE" in
  /*) ;; # already absolute
  *)  WO_FILE="$REPO_ROOT/$WO_FILE" ;;
esac

if [ ! -f "$WO_FILE" ]; then
  echo "FATAL: work order file not found: $WO_FILE" >&2
  exit 1
fi

# ---- helpers ---------------------------------------------------------------
utc_ts() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# _event_append <json_line> — append and fsync immediately
_event_append() {
  python3 -c "
import os, sys
line = sys.argv[1] + '\n'
f = open('$EVENTS_FILE', 'a')
f.write(line)
f.flush()
os.fsync(f.fileno())
f.close()
" "$1"
}

_wo_field() {
  python3 -c "import json,sys; print(json.load(open('$WO_FILE'))[sys.argv[1]])" "$1"
}

_wo_array_lines() {
  python3 -c "
import json,sys
for item in json.load(open('$WO_FILE'))[sys.argv[1]]:
    print(item)
" "$1"
}

# ---- cleanup trap ----------------------------------------------------------
_cleanup_worktree() {
  if [ -n "${_WT_CREATED:-}" ] && [ -n "${WORKTREE:-}" ]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
  fi
}

# ---- --resume mode ---------------------------------------------------------
if $RESUME; then
  WO_ID=$(_wo_field "work_order_id")
  RUN_DIR="$RUN_ROOT/$WO_ID"
  EVENTS_FILE="$RUN_DIR/events.jsonl"

  if [ ! -f "$EVENTS_FILE" ]; then
    echo "FATAL: no events file found at $EVENTS_FILE — nothing to resume" >&2
    exit 1
  fi

  LAST_LINE="$(tail -1 "$EVENTS_FILE")"
  LAST_EVENT="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['event'])" "$LAST_LINE" 2>/dev/null || echo "unknown")"
  LAST_TS="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('ts','?'))" "$LAST_LINE" 2>/dev/null || echo "?")"

  if grep -q '"run_finished"' "$EVENTS_FILE" 2>/dev/null; then
    echo "COMPLETE: last event $LAST_EVENT at $LAST_TS"
    exit 0
  else
    echo "INCOMPLETE: last event $LAST_EVENT at $LAST_TS"
    exit 2
  fi
fi

# ---- pre-flight: cd to repo root -------------------------------------------
cd "$REPO_ROOT"

# ---- step 1: validate work order against schema ----------------------------
SCHEMA="$REPO_ROOT/schemas/work-order.json"

python3 -c "
import json, sys, re

with open('$SCHEMA') as f:
    schema = json.load(f)
with open('$WO_FILE') as f:
    data = json.load(f)

errs = []

# required fields
if 'required' in schema:
    for field in schema['required']:
        if field not in data:
            errs.append('MISSING required field: {}'.format(field))

# additionalProperties
if schema.get('additionalProperties') is False:
    allowed = set(schema.get('properties', {}).keys())
    for key in data:
        if key not in allowed:
            errs.append('UNKNOWN field: {}'.format(key))

# property checks
if 'properties' in schema:
    for pname, pschema in schema['properties'].items():
        if pname not in data:
            continue
        val = data[pname]

        # type check
        ptype = pschema.get('type')
        if ptype == 'string' and not isinstance(val, str):
            errs.append('TYPE violation: {} must be string'.format(pname))
        elif ptype == 'integer' and not isinstance(val, int):
            errs.append('TYPE violation: {} must be integer'.format(pname))
        elif ptype == 'array' and not isinstance(val, list):
            errs.append('TYPE violation: {} must be array'.format(pname))

        # pattern check
        if 'pattern' in pschema and isinstance(val, str):
            if not re.match(pschema['pattern'], val):
                errs.append('PATTERN violation: {}={} does not match {}'.format(pname, val, pschema['pattern']))

        # enum check
        if 'enum' in pschema and val not in pschema['enum']:
            errs.append('ENUM violation: {}={} not in {}'.format(pname, val, pschema['enum']))

        # minItems check
        if 'minItems' in pschema and isinstance(val, list):
            if len(val) < pschema['minItems']:
                errs.append('MINITEMS violation: {} has {} items, need {}'.format(pname, len(val), pschema['minItems']))

        # array item type check
        if 'items' in pschema and isinstance(val, list):
            itype = pschema['items'].get('type')
            for i, item in enumerate(val):
                if itype == 'string' and not isinstance(item, str):
                    errs.append('TYPE violation: {}[{}] must be string'.format(pname, i))

if errs:
    for e in errs:
        print('VALIDATION ERROR: {}'.format(e), file=sys.stderr)
    sys.exit(1)

print('VALID')
sys.exit(0)
" 2>&1 || {
  echo "FATAL: work order validation failed" >&2
  exit 1
}

# ---- extract work order fields ----------------------------------------------
WO_ID=$(_wo_field "work_order_id")
ISSUE=$(_wo_field "issue")
BASE_SHA=$(_wo_field "base_sha")
BUILDER=$(_wo_field "builder")

RUN_DIR="$RUN_ROOT/$WO_ID"
EVENTS_FILE="$RUN_DIR/events.jsonl"
RESULT_FILE="$RUN_DIR/result.json"

# ---- step 2: create run dir -------------------------------------------------
mkdir -p "$RUN_DIR"
> "$EVENTS_FILE"

# ---- record event: run_started ----------------------------------------------
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'run_started',
    'work_order_id': '$WO_ID',
    'issue': $ISSUE,
    'base_sha': '$BASE_SHA',
    'builder': '$BUILDER'
}, separators=(',', ':')))
")"

# ---- step 3: git worktree add (idempotent) ----------------------------------
WORKTREE="$RUN_DIR/wt"

# Prune stale registrations first, then remove any existing worktree at this path
git worktree prune 2>/dev/null || true
if git worktree list --porcelain 2>/dev/null | grep -q "worktree $(cd "$RUN_DIR" 2>/dev/null && pwd -P)/wt$"; then
  git worktree remove --force "$WORKTREE" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi
if [ -d "$WORKTREE" ]; then
  rm -rf "$WORKTREE"
fi

git worktree add --detach "$WORKTREE" "$BASE_SHA" >/dev/null 2>&1 || {
  echo "FATAL: failed to create worktree at $WORKTREE for sha $BASE_SHA" >&2
  exit 1
}
_WT_CREATED=1
trap _cleanup_worktree EXIT

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'worktree_created',
    'path': '$WORKTREE'
}, separators=(',', ':')))
")"

# ---- step 4: before snapshot ------------------------------------------------
python3 -c "
import json, hashlib, os, subprocess, sys
wt = '$WORKTREE'
os.chdir(wt)
out = subprocess.check_output(['git', 'ls-files'], text=True)
files = [f for f in out.strip().split('\n') if f]
snap = {}
for f in sorted(files):
    p = os.path.join(wt, f)
    if os.path.isfile(p):
        snap[f] = hashlib.sha256(open(p, 'rb').read()).hexdigest()
with open('$RUN_DIR/before_snapshot.json', 'w') as fh:
    json.dump(snap, fh, indent=2, sort_keys=True)
"

SNAP_COUNT=$(python3 -c "import json; print(len(json.load(open('$RUN_DIR/before_snapshot.json'))))")

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'before_snapshot',
    'file_count': $SNAP_COUNT
}, separators=(',', ':')))
")"

# ---- step 5: invoke builder -------------------------------------------------
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_started'
}, separators=(',', ':')))
")"

BUILDER_STDOUT_FILE="$RUN_DIR/builder_stdout.txt"
BUILDER_STDERR_FILE="$RUN_DIR/builder_stderr.txt"

set +o errexit
"$BUILDER" "$WORKTREE" >"$BUILDER_STDOUT_FILE" 2>"$BUILDER_STDERR_FILE"
BUILDER_EXIT=$?
set -o errexit

# Parse builder's reported outcome — we do NOT trust this
REPORTED_OUTCOME="$(python3 -c "
import json, sys
try:
    d = json.load(open('$BUILDER_STDOUT_FILE'))
    print(d.get('outcome', 'failed'))
except:
    print('failed')
" 2>/dev/null)"

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_finished',
    'exit_status': $BUILDER_EXIT,
    'reported_outcome': '$REPORTED_OUTCOME'
}, separators=(',', ':')))
")"

# ---- step 6: compute changed paths ------------------------------------------
CHANGED_PATHS_FILE="$RUN_DIR/changed_paths.txt"

{
  # Unstaged/staged working-tree changes
  git -C "$WORKTREE" status --porcelain 2>/dev/null | while IFS= read -r line; do
    echo "$line" | sed -n 's/^.. //p' | sed 's/.* -> //'
  done
  # Committed changes vs base_sha
  git -C "$WORKTREE" diff --name-only "$BASE_SHA" 2>/dev/null
} | sort -u > "$CHANGED_PATHS_FILE"

# ---- step 7: path enforcement -----------------------------------------------
# Use python3 for clean path checking — forbidden wins over allowed
PATH_CHECK_RESULT="$(python3 -c "
import json, sys

with open('$CHANGED_PATHS_FILE') as f:
    changed = [l.strip() for l in f if l.strip()]

with open('$WO_FILE') as f:
    wo = json.load(f)

allowed = wo['allowed_paths']
forbidden = wo['forbidden_paths']

violations = []
forbidden_hits = []

for p in changed:
    is_allowed = any(p.startswith(prefix) for prefix in allowed)
    is_forbidden = any(p.startswith(prefix) for prefix in forbidden)

    if is_forbidden:
        violations.append(p)
        forbidden_hits.append(p)
    elif not is_allowed:
        violations.append(p)

print(json.dumps({
    'changed_count': len(changed),
    'violations': violations,
    'forbidden_hits': forbidden_hits
}))
")"

# Also write to a file for safe reading in the result builder
echo "$PATH_CHECK_RESULT" > "$RUN_DIR/path_check_result.json"

CHANGED_COUNT=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['changed_count'])" "$PATH_CHECK_RESULT")
VIOLATION_JSON=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])['violations']))" "$PATH_CHECK_RESULT")
FORBIDDEN_JSON=$(python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1])['forbidden_hits']))" "$PATH_CHECK_RESULT")

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'paths_checked',
    'changed_count': $CHANGED_COUNT,
    'violations': $VIOLATION_JSON,
    'forbidden_hits': $FORBIDDEN_JSON
}, separators=(',', ':')))
")"

# ---- step 8: acceptance commands --------------------------------------------
ACCEPTANCE_COMMANDS_FILE="$RUN_DIR/acceptance_commands.txt"
_wo_array_lines "acceptance_commands" > "$ACCEPTANCE_COMMANDS_FILE"

CMD_COUNT=$(wc -l < "$ACCEPTANCE_COMMANDS_FILE" | tr -d ' ')

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'acceptance_started',
    'command_count': $CMD_COUNT
}, separators=(',', ':')))
")"

ACCEPTANCE_EXITS_FILE="$RUN_DIR/acceptance_exits.txt"
> "$ACCEPTANCE_EXITS_FILE"

IDX=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue

  set +o errexit
  (cd "$WORKTREE" && eval "$cmd") >/dev/null 2>&1
  CMD_EXIT=$?
  set -o errexit

  echo "$CMD_EXIT" >> "$ACCEPTANCE_EXITS_FILE"

  ESCAPED_CMD=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$cmd")

  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'acceptance_command_finished',
    'index': $IDX,
    'command': $ESCAPED_CMD,
    'exit_status': $CMD_EXIT
}, separators=(',', ':')))
")"
  IDX=$((IDX + 1))
done < "$ACCEPTANCE_COMMANDS_FILE"

# ---- step 9: verdict --------------------------------------------------------
# The rules that matter:
# verdict = "accepted" only if builder exited 0, reported "completed",
#           every changed path is permitted, and every acceptance command exited 0.
# verdict = "rejected" if builder claim is contradicted by any observable fact.

BUILDER_EXIT_OK=false
[ "$BUILDER_EXIT" -eq 0 ] && BUILDER_EXIT_OK=true

PATHS_OK=false
VIOLATION_COUNT=$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['violations']))" "$PATH_CHECK_RESULT")
[ "$VIOLATION_COUNT" -eq 0 ] && PATHS_OK=true

ACCEPTANCE_OK=true
while IFS= read -r ex; do
  [ -z "$ex" ] && continue
  [ "$ex" -ne 0 ] && ACCEPTANCE_OK=false
done < "$ACCEPTANCE_EXITS_FILE"

BUILDER_COMPLETED=false
[ "$REPORTED_OUTCOME" = "completed" ] && BUILDER_COMPLETED=true

VERDICT="rejected"
if $BUILDER_EXIT_OK && $BUILDER_COMPLETED && $PATHS_OK && $ACCEPTANCE_OK; then
  VERDICT="accepted"
fi

BUILDER_CLAIM_CONTRADICTED=false
if $BUILDER_COMPLETED && [ "$VERDICT" = "rejected" ]; then
  BUILDER_CLAIM_CONTRADICTED=true
fi

# Build contradiction reason
CONTRADICTION_REASON=""
$BUILDER_CLAIM_CONTRADICTED && {
  PARTS=""
  ! $BUILDER_EXIT_OK && PARTS="$PARTS builder exited $BUILDER_EXIT (non-zero);"
  ! $PATHS_OK && {
    VLIST=$(python3 -c "import json,sys; print(', '.join(json.loads(sys.argv[1])['violations']))" "$PATH_CHECK_RESULT")
    PARTS="$PARTS changed paths outside allowed boundaries: $VLIST;"
  }
  ! $ACCEPTANCE_OK && {
    FCMDS=""
    IDX2=0
    while IFS= read -r cmd2; do
      [ -z "$cmd2" ] && continue
      EXVAL=$(sed -n "$((IDX2 + 1))p" "$ACCEPTANCE_EXITS_FILE" 2>/dev/null || echo "?")
      [ "$EXVAL" != "0" ] && FCMDS="$FCMDS [$cmd2] exited $EXVAL;"
      IDX2=$((IDX2 + 1))
    done < "$ACCEPTANCE_COMMANDS_FILE"
    PARTS="$PARTS acceptance commands failed:$FCMDS;"
  }
  CONTRADICTION_REASON="Builder reported 'completed' but the run contradicted this:${PARTS}"
}

BCC_PYTHON="False"
$BUILDER_CLAIM_CONTRADICTED && BCC_PYTHON="True"

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'verdict',
    'verdict': '$VERDICT',
    'builder_claim_contradicted': $BCC_PYTHON
}, separators=(',', ':')))
")"

# ---- step 10: remove worktree; write result.json ----------------------------
git worktree remove --force "$WORKTREE" 2>/dev/null || true
git worktree prune 2>/dev/null || true
_WT_CREATED=""

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'worktree_removed',
    'path': '$WORKTREE'
}, separators=(',', ':')))
")"

# Build result.json using python3 — the only safe way to compose JSON
ESCAPED_REASON=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$CONTRADICTION_REASON")

python3 -c "
import json

wo = json.load(open('$WO_FILE'))

# Parse path check result from file (avoids quote-embedding issues)
pcr = json.load(open('$RUN_DIR/path_check_result.json'))

# Read acceptance exits
acc_exits = []
with open('$ACCEPTANCE_EXITS_FILE') as f:
    for line in f:
        line = line.strip()
        if line:
            acc_exits.append(int(line))

# Read changed paths
changed = []
with open('$CHANGED_PATHS_FILE') as f:
    for line in f:
        line = line.strip()
        if line:
            changed.append(line)

result = {
    'work_order_id': wo['work_order_id'],
    'issue': wo['issue'],
    'base_sha': wo['base_sha'],
    'verdict': '$VERDICT',
    'builder_exit_status': $BUILDER_EXIT,
    'builder_reported_outcome': '$REPORTED_OUTCOME',
    'changed_paths': changed,
    'path_violations': pcr['violations'],
    'forbidden_hits': pcr['forbidden_hits'],
    'acceptance_results': [
        {'command': cmd, 'exit_status': acc_exits[i] if i < len(acc_exits) else -1}
        for i, cmd in enumerate(wo['acceptance_commands'])
    ],
    'events_file': 'events.jsonl'
}

if $BCC_PYTHON:
    result['builder_claim_contradicted'] = True
    result['builder_claim_contradicted_reason'] = $ESCAPED_REASON

with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2, sort_keys=True)
"

# ---- final event: run_finished ----------------------------------------------
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'run_finished'
}, separators=(',', ':')))
")"

# ---- report -----------------------------------------------------------------
echo "Run $WO_ID: verdict=$VERDICT"
if $BUILDER_CLAIM_CONTRADICTED; then
  echo "  builder_claim_contradicted: true"
fi
echo "  result: $RESULT_FILE"
echo "  events: $EVENTS_FILE"
exit 0
