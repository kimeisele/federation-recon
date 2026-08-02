#!/usr/bin/env bats
# order-validator.bats — runs the S2 oracle against the validator.
#
# Written before the validator existed, by the author of core/orders/CONTRACT.md
# and the vectors, and committed to the implementation branch *before* the
# builder was dispatched. #103 is the reason: a builder that writes the tests
# its own work is judged by has written a description, not an acceptance.
#
# The builder must not modify this file, the vectors, or CONTRACT.md. A change
# to any of them inside an implementation pull request is the failure this
# arrangement exists to make visible, not a detail to be waved through.
#
# What is under test is exit status and the reason code on the first line of
# stderr. Wording below the first line is free — a message the operator can act
# on is worth more than a message a test can match.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  VEC="$REPO_ROOT/core/orders/vectors"

  # Vectors 38 and 46 depend on CPython's integer-string conversion limit, and
  # that limit is settable from the environment. `PYTHONINTMAXSTRDIGITS=0` is
  # legal and means *no limit*: the validator then computes a threshold of 10^9,
  # the pre-filter can never match inside a 64 KiB document, the parser raises
  # nothing, and both vectors are admitted — correct behaviour for the code,
  # and a red suite for a reason that has nothing to do with a regression.
  #
  # Unset rather than pinned to 4300: the default is what production runs with,
  # and hardcoding the number here would make the suite carry its own copy of
  # the constant it is meant to be checking. See #144 for what that costs.
  unset PYTHONINTMAXSTRDIGITS
}

# Run the validator on one vector. Prints "<exit>|<first stderr line>".
_validate() {
  local f="$1" out rc
  out="$(cd "$REPO_ROOT" && python3 -m core.orders.validate "$f" 2>&1 >/dev/null)"
  rc=$?
  printf '%s|%s\n' "$rc" "$(printf '%s' "$out" | head -n1)"
}

