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

# ---- the provider record every builder must write (#159) --------------------
#
# The runner refuses a run whose provider it cannot establish, and the fake is
# a builder like any other: it declares what served it. `fake` is the honest
# answer — no provider did — and a test that needs a substitution forces
# FAKE_PROVIDER to something else.
if [ -n "${RUN_DIR:-}" ]; then
  {
    printf 'requested_provider: %s\n' "${FAKE_REQUESTED_PROVIDER:-fake}"
    printf 'requested_model:    %s\n' "${FAKE_MODEL:-fake-builder}"
    printf 'resolved_provider:  %s\n' "${FAKE_PROVIDER:-fake}"
    printf 'resolved_model:     %s\n' "${FAKE_MODEL:-fake-builder}"
    printf 'verdict:            %s\n' "${FAKE_PROVIDER_VERDICT:-match}"
    printf 'log:                not applicable — no model was called\n'
    printf 'measured_by:        fake.sh, which is not measuring anything\n'
  } > "$RUN_DIR/builder_provider.txt"
fi

# ---- the cost record every builder must write (#160) ------------------------
#
# The fake spends nothing, and says so in the fields rather than leaving them
# blank. A blank field reads as zero, and zero is a measurement.
if [ -n "${RUN_DIR:-}" ]; then
  {
    printf 'run_provider:      %s\n' "${FAKE_PROVIDER:-fake}"
    printf 'run_model:         %s\n' "${FAKE_MODEL:-fake-builder}"
    printf 'api_calls:         0\n'
    printf 'stream_ms_total:   0\n'
    printf 'tokens:            none — no model was called\n'
    printf 'balance_before:    not applicable\n'
    printf 'balance_after:     not applicable\n'
  } > "${FAKE_COST_RECORD:-$RUN_DIR/builder_cost.txt}"
fi

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
