#!/usr/bin/env bash
# fake.sh — Deliberately controllable fake builder for Slice 1a.
#
# Invoked as: fake.sh <worktree_path>
#
# Behaviour driven entirely by environment variables so tests can make it misbehave:
#   FAKE_TOUCH_FILE   path relative to worktree; append a line to it. Default: operator/.fake-marker
#   FAKE_OUTCOME      what the builder REPORTS: completed | failed. Default: completed
#   FAKE_EXIT         exit status. Default: 0
#
# Writes its report as JSON to stdout: {"outcome": "<FAKE_OUTCOME>", "files_changed": [...]}
# It is possible for it to report "completed" while touching a forbidden file
# and to report "completed" while the acceptance commands fail.
# Those are the cases under test — the runner must catch both mechanically.
set -o errexit -o nounset -o pipefail

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

TOUCH_FILE="${FAKE_TOUCH_FILE:-operator/.fake-marker}"
OUTCOME="${FAKE_OUTCOME:-completed}"
EXIT="${FAKE_EXIT:-0}"

FILES_CHANGED="[]"

if [ -n "$TOUCH_FILE" ]; then
  TARGET="$WORKTREE/$TOUCH_FILE"
  mkdir -p "$(dirname "$TARGET")"
  echo "fake builder touched this file at $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$TARGET"

  # Safe JSON escaping for the filename
  FILES_CHANGED="$(python3 -c "import json; print(json.dumps(['$TOUCH_FILE']))" 2>/dev/null || echo "[]")"
fi

# Use python3 for clean JSON output
python3 -c "
import json
print(json.dumps({
    'outcome': '$OUTCOME',
    'files_changed': $FILES_CHANGED
}))
" 2>/dev/null || {
  echo "{\"outcome\":\"$OUTCOME\",\"files_changed\":$FILES_CHANGED}"
}

exit "${EXIT}"
