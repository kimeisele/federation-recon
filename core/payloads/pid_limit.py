"""
Payload: pid_limit — fork bomb that MUST be stopped by RLIMIT_NPROC.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

One controlling parent forks children that sleep (they never fork
themselves).  Counts successes until OSError.  Only the parent writes
result.json — children must never write output.

Does NOT judge — the host-side canary decides pass or fail.
"""

import json
import os
import sys
import time


def _child_sleep(duration=60):
    """Child process: sleep until killed or timeout.

    Must never fork, never write output, never call sys.exit() on its own.
    os._exit(0) is used only if signalled (SIGTERM from kill_all).
    """
    try:
        time.sleep(duration)
    except Exception:
        pass
    os._exit(0)


ws = sys.argv[1]

# One controlling parent.  It forks children that sleep and never fork
# again.  Count successes until OSError (EAGAIN from RLIMIT_NPROC).
count = 0
saved_errno = None
saved_strerror = None
error_record = None

try:
    while True:
        pid = os.fork()
        if pid == 0:
            # Child: sleep, never fork, never write output.
            _child_sleep()
            # Unreachable, but belt and suspenders.
            os._exit(0)
        # Parent: count the child.
        count += 1
except OSError as e:
    # Expected: EAGAIN when RLIMIT_NPROC is hit.
    saved_errno = e.errno
    saved_strerror = e.strerror
except Exception as e:
    # Any other exception is recorded (not swallowed).
    error_record = f"{type(e).__name__}: {e}"

# Only the parent writes result.json.
result = {
    "fork_count": count,
}
if saved_errno is not None:
    result["errno"] = saved_errno
    result["strerror"] = saved_strerror
if error_record is not None:
    result["error"] = error_record

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(result, f)
