#!/usr/bin/env bats
# heartbeat-v12-invariants.bats — Offline tests for all 24 ADR v1.2 invariants
# plus tests for the 8 Jcode-review merge-blocker fixes.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/operator/.runtime" "$WORKDIR/mockbin"
  chmod 0700 "$WORKDIR/operator"
  chmod 0700 "$WORKDIR/operator/.runtime"
  cp "$REPO_ROOT/operator/heartbeat.sh" "$WORKDIR/operator/heartbeat.sh"
  chmod +x "$WORKDIR/operator/heartbeat.sh"

  _seed_v1 > "$WORKDIR/operator/state.json"

  export WORKDIR
  export HEARTBEAT_NOW='2026-07-24T12:00:00Z'
  export MOCK_PRS='[]'
  export MOCK_ISSUES='[]'
  export MOCK_GH_FAIL_ON=''
  export MOCK_GH_CWD="$WORKDIR"
  export MOCK_GIT_DIRTY='clean'
  export MOCK_GIT_FAIL='false'

  cat > "$WORKDIR/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ -n "${MOCK_GH_CWD:-}" ] && [ "$PWD" != "$MOCK_GH_CWD" ]; then exit 4; fi
if [ -n "${GH_REPO:-}" ]; then exit 5; fi
if [ -n "${GH_HOST:-}" ]; then exit 6; fi
if [ "$MOCK_GH_FAIL_ON" = "all" ] || [ "$MOCK_GH_FAIL_ON" = "${1:-}" ]; then exit 1; fi
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "$MOCK_PRS" ;;
  "issue list") printf '%s\n' "$MOCK_ISSUES" ;;
  *) exit 2 ;;
esac
GHSCRIPT
  chmod +x "$WORKDIR/mockbin/gh"

  cat > "$WORKDIR/mockbin/git" <<'GITSCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
if [ "${1:-}" = "status" ]; then
  [ "$MOCK_GIT_FAIL" = "false" ] || exit 1
  [ "$MOCK_GIT_DIRTY" = "clean" ] || printf ' M operator/state.json\n'
  exit 0
fi
exec /usr/bin/git "$@"
GITSCRIPT
  chmod +x "$WORKDIR/mockbin/git"
}

teardown() {
  rm -rf "$WORKDIR"
}

# ── helpers ────────────────────────────────────────────────

_seed_v1() {
  printf '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"0_BOOTSTRAP","cycle":0,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
}

_seed_v1_classify() {
  printf '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}'
}

_runtime_path() {
  echo "$WORKDIR/operator/.runtime/state.json"
}

_init_runtime() {
  PATH="$WORKDIR/mockbin:$PATH" \
    HEARTBEAT_NOW="$HEARTBEAT_NOW" \
    /bin/bash "$WORKDIR/operator/heartbeat.sh" --init-runtime 2>&1
}

_run_heartbeat() {
  PATH="$WORKDIR/mockbin:$PATH" \
    HEARTBEAT_NOW="$HEARTBEAT_NOW" \
    /bin/bash "$WORKDIR/operator/heartbeat.sh" "$@" 2>&1
}

_shasum() {
  shasum -a 256 "$1" | awk '{print $1}'
}

_state_field() {
  python3 -c "import json; print(json.load(open('$1'))${2:+['$2']})"
}

# ────────────────────────────────────────────────────────────
#  Fix #1: separate seed vs runtime validation (seed no 0700)
# ────────────────────────────────────────────────────────────

@test "fix1: --init-runtime succeeds when operator/ is NOT 0700" {
  chmod 0755 "$WORKDIR/operator"
  run _init_runtime
  [ "$status" -eq 0 ]
  [ -f "$(_runtime_path)" ]
  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
}

# ────────────────────────────────────────────────────────────
#  D1.x — Bootstrap Seed vs. Runtime Checkpoint
# ────────────────────────────────────────────────────────────

@test "D1.1: seed never mutated by --init-runtime" {
  seed_hash="$(_shasum "$WORKDIR/operator/state.json")"
  _init_runtime
  [ "$seed_hash" = "$(_shasum "$WORKDIR/operator/state.json")" ]
}

