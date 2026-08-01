#!/usr/bin/env bats
# worker-limits.bats — the sandbox must have ONE source of truth for its limits.
#
# A cross-provider re-review of the S1 backend (#144) found two, and they
# already disagreed:
#
#   core/worker_exec.sh   ulimit -f 10240      -> 10240 × 512 B = 5 MiB
#   core/policy.json      rlimit_fsize_bytes:   10485760        = 10 MiB
#
# `ulimit -f` counts 512-byte blocks. Both values have been on main since S1
# merged. Nothing was broken by it — the enforced limit is the stricter one, so
# it failed safe — and that is exactly why nobody noticed for nine days.
#
# What it shows is that `policy.json` is not the source of truth it is
# documented to be. The order validator refuses limits by subtracting from it;
# the sandbox enforces numbers hand-written in a shell script. An order admitted
# against a 10 MiB budget runs under 5 MiB.
#
# Correcting the number would leave two sources that agree today. These tests
# demand that the wrapper's values be DERIVED, and that drift be a red build.

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

@test "worker-limits: the wrapper's file-size limit equals the policy's, in bytes" {
  # The specific disagreement that started this, asserted in the units that
  # matter rather than in the units each file happens to use.
  run python3 - "$WRAPPER" "$POLICY" <<'PY'
import json, re, sys
wrapper, policy = open(sys.argv[1]).read(), json.load(open(sys.argv[2]))
m = re.search(r'^ulimit -f (\d+)', wrapper, re.M)
assert m, "no `ulimit -f` in the wrapper"
blocks = int(m.group(1))
declared = policy["limits"]["rlimit_fsize_bytes"]
print("wrapper: %d blocks x 512 = %d bytes" % (blocks, blocks * 512))
print("policy : %d bytes" % declared)
assert blocks * 512 == declared, (
    "the wrapper enforces %d bytes and the policy declares %d — a factor of %.1f"
    % (blocks * 512, declared, declared / (blocks * 512)))
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
  # 2 MiB / 512 = 4096 blocks
  [[ "$output" == *"ulimit -f 4096"* ]]
}
