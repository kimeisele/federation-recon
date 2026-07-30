"""
Payload: no_network — attempts outbound TCP, DNS, and loopback from inside the sandbox.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports raw check results as three-outcome ("allowed"|"blocked"|"unavailable").
Does NOT judge — the host-side canary decides pass or fail.

The loopback check is the primary decision: if a local listener was
confirmed reachable from the host pre-launch, a connection failure from
inside the sandbox means Seatbelt blocked it.
"""

import json
import os
import socket
import sys


def _try_connect(host, port, timeout=2):
    """Attempt a TCP connect.

    Returns {"outcome": "allowed"|"blocked", "detail": str}.
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return {"outcome": "allowed", "detail": f"connected to {host}:{port}"}
    except Exception as e:
        return {"outcome": "blocked", "detail": f"{host}:{port} -> {e}"}


def _try_dns(host, timeout=2):
    """Attempt DNS resolution.

    Returns {"outcome": "allowed"|"blocked", "detail": str}.
    """
    try:
        socket.setdefaulttimeout(timeout)
        addrs = socket.getaddrinfo(host, None)
        ips = sorted(set(a[4][0] for a in addrs))
        return {"outcome": "allowed", "detail": f"{host} -> {', '.join(ips)}"}
    except Exception as e:
        return {"outcome": "blocked", "detail": f"{host} -> {e}"}


ws = sys.argv[1]

# Read loopback target from config (written by host-side canary).
loopback_host = "127.0.0.1"
loopback_port = None
config_path = os.path.join(ws, "config.json")
config_err = None
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
        loopback_host = config.get("loopback_host", "127.0.0.1")
        loopback_port = config.get("loopback_port")
    except (OSError, json.JSONDecodeError) as e:
        config_err = str(e)

checks = {
    "tcp_1.1.1.1_443": _try_connect("1.1.1.1", 443, timeout=2),
    "dns_example_com": _try_dns("example.com", timeout=2),
}

# Loopback probe — the primary decision.
if config_err is not None:
    checks["loopback_127.0.0.1"] = {
        "outcome": "unavailable",
        "detail": f"config unreadable: {config_err}",
    }
elif loopback_port is not None:
    checks["loopback_127.0.0.1"] = _try_connect(loopback_host, loopback_port, timeout=2)
else:
    checks["loopback_127.0.0.1"] = {
        "outcome": "unavailable",
        "detail": "no loopback target configured — cannot assess",
    }

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump({"checks": checks}, f)
