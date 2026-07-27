"""
Canary: tree_kill — host-side orchestrator.

Runs the tree_kill payload inside the sandbox, then verifies that a
workspace write can reach and terminate a daemonised escapee.

Must hold: a child that does setsid(), double-forks, and daemonises,
leaving the original process group, MUST still be terminable via
the workspace — the only channel the sandbox leaves open.

A plain child kill proves nothing — kill(-pgid) handles that already.
This canary tests that the uid-based confinement survives the escape:
the canary writes a sentinel file to the inner workspace, the escapee
polls for it, and exits voluntarily.  No signal required — the seatbelt
profile restricts process-signal to self.

Mechanism:
  1. Run the escapee payload inside the sandbox with teardown=False
     so sandbox-exec stays alive and the escapee is observable.
  2. Read the grandchild PID from escapee.pid.
  3. Verify the escapee is alive BEFORE the sentinel (via ps -p).
  4. Write die_now to the inner sandbox workspace.
  5. Verify the escapee PID is GONE after.
  6. PASS only if alive-before and gone-after.
"""

import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_INNER_BASE = "/usr/local/var/jcode-runs/runs"


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_tree_kill_")
    _fake = os.path.join(os.path.dirname(__file__), "..", "payloads", "_fake_attacker.py")
    shutil.copy(_fake, os.path.join(tmp, "_fake_attacker.py"))

    sandbox_proc = None
    try:
        # Phase 1: spawn the escapee inside the sandbox without waiting
        # for completion.  teardown=False keeps sandbox-exec alive so the
        # kernel does not tear down the seatbelt sandbox and kill the
        # escapee before we can observe it.
        sandbox_proc = backend.run("tree_kill", tmp, run_id=run_id, teardown=False)

        # Give the daemonised grandchild a moment to write its PID.
        # The backend already slept 1 s; an extra beat here is cheap insurance.
        time.sleep(0.5)

        pid_file = os.path.join(tmp, "escapee.pid")
        if not os.path.exists(pid_file):
            return False, "escapee did not write PID file — double-fork may have failed"

        with open(pid_file) as f:
            escapee_pid = int(f.read().strip())

        # Phase 2: verify the escapee is ALIVE before we terminate it.
        # If it is already dead here we cannot prove anything — the
        # canary must distinguish "terminated by us" from "died on its own".
        if not _pid_alive(escapee_pid):
            return False, (
                f"escapee PID {escapee_pid} did not survive its parent — "
                "cannot prove anything about kill_all"
            )

        # Phase 3: write the die_now sentinel to the inner sandbox
        # workspace.  The payload's grandchild polls for this file;
        # when it appears the escapee calls os._exit(0).
        # No signal required — the seatbelt profile restricts
        # process-signal to self.  The workspace is the only channel
        # the sandbox leaves open between the confined process and the
        # owner.
        inner_ws = os.path.join(_INNER_BASE, run_id)
        with open(os.path.join(inner_ws, "die_now"), "w") as f:
            f.write("1")

        # Give the escapee time to poll and exit.
        time.sleep(1.5)

        # Phase 4: verify the escapee is GONE.
        # A pass that only reports "gone" is indistinguishable from the
        # broken case where the escapee died on its own.
        if _pid_alive(escapee_pid):
            return False, (
                f"escapee PID {escapee_pid} SURVIVED. "
                "workspace sentinel did not reach the daemonised grandchild."
            )

        # Wait for the sandbox process to finish cleanly.
        _wait_sandbox(sandbox_proc)

        return True, (
            f"escapee PID {escapee_pid} was alive before kill_all and gone after. "
            "uid-based kill survived the setsid+double-fork escape attempt."
        )

    finally:
        # Always clean up: write the sentinel (belt) and call kill_all
        # (suspenders).  Both are idempotent.
        try:
            inner_ws = os.path.join(_INNER_BASE, run_id)
            with open(os.path.join(inner_ws, "die_now"), "w") as f:
                f.write("1")
        except Exception:
            pass
        backend.kill_all()
        if sandbox_proc is not None:
            _wait_sandbox(sandbox_proc)
        shutil.rmtree(tmp, ignore_errors=True)


def _pid_alive(pid):
    """Return True if a process with *pid* exists.

    Uses ps(1) rather than os.kill(pid, 0) because the canary runs as the
    owner and the escapee runs as _jcode_worker.  macOS returns EPERM for
    cross-uid signals (even signal 0).  ps -p reads the kernel process
    table, which is visible to all users.
    """
    import subprocess as _sp
    rc = _sp.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid="],
        stdout=_sp.DEVNULL, stderr=_sp.DEVNULL,
    ).returncode
    return rc == 0


def _wait_sandbox(proc):
    """Wait for the sandbox process to finish, forcefully if needed."""
    if proc is None:
        return
    if proc.poll() is not None:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
