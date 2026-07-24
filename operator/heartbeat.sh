#!/usr/bin/env bash
# heartbeat.sh — Deterministic, decide-only operator dispatcher.
#
# Phases: 0_BOOTSTRAP → 1_CLASSIFY → 2_DELEGATE → 3_REVIEW → 4_INTEGRATE → 5_SWEEP
#
# v1.2 adds durable runtime-state with single-writer locking, schema v2,
# previous_checkpoint audit, crash-safe writes, and explicit init/force/break-lock
# modes. The committed operator/state.json (schema v1) is the immutable bootstrap
# seed. Runtime state defaults to operator/.runtime/state.json.
#
# Usage:
#   bash operator/heartbeat.sh [--init-runtime [--force]] [--break-lock]
#                              [--dry-run] [--state-file PATH]
#
# Environment:
#   OPERATOR_STATE_FILE  default runtime state path override
#   HEARTBEAT_NOW        fixed ISO-8601 UTC time for deterministic testing
#   _HB_FSYNC_FAIL_INJECT  set to 1 to simulate directory fsync failure (tests)

set -o errexit -o nounset -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED_FILE="$REPO_ROOT/operator/state.json"
STATE_FILE=""
DRY_RUN=false
INIT_RUNTIME=false
FORCE_INIT=false
BREAK_LOCK=false
STALE_DAYS_PR=7
STALE_DAYS_ISSUE=14

usage() {
  cat <<'EOF'
Usage: bash operator/heartbeat.sh [--init-runtime [--force]] [--break-lock]
                                   [--dry-run] [--state-file PATH]

  --init-runtime     initialize runtime state from the immutable seed
  --force            with --init-runtime: backup current state, re-init from seed
  --break-lock       remove a stuck lock directory (PID dead, boot-id missing)
  --dry-run          decide without modifying the runtime state file
  --state-file PATH  use an explicit runtime checkpoint path

Exit status: 0 = success / decision, 1 = local irrecoverable,
             2 = transient / lock contention
EOF
}

die() { echo "FATAL: $*" >&2; exit 1; }

# ────────────────────────────────────────────────────────────
#  Argument parsing
# ────────────────────────────────────────────────────────────

while [ "$#" -gt 0 ]; do
  case "$1" in
    --init-runtime)
      INIT_RUNTIME=true
      shift
      ;;
    --force)
      FORCE_INIT=true
      shift
      ;;
    --break-lock)
      BREAK_LOCK=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --state-file)
      [ "$#" -ge 2 ] || die "--state-file requires a path"
      STATE_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

# --force is only valid with --init-runtime
if $FORCE_INIT && ! $INIT_RUNTIME; then
  die "--force requires --init-runtime"
fi

# Mutually exclusive high-level modes
mode_count=0
$INIT_RUNTIME && mode_count=$((mode_count + 1))
$BREAK_LOCK && mode_count=$((mode_count + 1))
if [ "$mode_count" -gt 1 ]; then
  die "--init-runtime and --break-lock are mutually exclusive"
fi

# Resolve runtime state path: explicit > env > default
if [ -z "$STATE_FILE" ]; then
  STATE_FILE="${OPERATOR_STATE_FILE:-$REPO_ROOT/operator/.runtime/state.json}"
fi

# ────────────────────────────────────────────────────────────
#  Boot identity (for stale-lock detection)
# ────────────────────────────────────────────────────────────

get_boot_id() {
  if [ -r /proc/sys/kernel/random/boot_id ]; then
    cat /proc/sys/kernel/random/boot_id
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n kern.boottime 2>/dev/null || true
  fi
}

BOOT_ID="$(get_boot_id)"

# ────────────────────────────────────────────────────────────
#  Path validation (§2 of ADR)
# ────────────────────────────────────────────────────────────

