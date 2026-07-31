#!/usr/bin/env bats
# stray-processes.bats — identify on what a process cannot choose.
#
# On 2026-07-31 a root-owned worker from a killed run survived seven hours
# while the launcher printed "reconcile(): zero orphans". The line was true
# about directories, which is all reconcile() ever inspected (#129).
#
# The FIRST attempt to fix that matched `_SANDBOX_BASE in command` and excluded
# live runs by looking for a claimed run id anywhere in the command line. An
# independent red-team rejected it, and the objection was structural:
#
#   "Substring matching against attacker-influenceable data. […] the builder
#    can read runs/, learn live ids, and mint them into its daemon's argv."
#
# Measured, all three returning zero strays: a survivor that execs by relative
# path carries no base path and vanished; a survivor carrying a claimed run id
# excluded itself; and a single EMPTY run id in the claimed set voided the
# entire check while still reporting status "ok".
#
# Identification now rests on the uid the kernel assigned — the property the
# whole sandbox is built on and every capability canary already depends on.
# argv is consulted for exactly one case, the root-owned sudo parent, whose
# command line run() constructs and the worker never touches.
#
# Every test drives fixtures. That is not a shortcut: creating a long-lived
# root-owned process requires a sudoers rule, and permission changes are
# OWNER-ONLY, so fixtures are the only way to exercise the root case at all.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
}

_py() {
  python3 - "$REPO_ROOT" "$1" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/core")
import backends.macos_seatbelt as b
BASE = b._SANDBOX_BASE
WRAPPER = b._WRAPPER_PATH
exec(open(sys.argv[2]).read())
PY
}

@test "stray-processes: a root-owned sudo survivor is found and attributed" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = (" 35701 root     T        sudo -u _jcode_w01 %s W-AbGC tree_kill\n"
      "   501 ss       S        /usr/bin/python3 unrelated\n") % WRAPPER
strays, status = b.find_stray_processes((), ps)
assert status == "ok", status
assert len(strays) == 1, strays
assert strays[0]["pid"] == "35701" and strays[0]["slot"] == "_jcode_w01", strays
print("found:", strays[0]["pid"], strays[0]["slot"], strays[0]["state"])
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: a survivor cannot hide by rewriting its own argv" {
  # The red-team's first evasion, executed. A double-fork descendant that execs
  # by relative path carries no sandbox path at all — and is still owned by the
  # slot uid, which it cannot change.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 40002 _jcode_w03 S      ./payload\n"
strays, status = b.find_stray_processes((), ps)
assert status == "ok", status
assert len(strays) == 1 and strays[0]["slot"] == "_jcode_w03", strays
print("argv mentions nothing; uid still gives it away:", strays[0]["slot"])
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: a survivor cannot exclude itself by naming a live run" {
  # The red-team's second evasion. The builder can read runs/ and learn a live
  # run id. Under the old rule, putting one in its argv excluded it. Exclusion
  # is now by slot ownership, which argv cannot assert.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 40003 _jcode_w05 S      ./daemon --tag qzA5VJYFsvwF0ANX\n"
strays, _ = b.find_stray_processes(("_jcode_w02",), ps)   # w05 is NOT claimed
assert len(strays) == 1 and strays[0]["slot"] == "_jcode_w05", strays
print("run id in argv no longer buys an exclusion")
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: an empty or odd claim entry cannot void the check" {
  # The red-team's third and sharpest finding, executed against the old code:
  # `any(rid in command for rid in claimed_run_ids)` with rid == "" is true for
  # every line, so a single corrupt claim silently excluded everything while
  # reporting status "ok". Tolerating corrupt claim state is what reconcile()
  # is FOR.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 40004 _jcode_w07 S      ./payload\n"
for claimed in [("",), ("", "_jcode_w01"), ("w07",), ("_jcode_w0",), ()]:
    strays, status = b.find_stray_processes(claimed, ps)
    assert status == "ok", (claimed, status)
    assert len(strays) == 1, (claimed, strays)
