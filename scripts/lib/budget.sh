#!/usr/bin/env bash
# budget.sh — Size-budget enforcement for federation-recon runs.
#
# Source after helpers.sh. Provides:
#   budget_init, budget_track, budget_checkpoint, budget_summary
#
# Adopted budgets (per founding-decision-record.md):
#   WARN_THRESHOLD  = 256000 bytes (250 KB)
#   HARD_ABORT      = 1048576 bytes (1 MB)
#   No silent deletion to make a run appear successful.
#   Budget breach fails the run and creates a self-Finding.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WARN_THRESHOLD=${RECON_BUDGET_WARN:-256000}
HARD_ABORT=${RECON_BUDGET_ABORT:-1048576}

BUDGET_TRACKED_FILES=""
BUDGET_TOTAL_BYTES=0
BUDGET_CHECKPOINTS=""

# budget_init — start tracking a set of output directories
budget_init() {
  BUDGET_TRACKED_FILES=""
  BUDGET_TOTAL_BYTES=0
  BUDGET_CHECKPOINTS=""
  log "Budget: warn at ${WARN_THRESHOLD}B, hard abort at ${HARD_ABORT}B"
}

# budget_track <file> — add a file to the budget tracker
budget_track() {
  local f="$1"
  if [ -f "$f" ]; then
    local size
    # Cross-platform stat: try macOS (-f), Linux (-c), fallback wc
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null)
    size=${size:-0}
    BUDGET_TOTAL_BYTES=$(( BUDGET_TOTAL_BYTES + size ))
    BUDGET_TRACKED_FILES="$BUDGET_TRACKED_FILES $f"
  fi
}

# budget_track_dir <dir> — add all files in a directory (recursive)
budget_track_dir() {
  local dir="$1"
  if [ -d "$dir" ]; then
    while IFS= read -r -d '' f; do
      budget_track "$f"
    done < <(find "$dir" -type f -print0 2>/dev/null || true)
  fi
}

# budget_checkpoint [label] — check budget thresholds, report current size
budget_checkpoint() {
  local label="${1:-checkpoint}"
  BUDGET_CHECKPOINTS="$BUDGET_CHECKPOINTS [${label}:${BUDGET_TOTAL_BYTES}]"
  log "Budget (${label}): ${BUDGET_TOTAL_BYTES}B total"

  if [ "$BUDGET_TOTAL_BYTES" -ge "$HARD_ABORT" ]; then
    die "BUDGET BREACH: ${BUDGET_TOTAL_BYTES}B >= ${HARD_ABORT}B hard limit — run aborted."
  fi

  if [ "$BUDGET_TOTAL_BYTES" -ge "$WARN_THRESHOLD" ]; then
    warn "BUDGET WARNING: ${BUDGET_TOTAL_BYTES}B >= ${WARN_THRESHOLD}B warn threshold"
  fi
}

# budget_summary — emit budget summary as JSON
budget_summary() {
  local breached="false"
  [ "$BUDGET_TOTAL_BYTES" -ge "$HARD_ABORT" ] && breached="true"
  local warned="false"
  [ "$BUDGET_TOTAL_BYTES" -ge "$WARN_THRESHOLD" ] && warned="true"

  cat <<ENDJSON
{
  "total_bytes": $BUDGET_TOTAL_BYTES,
  "warn_threshold": $WARN_THRESHOLD,
  "hard_abort": $HARD_ABORT,
  "warned": $warned,
  "breached": $breached,
  "checkpoints": $(json_val "$BUDGET_CHECKPOINTS")
}
ENDJSON
}
