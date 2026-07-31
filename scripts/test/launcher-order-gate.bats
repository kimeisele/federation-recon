#!/usr/bin/env bats
# launcher-order-gate.bats — the validator is on the execution path, not beside it.
#
# S2 shipped a correct order validator that nothing called. An independent
# red-team rejected it on exactly that ground — "a correct mechanism that
# nothing invokes is a prop" — and a second reviewer, from a third provider,
# ruled that deferring the caller to S3 was the defect rather than the
# schedule, because a gate first exercised at a real boundary in S4/S5 meets
# that boundary at the moment failure is expensive and the pressure to waive it
# is highest.
#
# These tests cover the REFUSAL half of the gate, which needs no sandbox host:
# a refused order exits before the backend is imported, so everything up to and
# including the refusal runs anywhere. The admission half stops at "the order
# got past the gate", because what follows needs the root-owned pool from
# docs/s1-setup.md and cannot run in CI. That asymmetry is stated rather than
# papered over — and it happens to favour the tests, since the enforcing half
# is the one that runs everywhere.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  VEC="$REPO_ROOT/core/orders/vectors"
}

@test "launcher-order-gate: an order file is required, not optional" {
  # An optional gate is bypassed by omitting it. Then the thing that can be
  # left out is the gate rather than the order.
  run python3 "$REPO_ROOT/core/launcher.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]

  run python3 "$REPO_ROOT/core/launcher.py" "$VEC/accept/01-minimal.json" extra
  [ "$status" -eq 2 ]
}

@test "launcher-order-gate: a refused order never loads the backend" {
  # The property, asserted directly rather than by proxy: after main() returns
  # its refusal, the backend module is absent from sys.modules. Not "no output
  # mentioning the backend" — actually not imported, so there is nothing
  # loaded for a later line to reach even by mistake.
  run python3 - "$REPO_ROOT" <<'PY'
import sys
root = sys.argv[1]
sys.path.insert(0, root + "/core")
sys.path.insert(0, root)
import launcher
rc = launcher.main([root + "/core/orders/vectors/reject/25-unproven-mem-limit.json"])
loaded = [m for m in sys.modules if "macos_seatbelt" in m or m.startswith("backends")]
print("rc=%s backend_modules=%s" % (rc, loaded))
assert rc == 1, rc
assert not loaded, loaded
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "launcher-order-gate: the launcher does not soften the validator's verdict" {
  # Every vector the validator refuses, the launcher refuses too, with the
  # same code. A caller that downgraded any refusal to a warning would be the
  # cheapest possible way to keep a green gate and an ungated path.
  run python3 - "$REPO_ROOT" <<'PY'
import json, os, subprocess, sys
root = sys.argv[1]
vec = os.path.join(root, "core/orders/vectors")
man = json.load(open(os.path.join(vec, "manifest.json")))
bad = []
for fn, spec in sorted(man["reject"].items()):
    p = os.path.join(vec, "reject", fn)
    r = subprocess.run([sys.executable, os.path.join(root, "core/launcher.py"), p],
                       capture_output=True, text=True)
    first = (r.stderr.strip().splitlines() or [""])[0].strip()
    if r.returncode != 1:
        bad.append(f"{fn}: launcher exit {r.returncode}, expected 1")
    elif first != f"ORDER REFUSED: {spec['code']}":
        bad.append(f"{fn}: launcher said {first!r}, expected the {spec['code']} refusal")
if bad:
    print("\n".join(bad)); sys.exit(1)
print(f"{len(man['reject'])} refusals passed through the launcher unchanged")
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "launcher-order-gate: an admissible order gets past the gate" {
  # Without this the gate could refuse everything and every test above would
  # still pass.
  #
  # The backend is replaced by a stub in sys.modules BEFORE main() runs, so the
  # real one is never imported. That is not tidiness. The first version of this
  # test invoked the launcher as a subprocess and let it continue past the
  # gate, and on a host where S1 is installed that runs the entire canary suite
  # — eight sandboxed workers under sudo, minutes per invocation. One of those
  # sudo calls was left stopped and orphaned for seven hours (#129). A test
  # asserting one line of stdout must not launch root-owned processes to do it.
  #
  # Stubbing also makes the assertion sharper: what is under test is that the
  # gate admits the order and hands control onward, not what the backend then
  # does with it.
  run python3 - "$REPO_ROOT" <<'PY'
import sys, types
root = sys.argv[1]
sys.path.insert(0, root + "/core")
sys.path.insert(0, root)

stub = types.ModuleType("backends.macos_seatbelt")
stub.reached = False
def _unreachable(*a, **k):
    stub.reached = True
    raise AssertionError("the stub was called — see the assertions below")
stub.pool_status = lambda: {}
stub.reconcile = lambda: {"removed_runs": 0, "released_slots": 0, "errors": 0}
pkg = types.ModuleType("backends")
pkg.macos_seatbelt = stub
sys.modules["backends"] = pkg
sys.modules["backends.macos_seatbelt"] = stub

import io, contextlib
import launcher
out = io.StringIO()
with contextlib.redirect_stdout(out):
    try:
        launcher.main([root + "/core/orders/vectors/accept/01-minimal.json"])
    except BaseException as exc:      # anything past the gate is out of scope
        # BaseException, not Exception: the launcher signals a failed canary
        # suite with sys.exit, and SystemExit does not inherit from Exception.
        # Catching the narrower class made this test fail for a reason that has
        # nothing to do with the gate it is testing.
        print("(stopped after the gate: %s)" % type(exc).__name__)
text = out.getvalue()
print(text)
assert "admitted for issue" in text, text[:400]
assert "ORDER REFUSED" not in text, text[:400]
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "launcher-order-gate: admitting an order does not need the real backend" {
  # The property the stub above relies on, asserted rather than assumed: the
  # admission decision is complete before the backend is consulted. If this
  # ever stops holding, the test above starts passing for the wrong reason.
  run python3 - "$REPO_ROOT" <<'PY'
import sys
root = sys.argv[1]
sys.path.insert(0, root + "/core")
sys.path.insert(0, root)
import launcher
rc, err = launcher.validate_order(root + "/core/orders/vectors/accept/01-minimal.json")
loaded = [m for m in sys.modules if m.startswith("backends")]
print("rc=%s stderr=%r backend_modules=%s" % (rc, err, loaded))
assert rc == 0, (rc, err)
assert err == "", err
assert not loaded, loaded
PY
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "launcher-order-gate: the refusal says the backend was not consulted" {
  # The operator reading a refused run must be able to tell it stopped before
  # the boundary, not after it. An ambiguous refusal invites a re-run to find
  # out, and a re-run is the thing that must not be needed.
  run python3 "$REPO_ROOT/core/launcher.py" "$VEC/reject/09-absolute-limits.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"The backend was not consulted and no workspace was created."* ]]
}
