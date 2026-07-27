"""
Fake attacker utilities used by payloads inside the sandbox.

Each function lives here (not in the payload) so that a reader can verify
it does what it claims without the payload's reporting logic getting in
the way.
"""

import os
import signal
import socket
import sys
import time


def try_connect(host, port, timeout=2):
    """Attempt a TCP connect.  Returns (succeeded: bool, detail: str)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        s.close()
        return True, f"connected to {host}:{port}"
    except Exception as e:
        return False, f"{host}:{port} -> {e}"


def try_dns(host, timeout=2):
    """Attempt DNS resolution.  Returns (succeeded: bool, detail: str)."""
    try:
        socket.setdefaulttimeout(timeout)
        addrs = socket.getaddrinfo(host, None)
        ips = sorted(set(a[4][0] for a in addrs))
        return True, f"{host} -> {', '.join(ips)}"
    except Exception as e:
        return False, f"{host} -> {e}"


def try_read_file(path):
    """Attempt to open and read *path*.  Returns (succeeded: bool, detail)."""
    try:
        with open(path, "r") as f:
            content = f.read(256)
        return True, f"read {len(content)} bytes from {path}"
    except PermissionError:
        return False, f"PermissionError reading {path}"
    except FileNotFoundError:
        return False, f"FileNotFoundError: {path}"
    except IsADirectoryError:
        return False, f"IsADirectoryError: {path}"
    except Exception as e:
        # Any unexpected success (e.g. sandbox didn't enforce) is a failure
        # of the canary and must be reported as success=true.
        return True, f"UNEXPECTED read access: {path} -> {type(e).__name__}: {e}"


def try_write_file(path, content="canary-write-test"):
    """Attempt to write *content* to *path*.  Returns (succeeded: bool, detail)."""
    try:
        with open(path, "w") as f:
            f.write(content)
        return True, f"wrote {len(content)} bytes to {path}"
    except PermissionError:
        return False, f"PermissionError writing {path}"
    except Exception as e:
        return True, f"UNEXPECTED write access: {path} -> {type(e).__name__}: {e}"


def try_list_dir(path):
    """Attempt to list *path*.  Returns (succeeded: bool, detail)."""
    try:
        entries = os.listdir(path)
        return True, f"listed {len(entries)} entries in {path}"
    except PermissionError:
        return False, f"PermissionError listing {path}"
    except FileNotFoundError:
        return False, f"FileNotFoundError: {path}"
    except Exception as e:
        return True, f"UNEXPECTED list access: {path} -> {type(e).__name__}: {e}"


def escape_and_sleep(pid_file, sleep_secs=60):
    """Daemonise via setsid + double fork, then sleep.

    The resulting grandchild is in a new session with its own process
    group.  kill(-original_pgid) cannot reach it.  Only a uid-based kill
    (pkill -9 -u) or cgroup freeze/kill can.

    Writes the grandchild PID to *pid_file* so the orchestrator can verify.

    The original process stays alive (polling for a ``die_now`` sentinel
    in the workspace) so that sandbox-exec does not exit.  If the parent
    exits, the kernel tears down the seatbelt sandbox and kills the
    grandchild before the canary can observe it.  When the canary writes
    ``die_now`` to the inner workspace, the grandchild calls os._exit(0)
    — no signal required; the seatbelt profile restricts process-signal
    to self.
    """
    # Block SIGHUP — launchd may signal reparented daemonised processes.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    ws = os.path.dirname(pid_file)
    die_now = os.path.join(ws, "die_now")

    # First fork — parent stays alive, child daemonises.
    pid = os.fork()
    if pid < 0:
        sys.exit(1)
    if pid > 0:
        # Parent: keep sandbox-exec alive so the canary can observe.
        _poll_die_then_sleep(die_now, timeout=300)
        sys.exit(0)

    # Create new session — detaches from the original process group.
    os.setsid()

    # Second fork — middle child stays alive, grandchild daemonises.
    pid = os.fork()
    if pid < 0:
        sys.exit(1)
    if pid > 0:
        _poll_die_then_sleep(die_now, timeout=300)
        sys.exit(0)

    # Grandchild: write PID, then poll for die_now sentinel.
    try:
        with open(pid_file, "w") as f:
            f.write(str(os.getpid()))
    except OSError:
        pass

    deadline = time.time() + sleep_secs
    while time.time() < deadline:
        if os.path.exists(die_now):
            os._exit(0)
        time.sleep(0.5)


def _poll_die_then_sleep(die_now, timeout):
    """Poll die_now briefly; if it appears exit, else sleep."""
    deadline = time.time() + 60
    while time.time() < deadline:
        if os.path.exists(die_now):
            sys.exit(0)
        time.sleep(0.5)
    time.sleep(timeout - 60)
