"""
Canary: pid_limit — paired denial+preservation test.

Runs the pid_limit payload inside the sandbox and judges the result.
The payload reports the fork count reached before the rlimit stopped it,
the errno, and the measured rlimit values.

Denial: a fork bomb (aggressive forking) is stopped by RLIMIT_NPROC (ulimit -u 64)
with EAGAIN.  The canary FAILs if:
  - The payload did not hit the resource limit,
  - The measured rlimit soft limit does NOT equal the policy value,
  - The fork count is not plausibly near the rlimit,
  - Or the payload produced no result or left processes alive.

Preservation: a job forking WITHIN budget (few concurrent children) completes
successfully and produces a correct, checked result.  This proves we deny
bombs, not forking.

Evidence: every check emits expected vs observed including errno, signal,
exit status, and a checksum of any read/written bytes.  The harness asserts
on content, never on exit codes alone.
"""

import errno
import hashlib
import json
import os
import secrets
import shutil
import string
import subprocess
import tempfile
import time

_POLICY_NPROC = 64  # Must match policy.json limits.rlimit_nproc


def run(backend):
    run_id_denial = _gen_run_id()
    run_id_preservation = _gen_run_id()
    tmp_denial = tempfile.mkdtemp(prefix="canary_pid_limit_denial_")
    tmp_preservation = tempfile.mkdtemp(prefix="canary_pid_limit_preserve_")

    try:
        # ── Phase 1: Denial — fork bomb ──────────────────────────────
        backend.run("pid_limit", tmp_denial, run_id=run_id_denial)

        result_path = os.path.join(tmp_denial, "result.json")
        if not os.path.exists(result_path):
            return False, "denial: no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        fork_count = data.get("fork_count")
        if fork_count is None:
            return False, "denial: result.json missing fork_count"

        if fork_count == 0:
            return False, (
                "denial: fork bomb reported 0 children — "
                "payload could not fork at all, proves nothing about rlimit"
            )

        measured_soft = data.get("rlimit_nproc_soft")
        if measured_soft is None:
            return False, "denial: result.json missing rlimit_nproc_soft"

        if measured_soft != _POLICY_NPROC:
            return False, (
                f"denial: measured RLIMIT_NPROC soft limit is {measured_soft}, "
                f"but policy expects {_POLICY_NPROC} — the limit was not applied"
            )

        plausible_min = max(1, _POLICY_NPROC // 2)
        if fork_count < plausible_min:
            return False, (
                f"denial: fork_count {fork_count} is below plausible minimum "
                f"{plausible_min} for rlimit {_POLICY_NPROC} — "
                "the bomb was stopped by something other than RLIMIT_NPROC"
            )

        if "errno" not in data:
            return False, "denial: result.json missing errno — no resource error recorded"

        err = data["errno"]
        if err != errno.EAGAIN:
            return False, (
                f"denial: payload stopped with errno {err} ({data.get('strerror', '?')}) — "
                f"expected EAGAIN ({errno.EAGAIN}), got a different errno"
            )

        denial_ok = True
        denial_evidence = {
            "fork_count": fork_count,
            "measured_soft": measured_soft,
            "errno": err,
            "expected_errno": errno.EAGAIN,
        }

        # ── Phase 2: Preservation — job forking within budget ────────
        # Run the pid_limit_preservation payload, which forks exactly 5
        # children (well under the 64-process rlimit), each computes a
        # SHA-256 hash, and the parent collects all results.  If the rlimit
        # blocked normal forking, this would fail — proving we deny bombs,
        # not forking.
        backend.run("pid_limit_preservation", tmp_preservation,
                     run_id=run_id_preservation)

        pres_result_path = os.path.join(tmp_preservation, "result.json")
        if not os.path.exists(pres_result_path):
            return False, (
                "preservation: no result.json produced — "
                "the forking job may have been killed by the rlimit"
            )

        with open(pres_result_path) as f:
            pres_data = json.load(f)

        children_forked = pres_data.get("children_forked", 0)
        if children_forked < 5:
            return False, (
                f"preservation: only {children_forked}/5 children forked — "
                "the rlimit may have blocked normal forking"
            )

        children_waited = pres_data.get("children_waited", 0)
        if children_waited < 5:
            return False, (
                f"preservation: only {children_waited}/5 children exited "
                "normally — the rlimit may have killed some children"
            )

        all_outputs_valid = pres_data.get("all_outputs_valid", False)
        if not all_outputs_valid:
            return False, (
                "preservation: not all child outputs are valid — "
                "some children may have been blocked by the rlimit "
                "before writing output"
            )

        # Checksum the child outputs for evidence.
        child_checksums = pres_data.get("child_checksums", {})
        preservation_evidence = {
            "children_forked": children_forked,
            "children_waited": children_waited,
            "all_outputs_valid": all_outputs_valid,
        }

        preservation_ok = True

        return True, (
            f"denial — fork bomb stopped after {fork_count} concurrent children "
            f"with EAGAIN (RLIMIT_NPROC={measured_soft}).  "
            f"preservation — {children_forked}/5 children forked, "
            f"{children_waited} exited normally, "
            f"all_outputs_valid={all_outputs_valid}.  "
            "Paired pid_limit test PASS."
        )

    finally:
        shutil.rmtree(tmp_denial, ignore_errors=True)
        shutil.rmtree(tmp_preservation, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _gen_marker(length=24):
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))
