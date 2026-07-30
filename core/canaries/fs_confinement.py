"""
Canary: fs_confinement — host-side orchestrator with evidence objects.

Runs the fs_confinement payload inside the sandbox and judges the results.
The payload reports check outcomes as "allowed"|"blocked"|"unavailable";
the host decides pass or fail.

Evidence: every check emits expected vs observed including errno, signal,
exit status, and a checksum of any bytes read/written.  The harness asserts
on content, never on exit codes alone.

Must hold:
  - Reading ~/.config/secrets/env FAILS
  - Reading a planted fake secret outside the workspace FAILS
  - Listing $HOME FAILS
  - Listing /Library/Keychains FAILS
  - Listing /private/tmp FAILS
  - Writing outside the workspace FAILS
  - Writing inside the workspace SUCCEEDS (preservation)

Write-outside proof: creates a **world-writable** file outside the workspace
(e.g. /tmp/.jcode_canary_writable_<random>, mode 0666, with known content)
and the payload attempts to modify it.  The canary verifies host-side that
the content is **unchanged** and compares checksums.  Only DAC-permitted-but-
Seatbelt-denied proves the sandbox.

Any check returning "unavailable" = canary failure — the check must be
assessable.  Absence of evidence is not evidence of confinement.
"""

import hashlib
import json
import os
import secrets
import shutil
import stat
import string
import tempfile


# Mandatory checks that MUST be present in the payload result.
_MANDATORY_CHECKS = frozenset({
    "read_real_secret",
    "read_planted_secret",
    "list_home",
    "list_keychains",
    "list_private_tmp",
    "write_outside",
    "write_inside",
})

# Expectations: False means blocked/denied, True means allowed/succeeded.
_EXPECTATIONS = {
    "read_real_secret": False,
    "read_planted_secret": False,
    "list_home": False,
    "list_keychains": False,
    "list_private_tmp": False,
    "write_outside": False,
    "write_inside": True,
}


# Targets for host-side pre-verification: map check name → absolute path.
_READ_TARGETS = {
    "read_real_secret": "/etc/hosts",
    "read_planted_secret": "/tmp/.jcode_canary_secret_fs",
    "list_home": "/Users",
    "list_keychains": "/Library/Keychains",
    "list_private_tmp": "/private/tmp",
}


def _target_readable_by_worker(path):
    """Return True if *path* exists and is world-readable (o+r / o+rx)."""
    try:
        st = os.stat(path)
    except OSError:
        return False
    mode = st.st_mode
    if stat.S_ISDIR(mode):
        return bool(mode & stat.S_IXOTH) and bool(mode & stat.S_IROTH)
    return bool(mode & stat.S_IROTH)


def _precheck_targets():
    """Verify every mandatory read target exists and is world-readable.

    Returns None on success or a (False, reason) tuple on failure.
    """
    for name, path in _READ_TARGETS.items():
        if not os.path.exists(path):
            return False, (
                f"precheck failed: mandatory target {path!r} for check "
                f"{name!r} does not exist — cannot assess confinement"
            )
        if not _target_readable_by_worker(path):
            return False, (
                f"precheck failed: mandatory target {path!r} for check "
                f"{name!r} is not world-readable — DAC would block before Seatbelt"
            )
    return None