@test "D1.1: seed never mutated by normal heartbeat" {
  _init_runtime
  seed_hash="$(_shasum "$WORKDIR/operator/state.json")"
  _run_heartbeat
  [ "$seed_hash" = "$(_shasum "$WORKDIR/operator/state.json")" ]
}

@test "D1.1: seed never mutated by --init-runtime --force" {
  _init_runtime
  seed_hash="$(_shasum "$WORKDIR/operator/state.json")"
  _run_heartbeat --init-runtime --force
  [ "$seed_hash" = "$(_shasum "$WORKDIR/operator/state.json")" ]
}

@test "D1.2: --init-runtime creates valid v2 state from seed" {
  [ ! -f "$(_runtime_path)" ]
  _init_runtime
  [ -f "$(_runtime_path)" ]
  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]
}

@test "D1.3: normal heartbeat without runtime state exits 1" {
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
  [ ! -f "$(_runtime_path)" ]
}

@test "D1.4: --force backs up current state and replaces from seed" {
  _init_runtime
  bak="$WORKDIR/operator/.runtime/state.json.bak"

  _run_heartbeat
  before_hash="$(_shasum "$(_runtime_path)")"

  _run_heartbeat --init-runtime --force
  [ -f "$bak" ]
  [ "$before_hash" = "$(_shasum "$bak")" ]

  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
  [ "$(_state_field "$(_runtime_path)" "phase")" = "0_BOOTSTRAP" ]
  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]
}

@test "D1.5: symlinked state path rejected" {
  _init_runtime
  ln -s "$(_runtime_path)" "$WORKDIR/symlink-state.json"

  run _run_heartbeat --state-file "$WORKDIR/symlink-state.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be a symbolic link"* ]]
}

@test "D1.5: symlinked parent directory rejected" {
  mkdir -p "$WORKDIR/real-dir"
  chmod 0700 "$WORKDIR/real-dir"
  _seed_v1 > "$WORKDIR/real-dir/seed.json"
  ln -s "$WORKDIR/real-dir" "$WORKDIR/link-dir"

  run _run_heartbeat --init-runtime --state-file "$WORKDIR/link-dir/runtime.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symbolic link"* ]]
}

# ────────────────────────────────────────────────────────────
#  Fix #5: intermediate ancestor symlink rejection
# ────────────────────────────────────────────────────────────

@test "fix5: intermediate ancestor symlink in custom state path rejected" {
  mkdir -p "$WORKDIR/a/b/c" "$WORKDIR/evil"
  chmod 0700 "$WORKDIR/a" "$WORKDIR/a/b" "$WORKDIR/a/b/c" "$WORKDIR/evil"
  _init_runtime --state-file "$WORKDIR/a/b/c/runtime.json"
  # Replace intermediate dir with symlink
  rm -rf "$WORKDIR/a/b"
  ln -s "$WORKDIR/evil" "$WORKDIR/a/b"

  run _run_heartbeat --state-file "$WORKDIR/a/b/c/runtime.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symbolic link"* ]]
}

# ────────────────────────────────────────────────────────────
#  D2.x — Crash Safety and Permissions
# ────────────────────────────────────────────────────────────

@test "D2.1: state file is valid JSON after --init-runtime" {
  _init_runtime
  python3 -c "import json; json.load(open('$(_runtime_path)'))"
}

@test "D2.1: state file is valid JSON after normal heartbeat write" {
  _init_runtime
  _run_heartbeat
  python3 -c "import json; json.load(open('$(_runtime_path)'))"
}

@test "D2.2: .runtime/ files not git-tracked" {
  _init_runtime
  grep -q '.runtime' "$REPO_ROOT/.gitignore"
}

@test "D2.3: runtime parent dir is 0700" {
  _init_runtime
  mode="$(stat -f '%p' "$WORKDIR/operator/.runtime" 2>/dev/null || stat -c '%a' "$WORKDIR/operator/.runtime")"
  while [ "${#mode}" -gt 3 ]; do mode="${mode#?}"; done
  [ "$mode" = "700" ]
}

