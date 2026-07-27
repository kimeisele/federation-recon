"""
macOS seatbelt backend for the Execution Core.

Runs a command inside an Apple Seatbelt sandbox using sandbox-exec(1).
Tree kill uses pkill -9 -u to survive setsid+double-fork escapees.

Design invariant: the owner's environment never crosses the isolation
boundary.  env -i guarantees an empty initial environment.
"""

import json
import os
import shutil
import subprocess
import time

# ── Paths baked in at import time ──────────────────────────────────────────
_HERE = os.path.dirname(os.path.abspath(__file__))
_CORE = os.path.dirname(_HERE)
_POLICY_PATH = os.path.join(_CORE, "policy.json")
_PROFILE_PATH = os.path.join(_CORE, "profiles", "worker.sb")
_WORKER_USER = "_jcode_worker"
_WRAPPER_PATH = os.path.join(_CORE, "worker_exec.sh")
_SANDBOX_BASE = "/tmp/jcode_sandbox"

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
    are applied in the pre-exec hook before sudo hands off to the wrapper.

    The wrapper (core/worker_exec.sh) is the ONLY command sudoers permits
    as _jcode_worker.  It hard-codes the profile path and computes the
    workspace from a validated run-id — the caller cannot substitute either.

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

    # The wrapper computes its workspace as _SANDBOX_BASE/<run-id>.
    # Use the caller's workspace basename as the run-id so the wrapper
    # and Python agree on where files live.
    run_id = os.path.basename(workspace)
    inner_ws = os.path.join(_SANDBOX_BASE, run_id)

    # Copy caller's workspace files into the inner workspace that the
    # wrapper will confine.  The wrapper always runs canary.py, so rename
    # the caller's script if it has a different basename.
    os.makedirs(inner_ws, exist_ok=True)
    os.chmod(inner_ws, 0o777)
    for fn in os.listdir(workspace):
        src = os.path.join(workspace, fn)
        dst = os.path.join(inner_ws, fn)
        if os.path.isfile(src):
            shutil.copy(src, dst)
    script_basename = os.path.basename(script_path)
    if script_basename != "canary.py":
        shutil.copy(os.path.join(inner_ws, script_basename),
                    os.path.join(inner_ws, "canary.py"))

    # Build the command line.  The wrapper handles env -i, the profile,
    # and the workspace — the caller only supplies a validated run-id.
    cmd = [
        "sudo", "-u", _WORKER_USER,
        _WRAPPER_PATH,
        run_id,
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

    # Copy any result files the sandboxed script wrote back to the
    # caller's workspace (e.g. result.json, escapee.pid).
    for fn in os.listdir(inner_ws):
        src = os.path.join(inner_ws, fn)
        dst = os.path.join(workspace, fn)
        if os.path.isfile(src) and not os.path.exists(dst):
            shutil.copy(src, dst)

    # Clean up the inner workspace.
    shutil.rmtree(inner_ws, ignore_errors=True)

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
