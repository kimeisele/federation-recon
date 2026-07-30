#!/bin/sh
set -e

# worker_exec.sh — root-owned gateway into the seatbelt sandbox.
# The sudoers line permits ONLY this script as the slot uid.  The caller
# supplies a validated run-id and canary name; workspace, profile, and
# canary directory are hard-coded below.
#
# Invoked via "sudo -u <slot_name> .../worker_exec.sh <run_id> <canary_name>".
# The slot uid derives its identity from the uid switch, not from a
# command-line argument.

[ $# -eq 2 ] || {
    echo "worker_exec.sh: expected exactly 2 arguments, got $#" >&2
    exit 1
}

# sudo started us with the caller's cwd.  The worker must not read it,
# which would cause every getcwd call to fail.  Switch away immediately.
cd / || exit 1

RUN_ID="$1"
CANARY_NAME="$2"

# Reject any argument containing a newline — embedded newlines bypass
# grep's line-oriented matching and can inject path separators or
# options.  The case test below is a whole-string match that cannot be
# fooled by newlines.
case "$RUN_ID" in
  *[!A-Za-z0-9_-]*)
    echo "worker_exec.sh: invalid run_id (contains disallowed characters)" >&2
    exit 1
    ;;
esac
# Length check: 1-64 characters.
RUN_ID_LEN="${#RUN_ID}"
[ "$RUN_ID_LEN" -ge 1 ] && [ "$RUN_ID_LEN" -le 64 ] || {
    echo "worker_exec.sh: invalid run_id length ${RUN_ID_LEN} (expected 1-64)" >&2
    exit 1
}

# Validate canary name: lowercase letters and underscores, 1-32 chars.
# Same whole-string discipline — case cannot be fooled by newlines.
case "$CANARY_NAME" in
  *[!a-z_]*)
    echo "worker_exec.sh: invalid canary_name (contains disallowed characters)" >&2
    exit 1
    ;;
esac
CANARY_LEN="${#CANARY_NAME}"
[ "$CANARY_LEN" -ge 1 ] && [ "$CANARY_LEN" -le 32 ] || {
    echo "worker_exec.sh: invalid canary_name length ${CANARY_LEN} (expected 1-32)" >&2
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

# Resource limits are applied HERE, after the uid switch, so RLIMIT_NPROC
# counts the slot's processes (per-run) rather than the owner's.
# Applied before exec, inherited by everything below.
# Fail-closed: if a limit cannot be applied, the wrapper exits non-zero
# before exec.
#
# Note: RLIMIT_NPROC is per-uid on macOS.  With per-run uids (slot pool)
# this limit is now per-RUN, which is what bounds the kill protocol's
# convergence — with a shared uid it bounded nothing.
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
# Python holds the cwd in the module search path.  If it is outside the
# workspace, every import fails with PermissionError.
cd "$WORKSPACE" || exit 1

exec /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/sandbox-exec -f "$PROFILE" -D "WORKSPACE=$WORKSPACE" \
    /Library/Developer/CommandLineTools/usr/bin/python3 "$CANARY_SCRIPT" "$WORKSPACE"
