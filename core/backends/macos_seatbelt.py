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
import re
import shutil
import stat
import subprocess
import sys
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

# Lockfile for exclusive run access (see run() docstring).
# Uses a dotted name so _sweep_stale_runs() skips it automatically.
# Placed under _RUNS_DIR (root:wheel, drwxr-xr-x) — NOT /tmp — because a
# lock in a world-writable directory hands the worker control over it.
_LOCKFILE_PATH = os.path.join(_RUNS_DIR, ".run_lock")

_policy = None
_swept = False


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
        # fchmod to world-readable so the worker (uid 601) can read its own
        # config.  The run directory is still 0700 at this point so nothing
        # is exposed before staging completes.  An input the worker cannot
        # read is not an input.
        os.fchmod(fd, 0o644)
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
    """Kill every process owned by the worker user with stable-interval looping.

    A single pkill walks the process table non-atomically.  A parent
    considered early can fork a replacement before it is signalled, and
    the child is never visited.  This loop defeats that race: signal,
    then re-enumerate uid-601 processes, until the identity is empty for
    a **stable interval** (two consecutive checks ~250 ms apart with zero
    processes), or a deadline (~10 s) passes.

    Uses the root-owned worker_kill.sh helper via sudo -n -u _jcode_worker.
    Running AS the worker is sufficient: a process may signal processes of
    its own uid.  No root privilege is needed.

    Returns a structured dict:
        ok          — True when uid-601 reached zero within deadline
        returncode  — exit code from the last helper invocation
        stderr      — stderr captured from the last helper invocation
        killed_any  — True if any helper invocation reported rc 0
        surviving   — count of uid-601 processes after deadline (0 on success)

    Raises KillUnavailable if the helper cannot be executed at all.
    """
    if not os.path.exists(_KILL_HELPER_PATH):
        raise KillUnavailable(
            f"kill helper not found: {_KILL_HELPER_PATH}"
        )

    cmd = ["sudo", "-n", "-u", _WORKER_USER, _KILL_HELPER_PATH]
    deadline = time.time() + 10.0
    killed_any = False
    last_rc = None
    last_stderr = ""
    consecutive_zero = 0

    while time.time() < deadline:
        # ── Signal ────────────────────────────────────────────────────
        try:
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
        last_rc = rc
        last_stderr = stderr

        if rc == 0:
            killed_any = True

        # ── Re-enumerate ──────────────────────────────────────────────
        # Count uid-601 processes via pgrep.
        try:
            pgrep_result = subprocess.run(
                ["/usr/bin/pgrep", "-u", _WORKER_USER],
                capture_output=True, text=True, timeout=5,
            )
        except Exception:
            # pgrep itself failed — we cannot know how many processes remain.
            # Fail closed rather than assuming zero.
            return {
                "ok": False,
                "returncode": last_rc,
                "stderr": last_stderr + "pgrep threw an exception — cannot count survivors",
                "killed_any": killed_any,
                "surviving": -1,
            }

        if pgrep_result.returncode == 0:
            surviving = len(pgrep_result.stdout.strip().splitlines())
        elif pgrep_result.returncode == 1:
            # Exit status 1 means "no processes matched" (pgrep convention).
            surviving = 0
        else:
            # Exit status >1 means an error occurred — we do not know whether
            # any processes remain.  Fail closed.
            return {
                "ok": False,
                "returncode": last_rc,
                "stderr": last_stderr + (
                    f"pgrep exited with status {pgrep_result.returncode}: "
                    f"{pgrep_result.stderr.strip()} — cannot count survivors"
                ),
                "killed_any": killed_any,
                "surviving": -1,
            }

        if surviving == 0:
            consecutive_zero += 1
            if consecutive_zero >= 2:
                # Stable interval: two consecutive empty checks.
                return {
                    "ok": True,
                    "returncode": last_rc,
                    "stderr": last_stderr,
                    "killed_any": killed_any,
                    "surviving": 0,
                }
        else:
            consecutive_zero = 0

        time.sleep(0.25)

    # Deadline reached — fail closed.
    return {
        "ok": False,
        "returncode": last_rc,
        "stderr": last_stderr,
        "killed_any": killed_any,
        "surviving": surviving,
    }


