"""
macOS seatbelt backend for the Execution Core.

Runs a command inside an Apple Seatbelt sandbox using sandbox-exec(1).
Tree kill uses pkill -9 -u to survive setsid+double-fork escapees.

Design invariant: the owner's environment never crosses the isolation
boundary.  env -i guarantees an empty initial environment.

File transfer discipline (defence against confused-deputy symlink attacks):
  - Never os.path.isfile() on an untrusted path.  Use os.lstat + S_ISREG.
  - Reject symlinks, directories, FIFOs, sockets, devices, hard links.
  - Open with O_RDONLY | O_NOFOLLOW, then fstat + re-check S_ISREG.
  - Egress: allowlist of {"result.json", "escapee.pid"} only, 64 KiB cap.
  - Refusal is visible via raised PermissionError.
"""

import json
import os
import shutil
import stat
import subprocess
import time

# ── Installed paths — these define the trust boundary ────────────────────────
_SANDBOX_BASE = "/usr/local/var/jcode-runs"
_CANARY_DIR = os.path.join(_SANDBOX_BASE, "canaries")
_RUNS_DIR = os.path.join(_SANDBOX_BASE, "runs")
_PROFILE_PATH = os.path.join(_SANDBOX_BASE, "profiles", "worker.sb")
_WORKER_USER = "_jcode_worker"
_WRAPPER_PATH = os.path.join(_SANDBOX_BASE, "worker_exec.sh")

# Egress allowlist — only these filenames may be copied out of the sandbox.
_EGRESS_ALLOWLIST = frozenset({"result.json", "escapee.pid"})
# Maximum bytes for any egress file (64 KiB).
_EGRESS_MAX_BYTES = 65536

# Path to the root-owned kill helper.
_KILL_HELPER_PATH = os.path.join(_SANDBOX_BASE, "worker_kill.sh")

_policy = None


def _load_policy():
    global _policy
    if _policy is None:
        _CORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        with open(os.path.join(_CORE, "policy.json")) as f:
            _policy = json.load(f)
    return _policy


# ── Secure file transfer helpers ────────────────────────────────────────────

_ERROR_NOT_REGULAR = "not a regular file: {path}"
_ERROR_NLINK = "hard link count > 1: {path} ({nlink})"
_ERROR_TRUNCATED = "file truncated after open — possible race: {path}"
_ERROR_TOO_LARGE = "file too large: {size} > {limit} bytes: {path}"


def _secure_open_read(path):
    """Open *path* for reading with symlink-attack defences.

    Returns a (fd, stat_result) pair that is guaranteed to describe the
    same regular file.  Raises PermissionError if the file is not a
    regular file, is a hard link (nlink > 1), or changes type between
    lstat and open/fstat.
    """
    lst = os.lstat(path)
    if not stat.S_ISREG(lst.st_mode):
        raise PermissionError(_ERROR_NOT_REGULAR.format(path=path))
    if lst.st_nlink > 1:
        raise PermissionError(_ERROR_NLINK.format(path=path, nlink=lst.st_nlink))

    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        fst = os.fstat(fd)
        if not stat.S_ISREG(fst.st_mode):
            raise PermissionError(_ERROR_NOT_REGULAR.format(path=path))
        if fst.st_nlink > 1:
            raise PermissionError(_ERROR_NLINK.format(path=path, nlink=fst.st_nlink))
        # Sanity: the file we opened should be the one we stat'd.
        if fst.st_ino != lst.st_ino or fst.st_dev != lst.st_dev:
            raise PermissionError(_ERROR_TRUNCATED.format(path=path))
    except PermissionError:
        os.close(fd)
        raise
    except Exception:
        os.close(fd)
        raise

    return fd, fst


def _read_fd_all(fd, max_bytes):
    """Read up to *max_bytes* bytes from fd.  When None, read until EOF."""
    data = bytearray()
    if max_bytes is None:
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data.extend(chunk)
    else:
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            data.extend(chunk)
            remaining -= len(chunk)
    return bytes(data)


