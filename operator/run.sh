#!/usr/bin/env bash
# run.sh — Slice 1a execution layer. Invokes a builder in a detached worktree
# and independently verifies every claim it makes. The builder is assumed to be
# wrong, slow, or lying; this runner catches that mechanically.
#
# Usage:
#   bash operator/run.sh <work-order.json> [--resume]
#
# --resume CONTINUES an interrupted run. It does not merely report on one.
# Every step that recorded its completion event in the ledger is skipped and
# its result re-read from disk; the run picks up at the first step that did
# not. Acceptance commands resume per command, not per phase, so a run killed
# after the third of five commands runs exactly two.
#
# What makes this safe rather than clever: nothing is recomputed from memory.
# The ledger is append-only and fsynced per line (see _event_append), and every
# step writes its output to a file before recording that it finished. So the
# state a resumed run reads is the state the crashed run wrote, not a
# reconstruction of it. A step whose event is present but whose output file is
# missing is treated as NOT done — the event is a claim, the file is the thing.
#
# Exit codes:
#   0 — run completed (verdict may be "accepted" or "rejected"; see result.json)
#   1 — usage or pre-flight error
#   2 — --resume asked for, and the run cannot be resumed
#
# Boundaries: MUST NOT merge, and MUST NOT write outside operator/.runs/ and
# its own worktree. It may open a pull request, and only when the work order
# names a `pr_opener` and the verdict is "accepted" — #83 §23 puts "PR
# geoeffnet" inside Slice 1 and "STOP. Kein Merge." immediately after it.
#
# The opener is a field rather than a hardcoded `gh pr create` because opening
# a PR is the first outward-facing act in this pipeline. A work order with no
# `pr_opener` stops at result.json, which is what every run did before the
# field existed and is still the default.
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

# _completed <event> [file …] — did this step finish, and is its output there?
#
# Both halves are load-bearing. The event alone is a claim the crashed run made
# about itself, and this repository's standing rule is that a claim is not a
# finding; a file alone cannot say whether it was complete when the process
# died. Requiring both means a step interrupted between writing its output and
# recording the event re-runs, which is the safe direction: these steps are
# idempotent, and re-running one costs time while skipping one loses work.
_completed() {
  local event="$1"; shift
  [ -f "${EVENTS_FILE:-/nonexistent}" ] || return 1
  grep -q "\"event\":\"${event}\"" "$EVENTS_FILE" || return 1
  local f
  for f in "$@"; do
    [ -s "$f" ] || return 1
  done
  return 0
}

# _skip <step> — announce a step that is not being re-run.
_skip() {
  echo "  resume: $1 already done, not re-running"
}

# ---- cleanup trap ----------------------------------------------------------
#
# On a run that finished, the worktree is removed in step 10 and this is a
# no-op. On a run that did not, the worktree is KEPT: it holds the builder's
# work, and removing it would make --resume a synonym for --restart. That is
# the difference between a ledger that records a crash and one that survives
# it.
_cleanup_worktree() {
  if [ -n "${_WT_CREATED:-}" ] && [ -n "${WORKTREE:-}" ] && [ -z "${_RUN_FINISHED:-}" ]; then
    echo "  worktree kept for --resume: $WORKTREE" >&2
    return 0
  fi
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
  fi

  echo "INCOMPLETE: last event $LAST_EVENT at $LAST_TS"
  echo "RESUMING from there — completed steps will not be re-run"
  RESUMING=true
fi
RESUMING="${RESUMING:-false}"

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
PATCH_FILE="$RUN_DIR/changes.patch"

# ---- step 2: create run dir -------------------------------------------------
mkdir -p "$RUN_DIR"

# The ledger is truncated only for a fresh run. Truncating it on resume would
# destroy the very record the resume is reading, and the second run would then
# look like a first one that had simply never got far — the failure mode being
# that a crash becomes invisible after one retry.
if ! $RESUMING; then
  > "$EVENTS_FILE"
fi

# ---- record event: run_started ----------------------------------------------
if $RESUMING; then
  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'run_resumed',
    'work_order_id': '$WO_ID'
}, separators=(',', ':')))
")"
else
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
fi

