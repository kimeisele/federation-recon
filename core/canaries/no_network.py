"""
Canary: no_network — sandbox MUST block outbound TCP and DNS.

Must hold: connect to 1.1.1.1:80 fails, connect to 8.8.8.8:53 fails,
DNS resolution of example.com fails.  Any success = canary failure.
"""

import json
import os
import shutil
import tempfile


def run(backend):
    ws = tempfile.mkdtemp(prefix="canary_no_network_")
    try:
        # Copy fake_attacker into the workspace so the sandbox can import it
        src = os.path.join(os.path.dirname(__file__), "_fake_attacker.py")
        shutil.copy(src, os.path.join(ws, "_fake_attacker.py"))

        backend.run("no_network", ws)

        result_path = os.path.join(ws, "result.json")
        if os.path.exists(result_path):
            with open(result_path) as f:
                data = json.load(f)
            return data["passed"], data["reason"]
        else:
            return False, "no result.json produced (sandbox may have killed the script)"
    finally:
        shutil.rmtree(ws, ignore_errors=True)
