"""
Payload: kill_persistent — churning process population with headroom.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

The population is kept well below RLIMIT_NPROC (target ~30 of 64) so
there is always headroom to fork.  Every process is short-lived: fork
a replacement immediately on start, sleep a randomised interval (tens
of milliseconds), exit.  A supervisor keeps the population topped up.

This creates continuous PID turnover with free capacity.  During a kill
sweep a survivor can fork a replacement the sweep has already passed,
making a non-atomic traversal miss some descendants.  Only the
STOP-then-KILL protocol can clear the slot.

On EAGAIN the process sleeps briefly and retries; it never exits the
loop.  A process that gives up is not adversarial.
"""

import os
import random
import sys
import time

# Target direct children for the supervisor.  Each child forks one
# replacement immediately on start, so total population ≈ 2 * TARGET.
# 15 direct children → ~30 total, well below RLIMIT_NPROC (64).
_TARGET = 15
_MIN_SLEEP = 0.010   # 10 ms
_MAX_SLEEP = 0.090   # 90 ms
_RETRY_SLEEP = 0.020  # 20 ms wait on EAGAIN
_SUPERVISOR_SLEEP = 0.050  # 50 ms poll interval when at target

ws = sys.argv[1]

pid_file = os.path.join(ws, "pid")
with open(pid_file, "w") as f:
    f.write(str(os.getpid()))

evidence_file = os.path.join(ws, "evidence")
with open(evidence_file, "w") as f:
    f.write("kill_persistent: churning population below RLIMIT_NPROC")


def _short_lived() -> None:
    """Short-lived process lifecycle.

    Fork a replacement immediately on start, sleep a short randomised
    interval, then exit.  Both the original process and the replacement
    follow this lifecycle, so each supervisor fork yields two processes
    that die after tens of milliseconds, freeing capacity for new PIDs.

    If fork returns EAGAIN, skip (the process still exits on schedule,
    freeing a slot for the next cycle).
    """
    try:
        pid = os.fork()
        if pid == 0:
            # Replacement: also goes through this lifecycle (sleep, exit).
            pass
        # Parent (supervisor's direct child) falls through to sleep+exit.
    except OSError:
        # EAGAIN — no headroom right now, but this process will exit
        # shortly, freeing a slot.
        pass

    interval = random.uniform(_MIN_SLEEP, _MAX_SLEEP)
    time.sleep(interval)
    os._exit(0)


def _supervisor_loop() -> None:
    """Maintain ~_TARGET direct children.

    Track children via waitpid and replenish when the count drops below
    the target.  Each child forks its own replacement, so total slot
    population is roughly 2 * _TARGET (~30 PIDs).
    """
    children: dict[int, bool] = {}

    while True:
        # Reap exited children (non-blocking).
        while True:
            try:
                wpid, _ = os.waitpid(-1, os.WNOHANG)
                if wpid == 0:
                    break
                children.pop(wpid, None)
            except OSError:
                break

        alive = len(children)

        if alive < _TARGET:
            try:
                pid = os.fork()
                if pid == 0:
                    _short_lived()
                    os._exit(0)  # unreachable, but defensive
                children[pid] = True
            except OSError:
                # EAGAIN — RLIMIT_NPROC hit.  Sleep briefly and retry;
                # never exit the loop.
                time.sleep(_RETRY_SLEEP)
        else:
            time.sleep(_SUPERVISOR_SLEEP)


_supervisor_loop()