# ---- step 2b: the oracle must predate the order (#103) ----------------------
#
# `wo-98-3` was accepted by a verifier that did everything right. The work
# order's acceptance was `bats scripts/test/gate-cleanup.bats` — a file that
# did not exist when the order was written. The builder wrote it, then wrote
# code that passed it, and the acceptance confirmed that the builder agreed
# with itself.
#
# The gap was in the contract, not the machine, and this is the contract made
# executable. Two rules, and the first is the one that would have stopped it:
#
#   1. Every oracle path must exist at base_sha. A test file the builder is
#      about to write cannot be the thing that judges it.
#   2. The builder may not touch an oracle path. Checked after the run, at
#      step 7, because an oracle edited during the run is the same defect
#      arriving one step later.
#
# An order whose acceptance names a repository path and declares no oracle is
# refused. Silence is not a declaration that there is no oracle; it is the
# absence of one, and the two must not produce the same outcome.
ORACLE_PATHS_FILE="$RUN_DIR/oracle_paths.txt"
python3 -c "
import json
wo = json.load(open('$WO_FILE'))
for p in wo.get('oracle_paths', []):
    print(p)
" > "$ORACLE_PATHS_FILE"

ORACLE_COUNT=$(wc -l < "$ORACLE_PATHS_FILE" | tr -d ' ')

# Does the acceptance name a path in the repository at all?
ACCEPTANCE_NAMES_PATH=$(python3 -c "
import json, os, sys
wo = json.load(open('$WO_FILE'))
# A token that looks like a repo-relative path and exists at HEAD of the
# checkout. Crude on purpose: the question is 'might this acceptance depend on
# a file', and over-answering it costs a declaration, while under-answering it
# costs the whole check.
hit = False
for cmd in wo['acceptance_commands']:
    for tok in cmd.replace(';', ' ').replace('&&', ' ').split():
        tok = tok.strip(chr(34) + chr(39))   # quote chars by code: a literal
                                            # quote here closes the shell's
                                            # double-quoted -c argument
        if '/' in tok and not tok.startswith('-'):
            hit = True
print('yes' if hit else 'no')
")

if [ "$ACCEPTANCE_NAMES_PATH" = "yes" ] && [ "$ORACLE_COUNT" -eq 0 ]; then
  echo "FATAL: acceptance_commands name a repository path but the work order" >&2
  echo "       declares no oracle_paths. An undeclared oracle is how #103" >&2
  echo "       happened: the builder wrote the test that judged it." >&2
  exit 1
fi

if [ "$ORACLE_COUNT" -gt 0 ]; then
  MISSING=""
  while IFS= read -r op; do
    [ -z "$op" ] && continue
    if ! git cat-file -e "$BASE_SHA:$op" 2>/dev/null; then
      MISSING="${MISSING}    $op"$'\n'
    fi
  done < "$ORACLE_PATHS_FILE"

  if [ -n "$MISSING" ]; then
    echo "FATAL: these oracle paths do not exist at base_sha $BASE_SHA:" >&2
    printf '%s' "$MISSING" >&2
    echo "       An oracle the builder is about to write is not an oracle." >&2
    echo "       See #103." >&2
    _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'oracle_refused',
    'reason': 'oracle paths absent at base_sha'
}, separators=(',', ':')))
")"
    exit 1
  fi

  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'oracle_verified',
    'count': $ORACLE_COUNT
}, separators=(',', ':')))
")"
fi

# ---- step 3: git worktree add (idempotent) ----------------------------------
WORKTREE="$RUN_DIR/wt"

if $RESUMING && grep -q '"event":"worktree_removed"' "$EVENTS_FILE" 2>/dev/null; then
  # The run had already finished with the worktree and removed it. Recreating
  # it would be pure waste — and worse, it would put a clean checkout of
  # base_sha where a reader might mistake it for the builder's output. Noticed
  # while watching the kill-after-verification case rebuild 471 files it was
  # never going to look at.
  _skip "worktree (already removed by the run being resumed)"
elif $RESUMING && [ -d "$WORKTREE" ]; then
  # The builder's work is in here. Re-creating it from base_sha would discard
  # exactly what the resume exists to preserve.
  _skip "worktree"
  _WT_CREATED=1
  trap _cleanup_worktree EXIT
else
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
fi

