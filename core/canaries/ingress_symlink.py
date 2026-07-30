"""
Canary: ingress_symlink — host-side orchestrator.

Negative canary: PASSes only if the supervisor REFUSED to copy ingress
files into a workspace whose directory was pre-created by an attacker
with a symlink pointing outside the workspace.

Testing approach — direct mechanism test (not adversarial-worker):
We cannot spawn a process as _jcode_worker from the canary: the only
NOPASSWD sudoers entries are the two wrappers (worker_exec.sh and
worker_kill.sh), and running either as the worker would grant more
capability than the canary should exercise.  Instead, this canary
pre-creates the inner workspace directory (with a symlink planted
inside it) from the host side — simulating what an attacker who had
already compromised the worker identity would do — then calls
backend.run() and asserts that:

  Phase 1 (directory guard):
    1a. The backend REFUSES (raises PermissionError) because os.mkdir
        with no exist_ok rejects the pre-existing directory.
    1b. The target file that the symlink pointed to is UNCHANGED —
        verified by content comparison, not by the canary's own report.

  Phase 2 (destination open guard):
    2a. A fresh run directory is created by the canary (simulating the
        supervisor creating a clean directory).  A symlink is planted
        at the ingress DESTINATION path.  _copy_ingress is called
        directly and MUST raise OSError (the O_EXCL|O_NOFOLLOW open
        rejects the existing symlink entry).
    2b. The symlink target's content is still byte-identical to the
        pre-call snapshot.
    2c. The symlink was NOT replaced by a regular file — os.path.islink
        still true.

This tests both defences in the ingress path: the exclusive-create of
the run directory (Phase 1) and the O_EXCL|O_NOFOLLOW write-path
defence (Phase 2), both of which prevent writing through a symlink
planted by the worker before the supervisor stages ingress files.
"""

import os
import secrets
import shutil
import string
import tempfile

_SANDBOX_BASE = "/usr/local/var/jcode-runs"
_RUNS_DIR = os.path.join(_SANDBOX_BASE, "runs")
_WORKER_USER = "_jcode_worker"


