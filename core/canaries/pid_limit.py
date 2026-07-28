"""
Canary: pid_limit — host-side orchestrator.

Runs the pid_limit payload inside the sandbox and judges the result.
The payload reports the fork count it reached; the host decides pass or fail.

Must hold: the fork bomb is stopped by RLIMIT_NPROC (ulimit -u 64) before
it can consume unbounded resources.  The fork count in the parent should
be modest (well under the ulimit, since children also fork).
"""

import json
import os
import secrets
import shutil
import string
import tempfile


def run(backend):
    run_id = _gen_run_id()
    tmp = tempfile.mkdtemp(prefix="canary_pid_limit_")

    try:
        backend.run("pid_limit", tmp, run_id=run_id)

        result_path = os.path.join(tmp, "result.json")
        if not os.path.exists(result_path):
            return False, "no result.json produced"

        with open(result_path) as f:
            data = json.load(f)

        fork_count = data.get("fork_count")
        if fork_count is None:
            return False, "result.json missing fork_count"

        # The ulimit is 64.  Children also fork, so the parent's count of
        # concurrent children is typically well below 64 when the limit
        # bites.  A count over 100 suggests the rlimit did not apply.
        if fork_count > 100:
            return False, (
                f"fork bomb reached {fork_count} concurrent children — "
                "rlimit may not have applied"
            )

        return True, (
            f"fork bomb stopped after {fork_count} concurrent children "
            "in parent (rlimit enforced)"
        )

    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _gen_run_id(length=16):
    alphabet = string.ascii_letters + string.digits + "_-"
    return "".join(secrets.choice(alphabet) for _ in range(length))
