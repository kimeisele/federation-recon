"""
Canary: kill_persistent — verifies per-slot kill reaches zero against regeneration.

Runs the kill_persistent payload inside the sandbox on a claimed slot, which
continuously forks replacement children (each child immediately forks and exits,
so the tree regenerates).  The canary calls backend.kill_slot() once and
PASSes only if the slot reaches **zero processes and stays zero** across a
re-check.

This must go red if kill_slot is reverted to a single pkill, because a
single pkill walks the process table non-atomically and will miss children
that fork between the table walk and signal delivery.
"""

import hashlib
import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_INNER_BASE = "/usr/local/var/jcode-runs/runs"


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_kill_persistent_")

    slot_name = None
    slot_uid = None
    sandbox_proc = None

    try:
        # Phase 1: claim a slot.
        try:
            slot_name, slot_uid = backend._claim_slot()
        except backend.NoSlotAvailable:
            return False, "insufficient slots — kill_persistent requires >=1 free slot"

        # Phase 2: spawn the regenerating payload inside the sandbox without
        # waiting for completion.  teardown=False keeps sandbox-exec alive.
        sandbox_proc = backend.run(
            "kill_persistent", tmp, run_id=run_id,
            teardown=False, slot_spec=(slot_name, slot_uid)
        )

        # Give the payload time to fork several generations.
        time.sleep(2.0)

        # Phase 3: verify that the slot has processes running.
        initial_count = _count_procs(slot_uid)
        if initial_count == -1:
            return False, (
                "pgrep failed before kill_slot — "
                "cannot determine process count (UNKNOWN)"
            )
        if initial_count == 0:
            return False, (
                "zero slot processes before kill_slot — payload may not have "
                "forked anything"
            )

        # Phase 4: call backend.kill_slot().  This is the actual test.
        kill_result = backend.kill_slot(slot_name, slot_uid)
        if not kill_result["ok"]:
            return False, (
                f"kill_slot failed: ok={kill_result['ok']}, "
                f"returncode={kill_result['returncode']}, "
                f"stderr={kill_result['stderr']!r}"
            )

        # Phase 5: verify zero processes and STAYS zero across a re-check.
        deadline = time.time() + 10.0
        while time.time() < deadline:
            leftover = _count_procs(slot_uid)
            if leftover == -1:
                return False, (
                    f"pgrep failed after kill_slot — "
                    "cannot determine process count (UNKNOWN)"
                )
            if leftover == 0:
                break
            time.sleep(0.25)
        else:
            return False, (
                f"after kill_slot, {leftover} process(es) still running "
                f"under slot '{slot_name}' (uid {slot_uid})"
            )

        # Re-check after a brief pause to catch regeneration.
        time.sleep(0.5)
        final_count = _count_procs(slot_uid)
        if final_count == -1:
            return False, (
                f"pgrep failed during re-check — "
                "cannot determine process count (UNKNOWN)"
            )
        if final_count != 0:
            return False, (
                f"after kill_slot completed, {final_count} process(es) "
                f"reappeared — the process tree regenerated after the kill"
            )

        # Phase 6: release the slot (prove empty).
        released_slot = slot_name
        backend._release_slot(slot_name, slot_uid)
        slot_name = None  # Prevent double-release in finally.

        return True, (
            f"kill_slot reduced {initial_count} regenerating processes "
            f"to zero on {released_slot} (stable interval confirmed, "
            f"no regeneration).  Evidence: initial={initial_count}, "
            f"kill_rc={kill_result['returncode']}"
        )

    finally:
        if sandbox_proc is not None:
            _wait_sandbox(sandbox_proc)
        if slot_name is not None:
            try:
                # Try to release the slot, quarantine on failure.
                backend._release_slot(slot_name, slot_uid)
            except Exception:
                pass
        shutil.rmtree(tmp, ignore_errors=True)


def _count_procs(uid):
    """Return the number of processes owned by *uid*.

    Returns an int on success (0 or more).  Returns -1 if pgrep failed
    with an error (exit status > 1) — the caller MUST treat -1 as UNKNOWN
    and cannot assume zero.
    """
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(uid)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=5,
    )
    if result.returncode == 0:
        return len(result.stdout.strip().splitlines())
    if result.returncode == 1:
        return 0  # No processes — known empty.
    return -1  # Error — unknown.


def _wait_sandbox(proc):
    """Wait for the sandbox process to finish, forcefully if needed."""
    if proc is None:
        return
    if proc.poll() is not None:
        return
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
