"""
macOS seatbelt backend for the Execution Core.

Runs a command inside an Apple Seatbelt sandbox using sandbox-exec(1).
Per-run uid pool replaces the singleton lock: slots _jcode_w01.._jcode_w08,
uid 611..618.  Concurrency up to the pool size is **permitted**.

Design invariant: the owner's environment never crosses the isolation
boundary.  env -i guarantees an empty initial environment.

File transfer discipline (defence against confused-deputy symlink attacks):
  - Never os.path.isfile() on an untrusted path.  Use os.lstat + S_ISREG.
  - Reject symlinks, directories, FIFOs, sockets, devices, hard links.
  - Open with O_RDONLY | O_NOFOLLOW, then fstat + re-check S_ISREG.
  - Egress: allowlist of {"result.json", "escapee.pid"} only, 64 KiB cap.
  - Refusal is visible via raised PermissionError.
"""

import hashlib
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
_SLOTS_DIR = os.path.join(_SANDBOX_BASE, "slots")
_PROFILE_PATH = os.path.join(_SANDBOX_BASE, "profiles", "worker.sb")
_WRAPPER_PATH = os.path.join(_SANDBOX_BASE, "worker_exec.sh")
_KILL_SELF_PATH = os.path.join(_SANDBOX_BASE, "worker_kill_self.sh")

# Egress allowlist — only these filenames may be copied out of the sandbox.
_EGRESS_ALLOWLIST = frozenset({"result.json", "escapee.pid", "inside_test.txt"})
# Maximum bytes for any egress file (64 KiB).
_EGRESS_MAX_BYTES = 65536

# Pool definition: 8 slots, uid 611..618.
_SLOT_NAMES = ["_jcode_w01", "_jcode_w02", "_jcode_w03", "_jcode_w04",
               "_jcode_w05", "_jcode_w06", "_jcode_w07", "_jcode_w08"]
_SLOT_UIDS = [611, 612, 613, 614, 615, 616, 617, 618]
_SLOT_MAP = dict(zip(_SLOT_NAMES, _SLOT_UIDS))
_SLOT_REVERSE_MAP = dict(zip(_SLOT_UIDS, _SLOT_NAMES))

_policy = None


def _load_policy():
    global _policy
    if _policy is None:
        _CORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        with open(os.path.join(_CORE, "policy.json")) as f:
            _policy = json.load(f)
    return _policy


# ── Slot-poisoning exception ───────────────────────────────────────────────

class NoSlotAvailable(Exception):
    """Raised when every slot in the pool is claimed or quarantined.

    This is the **admission path** failure: no run starts, no state exists,
    the caller sees a clean refusal.  Moving failures from the kill path to
    the admission path is by design — exhaustion on admission is safe.
    """
    pass


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
        # fchmod to world-readable so the worker (uid 611..618) can read its own
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


# ── Pool status ────────────────────────────────────────────────────────────

def pool_status():
    """Return a dict mapping slot name → status string.

    Status is one of "free", "claimed", or "quarantined".
    """
    if not os.path.isdir(_SLOTS_DIR):
        return {name: "free" for name in _SLOT_NAMES}

    existing = set()
    quarantined = set()
    try:
        for entry in os.listdir(_SLOTS_DIR):
            if "." in entry:
                # Quarantined entries: <slot>.quarantined.<timestamp>
                base = entry.split(".")[0]
                quarantined.add(base)
            else:
                existing.add(entry)
    except OSError:
        pass

    status = {}
    for name in _SLOT_NAMES:
        if name in quarantined:
            status[name] = "quarantined"
        elif name in existing:
            status[name] = "claimed"
        else:
            status[name] = "free"
    return status


# ── Slot allocation ────────────────────────────────────────────────────────

