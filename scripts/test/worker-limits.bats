#!/usr/bin/env bats
# worker-limits.bats — the sandbox's limits must be derived and MEASURED.
#
# ── The mistake this file exists to prevent, made while writing this file ──
#
# A cross-provider re-review of the S1 backend (#144) reported that the sandbox
# had two disagreeing sources of truth:
#
#   core/worker_exec.sh   ulimit -f 10240   -> "10240 × 512 B = 5 MiB"
#   core/policy.json      rlimit_fsize_bytes:  10485760       = 10 MiB
#
# The operator accepted that without running it, wrote an acceptance asserting
# `blocks * 512 == declared`, and dispatched a builder against it. The builder
# satisfied the acceptance exactly: `ulimit -f 20480`.
#
# Measured afterwards, on this platform:
#
#   ulimit -f 1  ->  1024 bytes written ok, 1025 blocked
#   ulimit -f 2  ->  2048 bytes written ok, 2049 blocked
#
# The block size is 1024. So `ulimit -f 10240` was 10 MiB and matched the
# policy EXACTLY — there was never any drift — and the "fix" would have set the
# sandbox's file-size limit to twenty MiB, twice what the policy declares, to
# repair a defect that did not exist.
#
# The 512 came from a comment in the wrapper that nobody had ever run, and it
# was repeated by a reviewer, and then by the operator, and then encoded in a
# test. Four places agreeing about a number none of them had measured.
#
# ── What survives ──────────────────────────────────────────────────────────
#
# The wrapper stays at 10240. What was actually wrong is that the conversion
# rested on an unverified constant and that three components set these limits
# independently. So the block size is now MEASURED by writing to a file under
# `ulimit -f 1`, the generator derives from the policy using that measurement,
# and a drifted wrapper fails the build.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WRAPPER="$REPO_ROOT/core/worker_exec.sh"
  POLICY="$REPO_ROOT/core/policy.json"
  GEN="$REPO_ROOT/scripts/gen-worker-limits.sh"
}

@test "worker-limits: a generator exists and is executable" {
  [ -x "$GEN" ]
}

@test "worker-limits: the committed wrapper matches what the generator emits" {
  # The check that turns drift into a failing build instead of a surprise nine
  # days later.
  run bash "$GEN" --check
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "worker-limits: the ulimit block size is MEASURED, never assumed" {
  # The load-bearing constant, and the one this whole change got wrong.
  #
  # The first version of this test asserted `blocks * 512 == declared`, because
  # a re-review said `ulimit -f` counts 512-byte blocks and a comment in the
  # wrapper said the same. Neither had run it. On this platform it is 1024:
  #
  #     ulimit -f 1  ->  1024 bytes written ok, 1025 blocked
  #     ulimit -f 2  ->  2048 bytes written ok, 2049 blocked
  #
  # So the original `ulimit -f 10240` was 10 MiB and matched the policy exactly.
  # There was no drift. The "fix" built against the wrong constant emitted
  # `ulimit -f 20480` — twenty MiB, DOUBLE the policy — and made the sandbox
  # more permissive to repair a defect that did not exist.
  #
  # This test measures. If the platform ever answers differently, it fails here
  # rather than silently doubling a sandbox limit.
  run bash -c '
    probe() {
      ( ulimit -f 1 2>/dev/null || exit 2
        out=$(mktemp)
        dd if=/dev/zero of="$out" bs=1 count=$1 2>/dev/null
        rc=$?
        rm -f "$out"
        exit $rc ) 2>/dev/null
    }
    probe 1024 || { echo "1024 bytes blocked at ulimit -f 1"; exit 1; }
    probe 1025 && { echo "1025 bytes allowed at ulimit -f 1 — block size is larger"; exit 1; }
    echo "measured block size: 1024 bytes"
  '
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "worker-limits: the wrapper's file-size limit equals the policy's, in bytes" {
  # In the units that matter, with the block size taken from the generator
  # rather than re-declared here — a test that carries its own copy of a
  # constant passes when production breaks.
  run python3 - "$WRAPPER" "$POLICY" "$GEN" <<'PY'
import json, re, subprocess, sys
wrapper, policy = open(sys.argv[1]).read(), json.load(open(sys.argv[2]))
block = int(subprocess.run(["bash", sys.argv[3], "--block-size"],
                           capture_output=True, text=True).stdout.strip())
m = re.search(r'^ulimit -f (\d+)', wrapper, re.M)
assert m, "no `ulimit -f` in the wrapper"
blocks = int(m.group(1))
declared = policy["limits"]["rlimit_fsize_bytes"]
print("block size the generator uses: %d" % block)
print("wrapper: %d blocks x %d = %d bytes" % (blocks, block, blocks * block))
print("policy : %d bytes" % declared)
assert blocks * block == declared, (
    "the wrapper enforces %d bytes and the policy declares %d"
    % (blocks * block, declared))
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "worker-limits: the CPU and process limits also agree with the policy" {
  run python3 - "$WRAPPER" "$POLICY" <<'PY'
import json, re, sys
wrapper, policy = open(sys.argv[1]).read(), json.load(open(sys.argv[2]))
lim = policy["limits"]
for flag, key, factor in (("u", "rlimit_nproc", 1), ("t", "rlimit_cpu_seconds", 1)):
    m = re.search(r'^ulimit -%s (\d+)' % flag, wrapper, re.M)
    assert m, "no `ulimit -%s` in the wrapper" % flag
    got, want = int(m.group(1)) * factor, lim[key]
    print("ulimit -%s: wrapper %d, policy %s %d" % (flag, got, key, want))
    assert got == want, "ulimit -%s is %d, policy says %d" % (flag, got, want)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "worker-limits: a drifted wrapper is caught" {
  # Without this the generator could emit anything and the check could compare
  # it to itself. The mutation is performed on a copy; the real wrapper is not
  # touched.
  tmp="$BATS_TEST_TMPDIR/worker_exec.sh"
  sed 's/^ulimit -f [0-9]*/ulimit -f 99/' "$WRAPPER" > "$tmp"
  run bash "$GEN" --check --wrapper "$tmp"
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ulimit -f"* || "$output" == *"fsize"* ]]
}

@test "worker-limits: changing the policy changes what the generator emits" {
  # Derived, not copied. If the generator ignores the policy it passes every
  # test above by accident.
  tmp="$BATS_TEST_TMPDIR/policy.json"
  python3 -c "
import json,sys
p=json.load(open('$POLICY')); p['limits']['rlimit_fsize_bytes']=2097152
json.dump(p, open('$tmp','w'), indent=2)"
  run bash "$GEN" --policy "$tmp"
  echo "$output"
  [ "$status" -eq 0 ]
  # 2 MiB / 1024 = 2048 blocks — the measured block size, not a guess
  [[ "$output" == *"ulimit -f 2048"* ]]
}