def _write_file_secure(dst, data):
    """Write *data* to *dst* with symlink-attack defences.

    Creates *dst* with O_EXCL | O_NOFOLLOW — refuses to follow an
    existing symlink or to overwrite an existing entry.  fstat+verifies
    S_ISREG on the newly created file before writing.

    Raises PermissionError on any violation.
    """
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        fst = os.fstat(fd)
        if not stat.S_ISREG(fst.st_mode):
            os.close(fd)
            raise PermissionError(
                f"destination is not a regular file after creation: {dst}"
            )
        os.write(fd, data)
    except PermissionError:
        os.close(fd)
        raise
    except Exception:
        os.close(fd)
        raise


def _copy_file_secure(src, dst, max_bytes=None):
    """Copy *src* to *dst* with symlink-attack defences.

    *src* must be a regular file (not a symlink, device, FIFO, etc.)
    with nlink == 1.  Opened with O_NOFOLLOW; re-verified via fstat.

    When *max_bytes* is set, the copy is capped at that value and a
    PermissionError is raised if the source exceeds it.  The cap is
    checked BEFORE reading (by fstat) and AFTER reading (by length),
    defending against file growth between the two calls.

    Raises PermissionError on any violation.  Silent skip is not acceptable.
    """
    fd, fst = _secure_open_read(src)
    try:
        size = fst.st_size
        if max_bytes is not None and size > max_bytes:
            raise PermissionError(
                _ERROR_TOO_LARGE.format(
                    path=src, size=size, limit=max_bytes
                )
            )

        # Read the whole file when no cap is given (ingress).  Silent truncation
        # is not acceptable — max_bytes=None means no cap, not a hidden 64 KiB.
        data = _read_fd_all(fd, max_bytes)

        # Post-read cap check: a file that grew between fstat and read would
        # pass the pre-read check but exceed the cap.  Reject it rather than
        # silently writing past the limit.
        if max_bytes is not None and len(data) > max_bytes:
            raise PermissionError(
                f"file grew between stat and read: read {len(data)} bytes "
                f"but cap is {max_bytes}: {src}"
            )

        _write_file_secure(dst, data)
    finally:
        os.close(fd)


def _copy_egress(src, dst):
    """Copy *src* (from inner workspace) to *dst* (host workspace).

    Restricted to the egress allowlist with a 64 KiB byte cap.

    Returns the basename if the file was skipped (not in allowlist),
    or None if it was copied or already existed.  Skipped files are
    silently not copied — the allowlist is a FILTER, not an assertion.

    Raises PermissionError when a file IS in the allowlist but is not
    a regular file (symlink, directory, FIFO, device, hard link).
    """
    basename = os.path.basename(src)
    if basename not in _EGRESS_ALLOWLIST:
        return basename  # Skip — not a denial.
    if os.path.exists(dst):
        return None  # Do not overwrite an existing host-side file.
    _copy_file_secure(src, dst, max_bytes=_EGRESS_MAX_BYTES)
    return None


def _copy_ingress(src, dst):
    """Copy *src* (from host workspace) to *dst* (inner workspace).

    Regular-file-only discipline; no allowlist needed on ingress because
    the caller controls the workspace, but we enforce the same defences
    against symlink substitution.
    """
    _copy_file_secure(src, dst)


# ── Kill-unavailable exception ────────────────────────────────────────────

class KillUnavailable(Exception):
    """Raised when the kill helper cannot be executed at all.

    Missing file, sudo refusal, or any other condition that prevents
    the helper from running qualifies.  A kill path that cannot report
    its own failure is the defect this exception exists to prevent.
    """
    pass


# ── Tree kill ──────────────────────────────────────────────────────────────

