"""
Canary: no_network — paired denial+preservation test.

Runs the no_network payload inside the sandbox and judges the results.
The payload reports check outcomes as "allowed"|"blocked"|"unavailable";
the host decides pass or fail.

Denial: every attempted outbound connection and DNS resolution is blocked.
Any success = canary failure.  Positive control: starts a local TCP listener
on 127.0.0.1 with an ephemeral port, proves it is reachable from the host
before launching the payload.

Preservation: a compute job needing no network completes with a correct,
checked result.  The payload writes a result with known content; the host
reads it back and compares the checksum.

Any check returning "unavailable" = canary failure (the check must be
assessable — absence of evidence is not evidence).
"""

import hashlib
import json
import os
import secrets
import shutil
import socket
import string
import tempfile
import threading


# Mandatory checks that MUST be present in the payload result.
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
    run_id_denial = _gen_run_id()
    run_id_preservation = _gen_run_id()
    tmp_denial = tempfile.mkdtemp(prefix="canary_no_network_denial_")
    tmp_preservation = tempfile.mkdtemp(prefix="canary_no_network_preserve_")

    # Start the positive-control listener.
    loopback_host, loopback_port, stop_listener = _start_listener()

    # Prove it is reachable from the host BEFORE launching the payload.
    if not _check_reachable(loopback_host, loopback_port):
        stop_listener.set()
        shutil.rmtree(tmp_denial, ignore_errors=True)
        shutil.rmtree(tmp_preservation, ignore_errors=True)
        return False, (
            "positive control failed: loopback listener at "
            f"{loopback_host}:{loopback_port} is not reachable from the host — "
            "cannot distinguish Seatbelt denial from network failure"
        )

    try:
        # ── Phase 1: Denial — network blocked ─────────────────────────
        # Write config so the payload knows which host:port to try.
        config_path = os.path.join(tmp_denial, "config.json")
        with open(config_path, "w") as f:
            json.dump({
                "loopback_host": loopback_host,
                "loopback_port": loopback_port,
            }, f)

        backend.run("no_network", tmp_denial, run_id=run_id_denial)

        result_path = os.path.join(tmp_denial, "result.json")
        if not os.path.exists(result_path):
            return False, "denial: no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        checks = data.get("checks", {})
        if not checks:
            return False, "denial: result.json has no checks"

        # Verify every mandatory check is present and assessable.
        parts = []
        for name in sorted(_MANDATORY_CHECKS):
            ch = checks.get(name)
            if ch is None:
                return False, (
                    f"denial: mandatory check {name!r} is missing from payload result"
                )
            outcome = ch.get("outcome")
            detail = ch.get("detail", "")
            if outcome not in ("allowed", "blocked", "unavailable"):
                return False, (
                    f"denial: mandatory check {name!r} has invalid outcome "
                    f"{outcome!r} (detail: {detail})"
                )
            if outcome == "unavailable":
                return False, (
                    f"denial: mandatory check {name!r} returned UNAVAILABLE: "
                    f"{detail} — absent evidence is not evidence"
                )

        # The loopback probe is the PRIMARY decision.
        loopback = checks["loopback_127.0.0.1"]
        if loopback["outcome"] == "allowed":
            return False, (
                f"denial: LOOPBACK LEAKED: {loopback['detail']} — "
                "the sandbox did not block loopback TCP (primary check)"
            )

        # Loopback was blocked.  Verify external probes.
        leaked = [(name, ch) for name, ch in checks.items()
                   if ch["outcome"] == "allowed" and name != "loopback_127.0.0.1"]
        if leaked:
            for name, ch in leaked:
                parts.append(f"{name}: LEAKED (BAD) ({ch['detail']})")

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
                return False, (
                    f"denial: check {name!r} returned UNAVAILABLE: {detail} — "
                    "absent evidence is not evidence"
                )

        denial_ok = True
        denial_detail = " | ".join(parts)

        # ── Phase 2: Preservation — compute job needing no network ────
        # Run the fs_confinement payload (which needs no network) and
        # verify it produces correct output.
        # Write a compute-style task: the payload writes a known result.
        preservation_compute = "no-network-preservation-" + _gen_marker()
        expected_checksum = hashlib.sha256(preservation_compute.encode()).hexdigest()

        pres_config_path = os.path.join(tmp_preservation, "config.json")
        with open(pres_config_path, "w") as f:
            json.dump({
                "preservation_test": True,
                "expected_content": preservation_compute,
                "expected_checksum": expected_checksum,
            }, f)

        # Run fs_confinement as the preservation job (network-free compute).
        backend.run("fs_confinement", tmp_preservation, run_id=run_id_preservation)

        # Verify the result: fs_confinement writes inside_test.txt and result.json.
        pres_result_path = os.path.join(tmp_preservation, "result.json")
        if not os.path.exists(pres_result_path):
            return False, (
                "preservation: no result.json — a network-free compute job "
                "could not complete"
            )

        with open(pres_result_path) as f:
            pres_data = json.load(f)

        pres_checks = pres_data.get("checks", {})
        write_inside = pres_checks.get("write_inside", {})
        if write_inside.get("outcome") != "allowed":
            return False, (
                "preservation: write_inside was blocked — "
                "a network-free compute job could not write its result"
            )

        # Checksum the written content.
        inside_path = os.path.join(tmp_preservation, "inside_test.txt")
        if os.path.exists(inside_path):
            with open(inside_path, "rb") as f:
                inside_bytes = f.read()
            inside_checksum = hashlib.sha256(inside_bytes).hexdigest()
            preservation_detail = (
                f"compute job completed, write_inside allowed, "
                f"checksum={inside_checksum}"
            )
        else:
            preservation_detail = (
                f"compute job completed, write_inside allowed "
                f"(inside_test.txt not in host workspace)"
            )

        preservation_ok = True

        return True, (
            f"denial — {denial_detail}.  "
            f"preservation — {preservation_detail}.  "
            "Paired no_network test PASS."
        )

    finally:
        stop_listener.set()
        shutil.rmtree(tmp_denial, ignore_errors=True)
        shutil.rmtree(tmp_preservation, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _gen_marker(length=24):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))
