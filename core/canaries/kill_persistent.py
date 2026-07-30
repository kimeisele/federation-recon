"""
Canary: kill_persistent — verifies kill_all reaches zero against regeneration.

Runs the kill_persistent payload inside the sandbox, which continuously
forks replacement children (each child immediately forks and exits, so
the tree regenerates).  The canary calls backend.kill_all() once and
PASSes only if uid-601 reaches **zero processes and stays zero** across
a re-check.

This must go red if kill_all is reverted to a single pkill, because a
single pkill walks the process table non-atomically and will miss children
that fork between the table walk and signal delivery.
"""

import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_INNER_BASE = "/usr/local/var/jcode-runs/runs"
_WORKER_USER = "_jcode_worker"


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_kill_persistent_")

    sandbox_proc = None
    try:
        # Phase 1: spawn the regenerating payload inside the sandbox without
        # waiting for completion.  teardown=False keeps sandbox-exec alive
        # so the kernel does not tear down the seatbelt sandbox and kill
        # the process tree before we can test kill_all.
        sandbox_proc = backend.run("kill_persistent", tmp, run_id=run_id, teardown=False)

        # Give the payload time to fork several generations.
        time.sleep(2.0)

        # Phase 2: verify that the worker user has processes running.
        # If there are zero, the payload forked nothing and the test is invalid.
        initial_count = _count_worker_procs()
        if initial_count == 0:
            return False, (
                "zero worker processes before kill_all — payload may not have "
                "forked anything"
            )

        # Phase 3: call backend.kill_all().  This is the actual test.
        kill_result = backend.kill_all()
        if not kill_result["ok"]:
            return False, (
                f"kill_all failed: ok={kill_result['ok']}, "
                f"surviving={kill_result.get('surviving', '?')} processes, "
                f"returncode={kill_result['returncode']}, "
                f"stderr={kill_result['stderr']!r}"
            )

        # Phase 4: verify zero processes and STAYS zero across a re-check.
        # A single pkill could temporarily reduce the count but miss a
        # child that forked during the table walk.
        if kill_result.get("surviving", -1) != 0:
            return False, (
                f"kill_all reported ok=True but surviving={kill_result['surviving']} "
                "processes — expected 0"
            )

        # Re-check after a brief pause to catch regeneration.
        time.sleep(0.5)
        final_count = _count_worker_procs()
        if final_count != 0:
            return False, (
                f"after kill_all completed, {final_count} process(es) reappeared — "
                "the process tree regenerated after the stable-interval check"
            )

        return True, (
            f"kill_all reduced {initial_count} regenerating processes to zero "
            "(stable interval confirmed, no regeneration)"
        )

    finally:
        # Cleanup fallback.
        try:
            inner_ws = os.path.join(_INNER_BASE, run_id)
            with open(os.path.join(inner_ws, "die_now"), "w") as f:
                f.write("1")
        except Exception:
            pass
        try:
            backend.kill_all()
        except backend.KillUnavailable:
            pass
        if sandbox_proc is not None:
            _wait_sandbox(sandbox_proc)
        # Clean up the inner workspace left by teardown=False.
        try:
            backend.cleanup(run_id)
        except Exception:
            pass
        shutil.rmtree(tmp, ignore_errors=True)


def _count_worker_procs():
    """Return the number of processes owned by the worker user."""
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", _WORKER_USER],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=5,
    )
    if result.returncode == 0:
        return len(result.stdout.strip().splitlines())
    return 0


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