# validate_path TARGET_PATH [must_exist]
# Rejects symlinks on the target and its immediate parent directory.
# Resolves parent to physical path (handles macOS system symlinks like
# /var -> /private/var, /tmp -> /private/tmp) and validates all resolved
# ancestors are directories. Checks ownership/mode of the parent dir.
validate_path() {
  local target="$1"
  local must_exist="${2:-false}"

  # --- Raw checks: target + immediate parent only ---

  # Target must not be a symlink
  if [ -L "$target" ]; then
    die "state file must not be a symbolic link: $target"
  fi

  local parent_dir
  parent_dir="$(dirname "$target")"

  # Parent must not be a symlink (catches "ln -s evil state_dir")
  if [ -L "$parent_dir" ]; then
    die "path component is a symbolic link: $parent_dir"
  fi

  # --- Physical ancestor checks (resolves system symlinks) ---

  local resolved_parent=""
  if [ -d "$parent_dir" ]; then
    resolved_parent="$(cd "$parent_dir" 2>/dev/null && pwd -P 2>/dev/null)" || true
  fi

  if [ -n "$resolved_parent" ]; then
    local component="$resolved_parent"
    while [ "$component" != "/" ]; do
      if [ -e "$component" ] && [ ! -d "$component" ]; then
        die "path component is not a directory: $component"
      fi
      component="$(dirname "$component")"
    done
  fi

  # --- Existence check ---

  if $must_exist; then
    [ -f "$target" ] || die "state file not found: $target"
  elif [ -e "$target" ] && [ ! -f "$target" ]; then
    die "state file is not a regular file: $target"
  fi

  # --- Parent ownership and mode ---

  if [ -d "$parent_dir" ]; then
    local owner_uid
    owner_uid="$(stat -f '%u' "$parent_dir" 2>/dev/null || stat -c '%u' "$parent_dir" 2>/dev/null || echo "")"
    if [ "$owner_uid" != "$(id -u)" ]; then
      die "runtime parent directory not owned by current user: $parent_dir"
    fi
    local dir_mode
    dir_mode="$(stat -f '%p' "$parent_dir" 2>/dev/null || stat -c '%a' "$parent_dir" 2>/dev/null || echo "")"
    if [ -n "$dir_mode" ]; then
      while [ "${#dir_mode}" -gt 3 ]; do dir_mode="${dir_mode#?}"; done
      if [ "$dir_mode" != "700" ]; then
        die "runtime parent directory mode must be 0700: $parent_dir (got $dir_mode)"
      fi
    fi
  fi
}

# create_runtime_parent PARENT_DIR
# Create missing parent dirs under a validated ancestor with umask 077.
# Uses physical path resolution to handle macOS system symlinks (/var -> /private/var).
create_runtime_parent() {
  local parent_dir="$1"
  if [ -d "$parent_dir" ]; then
    return 0
  fi

  # Find last existing ancestor: first try raw, but if it lands on a system
  # symlink, resolve physically to find the correct ancestor.
  local p="$parent_dir"
  while [ "$p" != "/" ] && [ ! -d "$p" ] && [ ! -L "$p" ]; do
    p="$(dirname "$p")"
  done

  # If we landed on a symlink, resolve physically.
  if [ -L "$p" ]; then
    p="$(cd "$p" 2>/dev/null && pwd -P 2>/dev/null)" || true
    if [ -z "$p" ] || [ ! -d "$p" ]; then
      die "cannot resolve physical ancestor for: $parent_dir"
    fi
  fi

  if [ ! -d "$p" ]; then
    die "cannot find existing ancestor for: $parent_dir"
  fi
  if [ ! -w "$p" ]; then
    die "ancestor not writable: $p"
  fi

  # Create missing suffix
  umask 077
  mkdir -p "$parent_dir"

  # Revalidate ownership
  local owner_uid
  owner_uid="$(stat -f '%u' "$parent_dir" 2>/dev/null || stat -c '%u' "$parent_dir" 2>/dev/null || echo "")"
  if [ "$owner_uid" != "$(id -u)" ]; then
    die "created runtime parent not owned by current user: $parent_dir"
  fi
}

