"""
Payload: fs_confinement — filesystem access checks from inside the sandbox.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports raw check results — does NOT judge.  The host-side canary
decides pass or fail.
"""

import json
import os
import sys


def _try_read_file(path):
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
        return True, f"UNEXPECTED read access: {path} -> {type(e).__name__}: {e}"


def _try_write_file(path, content="canary-write-test"):
    """Attempt to write *content* to *path*.  Returns (succeeded: bool, detail)."""
    try:
        with open(path, "w") as f:
            f.write(content)
        return True, f"wrote {len(content)} bytes to {path}"
    except PermissionError:
        return False, f"PermissionError writing {path}"
    except Exception as e:
        return True, f"UNEXPECTED write access: {path} -> {type(e).__name__}: {e}"


def _try_list_dir(path):
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


ws = sys.argv[1]

checks = {}

# 1. Attempt to read the REAL ~/.config/secrets/env (if HOME is set)
home = os.environ.get("HOME", os.path.expanduser("~"))
if home and home != "/var/empty":
    real_secret = os.path.join(home, ".config", "secrets", "env")
    checks["read_real_secret"] = _try_read_file(real_secret)
else:
    checks["read_real_secret"] = (False, "HOME not set or /var/empty — expected")

# 2. Attempt to read the PLANTED fake secret file (outside workspace)
planted = "/tmp/.jcode_canary_secret_fs"
checks["read_planted_secret"] = _try_read_file(planted)

# 3. Attempt to list $HOME
if home and home != "/var/empty":
    checks["list_home"] = _try_list_dir(home)
else:
    checks["list_home"] = (False, "HOME not set — expected")

# 4. Attempt to list /Library/Keychains
checks["list_keychains"] = _try_list_dir("/Library/Keychains")

# 5. Attempt to list /private/tmp
checks["list_private_tmp"] = _try_list_dir("/private/tmp")

# 6. Attempt to write outside the workspace
outside = os.path.realpath(os.path.join(ws, "..", "outside_canary_test"))
checks["write_outside"] = _try_write_file(outside, "should-fail")

# 7. Attempt to write inside the workspace
inside = os.path.join(ws, "inside_test.txt")
checks["write_inside"] = _try_write_file(inside, "should-succeed")

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(
        {"checks": {name: {"succeeded": ok, "detail": detail} for name, (ok, detail) in checks.items()}},
        f,
    )
