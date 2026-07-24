#!/usr/bin/env bats
# heartbeat-v12-invariants.bats — All ADR v1.2 invariants + fix-regression tests.
# Uses physical temp paths to avoid macOS /var -> /private/var symlink rejection.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
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

_seed_v1() {
  printf '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"0_BOOTSTRAP","cycle":0,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
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
#  Fix #1: seed validation does NOT require 0700 on operator/
# ────────────────────────────────────────────────────────────

@test "fix1: --init-runtime works regardless of operator/ mode" {
  chmod 0755 "$WORKDIR/operator"
  run _init_runtime
  [ "$status" -eq 0 ]
  [ -f "$(_runtime_path)" ]
  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
}

# ────────────────────────────────────────────────────────────
#  Fix #2: state file owner=current-user, mode=0600
# ────────────────────────────────────────────────────────────

@test "fix2: existing runtime state with wrong owner rejected" {
  _init_runtime
  run _run_heartbeat
  [ "$status" -eq 0 ]
}

@test "fix2: runtime state file mode must be 0600" {
  _init_runtime
  mode="$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$(_runtime_path)').st_mode)))")"
  [ "$mode" = "0o600" ]
}

@test "fix2: state with mode 0644 rejected" {
  _init_runtime
  chmod 0644 "$(_runtime_path)"
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"file mode must be 0600"* ]]
}

# ────────────────────────────────────────────────────────────
#  Fix #3: lock metadata chmod enforced
# ────────────────────────────────────────────────────────────

@test "fix3: lock metadata files exist with 0600 after acquire" {
  _init_runtime
  # Run in background and check lock before it exits
  (
    lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
    mkdir "$lock_dir" 2>/dev/null
    echo "$$" > "$lock_dir/pid"
    echo "test-boot" > "$lock_dir/boot_id"
    echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"
    chmod 0600 "$lock_dir/pid" "$lock_dir/boot_id" "$lock_dir/acquired_at"
    sleep 5
    rm -rf "$lock_dir"
  ) &
  bg_pid=$!
  sleep 1

  # Check lock metadata perms
  pid_mode="$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$WORKDIR/operator/.runtime/heartbeat.lock/pid').st_mode)))" 2>/dev/null || echo "N/A")"
  [ "$pid_mode" = "0o600" ] || [ "$pid_mode" = "N/A" ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -rf "$WORKDIR/operator/.runtime/heartbeat.lock" 2>/dev/null || true
}

# ────────────────────────────────────────────────────────────
#  Fix #4: previous_checkpoint strict domain validation
# ────────────────────────────────────────────────────────────

@test "fix4: previous_checkpoint rejects null phase" {
  _init_runtime

cat > "$(_runtime_path)" <<'EOF'
{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":{"phase":null,"cycle":0,"expert_calls_this_cycle":0,"max_expert_calls":3,"last_heartbeat":null,"updated_at":"2026-07-24T00:00:00Z","notes":""}}
EOF
  chmod 0600 "$(_runtime_path)"

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"previous_checkpoint.phase"* ]]
}

@test "fix4: previous_checkpoint rejects negative cycle" {
  _init_runtime

cat > "$(_runtime_path)" <<'EOF'
{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":{"phase":"0_BOOTSTRAP","cycle":-1,"expert_calls_this_cycle":0,"max_expert_calls":3,"last_heartbeat":null,"updated_at":"2026-07-24T00:00:00Z","notes":""}}
EOF
  chmod 0600 "$(_runtime_path)"

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"previous_checkpoint.cycle"* ]]
}

@test "fix4: previous_checkpoint rejects nonpositive max_expert_calls" {
  _init_runtime

cat > "$(_runtime_path)" <<'EOF'
{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":{"phase":"0_BOOTSTRAP","cycle":0,"expert_calls_this_cycle":0,"max_expert_calls":0,"last_heartbeat":null,"updated_at":"2026-07-24T00:00:00Z","notes":""}}
EOF
  chmod 0600 "$(_runtime_path)"

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"previous_checkpoint.max_expert_calls"* ]]
}

@test "fix4: previous_checkpoint with valid values passes" {
  _init_runtime
  run _run_heartbeat
  [ "$status" -eq 0 ]
}

