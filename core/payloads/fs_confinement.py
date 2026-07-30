"""
Payload: fs_confinement — filesystem access checks from inside the sandbox.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Reports raw check results as three-outcome ("allowed"|"blocked"|"unavailable").
Does NOT judge — the host-side canary decides pass or fail.

The write_outside check targets a world-writable file planted by the
canary so that only Seatbelt (not Unix DAC) can block the write.
The path is passed via config.json — the payload must not discover it.
"""

import json
import os
import sys


def _try_read_file(path):
    """Attempt to open and read *path*.

    Returns {"outcome": "allowed"|"blocked", "detail": str}.
    """
    try:
        with open(path, "r") as f:
            content = f.read(256)
        return {"outcome": "allowed", "detail": f"read {len(content)} bytes from {path}"}
    except PermissionError:
        return {"outcome": "blocked", "detail": f"PermissionError reading {path}"}
    except FileNotFoundError:
        return {"outcome": "unavailable", "detail": f"FileNotFoundError: {path} — target absent, cannot assess"}
    except IsADirectoryError:
        return {"outcome": "blocked", "detail": f"IsADirectoryError: {path}"}
    except Exception as e:
        return {"outcome": "allowed", "detail": f"UNEXPECTED read access: {path} -> {type(e).__name__}: {e}"}


def _try_write_file(path, content="canary-write-test"):
    """Attempt to write *content* to *path*.

    Returns {"outcome": "allowed"|"blocked", "detail": str}.
    """
    try:
        with open(path, "w") as f:
            f.write(content)
        return {"outcome": "allowed", "detail": f"wrote {len(content)} bytes to {path}"}
    except PermissionError:
        return {"outcome": "blocked", "detail": f"PermissionError writing {path}"}
    except Exception as e:
        return {"outcome": "allowed", "detail": f"UNEXPECTED write access: {path} -> {type(e).__name__}: {e}"}


def _try_list_dir(path):
    """Attempt to list *path*.

    Returns {"outcome": "allowed"|"blocked", "detail": str}.
    """
    try:
        entries = os.listdir(path)
        return {"outcome": "allowed", "detail": f"listed {len(entries)} entries in {path}"}
    except PermissionError:
        return {"outcome": "blocked", "detail": f"PermissionError listing {path}"}
    except FileNotFoundError:
        return {"outcome": "unavailable", "detail": f"FileNotFoundError: {path} — target absent, cannot assess"}
    except Exception as e:
        return {"outcome": "allowed", "detail": f"UNEXPECTED list access: {path} -> {type(e).__name__}: {e}"}


ws = sys.argv[1]

# Read config (written by host-side canary).
config_path = os.path.join(ws, "config.json")
writable_target = None
write_marker = None
config_err = None
if os.path.exists(config_path):
    try:
        with open(config_path) as f:
            config = json.load(f)
        writable_target = config.get("writable_path")
        write_marker = config.get("write_marker", "should-succeed")
    except (OSError, json.JSONDecodeError) as e:
        config_err = str(e)

checks = {}

# 1. Attempt to read /etc/hosts (exists on every macOS, should be blocked by sandbox)
checks["read_real_secret"] = _try_read_file("/etc/hosts")

# 2. Attempt to read the PLANTED fake secret file (outside workspace)
planted = "/tmp/.jcode_canary_secret_fs"
checks["read_planted_secret"] = _try_read_file(planted)

# 3. Attempt to list /Users (should be blocked by sandbox)
checks["list_home"] = _try_list_dir("/Users")

# 4. Attempt to list /Library/Keychains
checks["list_keychains"] = _try_list_dir("/Library/Keychains")

# 5. Attempt to list /private/tmp
checks["list_private_tmp"] = _try_list_dir("/private/tmp")

# 6. Attempt to write outside the workspace.
# The path is read from config.json (planted by the host canary).
# The payload must NOT discover it by listing /tmp — that directory is
# also blocked by the same sandbox profile we are testing.
if config_err is not None:
    checks["write_outside"] = {
        "outcome": "unavailable",
        "detail": f"config unreadable: {config_err}",
    }
elif writable_target:
    checks["write_outside"] = _try_write_file(writable_target, "should-be-blocked-by-seatbelt")
else:
    checks["write_outside"] = {
        "outcome": "unavailable",
        "detail": "writable target path not in config — cannot assess",
    }

# 7. Attempt to write inside the workspace with the canary-supplied marker.
inside = os.path.join(ws, "inside_test.txt")
checks["write_inside"] = _try_write_file(inside, write_marker)

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump({"checks": checks}, f)
