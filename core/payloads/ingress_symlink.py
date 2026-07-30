"""
Payload: ingress_symlink — never executed.

This payload exists only to satisfy the wrapper's file-existence
check.  The ingress_symlink canary pre-creates the run directory,
so backend.run() refuses at the os.mkdir stage before any sandbox
is launched.  No payload is ever needed.
"""

import sys

if __name__ == "__main__":
    sys.exit(0)