# ────────────────────────────────────────────────────────────
#  Lock protocol (§3 of ADR)
# ────────────────────────────────────────────────────────────

LOCK_DIR=""

acquire_lock() {
  local runtime_state="$1"
  local parent_dir
  parent_dir="$(dirname "$runtime_state")"
  LOCK_DIR="$parent_dir/heartbeat.lock"

  # Ensure parent exists (for init-runtime case)
  if [ ! -d "$parent_dir" ]; then
    die "runtime parent does not exist; run --init-runtime first"
  fi

  while true; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      # Lock acquired
      chmod 0700 "$LOCK_DIR"
      local now_iso
      now_iso="${HEARTBEAT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
      echo "$$" > "$LOCK_DIR/pid"
      echo "${BOOT_ID:-unknown}" > "$LOCK_DIR/boot_id"
      echo "$now_iso" > "$LOCK_DIR/acquired_at"
      chmod 0600 "$LOCK_DIR/pid" "$LOCK_DIR/boot_id" "$LOCK_DIR/acquired_at"
      register_lock_trap
      return 0
    fi

    # Lock exists — inspect it
    local lock_pid lock_boot
    lock_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")"
    lock_boot="$(cat "$LOCK_DIR/boot_id" 2>/dev/null || echo "")"

    if [ -z "$lock_pid" ]; then
      die "lock metadata unreadable — manual inspection required: $LOCK_DIR"
    fi

    # Validate lock_pid is numeric
    case "$lock_pid" in
      ''|*[!0-9]*) die "lock PID invalid — manual inspection required: $LOCK_DIR" ;;
    esac

    # (a) Live process → contention
    if kill -0 "$lock_pid" 2>/dev/null; then
      echo "FATAL: lock held by live process $lock_pid" >&2
      exit 2
    fi

    # PID is dead — determine staleness
    if [ -z "$BOOT_ID" ]; then
      # (d) Boot identity unavailable, but PID metadata is valid → exit 1
      die "lock from dead PID $lock_pid but boot identity unavailable — use --break-lock"
    fi

    if [ -n "$lock_boot" ] && [ "$lock_boot" != "unknown" ] && [ "$lock_boot" != "$BOOT_ID" ]; then
      # (c) Cross-boot: stale
      :
    elif [ "$lock_boot" = "$BOOT_ID" ]; then
      # (b) Same boot: stale
      :
    else
      # (e) Lock metadata untrusted
      die "lock from dead PID $lock_pid but boot identity cannot be verified — manual inspection required: $LOCK_DIR"
    fi

    # Break stale lock and retry
    rm -rf "$LOCK_DIR"
  done
}

_release_lock() {
  if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
    rm -rf "$LOCK_DIR"
  fi
}

# _add_exit_trap COMMAND — chain a command onto the EXIT trap (Bash 3.2 compat).
_add_exit_trap() {
  local cmd="$1"
  local existing
  existing="$(trap -p EXIT 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "trap -- '' EXIT" ]; then
    existing="${existing#trap -- }"
    existing="${existing% EXIT}"
    [ "${existing#\'}" != "$existing" ] && existing="${existing#\'}"
    [ "${existing%\'}" != "$existing" ] && existing="${existing%\'}"
    trap "$cmd; $existing" EXIT
  else
    trap "$cmd" EXIT
  fi
}

register_lock_trap() {
  _add_exit_trap '_release_lock'
}

do_break_lock() {
  local runtime_state="$1"
  local parent_dir
  parent_dir="$(dirname "$runtime_state")"
  local lock_dir="$parent_dir/heartbeat.lock"

  if [ ! -d "$lock_dir" ]; then
    echo "No lock directory found at $lock_dir"
    exit 0
  fi

  local lock_pid
  lock_pid="$(cat "$lock_dir/pid" 2>/dev/null || echo "")"

  if [ -z "$lock_pid" ]; then
    die "lock metadata unreadable — cannot break: $lock_dir"
  fi

  case "$lock_pid" in
    ''|*[!0-9]*) die "lock PID invalid — cannot break: $lock_dir" ;;
  esac

  if kill -0 "$lock_pid" 2>/dev/null; then
    die "lock held by live process $lock_pid — refusing to break"
  fi

  echo "Breaking lock from dead PID $lock_pid"
  rm -rf "$lock_dir"
  echo "Lock removed."
  exit 0
}

