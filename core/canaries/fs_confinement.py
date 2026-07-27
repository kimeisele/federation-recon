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

        backend.run("fs_confinement", ws)

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