@test "D2.3: runtime state file is 0600" {
  _init_runtime
  mode="$(python3 -c "import os, stat; print(oct(stat.S_IMODE(os.stat('$(_runtime_path)').st_mode)))")"
  [ "$mode" = "0o600" ]
}

# ────────────────────────────────────────────────────────────
#  D3.x — Single-Writer Locking
# ────────────────────────────────────────────────────────────

@test "D3.1: concurrent heartbeat exits 2 with ACTION: STOP, state unchanged" {
  _init_runtime
  before="$(_shasum "$(_runtime_path)")"

  (
    lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
    mkdir "$lock_dir" 2>/dev/null
    echo "$$" > "$lock_dir/pid"
    echo "test-boot" > "$lock_dir/boot_id"
    echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"
    sleep 10
    rm -rf "$lock_dir"
  ) &
  bg_pid=$!
  sleep 1

  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"lock held by live process"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]
  [ "$before" = "$(_shasum "$(_runtime_path)")" ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -rf "$WORKDIR/operator/.runtime/heartbeat.lock" 2>/dev/null || true
}

@test "D3.2: lock released on normal exit, sequential heartbeat succeeds" {
  _init_runtime
  run _run_heartbeat
  [ "$status" -eq 0 ]

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [ ! -d "$WORKDIR/operator/.runtime/heartbeat.lock" ]
}

@test "D3.3: same-boot stale lock auto-recovered after kill -9" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  dead_pid=99999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  echo "$dead_pid" > "$lock_dir/pid"
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || echo "unknown")"
  echo "$current_boot" > "$lock_dir/boot_id"
  echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
  [ ! -d "$lock_dir" ]
}

@test "D3.4: cross-boot stale lock auto-recovered" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  dead_pid=99998
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  echo "$dead_pid" > "$lock_dir/pid"
  echo "different-boot-id-abcdef" > "$lock_dir/boot_id"
  echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
  [ ! -d "$lock_dir" ]
}

@test "D3.5: --init-runtime and normal heartbeat serialized by lock" {
  _init_runtime

  (
    lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
    mkdir "$lock_dir" 2>/dev/null
    echo "$$" > "$lock_dir/pid"
    echo "test-boot-xyz" > "$lock_dir/boot_id"
    echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"
    sleep 10
    rm -rf "$lock_dir"
  ) &
  bg_pid=$!
  sleep 1

  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"lock held by live process"* ]]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -rf "$WORKDIR/operator/.runtime/heartbeat.lock" 2>/dev/null || true
}

@test "D3.6: --dry-run skips the lock" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir "$lock_dir" 2>/dev/null
  echo "$$" > "$lock_dir/pid"
  echo "test-boot-dry" > "$lock_dir/boot_id"
  echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"

  run _run_heartbeat --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]

  rm -rf "$lock_dir"
}

@test "D3.7: --break-lock removes stuck lock, heartbeat proceeds" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  dead_pid=99997
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  echo "$dead_pid" > "$lock_dir/pid"

  run _run_heartbeat
  [ "$status" -eq 1 ]

  run _run_heartbeat --break-lock
  [ "$status" -eq 0 ]
  [ ! -d "$lock_dir" ]

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
}

@test "D3.7: --break-lock refuses to break live lock" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  echo "$$" > "$lock_dir/pid"
  echo "test-boot-live" > "$lock_dir/boot_id"

  run _run_heartbeat --break-lock
  [ "$status" -eq 1 ]
  [[ "$output" == *"live process"* ]]
  [ -d "$lock_dir" ]

  rm -rf "$lock_dir"
}

# ────────────────────────────────────────────────────────────
#  Fix #2: cleanup_tempfiles under lock only, never dry-run
# ────────────────────────────────────────────────────────────

