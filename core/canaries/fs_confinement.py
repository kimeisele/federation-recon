"""
Canary: fs_confinement — filesystem access MUST be confined to the workspace.

Must hold:
  - Reading ~/.config/secrets/env FAILS
  - Listing $HOME FAILS
  - Writing outside the workspace FAILS
  - Writing inside the workspace SUCCEEDS

Uses a planted fake secret file at a known path OUTSIDE the workspace
for the positive check; also attempts the REAL ~/.config/secrets/env.
Both must be unreadable.  The planted file is created world-readable in
/tmp so that only the sandbox (not Unix permissions) can block it.
"""

import json
import os
import shutil
import tempfile


_CANARY_BODY = r"""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _fake_attacker as fa

ws = os.path.dirname(os.path.abspath(__file__))

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
"""


def run(backend):
    ws = tempfile.mkdtemp(prefix="canary_fs_confinement_")
    try:
        src = os.path.join(os.path.dirname(__file__), "_fake_attacker.py")
        shutil.copy(src, os.path.join(ws, "_fake_attacker.py"))

        # Plant a fake secret file OUTSIDE the workspace at a known path.
        # It is created world-readable (0o644) in /tmp.  A process running
        # as _jcode_worker would be able to read it by Unix permissions —
        # only the sandbox profile, which denies access to everything
        # outside WORKSPACE, should block it.  This isolates the test to
        # the sandbox itself, not Unix file permissions.
        planted_path = "/tmp/.jcode_canary_secret_fs"
        with open(planted_path, "w") as f:
            f.write("fake-api-key-planted-by-canary-orchestrator")
        os.chmod(planted_path, 0o644)

        script = os.path.join(ws, "canary.py")
        with open(script, "w") as f:
            f.write(_CANARY_BODY)
        os.chmod(script, 0o700)

        backend.run(script, ws)

        result_path = os.path.join(ws, "result.json")
        if os.path.exists(result_path):
            with open(result_path) as f:
                data = json.load(f)
            return data["passed"], data["reason"]
        else:
            return False, "no result.json produced"
    finally:
        # Clean up the planted secret file
        try:
            os.remove("/tmp/.jcode_canary_secret_fs")
        except OSError:
            pass
        shutil.rmtree(ws, ignore_errors=True)
