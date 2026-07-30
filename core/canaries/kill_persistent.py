"""
Canary: kill_persistent — verifies per-slot kill reaches zero against
churning regeneration.

Runs the kill_persistent payload inside the sandbox on a claimed slot,
which creates a churning process population with ~30 short-lived PIDs
and continuous turnover.  The canary:

1. Samples `pgrep -u <slot>` twice ~0.3 s apart, converts each to a
   set of PIDs, and requires that the second set contains PIDs absent
   from the first — new PIDs appearing is regeneration.  A static or
   saturated population shows no new PIDs and the canary FAILs.
2. Calls backend.kill_slot() once.
3. Verifies zero processes, and still zero on a re-check.
4. Reports both sample sizes, the count of new PIDs, and final counts
   so a reader can distinguish saturation from stasis.

This must go red if kill_slot is reverted to a single pkill, because a
single pkill walks the process table non-atomically and will miss
children that fork between the table walk and signal delivery.  The
payload churns fast enough that only the STOP-then-KILL protocol can
clear the slot.
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

        # Phase 2: spawn the churning payload inside the sandbox without
        # waiting for completion.  teardown=False keeps sandbox-exec alive.
        sandbox_proc = backend.run(
            "kill_persistent", tmp, run_id=run_id,
            teardown=False, slot_spec=(slot_name, slot_uid)
        )

        # Give the payload time to build a steady population (~30 PIDs).
        time.sleep(2.0)

        # Phase 3a: first pre-kill sample — collect PID SET.
        pids1 = _get_pids(slot_uid)
        if pids1 is None:
            return False, (
                "pgrep failed (sample 1) before kill_slot — "
                "cannot determine process PIDs (UNKNOWN)"
            )
        n1 = len(pids1)
        if n1 == 0:
            return False, (
                "zero slot processes before kill_slot — payload may not have "
                "forked anything"
            )

        # Phase 3b: second pre-kill sample ~0.3 s later — collect PID SET.
        time.sleep(0.3)
        pids2 = _get_pids(slot_uid)
        if pids2 is None:
            return False, (
                "pgrep failed (sample 2) before kill_slot — "
                "cannot determine process PIDs (UNKNOWN)"
            )
        n2 = len(pids2)
        if n2 == 0:
            return False, (
                "zero slot processes in sample 2 before kill_slot — "
                "all processes exited, cannot test regeneration"
            )

        # Compare PID sets: new PIDs in the second sample = regeneration.
        new_pids = pids2 - pids1
        n_new = len(new_pids)

        if n_new == 0:
            return False, (
                f"payload is not regenerating — no new PIDs appeared across "
                f"two samples 0.3 s apart (s1={n1}, s2={n2}, new={n_new}).  "
                f"A static or saturated population indicates the payload is "
                f"not adversarial enough; only the STOP-then-KILL protocol "
                f"can clear a churning population."
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
            f"kill_slot reduced regenerating processes to zero on "
            f"{released_slot}.  "
            f"Pre-kill PID turnover confirmed: s1={n1}, s2={n2}, "
            f"new PIDs={n_new}.  "
            f"Kill rc={kill_result['returncode']}, "
            f"final count=0 (stable)."
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


def _get_pids(uid):
    """Return a set of PIDs owned by *uid*.

    Returns a set of ints on success (possibly empty).  Returns None if
    pgrep failed with an error (exit status > 1).
    """
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", str(uid)],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=5,
    )
    if result.returncode == 0:
        raw = result.stdout.strip()
        if not raw:
            return set()
        return {int(line.strip()) for line in raw.splitlines() if line.strip()}
    if result.returncode == 1:
        return set()  # No processes — known empty.
    return None  # Error — unknown.


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