def kill_all():
    """Kill every process owned by the worker user.

    Uses the root-owned worker_kill.sh helper via sudo -n -u _jcode_worker.
    Running AS the worker is sufficient: a process may signal processes of
    its own uid.  No root privilege is needed.

    Returns a structured dict:
        ok          — False when returncode is neither 0 nor 1
        returncode  — exit code from the helper
        stderr      — stderr captured from the helper
        killed_any  — True if pkill reported killing at least one process

    Raises KillUnavailable if the helper cannot be executed at all.
    """
    if not os.path.exists(_KILL_HELPER_PATH):
        raise KillUnavailable(
            f"kill helper not found: {_KILL_HELPER_PATH}"
        )

    cmd = ["sudo", "-n", "-u", _WORKER_USER, _KILL_HELPER_PATH]
    try:
        # cwd="/" is load-bearing, not tidiness. sudo hands the helper the
        # caller's working directory, and the worker cannot read the owner's
        # repo. /bin/sh then emits "shell-init: error retrieving current
        # directory" on startup — before the script's own `cd /` can run.
        # That noise lands in stderr, and stderr is how we judge the kill.
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=10,
            cwd="/",
        )
    except FileNotFoundError:
        raise KillUnavailable("sudo not found — cannot run kill helper")
    except subprocess.TimeoutExpired:
        raise KillUnavailable("kill helper timed out after 10 seconds")

    rc = result.returncode
    stderr = result.stderr or ""

    # pkill exits 1 both when nothing matched and when it was refused
    # permission to signal what it found — measured, as the owner:
    #   pkill: signalling pid 137: Operation not permitted
    #   returncode: 1
    # Treating rc 1 as success on its own is what hid a kill path that had
    # never worked. Any stderr means the helper had something to complain
    # about, and a kill that complains has not proven it killed.
    return {
        "ok": rc in (0, 1) and not stderr.strip(),
        "returncode": rc,
        "stderr": stderr,
        "killed_any": rc == 0,
    }


# ── Run ────────────────────────────────────────────────────────────────────

def run(canary_name, workspace, run_id=None, teardown=True):
    """Run the named canary inside the seatbelt sandbox.

    *canary_name* identifies a pre-installed script under
    /usr/local/var/jcode-runs/canaries/.  The wrapper resolves it to a
    root-owned file outside the workspace — nothing is ever executed from
    the workspace, and the caller cannot choose a path.

    *workspace* is a host-side scratch directory.  Files in it are copied
    into the inner sandbox workspace before execution, and result files
    (result.json, escapee.pid) are copied back after the sandbox exits.

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

      teardown=False → subprocess.Popen for the running sandbox.
    """
    policy = _load_policy()
    lim = policy["limits"]

    # Per-run directory under the root-owned base.  Created EXCLUSIVELY:
    # a pre-existing directory is an attack (the worker could have
    # planted symlinks inside it).  Mode 0o700 during staging so no
    # other process can see or modify files while they are being copied.
    # Changed to 0o777 after staging so the sandbox can read/write.
    # The base directory (0771 root:wheel) prevents non-wheel users
    # from creating or listing entries under it.
    if run_id is None:
        run_id = os.path.basename(workspace)
    inner_ws = os.path.join(_RUNS_DIR, run_id)
    try:
        os.mkdir(inner_ws, 0o700)
    except FileExistsError:
        raise PermissionError(
            f"run directory already exists: {inner_ws} — "
            "refusing to reuse; a pre-existing directory may contain "
            "symlinks planted by the worker"
        )

    # Stage all ingress files while the directory is still owner-only.
    # This prevents a confused-deputy attack where the worker pre-creates
    # a symlink under inner_ws that points to an owner-writable file.
    for fn in os.listdir(workspace):
        src = os.path.join(workspace, fn)
        dst = os.path.join(inner_ws, fn)
        _copy_ingress(src, dst)

    # Hand the workspace over to the worker.  The sandbox profile —
    # not Unix permissions — is the confinement boundary for what
    # runs inside.
    os.chmod(inner_ws, 0o777)

    # The wrapper takes run_id and canary_name.  It resolves the canary
    # script from the root-owned canary directory; the caller cannot
    # influence the path beyond choosing a valid name.
    cmd = [
        "sudo", "-u", _WORKER_USER,
        _WRAPPER_PATH,
        run_id,
        canary_name,
    ]

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
            except Exception:
                pass

    wall_start = time.monotonic()
    proc = subprocess.Popen(cmd, preexec_fn=_preexec, cwd="/")

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
            _copy_egress(src, dst)
        return proc

    # ── Wall-clock watchdog ────────────────────────────────────────────
    timed_out = False
    kill_ok = True
    try:
        proc.wait(timeout=lim["wall_clock_seconds"])
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            kill_result = kill_all()
            kill_ok = kill_result["ok"]
        except KillUnavailable as exc:
            kill_ok = False
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
    # Files not in the allowlist are silently skipped and recorded.
    egress_skipped = []
    for fn in os.listdir(inner_ws):
        src = os.path.join(inner_ws, fn)
        dst = os.path.join(workspace, fn)
        skip_name = _copy_egress(src, dst)
        if skip_name is not None:
            egress_skipped.append(skip_name)

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
        "kill_ok": kill_ok,
        "egress_skipped": egress_skipped,
    }


