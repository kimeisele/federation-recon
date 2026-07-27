"""
Payload: tree_kill — daemonised escapee for uid-based kill verification.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Daemonises via setsid + double-fork.  The resulting grandchild writes
its PID to <workspace>/escapee.pid, then polls for a <workspace>/die_now
sentinel.  When the canary creates that file in the inner workspace, the
escapee calls os._exit(0) — no signal needed, the seatbelt profile
already restricts process-signal to self.

The original process stays alive (polling for die_now, then sleeping)
so that sandbox-exec does not exit — if it exits, the kernel tears down
the seatbelt sandbox and kills the escapee before the canary can
observe it.  The canary uses teardown=False to regain control while the
sandbox is still running.
"""

import os
import signal
import sys
import time

# Prevent SIGHUP from launchd when the grandchild is reparented.
signal.signal(signal.SIGHUP, signal.SIG_IGN)

ws = sys.argv[1]
pid_file = os.path.join(ws, "escapee.pid")
die_now = os.path.join(ws, "die_now")

# Phase 1 — first fork: parent stays alive, child daemonises.
pid = os.fork()
if pid < 0:
    sys.exit(1)
if pid > 0:
    # Parent: keep sandbox-exec alive so the canary can observe the
    # escapee.  Poll die_now briefly, then sleep.
    _wait_die_then_sleep(die_now, timeout=300)
    sys.exit(0)

# Phase 2 — child: detach from the original process group.
os.setsid()

# Phase 3 — second fork: daemonise the grandchild.
pid = os.fork()
if pid < 0:
    sys.exit(1)
if pid > 0:
    _wait_die_then_sleep(die_now, timeout=300)
    sys.exit(0)

# Phase 4 — grandchild: write pid, then poll for die_now.
try:
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))
except OSError:
    pass

# Poll die_now; exit when signalled by the canary.
deadline = time.time() + 120
while time.time() < deadline:
    if os.path.exists(die_now):
        os._exit(0)
    time.sleep(0.5)


def _wait_die_then_sleep(die_now, timeout):
    """Poll die_now briefly; if it appears exit, else sleep."""
    # Give the canary time to write die_now after it confirms the escapee alive.
    deadline = time.time() + 60
    while time.time() < deadline:
        if os.path.exists(die_now):
            sys.exit(0)
        time.sleep(0.5)
    # Not asked to die — sleep until timeout to keep sandbox-exec alive.
    time.sleep(timeout - 60)
