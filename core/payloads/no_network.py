"""
Payload: no_network — attempts outbound TCP and DNS from inside the sandbox.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports raw check results — does NOT judge.  The host-side canary
decides pass or fail.
"""

import json
import os
import sys

ws = sys.argv[1]
sys.path.insert(0, ws)
import _fake_attacker as fa  # noqa: E402

checks = {
    "tcp_1.1.1.1_443": fa.try_connect("1.1.1.1", 443, timeout=2),
    "dns_example_com": fa.try_dns("example.com", timeout=2),
}

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(
        {"checks": {name: {"succeeded": ok, "detail": detail} for name, (ok, detail) in checks.items()}},
        f,
    )
