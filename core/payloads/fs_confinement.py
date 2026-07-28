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

ws = sys.argv[1]
sys.path.insert(0, ws)
import _fake_attacker as fa  # noqa: E402

checks = {}

# 1. Attempt to read the REAL ~/.config/secrets/env (if HOME is set)
home = os.environ.get("HOME", os.path.expanduser("~"))
if home and home != "/var/empty":
    real_secret = os.path.join(home, ".config", "secrets", "env")
    checks["read_real_secret"] = fa.try_read_file(real_secret)
else:
    checks["read_real_secret"] = (False, "HOME not set or /var/empty — expected")

# 2. Attempt to read the PLANTED fake secret file (outside workspace)
planted = "/tmp/.jcode_canary_secret_fs"
checks["read_planted_secret"] = fa.try_read_file(planted)

# 3. Attempt to list $HOME
if home and home != "/var/empty":
    checks["list_home"] = fa.try_list_dir(home)
else:
    checks["list_home"] = (False, "HOME not set — expected")

# 4. Attempt to list /Library/Keychains
checks["list_keychains"] = fa.try_list_dir("/Library/Keychains")

# 5. Attempt to list /private/tmp
checks["list_private_tmp"] = fa.try_list_dir("/private/tmp")

# 6. Attempt to write outside the workspace
outside = os.path.realpath(os.path.join(ws, "..", "outside_canary_test"))
checks["write_outside"] = fa.try_write_file(outside, "should-fail")

# 7. Attempt to write inside the workspace
inside = os.path.join(ws, "inside_test.txt")
checks["write_inside"] = fa.try_write_file(inside, "should-succeed")

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(
        {"checks": {name: {"succeeded": ok, "detail": detail} for name, (ok, detail) in checks.items()}},
        f,
    )