# ────────────────────────────────────────────────────────────
#  State I/O (Python helpers)
# ────────────────────────────────────────────────────────────

command -v python3 >/dev/null 2>&1 || die "python3 is required"

# _python_validate_v2 STATE_PATH
_python_validate_v2() {
  _HB_STATE="$1" python3 - <<'PY'
import datetime, json, os, sys

path = os.environ["_HB_STATE"]
try:
    with open(path) as handle:
        state = json.load(handle)
except Exception as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    raise SystemExit(1)

phases = {
    "0_BOOTSTRAP", "1_CLASSIFY", "2_DELEGATE",
    "3_REVIEW", "4_INTEGRATE", "5_SWEEP",
}

def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)

def valid_timestamp(value, nullable=False):
    if nullable and value is None:
        return True
    if not isinstance(value, str):
        return False
    try:
        datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value.endswith("Z")
    except ValueError:
        return False

errors = []
if state.get("schema_version") != 2:
    errors.append("schema_version must equal 2")
if state.get("phase") not in phases:
    errors.append("phase is missing or unsupported")
if not is_int(state.get("cycle")) or state["cycle"] < 0:
    errors.append("cycle must be a non-negative integer")
if not valid_timestamp(state.get("updated_at")):
    errors.append("updated_at must be an ISO-8601 UTC timestamp")
if not valid_timestamp(state.get("last_heartbeat"), nullable=True):
    errors.append("last_heartbeat must be null or an ISO-8601 UTC timestamp")
if not isinstance(state.get("notes"), str):
    errors.append("notes must be a string")

budget = state.get("budget")
if not isinstance(budget, dict):
    errors.append("budget must be an object")
else:
    used = budget.get("expert_calls_this_cycle")
    maximum = budget.get("max_expert_calls")
    if not is_int(used) or used < 0:
        errors.append("budget.expert_calls_this_cycle must be a non-negative integer")
    if not is_int(maximum) or maximum < 1:
        errors.append("budget.max_expert_calls must be a positive integer")

# previous_checkpoint: optional, must be null or object
pc = state.get("previous_checkpoint")
if pc is not None and not isinstance(pc, dict):
    errors.append("previous_checkpoint must be null or an object")

if errors:
    print("; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
PY
}