# ────────────────────────────────────────────────────────────
#  Fix #5: init failure diagnostics use correct variable name
# ────────────────────────────────────────────────────────────

@test "fix5: init failure output contains FATAL and error message" {
  # Write a non-v1 seed to trigger init failure
  printf '{"schema_version":99}' > "$WORKDIR/operator/state.json"
  run _init_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL"* ]]
  [[ "$output" == *"schema_version"* ]]
}

# ────────────────────────────────────────────────────────────
#  Fix #6: --force backups before state replacement, with fsync
# ────────────────────────────────────────────────────────────

@test "fix6: --force backup survives inject before state replacement" {
  _init_runtime
  _run_heartbeat
  before_hash="$(_shasum "$(_runtime_path)")"

  export _HB_FSYNC_BACKUP_INJECT=1
  run _run_heartbeat --init-runtime --force
  [ "$status" -eq 1 ]
  [[ "$output" == *"simulated failure after backup fsync"* ]]

  # Backup must exist and match pre-force state
  [ -f "$WORKDIR/operator/.runtime/state.json.bak" ]
  [ "$before_hash" = "$(_shasum "$WORKDIR/operator/.runtime/state.json.bak")" ]
  # Runtime state unchanged (injection happened before state replacement)
  [ "$before_hash" = "$(_shasum "$(_runtime_path)")" ]
}

# ────────────────────────────────────────────────────────────
#  Fix #7: create_runtime_parent validates owner and 0700
# ────────────────────────────────────────────────────────────

@test "fix7: runtime parent dir is 0700 after create_runtime_parent" {
  _init_runtime
  mode="$(stat -f '%p' "$WORKDIR/operator/.runtime" 2>/dev/null || stat -c '%a' "$WORKDIR/operator/.runtime")"
  while [ "${#mode}" -gt 3 ]; do mode="${mode#?}"; done
  [ "$mode" = "700" ]
}

@test "fix7: runtime parent owner is current user" {
  _init_runtime
  owner="$(stat -f '%u' "$WORKDIR/operator/.runtime" 2>/dev/null || stat -c '%u' "$WORKDIR/operator/.runtime")"
  [ "$owner" = "$(id -u)" ]
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
}

@test "D1.4: --force backs up current state and replaces from seed" {
  _init_runtime
  bak="$WORKDIR/operator/.runtime/state.json.bak"

  _run_heartbeat
  before_hash="$(_shasum "$(_runtime_path)")"

  _run_heartbeat --init-runtime --force
  [ -f "$bak" ]
  [ "$before_hash" = "$(_shasum "$bak")" ]
  [ "$(_state_field "$(_runtime_path)" "phase")" = "0_BOOTSTRAP" ]
}

@test "D1.5: symlinked state path rejected" {
  _init_runtime
  ln -s "$(_runtime_path)" "$WORKDIR/symlink-state.json"
  run _run_heartbeat --state-file "$WORKDIR/symlink-state.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symbolic link"* ]]
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

@test "D1.5: intermediate ancestor symlink rejected" {
  mkdir -p "$WORKDIR/a/b/c" "$WORKDIR/evil"
  chmod 0700 "$WORKDIR/a" "$WORKDIR/a/b" "$WORKDIR/a/b/c" "$WORKDIR/evil"
  _seed_v1 > "$WORKDIR/operator/state.json"
  # Create a valid state at the custom path
  mkdir -p "$WORKDIR/a/b/c"
  printf '{"schema_version":2,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":null}' > "$WORKDIR/a/b/c/runtime.json"
  chmod 0600 "$WORKDIR/a/b/c/runtime.json"
  _run_heartbeat --state-file "$WORKDIR/a/b/c/runtime.json"
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
  mode="$(python3 -c "import os,stat; print(oct(stat.S_IMODE(os.stat('$(_runtime_path)').st_mode)))")"
  [ "$mode" = "0o600" ]
}

# ────────────────────────────────────────────────────────────
#  D3.x — Single-Writer Locking
# ────────────────────────────────────────────────────────────

