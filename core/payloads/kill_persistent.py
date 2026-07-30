"""
Payload: kill_persistent — continuously forking replacement children.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Each child immediately forks and exits, so the process tree regenerates
continuously.  The parent keeps spawning new children until it is killed
by the canary's kill_all() call.

This tests whether kill_all() can reach zero even when the tree is
actively regenerating — a single pkill would miss children that fork
between the table walk and the signal delivery.
"""

import os
import sys
import time

ws = sys.argv[1]

# The parent forks children indefinitely.  Each child forks once more
# (the grandchild sleeps briefly) and exits, creating a continuously
# regenerating process tree.
while True:
    try:
        pid = os.fork()
        if pid == 0:
            # Child: fork a replacement, then exit.
            try:
                pid2 = os.fork()
                if pid2 == 0:
                    # Grandchild: sleep briefly, then exit.
                    time.sleep(5)
                    os._exit(0)
                # Child exits; grandchild is reparented to init.
            except OSError:
                pass
            os._exit(0)
        # Parent: brief pause, then fork again.
        time.sleep(0.01)
    except OSError:
        # Fork failed (rlimit or table full) — brief pause, retry.
        time.sleep(0.1)
