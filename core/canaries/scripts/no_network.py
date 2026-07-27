"""
Canary script: no_network — sandbox MUST block outbound TCP and DNS.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Must hold: connect to 1.1.1.1:80 fails, connect to 8.8.8.8:53 fails,
DNS resolution of example.com fails.  Any success = canary failure.
"""

import json
import os
import sys

ws = sys.argv[1]
sys.path.insert(0, ws)
import _fake_attacker as fa  # noqa: E402

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

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump({"passed": passed, "reason": " | ".join(parts)}, f)
sys.exit(0 if passed else 1)