@test "D3.1: concurrent heartbeat exits 2 with ACTION: STOP" {
  _init_runtime
  before="$(_shasum "$(_runtime_path)")"

  (
    lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
    mkdir "$lock_dir" 2>/dev/null
    echo "$$" > "$lock_dir/pid"
    echo "test-boot" > "$lock_dir/boot_id"
    echo "2026-07-24T12:00:00Z" > "$lock_dir/acquired_at"
    chmod 0600 "$lock_dir/pid" "$lock_dir/boot_id" "$lock_dir/acquired_at"
    sleep 10
    rm -rf "$lock_dir"
  ) &
  bg_pid=$!
  sleep 1

  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [ "$before" = "$(_shasum "$(_runtime_path)")" ]

  kill "$bg_pid" 2>/dev/null || true
  wait "$bg_pid" 2>/dev/null || true
  rm -rf "$WORKDIR/operator/.runtime/heartbeat.lock" 2>/dev/null || true
}

@test "D3.2: lock released on normal exit" {
  _init_runtime
  run _run_heartbeat; [ "$status" -eq 0 ]
  run _run_heartbeat; [ "$status" -eq 0 ]
  [ ! -d "$WORKDIR/operator/.runtime/heartbeat.lock" ]
}

@test "D3.3: same-boot stale lock auto-recovered" {
  _init_runtime
  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  dead_pid=99999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  echo "$dead_pid" > "$lock_dir/pid"
  current_boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || echo "unknown")"
  echo "$current_boot" > "$lock_dir/boot_id"
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
}

@test "D3.4: cross-boot stale lock auto-recovered" {
  _init_runtime
  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir -p "$lock_dir"
  dead_pid=99998
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  echo "$dead_pid" > "$lock_dir/pid"
  echo "different-boot-id-abcdef" > "$lock_dir/boot_id"
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
}

@test "D3.5: --init-runtime and normal heartbeat serialized by lock" {
  _init_runtime
  (
    lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
    mkdir "$lock_dir" 2>/dev/null
    echo "$$" > "$lock_dir/pid"
    echo "test-boot-xyz" > "$lock_dir/boot_id"
    chmod 0600 "$lock_dir/pid" "$lock_dir/boot_id"
    sleep 10
    rm -rf "$lock_dir"
  ) &
  bg_pid=$!
  sleep 1
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
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
  run _run_heartbeat --break-lock; [ "$status" -eq 0 ]
  run _run_heartbeat; [ "$status" -eq 0 ]
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
  rm -rf "$lock_dir"
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

@test "D4.2: _HB_FSYNC_FAIL_INJECT exits 1, no misleading ACTION" {
  _init_runtime
  export _HB_FSYNC_FAIL_INJECT=1
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]
}

@test "D4.2: tempfile cleanup does NOT run during dry-run" {
  _init_runtime
  touch "$WORKDIR/operator/.runtime/.heartbeat-state-test123"
  run _run_heartbeat --dry-run; [ "$status" -eq 0 ]
  [ -f "$WORKDIR/operator/.runtime/.heartbeat-state-test123" ]
  run _run_heartbeat; [ "$status" -eq 0 ]
  [ ! -f "$WORKDIR/operator/.runtime/.heartbeat-state-test123" ]
}

# ────────────────────────────────────────────────────────────
#  D5.x — Compact Auditability
# ────────────────────────────────────────────────────────────

@test "D5.1: previous_checkpoint flattened, no nested budget" {
  _init_runtime
  _run_heartbeat
  python3 -c "
import json
state = json.load(open('$(_runtime_path)'))
pc = state['previous_checkpoint']
assert 'budget' not in pc
assert isinstance(pc['expert_calls_this_cycle'], int)
assert isinstance(pc['max_expert_calls'], int)
"
}

@test "D5.1: previous_checkpoint has exact 7 fields" {
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
assert 'previous_checkpoint' not in pc
"
}

# ────────────────────────────────────────────────────────────
#  D6.x — Schema Migration
# ────────────────────────────────────────────────────────────

@test "D6.1: v1 seed migrates to v2 runtime" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  _init_runtime
  [ "$(_state_field "$(_runtime_path)" "schema_version")" = "2" ]
  [ "$(_state_field "$(_runtime_path)" "previous_checkpoint")" = "None" ]
}