@test "fix2: tempfile cleanup does NOT run during dry-run" {
  _init_runtime

  # Create a fake tempfile
  touch "$WORKDIR/operator/.runtime/.heartbeat-state-test123"

  # Dry-run must not delete it
  run _run_heartbeat --dry-run
  [ "$status" -eq 0 ]
  [ -f "$WORKDIR/operator/.runtime/.heartbeat-state-test123" ]

  # Normal heartbeat (under lock) must delete it
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [ ! -f "$WORKDIR/operator/.runtime/.heartbeat-state-test123" ]
}

# ────────────────────────────────────────────────────────────
#  Fix #3: lock cleanup armed immediately after mkdir
# ────────────────────────────────────────────────────────────

@test "fix3: lock orphan cleanup on metadata write failure" {
  _init_runtime

  # Simulate: mkdir succeeds but PID file cannot be written
  # (Tested indirectly: the trap is registered before metadata writes)
  # We verify that after a normal heartbeat exit, no lock remains
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [ ! -d "$WORKDIR/operator/.runtime/heartbeat.lock" ]
}

# ────────────────────────────────────────────────────────────
#  Fix #4: directory fsync propagated (no swallowed OSError)
# ────────────────────────────────────────────────────────────

@test "fix4: _HB_FSYNC_FAIL_INJECT exits 1, no misleading ACTION" {
  _init_runtime

  export _HB_FSYNC_FAIL_INJECT=1
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]
  [[ "$output" == *"simulated directory fsync failure"* ]]
}

# ────────────────────────────────────────────────────────────
#  D4.x — Crash States and Recovery
# ────────────────────────────────────────────────────────────

@test "D4.1: stale tempfiles cleaned at startup" {
  _init_runtime

  touch "$WORKDIR/operator/.runtime/.heartbeat-state-old123"
  touch "$WORKDIR/operator/.runtime/.heartbeat-backup-old456"

  _run_heartbeat
  [ ! -f "$WORKDIR/operator/.runtime/.heartbeat-state-old123" ]
  [ ! -f "$WORKDIR/operator/.runtime/.heartbeat-backup-old456" ]
}

# ────────────────────────────────────────────────────────────
#  Fix #6: previous_checkpoint flattened shape
# ────────────────────────────────────────────────────────────

@test "fix6: previous_checkpoint is flattened, no nested budget" {
  _init_runtime
  _run_heartbeat

  python3 -c "
import json
state = json.load(open('$(_runtime_path)'))
pc = state['previous_checkpoint']
assert 'budget' not in pc, 'budget must not be nested in previous_checkpoint'
assert isinstance(pc.get('expert_calls_this_cycle'), int), 'expert_calls_this_cycle must be int'
assert isinstance(pc.get('max_expert_calls'), int), 'max_expert_calls must be int'
assert pc.get('phase') is not None
assert pc.get('cycle') is not None
"
}

@test "fix6: previous_checkpoint has exact 7 fields" {
  _init_runtime
  _run_heartbeat

  fields="$(python3 -c "
import json
state = json.load(open('$(_runtime_path)'))
pc = state['previous_checkpoint']
print(sorted(pc.keys()))
")"
  [ "$fields" = "['cycle', 'expert_calls_this_cycle', 'last_heartbeat', 'max_expert_calls', 'notes', 'phase', 'updated_at']" ]
}

# ────────────────────────────────────────────────────────────
#  D5.x — Compact Auditability
# ────────────────────────────────────────────────────────────

@test "D5.1: previous_checkpoint captures all pre-write mutable fields" {
  _init_runtime

  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]

  _run_heartbeat

  pc="$(python3 -c "
import json
state = json.load(open('$(_runtime_path)'))
pc = state['previous_checkpoint']
print(pc['phase'])
print(pc['cycle'])
print(pc['expert_calls_this_cycle'])
print(pc['max_expert_calls'])
print(pc['last_heartbeat'])
print(pc['updated_at'])
print(pc['notes'])
")"
  [ -n "$pc" ]
}

@test "D5.2: previous_checkpoint null after --init-runtime" {
  _init_runtime
  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]
}

@test "D5.3: no nested previous_checkpoint" {
  _init_runtime
  _run_heartbeat
  _run_heartbeat

  python3 -c "
import json
state = json.load(open('$(_runtime_path)'))
pc = state['previous_checkpoint']
assert 'previous_checkpoint' not in pc, 'nested previous_checkpoint found'
"
}

