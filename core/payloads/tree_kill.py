"""
Payload: tree_kill — daemonised escapee for uid-based kill verification.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Daemonises via setsid + double-fork.  The resulting grandchild writes
its PID to <workspace>/escapee.pid, then sleeps ~120 s.  The grandchild
does NOT poll die_now — it must be killed, not asked.  The canary calls
backend.kill_all() to terminate it; that is the test.

Parent and middle process stay alive (sleeping) so sandbox-exec does not
exit — if it exits, the kernel tears down the seatbelt sandbox and kills
the escapee before the canary can observe it.  The canary uses
teardown=False to regain control while the sandbox is still running.
"""

import os
import signal
import sys
import time


def _sleep_forever(duration):
    """Sleep for *duration* seconds, keeping the process alive."""
    time.sleep(duration)


# Prevent SIGHUP from launchd when the grandchild is reparented.
signal.signal(signal.SIGHUP, signal.SIG_IGN)

ws = sys.argv[1]
pid_file = os.path.join(ws, "escapee.pid")

# Phase 1 — first fork: parent stays alive, child daemonises.
pid = os.fork()
if pid < 0:
    sys.exit(1)
if pid > 0:
    # Parent: keep sandbox-exec alive by sleeping.
    _sleep_forever(300)
    sys.exit(0)

# Phase 2 — child: detach from the original process group.
os.setsid()

# Phase 3 — second fork: daemonise the grandchild.
pid = os.fork()
if pid < 0:
    sys.exit(1)
if pid > 0:
    # Middle: keep sandbox-exec alive by sleeping.
    _sleep_forever(300)
    sys.exit(0)

# Phase 4 — grandchild: write pid, then sleep.
# Must NOT poll die_now — the test is whether kill_all() reaches it.
try:
    with open(pid_file, "w") as f:
        f.write(str(os.getpid()))
except OSError:
    pass

# Sleep ~120 s.  The canary must kill us; if it does not, the watchdog
# timer in the launcher will eventually clean up.
_sleep_forever(120)
