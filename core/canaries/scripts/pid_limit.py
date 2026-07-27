"""
Canary script: pid_limit — a fork bomb MUST be stopped at the rlimit.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Must hold: the fork bomb is killed by RLIMIT_NPROC (or the kernel
refuses further forks).  The mechanism is EAGAIN/ENOMEM from fork(),
or SIGKILL from the OOM killer — both are detected via the resulting
exit_status / term_signal.
"""

import json
import os
import sys

ws = sys.argv[1]

# Fork bomb: each child forks again, cascading.
# Must be stopped by RLIMIT_NPROC (nproc=64 from policy.json).
# If not stopped, this would bring the host to its knees.
# The sandbox profile denies network so no remote amplification.

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
# If this fires, the rlimit stopped the cascade.
result = {
    "passed": True,
    "reason": f"fork bomb stopped after roughly {count} concurrent children in parent",
}
with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(result, f)
sys.exit(0)