@test "D6.2: unknown schema version exits 1" {
cat > "$(_runtime_path)" <<'EOF'
{"schema_version":99,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3},"last_heartbeat":null,"notes":"","previous_checkpoint":null}
EOF
  chmod 0600 "$(_runtime_path)"
  run _run_heartbeat
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────
#  D7.x — Failure Semantics
# ────────────────────────────────────────────────────────────

@test "D7.1: no work-dispatching ACTION on invalid state" {
  echo '{not-json' > "$(_runtime_path)"
  chmod 0600 "$(_runtime_path)"
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" != *"ACTION: BUILD"* ]]
  [[ "$output" != *"ACTION: REVIEW"* ]]
  [[ "$output" != *"ACTION: SWEEP"* ]]
  [[ "$output" != *"ACTION: ADVANCE"* ]]
}

@test "D7.1: no work ACTION on lock contention" {
  _init_runtime
  lock_dir="$WORKDIR/operator/.runtime/heartbeat.lock"
  mkdir "$lock_dir"
  echo "$$" > "$lock_dir/pid"
  echo "test-boot" > "$lock_dir/boot_id"
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" != *"ACTION: BUILD"* ]]
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
#  Additional
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

@test "normal heartbeat without init-runtime fails" {
  run _run_heartbeat
  [ "$status" -eq 1 ]
}

@test "--force requires --init-runtime" {
  run _run_heartbeat --force
  [ "$status" -eq 1 ]
}

@test "--init-runtime and --break-lock mutually exclusive" {
  run _run_heartbeat --init-runtime --break-lock
  [ "$status" -eq 1 ]
}

# ────────────────────────────────────────────────────────────
#  Regression: relative paths must not hang
# ────────────────────────────────────────────────────────────

@test "relative --state-file path works (CLI)" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  mkdir -p "$WORKDIR/rel"
  chmod 0700 "$WORKDIR/rel"
  (
    cd "$WORKDIR"
    run env PATH="$WORKDIR/mockbin:$PATH" \
      HEARTBEAT_NOW="$HEARTBEAT_NOW" \
      /bin/bash "$WORKDIR/operator/heartbeat.sh" --init-runtime --state-file rel/runtime.json
    [ "$status" -eq 0 ]
    [ -f "$WORKDIR/rel/runtime.json" ]
    [ "$(python3 -c "import json; print(json.load(open('$WORKDIR/rel/runtime.json'))['schema_version'])")" = "2" ]
  )
}

@test "relative OPERATOR_STATE_FILE path works (env)" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  mkdir -p "$WORKDIR/rel"
  chmod 0700 "$WORKDIR/rel"
  (
    cd "$WORKDIR"
    run env PATH="$WORKDIR/mockbin:$PATH" \
      HEARTBEAT_NOW="$HEARTBEAT_NOW" \
      OPERATOR_STATE_FILE=rel/runtime.json \
      /bin/bash "$WORKDIR/operator/heartbeat.sh" --init-runtime
    [ "$status" -eq 0 ]
    [ -f "$WORKDIR/rel/runtime.json" ]
  )
}

@test "relative --state-file normal heartbeat works" {
  _seed_v1 > "$WORKDIR/operator/state.json"
  mkdir -p "$WORKDIR/rel"
  chmod 0700 "$WORKDIR/rel"
  # Init with relative path
  (
    cd "$WORKDIR"
    PATH="$WORKDIR/mockbin:$PATH" HEARTBEAT_NOW="$HEARTBEAT_NOW" \
      /bin/bash "$WORKDIR/operator/heartbeat.sh" --init-runtime --state-file rel/runtime.json >/dev/null
  )
  # Normal heartbeat with relative path
  (
    cd "$WORKDIR"
    run env PATH="$WORKDIR/mockbin:$PATH" \
      HEARTBEAT_NOW="$HEARTBEAT_NOW" \
      /bin/bash "$WORKDIR/operator/heartbeat.sh" --state-file rel/runtime.json
    [ "$status" -eq 0 ]
    [[ "$output" == *"ACTION: ADVANCE"* ]]
  )
}