def _claim_slot():
    """Claim a free slot from the pool.

    Allocates by exclusive os.mkdir under _SLOTS_DIR.  After claiming,
    asserts pgrep -u <uid> reports no processes (closes slot-reuse ABA).

    Returns (slot_name, slot_uid).

    Raises NoSlotAvailable if every slot is taken or quarantined.
    """
    # Ensure slots directory exists (root-owned, created during setup).
    if not os.path.isdir(_SLOTS_DIR):
        raise NoSlotAvailable(
            f"slots directory not found: {_SLOTS_DIR} — "
            "run s1 setup to create it"
        )

    status = pool_status()
    for name in _SLOT_NAMES:
        if status[name] != "free":
            continue
        uid = _SLOT_MAP[name]
        claimed = _claim_one(name, uid)
        if claimed:
            return name, uid

    raise NoSlotAvailable(
        "all 8 slots are claimed or quarantined — pool exhausted"
    )


def _claim_one(slot_name, slot_uid):
    """Try to claim *slot_name* (uid *slot_uid*).

    Returns True if the slot was successfully claimed.
    """
    claim_dir = os.path.join(_SLOTS_DIR, slot_name)
    try:
        os.mkdir(claim_dir, 0o700)
    except FileExistsError:
        return False
    except OSError:
        return False

    # After claiming, assert the slot has no surviving processes.
    try:
        result = subprocess.run(
            ["/usr/bin/pgrep", "-u", str(slot_uid)],
            capture_output=True, text=True, timeout=5,
        )
        # pgrep exit 0 = found processes, exit 1 = none found.
        # Any other exit means error.
        if result.returncode == 0:
            # Processes found — previous run left survivors.
            # Kill them and re-verify with a stable double-check.
            pids = result.stdout.strip()
            try:
                kill_result = kill_slot(slot_name, slot_uid)
                if not kill_result["ok"]:
                    _quarantine(slot_name,
                                f"kill_slot returned failure at claim time: "
                                f"returncode={kill_result['returncode']}, "
                                f"stderr={kill_result['stderr']!r}")
                    return False
            except Exception as exc:
                _quarantine(slot_name,
                            f"kill_slot exception at claim time: {exc}")
                return False
            # Stable double-check: poll until zero, then confirm after pause.
            try:
                deadline = time.time() + 10.0
                while time.time() < deadline:
                    recheck = subprocess.run(
                        ["/usr/bin/pgrep", "-u", str(slot_uid)],
                        capture_output=True, text=True, timeout=5,
                    )
                    if recheck.returncode == 0:
                        time.sleep(0.25)
                        continue
                    elif recheck.returncode == 1:
                        break
                    else:
                        _quarantine(slot_name,
                                    f"pgrep exit {recheck.returncode} at claim time "
                                    f"after kill: {recheck.stderr.strip()}")
                        return False
                else:
                    _quarantine(slot_name,
                                "processes still present at claim time after kill")
                    return False

                # First zero observed — confirm stable after pause.
                time.sleep(0.5)
                confirm = subprocess.run(
                    ["/usr/bin/pgrep", "-u", str(slot_uid)],
                    capture_output=True, text=True, timeout=5,
                )
                if confirm.returncode != 1:
                    _quarantine(slot_name,
                                "processes reappeared at claim time after kill")
                    return False
            except Exception as exc:
                _quarantine(slot_name,
                            f"exception during claim-time re-verify: {exc}")
                return False

            # Cleaned successfully.  Log for observability.
            print(
                f"[seatbelt] slot {slot_name} needed cleaning at claim time: "
                f"killed {pids} "
                f"(returncode={kill_result['returncode']})",
                file=sys.stderr,
            )
        elif result.returncode not in (0, 1):
            _quarantine(slot_name,
                        f"pgrep exit {result.returncode} at claim time: "
                        f"{result.stderr.strip()}")
            return False
    except subprocess.TimeoutExpired:
        _quarantine(slot_name, "pgrep timed out at claim time")
        return False
    except FileNotFoundError:
        _quarantine(slot_name, "pgrep not found at claim time")
        return False

    # Write owner pid + timestamp for human diagnosis only.
    # Nothing may make a decision from this file.
    try:
        owner_path = os.path.join(claim_dir, "owner")
        with open(owner_path, "w") as f:
            f.write(f"pid={os.getpid()} timestamp={time.time()}")
    except OSError:
        pass

    return True


