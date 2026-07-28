"""
Canary: pid_limit — host-side orchestrator.

Runs the pid_limit payload inside the sandbox and judges the result.
The payload reports the fork count reached before the rlimit stopped it
and the errno.

Must hold: the fork bomb is stopped by RLIMIT_NPROC (ulimit -u 64 from
worker_exec.sh) with EAGAIN.  The canary FAILs if the payload did not
hit the resource limit, produced no result, or left processes alive.
"""

import errno
import json
import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_WORKER_USER = "_jcode_worker"


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_pid_limit_")

    try:
        backend.run("pid_limit", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        fork_count = data.get("fork_count")
        if fork_count is None:
            return False, "result.json missing fork_count"

        if fork_count == 0:
            return False, (
                f"fork bomb reported 0 children — "
                "payload could not fork at all, proves nothing about rlimit"
            )

        if fork_count > 100:
            return False, (
                f"fork bomb reached {fork_count} concurrent children — "
                "rlimit may not have applied"
            )

        # Must have hit a resource error.
        if "errno" not in data:
            return False, "result.json missing errno — no resource error recorded"

        err = data["errno"]
        if err != errno.EAGAIN:
            return False, (
                f"payload stopped with errno {err} ({data.get('strerror', '?')}) — "
                f"expected EAGAIN ({errno.EAGAIN}), got a different errno. "
                "The fork bomb was not stopped by RLIMIT_NPROC."
            )

        # After measurement, call kill_all and poll for zero worker processes.
        # SIGKILL delivery and reaping are asynchronous; poll up to ~10 s,
        # checking every 0.25 s.  Zero is the criterion.
        kill_result = backend.kill_all()
        if not kill_result["ok"]:
            return False, (
                f"kill_all failed: returncode={kill_result['returncode']}, "
                f"stderr={kill_result['stderr']!r}"
            )

        deadline = time.time() + 10.0
        while time.time() < deadline:
            leftover = _count_worker_procs()
            if leftover == 0:
                break
            time.sleep(0.25)
        else:
            return False, (
                f"after kill_all, {leftover} process(es) still running "
                f"under uid '{_WORKER_USER}'"
            )

        return True, (
            f"fork bomb stopped after {fork_count} concurrent children "
            f"with EAGAIN (rlimit enforced); no leftover processes"
        )

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _count_worker_procs():
    """Return the number of processes owned by the worker user."""
    result = subprocess.run(
        ["/usr/bin/pgrep", "-u", _WORKER_USER],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, timeout=5,
    )
    # pgrep exits 0 when matches found, 1 when none.
    if result.returncode == 0:
        return len(result.stdout.strip().splitlines())
    return 0


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
