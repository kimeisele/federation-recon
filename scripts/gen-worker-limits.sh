#!/usr/bin/env bash
# gen-worker-limits.sh — one source of truth for the sandbox's resource limits.
#
# core/policy.json declares the sandbox limits in its "limits" object; this
# script DERIVES the ulimit lines that core/worker_exec.sh bakes in.  The
# wrapper runs as the sandboxed worker under sudo and has no business reading
# repository files, so it cannot consult the policy at runtime.  Instead the
# generator writes the numbers, and `--check` turns any drift between the two
# into a failing build.
#
# Usage:
#   gen-worker-limits.sh [--policy PATH] [--wrapper PATH] [--check|--block-size]
#
# Default: read core/policy.json and print the three ulimit lines it implies,
# one per line, in exactly the form the wrapper uses.
#
#   --policy PATH   read that policy instead (values are COMPUTED from it,
#                   never printed from constants)
#   --wrapper PATH  check that wrapper instead of core/worker_exec.sh
#   --check         exit 0 iff the wrapper's ulimit lines match what the
#                   policy implies; otherwise exit non-zero, name the limit
#                   that drifted, and print both numbers
#
# Conversion: `ulimit -f` counts blocks whose size is MEASURED at run time by
# measure_block_size(), not assumed. See the note above.
# `ulimit -u` and `ulimit -t` take the policy's values directly.
#
# Requires: bash 3.2+, python3 for JSON.  No jq, no new dependencies.


# ── The block size is MEASURED, never assumed ─────────────────────────────
#
# It was written as 512 here, taken from a comment in core/worker_exec.sh that
# nobody had ever run, then repeated by a reviewer, by the operator, and by a
# test. Four places agreeing about a number none of them had measured.
#
# On this platform it is 1024:
#
#     ulimit -f 1  ->  1024 bytes written ok, 1025 blocked
#     ulimit -f 2  ->  2048 bytes written ok, 2049 blocked
#
# Which means the original `ulimit -f 10240` was exactly the policy's 10485760
# bytes, the "drift" this script was written to repair did not exist, and
# generating from 512 would have DOUBLED the sandbox's file-size limit.
#
# So it is measured: set `ulimit -f 1` in a subshell and find the largest write
# that survives. Measured once per process.

BLOCK_SIZE_CACHE=""
measure_block_size() {
    if [ -n "$BLOCK_SIZE_CACHE" ]; then
        printf '%s' "$BLOCK_SIZE_CACHE"
        return 0
    fi
    local candidate last out rc
    last=""
    for candidate in 128 256 512 1024 2048 4096 8192 16384; do
        out="$(mktemp)"
        ( ulimit -f 1 2>/dev/null || exit 2
          dd if=/dev/zero of="$out" bs=1 count="$candidate" 2>/dev/null ) >/dev/null 2>&1
        rc=$?
        rm -f "$out"
        if [ "$rc" -ne 0 ]; then
            break
        fi
        last="$candidate"
    done
    if [ -z "$last" ]; then
        echo "gen-worker-limits.sh: could not measure the ulimit -f block size" >&2
        return 1
    fi
    BLOCK_SIZE_CACHE="$last"
    printf '%s' "$last"
}

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

POLICY="$REPO_ROOT/core/policy.json"
WRAPPER="$REPO_ROOT/core/worker_exec.sh"
CHECK=false
WRAPPER_SET=false

usage() {
    echo "usage: gen-worker-limits.sh [--policy PATH] [--wrapper PATH] [--check]" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --policy)
            [ $# -ge 2 ] || usage
            POLICY="$2"
            shift 2
            ;;
        --wrapper)
            [ $# -ge 2 ] || usage
            WRAPPER="$2"
            WRAPPER_SET=true
            shift 2
            ;;
        --check)
            CHECK=true
            shift
            ;;
        --block-size)
            # The measurement itself, so a test can compare against the value
            # production uses rather than re-declaring a constant of its own.
            # A test that carries its own copy of a number passes when
            # production breaks — which is exactly how a 512 that nobody had
            # run reached four separate places.
            measure_block_size || exit 1
            echo
            exit 0
            ;;
        *)
            usage
            ;;
    esac
done

if $WRAPPER_SET && ! $CHECK; then
    echo "gen-worker-limits.sh: --wrapper is only meaningful with --check" >&2
    exit 2
fi

# limits_for <policy> — print the three ulimit lines the policy implies.
limits_for() {
    python3 - "$1" "$(measure_block_size)" <<'PY'
import json, sys
BLOCK = int(sys.argv[2])          # measured, not assumed — see the note above
with open(sys.argv[1]) as f:
    d = json.load(f)
lim = d["limits"]
fsize = int(lim["rlimit_fsize_bytes"])
if fsize % BLOCK != 0:
    sys.stderr.write(
        "gen-worker-limits.sh: rlimit_fsize_bytes %d is not a multiple of %d "
        "(the measured ulimit -f block size)\n" % (fsize, BLOCK))
    sys.exit(1)
print("ulimit -u %d" % int(lim["rlimit_nproc"]))
print("ulimit -t %d" % int(lim["rlimit_cpu_seconds"]))
print("ulimit -f %d" % (fsize // BLOCK))
PY
}

# check_limits <policy> <wrapper> — exit 0 iff the wrapper's ulimit lines
# match what the policy implies.  On mismatch, name the drifting limit and
# print both numbers.
check_limits() {
    python3 - "$1" "$2" "$(measure_block_size)" <<'PY'
import json, re, sys
policy_path, wrapper_path = sys.argv[1], sys.argv[2]
BLOCK = int(sys.argv[3])          # measured, not assumed — see the note above
with open(policy_path) as f:
    d = json.load(f)
lim = d["limits"]
nproc = int(lim["rlimit_nproc"])
cpu = int(lim["rlimit_cpu_seconds"])
fsize = int(lim["rlimit_fsize_bytes"])
if fsize % BLOCK != 0:
    sys.stderr.write(
        "gen-worker-limits.sh: rlimit_fsize_bytes %d is not a multiple of %d "
        "(the measured ulimit -f block size)\n" % (fsize, BLOCK))
    sys.exit(1)
fsize_blocks = fsize // BLOCK

with open(wrapper_path) as f:
    wrapper = f.read()

def wrapper_value(flag):
    m = re.search(r"^ulimit -%s[ \t]+([0-9]+)" % flag, wrapper, re.M)
    return int(m.group(1)) if m else None

bad = 0
for flag, want in (("u", nproc), ("t", cpu), ("f", fsize_blocks)):
    got = wrapper_value(flag)
    if got is None:
        sys.stderr.write(
            "gen-worker-limits.sh: wrapper has no `ulimit -%s` line\n" % flag)
        bad = 1
    elif got != want:
        if flag == "f":
            sys.stderr.write(
                "gen-worker-limits.sh: wrapper `ulimit -f %d` (%d blocks = %d bytes) "
                "disagrees with policy rlimit_fsize_bytes %d (%d blocks)\n"
                % (got, got, got * BLOCK, fsize, want))
        else:
            key = "rlimit_nproc" if flag == "u" else "rlimit_cpu_seconds"
            sys.stderr.write(
                "gen-worker-limits.sh: wrapper `ulimit -%s %d` disagrees with "
                "policy %s %d\n" % (flag, got, key, want))
        bad = 1

sys.exit(bad)
PY
}

if $CHECK; then
    check_limits "$POLICY" "$WRAPPER"
else
    limits_for "$POLICY"
fi
