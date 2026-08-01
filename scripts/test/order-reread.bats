#!/usr/bin/env bats
# order-reread.bats — the launcher must act on the bytes that were validated.
#
# It used to learn only the exit status and then re-open the file with a plain
# json.load: no size check, no canonicity, no schema, no provenance. Everything
# the validator established about the bytes it read was assumed to hold for
# whatever bytes were at that path a moment later.
#
# ADR §5 says "Bytegrößen-Prüfung vor jedem Lesen" — before EVERY read, not
# before the first one. The second read had none. Found by a red-team on
# PR #127 and filed as #128.
#
# Exploiting it needed a concurrent writer between two operations microseconds
# apart, and the only field the launcher took from the second read was
# re-checked against the policy anyway. What made it worth closing is not the
# exploit: it is that the code contained a read the contract's guarantees did
# not cover, and the next person to use a field from that dict would inherit
# the gap without knowing it existed. The reason it was safe was a property of
# which fields were used, not of the mechanism.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  VEC="$REPO_ROOT/core/orders/vectors"
}

@test "order-reread: the launcher acts on the validated bytes, not the file" {
  # The window, demonstrated. The file is REPLACED between the validator's
  # verdict and the launcher's use of the order. Under the old code the
  # launcher would report the swapped order's issue number; it must report the
  # validated one.
  run python3 - "$REPO_ROOT" <<'PY'
import io, contextlib, json, os, shutil, sys, tempfile, types
root = sys.argv[1]
sys.path.insert(0, root + "/core"); sys.path.insert(0, root)

tmp = tempfile.mkdtemp()
path = os.path.join(tmp, "order.json")
good = json.load(open(root + "/core/orders/vectors/accept/01-minimal.json"))
good["issue"] = 4242
json.dump(good, open(path, "w"), indent=2)

swapped = json.loads(json.dumps(good))
swapped["issue"] = 9999

import orders.validate as v
real_validate = v.validate
def validate_then_swap(p):
    try:
        real_validate(p)
    finally:
        # The instant the verdict is reached, the bytes on disk change.
        json.dump(swapped, open(p, "w"), indent=2)
v.validate = validate_then_swap

stub = types.ModuleType("backends.macos_seatbelt")
stub.pool_status = lambda: {}
stub.reconcile = lambda **k: {"removed_runs": 0, "released_slots": 0, "errors": 0,
                              "stray_processes": [], "stray_status": "ok"}
pkg = types.ModuleType("backends"); pkg.macos_seatbelt = stub
sys.modules["backends"] = pkg; sys.modules["backends.macos_seatbelt"] = stub

import launcher
launcher.order_validate = None  # ensure a fresh import path inside validate_order
out = io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
    try:
        launcher.main([path])
    except BaseException:
        pass
text = out.getvalue()
print(text[:300])
assert "issue #4242" in text, "acted on the swapped file, not the validated bytes:\n" + text[:400]
assert "issue #9999" not in text, "the swapped order reached the run:\n" + text[:400]
shutil.rmtree(tmp, ignore_errors=True)
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-reread: run_checks() returns the order it inspected" {
  run python3 - "$REPO_ROOT" <<'EOPY'
import sys
root = sys.argv[1]; sys.path.insert(0, root + "/core")
import orders.validate as v
o = v.run_checks(root + "/core/orders/vectors/accept/01-minimal.json")
assert o is not None and o["schema"] == "execution-core/order/v1", o
print("run_checks() returned the order, issue", o["issue"])
EOPY
  echo "$output"; [ "$status" -eq 0 ]
}