# _python_init_runtime SEED_PATH RUNTIME_PATH
_python_init_runtime() {
  _HB_SEED="$1" _HB_RUNTIME="$2" python3 - <<'PY'
import json, os, stat, sys, tempfile

seed_path = os.environ["_HB_SEED"]
runtime_path = os.environ["_HB_RUNTIME"]

with open(seed_path) as handle:
    seed = json.load(handle)

if seed.get("schema_version") != 1:
    print("seed schema_version must be 1", file=sys.stderr)
    raise SystemExit(1)

runtime = dict(seed)
runtime["schema_version"] = 2
runtime["previous_checkpoint"] = None

# Atomic write
directory = os.path.dirname(os.path.abspath(runtime_path))
fd, temporary = tempfile.mkstemp(prefix=".heartbeat-state-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(runtime, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, runtime_path)
    # Directory fsync
    if os.environ.get("_HB_FSYNC_FAIL_INJECT") == "1":
        print("FATAL: simulated directory fsync failure after os.replace", file=sys.stderr)
        raise SystemExit(1)
    try:
        dir_fd = os.open(directory, os.O_RDONLY)
        os.fsync(dir_fd)
        os.close(dir_fd)
    except OSError:
        pass
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

# _python_init_force SEED_PATH RUNTIME_PATH
_python_init_force() {
  _HB_SEED="$1" _HB_RUNTIME="$2" python3 - <<'PY'
import json, os, stat, sys, tempfile

seed_path = os.environ["_HB_SEED"]
runtime_path = os.environ["_HB_RUNTIME"]
directory = os.path.dirname(os.path.abspath(runtime_path))
backup_path = os.path.join(directory, "state.json.bak")

# 1. Backup current runtime state if it exists
if os.path.exists(runtime_path):
    fd, temporary = tempfile.mkstemp(prefix=".heartbeat-backup-", dir=directory, text=True)
    try:
        with open(runtime_path) as src:
            current = src.read()
        with os.fdopen(fd, "w") as dst:
            dst.write(current)
            dst.flush()
            os.fsync(dst.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, backup_path)
        # Directory fsync after backup
        try:
            dir_fd = os.open(directory, os.O_RDONLY)
            os.fsync(dir_fd)
            os.close(dir_fd)
        except OSError:
            pass
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

# 2. Write new state from seed
with open(seed_path) as handle:
    seed = json.load(handle)

if seed.get("schema_version") != 1:
    print("seed schema_version must be 1", file=sys.stderr)
    raise SystemExit(1)

runtime = dict(seed)
runtime["schema_version"] = 2
runtime["previous_checkpoint"] = None

fd, temporary = tempfile.mkstemp(prefix=".heartbeat-state-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(runtime, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, runtime_path)
    if os.environ.get("_HB_FSYNC_FAIL_INJECT") == "1":
        print("FATAL: simulated directory fsync failure after os.replace", file=sys.stderr)
        raise SystemExit(1)
    try:
        dir_fd = os.open(directory, os.O_RDONLY)
        os.fsync(dir_fd)
        os.close(dir_fd)
    except OSError:
        pass
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

# _python_write_state STATE_PATH PHASE CYCLE EXPERT_CALLS LAST_HB NOTES UPDATED_AT
_python_write_state() {
  _HB_STATE_PATH="$1" \
  _HB_PHASE="$2" \
  _HB_CYCLE="$3" \
  _HB_EXPERT_CALLS="$4" \
  _HB_LAST_HEARTBEAT="$5" \
  _HB_NOTES="$6" \
  _HB_UPDATED_AT="$7" \
  python3 - <<'PY' || die "failed to write state file"
import json, os, stat, sys, tempfile

path = os.environ["_HB_STATE_PATH"]
with open(path) as handle:
    state = json.load(handle)

# Capture previous_checkpoint: snapshot of all mutable fields before mutation
mutable_fields = ["phase", "cycle", "budget", "last_heartbeat", "updated_at", "notes"]
prev = {}
for field in mutable_fields:
    prev[field] = state.get(field)
# Strip nested previous_checkpoint
prev.pop("previous_checkpoint", None)

state["previous_checkpoint"] = prev
state["updated_at"] = os.environ["_HB_UPDATED_AT"]
state["phase"] = os.environ["_HB_PHASE"]
state["cycle"] = int(os.environ["_HB_CYCLE"])
state["budget"]["expert_calls_this_cycle"] = int(os.environ["_HB_EXPERT_CALLS"])
state["last_heartbeat"] = os.environ["_HB_LAST_HEARTBEAT"] or None
state["notes"] = os.environ["_HB_NOTES"]

directory = os.path.dirname(os.path.abspath(path))
fd, temporary = tempfile.mkstemp(prefix=".heartbeat-state-", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(state, handle, indent=2)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    # Directory fsync (with injectable failure for tests)
    if os.environ.get("_HB_FSYNC_FAIL_INJECT") == "1":
        print("FATAL: simulated directory fsync failure after os.replace", file=sys.stderr)
        raise SystemExit(1)
    try:
        dir_fd = os.open(directory, os.O_RDONLY)
        os.fsync(dir_fd)
        os.close(dir_fd)
    except OSError:
        pass
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

# _python_field STATE_PATH DOT_NOTATED_KEY
_python_field() {
  _HB_STATE="$1" _HB_KEY="$2" python3 - <<'PY'
import json, os

with open(os.environ["_HB_STATE"]) as handle:
    value = json.load(handle)
for part in os.environ["_HB_KEY"].split("."):
    value = value[part]
if value is None:
    print("")
else:
    print(value)
PY
}

# ────────────────────────────────────────────────────────────
#  Tempfile cleanup
# ────────────────────────────────────────────────────────────

cleanup_tempfiles() {
  local parent_dir
  parent_dir="$(dirname "$STATE_FILE")"
  if [ -d "$parent_dir" ]; then
    local f
    for f in "$parent_dir"/.heartbeat-state-* "$parent_dir"/.heartbeat-backup-*; do
      [ -e "$f" ] || continue
      rm -f "$f"
    done
  fi
}

# ────────────────────────────────────────────────────────────
#  --break-lock mode
# ────────────────────────────────────────────────────────────

if $BREAK_LOCK; then
  validate_path "$STATE_FILE"
  do_break_lock "$STATE_FILE"
fi

# ────────────────────────────────────────────────────────────
#  --init-runtime mode
# ────────────────────────────────────────────────────────────

if $INIT_RUNTIME; then
  # Seed must exist and be valid v1
  [ -f "$SEED_FILE" ] || die "seed file not found: $SEED_FILE"
  [ ! -L "$SEED_FILE" ] || die "seed file must not be a symbolic link: $SEED_FILE"

  # Validate seed path ancestry
  validate_path "$SEED_FILE" true

  # Validate runtime path ancestry and create parent if needed
  validate_path "$STATE_FILE"
  create_runtime_parent "$(dirname "$STATE_FILE")"

  # Cleanup stale tempfiles before acquiring lock
  cleanup_tempfiles

  # Acquire lock
  acquire_lock "$STATE_FILE"

  if $FORCE_INIT; then
    if _python_init_force_out="$(_python_init_force "$SEED_FILE" "$STATE_FILE" 2>&1)"; then
      echo "Runtime state re-initialized from seed: $STATE_FILE"
      exit 0
    else
      echo "FATAL: $python_init_force_out" >&2
      exit 1
    fi
  else
    if [ -f "$STATE_FILE" ]; then
      die "runtime state already exists: $STATE_FILE (use --force to re-initialize)"
    fi
    if _python_init_runtime_out="$(_python_init_runtime "$SEED_FILE" "$STATE_FILE" 2>&1)"; then
      echo "Runtime state initialized: $STATE_FILE"
      exit 0
    else
      echo "FATAL: $python_init_runtime_out" >&2
      exit 1
    fi
  fi
fi

# ────────────────────────────────────────────────────────────
#  Normal heartbeat
# ────────────────────────────────────────────────────────────

# Validate runtime state path
validate_path "$STATE_FILE" true

# Cleanup stale tempfiles
cleanup_tempfiles

# Acquire lock (skip for dry-run)
if ! $DRY_RUN; then
  acquire_lock "$STATE_FILE"
fi

# Validate runtime state as schema v2
if ! validation_error="$(_python_validate_v2 "$STATE_FILE" 2>&1)"; then
  die "invalid runtime state: $validation_error"
fi

# ────────────────────────────────────────────────────────────
#  Decision engine (unchanged logic from v1.1)
# ────────────────────────────────────────────────────────────

state_field() {
  _python_field "$STATE_FILE" "$1"
}

now_iso="${HEARTBEAT_NOW:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"
runtime_tmp="$(mktemp -d)"
# Chain runtime_tmp cleanup onto existing EXIT trap (which may include lock release)
_add_exit_trap 'rm -rf "$runtime_tmp"'
if ! _HB_NOW="$now_iso" python3 - > "$runtime_tmp/now-epoch" 2>/dev/null <<'PY'
import datetime
import os

value = os.environ["_HB_NOW"]
parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
if not value.endswith("Z") or parsed.tzinfo is None:
    raise ValueError("HEARTBEAT_NOW must be ISO-8601 UTC")
print(int(parsed.timestamp()))
PY
then
  die "invalid HEARTBEAT_NOW: $now_iso"
fi
now_epoch="$(cat "$runtime_tmp/now-epoch")"

write_state() {
  local phase="$1" cycle="$2" expert_calls="$3" last_heartbeat="$4" notes="$5"
  $DRY_RUN && return 0
  _python_write_state "$STATE_FILE" "$phase" "$cycle" "$expert_calls" "$last_heartbeat" "$notes" "$now_iso"
}

emit_action() {
  echo "ACTION: $*"
}

stop_action() {
  local reason="$1" note="$2"
  write_state "$phase" "$cycle" "$expert_calls" "$now_iso" "$note"
  emit_action "STOP" "$reason"
}

visibility_stop() {
  local reason="$1"
  emit_action "STOP" "$reason"
}

phase="$(state_field phase)"
cycle="$(state_field cycle)"
expert_calls="$(state_field budget.expert_calls_this_cycle)"
max_expert="$(state_field budget.max_expert_calls)"

# Bootstrap is local-only. It does not require GitHub visibility.
if [ "$phase" = "0_BOOTSTRAP" ]; then
  if ! git_status="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal 2>/dev/null)"; then
    stop_action "local repository status unavailable — cannot run heartbeat" "STOP: git status failed"
    exit 2
  fi
  if [ -n "$git_status" ]; then
    stop_action "uncommitted changes in working tree — cannot run heartbeat" "STOP: dirty git tree"
    exit 0
  fi

  write_state "1_CLASSIFY" "$((cycle + 1))" "$expert_calls" "$now_iso" "bootstrap OK, advancing"
  emit_action "ADVANCE" "bootstrap clean → 1_CLASSIFY"
  exit 0
fi

# GitHub is the read-only control plane.
command -v gh >/dev/null 2>&1 || {
  visibility_stop "GitHub visibility unavailable: gh not found"
  exit 2
}

if ! prs_json="$(cd "$REPO_ROOT" 2>/dev/null && unset GH_REPO GH_HOST && gh pr list --state open --limit 1000 --json number,updatedAt 2>/dev/null)"; then
  visibility_stop "GitHub visibility unavailable: open PR query failed"
  exit 2
fi
if ! issues_json="$(cd "$REPO_ROOT" 2>/dev/null && unset GH_REPO GH_HOST && gh issue list --state open --limit 1000 --json number,updatedAt,labels 2>/dev/null)"; then
  visibility_stop "GitHub visibility unavailable: open issue query failed"
  exit 2
fi

printf '%s' "$prs_json" > "$runtime_tmp/prs.json"
printf '%s' "$issues_json" > "$runtime_tmp/issues.json"

# Output is five integers: WIP_COUNT STALE_PR STALE_ISSUE REVIEW_PR BUILD_ISSUE
if ! _HB_PRS="$runtime_tmp/prs.json" \
  _HB_ISSUES="$runtime_tmp/issues.json" \
  _HB_NOW_EPOCH="$now_epoch" \
  _HB_STALE_PR="$STALE_DAYS_PR" \
  _HB_STALE_ISSUE="$STALE_DAYS_ISSUE" \
  python3 - > "$runtime_tmp/decision" 2>/dev/null <<'PY'
import datetime
import json
import os

with open(os.environ["_HB_PRS"]) as handle:
    prs = json.load(handle)
with open(os.environ["_HB_ISSUES"]) as handle:
    issues = json.load(handle)
if not isinstance(prs, list) or not isinstance(issues, list):
    raise ValueError("GitHub list responses must be arrays")

def parse_time(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("updatedAt must be an ISO-8601 UTC string")
    return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())

def validate_number(value):
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError("number must be a positive integer")
    return value

normalized_prs = []
for pr in prs:
    if not isinstance(pr, dict):
        raise ValueError("PR entries must be objects")
    number = validate_number(pr.get("number"))
    updated = parse_time(pr.get("updatedAt"))
    normalized_prs.append((updated, number))

normalized_issues = []
for issue in issues:
    if not isinstance(issue, dict):
        raise ValueError("issue entries must be objects")
    number = validate_number(issue.get("number"))
    updated = parse_time(issue.get("updatedAt"))
    labels = issue.get("labels")
    if not isinstance(labels, list):
        raise ValueError("issue labels must be an array")
    names = []
    for label in labels:
        if not isinstance(label, dict) or not isinstance(label.get("name"), str):
            raise ValueError("issue labels must contain string names")
        names.append(label["name"])
    normalized_issues.append((updated, number, names))

normalized_prs.sort(key=lambda item: (item[0], item[1]))
normalized_issues.sort(key=lambda item: (item[0], item[1]))
now = int(os.environ["_HB_NOW_EPOCH"])
pr_cutoff = now - int(os.environ["_HB_STALE_PR"]) * 86400
issue_cutoff = now - int(os.environ["_HB_STALE_ISSUE"]) * 86400

stale_pr = next((number for updated, number in normalized_prs if updated < pr_cutoff), 0)
stale_issue = next((number for updated, number, _ in normalized_issues if updated < issue_cutoff), 0)
review_pr = normalized_prs[0][1] if normalized_prs else 0

build_issue = 0
for _, number, labels in normalized_issues:
    if "approved" in labels:
        build_issue = number
        break

print(len(normalized_prs), stale_pr, stale_issue, review_pr, build_issue)
PY
then
  visibility_stop "GitHub visibility unavailable: malformed list response"
  exit 2
fi

decision_tuple="$(cat "$runtime_tmp/decision")"

case "$decision_tuple" in
  ""|*[!0-9\ ]*)
    visibility_stop "GitHub visibility unavailable: invalid decision data"
    exit 2
    ;;
esac

set -- $decision_tuple
if [ "$#" -ne 5 ]; then
  visibility_stop "GitHub visibility unavailable: invalid decision data"
  exit 2
fi
wip="$1"
stale_pr="$2"
stale_issue="$3"
review_pr="$4"
build_issue="$5"

if [ "$wip" -gt 1 ]; then
  stop_action "WIP cap violated: $wip open PRs (limit 1)" "STOP: WIP cap ($wip open PRs)"
  exit 0
fi

if [ "$expert_calls" -ge "$max_expert" ]; then
  stop_action "budget cap: $expert_calls/$max_expert expert calls used" "STOP: budget cap"
  exit 0
fi

if [ "$stale_pr" -gt 0 ]; then
  write_state "5_SWEEP" "$cycle" "$expert_calls" "$now_iso" "SWEEP: stale PR #$stale_pr"
  emit_action "SWEEP" "PR #$stale_pr — no activity for >${STALE_DAYS_PR} days"
  exit 0
fi

if [ "$stale_issue" -gt 0 ]; then
  write_state "5_SWEEP" "$cycle" "$expert_calls" "$now_iso" "SWEEP: stale issue #$stale_issue"
  emit_action "SWEEP" "issue #$stale_issue — no activity for >${STALE_DAYS_ISSUE} days"
  exit 0
fi

if [ "$review_pr" -gt 0 ]; then
  write_state "3_REVIEW" "$cycle" "$expert_calls" "$now_iso" "REVIEW: PR #$review_pr"
  emit_action "REVIEW" "PR #$review_pr"
  exit 0
fi

if [ "$build_issue" -gt 0 ]; then
  write_state "2_DELEGATE" "$cycle" "$expert_calls" "$now_iso" "BUILD: issue #$build_issue"
  emit_action "BUILD" "issue #$build_issue"
  exit 0
fi

write_state "$phase" "$cycle" "$expert_calls" "$now_iso" "HOLD: no work"
emit_action "HOLD" "nothing to do — WIP=$wip, no approved issues without PR, no stale items"