print("empty, partial and near-miss claim entries all fail to exclude")
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: a claimed slot's own processes are not strays" {
  # Without this the check reports every live worker, the output becomes noise,
  # and the real line is lost in it — which the red-team named as the way false
  # positives train dismissal.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = (" 41000 _jcode_w03 S      ./worker\n"
      " 41001 root     S        sudo -u _jcode_w03 %s RUNID x\n") % WRAPPER
strays, status = b.find_stray_processes(("_jcode_w03",), ps)
assert status == "ok" and strays == [], strays
strays2, _ = b.find_stray_processes(("_jcode_w04",), ps)
assert len(strays2) == 2, strays2
print("claimed slot silent; the same two lines report when it is not claimed")
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: root naming the wrapper in an unexpected shape is reported, not ignored" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 42000 root     S        /bin/sh -c %s something\n" % WRAPPER
strays, status = b.find_stray_processes(("_jcode_w01",), ps)
assert len(strays) == 1 and strays[0]["slot"] == "unattributed", strays
print("unexplained rather than benign:", strays[0]["slot"])
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: unrelated processes are ignored" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = ("   1 root     S        /sbin/launchd\n"
      " 900 ss       S        /usr/bin/python3 -m http.server\n"
      " 901 root     S        sudo -u nobody /bin/sleep 30\n"
      " 902 ss       S        tail -f %s/log\n") % BASE
strays, status = b.find_stray_processes((), ps)
assert status == "ok" and strays == [], strays
print("four unrelated processes, including one that merely names the base path")
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: an unreadable process table is UNKNOWN, never zero" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
import subprocess
orig = subprocess.run
subprocess.run = lambda *a, **k: (_ for _ in ()).throw(OSError("ps unavailable"))
try:
    strays, status = b.find_stray_processes(())
finally:
    subprocess.run = orig
assert strays == [] and status.startswith("unknown"), (strays, status)
print("status:", status)
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: a non-zero ps exit is UNKNOWN, not zero" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
import subprocess
class R:
    returncode = 1; stdout = ""; stderr = "ps: permission denied"
orig = subprocess.run
subprocess.run = lambda *a, **k: R()
try:
    strays, status = b.find_stray_processes(())
finally:
    subprocess.run = orig
assert strays == [] and status.startswith("unknown"), (strays, status)
print("status:", status)
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: malformed ps lines are skipped, not crashed on" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = "\ngarbage\n 123 root\n 456 _jcode_w08 T   ./x\n"
strays, status = b.find_stray_processes((), ps)
assert status == "ok" and len(strays) == 1 and strays[0]["pid"] == "456", strays
print("three malformed lines skipped, the real one still found")
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: reconcile actually runs the check, proven by executing it" {
  # The previous version of this test called inspect.getsource(reconcile) and
  # asserted that strings appeared in it. The red-team named that: the
  # integration path was untested and the test was a source grep — the same
  # defect found in a different test the same afternoon. reconcile() now takes
  # an injectable process table, so this executes the wiring instead of reading
  # about it.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 43000 _jcode_w06 T      ./leftover\n"
r = b.reconcile(ps_output=ps)
assert r["stray_status"] == "ok", r
assert len(r["stray_processes"]) == 1, r
assert r["stray_processes"][0]["slot"] == "_jcode_w06", r
assert "removed_runs" in r and "released_slots" in r, sorted(r)
print("reconcile carried the process finding out:", r["stray_processes"][0]["pid"])
PY
  run _py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"; [ "$status" -eq 0 ]
}

# ── The consumer ───────────────────────────────────────────────────────────
#
# "A report with no consumer, no exit code, no scheduler, whose false positives
# train dismissal" was the red-team's verdict on the first version. These two
# assert that the finding now stops a run rather than decorating one.