# ── Run ────────────────────────────────────────────────────────────────────

def cleanup(run_id):
    """Remove the inner workspace directory for *run_id*.

    Safe to call on non-existent directories or after prior removal.
    Raises OSError (not ignore_errors=True) when the directory cannot
    be removed — a surviving process holding it open is a real failure
    that must not be swallowed.
    """
    path = os.path.join(_RUNS_DIR, run_id)
    if os.path.exists(path):
        shutil.rmtree(path)


def _sweep_stale_runs():
    """Remove all directories under _RUNS_DIR that are not currently locked.

    Called once at startup (via _swept guard in run()).  Skips entries
    starting with '.' — the lockfile (.run_lock) lives under _RUNS_DIR
    and must not be removed.

    Returns the number of stale directories cleaned.  Reports (to stderr)
    directories that could not be removed.
    """
    if not os.path.isdir(_RUNS_DIR):
        return 0
    stale = 0
    for entry in os.listdir(_RUNS_DIR):
        if entry.startswith("."):
            continue  # Skip lockfile and other dotfiles.
        path = os.path.join(_RUNS_DIR, entry)
        if os.path.isdir(path):
            try:
                shutil.rmtree(path)
                stale += 1
            except Exception as exc:
                print(
                    f"[seatbelt] could not remove stale run directory "
                    f"{path}: {exc}",
                    file=sys.stderr,
                )
    return stale


# ── Run ────────────────────────────────────────────────────────────────────

def _verify_runs_dir_secure():
    """Verify _RUNS_DIR is not group- or world-writable.

    A lock in a writable directory is not a lock — the worker (or any
    local process) can delete or replace it.  Raises PermissionError if
    the directory's permissions are too permissive.
    """
    try:
        st = os.stat(_RUNS_DIR)
    except OSError as exc:
        raise PermissionError(
            f"cannot stat runs directory {_RUNS_DIR}: {exc}"
        )
    mode = st.st_mode
    if mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise PermissionError(
            f"runs directory {_RUNS_DIR} has permissions "
            f"{oct(stat.S_IMODE(mode))} — refusing to run because a "
            "writable lock directory defeats exclusive-run enforcement"
        )


