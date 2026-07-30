"""
Canary: symlink_egress — host-side orchestrator.

Negative canary: PASSes only if the supervisor REFUSED to copy a
symlink out of the inner workspace AND zero bytes of the planted
secret reached the host workspace.

The payload creates result.json as a symlink pointing at a secret
file planted outside the workspace.  A vulnerable backend (using
os.path.isfile + shutil.copy, which follow symlinks) would copy the
secret into the host workspace — a confused-deputy exfiltration.

Must hold: the backend's egress path uses os.lstat + S_ISREG +
O_NOFOLLOW, rejects symlinks, and the secret never leaves the inner
workspace.
"""

import os
import secrets
import shutil
import stat
import string
import tempfile


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_symlink_egress_")

    # Generate a unique marker for this run.
    marker = _gen_marker()
    planted_path = "/tmp/.jcode_canary_secret_symlink"

    # Plant a secret file outside the workspace, world-readable, so
    # that only the sandbox (not Unix permissions) would block it.
    with open(planted_path, "w") as f:
        f.write(f"secret-key-planted-by-canary-orchestrator-{marker}")
    os.chmod(planted_path, 0o644)

    try:
        # Run the payload inside the sandbox.  The payload creates
        # result.json as a symlink pointing at planted_path.  The
        # backend's egress copy should REJECT it (PermissionError
        # from O_NOFOLLOW + S_ISREG check).  We catch the exception
        # because the rejection is the expected outcome.
        try:
            backend.run("symlink_egress", tmp, run_id=run_id)
        except PermissionError as exc:
            # Expected: the backend refused the symlink egress.
            # Record but do not fail on this alone — we must also
            # verify no data leaked.
            #
            # Only PermissionError counts, and only when its message names
            # the regular-file check.  Accepting any exception would let an
            # unrelated failure — a missing canary script, a sudo error, a
            # typo in the wrapper — masquerade as a successful defence.
            # This canary must fail if the mechanism it names is absent.
            if "not a regular file" not in str(exc):
                return False, (
                    f"backend raised PermissionError but not for the symlink: "
                    f"{exc!r} — the O_NOFOLLOW/S_ISREG defence was not what refused"
                )
            egress_refused = str(exc)
        except Exception as exc:
            return False, (
                f"backend failed with {type(exc).__name__}: {exc} — "
                "this is not a symlink refusal and proves nothing about egress"
            )
        else:
            # No exception — the backend may have silently skipped
            # or, worse, copied the symlink content.  We record
            # that no refusal was raised; the content check below
            # will catch a leak.
            egress_refused = None

        # Assert on content: the marker string must appear in NO
        # file under the host workspace.  If the backend followed
        # the symlink and copied the secret, its content (including
        # the marker) would be in result.json (or any other file).
        leaked = _marker_in_workspace(tmp, marker)
        if leaked:
            return False, (
                f"SECRET LEAKED: planted marker '{marker}' found in "
                f"host workspace file '{leaked}' — symlink egress "
                "was not blocked"
            )

        if egress_refused is None:
            return False, (
                "backend did not raise on symlink egress but no "
                "marker found in host workspace — possible silent skip; "
                "O_NOFOLLOW defence may not be exercised"
            )

        return True, (
            f"backend refused symlink egress: {egress_refused}.  "
            "Zero bytes of planted secret reached host workspace."
        )

    finally:
        try:
            os.remove(planted_path)
        except OSError:
            pass
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _gen_marker(length=24):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _marker_in_workspace(workspace, marker):
    """Return the path of the first file in *workspace* containing *marker*,
    or None if no file contains it."""
    for fn in os.listdir(workspace):
        path = os.path.join(workspace, fn)
        try:
            lst = os.lstat(path)
            if not stat.S_ISREG(lst.st_mode):
                continue
        except OSError:
            continue
        try:
            with open(path, "r") as f:
                content = f.read()
            if marker in content:
                return fn
        except Exception:
            continue
    return None
