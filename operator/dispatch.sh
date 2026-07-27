#!/usr/bin/env bash
# dispatch.sh — Explicit bridge between heartbeat.sh (decide) and run.sh (execute).
#
# Usage:
#   bash operator/dispatch.sh [--dry-run]
#
# Environment:
#   HEARTBEAT_CMD         override the heartbeat command (default: bash operator/heartbeat.sh --dry-run)
#   HEARTBEAT_RECORD_CMD  override the expert-call recording command (default: bash operator/heartbeat.sh --record-expert-call)
#   RUN_ROOT              run-directory root (default: operator/.runs, same as run.sh)
#
# Exit codes:
#   0 — nothing to execute (non-BUILD, non-STOP action) or run completed with verdict "accepted"
#   1 — usage / unexpected error / FAILED to record expert call
#   3 — BUILD action but no work-order template exists
#   4 — work order failed schema validation
#   5 — STOP action refused or run completed with verdict "rejected"
#
# Boundaries: MUST NOT push, open a PR, merge, or write outside RUN_ROOT.
set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ROOT="${RUN_ROOT:-$REPO_ROOT/operator/.runs}"
DRY_RUN=false

# ---- argument parsing ----------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      echo "Usage: bash operator/dispatch.sh [--dry-run]"
      exit 0
      ;;
    *)
      echo "dispatch: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ---- step 1: obtain the decision -----------------------------------------------
# Honour HEARTBEAT_CMD env var for testability.
HEARTBEAT_CMD="${HEARTBEAT_CMD:-bash $REPO_ROOT/operator/heartbeat.sh --dry-run}"

# Capture stdout only; stderr from heartbeat goes to our stderr.
HEARTBEAT_OUTPUT="$(eval "$HEARTBEAT_CMD" 2>/dev/null)" || true

# The decision is the line matching ^ACTION: .
ACTION_LINE="$(echo "$HEARTBEAT_OUTPUT" | grep '^ACTION:' | head -1 || true)"

if [ -z "$ACTION_LINE" ]; then
  echo "dispatch: no ACTION line found in heartbeat output" >&2
  exit 1
fi

# ---- step 2: parse the action word ---------------------------------------------
# Format: "ACTION: <WORD> <rest>"
ACTION_WORD="$(echo "$ACTION_LINE" | sed 's/^ACTION:[[:space:]]*//' | awk '{print $1}')"

# ---- step 3: non-BUILD actions ---------------------------------------------------
if [ "$ACTION_WORD" != "BUILD" ]; then
  if [ "$ACTION_WORD" = "STOP" ]; then
    echo "dispatch: refused — $ACTION_LINE"
    exit 5
  fi
  echo "dispatch: nothing to execute — decision was $ACTION_LINE"
  exit 0
fi

# ---- step 4: extract issue number, look for template ---------------------------
# Format: "ACTION: BUILD issue #N"
ISSUE_N="$(echo "$ACTION_LINE" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"

if [ -z "$ISSUE_N" ]; then
  echo "dispatch: cannot parse issue number from: $ACTION_LINE" >&2
  exit 1
fi

WORK_ORDERS_DIR="${WORK_ORDERS_DIR:-$REPO_ROOT/operator/work-orders}"
TEMPLATE="$WORK_ORDERS_DIR/${ISSUE_N}.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "dispatch: refusing to execute — no work order template at $WORK_ORDERS_DIR/${ISSUE_N}.json"
  exit 3
fi

# ---- step 5: compose the work order --------------------------------------------
# Count existing run directories for this issue to compute the run number.
N_EXISTING=0
if [ -d "$RUN_ROOT" ]; then
  for d in "$RUN_ROOT"/wo-${ISSUE_N}-*; do
    [ -d "$d" ] && N_EXISTING=$((N_EXISTING + 1))
  done
fi
RUN_N=$((N_EXISTING + 1))
WO_ID="wo-${ISSUE_N}-${RUN_N}"

BASE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

mkdir -p "$RUN_ROOT"
WO_FILE="$RUN_ROOT/${WO_ID}.json"

python3 -c "
import json

with open('$TEMPLATE') as f:
    wo = json.load(f)

# Overwrite the three fields dispatch.sh owns
wo['work_order_id'] = '$WO_ID'
wo['issue'] = $ISSUE_N
wo['base_sha'] = '$BASE_SHA'

with open('$WO_FILE', 'w') as f:
    json.dump(wo, f, indent=2)
"

# ---- validate against schema ---------------------------------------------------
SCHEMA="$REPO_ROOT/schemas/work-order.json"

VALIDATION_OUT="$(python3 -c "
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

sys.exit(0)
" 2>&1)" || {
  echo "$VALIDATION_OUT" >&2
  echo "dispatch: work order failed schema validation" >&2
  rm -f "$WO_FILE"
  exit 4
}

# ---- step 6: --dry-run — print and exit without invoking run.sh -----------------
if $DRY_RUN; then
  python3 -c "import json; print(json.dumps(json.load(open('$WO_FILE')), indent=2))"
  exit 0
fi

# ---- step 7: invoke run.sh -----------------------------------------------------
set +o errexit
bash "$REPO_ROOT/operator/run.sh" "$WO_FILE"
RUN_EXIT=$?
set -o errexit

# ---- step 7a: record expert call consumption ----------------------------------
HEARTBEAT_RECORD_CMD="${HEARTBEAT_RECORD_CMD:-bash $REPO_ROOT/operator/heartbeat.sh --record-expert-call}"

if ! eval "$HEARTBEAT_RECORD_CMD" 2>/dev/null; then
  echo "dispatch: FAILED to record expert call after a completed run"
  exit 1
fi

# Check the result to distinguish accepted from rejected.
RESULT_FILE="$RUN_ROOT/$WO_ID/result.json"

if [ -f "$RESULT_FILE" ]; then
  VERDICT="$(python3 -c "import json; print(json.load(open('$RESULT_FILE'))['verdict'])" 2>/dev/null || echo "unknown")"
  echo "dispatch: run directory: $RUN_ROOT/$WO_ID"
  if [ "$VERDICT" = "rejected" ]; then
    echo "dispatch: verdict was rejected"
    exit 5
  fi
  exit 0
fi

# If no result.json, pass through run.sh's exit status.
echo "dispatch: run directory: $RUN_ROOT/$WO_ID"
exit "$RUN_EXIT"