def _sweep_at_startup():
    """Call _sweep_stale_runs exactly once per process.

    Uses a module-level guard flag.  Reports the count and any failures
    to stderr.
    """
    global _swept
    if _swept:
        return
    _swept = True
    stale = _sweep_stale_runs()
    if stale:
        print(
            f"[seatbelt] cleaned {stale} stale run "
            f"{'directory' if stale == 1 else 'directories'}",
            file=sys.stderr,
        )


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
    the tree_kill and kill_persistent canaries, which must observe the
    escapee while the sandbox is still running (macOS seatbelt kills child
    processes when sandbox-exec exits).  The caller is responsible for
    waiting on the returned Popen and for calling kill_all().

    **Concurrency note**: kill_all() is uid-wide — pkill -9 -u _jcode_worker
    terminates every process under that uid.  Two concurrent runs would let
    either terminate the other, and a malicious payload could trigger its
    own timeout to kill an innocent concurrent run.  Therefore we acquire an
    **exclusive lock** (O_CREAT|O_EXCL) before launching.  A second
    concurrent run() raises PermissionError.  The lock is released in a
    finally block.

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
    # ── Verify runs directory is secure (not group/world writable) ────
    # A lock in a writable directory is not a lock.  Check before
    # attempting to acquire the exclusive lock.
    _verify_runs_dir_secure()

    # ── Validate run_id FIRST — before any path operation ─────────────
    # This is a security boundary: an attacker-controlled run_id can
    # escape the runs tree via path separators or newline injection.
    if run_id is None:
        run_id = os.path.basename(workspace)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", run_id):
        raise ValueError(
            f"run_id must match [A-Za-z0-9_-]{{1,64}}, got {run_id!r}"
        )

    # ── Exclusive lock ───────────────────────────────────────────────
    # O_CREAT|O_EXCL ensures only one run() at a time.  A second
    # concurrent call raises PermissionError.  This is necessary because
    # kill_all() is uid-wide and cannot distinguish concurrent runs.
    # Stale lockfile recovery: if the lockfile exists but the PID that
    # created it is no longer alive, remove it and try again.
    # Uses os.kill(pid, 0) which works cross-process (unlike waitpid
    # which only works on child PIDs).
    lock_fd = None
    for _attempt in range(2):
        try:
            lock_fd = os.open(
                _LOCKFILE_PATH,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o644,
            )
            os.write(lock_fd, str(os.getpid()).encode())
            # ── One-time startup sweep, UNDER THE LOCK ────────────────
            # This must not run before the lock is held. The sweep removes
            # every non-dotted directory under _RUNS_DIR, including the
            # live workspace of a run in progress in another process. A
            # second launcher would then destroy the first one's workspace
            # and only afterwards discover it cannot have the lock. Holding
            # the lock means no other run is in progress, so everything the
            # sweep finds really is stale.
            _sweep_at_startup()
            break
        except FileExistsError:
            if _attempt == 0:
                # Check if the lockfile is stale.
                try:
                    with open(_LOCKFILE_PATH) as lf:
                        pid_str = lf.read().strip()
                    if pid_str:
                        lock_pid = int(pid_str)
                        if lock_pid == os.getpid():
                            # We already hold the lock — should not happen.
                            raise PermissionError(
                                "lockfile contains our own PID — possible bug"
                            )
                        # Test if the PID is alive via signal 0.
                        # ProcessLookupError (ESRCH) means dead.
                        try:
                            os.kill(lock_pid, 0)
                            # Process still alive — lock is valid.
                        except ProcessLookupError:
                            # PID does not exist — stale lockfile.
                            os.remove(_LOCKFILE_PATH)
                            continue
                        except OSError:
                            # EPERM means process exists but we cannot
                            # signal it — lock is valid, do not remove.
                            pass
                except (ValueError, OSError):
                    try:
                        os.remove(_LOCKFILE_PATH)
                        continue
                    except OSError:
                        pass
            raise PermissionError(
                "a run is already in progress (lockfile exists: "
                f"{_LOCKFILE_PATH}) — refused because kill_all() is uid-wide "
                "and cannot safely handle concurrent runs"
            )
        except OSError as exc:
            raise PermissionError(
                f"could not acquire exclusive run lock: {exc}"
            )

    policy = _load_policy()
    lim = policy["limits"]

    # Per-run directory under the root-owned base.  Created EXCLUSIVELY:
    # a pre-existing directory is an attack (the worker could have
    # planted symlinks inside it).  Mode 0o700 during staging so no
    # other process can see or modify files while they are being copied.
    # Changed to 0o777 after staging so the sandbox can read/write.
    # The base directory (0771 root:wheel) prevents non-wheel users
    # from creating or listing entries under it.
    inner_ws = os.path.join(_RUNS_DIR, run_id)

    # The outer try/finally ensures the exclusive lock is ALWAYS released,
    # even if mkdir or the main work raises.
    try:
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

    finally:
        # ── Cleanup in outer finally — happens on EVERY exit path ────
        # This includes exceptions (PermissionError from mkdir, OSError
        # from ingress copy, etc.), teardown=False return, TimeoutExpired,
        # and normal completion.
        try:
            if os.path.isdir(inner_ws):
                shutil.rmtree(inner_ws)
        except Exception:
            # rmtree failure is a backend issue (e.g. ENOTEMPTY from a
            # surviving process).  Do not swallow with ignore_errors=True.
            pass

        # Release the exclusive lock.
        if lock_fd is not None:
            try:
                os.close(lock_fd)
            except Exception:
                pass
            try:
                os.remove(_LOCKFILE_PATH)
            except Exception:
                pass


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