# ---- step 4: before snapshot ------------------------------------------------
if _completed before_snapshot "$RUN_DIR/before_snapshot.json"; then
  _skip "before-snapshot"
else
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
fi

# ---- step 5: invoke builder -------------------------------------------------
BUILDER_STDOUT_FILE="$RUN_DIR/builder_stdout.txt"
BUILDER_STDERR_FILE="$RUN_DIR/builder_stderr.txt"

if _completed builder_finished "$BUILDER_STDOUT_FILE"; then
  # This is the step that must never run twice. A builder is not idempotent —
  # it appends, commits, calls a model, spends money. Its verdict is read back
  # out of the ledger it wrote at the time, not re-derived.
  _skip "builder"
  BUILDER_EXIT=$(python3 -c "
import json
for line in open('$EVENTS_FILE'):
    d = json.loads(line)
    if d['event'] == 'builder_finished':
        print(d['exit_status'])
        break
")
  REPORTED_OUTCOME=$(python3 -c "
import json
for line in open('$EVENTS_FILE'):
    d = json.loads(line)
    if d['event'] == 'builder_finished':
        print(d['reported_outcome'])
        break
")
else
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_started'
}, separators=(',', ':')))
")"

set +o errexit
# RUN_DIR is exported, not merely set. The adapter writes its provider record
# and its usage evidence there, and falls back to a temp directory it then
# deletes when the variable is absent — which was every run until now (#160).
WORK_ORDER="$WO_FILE" RUN_DIR="$RUN_DIR" \
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

# ── the resolved provider goes in the ledger ──────────────────────────────
#
# Written from what the probe MEASURED, not from what the work order asked
# for. A run whose provider cannot be established is refused here as well as
# in the adapter — two independent points, because the adapter is the thing
# being audited and a control inside the audited component is the weaker half.
PROVIDER_RECORD="$RUN_DIR/builder_provider.txt"
if [ -f "$PROVIDER_RECORD" ]; then
  RESOLVED_PROVIDER="$(sed -n 's/^resolved_provider:[[:space:]]*//p' "$PROVIDER_RECORD" | head -1)"
  RESOLVED_PMODEL="$(sed -n 's/^resolved_model:[[:space:]]*//p' "$PROVIDER_RECORD" | head -1)"
  PROVIDER_VERDICT="$(sed -n 's/^verdict:[[:space:]]*//p' "$PROVIDER_RECORD" | head -1)"
else
  RESOLVED_PROVIDER="undetermined"
  RESOLVED_PMODEL="undetermined"
  PROVIDER_VERDICT="no record written"
fi

ESCAPED_PROV=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$RESOLVED_PROVIDER")
ESCAPED_PMOD=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$RESOLVED_PMODEL")
ESCAPED_PVER=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PROVIDER_VERDICT")
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_provider',
    'resolved_provider': $ESCAPED_PROV,
    'resolved_model': $ESCAPED_PMOD,
    'verdict': $ESCAPED_PVER
}, separators=(',', ':')))
")"

if [ "$PROVIDER_VERDICT" != "match" ]; then
  echo "FATAL: the builder's provider was not established as the one requested." >&2
  echo "       verdict: $PROVIDER_VERDICT (resolved: $RESOLVED_PROVIDER)" >&2
  echo "       A run billed to a provider nobody chose is not a run. See #159." >&2
  BUILDER_EXIT=1
  REPORTED_OUTCOME="failed"
fi

# ── the cost record goes in the ledger, and its absence fails the run ─────
#
# #160: a run has to be able to say what it cost and where. The record names
# the provider, the model, the call count, and — explicitly — the figures the
# tool redacts, because an empty field reads as zero and zero is a
# measurement while "unavailable" is not.
COST_RECORD="$RUN_DIR/builder_cost.txt"
if [ -f "$COST_RECORD" ]; then
  COST_PROVIDER="$(sed -n 's/^run_provider:[[:space:]]*//p' "$COST_RECORD" | head -1)"
  COST_MODEL="$(sed -n 's/^run_model:[[:space:]]*//p' "$COST_RECORD" | head -1)"
  COST_CALLS="$(sed -n 's/^api_calls:[[:space:]]*//p' "$COST_RECORD" | head -1)"