@test "order-reread: a refusal binds nothing, and no module state survives" {
  # The first version of this fix deposited the order in a module global and
  # cleared it at the top of every call. A reviewer refused that shape, and was
  # right: it makes the validator stateful for one caller's benefit, so two
  # callers in one process read each other's results, and the only guard is a
  # .clear() somebody has to remember to keep first.
  #
  # With a return value there is nothing to leave behind. This asserts the
  # property rather than trusting the argument — including that the global and
  # its accessor are gone, so the old shape cannot quietly come back.
  run python3 - "$REPO_ROOT" <<'EOPY'
import sys
root = sys.argv[1]; sys.path.insert(0, root + "/core")
import orders.validate as v
vec = root + "/core/orders/vectors"
good = v.run_checks(vec + "/accept/01-minimal.json")
assert good is not None
leaked = "sentinel"
try:
    leaked = v.run_checks(vec + "/reject/25-unproven-mem-limit.json")
except SystemExit as e:
    assert e.code == 1, e.code
else:
    raise AssertionError("a refused order returned instead of exiting")
assert leaked == "sentinel", "the refusal bound a value"
assert not hasattr(v, "_validated_order"), "the module global is back"
assert not hasattr(v, "validated_order"), "the accessor is back"
print("a refusal exits and binds nothing; no module state remains")
EOPY
  echo "$output"; [ "$status" -eq 0 ]
}

@test "order-reread: two callers in one process do not see each other's order" {
  # The concrete failure the module global permitted, as a test. Under the old
  # shape this was only safe because every call began with .clear(); under a
  # return value it cannot be expressed.
  run python3 - "$REPO_ROOT" <<'EOPY'
import sys
root = sys.argv[1]; sys.path.insert(0, root + "/core")
import orders.validate as v
vec = root + "/core/orders/vectors"
a = v.run_checks(vec + "/accept/01-minimal.json")
b = v.run_checks(vec + "/accept/02-with-reductions.json")
assert a is not b, "the two calls returned the same object"
assert a["run_id"] != b["run_id"] or a != b, "the second call overwrote the first"
# a must still be the order the FIRST call inspected, after the second ran
again = v.run_checks(vec + "/accept/01-minimal.json")
assert a == again, "the first result changed when another order was validated"
print("each caller holds its own order")
EOPY
  echo "$output"; [ "$status" -eq 0 ]
}

@test "order-reread: the launcher no longer opens the order a second time" {
  # The property rather than the symptom. Comments stripped first — the source
  # explains the defect by naming json.load right above the code that no longer
  # does it.
  run bash -c "sed 's/#.*//' '$REPO_ROOT/core/launcher.py' | grep -nE 'json.load\(.*order|open\(order_path'"
  echo "$output"
  [ -z "$output" ]
}

@test "order-reread: an admissible verdict with no order is refused, not re-read" {
  # The defensive branch, which mutation testing found untested: if the
  # validator ever reports admissible without handing back what it inspected,
  # the launcher must refuse. The tempting alternative — fall back to reading
  # the file — is the defect this change removes, and a fallback would restore
  # it silently the first time the contract drifted.
  run python3 - "$REPO_ROOT" <<'PY'
import io, contextlib, sys, types
root = sys.argv[1]
sys.path.insert(0, root + "/core"); sys.path.insert(0, root)

stub = types.ModuleType("backends.macos_seatbelt")
stub.pool_status = lambda: {}
stub.reconcile = lambda **k: {"removed_runs": 0, "released_slots": 0, "errors": 0,
                              "stray_processes": [], "stray_status": "ok"}
pkg = types.ModuleType("backends"); pkg.macos_seatbelt = stub
sys.modules["backends"] = pkg; sys.modules["backends.macos_seatbelt"] = stub

import launcher
launcher.validate_order = lambda p: (0, "", None)   # admissible, nothing returned

err = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    rc = launcher.main([root + "/core/orders/vectors/accept/01-minimal.json"])
text = err.getvalue()
print("rc=%s" % rc); print(text[:250])
assert rc == 1, rc
assert "REFUSED" in text, text[:250]
assert "without returning the order" in text, text[:250]
PY
  echo "$output"; [ "$status" -eq 0 ]
}
