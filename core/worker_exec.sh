#!/bin/sh
set -e

# worker_exec.sh — root-owned gateway into the seatbelt sandbox.
# The sudoers line permits ONLY this script; no other command may run
# as _jcode_worker.  The caller cannot supply a profile or choose a
# workspace path — both are fixed below and are the whole game.

[ $# -eq 1 ] || {
    echo "worker_exec.sh: expected exactly 1 argument, got $#" >&2
    exit 1
}

RUN_ID="$1"

# Reject anything that is not a short alphanumeric + dash + underscore token.
# This keeps the caller from injecting path separators or options.
echo "$RUN_ID" | grep -qE '^[A-Za-z0-9_-]{1,64}$' || {
    echo "worker_exec.sh: invalid run_id '$RUN_ID'" >&2
    exit 1
}

BASE="/tmp/jcode_sandbox"
WORKSPACE="$BASE/$RUN_ID"
PROFILE="$(cd "$(dirname "$0")" && pwd)/profiles/worker.sb"

# env -i guarantees the owner's environment never crosses the boundary.
exec /usr/bin/env -i PATH=/usr/bin:/bin \
    /usr/bin/sandbox-exec -f "$PROFILE" -D "WORKSPACE=$WORKSPACE" \
    /usr/bin/python3 "$WORKSPACE/canary.py"
