"""
Canary script: fs_confinement — filesystem access MUST be confined to workspace.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Must hold:
  - Reading ~/.config/secrets/env FAILS
  - Reading a planted fake secret outside the workspace FAILS
  - Listing $HOME FAILS
  - Writing outside the workspace FAILS
  - Writing inside the workspace SUCCEEDS
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

# 4. Attempt to write outside the workspace (resolves ../outside)
outside = os.path.realpath(os.path.join(ws, "..", "outside_canary_test"))
checks["write_outside"] = fa.try_write_file(outside, "should-fail")

# 5. Attempt to write inside the workspace
inside = os.path.join(ws, "inside_test.txt")
checks["write_inside"] = fa.try_write_file(inside, "should-succeed")

# Evaluate
must_fail = ["read_real_secret", "read_planted_secret", "list_home", "write_outside"]
must_succeed = ["write_inside"]

passed = True
parts = []
for name in must_fail:
    ok, detail = checks[name]
    if ok:
        passed = False
        parts.append(f"{name}: LEAKED (BAD) ({detail})")
    else:
        parts.append(f"{name}: BLOCKED ({detail})")

for name in must_succeed:
    ok, detail = checks[name]
    if not ok:
        passed = False
        parts.append(f"{name}: BLOCKED (BAD) ({detail})")
    else:
        parts.append(f"{name}: ALLOWED ({detail})")

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump({"passed": passed, "reason": " | ".join(parts)}, f)
sys.exit(0 if passed else 1)
