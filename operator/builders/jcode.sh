#!/usr/bin/env bash
# jcode.sh — Real jcode builder for Slice 1b.
#
# Invoked as: jcode.sh <worktree_path>
# Reads $WORK_ORDER from the environment (merged in #96).
#
# Writes its report as JSON to stdout: {"outcome": "...", "files_changed": [...]}
# Cost evidence (raw jcode usage before/after) goes to $RUN_DIR/builder_usage.txt
# if RUN_DIR is set, otherwise beside the work order.
#
# bash 3.2, python3, and git only. No jq.
set -o errexit -o nounset -o pipefail

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 1. Read the work order
# -----------------------------------------------------------------
if [ -z "${WORK_ORDER:-}" ] || [ ! -f "$WORK_ORDER" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# Parse work order fields with python3
WO_DATA=$(python3 -c "
import json
wo = json.load(open('$WORK_ORDER'))
print(json.dumps({
    'issue': wo['issue'],
    'allowed': ' '.join(wo['allowed_paths']),
    'forbidden': ' '.join(wo['forbidden_paths']),
    'acceptance': '; '.join(wo['acceptance_commands'])
}))
" 2>/dev/null) || {
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
}

ISSUE=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['issue'])" 2>/dev/null)
ALLOWED=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['allowed'])" 2>/dev/null)
FORBIDDEN=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['forbidden'])" 2>/dev/null)
ACCEPTANCE=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['acceptance'])" 2>/dev/null)

# -----------------------------------------------------------------
# 2. Build the prompt
# -----------------------------------------------------------------
PROMPT="You are working on issue #${ISSUE} in this repository.

You may only modify files under these paths: ${ALLOWED}

PROHIBITION: You must NOT modify any files under these paths: ${FORBIDDEN}
Do not create, edit, or delete anything under a forbidden path for any reason.
If the task requires touching a forbidden path, stop and report failure — do not proceed.

After completing your changes, run these acceptance commands from the repository root to verify your work:
${ACCEPTANCE}

Complete the task described by the issue."

# -----------------------------------------------------------------
# 3. Provider
# -----------------------------------------------------------------
PROVIDER="${JCODE_PROVIDER:-deepseek}"

# -----------------------------------------------------------------
# 4. Usage before
# -----------------------------------------------------------------
USAGE_BEFORE=$(jcode usage 2>&1 || true)

# -----------------------------------------------------------------
# 5. Invoke jcode
# -----------------------------------------------------------------
set +o errexit
JCODE_PROVIDER="$PROVIDER" jcode run --quiet -C "$WORKTREE" "$PROMPT" >/dev/null 2>&1
JCODE_EXIT=$?
set -o errexit

# -----------------------------------------------------------------
# 6. Usage after
# -----------------------------------------------------------------
USAGE_AFTER=$(jcode usage 2>&1 || true)

# -----------------------------------------------------------------
# 7. Write usage file
# -----------------------------------------------------------------
if [ -n "${RUN_DIR:-}" ]; then
  USAGE_FILE="$RUN_DIR/builder_usage.txt"
else
  USAGE_FILE="$(dirname "$WORK_ORDER")/builder_usage.txt"
fi
mkdir -p "$(dirname "$USAGE_FILE")" 2>/dev/null || true
{
  echo "=== jcode usage BEFORE ==="
  printf '%s\n' "$USAGE_BEFORE"
  echo "=== jcode usage AFTER ==="
  printf '%s\n' "$USAGE_AFTER"
} > "$USAGE_FILE"

# -----------------------------------------------------------------
# 8. If jcode failed, report failure
# -----------------------------------------------------------------
if [ "$JCODE_EXIT" -ne 0 ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 9. Determine what actually changed
# -----------------------------------------------------------------
CHANGED=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null || true)

if [ -z "$CHANGED" ]; then
  # Nothing changed — this is a failure, not a success
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# Parse porcelain output: XY filename (status at pos 0-1, space at 2, path at 3).
# Pipe the shell-captured output into python so we never call git twice.
FILES_CHANGED=$(python3 -c "
import json, sys
lines = sys.stdin.read().strip().split('\n')
files = []
for line in lines:
    line = line.rstrip('\r')
    if not line.strip():
        continue
    # porcelain v1: XY path (status in col 0-1, space in col 2, path from col 3)
    if len(line) < 4:
        continue
    path = line[3:]
    # For renames: 'old -> new' — take the new side
    if ' -> ' in path:
        path = path.split(' -> ')[-1]
    # Strip surrounding quotes from C-style quoted paths
    path = path.strip('\"')
    files.append(path)
print(json.dumps(files) if files else '[]')
" <<< "$CHANGED" 2>/dev/null || echo "[]")

# If parsing produced nothing, that's also a failure
if [ "$FILES_CHANGED" = "[]" ] || [ -z "$FILES_CHANGED" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

python3 -c "
import json
print(json.dumps({
    'outcome': 'completed',
    'files_changed': $FILES_CHANGED
}))
"

exit 0