def _claim_set_run_id(slot_name, run_id):
    """Record the active run_id in the claim directory for reconcile().

    This creates a bidirectional mapping (slot ↔ run_id) so reconcile()
    can determine which run directories are legitimate (correspond to
    a currently claimed slot) vs orphaned.

    This file IS used for decisions by reconcile().  It is a cross-reference
    between the runs/ and slots/ namespaces, not a liveness inference.
    """
    claim_dir = os.path.join(_SLOTS_DIR, slot_name)
    if not os.path.isdir(claim_dir):
        return
    try:
        rid_path = os.path.join(claim_dir, "run_id")
        with open(rid_path, "w") as f:
            f.write(run_id)
    except OSError:
        pass


def _claim_get_run_id(slot_name):
    """Return the run_id recorded for *slot_name*, or None."""
    rid_path = os.path.join(_SLOTS_DIR, slot_name, "run_id")
    try:
        with open(rid_path) as f:
            return f.read().strip()
    except OSError:
        return None


# ── Quarantine ─────────────────────────────────────────────────────────────

def _quarantine(slot_name, reason):
    """Mark *slot_name* as quarantined.

    Renames slots/<slot> to slots/<slot>.quarantined.<timestamp> if a
    claim directory exists, writes the reason into it.  The slot is not
    reused and no code path may auto-clear it.

    If the rename fails (e.g. concurrent removal), attempts shutil.rmtree
    as a fallback so the slot is not permanently leaked (F4 fix).  All
    failures are logged.
    """
    claim_dir = os.path.join(_SLOTS_DIR, slot_name)
    ts = int(time.time())
    q_dir = os.path.join(_SLOTS_DIR, f"{slot_name}.quarantined.{ts}")
    try:
        os.rename(claim_dir, q_dir)
    except OSError as exc:
        print(
            f"[seatbelt] _quarantine({slot_name}): rename failed: {exc} — "
            "attempting rmtree fallback",
            file=sys.stderr,
        )
        if os.path.isdir(claim_dir):
            try:
                shutil.rmtree(claim_dir)
            except Exception as rmtree_exc:
                print(
                    f"[seatbelt] _quarantine({slot_name}): rmtree fallback "
                    f"also failed: {rmtree_exc} — slot may be permanently leaked",
                    file=sys.stderr,
                )
        return
    try:
        with open(os.path.join(q_dir, "reason"), "w") as f:
            f.write(reason)
    except OSError:
        pass
    print(
        f"[seatbelt] SLOT QUARANTINED: {slot_name} — {reason}",
        file=sys.stderr,
    )


# ── Slot release ───────────────────────────────────────────────────────────

def _release_slot(slot_name, slot_uid, deadline_seconds=10):
    """Release *slot_name* after proving it is empty.

    Calls kill_slot first, then polls pgrep -u <uid> until empty, up to
    ~10 s.  pgrep exit 0 (found) and 1 (none) are the only non-fatal
    outcomes.  Any other exit status, and any exception, means UNKNOWN →
    quarantine.

    Only a slot proven empty is released by removing its claim directory.
    """
    kill_result = kill_slot(slot_name, slot_uid)
    if not kill_result["ok"]:
        print(
            f"[seatbelt] _release_slot({slot_name}): kill_slot returned "
            f"ok=False (returncode={kill_result['returncode']}, "
            f"stderr={kill_result['stderr']!r}) — "
            "polling loop will proceed but may not find an empty slot",
            file=sys.stderr,
        )
    deadline = time.time() + deadline_seconds
    while time.time() < deadline:
        try:
            result = subprocess.run(
                ["/usr/bin/pgrep", "-u", str(slot_uid)],
                capture_output=True, text=True, timeout=5,
            )
        except Exception as exc:
            _quarantine(slot_name, f"exception during release pgrep: {exc}")
            return

        if result.returncode == 0:
            # Processes still found — wait and retry.
            time.sleep(0.25)
            continue
        elif result.returncode == 1:
            # First observation of empty — wait ~0.5 s and confirm again.
            # This catches processes that regenerate microseconds after pgrep,
            # matching the same "reaches zero AND stays zero" property that
            # kill_persistent applies.
            time.sleep(0.5)
            try:
                recheck = subprocess.run(
                    ["/usr/bin/pgrep", "-u", str(slot_uid)],
                    capture_output=True, text=True, timeout=5,
                )
            except Exception as exc:
                _quarantine(slot_name,
                            f"exception during release re-check: {exc}")
                return
            if recheck.returncode == 0:
                # Processes reappeared — keep polling until deadline.
                continue
            elif recheck.returncode != 1:
                # Unknown outcome on re-check → quarantine.
                _quarantine(slot_name,
                            f"pgrep exit {recheck.returncode} during release "
                            f"re-check: {recheck.stderr.strip()}")
                return

            # Confirmed stable zero.  Remove the claim directory.
            claim_dir = os.path.join(_SLOTS_DIR, slot_name)
            try:
                shutil.rmtree(claim_dir)
            except FileNotFoundError:
                pass
            except Exception as exc:
                print(
                    f"[seatbelt] could not remove claim directory "
                    f"{claim_dir}: {exc}",
                    file=sys.stderr,
                )
            return
        else:
            # Any other exit means UNKNOWN → quarantine.
            _quarantine(slot_name,
                        f"pgrep exit {result.returncode} during release: "
                        f"{result.stderr.strip()}")
            return

    # Deadline reached with processes still present → quarantine.
    _quarantine(slot_name, f"processes still present after {deadline_seconds}s deadline")