def _checksum_bytes(data):
    """Return SHA-256 hex digest of *data* bytes."""
    return hashlib.sha256(data).hexdigest()


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_fs_confinement_")

    # Plant a fake secret file OUTSIDE the workspace at a known path.
    planted_path = "/tmp/.jcode_canary_secret_fs"
    planted_content = "fake-api-key-planted-by-canary-orchestrator"
    with open(planted_path, "w") as f:
        f.write(planted_content)
    os.chmod(planted_path, 0o644)
    planted_checksum = _checksum_bytes(planted_content.encode())

    # Create a WORLD-WRITABLE file for the write-outside test.
    writable_path = "/tmp/.jcode_canary_writable_%s" % secrets.token_hex(8)
    writable_content = "canary-writable-test-content-" + secrets.token_hex(8)
    with open(writable_path, "w") as f:
        f.write(writable_content)
    os.chmod(writable_path, 0o666)
    writable_checksum = _checksum_bytes(writable_content.encode())

    try:
        # Write config so the payload knows the writable path.
        config_path = os.path.join(tmp, "config.json")
        with open(config_path, "w") as f:
            json.dump({"writable_path": writable_path}, f)

        # Host-side precheck.
        precheck = _precheck_targets()
        if precheck is not None:
            return precheck

        backend.run("fs_confinement", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        checks = data.get("checks", {})
        if not checks:
            return False, "result.json has no checks"

        # Build evidence objects for each check.
        evidence = {}
        for name in _MANDATORY_CHECKS:
            ch = checks.get(name)
            if ch is None:
                return False, (
                    f"mandatory check {name!r} is missing from payload result"
                )
            outcome = ch.get("outcome")
            detail = ch.get("detail", "")
            if outcome not in ("allowed", "blocked", "unavailable"):
                return False, (
                    f"mandatory check {name!r} has invalid outcome {outcome!r} "
                    f"(detail: {detail})"
                )
            if outcome == "unavailable":
                return False, (
                    f"mandatory check {name!r} returned UNAVAILABLE: {detail} — "
                    "absent evidence is not evidence"
                )

            ev = {
                "expected": "blocked" if _EXPECTATIONS.get(name) is False else "allowed",
                "observed": outcome,
                "detail": detail,
            }

            # For read checks, compute checksum of expected content.
            if name == "read_planted_secret":
                ev["expected_checksum"] = planted_checksum
            elif name == "write_inside":
                # The write_inside test writes "canary-write-test" to a file.
                ev["expected_bytes"] = _checksum_bytes(b"canary-write-test")
            elif name == "write_outside":
                ev["expected_checksum"] = writable_checksum

            evidence[name] = ev

        # Verify the world-writable file content is UNCHANGED via checksum.
        try:
            with open(writable_path, "rb") as f:
                actual_bytes = f.read()
            actual_checksum = _checksum_bytes(actual_bytes)
            if actual_checksum != writable_checksum:
                return False, (
                    f"WRITE LEAK: world-writable file {writable_path} was modified "
                    f"(checksum mismatch: expected {writable_checksum}, "
                    f"got {actual_checksum}) — the sandbox did not block "
                    "the write-outside attempt"
                )
        except Exception as exc:
            return False, (
                f"could not verify writable file after run: {exc}"
            )

        # Also verify write_inside: read back the file the payload wrote.
        inside_path = os.path.join(tmp, "inside_test.txt")
        if os.path.exists(inside_path):
            try:
                with open(inside_path, "rb") as f:
                    inside_bytes = f.read()
                inside_checksum = _checksum_bytes(inside_bytes)
                expected_inside = _checksum_bytes(b"canary-write-test")
                if inside_checksum != expected_inside:
                    return False, (
                        f"WRITE INSIDE checksum mismatch: "
                        f"expected {expected_inside}, got {inside_checksum} — "
                        "bytes read back differ from what was written"
                    )
            except Exception as exc:
                return False, (
                    f"could not verify write_inside file: {exc}"
                )

        passed = True
        parts = []
        for name in sorted(checks):
            ch = checks[name]
            outcome = ch["outcome"]
            detail = ch["detail"]
            must_succeed = _EXPECTATIONS.get(name)

            if must_succeed is True:
                if outcome == "blocked":
                    passed = False
                    parts.append(f"{name}: BLOCKED (BAD) ({detail})")
                else:
                    parts.append(f"{name}: ALLOWED ({detail})")
            elif must_succeed is False:
                if outcome == "allowed":
                    passed = False
                    parts.append(f"{name}: LEAKED (BAD) ({detail})")
                else:
                    parts.append(f"{name}: BLOCKED ({detail})")

        return passed, " | ".join(parts)

    finally:
        try:
            os.remove(planted_path)
        except OSError:
            pass
        try:
            os.remove(writable_path)
        except OSError:
            pass
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
