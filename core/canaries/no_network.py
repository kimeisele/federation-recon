"""
Canary: no_network — sandbox MUST block outbound TCP and DNS.

Must hold: connect to 1.1.1.1:80 fails, connect to 8.8.8.8:53 fails,
DNS resolution of example.com fails.  Any success = canary failure.
"""

import json
import os
import shutil
import tempfile


# ── Script that runs inside the sandbox ─────────────────────────────────

_CANARY_BODY = r"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _fake_attacker as fa

checks = {
    "tcp_1.1.1.1_80": fa.try_connect("1.1.1.1", 80, timeout=2),
    "tcp_8.8.8.8_53": fa.try_connect("8.8.8.8", 53, timeout=2),
    "dns_example_com": fa.try_dns("example.com", timeout=2),
}

passed = all(not ok for ok, _ in checks.values())
parts = []
for name, (ok, detail) in checks.items():
    status = "BLOCKED" if not ok else "LEAKED (BAD)"
    parts.append(f"{name}: {status} ({detail})")

with open(os.path.join(os.path.dirname(__file__), "result.json"), "w") as f:
    json.dump({"passed": passed, "reason": " | ".join(parts)}, f)
sys.exit(0 if passed else 1)
"""


def run(backend):
    ws = tempfile.mkdtemp(prefix="canary_no_network_")
    try:
        # Copy fake_attacker into the workspace so the sandbox can import it
        src = os.path.join(os.path.dirname(__file__), "_fake_attacker.py")
        shutil.copy(src, os.path.join(ws, "_fake_attacker.py"))

        script = os.path.join(ws, "canary.py")
        with open(script, "w") as f:
            f.write(_CANARY_BODY)
        os.chmod(script, 0o700)

        backend.run(script, ws)

        result_path = os.path.join(ws, "result.json")
        if os.path.exists(result_path):
            with open(result_path) as f:
                data = json.load(f)
            return data["passed"], data["reason"]
        else:
            return False, "no result.json produced (sandbox may have killed the script)"
    finally:
        shutil.rmtree(ws, ignore_errors=True)
