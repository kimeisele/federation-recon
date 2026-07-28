"""
Canary: fs_confinement — host-side orchestrator.

Runs the fs_confinement payload inside the sandbox and judges the results.
The payload reports raw check outcomes; the host decides pass or fail.

Must hold:
  - Reading ~/.config/secrets/env FAILS
  - Reading a planted fake secret outside the workspace FAILS
  - Listing $HOME FAILS
  - Listing /Library/Keychains FAILS
  - Listing /private/tmp FAILS
  - Writing outside the workspace FAILS
  - Writing inside the workspace SUCCEEDS

Plants a fake secret file at a known path OUTSIDE the workspace for the
positive read check.  The file is created world-readable in /tmp so that
only the sandbox (not Unix permissions) can block it.
"""

import json
import os
import secrets
import shutil
import string
import tempfile


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_fs_confinement_")
    _fake = os.path.join(os.path.dirname(__file__), "..", "payloads", "_fake_attacker.py")
    shutil.copy(_fake, os.path.join(tmp, "_fake_attacker.py"))

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

    try:
        backend.run("fs_confinement", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        checks = data.get("checks", {})
        if not checks:
            return False, "result.json has no checks"

        # Mandatory expectations for each check
        expectations = {
            "read_real_secret": False,
            "read_planted_secret": False,
            "list_home": False,
            "list_keychains": False,
            "list_private_tmp": False,
            "write_outside": False,
            "write_inside": True,
        }

        passed = True
        parts = []
        for name, must_succeed in expectations.items():
            ch = checks.get(name)
            if ch is None:
                passed = False
                parts.append(f"{name}: MISSING")
                continue

            ok = ch["succeeded"]
            detail = ch["detail"]

            if must_succeed:
                if not ok:
                    passed = False
                    parts.append(f"{name}: BLOCKED (BAD) ({detail})")
                else:
                    parts.append(f"{name}: ALLOWED ({detail})")
            else:
                if ok:
                    passed = False
                    parts.append(f"{name}: LEAKED (BAD) ({detail})")
                else:
                    parts.append(f"{name}: BLOCKED ({detail})")

        return passed, " | ".join(parts)

    finally:
        try:
            os.remove("/tmp/.jcode_canary_secret_fs")
        except OSError:
            pass
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
