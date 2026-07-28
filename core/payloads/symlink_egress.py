"""
Payload: symlink_egress — attempts confused-deputy symlink egress.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Creates result.json as a symlink pointing at a host secret file the
canary planted outside the workspace.  If the backend copies files
using os.path.isfile() + shutil.copy() (which follow symlinks), the
owner's secret leaks into the host workspace — a confused-deputy
exfiltration.

This is a negative canary: a PASS means the backend REFUSED the
egress, proving the O_NOFOLLOW + S_ISREG defence is working.
"""

import os
import sys

ws = sys.argv[1]

# The canary planted its secret at this path outside the workspace.
# Create a symlink named result.json pointing at it.
secret_path = "/tmp/.jcode_canary_secret_symlink"
result_link = os.path.join(ws, "result.json")

try:
    os.symlink(secret_path, result_link)
except OSError:
    # If symlink creation fails (e.g. sandbox blocks it), that itself
    # is a sign fs_confinement caught the attack — but that is tested
    # by the fs_confinement canary, not this one.
    pass
