"""
Canary script: tree_kill — daemonised escapee for uid-based kill verification.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

This script daemonises via setsid + double-fork.  The resulting grandchild
writes its PID to <workspace>/escapee.pid, then sleeps for 120 seconds.
The orchestrator reads the PID, calls kill_all(), and verifies the PID is
gone — confirming that pkill -9 -u reaches processes outside the original
process group.
"""

import os
import sys

ws = sys.argv[1]
sys.path.insert(0, ws)
import _fake_attacker as fa  # noqa: E402

pid_file = os.path.join(ws, "escapee.pid")
fa.escape_and_sleep(pid_file, sleep_secs=120)