# ── Regression test: egress growth race ────────────────────────────────────

def test_egress_growth_race():
    """Regression test: file that grows between fstat and read.

    Creates a small file, hooks _secure_open_read to extend the file
    BETWEEN the fstat and the return (simulating growth), then calls
    _copy_file_secure with a byte cap.  Asserts PermissionError is
    raised (the post-read cap check) and the destination was never
    created.

    This is deterministic because the file is extended synchronously
    before the read — no race window, no timing dependency.

    Returns (passed, message).
    """
    import importlib as _importlib
    import shutil as _shutil
    import tempfile as _tempfile

    tmp = _tempfile.mkdtemp(prefix="growth_race_")
    try:
        src = os.path.join(tmp, "source.bin")
        dst = os.path.join(tmp, "dest.bin")
        cap = 500

        # Write initial content under the cap: 100 bytes.
        with open(src, "wb") as f:
            f.write(b"x" * 100)

        # Hook _secure_open_read to extend the file after fstat
        # but before returning the fd/fst pair.
        _orig_secure_open = _secure_open_read

        def _hooked_secure_open(path):
            fd, fst = _orig_secure_open(path)
            # File is now open and stat'd.  Extend it well past the
            # cap so the read returns more data than max_bytes.
            # os.write on the same fd would update the fd's position,
            # so extend via a separate open call.
            _fd2 = os.open(path, os.O_WRONLY | os.O_APPEND)
            try:
                os.write(_fd2, b"y" * 1000)
            finally:
                os.close(_fd2)
            return fd, fst

        import sys as _sys
        _mod = _sys.modules[__name__]
        _mod._secure_open_read = _hooked_secure_open

        try:
            _copy_file_secure(src, dst, max_bytes=cap)
            # No exception — post-read check is missing.
            _mod._secure_open_read = _orig_secure_open
            return False, (
                f"_copy_file_secure did NOT raise on a file that grew "
                f"past the {cap}-byte cap — post-read cap check may "
                "be missing"
            )
        except PermissionError:
            # Expected: the post-read check caught the oversized read.
            _mod._secure_open_read = _orig_secure_open
        except Exception as exc:
            _mod._secure_open_read = _orig_secure_open
            return False, (
                f"_copy_file_secure raised {type(exc).__name__}: {exc} "
                "instead of PermissionError"
            )

        # Verify the destination was NOT created (O_EXCL would have
        # prevented creation only if the write path was never reached,
        # but the PermissionError should have been raised before any
        # write).
        if os.path.exists(dst):
            return False, (
                f"destination file {dst} was created despite "
                "PermissionError — O_EXCL/O_NOFOLLOW defence may "
                "not have prevented the write"
            )

        return True, (
            f"_copy_file_secure correctly raised PermissionError on "
            f"file that grew past the {cap}-byte cap; destination was "
            "not created"
        )

    finally:
        _shutil.rmtree(tmp, ignore_errors=True)