# ── Kill protocol via per-slot kill-self wrapper ───────────────────────────

def kill_slot(slot_name, slot_uid):
    """Kill every process owned by *slot_uid* via the kill-self wrapper.

    Invokes worker_kill_self.sh AS the slot uid (no uid string crosses the
    sudo boundary).  The wrapper derives its target from id -u.

    Returns a structured dict:
        ok          — True when the helper reported success
        returncode  — exit code from the helper invocation
        stderr      — stderr captured from the helper invocation
    """
    if not os.path.exists(_KILL_SELF_PATH):
        return {
            "ok": False,
            "returncode": -1,
            "stderr": f"kill-self helper not found: {_KILL_SELF_PATH}",
        }

    cmd = ["sudo", "-n", "-u", slot_name, _KILL_SELF_PATH]
    try:
        result = subprocess.run(
            cmd,
            capture_output=True, text=True, timeout=15,
            cwd="/",
        )
    except FileNotFoundError:
        return {
            "ok": False,
            "returncode": -1,
            "stderr": "sudo not found — cannot run kill-self helper",
        }
    except subprocess.TimeoutExpired:
        return {
            "ok": False,
            "returncode": -1,
            "stderr": "kill-self helper timed out after 15 seconds",
        }

    rc = result.returncode
    stderr = result.stderr or ""

    if rc == 0:
        return {"ok": True, "returncode": rc, "stderr": stderr}
    else:
        return {"ok": False, "returncode": rc, "stderr": stderr}


# ── Reconcile ──────────────────────────────────────────────────────────────

# ── Stray process detection ────────────────────────────────────────────────
#
# reconcile() below counts DIRECTORIES. That is all it ever counted, and the
# launcher printed its result as "zero orphans", which reads as a statement
# about processes. On 2026-07-31 a root-owned `sudo` from a killed run survived
# seven hours while exactly that line was printed. See #129.
#
# The blindness is structural. A worker is launched as
#   sudo -u <slot> <wrapper> ...
# and the sudo process itself runs as ROOT until it drops privileges. So it
# cannot appear in `pgrep -u <slot_uid>` — the emptiness proof _release_slot
# uses — and cannot be killed by kill_slot, which kills *as* the slot user.
# Both existing controls are scoped to a uid the survivor does not have.
#
# ── Identify on what the process cannot choose ────────────────────────────
#
# The first version of this function matched `_SANDBOX_BASE in command` and
# excluded live runs by looking for a claimed run id anywhere in the command
# line. An independent red-team took it apart, and the objection was
# structural rather than cosmetic:
#
#   "Substring matching against attacker-influenceable data. […] the builder
#    can read runs/, learn live ids, and mint them into its daemon's argv."
#
# argv belongs to the process. A worker that double-forks and execs by relative
# path has no base path in its command line and was invisible; a worker that
# copies a live run id into its arguments excluded itself. Both were measured
# and both returned zero strays.
#
# So identification now rests on the one attribute a sandboxed process cannot
# rewrite: **the uid the kernel assigned it**. Every descendant of a worker
# runs as that slot's user — that is the property the whole sandbox is built
# on, and the property every capability canary already depends on. Whether a
# process is sandbox-owned is read from the user column; whether it is a stray
# is decided by whether its slot is currently claimed.
#
# argv is still consulted for exactly one case: the root-owned `sudo` parent,
# whose command line WE construct in run() and the worker never touches.
#
# This reports. It does not kill: reaping a root-owned process needs a sudoers
# rule, which is an owner decision (#134). The caller is expected to refuse
# rather than merely print — see launcher.py.

