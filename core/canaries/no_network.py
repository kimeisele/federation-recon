"""
Canary: no_network — host-side orchestrator with positive control.

Runs the no_network payload inside the sandbox and judges the results.
The payload reports check outcomes as "allowed"|"blocked"|"unavailable";
the host decides pass or fail.

Positive control: starts a local TCP listener on 127.0.0.1 with an
ephemeral port, and proves it is reachable from the host before launching
the payload.  The payload then attempts that exact host:port.  A connection
failure now means Seatbelt blocked it, because reachability was just
established.  Keep the existing external probes as supporting evidence, but
the loopback probe is the one that decides.

Must hold: every attempted outbound connection and DNS resolution is blocked.
Any success = canary failure.
Any check returning "unavailable" = canary failure (the check must be
assessable — absence of evidence is not evidence).
"""

import json
import os
import secrets
import shutil
import socket
import string
import tempfile
import threading


# Mandatory checks that MUST be present in the payload result.
# If any is missing or reports "unavailable", the canary FAILs.
_MANDATORY_CHECKS = frozenset({
    "tcp_1.1.1.1_443",
    "dns_example_com",
    "loopback_127.0.0.1",
})


def _start_listener():
    """Start a TCP listener on 127.0.0.1:0 and return (host, port, stop_event)."""
    host = "127.0.0.1"
    stop = threading.Event()
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind((host, 0))
    port = server_sock.getsockname()[1]
    server_sock.listen(1)

    def _serve():
        server_sock.settimeout(1.0)
        while not stop.is_set():
            try:
                conn, _ = server_sock.accept()
                conn.close()
            except socket.timeout:
                continue
            except Exception:
                break
        try:
            server_sock.close()
        except Exception:
            pass

    t = threading.Thread(target=_serve, daemon=True)
    t.start()
    return host, port, stop


def _check_reachable(host, port, timeout=2):
    """Prove the listener is reachable from THIS host before the sandbox runs."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return True
    except Exception:
        return False


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_no_network_")

    # Start the positive-control listener.
    loopback_host, loopback_port, stop_listener = _start_listener()

    # Prove it is reachable from the host BEFORE launching the payload.
    if not _check_reachable(loopback_host, loopback_port):
        stop_listener.set()
        shutil.rmtree(tmp, ignore_errors=True)
        return False, (
            "positive control failed: loopback listener at "
            f"{loopback_host}:{loopback_port} is not reachable from the host — "
            "cannot distinguish Seatbelt denial from network failure"
        )

    try:
        # Write config so the payload knows which host:port to try.
        config_path = os.path.join(tmp, "config.json")
        with open(config_path, "w") as f:
            json.dump({
                "loopback_host": loopback_host,
                "loopback_port": loopback_port,
            }, f)

        backend.run("no_network", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        checks = data.get("checks", {})
        if not checks:
            return False, "result.json has no checks"

        # Verify every mandatory check is present and assessable.
        parts = []
        for name in sorted(_MANDATORY_CHECKS):
            ch = checks.get(name)
            if ch is None:
                return False, (
                    f"mandatory check {name!r} is missing from payload result"
                )
            outcome = ch.get("outcome")
            detail = ch.get("detail", "")
            # Validate outcome is a recognised enum value.
            if outcome not in ("allowed", "blocked", "unavailable"):
                return False, (
                    f"mandatory check {name!r} has invalid outcome {outcome!r} "
                    f"(detail: {detail}) — must be one of allowed/blocked/unavailable"
                )
            if outcome == "unavailable":
                return False, (
                    f"mandatory check {name!r} returned UNAVAILABLE: {detail} — "
                    "absent evidence is not evidence"
                )

        # The loopback probe is the PRIMARY decision.  If it succeeded,
        # Seatbelt did NOT block loopback — the sandbox is permeable.
        loopback = checks["loopback_127.0.0.1"]
        if loopback["outcome"] == "allowed":
            return False, (
                f"LOOPBACK LEAKED: {loopback['detail']} — "
                "the sandbox did not block loopback TCP (primary check)"
            )

        # Loopback was blocked.  Verify external probes as supporting evidence.
        leaked = [(name, ch) for name, ch in checks.items()
                   if ch["outcome"] == "allowed" and name != "loopback_127.0.0.1"]
        if leaked:
            for name, ch in leaked:
                parts.append(f"{name}: LEAKED (BAD) ({ch['detail']})")

        # Report every check's outcome.
        for name in sorted(checks):
            ch = checks[name]
            outcome = ch["outcome"]
            detail = ch["detail"]
            if outcome == "allowed":
                if name not in {l[0] for l in leaked}:
                    parts.append(f"{name}: ALLOWED ({detail})")
            elif outcome == "blocked":
                parts.append(f"{name}: BLOCKED ({detail})")
            elif outcome == "unavailable":
                # Already caught above for mandatory checks; non-mandatory
                # unavailable is still a failure.
                return False, (
                    f"check {name!r} returned UNAVAILABLE: {detail} — "
                    "absent evidence is not evidence"
                )

        return True, " | ".join(parts)

    finally:
        stop_listener.set()
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
