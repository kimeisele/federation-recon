"""
macOS seatbelt backend for the Execution Core.

Runs a command inside an Apple Seatbelt sandbox using sandbox-exec(1).
Tree kill uses pkill -9 -u to survive setsid+double-fork escapees.

Design invariant: the owner's environment never crosses the isolation
boundary.  env -i guarantees an empty initial environment.
"""

import json
import os
import signal
import subprocess
import time

# ── Paths baked in at import time ──────────────────────────────────────────
_HERE = os.path.dirname(os.path.abspath(__file__))
_CORE = os.path.dirname(_HERE)
_POLICY_PATH = os.path.join(_CORE, "policy.json")
_PROFILE_PATH = os.path.join(_CORE, "profiles", "worker.sb")
_WORKER_USER = "_jcode_worker"

_policy = None


def _load_policy():
    global _policy
    if _policy is None:
        with open(_POLICY_PATH) as f:
            _policy = json.load(f)
    return _policy


# ── Tree kill ──────────────────────────────────────────────────────────────

def kill_all():
    """Kill every process owned by the worker user.

    Uses pkill(1) to send SIGKILL to every process of _WORKER_USER.
    kill(-pgid) alone is insufficient: a child that calls setsid() then
    double-forks creates a grandchild in a new session and process group,
    unreachable via the original pgid.  pkill -9 -u kills by uid; the
    escapee cannot shed its uid on macOS (no user namespaces).
    """
    subprocess.run(
        ["/usr/bin/pkill", "-9", "-u", _WORKER_USER],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


# ── Run ────────────────────────────────────────────────────────────────────

def run(script_path, workspace):
    """Run *script_path* inside the seatbelt sandbox.

    The script executes as the unprivileged _WORKER_USER with an empty
    environment, confined by the SBPL profile at _PROFILE_PATH.  rlimits
    are applied in the pre-exec hook before sudo hands off to sandbox-exec.

    Returns a dict:
        exit_status     — int exit code, or None if killed by signal
        term_signal     — signal number, or None if exited normally
        wall_clock_ms   — elapsed wall-clock time (int, milliseconds)
        timed_out       — True if the wall-clock watchdog fired
        limits_applied  — dict: {rlimit_cpu: bool, rlimit_nproc: bool,
                                rlimit_fsize: bool}
    """
    policy = _load_policy()
    lim = policy["limits"]

    # Build the command line.  env -i clears the owner's environment
    # entirely; the only variable the child sees is PATH.
    cmd = [
        "sudo", "-u", _WORKER_USER,
        "env", "-i",
        "PATH=/usr/bin:/bin",
        "sandbox-exec", "-f", _PROFILE_PATH,
        "-D", "WORKSPACE=" + workspace,
        "/usr/bin/python3", script_path,
    ]

    # Collected inside the preexec_fn (runs in the forked child).
    # Must be a mutable container because the child can't return values.
    limits_applied = {}

    def _preexec():
        import resource

        # RLIMIT_AS is intentionally NOT set — it raises ValueError on macOS
        # (ENOTSUP).  This is why mem_limit lives in unclaimable_capabilities.
        for name, rlim_const, value in [
            ("rlimit_cpu",   resource.RLIMIT_CPU,   lim["rlimit_cpu_seconds"]),
            ("rlimit_nproc", resource.RLIMIT_NPROC, lim["rlimit_nproc"]),
            ("rlimit_fsize", resource.RLIMIT_FSIZE, lim["rlimit_fsize_bytes"]),
        ]:
            try:
                resource.setrlimit(rlim_const, (value, value))
                limits_applied[name] = True
            except Exception:
                limits_applied[name] = False

    wall_start = time.monotonic()
    proc = subprocess.Popen(cmd, preexec_fn=_preexec)

    # ── Wall-clock watchdog ────────────────────────────────────────────
    timed_out = False
    try:
        proc.wait(timeout=lim["wall_clock_seconds"])
    except subprocess.TimeoutExpired:
        timed_out = True
        kill_all()
        # Give the kill a moment to propagate, then force-clean the sudo
        # wrapper (which runs as root and is not reached by pkill -u worker).
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    wall_end = time.monotonic()

    rc = proc.returncode
    exit_status = rc if rc >= 0 else None
    term_signal = -rc if rc < 0 else None

    return {
        "exit_status": exit_status,
        "term_signal": term_signal,
        "wall_clock_ms": int((wall_end - wall_start) * 1000),
        "timed_out": timed_out,
        "limits_applied": limits_applied,
    }