def _slot_of_sudo_parent(command):
    """The slot named by `sudo -u <slot>` in *command*, or None.

    Only meaningful for root-owned processes, whose command line is the one
    run() built. A worker cannot produce this: it has no privilege to become
    root, which is the property the whole sandbox rests on.
    """
    tokens = command.split()
    for i, tok in enumerate(tokens):
        if tok == "-u" and i + 1 < len(tokens):
            candidate = tokens[i + 1]
            if candidate in _SLOT_MAP:
                return candidate
    return None


def find_stray_processes(claimed_slots=(), ps_output=None):
    """Sandbox-owned processes whose slot is not currently claimed.

    Returns (strays, status). Each stray is a dict with pid, user, state,
    command and slot.

    **"unknown" is not "none".** If the process table cannot be read, the
    answer is that we do not know, and the caller must not render that as a
    clean result. The defect this function exists for was a clean-looking line
    printed by a check that had not looked; a version able to print zero
    without looking would reintroduce it in its own body.

    *ps_output* is injectable so tests can drive real fixtures without a
    sandbox host or privileges — the root-owned case cannot be created
    otherwise, since a long-lived root process needs a sudoers rule.
    """
    if ps_output is None:
        try:
            result = subprocess.run(
                ["/bin/ps", "-eo", "pid=,user=,state=,command="],
                capture_output=True, text=True, timeout=10,
            )
        except Exception as exc:
            return [], "unknown: cannot run ps: %s" % exc
        if result.returncode != 0:
            return [], "unknown: ps exit %d: %s" % (
                result.returncode, result.stderr.strip())
        ps_output = result.stdout

    claimed = set(claimed_slots)
    strays = []
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) < 4:
            continue
        pid, user, state, command = parts

        if user in _SLOT_MAP:
            # Owned by a slot uid. The kernel assigned it; nothing the process
            # does to its own argv changes this.
            slot = user
        elif user == "root" and _WRAPPER_PATH in command:
            # The sudo parent. Its command line is ours, not the worker's.
            slot = _slot_of_sudo_parent(command)
            if slot is None:
                # Root, naming the wrapper, but not in the shape run() emits.
                # Unexplained rather than benign — report it and say so.
                strays.append({"pid": pid, "user": user, "state": state,
                               "command": command, "slot": "unattributed"})
                continue
        else:
            continue

        if slot in claimed:
            continue
        strays.append({"pid": pid, "user": user, "state": state,
                       "command": command, "slot": slot})
    return strays, "ok"


