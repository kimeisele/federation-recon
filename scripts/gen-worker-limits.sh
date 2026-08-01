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
#   gen-worker-limits.sh [--policy PATH] [--wrapper PATH] [--check]
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
# Conversion: `ulimit -f` counts 512-byte blocks, so blocks = bytes / 512.
# `ulimit -u` and `ulimit -t` take the policy's values directly.
#
# Requires: bash 3.2+, python3 for JSON.  No jq, no new dependencies.

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
    python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
lim = d["limits"]
fsize = int(lim["rlimit_fsize_bytes"])
if fsize % 512 != 0:
    sys.stderr.write(
        "gen-worker-limits.sh: rlimit_fsize_bytes %d is not a multiple of 512 "
        "(ulimit -f counts 512-byte blocks)\n" % fsize)
    sys.exit(1)
print("ulimit -u %d" % int(lim["rlimit_nproc"]))
print("ulimit -t %d" % int(lim["rlimit_cpu_seconds"]))
print("ulimit -f %d" % (fsize // 512))
PY
}

# check_limits <policy> <wrapper> — exit 0 iff the wrapper's ulimit lines
# match what the policy implies.  On mismatch, name the drifting limit and
# print both numbers.
check_limits() {
    python3 - "$1" "$2" <<'PY'
import json, re, sys
policy_path, wrapper_path = sys.argv[1], sys.argv[2]
with open(policy_path) as f:
    d = json.load(f)
lim = d["limits"]
nproc = int(lim["rlimit_nproc"])
cpu = int(lim["rlimit_cpu_seconds"])
fsize = int(lim["rlimit_fsize_bytes"])
if fsize % 512 != 0:
    sys.stderr.write(
        "gen-worker-limits.sh: rlimit_fsize_bytes %d is not a multiple of 512 "
        "(ulimit -f counts 512-byte blocks)\n" % fsize)
    sys.exit(1)
fsize_blocks = fsize // 512

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
                % (got, got, got * 512, fsize, want))
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