@test "order-validator: the module exists and is runnable" {
  # Ordered first so that "not built yet" reads as one clear failure rather
  # than 38 confusing ones.
  run bash -c "cd '$REPO_ROOT' && python3 -c 'import core.orders.validate'"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-validator: every reject vector is refused with its recorded code" {
  run python3 - "$REPO_ROOT" <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
vec = os.path.join(root, "core/orders/vectors")
man = json.load(open(os.path.join(vec, "manifest.json")))
bad = []
for fn, spec in sorted(man["reject"].items()):
    p = os.path.join(vec, "reject", fn)
    r = subprocess.run([sys.executable, "-m", "core.orders.validate", p],
                       cwd=root, capture_output=True, text=True)
    first = (r.stderr.strip().splitlines() or [""])[0].strip()
    if r.returncode != 1:
        bad.append(f"{fn}: exit {r.returncode}, expected 1 ({spec['code']})")
    elif first != spec["code"]:
        bad.append(f"{fn}: got {first!r}, expected {spec['code']!r}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{len(man['reject'])} vectors refused with the expected code")
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-validator: every accept vector is admitted, silently" {
  # Without this test, `sys.exit(1)` on line one passes the whole suite above.
  run python3 - "$REPO_ROOT" <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
vec = os.path.join(root, "core/orders/vectors")
man = json.load(open(os.path.join(vec, "manifest.json")))
bad = []
for fn in sorted(man["accept"]):
    p = os.path.join(vec, "accept", fn)
    r = subprocess.run([sys.executable, "-m", "core.orders.validate", p],
                       cwd=root, capture_output=True, text=True)
    if r.returncode != 0:
        bad.append(f"{fn}: exit {r.returncode}, stderr: {r.stderr.strip()[:200]}")
    elif r.stderr.strip():
        bad.append(f"{fn}: exit 0 but stderr not empty: {r.stderr.strip()[:200]}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"{len(man['accept'])} vectors admitted")
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-validator: the size check fires before the parser" {
  # CONTRACT.md §2 orders the codes: size before parse. A file that is both
  # oversize and unparseable must report E_SIZE. If it reports E_JSON, the
  # bytes reached the parser — which is the thing the byte limit exists to
  # prevent (ADR §5).
  tmp="$BATS_TEST_TMPDIR/huge-and-broken.json"
  python3 -c "
open('$tmp','w').write('{\"schema\": ' + 'x'*70000)
"
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$tmp' 2>&1 >/dev/null | head -n1"
  echo "$output"
  [ "$output" = "E_SIZE" ]
}

@test "order-validator: it does not execute the order" {
  # An order is data. This one names a file in intent; if the validator
  # interpolates any field into a shell, the file appears.
  canary="$BATS_TEST_TMPDIR/canary"
  tmp="$BATS_TEST_TMPDIR/inject.json"
  python3 - "$tmp" "$canary" <<'PY'
import json, sys
o = json.load(open("core/orders/vectors/accept/01-minimal.json"))
o["intent"] = "touch %s; echo done" % sys.argv[2]
json.dump(o, open(sys.argv[1], "w"), indent=2)
PY
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$tmp'"
  echo "status=$status output=$output"
  [ ! -e "$canary" ]
}

@test "order-validator: it is deterministic" {
  # Same bytes in, same verdict out, twice. A validator that consults the
  # clock, the environment, or a random source produces an order that is
  # admissible on one run and not the next, and the run record cannot say why.
  f="$VEC/reject/25-unproven-mem-limit.json"
  a="$(_validate "$f")"
  b="$(_validate "$f")"
  echo "a=$a b=$b"
  [ "$a" = "$b" ]
}

@test "order-validator: it reads no state outside the order and the policy" {
  # Run it from an empty directory with a cleared environment. Anything it
  # needed from HOME, the cwd, or an inherited variable fails here — and a
  # validator whose verdict depends on where it was invoked from cannot be
  # part of a trusted computing base (ADR §3.1).
  f="$VEC/accept/01-minimal.json"
  run env -i PATH="/usr/bin:/bin" HOME="$BATS_TEST_TMPDIR" \
      bash -c "cd '$BATS_TEST_TMPDIR' && PYTHONPATH='$REPO_ROOT' python3 -m core.orders.validate '$f'"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-validator: a refusal names the missing capability and the backend" {
  # Not a wording test — a content test. ADR §7.2 requires the refusal to name
  # the missing capability, the backend, and the policy rule, so that the
  # legitimate way to change the answer is a visible policy change rather than
  # switching a canary off.
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$VEC/reject/25-unproven-mem-limit.json' 2>&1 >/dev/null"
  echo "$output"
  [[ "$output" == *"mem_limit"* ]]
  [[ "$output" == *"macos-seatbelt"* ]]
}

# ---------------------------------------------------------------------------
# UNREADABLE INPUT (#126) — exit 2, and not a verdict.
#
# Written and committed BEFORE the implementation order exists, by the author
# of the contract decision and not by the party that will be judged against it.
# That ordering is #103's remedy: an acceptance the builder writes confirms
# only that the builder agrees with itself.
#
# CONTRACT.md §1 now says exit 2 means the order could not be READ, and that
# the first stderr line is deliberately not a reason code. These cases hold
# both halves — a caller that folded exit 2 into exit 1 would still see a
# refusal it could route on, which is the thing being prevented.
# ---------------------------------------------------------------------------

@test "order-validator: a missing file exits 2" {
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$BATS_TEST_TMPDIR/nope.json'"
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
}

@test "order-validator: a missing file does not report a reason code" {
  # The half that matters for a consumer: E_* on line 1 means a verdict was
  # reached, and none was.
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$BATS_TEST_TMPDIR/nope.json' 2>&1 >/dev/null | head -n1"
  echo "$output"
  [[ "$output" != E_* ]]
}

@test "order-validator: a directory exits 2" {
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$BATS_TEST_TMPDIR'"
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
}

@test "order-validator: an unreadable file exits 2" {
  f="$BATS_TEST_TMPDIR/locked.json"
  cp "$VEC/accept/01-minimal.json" "$f"
  chmod 000 "$f"
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$f'"
  chmod 644 "$f"
  echo "status=$status output=$output"
  # Running as root defeats the permission bit; skip rather than pass, so a
  # green result never means "the check could not run".
  if [ "$(id -u)" = "0" ]; then
    skip "running as root: chmod 000 does not deny read"
  fi
  [ "$status" -eq 2 ]
}

@test "order-validator: an unreadable POLICY also exits 2" {
  # The other caller of the same funnel. A policy that cannot be read is the
  # supervisor failing to find its own configuration — the same class, and it
  # used to report E_SIZE too.
  run bash -c "
    set -e
    tmp=\"\$(mktemp -d)\"
    cp -R '$REPO_ROOT/core' \"\$tmp/core\"
    rm -f \"\$tmp/core/policy.json\"
    cd \"\$tmp\"
    PYTHONPATH=\"\$tmp\" python3 -m core.orders.validate '$VEC/accept/01-minimal.json'
  "
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
}

@test "order-validator: a real refusal still exits 1 with its code" {
  # The regression that matters: exit 2 must not swallow verdicts. An
  # implementation that returned 2 for everything would pass every case above.
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$VEC/reject/25-unproven-mem-limit.json'"
  [ "$status" -eq 1 ]
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$VEC/reject/25-unproven-mem-limit.json' 2>&1 >/dev/null | head -n1"
  [ "$output" = "E_CAPABILITY_UNPROVEN" ]
}

@test "order-validator: an admissible order still exits 0" {
  run bash -c "cd '$REPO_ROOT' && python3 -m core.orders.validate '$VEC/accept/01-minimal.json'"
  [ "$status" -eq 0 ]
}