def reconcile(ps_output=None):
    """Reconcile runs directory with slot state.

    For every directory under runs/, if its run id does not correspond to a
    currently claimed slot, remove it.

    For every claim directory under slots/, if no live run holds it, and the
    slot is proven empty, release it.  Quarantined slots are never touched.

    Run at launcher startup and after every run.

    Returns dict with counts: {removed_runs, released_slots, errors} plus
    stray_processes and stray_status.

    *ps_output* is forwarded to find_stray_processes so this whole path can be
    exercised by execution rather than by grepping the source of this function
    — which is what the first version of its test did.
    Errors are reported, never swallowed.
    """
    # removed_runs and released_slots count DIRECTORIES. stray_processes
    # counts processes, and stray_status records whether we were able to look
    # at all — a caller that renders "unknown" as "none" reintroduces #129.
    result = {"removed_runs": 0, "released_slots": 0, "errors": 0,
              "stray_processes": [], "stray_status": "not checked"}

    # ── Collect currently claimed slot names and their run_ids ──────
    claimed_slots = set()
    claimed_run_ids = set()
    if os.path.isdir(_SLOTS_DIR):
        try:
            for entry in os.listdir(_SLOTS_DIR):
                if "." not in entry:
                    claimed_slots.add(entry)
                    rid = _claim_get_run_id(entry)
                    if rid:
                        claimed_run_ids.add(rid)
        except OSError as exc:
            print(f"[seatbelt] reconcile: cannot list slots dir: {exc}",
                  file=sys.stderr)
            result["errors"] += 1

    # ── Remove run dirs whose run_id does not correspond to a claimed slot ─
    if os.path.isdir(_RUNS_DIR):
        try:
            for entry in os.listdir(_RUNS_DIR):
                if entry.startswith("."):
                    continue
                path = os.path.join(_RUNS_DIR, entry)
                if not os.path.isdir(path):
                    continue
                # Only remove if the run_id is NOT tracked by a claimed slot.
                if entry in claimed_run_ids:
                    continue
                try:
                    shutil.rmtree(path)
                    result["removed_runs"] += 1
                except Exception as exc:
                    print(
                        f"[seatbelt] reconcile: could not remove run "
                        f"directory {path}: {exc}",
                        file=sys.stderr,
                    )
                    result["errors"] += 1
        except OSError as exc:
            print(f"[seatbelt] reconcile: cannot list runs dir: {exc}",
                  file=sys.stderr)
            result["errors"] += 1

    # ── Release orphaned claim directories ──────────────────────────
    for slot_name in list(claimed_slots):
        if slot_name not in _SLOT_MAP:
            # Unknown slot name — should not happen, but handle gracefully.
            claim_dir = os.path.join(_SLOTS_DIR, slot_name)
            try:
                shutil.rmtree(claim_dir)
                result["released_slots"] += 1
            except Exception as exc:
                print(
                    f"[seatbelt] reconcile: could not remove unknown claim "
                    f"{claim_dir}: {exc}",
                    file=sys.stderr,
                )
                result["errors"] += 1
            continue

        # Grace period (F2 fix): if the claim directory was created within the
        # last few seconds, treat it as live regardless of its mapping.  Between
        # _claim_set_run_id() (which writes run_id) and os.mkdir() (which creates
        # the inner workspace directory), a concurrent reconcile() would see a
        # claimed slot with a run_id whose directory does not yet exist.  Without
        # this grace period, reconcile() would not find the run_id in the runs/
        # listing (it does not exist) and would release the slot — deleting the
        # claim directory — while the run() caller has already started working.
        try:
            claim_dir = os.path.join(_SLOTS_DIR, slot_name)
            ctime = os.stat(claim_dir).st_ctime
            if time.time() - ctime < 5.0:
                # Too young to be confidently orphaned — leave it alone.
                continue
        except OSError:
            # Can't stat — may have been removed by a concurrent caller.
            pass

        uid = _SLOT_MAP[slot_name]
        # Check if the slot is proven empty.
        try:
            pgrep_result = subprocess.run(
                ["/usr/bin/pgrep", "-u", str(uid)],
                capture_output=True, text=True, timeout=5,
            )
        except Exception as exc:
            print(
                f"[seatbelt] reconcile: pgrep failed for {slot_name}: {exc}",
                file=sys.stderr,
            )
            result["errors"] += 1
            continue

        if pgrep_result.returncode == 1:
            # No processes — slot is empty, release it.
            try:
                shutil.rmtree(claim_dir)
                result["released_slots"] += 1
            except Exception as exc:
                print(
                    f"[seatbelt] reconcile: could not release claim "
                    f"{claim_dir}: {exc}",
                    file=sys.stderr,
                )
                result["errors"] += 1

    # The process table, which nothing above looked at.
    #
    # Deliberately re-reads the claim directory instead of reusing the
    # claimed_slots snapshot taken at the top of this function. The red-team's
    # third finding: that snapshot predates the releases this pass performs, so
    # a slot released here would still mask its own root-owned survivor for a
    # whole cycle — one turn of blindness, on exactly the shape of #129.
    live_slots = set()
    if os.path.isdir(_SLOTS_DIR):
        try:
            live_slots = {e for e in os.listdir(_SLOTS_DIR) if "." not in e}
        except OSError as exc:
            print(f"[seatbelt] reconcile: cannot re-list slots dir: {exc}",
                  file=sys.stderr)
            result["errors"] += 1
    strays, status = find_stray_processes(live_slots, ps_output)
    result["stray_processes"] = strays
    result["stray_status"] = status
    return result


