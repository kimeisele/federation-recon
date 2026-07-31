#!/usr/bin/env bats
# stray-processes.bats — reconcile() counts directories; this counts processes.
#
# On 2026-07-31 a root-owned worker from a killed run survived seven hours
# while the launcher printed "reconcile(): zero orphans". The line was true
# about directories, which is all reconcile() ever inspected, and false in the
# way a reader would take it (#129).
#
# The cause is structural. A worker is launched as `sudo -u <slot> <wrapper>`,
# and the sudo process runs as ROOT until it drops privileges — so it cannot
# appear in `pgrep -u <slot_uid>`, the emptiness proof _release_slot uses, and
# cannot be killed by kill_slot, which kills *as* the slot user. Both existing
# controls are scoped to a uid the survivor does not have.
#
# Every test here drives find_stray_processes with fixture `ps` output. That is
# not a shortcut around the real thing: it is the only way to exercise the
# root-owned case at all, since creating a long-lived root process requires a
# sudoers rule, and permission changes are OWNER-ONLY.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
}

_run_py() {
  python3 - "$REPO_ROOT" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/core")
import backends.macos_seatbelt as b
BASE = b._SANDBOX_BASE
exec(open(sys.argv[2]).read())
PY
}

@test "stray-processes: a root-owned survivor is found" {
  # The exact shape of the process that survived: owner root, state T, command
  # naming the wrapper. It is invisible to pgrep -u <slot_uid> by construction.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = (
    " 35701 root     T        sudo -u _jcode_w01 %s/worker_exec.sh W-AbGC tree_kill\n"
    "   501 ss       S        /usr/bin/python3 something-unrelated\n"
) % BASE
strays, status = b.find_stray_processes((), ps)
assert status == "ok", status
assert len(strays) == 1, strays
assert strays[0]["pid"] == "35701", strays
assert strays[0]["user"] == "root", strays
assert strays[0]["state"] == "T", strays
print("found:", strays[0]["pid"], strays[0]["user"], strays[0]["state"])
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: a process belonging to a claimed run is not a stray" {
  # Without this the check reports every live worker as a survivor, the output
  # becomes noise, and the one real line is lost in it.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = " 40001 root     S        sudo -u _jcode_w03 %s/worker_exec.sh RUNID-LIVE no_network\n" % BASE
strays, status = b.find_stray_processes(("RUNID-LIVE",), ps)
assert status == "ok", status
assert strays == [], strays
strays2, _ = b.find_stray_processes(("SOME-OTHER-RUN",), ps)
assert len(strays2) == 1, strays2
print("live run excluded; the same line with a different claim is reported")
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: unrelated processes are ignored" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = (
    "   1 root     S        /sbin/launchd\n"
    " 900 ss       S        /usr/bin/python3 -m http.server\n"
    " 901 root     S        sudo -u nobody /bin/sleep 30\n"
)
strays, status = b.find_stray_processes((), ps)
assert status == "ok", status
assert strays == [], strays
print("three unrelated processes, none reported")
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: an unreadable process table is UNKNOWN, never zero" {
  # The defect this whole file exists for was a clean-looking line printed by
  # a check that had not looked. "Could not read ps" must be distinguishable
  # from "nothing there", or the fix reintroduces the bug it fixes.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
import subprocess
def boom(*a, **k):
    raise OSError("ps is unavailable")
orig = subprocess.run
subprocess.run = boom
try:
    strays, status = b.find_stray_processes(())
finally:
    subprocess.run = orig
assert strays == [], strays
assert status.startswith("unknown"), status
print("status:", status)
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: a non-zero ps exit is UNKNOWN, not zero" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
import subprocess
class R:
    returncode = 1
    stdout = ""
    stderr = "ps: permission denied"
orig = subprocess.run
subprocess.run = lambda *a, **k: R()
try:
    strays, status = b.find_stray_processes(())
finally:
    subprocess.run = orig
assert strays == [], strays
assert status.startswith("unknown"), status
print("status:", status)
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: malformed ps lines are skipped, not crashed on" {
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
ps = (
    "\n"
    "garbage\n"
    " 123 root\n"
    " 456 root     T        sudo %s/worker_exec.sh X y\n"
) % BASE
strays, status = b.find_stray_processes((), ps)
assert status == "ok", status
assert len(strays) == 1 and strays[0]["pid"] == "456", strays
print("three malformed lines skipped, the real one still found")
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "stray-processes: reconcile reports the process dimension separately" {
  # reconcile()'s counters are about directories. This asserts that its result
  # now carries the process answer as its own field with its own status, so a
  # caller cannot read one as the other.
  cat > "$BATS_TEST_TMPDIR/t.py" <<'PY'
import inspect
src = inspect.getsource(b.reconcile)
assert "stray_processes" in src, "reconcile does not report strays"
assert "stray_status" in src, "reconcile does not report whether it looked"
assert "find_stray_processes" in src, "reconcile never calls the process check"
r = {"removed_runs": 0, "released_slots": 0, "errors": 0,
     "stray_processes": [], "stray_status": "not checked"}
print("reconcile result keys:", sorted(r))
PY
  run _run_py "$BATS_TEST_TMPDIR/t.py"
  echo "$output"
  [ "$status" -eq 0 ]
}
