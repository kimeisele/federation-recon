"""
Payload: pid_limit — fork bomb that MUST be stopped by RLIMIT_NPROC.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports the fork count reached before the rlimit stopped it.
Does NOT judge — the host-side canary decides pass or fail.
"""

import json
import os
import sys

ws = sys.argv[1]

# Fork bomb: each child forks again, cascading.
# Must be stopped by RLIMIT_NPROC (ulimit -u 64 from worker_exec.sh).
# If not stopped, this would bring the host to its knees.

count = 0
try:
    while True:
        pid = os.fork()
        if pid == 0:
            # Child: loop again
            count = 0
            continue
        else:
            count += 1
except OSError:
    # Expected: EAGAIN or similar when rlimit is hit
    pass
except Exception:
    pass

# Only the original process should reach here (children loop).
with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump({"fork_count": count}, f)
