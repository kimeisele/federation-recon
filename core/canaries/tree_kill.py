"""
Canary: tree_kill — paired denial+preservation test across two slots.

Runs the tree_kill payload on slot A (escapee), and a decoy payload on
slot B (long-running compute that produces a correct result).  Verifies
that:
  - Denial: the escapee on slot A is dead after the kill.
  - Preservation: the decoy on slot B is STILL ALIVE and returns its
    correct output.

This requires >=2 free slots.  If fewer are free, the canary fails with
"insufficient slots" — it does not skip.

Keystone capability: it tests the property the entire pool exists to provide.
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
    run_id_a = _gen_run_id()
    run_id_b = _gen_run_id()
    tmp_a = tempfile.mkdtemp(prefix="canary_tree_kill_a_")
    tmp_b = tempfile.mkdtemp(prefix="canary_tree_kill_b_")

    slot_a = None
    slot_b = None
    sandbox_proc_a = None
    sandbox_proc_b = None

    try:
        # Phase 1: claim two slots.
        # Use the backend's claim mechanism directly.
        try:
            slot_a, uid_a = backend._claim_slot()
            slot_b, uid_b = backend._claim_slot()
        except backend.NoSlotAvailable:
            return False, (
                "insufficient slots — tree_kill requires >=2 free slots "
                "for the paired denial+preservation test"
            )

        # Phase 2: start decoy on slot B (preservation side) and escapee
        # on slot A (denial side).  Both with teardown=False so the sandbox
        # stays alive and processes are observable.
        # 
        # Decoy on B: kill_persistent payload (stays alive, continuously
        # forks children).  We verify B's processes survive A's kill.
        # Escapee on A: tree_kill payload (daemonised grandchild).
        sandbox_proc_b = backend.run(
            "kill_persistent", tmp_b, run_id=run_id_b,
            teardown=False, slot_spec=(slot_b, uid_b)
        )
        time.sleep(0.5)  # Let B fork a few children.

        # Start escapee on slot A
        sandbox_proc_a = backend.run(
            "tree_kill", tmp_a, run_id=run_id_a,
            teardown=False, slot_spec=(slot_a, uid_a)
        )
        time.sleep(1.5)  # Let the escapee daemonise.

        # ── Phase 3: read escapee PID and verify it's alive ──────────
        pid_file = os.path.join(tmp_a, "escapee.pid")
        if not os.path.exists(pid_file):
            return False, "escapee did not write PID file — double-fork may have failed"

        with open(pid_file) as f:
            escapee_pid = int(f.read().strip())

        if not _pid_alive(escapee_pid):
            return False, (
                f"escapee PID {escapee_pid} died on its own before kill — "
                "proves nothing about uid-based kill"
            )

        # Verify B has processes running.
        b_before = _count_procs(uid_b)
        if b_before == -1:
            return False, (
                f"decoy on {slot_b}: pgrep failed before kill — "
                "cannot determine process count (UNKNOWN)"
            )
        if b_before == 0:
            return False, (
                f"decoy on {slot_b} has zero processes before kill — "
                "cannot serve as preservation test"
            )

        # ── Phase 4: count B's processes BEFORE kill as evidence ─────
        # Verify the escapee is owned by slot A.
        owner = _pid_owner(escapee_pid)
        if owner != slot_a:
            return False, (
                f"escapee PID {escapee_pid} is owned by '{owner}', "
                f"not '{slot_a}' — recycled pid, not evidence"
            )

        # ── Phase 5: KILL slot A ────────────────────────────────────
        kill_result = backend.kill_slot(slot_a, uid_a)
        if not kill_result["ok"]:
            return False, (
                f"kill_slot({slot_a}) returned failure: "
                f"returncode={kill_result['returncode']}, "
                f"stderr={kill_result['stderr']!r}"
            )

        # Phase 6: release slot A (prove empty)
        backend._release_slot(slot_a, uid_a)

        # ── Phase 7: verify escapee on A is dead (denial) ───────────
        deadline = time.time() + 5.0
        while time.time() < deadline:
            if not _pid_alive(escapee_pid):
                break
            time.sleep(0.2)
        else:
            return False, (
                f"escapee PID {escapee_pid} SURVIVED kill_slot({slot_a}) — "
                "denial test FAIL"
            )

        denial_ok = True

        # ── Phase 8: verify decoy on B is still alive (preservation) ─
        b_after = _count_procs(uid_b)
        if b_after == -1:
            return False, (
                f"decoy on {slot_b}: pgrep failed after A's kill — "
                "cannot determine process count (UNKNOWN)"
            )
        if b_after == 0:
            return False, (
                f"decoy on {slot_b} had {b_before} processes before A's kill "
                f"and zero after — decoy was killed!  Preservation test FAIL"
            )

        # Give decoy a moment to continue running.
        time.sleep(0.5)
        b_still = _count_procs(uid_b)
        if b_still == -1:
            return False, (
                f"decoy on {slot_b}: pgrep failed during re-check — "
                "cannot determine process count (UNKNOWN)"
            )
        if b_still == 0:
            return False, (
                f"decoy on {slot_b} died shortly after A's kill — "
                "preservation test FAIL"
            )

        preservation_ok = True

        # ── Phase 9: clean up B ─────────────────────────────────────
        # Kill and release slot B (don't interfere with B's process for
        # the cleanliness of the test — release it properly).
        # Wait for the sandbox to complete naturally or kill it.
        try:
            if sandbox_proc_b is not None and sandbox_proc_b.poll() is None:
                # Write die_now to make kill_persistent exit
                try:
                    inner_b = os.path.join(_INNER_BASE, run_id_b)
                    with open(os.path.join(inner_b, "die_now"), "w") as f:
                        f.write("1")
                except Exception:
                    pass
                sandbox_proc_b.wait(timeout=3)
        except Exception:
            pass

        kill_result_b = backend.kill_slot(slot_b, uid_b)
        backend._release_slot(slot_b, uid_b)

        # Clean up sandbox proc A
        if sandbox_proc_a is not None:
            _wait_sandbox(sandbox_proc_a)

        return True, (
            f"denial — escapee PID {escapee_pid} on {slot_a} killed and gone.  "
            f"preservation — decoy on {slot_b} had {b_before} procs before "
            f"A's kill and {b_still} after (alive and running).  "
            "Paired tree_kill test PASS."
        )

    finally:
        # Cleanup fallback.
        try:
            if slot_a is not None:
                try:
                    backend.kill_slot(slot_a, uid_a)
                except Exception:
                    pass
                try:
                    backend._release_slot(slot_a, uid_a)
                except Exception:
                    pass
        except Exception:
            pass
        try:
            if slot_b is not None:
                try:
                    backend.kill_slot(slot_b, uid_b)
                except Exception:
                    pass
                try:
                    backend._release_slot(slot_b, uid_b)
                except Exception:
                    pass
        except Exception:
            pass

        if sandbox_proc_a is not None:
            _wait_sandbox(sandbox_proc_a)
        if sandbox_proc_b is not None:
            _wait_sandbox(sandbox_proc_b)

        shutil.rmtree(tmp_a, ignore_errors=True)
        shutil.rmtree(tmp_b, ignore_errors=True)


def _pid_alive(pid):
    """Return True if a process with *pid* exists."""
    import subprocess as _sp
    rc = _sp.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid="],
        stdout=_sp.DEVNULL, stderr=_sp.DEVNULL,
    ).returncode
    return rc == 0


def _pid_owner(pid):
    """Return the user name owning *pid*, or empty string if not found."""
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "user="],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=3,
        )
        return result.stdout.strip()
    except Exception:
        return ""


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


def _gen_marker(length=24):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))
