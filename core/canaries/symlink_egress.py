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
        # from O_NOFOLLOW + S_ISREG check, collected into the
        # egress_refusals result dict).
        #
        # An exception from run() is still a failure — it means
        # something went wrong before or during execution, and
        # proves nothing about egress security.
        try:
            result = backend.run("symlink_egress", tmp, run_id=run_id)
        except Exception as exc:
            return False, (
                f"backend failed with {type(exc).__name__}: {exc} — "
                "this is not a symlink refusal and proves nothing about egress"
            )

        # ── Check egress_refusals ────────────────────────────────────
        # Require an entry for result.json whose reason contains
        # "not a regular file" — the O_NOFOLLOW/S_ISREG check must
        # be what refused the symlink egress.
        refusals = result.get("egress_refusals", [])
        if not refusals:
            # No refusals at all: the symlink was not rejected, so
            # the absence of leaked content is unexplained.
            pass  # handled below alongside the content check
        else:
            # Find the refusal for result.json.
            found = None
            for entry in refusals:
                if entry.get("filename") == "result.json":
                    found = entry
                    break

            if found is None:
                # result.json was not refused — other files may have
                # been, but the symlink test target was not.  Still a
                # failure, but check content too before reporting.
                pass  # handled below
            else:
                reason = found.get("reason", "")
                if "not a regular file" not in reason:
                    return False, (
                        f"result.json was refused but not for the symlink: "
                        f"{reason!r} — the O_NOFOLLOW/S_ISREG defence "
                        "was not what refused"
                    )
                # Record the refusal reason for evidence.
                egress_refused = reason

        # ── Assert on content ────────────────────────────────────────
        # The marker string must appear in NO file under the host
        # workspace.  If the backend followed the symlink and copied
        # the secret, its content (including the marker) would be in
        # result.json (or any other file).
        leaked = _marker_in_workspace(tmp, marker)
        if leaked:
            return False, (
                f"SECRET LEAKED: planted marker '{marker}' found in "
                f"host workspace file '{leaked}' — symlink egress "
                "was not blocked"
            )

        # ── Both conditions must hold ────────────────────────────────
        # A refusal naming the regular-file check, AND zero bytes
        # leaked.  Either alone is insufficient.
        if not refusals:
            return False, (
                "egress_refusals is empty — the symlink was not refused, "
                "and the absence of a leak is unexplained; "
                "O_NOFOLLOW defence may not be exercised"
            )

        if found is None:
            return False, (
                "egress_refusals contains entries but none for result.json "
                f"— the symlink test target was not refused.  "
                f"Refused files: {[e.get('filename') for e in refusals]}"
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
