"""
Payload: no_network — attempts outbound TCP and DNS from inside the sandbox.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports raw check results — does NOT judge.  The host-side canary
decides pass or fail.
"""

import json
import os
import socket
import sys


def _try_connect(host, port, timeout=2):
    """Attempt a TCP connect.  Returns (succeeded: bool, detail: str)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return True, f"connected to {host}:{port}"
    except Exception as e:
        return False, f"{host}:{port} -> {e}"


def _try_dns(host, timeout=2):
    """Attempt DNS resolution.  Returns (succeeded: bool, detail: str)."""
    try:
        socket.setdefaulttimeout(timeout)
        addrs = socket.getaddrinfo(host, None)
        ips = sorted(set(a[4][0] for a in addrs))
        return True, f"{host} -> {', '.join(ips)}"
    except Exception as e:
        return False, f"{host} -> {e}"


ws = sys.argv[1]

checks = {
    "tcp_1.1.1.1_443": _try_connect("1.1.1.1", 443, timeout=2),
    "dns_example_com": _try_dns("example.com", timeout=2),
}

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(
        {"checks": {name: {"succeeded": ok, "detail": detail} for name, (ok, detail) in checks.items()}},
        f,
    )