else
  COST_PROVIDER=""
  COST_MODEL=""
  COST_CALLS=""
fi

ESCAPED_CP=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${COST_PROVIDER:-missing}")
ESCAPED_CM=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${COST_MODEL:-missing}")
ESCAPED_CC=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "${COST_CALLS:-missing}")
_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_cost',
    'provider': $ESCAPED_CP,
    'model': $ESCAPED_CM,
    'api_calls': $ESCAPED_CC,
    'record': 'builder_cost.txt'
}, separators=(',', ':')))
")"

if [ ! -f "$COST_RECORD" ] || [ -z "$COST_PROVIDER" ] || [ -z "$COST_MODEL" ]; then
  echo "FATAL: no cost record for this run — it cannot say what it spent or where." >&2
  echo "       expected $COST_RECORD with run_provider and run_model." >&2
  echo "       A run without a cost record is not complete. See #160." >&2
  BUILDER_EXIT=1
  REPORTED_OUTCOME="failed"
fi

_event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'builder_finished',
    'exit_status': $BUILDER_EXIT,
    'reported_outcome': '$REPORTED_OUTCOME'
}, separators=(',', ':')))
")"
fi

# ---- step 6: compute changed paths ------------------------------------------
CHANGED_PATHS_FILE="$RUN_DIR/changed_paths.txt"

if _completed paths_checked "$CHANGED_PATHS_FILE" "$RUN_DIR/path_check_result.json"; then
  _skip "path check"
  PATH_CHECK_RESULT="$(cat "$RUN_DIR/path_check_result.json")"
else
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

