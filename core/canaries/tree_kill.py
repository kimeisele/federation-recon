"""
Canary: tree_kill — host-side orchestrator.

Runs the tree_kill payload inside the sandbox, then verifies that
backend.kill_all() terminates a daemonised escapee.

Must hold: a child that does setsid(), double-forks, and daemonises,
leaving the original process group, MUST still be terminable by
backend.kill_all() — a uid-based pkill.  The canary FAILs if the
escapee disappeared before kill_all() was called, because that
proves nothing about the mechanism.

Mechanism:
  1. Run the escapee payload inside the sandbox with teardown=False
     so sandbox-exec stays alive and the escapee is observable.
  2. Read the grandchild PID from escapee.pid.
  3. Verify the escapee is alive (via /bin/ps -p) — if dead, FAIL.
  4. Verify the pid's owner is the worker uid — a recycled pid owned
     by someone else is not evidence.
  5. Call backend.kill_all().  This IS the test.
  6. Poll up to ~5 s for the pid to disappear.  Still alive → FAIL.
  7. PASS only if alive-before and gone-after, stating what was actually
     observed.
  8. die_now exists ONLY as a cleanup fallback in finally; it must not
     influence the verdict.
"""

import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_INNER_BASE = "/usr/local/var/jcode-runs/runs"
_WORKER_USER = "_jcode_worker"


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_tree_kill_")

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

        # Phase 2: verify the escapee is ALIVE before we call kill_all.
        # If it is already dead here we cannot prove anything — the
        # canary must distinguish "terminated by us" from "died on its own".
        if not _pid_alive(escapee_pid):
            return False, (
                f"escapee PID {escapee_pid} died on its own before kill_all was called — "
                "proves nothing about uid-based kill"
            )

        # Phase 3: verify the pid's owner is the worker uid.
        # A recycled pid owned by someone else is not evidence.
        owner = _pid_owner(escapee_pid)
        if owner != _WORKER_USER:
            return False, (
                f"escapee PID {escapee_pid} is owned by '{owner}', "
                f"not '{_WORKER_USER}' — recycled pid, not evidence"
            )

        # Phase 4: call backend.kill_all().  This is the actual test.
        kill_result = backend.kill_all()
        if not kill_result["ok"]:
            return False, (
                f"kill_all returned failure: returncode={kill_result['returncode']}, "
                f"stderr={kill_result['stderr']!r}"
            )

        # Phase 5: poll up to ~5 s for the pid to disappear.
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if not _pid_alive(escapee_pid):
                break
            time.sleep(0.2)
        else:
            # Still alive after polling — kill_all did not reach it.
            return False, (
                f"escapee PID {escapee_pid} SURVIVED backend.kill_all() — "
                "uid-based pkill did not terminate the daemonised grandchild"
            )

        # Phase 6: escapee is gone.  Wait for the sandbox process to finish.
        _wait_sandbox(sandbox_proc)

        return True, (
            f"escapee PID {escapee_pid} was alive before kill_all and gone after — "
            "uid-based kill survived the setsid+double-fork escape attempt"
        )

    finally:
        # die_now is ONLY a cleanup fallback here, not the test.
        try:
            inner_ws = os.path.join(_INNER_BASE, run_id)
            with open(os.path.join(inner_ws, "die_now"), "w") as f:
                f.write("1")
        except Exception:
            pass
        try:
            backend.kill_all()
        except backend.KillUnavailable:
            pass
        if sandbox_proc is not None:
            _wait_sandbox(sandbox_proc)
        # Clean up the inner workspace left by teardown=False.
        try:
            backend.cleanup(run_id)
        except Exception:
            pass
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


def _pid_owner(pid):
    """Return the user name owning *pid*, or empty string if not found."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "user="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=3,
        )
        return result.stdout.strip()
    except Exception:
        return ""


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
