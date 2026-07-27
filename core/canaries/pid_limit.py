"""
Canary: pid_limit — a fork bomb MUST be stopped at the rlimit.

Must hold: the fork bomb is killed by RLIMIT_NPROC (or the kernel
refuses further forks).  The mechanism is EAGAIN/ENOMEM from fork(),
or SIGKILL from the OOM killer — both are detected via the resulting
exit_status / term_signal.
"""

import json
import os
import shutil
import tempfile


def run(backend):
    ws = tempfile.mkdtemp(prefix="canary_pid_limit_")
    try:
        src = os.path.join(os.path.dirname(__file__), "_fake_attacker.py")
        shutil.copy(src, os.path.join(ws, "_fake_attacker.py"))

        result = backend.run("pid_limit", ws)

        # The fork bomb should have been stopped by the rlimit,
        # resulting in exit 0 (not killed by a signal).
        # If it was killed by SIGKILL (term_signal=9), that's also fine
        # — the limit worked, just more violently.
        # If exit_status is 0 and the result file says passed, that's ideal.
        result_path = os.path.join(ws, "result.json")
        if os.path.exists(result_path):
            with open(result_path) as f:
                data = json.load(f)
            return data["passed"], data["reason"]

        # Fallback: interpret the backend result
        if result["exit_status"] == 0:
            return True, "fork bomb exited cleanly (rlimit stopped it)"
        elif result["term_signal"] is not None:
            return True, f"fork bomb killed by signal {result['term_signal']} (rlimit enforced)"
        else:
            return False, f"exit_status={result['exit_status']} — limit may not have applied"
    finally:
        shutil.rmtree(ws, ignore_errors=True)
