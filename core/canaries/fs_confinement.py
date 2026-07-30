"""
Canary: fs_confinement — host-side orchestrator.

Runs the fs_confinement payload inside the sandbox and judges the results.
The payload reports check outcomes as "allowed"|"blocked"|"unavailable";
the host decides pass or fail.

Must hold:
  - Reading ~/.config/secrets/env FAILS
  - Reading a planted fake secret outside the workspace FAILS
  - Listing $HOME FAILS
  - Listing /Library/Keychains FAILS
  - Listing /private/tmp FAILS
  - Writing outside the workspace FAILS
  - Writing inside the workspace SUCCEEDS

Write-outside proof: creates a **world-writable** file outside the workspace
(e.g. /tmp/.jcode_canary_writable_<random>, mode 0666, with known content)
and the payload attempts to modify it.  The canary verifies host-side that
the content is **unchanged**.  Only DAC-permitted-but-Seatbelt-denied proves
the sandbox.

Any check returning "unavailable" = canary failure — the check must be
assessable.  Absence of evidence is not evidence of confinement.
"""

import json
import os
import secrets
import shutil
import stat
import string
import tempfile


# Mandatory checks that MUST be present in the payload result.
# If any is missing or reports "unavailable", the canary FAILs.
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
# The canary verifies each exists and is DAC-readable before launching.
_READ_TARGETS = {
    "read_real_secret": "/etc/hosts",
    "read_planted_secret": "/tmp/.jcode_canary_secret_fs",
    "list_home": "/Users",
    "list_keychains": "/Library/Keychains",
    "list_private_tmp": "/private/tmp",
}


def _target_readable_by_worker(path):
    """Return True if *path* exists and is world-readable (o+r / o+rx).

    The seatbelt worker runs as _jcode_worker (uid 601), not as the
    calling user.  A DAC check against our own uid would be wrong.
    We check world permissions instead: if the target is not world-
    readable, the sandbox is not the only thing blocking access, and
    the measurement is confounded.
    """
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


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_fs_confinement_")

    # Plant a fake secret file OUTSIDE the workspace at a known path.
    # It is created world-readable (0o644) in /tmp.  A process running
    # as _jcode_worker would be able to read it by Unix permissions —
    # only the sandbox profile, which denies access to everything
    # outside WORKSPACE, should block it.  This isolates the test to
    # the sandbox itself, not Unix file permissions.
    planted_path = "/tmp/.jcode_canary_secret_fs"
    with open(planted_path, "w") as f:
        f.write("fake-api-key-planted-by-canary-orchestrator")
    os.chmod(planted_path, 0o644)

    # Create a WORLD-WRITABLE file for the write-outside test.
    # mode 0666 means any process on the host can modify it — if the
    # sandbox blocks the write, it is because Seatbelt, not Unix DAC.
    writable_path = "/tmp/.jcode_canary_writable_%s" % secrets.token_hex(8)
    writable_content = "canary-writable-test-content-" + secrets.token_hex(8)
    with open(writable_path, "w") as f:
        f.write(writable_content)
    os.chmod(writable_path, 0o666)

    try:
        # Write config so the payload knows the writable path (instead of
        # scanning /tmp, which the same sandbox blocks).
        config_path = os.path.join(tmp, "config.json")
        with open(config_path, "w") as f:
            json.dump({"writable_path": writable_path}, f)

        # Host-side precheck: verify every mandatory read target exists and is
        # world-readable.  Fail early if a target cannot serve as evidence.
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

        # Verify every mandatory check is present and assessable.
        for name in _MANDATORY_CHECKS:
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

        # Also fail on any invalid or UNAVAILABLE in non-mandatory checks.
        for name, ch in checks.items():
            outcome = ch.get("outcome")
            if outcome not in ("allowed", "blocked", "unavailable", None):
                return False, (
                    f"check {name!r} has invalid outcome {outcome!r} "
                    f"(detail: {ch.get('detail', '')}) — must be one of allowed/blocked/unavailable"
                )
            if outcome == "unavailable":
                return False, (
                    f"check {name!r} returned UNAVAILABLE: {ch.get('detail', '')} — "
                    "absent evidence is not evidence"
                )

        # Verify the world-writable file content is UNCHANGED.
        try:
            with open(writable_path, "r") as f:
                actual_content = f.read()
            if actual_content != writable_content:
                return False, (
                    f"WRITE LEAK: world-writable file {writable_path} was modified — "
                    "the sandbox did not block the write-outside attempt"
                )
        except Exception as exc:
            return False, (
                f"could not verify writable file after run: {exc}"
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
