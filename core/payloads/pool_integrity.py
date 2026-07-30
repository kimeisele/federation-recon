"""
Payload: pool_integrity — never executed.

This payload exists only to satisfy the wrapper's file-existence
check.  The pool_integrity canary runs entirely on the host side
(via dscl, sudo, etc.) and never needs to run inside the sandbox.
"""

import sys

if __name__ == "__main__":
    sys.exit(0)
