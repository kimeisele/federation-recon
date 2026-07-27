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

# ── Installed paths — these define the trust boundary ────────────────────────
_SANDBOX_BASE = "/usr/local/var/jcode-runs"
_CANARY_DIR = os.path.join(_SANDBOX_BASE, "canaries")
_RUNS_DIR = os.path.join(_SANDBOX_BASE, "runs")
_PROFILE_PATH = os.path.join(_SANDBOX_BASE, "profiles", "worker.sb")
_WORKER_USER = "_jcode_worker"
_WRAPPER_PATH = os.path.join(_SANDBOX_BASE, "worker_exec.sh")

_policy = None


def _load_policy():
    global _policy
    if _policy is None:
        _CORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        with open(os.path.join(_CORE, "policy.json")) as f:
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

def run(canary_name, workspace, run_id=None, teardown=True):
    """Run the named canary inside the seatbelt sandbox.

    *canary_name* identifies a pre-installed script under
    /usr/local/var/jcode-runs/canaries/.  The wrapper resolves it to a
    root-owned file outside the workspace — nothing is ever executed from
    the workspace, and the caller cannot choose a path.

    *workspace* is a host-side scratch directory.  Files in it (e.g.
    _fake_attacker.py) are copied into the inner sandbox workspace before
    execution, and result files (result.json, escapee.pid) are copied back
    after the sandbox exits.

    *run_id* is an optional explicit run identifier matching
    [A-Za-z0-9_-]{1,64}.  If omitted, os.path.basename(workspace) is used
    — the caller must ensure the basename passes the wrapper's validation.

    *teardown* (default True): when False, the sandbox is started but the
    method returns the subprocess.Popen immediately — without waiting for
    completion or cleaning up the inner workspace.  This exists ONLY for
    the tree_kill canary, which must observe the escapee while the sandbox
    is still running (macOS seatbelt kills child processes when
    sandbox-exec exits).  The caller is responsible for waiting on the
    returned Popen and for calling kill_all().

    The script executes as the unprivileged _WORKER_USER with an empty
    environment, confined by the SBPL profile.  rlimits are applied in the
    pre-exec hook before sudo hands off to the wrapper.

    The wrapper (core/worker_exec.sh) is the ONLY command sudoers permits
    as _jcode_worker.  It hard-codes the profile path and canary directory;
    the caller cannot substitute either.

    Returns:
      teardown=True → a dict:
        exit_status     — int exit code, or None if killed by signal
        term_signal     — signal number, or None if exited normally
        wall_clock_ms   — elapsed wall-clock time (int, milliseconds)
        timed_out       — True if the wall-clock watchdog fired
        limits_applied  — dict: {rlimit_cpu: bool, rlimit_nproc: bool,
                                rlimit_fsize: bool}

      teardown=False → subprocess.Popen for the running sandbox.
    """
    policy = _load_policy()
    lim = policy["limits"]

    # Per-run directory under the root-owned base.  Mode 0777 so the
    # worker can read and write its own workspace.  The sandbox profile
    # — not Unix permissions — is the confinement boundary for what
    # runs inside.  The base directory (0771 root:wheel) prevents
    # non-wheel users from creating or listing entries under it.
    if run_id is None:
        run_id = os.path.basename(workspace)
    inner_ws = os.path.join(_RUNS_DIR, run_id)
    os.makedirs(inner_ws, exist_ok=True)
    os.chmod(inner_ws, 0o777)

    # Copy caller's workspace files (e.g. _fake_attacker.py) into the
    # inner workspace that the sandbox will confine.  The canary script
    # itself is NOT written here — it runs from the root-owned canary dir.
    for fn in os.listdir(workspace):
        src = os.path.join(workspace, fn)
        dst = os.path.join(inner_ws, fn)
        if os.path.isfile(src):
            shutil.copy(src, dst)

    # The wrapper takes run_id and canary_name.  It resolves the canary
    # script from the root-owned canary directory; the caller cannot
    # influence the path beyond choosing a valid name.
    cmd = [
        "sudo", "-u", _WORKER_USER,
        _WRAPPER_PATH,
        run_id,
        canary_name,
    ]

    # Collected inside the preexec_fn (runs in the forked child).
    # Must be a mutable container because the child can't return values.
    limits_applied = {}

    def _preexec():
        import resource

        # RLIMIT_AS is intentionally NOT set — it raises ValueError on macOS
        # RLIMIT_NPROC is NOT set here either: on macOS it counts processes per
        # REAL UID, and preexec still runs as the owner, who has hundreds. The
        # worker's process limit is applied inside worker_exec.sh, after sudo
        # has switched uid — measured: setting it here makes sudo fail to fork.
        # (ENOTSUP).  This is why mem_limit lives in unclaimable_capabilities.
        for name, rlim_const, value in [
            ("rlimit_cpu",   resource.RLIMIT_CPU,   lim["rlimit_cpu_seconds"]),
            ("rlimit_fsize", resource.RLIMIT_FSIZE, lim["rlimit_fsize_bytes"]),
        ]:
            try:
                resource.setrlimit(rlim_const, (value, value))
                limits_applied[name] = True
            except Exception:
                limits_applied[name] = False

    wall_start = time.monotonic()
    proc = subprocess.Popen(cmd, preexec_fn=_preexec)

    # ── teardown=False: return early so the tree_kill canary can observe ──
    # the escapee while the sandbox is still running.  macOS seatbelt kills
    # child processes when sandbox-exec exits; if we wait for completion
    # the escapee is already dead and we cannot prove kill_all works.
    if not teardown:
        # Let the payload daemonise and write escapee.pid.
        time.sleep(1.0)
        # Copy any result files back so the caller can read escapee.pid.
        for fn in os.listdir(inner_ws):
            src = os.path.join(inner_ws, fn)
            dst = os.path.join(workspace, fn)
            if os.path.isfile(src) and not os.path.exists(dst):
                shutil.copy(src, dst)
        return proc

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
