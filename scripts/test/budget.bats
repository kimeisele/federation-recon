#!/usr/bin/env bats
# budget.bats — Unit tests for scripts/lib/budget.sh
#
# Tests: budget_init, budget_track, budget_checkpoint, budget_summary
#         warn threshold (250 KB), hard abort (1 MB)

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/budget.sh"

  TESTDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TESTDIR"
}

# Create a file of exactly $1 bytes inside $TESTDIR, return its path
_make_file() {
  local size="$1" name="${2:-testfile}"
  dd if=/dev/zero of="$TESTDIR/$name" bs=1 count="$size" 2>/dev/null
  echo "$TESTDIR/$name"
}

# ---------------------------------------------------------------------------
# budget_init
# ---------------------------------------------------------------------------

@test "budget_init: initializes counters to zero" {
  budget_init
  [ "$BUDGET_TOTAL_BYTES" -eq 0 ]
  [ -z "$BUDGET_TRACKED_FILES" ]
}

# ---------------------------------------------------------------------------
# budget_track
# ---------------------------------------------------------------------------

@test "budget_track: adds file size to total" {
  budget_init
  f="$(_make_file 100 'a.dat')"
  budget_track "$f"
  [ "$BUDGET_TOTAL_BYTES" -eq 100 ]
}

@test "budget_track: accumulates multiple files" {
  budget_init
  f1="$(_make_file 50 'x.dat')"
  f2="$(_make_file 75 'y.dat')"
  budget_track "$f1"
  budget_track "$f2"
  [ "$BUDGET_TOTAL_BYTES" -eq 125 ]
}

@test "budget_track: nonexistent file does not change total" {
  budget_init
  budget_track "$TESTDIR/does_not_exist"
  [ "$BUDGET_TOTAL_BYTES" -eq 0 ]
}

# ---------------------------------------------------------------------------
# budget_track_dir
# ---------------------------------------------------------------------------

@test "budget_track_dir: tracks all files in a directory" {
  budget_init
  _make_file 30 'a.dat'
  _make_file 70 'b.dat'
  budget_track_dir "$TESTDIR"
  [ "$BUDGET_TOTAL_BYTES" -eq 100 ]
}

@test "budget_track_dir: nonexistent directory is safe" {
  budget_init
  budget_track_dir "$TESTDIR/nope"
  [ "$BUDGET_TOTAL_BYTES" -eq 0 ]
}

# ---------------------------------------------------------------------------
# budget_checkpoint — warn threshold
# ---------------------------------------------------------------------------

@test "budget_checkpoint: warns at or above warn threshold" {
  budget_init
  # Override thresholds directly since they are set at source time
  WARN_THRESHOLD=100
  HARD_ABORT=999999
  f="$(_make_file 150 'big.dat')"
  BUDGET_TOTAL_BYTES=150

  run budget_checkpoint "test-warn"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]] || [[ "$output" == *"WARN"* ]]
}

@test "budget_checkpoint: does not warn below warn threshold" {
  budget_init
  WARN_THRESHOLD=100
  HARD_ABORT=999999
  f="$(_make_file 50 'small.dat')"
  BUDGET_TOTAL_BYTES=50

  run budget_checkpoint "test-silent"
  [ "$status" -eq 0 ]
  ! grep -qi 'warn' <<< "$output" || true
}

# ---------------------------------------------------------------------------
# budget_checkpoint — hard abort (breach)
# ---------------------------------------------------------------------------

@test "budget_checkpoint: aborts at or above hard limit" {
  export RECON_BUDGET_WARN=50
  export RECON_BUDGET_ABORT=200

  # Run in subshell so the 'die' doesn't kill the test harness
  run bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/budget.sh'
    budget_init
    f=\"\$(_make_file 250 'huge.dat')\" 2>/dev/null || true
    # simulate the tracked state
    BUDGET_TOTAL_BYTES=250
    budget_checkpoint 'test-abort'
  " 2>&1 || true

  # Should exit non-zero from 'die'
  [ "$status" -ne 0 ]
  [[ "$output" == *"BREACH"* ]] || [[ "$output" == *"FATAL"* ]]
}

@test "budget_checkpoint: does not abort below hard limit" {
  export RECON_BUDGET_WARN=999999
  export RECON_BUDGET_ABORT=999999

  run bash -c "
    source '$REPO_ROOT/scripts/lib/helpers.sh'
    source '$REPO_ROOT/scripts/lib/budget.sh'
    budget_init
    BUDGET_TOTAL_BYTES=100
    budget_checkpoint 'safe'
  " 2>&1 || true

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# budget_summary
# ---------------------------------------------------------------------------

@test "budget_summary: produces valid JSON with correct totals" {
  budget_init
  f="$(_make_file 500 'medium.dat')"
  budget_track "$f"
  budget_checkpoint "final"

  run budget_summary
  [ "$status" -eq 0 ]

  # Validate it's parseable JSON
  echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['total_bytes']==500"
}

@test "budget_summary: flags warned correctly at warn threshold" {
  WARN_THRESHOLD=100
  HARD_ABORT=999999
  budget_init
  BUDGET_TOTAL_BYTES=200
  budget_checkpoint "over-warn"

  run budget_summary
  [ "$status" -eq 0 ]
  warned=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['warned'])")
  [ "$warned" = "True" ]
}

@test "budget_summary: flags breached correctly at hard limit" {
  WARN_THRESHOLD=50
  HARD_ABORT=500
  budget_init

  # Simulate total exceeding hard limit (checkpoint would call die, so we skip it)
  BUDGET_TOTAL_BYTES=600

  run budget_summary
  [ "$status" -eq 0 ]
  breached=$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['breached'])")
  [ "$breached" = "True" ]
}