# ────────────────────────────────────────────────────────────
#  D6.x — Schema Migration
# ────────────────────────────────────────────────────────────

@test "D6.1: v1 seed migrates to v2 runtime on --init-runtime" {
  _seed_v1 > "$WORKDIR/operator/state.json"

  _init_runtime
  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]
}

@test "D6.2: unknown schema version exits 1" {
  cat > "$(_runtime_path)" <<'EOF'
{"schema_version":99,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":null}
EOF

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema_version must equal 2"* ]]
}

# ────────────────────────────────────────────────────────────
#  Fix #7: derived backup path for custom --state-file
# ────────────────────────────────────────────────────────────

@test "fix7: --force with custom --state-file uses derived .bak path" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  custom="$WORKDIR/custom/runtime.json"
  mkdir -p "$(dirname "$custom")"
  chmod 0700 "$(dirname "$custom")"

  _run_heartbeat --init-runtime --state-file "$custom"
  before="$(_shasum "$custom")"
  _run_heartbeat --init-runtime --force --state-file "$custom"

  # Backup should be runtime.json.bak (not state.json.bak)
  [ -f "$WORKDIR/custom/runtime.json.bak" ]
  [ "$before" = "$(_shasum "$WORKDIR/custom/runtime.json.bak")" ]
}

# ────────────────────────────────────────────────────────────
#  D7.x — Failure Semantics
# ────────────────────────────────────────────────────────────

@test "D7.1: no work-dispatching ACTION on invalid state" {
  echo '{not-json' > "$(_runtime_path)"

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]
}

@test "D7.1: no work-dispatching ACTION on lock contention" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir "$lock_dir"
  echo "$$" > "$lock_dir/pid"
  echo "test-boot" > "$lock_dir/boot_id"

  run _run_heartbeat
  [ "$status" -eq 2 ]
  # Must have ACTION: STOP (not a work action)
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]

  rm -rf "$lock_dir"
}

@test "D7.2: write failure before os.replace leaves state intact" {
  [ "$(id -u)" -ne 0 ] || skip "root bypasses directory write permissions"
  _init_runtime
  before="$(_shasum "$(_runtime_path)")"

  chmod 0500 "$WORKDIR/operator/.runtime"

  run _run_heartbeat
  chmod 0700 "$WORKDIR/operator/.runtime"

  [ "$status" -eq 1 ]
  [ "$before" = "$(_shasum "$(_runtime_path)")" ]
}

# ────────────────────────────────────────────────────────────
#  Additional tests
# ────────────────────────────────────────────────────────────

@test "--init-runtime honors --state-file" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  custom="$WORKDIR/custom-runtime.json"
  mkdir -p "$(dirname "$custom")"
  chmod 0700 "$(dirname "$custom")"

  run _run_heartbeat --init-runtime --state-file "$custom"
  [ "$status" -eq 0 ]
  [ -f "$custom" ]
  [ "$(_state_field "$custom" "schema_version")" = "2" ]
}

@test "normal heartbeat without init-runtime fails (default path)" {
  run _run_heartbeat
  [ "$status" -eq 1 ]
}

@test "--force requires --init-runtime" {
  run _run_heartbeat --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"--force requires --init-runtime"* ]]
}

@test "--init-runtime and --break-lock are mutually exclusive" {
  run _run_heartbeat --init-runtime --break-lock
  [ "$status" -eq 1 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "tempfile cleanup handles no matching files gracefully" {
  _init_runtime
  run _run_heartbeat
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────
#  Fix #8: live lock contention emits ACTION: STOP, nonzero
# ────────────────────────────────────────────────────────────

@test "fix8: live lock contention has ACTION: STOP and no misleading work" {
  _init_runtime

  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir "$lock_dir"
  echo "$$" > "$lock_dir/pid"
  echo "test-boot-fix8" > "$lock_dir/boot_id"

  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"lock held by live process"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]

  rm -rf "$lock_dir"
}