# ── the builder may not touch its own oracle (#103, second form) ──────────
#
# Declaring an oracle that exists and then rewriting it during the run is the
# same defect one step later: the acceptance still ends up judging the builder
# against something the builder chose.
ORACLE_TOUCHED=$(python3 -c "
import json
changed = set()
with open('$CHANGED_PATHS_FILE') as f:
    changed = {l.strip() for l in f if l.strip()}
oracle = set()
with open('$ORACLE_PATHS_FILE') as f:
    oracle = {l.strip() for l in f if l.strip()}
hits = sorted(changed & oracle)
print(json.dumps(hits))
")

PATH_CHECK_RESULT=$(python3 -c "
import json, sys
pcr = json.loads(sys.argv[1])
hits = json.loads(sys.argv[2])
pcr['oracle_touched'] = hits
if hits:
    # A touched oracle is a path violation, so the existing verdict rule
    # rejects the run without a second mechanism deciding the same thing.
    for h in hits:
        if h not in pcr['violations']:
            pcr['violations'].append(h)
print(json.dumps(pcr))
" "$PATH_CHECK_RESULT" "$ORACLE_TOUCHED")

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
fi

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

# Resume granularity is the command, not the phase. A run killed after the
# third of five acceptance commands must run exactly two, and the three
# already-recorded exit statuses must survive — they are what the verdict is
# computed from, and re-running them would ask a different question of a
# worktree that has since changed.
DONE_COUNT=0
if $RESUMING && [ -f "$ACCEPTANCE_EXITS_FILE" ]; then
  DONE_COUNT=$(grep -c '"event":"acceptance_command_finished"' "$EVENTS_FILE" || true)
  RECORDED=$(wc -l < "$ACCEPTANCE_EXITS_FILE" | tr -d ' ')
  # The file and the ledger must agree. If they do not, the crash landed
  # between the two writes and the honest move is to trust neither: fall back
  # to whichever is smaller, so a command runs twice rather than not at all.
  if [ "$RECORDED" -lt "$DONE_COUNT" ]; then
    DONE_COUNT="$RECORDED"
  fi
  # `head -n 0` is an error on BSD head, not an empty result. A resume that
  # crashed before the first acceptance command took this branch with
  # DONE_COUNT=0 and died on the trim rather than on anything to do with the
  # run — found by the test for that exact case.
  if [ "$DONE_COUNT" -gt 0 ]; then
    head -n "$DONE_COUNT" "$ACCEPTANCE_EXITS_FILE" > "$ACCEPTANCE_EXITS_FILE.keep"
    mv "$ACCEPTANCE_EXITS_FILE.keep" "$ACCEPTANCE_EXITS_FILE"
    _skip "$DONE_COUNT acceptance command(s)"
  else
    > "$ACCEPTANCE_EXITS_FILE"
  fi
else
  > "$ACCEPTANCE_EXITS_FILE"
fi

IDX=0
while IFS= read -r cmd; do
  [ -z "$cmd" ] && continue

  if [ "$IDX" -lt "$DONE_COUNT" ]; then
    IDX=$((IDX + 1))
    continue
  fi

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

# ---- step 9.5: save patch ----------------------------------------------------
# Stage everything in the worktree so new files are captured, then produce a
# patch against base_sha that is applicable with `git apply`.  If the patch
# cannot be produced or written the run becomes rejected, because a verified
# contribution nobody can see afterwards is worthless.
#
# On resume this step MUST be skipped once it has run, and the reason is not
# efficiency. The worktree is removed at step 10; a resume that recomputed the
# patch afterwards would diff a worktree that is gone, or — worse, and this is
# what actually happened — diff a clean checkout of base_sha that the resume
# had helpfully rebuilt, and write an EMPTY patch over the real one. The run
# then reports accepted with the builder's work silently discarded. Found by
# the test for resuming after the worktree was removed, and only because
# rebuilding the worktree was fixed first: the rebuild was hiding it.
if _completed patch_saved "$PATCH_FILE" || \
   { grep -q '"event":"patch_saved"' "$EVENTS_FILE" 2>/dev/null && [ -f "$PATCH_FILE" ]; }; then
  _skip "patch"
  PATCH_OK=true
  PATCH_ERROR=""
else
set +o errexit
PATCH_OUTCOME=$(python3 -c "
import json, subprocess, os, sys

wt = '$WORKTREE'
base_sha = '$BASE_SHA'
patch_file = '$PATCH_FILE'

# Stage all changes including new files
add = subprocess.run(['git', '-C', wt, 'add', '-A'],
                     capture_output=True, text=True)
if add.returncode != 0:
    print(json.dumps({
        'ok': False,
        'error': 'git add -A exit {}: {}'.format(
            add.returncode, add.stderr.strip()[:300])
    }))
    sys.exit(0)

# Produce the diff against base_sha
try:
    with open(patch_file, 'w') as fh:
        diff = subprocess.run(
            ['git', '-C', wt, 'diff', '--cached', base_sha],
            stdout=fh, stderr=subprocess.PIPE, text=True)
        if diff.returncode != 0:
            print(json.dumps({
                'ok': False,
                'error': 'git diff exit {}: {}'.format(
                    diff.returncode, diff.stderr.strip()[:300])
            }))
            sys.exit(0)
except OSError as e:
    print(json.dumps({
        'ok': False,
        'error': 'cannot write patch: {}'.format(str(e))
    }))
    sys.exit(0)

sz = os.path.getsize(patch_file)
print(json.dumps({'ok': True, 'size_bytes': sz}))
")
PATCH_EXIT=$?
set -o errexit

PATCH_OK=false
PATCH_ERROR=""

if [ "$PATCH_EXIT" -ne 0 ]; then
  PATCH_ERROR="internal error producing patch (python3 exit $PATCH_EXIT)"
else
  OK_VALUE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['ok'])" "$PATCH_OUTCOME")
  if [ "$OK_VALUE" = "True" ]; then
    PATCH_OK=true
    PATCH_SIZE=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['size_bytes'])" "$PATCH_OUTCOME")
  else
    PATCH_ERROR=$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['error'])" "$PATCH_OUTCOME")
  fi
fi

if ! $PATCH_OK; then
  VERDICT="rejected"
  # Update contradiction state to reflect the new verdict
  if $BUILDER_COMPLETED; then
    BUILDER_CLAIM_CONTRADICTED=true
    if [ -n "$CONTRADICTION_REASON" ]; then
      CONTRADICTION_REASON="${CONTRADICTION_REASON} patch save failed: ${PATCH_ERROR}"
    else
      CONTRADICTION_REASON="Builder reported 'completed' but patch save failed: ${PATCH_ERROR}"
    fi
  fi
  BCC_PYTHON="False"
  $BUILDER_CLAIM_CONTRADICTED && BCC_PYTHON="True"
fi

