#!/bin/sh
set -e

# worker_exec.sh — root-owned gateway into the seatbelt sandbox.
# The sudoers line permits ONLY this script; no other command may run
# as _jcode_worker.  The caller supplies a validated run-id and canary
# name; workspace, profile, and canary directory are hard-coded below.

[ $# -eq 2 ] || {
    echo "worker_exec.sh: expected exactly 2 arguments, got $#" >&2
    exit 1
}

# sudo startet uns mit dem cwd des Aufrufers. Der Worker darf es nicht
# lesen, was jeden getcwd-Aufruf scheitern laesst. Sofort wegwechseln.
cd / || exit 1

RUN_ID="$1"
CANARY_NAME="$2"

# Validate run-id: short alphanumeric + dash + underscore token.
# This keeps the caller from injecting path separators or options.
echo "$RUN_ID" | grep -qE '^[A-Za-z0-9_-]{1,64}$' || {
    echo "worker_exec.sh: invalid run_id '$RUN_ID'" >&2
    exit 1
}

# Validate canary name: lowercase letters and underscores, 1-32 chars.
echo "$CANARY_NAME" | grep -qE '^[a-z_]{1,32}$' || {
    echo "worker_exec.sh: invalid canary_name '$CANARY_NAME'" >&2
    exit 1
}

# ── Hard-coded trusted base — these define the boundary ─────────────────
BASE="/usr/local/var/jcode-runs"
CANARY_DIR="$BASE/canaries"
PROFILE="$BASE/profiles/worker.sb"

WORKSPACE="$BASE/runs/$RUN_ID"
CANARY_SCRIPT="$CANARY_DIR/${CANARY_NAME}.py"

# Reject any name that does not resolve to an existing file in the
# root-owned canary directory.  The workspace is scratch/output only;
# nothing is ever executed from it.
[ -f "$CANARY_SCRIPT" ] || {
    echo "worker_exec.sh: canary script not found: $CANARY_SCRIPT" >&2
    exit 1
}

# Resource limits are applied HERE, not by the caller: sudo has already
# switched to the worker uid, so RLIMIT_NPROC counts the worker's processes
# rather than the owner's. Applied before exec, inherited by everything below.
# Fail-closed: if a limit cannot be applied, the wrapper exits non-zero before
# exec.  Silently continuing without an enforced limit while claiming it is
# the defect this infrastructure exists to prevent.
ulimit -u 64  2>/dev/null || {
    echo "worker_exec.sh: FAILED to set RLIMIT_NPROC (ulimit -u 64)" >&2
    exit 1
}
ulimit -t 30  2>/dev/null || {
    echo "worker_exec.sh: FAILED to set RLIMIT_CPU (ulimit -t 30)" >&2
    exit 1
}
ulimit -f 10240  2>/dev/null || {
    echo "worker_exec.sh: FAILED to set RLIMIT_FSIZE (ulimit -f 10240)" >&2
    exit 1
}

# env -i guarantees the owner's environment never crosses the boundary.
# The workspace path is passed as a positional argument so the canary
# script knows where to write results (it lives outside the workspace).
# Python haelt das cwd im Modulsuchpfad. Liegt es ausserhalb des
# Workspace, scheitert jeder Import mit PermissionError.
cd "$WORKSPACE" || exit 1

exec /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/sandbox-exec -f "$PROFILE" -D "WORKSPACE=$WORKSPACE" \
    /Library/Developer/CommandLineTools/usr/bin/python3 "$CANARY_SCRIPT" "$WORKSPACE"