def run(backend):
    # Phase 1 — mkdir guard via backend.run()
    # Phase 2 — destination open guard via _copy_ingress direct call
    phase1_ok = False
    phase1_refusal = None
    phase2_ok = False
    phase2_detail = None

    marker = _gen_marker()
    secret_path = os.path.join(
        tempfile.gettempdir(),
        f".jcode_canary_secret_ingress_{secrets.token_hex(8)}"
    )

    # Plant a secret file outside the workspace.
    with open(secret_path, "w") as f:
        f.write(f"secret-key-planted-by-ingress-canary-{marker}\n")
    os.chmod(secret_path, 0o644)

    run_id_1 = _gen_run_id()
    tmp1 = tempfile.mkdtemp(prefix="canary_ingress_symlink_")

    # Phase 2 uses its own run directory (fresh, created by the canary).
    run_id_2 = _gen_run_id()
    inner_ws_2 = os.path.join(_RUNS_DIR, run_id_2)

    try:
        # ── Phase 1 ──────────────────────────────────────────────────
        # Create a workspace file that the backend will try to ingress.
        ws_file = os.path.join(tmp1, "marker.txt")
        with open(ws_file, "w") as f:
            f.write(f"workspace-marker-{marker}\n")

        # Pre-create the inner workspace directory — simulating what an
        # attacker who has compromised the worker identity would do.
        inner_ws_1 = os.path.join(_RUNS_DIR, run_id_1)
        os.makedirs(inner_ws_1, exist_ok=True)

        # Plant a symlink inside the pre-created directory matching the
        # name of one of the ingress files.  Point it at the secret file
        # outside the workspace.
        symlink_dst_1 = os.path.join(inner_ws_1, "marker.txt")
        try:
            os.symlink(secret_path, symlink_dst_1)
        except FileExistsError:
            os.remove(symlink_dst_1)
            os.symlink(secret_path, symlink_dst_1)

        # Snapshot the secret before the backend tries to copy.
        try:
            with open(secret_path, "r") as f:
                secret_before = f.read()
        except Exception as exc:
            return False, (
                f"could not read secret before backend call: {exc}"
            )

        # Now call backend.run() — the supervisor will try to
        # os.mkdir(inner_ws, 0o700) exclusively, which MUST fail
        # because the directory already exists.
        try:
            # Use a dummy canary name — the mkdir refusal happens
            # before any payload is needed.
            backend.run("no_network", tmp1, run_id=run_id_1)
            # If we get here, the backend did NOT refuse.
            return False, (
                f"Phase 1 FAIL: backend accepted a pre-created run "
                f"directory ({inner_ws_1}) — the exclusive-create "
                "defence is missing or bypassed"
            )
        except PermissionError as exc:
            phase1_refusal = str(exc)
        except FileExistsError as exc:
            # The backend should have caught this and re-raised as
            # PermissionError.  If it propagated, the defence is
            # incomplete.
            return False, (
                f"Phase 1 FAIL: backend raised FileExistsError instead "
                f"of PermissionError: {exc} — the mkdir defence does "
                "not wrap the exception"
            )
        except Exception as exc:
            return False, (
                f"Phase 1 FAIL: backend failed with "
                f"{type(exc).__name__}: {exc} — this is not a symlink "
                "ingress refusal and proves nothing about the ingress "
                "defence"
            )

        # Verify the secret file's content is UNCHANGED.
        try:
            with open(secret_path, "r") as f:
                secret_after = f.read()
        except Exception as exc:
            return False, (
                f"Phase 1 FAIL: could not read secret after backend "
                f"call: {exc}"
            )

        if secret_before != secret_after:
            return False, (
                f"Phase 1 FAIL: SECRET MODIFIED — content changed "
                f"after backend refused; the symlink may have been "
                "followed before the refusal"
            )

        phase1_ok = True

        # ── Phase 2 ──────────────────────────────────────────────────
        # This phase tests the destination O_EXCL|O_NOFOLLOW defence
        # directly, reaching the write path that Phase 1 never exercises
        # (the mkdir guard fires first).
        #
        # Create a clean run directory (simulating a supervisor that
        # just created it with os.mkdir(..., 0o700) exclusively).
        try:
            os.mkdir(inner_ws_2, 0o700)
        except FileExistsError:
            return False, (
                "Phase 2 FAIL: cannot create a fresh run directory "
                f"({inner_ws_2}) — it already exists"
            )

        # Create a workspace source file.
        src_file = os.path.join(tmp1, "phase2_marker.txt")
        with open(src_file, "w") as f:
            f.write(f"phase2-marker-{marker}\n")

        # Snapshot the secret content as bytes for byte-identical
        # comparison.
        try:
            with open(secret_path, "rb") as f:
                p2_secret_before = f.read()
        except Exception as exc:
            return False, (
                f"Phase 2 FAIL: could not read secret before "
                f"_copy_ingress: {exc}"
            )

        # Plant a symlink at the INGRESS DESTINATION path inside the
        # clean run directory, pointing at the secret host file.
        symlink_dst_2 = os.path.join(inner_ws_2, "phase2_marker.txt")
        try:
            os.symlink(secret_path, symlink_dst_2)
        except FileExistsError:
            os.remove(symlink_dst_2)
            os.symlink(secret_path, symlink_dst_2)

        # Now call _copy_ingress directly.  This should fail because
        # _write_file_secure opens the destination with
        # O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW — the symlink at dst
        # should be rejected.
        try:
            # backend is the macos_seatbelt module; _copy_ingress is
            # the private staging function.
            backend._copy_ingress(src_file, symlink_dst_2)
            # No exception — the O_EXCL|O_NOFOLLOW defence is missing.
            return False, (
                "Phase 2 FAIL: _copy_ingress accepted a destination "
                "that is a symlink — the O_EXCL|O_NOFOLLOW open "
                "defence is missing or bypassed"
            )
        except PermissionError as exc:
            # Spec says PermissionError — this is the ideal case.
            phase2_detail = (
                f"_copy_ingress refused symlink destination: "
                f"PermissionError: {exc}"
            )
        except FileExistsError as exc:
            # Actual macOS behaviour: O_EXCL on an existing directory
            # entry (even a symlink) raises EEXIST first.  Still a
            # valid refusal from the O_EXCL|O_NOFOLLOW flags.
            phase2_detail = (
                f"_copy_ingress refused symlink destination: "
                f"FileExistsError: {exc}"
            )
        except OSError as exc:
            # Other OSError (ELOOP from O_NOFOLLOW, EACCES, etc.) is
            # also a valid refusal.
            phase2_detail = (
                f"_copy_ingress refused symlink destination: "
                f"{type(exc).__name__}: {exc}"
            )
        except Exception as exc:
            return False, (
                f"Phase 2 FAIL: _copy_ingress raised "
                f"{type(exc).__name__}: {exc} — this is not a symlink "
                "ingress refusal and proves nothing about the "
                "O_EXCL|O_NOFOLLOW defence"
            )

        # Verify the secret file's content is byte-identical to the
        # pre-call snapshot.
        try:
            with open(secret_path, "rb") as f:
                p2_secret_after = f.read()
        except Exception as exc:
            return False, (
                f"Phase 2 FAIL: could not read secret after "
                f"_copy_ingress: {exc}"
            )

        if p2_secret_before != p2_secret_after:
            return False, (
                "Phase 2 FAIL: SECRET MODIFIED — symlink target "
                "content changed after _copy_ingress was called; "
                "the symlink may have been followed"
            )

        # Verify the symlink itself was NOT replaced by a regular file.
        if not os.path.islink(symlink_dst_2):
            return False, (
                f"Phase 2 FAIL: symlink was replaced by a regular file "
                f"({symlink_dst_2}) — the O_EXCL|O_NOFOLLOW defence "
                "did not prevent the write"
            )

        phase2_ok = True

        return True, (
            f"Phase 1 — backend refused pre-created run directory: "
            f"{phase1_refusal}.  "
            "Target file content unchanged.  "
            f"Phase 2 — {phase2_detail}.  "
            "Symlink target content unchanged; symlink not replaced."
        )

    finally:
        try:
            os.remove(secret_path)
        except OSError:
            pass
        # Clean up Phase 1 inner workspace.
        try:
            inner_ws_1 = os.path.join(_RUNS_DIR, run_id_1)
            shutil.rmtree(inner_ws_1, ignore_errors=True)
        except Exception:
            pass
        # Clean up Phase 2 inner workspace.
        try:
            shutil.rmtree(inner_ws_2, ignore_errors=True)
        except Exception:
            pass
        shutil.rmtree(tmp1, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _gen_marker(length=24):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))