fi   # end of the "patch not already saved" branch

# Emit patch_saved event — unless the resume skipped the step, in which case
# the event is already in the ledger.
#
# The first attempt at this guard put the condition on the `if` alone, so a
# resume fell into the `else` and appended a patch_saved marked FAILED next to
# the successful one. A guard that redirects into the failure branch is worse
# than no guard: it reports a defect that did not happen.
if grep -q '"event":"patch_saved"' "$EVENTS_FILE" 2>/dev/null; then
  :
elif $PATCH_OK; then
  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'patch_saved',
    'size_bytes': $PATCH_SIZE
}, separators=(',', ':')))
")"
else
  ESCAPED_PERR=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PATCH_ERROR")
  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'patch_saved',
    'status': 'failed',
    'reason': $ESCAPED_PERR
}, separators=(',', ':')))
")"
fi

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

PATCH_OK_PYTHON="False"
$PATCH_OK && PATCH_OK_PYTHON="True"

ESCAPED_PATCH_ERROR="null"
if [ -n "$PATCH_ERROR" ]; then
  ESCAPED_PATCH_ERROR=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PATCH_ERROR")
fi

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
    'patch_path': 'changes.patch',
    'events_file': 'events.jsonl'
}

if $BCC_PYTHON:
    result['builder_claim_contradicted'] = True
    result['builder_claim_contradicted_reason'] = $ESCAPED_REASON

if not $PATCH_OK_PYTHON:
    result['patch_error'] = $ESCAPED_PATCH_ERROR

with open('$RESULT_FILE', 'w') as f:
    json.dump(result, f, indent=2, sort_keys=True)
"

# ---- step 11: open the pull request -----------------------------------------
#
# Only on an accepted verdict, only when the work order names an opener, and
# resumable like every other step. A rejected run has nothing to propose.
PR_OPENER="$(python3 -c "
import json
print(json.load(open('$WO_FILE')).get('pr_opener', ''))
")"
PR_REF_FILE="$RUN_DIR/pr_ref.txt"

if [ -z "$PR_OPENER" ]; then
  :
elif [ "$VERDICT" != "accepted" ]; then
  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'pr_skipped',
    'reason': 'verdict is $VERDICT, not accepted'
}, separators=(',', ':')))
")"
elif _completed pr_opened "$PR_REF_FILE"; then
  # The one step where re-running is not merely wasteful: a second invocation
  # opens a second pull request, and nothing downstream would notice.
  _skip "pull request"
else
  _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'pr_started'
}, separators=(',', ':')))
")"

  set +o errexit
  "$PR_OPENER" "$RUN_DIR" >"$PR_REF_FILE" 2>"$RUN_DIR/pr_stderr.txt"
  PR_EXIT=$?
  set -o errexit

  PR_REF="$(head -1 "$PR_REF_FILE" 2>/dev/null || true)"

  # An opener that exits 0 while printing nothing has not opened anything, and
  # a run that recorded pr_opened on that basis would report a PR that does not
  # exist. The measurement is the reference, not the exit status.
  if [ "$PR_EXIT" -ne 0 ] || [ -z "$PR_REF" ]; then
    ESCAPED_PR_ERR=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" \
      "opener exited $PR_EXIT, reference: ${PR_REF:-<empty>}")
    _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'pr_failed',
    'exit_status': $PR_EXIT,
    'detail': $ESCAPED_PR_ERR
}, separators=(',', ':')))
")"
    rm -f "$PR_REF_FILE"
    echo "PR NOT OPENED: opener exited $PR_EXIT, reference ${PR_REF:-<empty>}" >&2
  else
    ESCAPED_PR_REF=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PR_REF")
    _event_append "$(python3 -c "
import json
print(json.dumps({
    'ts': '$(utc_ts)',
    'event': 'pr_opened',
    'reference': $ESCAPED_PR_REF
}, separators=(',', ':')))
")"
    python3 -c "
import json
r = json.load(open('$RESULT_FILE'))
r['pr_reference'] = open('$PR_REF_FILE').read().strip()
json.dump(r, open('$RESULT_FILE', 'w'), indent=2, sort_keys=True)
"
  fi
fi

# ---- final event: run_finished ----------------------------------------------
_RUN_FINISHED=1
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
