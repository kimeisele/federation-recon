"""
Canary: tree_kill — process tree MUST be fully killable, even with escapees.

Must hold: a child that does setsid(), double-forks, and daemonises,
leaving the original process group, MUST still be killed completely.

A plain child kill proves nothing — kill(-pgid) handles that already.
This canary tests the uid-based kill path in macos_seatbelt.kill_all().

Mechanism:
  1. Run an escapee setup script inside the sandbox that spawns a
     daemonised grandchild.
  2. Read the grandchild PID from the workspace.
  3. Call backend.kill_all() — pkill -9 -u WORKER_USER.
  4. Verify the grandchild PID no longer exists via os.kill(pid, 0).
"""

import json
import os
import shutil
import tempfile
import time


_ESCAPEE_SCRIPT = r"""
import os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _fake_attacker as fa

pid_file = os.path.join(os.path.dirname(__file__), "escapee.pid")
fa.escape_and_sleep(pid_file, sleep_secs=120)
"""


def run(backend):
    ws = tempfile.mkdtemp(prefix="canary_tree_kill_")
    try:
        src = os.path.join(os.path.dirname(__file__), "_fake_attacker.py")
        shutil.copy(src, os.path.join(ws, "_fake_attacker.py"))

        script = os.path.join(ws, "escapee.py")
        with open(script, "w") as f:
            f.write(_ESCAPEE_SCRIPT)
        os.chmod(script, 0o700)

        # Phase 1: spawn the escapee
        backend.run(script, ws)

        # Give the daemonised grandchild a moment to write its PID
        time.sleep(1)

        pid_file = os.path.join(ws, "escapee.pid")
        if not os.path.exists(pid_file):
            return False, "escapee did not write PID file — double-fork may have failed"

        with open(pid_file) as f:
            escapee_pid = int(f.read().strip())

        # Verify the escapee is alive before we try to kill it
        if not _pid_alive(escapee_pid):
            return False, f"escapee PID {escapee_pid} was already dead before kill_all"

        # Phase 2: kill the entire tree
        backend.kill_all()

        # Give the kill a moment to propagate
        time.sleep(1.5)

        # Phase 3: verify the escapee is dead
        if _pid_alive(escapee_pid):
            return False, (
                f"escapee PID {escapee_pid} SURVIVED kill_all(). "
                "pkill -9 -u did not reach the daemonised grandchild."
            )

        return True, (
            f"escapee PID {escapee_pid} was killed by kill_all(). "
            "uid-based kill survived the setsid+double-fork escape attempt."
        )

    finally:
        # Clean up any remaining escapees before removing workspace
        backend.kill_all()
        shutil.rmtree(ws, ignore_errors=True)


def _pid_alive(pid):
    """Return True if a process with *pid* exists."""
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False
