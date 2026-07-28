"""
Canary: no_network — host-side orchestrator.

Runs the no_network payload inside the sandbox and judges the results.
The payload reports raw check outcomes; the host decides pass or fail.

Must hold: every attempted outbound connection and DNS resolution is blocked.
Any success = canary failure.
"""

import json
import os
import secrets
import shutil
import string
import tempfile


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_no_network_")
    _fake = os.path.join(os.path.dirname(__file__), "..", "payloads", "_fake_attacker.py")
    shutil.copy(_fake, os.path.join(tmp, "_fake_attacker.py"))

    try:
        backend.run("no_network", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        checks = data.get("checks", {})
        if not checks:
            return False, "result.json has no checks"

        failed = [(name, ch["detail"]) for name, ch in checks.items() if ch["succeeded"]]
        if failed:
            parts = []
            for name, detail in failed:
                parts.append(f"{name}: LEAKED (BAD) ({detail})")
            for name, ch in checks.items():
                if not ch["succeeded"]:
                    parts.append(f"{name}: BLOCKED ({ch['detail']})")
            return False, " | ".join(parts)

        parts = [f"{name}: BLOCKED ({ch['detail']})" for name, ch in checks.items()]
        return True, " | ".join(parts)

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
