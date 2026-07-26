#!/usr/bin/env bash
# state-gate.sh — Scheduled run state gate wrapper.
#
# Fetches scheduled workflow history via gh, then delegates to the library.
# In LOGGING MODE (default), prints the verdict and exits 0 regardless.
# With --enforce, exits with the library's return code.
#
# Usage:
#   bash scripts/state-gate.sh [--workflow <file>] [--enforce]
#
# Environment:
#   STATE_GATE_FIXTURE — path to a JSON fixture file; bypasses gh entirely.

set -uo pipefail
cd "$(dirname "$0")/.."

WORKFLOW="node-census.yml"
ENFORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --enforce)  ENFORCE=true; shift ;;
    *) echo "Usage: $0 [--workflow <file>] [--enforce]" >&2; exit 2 ;;
  esac
done

# shellcheck disable=SC1091
source "$(dirname "$0")/lib/state-gate.sh"

HISTORY_FILE=""

if [[ -n "${STATE_GATE_FIXTURE:-}" ]]; then
  HISTORY_FILE="$STATE_GATE_FIXTURE"
elif command -v gh >/dev/null 2>&1; then
  HISTORY_FILE="$(mktemp)"
  gh run list --workflow="$WORKFLOW" --event=schedule \
    --json conclusion,databaseId,createdAt,status,event \
    > "$HISTORY_FILE" 2>/dev/null || {
    rm -f "$HISTORY_FILE"
    echo "STATE: UNKNOWN - gh failed to fetch workflow history" >&2
    exit 2
  }
else
  echo "STATE: UNKNOWN - gh is required and not installed" >&2
  exit 2
fi

check_scheduled_run_state "$HISTORY_FILE" "$WORKFLOW"
rc=$?

if [[ -z "${STATE_GATE_FIXTURE:-}" ]]; then
  rm -f "$HISTORY_FILE"
fi

if $ENFORCE; then
  exit $rc
else
  exit 0
fi