@test "stray-processes: the launcher refuses to start when a stray survives" {
  run python3 - "$REPO_ROOT" <<'PY'
import sys, types, io, contextlib
root = sys.argv[1]
sys.path.insert(0, root + "/core"); sys.path.insert(0, root)

stub = types.ModuleType("backends.macos_seatbelt")
stub.pool_status = lambda: {}
stub.reconcile = lambda **k: {"removed_runs": 0, "released_slots": 0, "errors": 0,
    "stray_processes": [{"pid": "1", "user": "_jcode_w01", "state": "T",
                         "command": "./leftover", "slot": "_jcode_w01"}],
    "stray_status": "ok"}
pkg = types.ModuleType("backends"); pkg.macos_seatbelt = stub
sys.modules["backends"] = pkg; sys.modules["backends.macos_seatbelt"] = stub

import launcher
err = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    rc = launcher.main([root + "/core/orders/vectors/accept/01-minimal.json"])
text = err.getvalue()
print("rc=%s" % rc)
print(text[-400:])
assert rc == 1, rc
assert "REFUSED" in text, text[:300]
assert "survive from a previous run" in text, text[:300]
assert "canary" not in text.lower(), "refused AFTER running the suite: " + text[:300]
PY
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: the launcher refuses when the check could not run" {
  # ADR §6: "fehlende Evidenz ist Ablehnung". Not measured and within limits
  # must never produce the same outcome — including here, where the easy
  # alternative is to shrug and continue.
  run python3 - "$REPO_ROOT" <<'PY'
import sys, types, io, contextlib
root = sys.argv[1]
sys.path.insert(0, root + "/core"); sys.path.insert(0, root)

stub = types.ModuleType("backends.macos_seatbelt")
stub.pool_status = lambda: {}
stub.reconcile = lambda **k: {"removed_runs": 0, "released_slots": 0, "errors": 0,
    "stray_processes": [], "stray_status": "unknown: cannot run ps: boom"}
pkg = types.ModuleType("backends"); pkg.macos_seatbelt = stub
sys.modules["backends"] = pkg; sys.modules["backends.macos_seatbelt"] = stub

import launcher
err = io.StringIO()
with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
    rc = launcher.main([root + "/core/orders/vectors/accept/01-minimal.json"])
text = err.getvalue()
print("rc=%s" % rc); print(text[-400:])
assert rc == 1, rc
assert "REFUSED" in text and "Not measured" in text, text[:300]
assert "canary" not in text.lower(), "refused AFTER running the suite: " + text[:300]
PY
  echo "$output"; [ "$status" -eq 0 ]
}

@test "stray-processes: the slot list is re-read at check time, not reused from the snapshot" {
  # The red-team's third finding: claimed_slots is collected at the top of
  # reconcile(), BEFORE the releases that pass performs. Reusing it would let a
  # slot released in this very pass keep masking its own survivor for a whole
  # cycle — one turn of blindness, on exactly the shape of #129.
  #
  # Mutation testing found this untested: reverting the re-list left all other
  # tests green. os.listdir is instrumented so the first read of the slots
  # directory sees the claim and the second does not, which is precisely the
  # difference between a snapshot and a fresh read.
  run python3 - "$REPO_ROOT" <<'PY'
import sys, os, tempfile
root = sys.argv[1]
sys.path.insert(0, root + "/core")
import backends.macos_seatbelt as b

tmp = tempfile.mkdtemp()
slots = os.path.join(tmp, "slots"); runs = os.path.join(tmp, "runs")
os.makedirs(slots); os.makedirs(runs)
b._SLOTS_DIR = slots
b._RUNS_DIR = runs

real_listdir = os.listdir
calls = {"n": 0}
def fake_listdir(path):
    if os.path.abspath(path) == os.path.abspath(slots):
        calls["n"] += 1
        # First read: the slot is claimed. Second read: it has been released
        # during this pass — which is the case the snapshot cannot see.
        return ["_jcode_w06"] if calls["n"] == 1 else []
    return real_listdir(path)
os.listdir = fake_listdir
try:
    ps = " 43000 _jcode_w06 T      ./leftover\n"
    r = b.reconcile(ps_output=ps)
finally:
    os.listdir = real_listdir

print("slots dir read %d time(s)" % calls["n"])
print("strays:", r["stray_processes"])
assert calls["n"] >= 2, "the slots directory was read once — that is the snapshot"
assert len(r["stray_processes"]) == 1, (
    "the survivor of a slot released during this pass was masked: %r" % r["stray_processes"])
assert r["stray_processes"][0]["slot"] == "_jcode_w06", r["stray_processes"]
PY
  echo "$output"; [ "$status" -eq 0 ]
}