# ── Run ────────────────────────────────────────────────────────────────────

def _verify_runs_dir_secure():
    """Verify _RUNS_DIR and _SLOTS_DIR are not group- or world-writable.

    Raises PermissionError if any directory's permissions are too permissive.
    A lock directory anyone can write is not a lock (F3 fix).
    """
    for label, path in [("runs", _RUNS_DIR), ("slots", _SLOTS_DIR)]:
        try:
            st = os.stat(path)
        except OSError as exc:
            raise PermissionError(
                f"cannot stat {label} directory {path}: {exc}"
            )
        mode = st.st_mode
        if mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise PermissionError(
                f"{label} directory {path} has permissions "
                f"{oct(stat.S_IMODE(mode))} — refusing to run because a "
                "writable directory defeats isolation"
            )


def run(canary_name, workspace, run_id=None, teardown=True, slot_spec=None):
    """Run the named canary inside the seatbelt sandbox using a pool slot.

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
    waiting on the returned Popen and for calling kill_slot().

    *slot_spec*: optional (slot_name, slot_uid) tuple.  If omitted, a slot
    is claimed from the pool.  When provided, the caller is responsible for
    releasing the slot (e.g., tree_kill canary that manages two slots).

    Concurrency: up to pool size is **permitted** — no lock, no refusal
    beyond pool exhaustion.

    The script executes as the unprivileged slot uid with an empty
    environment, confined by the SBPL profile.  rlimits are applied in the
    wrapper after the uid switch.

    The wrapper (core/worker_exec.sh) is the ONLY command sudoers permits
    as the slot uid.  It hard-codes the profile path and canary directory;
    the caller cannot substitute either.

    Returns:
      teardown=True → a dict:
        exit_status     — int exit code, or None if killed by signal
        term_signal     — signal number, or None if exited normally
        wall_clock_ms   — elapsed wall-clock time (int, milliseconds)
        timed_out       — True if the wall-clock watchdog fired
        slot_name       — the slot used for this run
        slot_uid        — the slot uid

      teardown=False → subprocess.Popen for the running sandbox.
    """
    # ── Slot allocation ─────────────────────────────────────────────
    if slot_spec is not None:
        slot_name, slot_uid = slot_spec
    else:
        slot_name, slot_uid = _claim_slot()

    # ── Verify runs directory is secure ──────────────────────────────
    _verify_runs_dir_secure()

    # ── Validate run_id FIRST ────────────────────────────────────────
    if run_id is None:
        run_id = os.path.basename(workspace)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", run_id):
        if slot_spec is None:
            _release_slot(slot_name, slot_uid)
        raise ValueError(
            f"run_id must match [A-Za-z0-9_-]{{1,64}}, got {run_id!r}"
        )

    policy = _load_policy()
    lim = policy["limits"]

    # ── Per-run directory ────────────────────────────────────────────
    inner_ws = os.path.join(_RUNS_DIR, run_id)

    try:
        # Record run_id in the claim directory BEFORE creating the inner
        # workspace.  Order matters (F2 fix): a concurrent reconcile() sees
        # the mapping before the run directory exists, so a claim directory
        # never exists without its run_id mapping.  Between this write and
        # os.mkdir below, reconcile() sees a slot claimed with a run_id
        # whose directory does not yet exist — the grace period in reconcile
        # (couple seconds) prevents it from removing the non-existent run
        # directory prematurely.
        _claim_set_run_id(slot_name, run_id)

        try:
            os.mkdir(inner_ws, 0o700)
        except FileExistsError:
            raise PermissionError(
                f"run directory already exists: {inner_ws} — "
                "refusing to reuse; a pre-existing directory may contain "
                "symlinks planted by the worker"
            )

        # Stage all ingress files while the directory is still owner-only.
        for fn in os.listdir(workspace):
            src = os.path.join(workspace, fn)
            dst = os.path.join(inner_ws, fn)
            _copy_ingress(src, dst)

        # Hand the workspace over to the worker.
        os.chmod(inner_ws, 0o777)

        # The wrapper takes run_id and canary_name.
        cmd = [
            "sudo", "-u", slot_name,
            _WRAPPER_PATH,
            run_id,
            canary_name,
        ]

        def _preexec():
            import resource

            # RLIMIT_AS is intentionally NOT set — it raises ValueError on macOS.
            # NPROC is applied inside worker_exec.sh after the uid switch,
            # not in preexec, because preexec still runs as the owner.
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

        # ── teardown=False: return early ─────────────────────────────
        if not teardown:
            time.sleep(1.0)
            for fn in os.listdir(inner_ws):
                src = os.path.join(inner_ws, fn)
                dst = os.path.join(workspace, fn)
                try:
                    _copy_egress(src, dst)
                except PermissionError as exc:
                    print(
                        f"[seatbelt] egress refused (teardown=False): "
                        f"{fn} — {exc}",
                        file=sys.stderr,
                    )
                except Exception as exc:
                    print(
                        f"[seatbelt] egress error (teardown=False): "
                        f"{fn} — {exc}",
                        file=sys.stderr,
                    )
            return proc

        # ── Wall-clock watchdog ──────────────────────────────────────
        timed_out = False
        kill_ok = True
        try:
            proc.wait(timeout=lim["wall_clock_seconds"])
        except subprocess.TimeoutExpired:
            timed_out = True
            kill_result = kill_slot(slot_name, slot_uid)
            kill_ok = kill_result["ok"]
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()

        wall_end = time.monotonic()

        # Copy result files back.
        egress_skipped = []
        egress_refusals = []
        for fn in os.listdir(inner_ws):
            src = os.path.join(inner_ws, fn)
            dst = os.path.join(workspace, fn)
            try:
                skip_name = _copy_egress(src, dst)
                if skip_name is not None:
                    egress_skipped.append(skip_name)
            except PermissionError as exc:
                egress_refusals.append({
                    "filename": fn,
                    "reason": str(exc),
                })
            except Exception as exc:
                egress_refusals.append({
                    "filename": fn,
                    "reason": str(exc),
                })

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
            "egress_refusals": egress_refusals,
            "slot_name": slot_name,
            "slot_uid": slot_uid,
        }

    finally:
        # ── Cleanup ──────────────────────────────────────────────────
        # Remove the inner workspace.
        try:
            if os.path.isdir(inner_ws):
                shutil.rmtree(inner_ws)
        except Exception:
            pass

        # Release the slot only if we auto-claimed it AND teardown=True
        # (the sandbox has finished).  When teardown=False the caller
        # provides slot_spec and manages the slot lifecycle.
        if slot_spec is None and teardown:
            _release_slot(slot_name, slot_uid)


# ── Evidence helpers ──────────────────────────────────────────────────────

def checksum_bytes(data):
    """Return SHA-256 hex digest of *data* bytes."""
    return hashlib.sha256(data).hexdigest()


def checksum_file(path):
    """Return SHA-256 hex digest of file at *path*, or None on error."""
    try:
        with open(path, "rb") as f:
            return checksum_bytes(f.read())
    except Exception:
        return None


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
            _mod._secure_open_read = _orig_secure_open
            return False, (
                f"_copy_file_secure did NOT raise on a file that grew "
                f"past the {cap}-byte cap — post-read cap check may "
                "be missing"
            )
        except PermissionError:
            _mod._secure_open_read = _orig_secure_open
        except Exception as exc:
            _mod._secure_open_read = _orig_secure_open
            return False, (
                f"_copy_file_secure raised {type(exc).__name__}: {exc} "
                "instead of PermissionError"
            )

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
