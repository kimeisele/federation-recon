"""
Canary: pid_limit — host-side orchestrator.

Runs the pid_limit payload inside the sandbox and judges the result.
The payload reports the fork count reached before the rlimit stopped it,
the errno, and the measured rlimit values.

Must hold: the fork bomb is stopped by RLIMIT_NPROC (ulimit -u 64 from
worker_exec.sh) with EAGAIN.  The canary FAILs if:
  - The payload did not hit the resource limit,
  - The measured rlimit soft limit does NOT equal the policy value,
  - The fork count is not plausibly near the rlimit (not merely under 100),
  - The baseline (zero worker processes) is not clean before launch,
  - Or the payload produced no result or left processes alive.
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
_POLICY_NPROC = 64  # Must match policy.json limits.rlimit_nproc


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_pid_limit_")

    try:
        # Phase 0: assert a zero-worker baseline before launching.
        # If uid 601 is not empty, any fork limit measured may be the
        # global per-uid ceiling being exhausted by stale processes,
        # not our RLIMIT_NPROC.
        baseline = _count_worker_procs()
        if baseline != 0:
            return False, (
                f"baseline not clean: {baseline} worker process(es) running "
                f"before launch — cannot distinguish rlimit from uid exhaustion"
            )

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

        # Assert the rlimit soft limit matches policy.
        measured_soft = data.get("rlimit_nproc_soft")
        if measured_soft is None:
            return False, "result.json missing rlimit_nproc_soft"

        if measured_soft != _POLICY_NPROC:
            return False, (
                f"measured RLIMIT_NPROC soft limit is {measured_soft}, "
                f"but policy expects {_POLICY_NPROC} — the limit was not applied"
            )

        # Assert fork_count is plausibly near the rlimit.
        # The fork bomb starts from 1 (the parent) and counts children that
        # succeed.  With rlimit 64, the bomb should reach ~63 forks (the
        # parent + 63 children = 64 processes total).  Allow some slack for
        # the sandbox overhead (e.g. sandbox-exec, sudo, sh).
        # A fork_count under ~50 would mean something else blocked it first.
        plausible_min = max(1, _POLICY_NPROC // 2)
        if fork_count < plausible_min:
            return False, (
                f"fork_count {fork_count} is below plausible minimum "
                f"{plausible_min} for rlimit {_POLICY_NPROC} — "
                "the bomb was stopped by something other than RLIMIT_NPROC"
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
            f"RLIMIT_NPROC verified: soft={measured_soft} matches policy; "
            f"fork bomb stopped after {fork_count} concurrent children "
            f"with EAGAIN; zero-worker baseline confirmed"
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
