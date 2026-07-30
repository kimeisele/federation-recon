"""
Payload: pid_limit_preservation — forks a fixed small number of children.

Executed inside the seatbelt sandbox by worker_exec.sh.
Receives the workspace path as sys.argv[1].

Forks exactly 5 children (well under the 64-process rlimit), each of which
computes a simple SHA-256 hash and writes it to a numbered output file.
The parent then writes a combined result.json with checksums of all child
outputs.  If the rlimit blocked normal forking, this would fail — proving
we deny bombs, not forking.
"""

import hashlib
import json
import os
import sys
import time

ws = sys.argv[1]

NUM_CHILDREN = 5
children = []

for i in range(NUM_CHILDREN):
    pid = os.fork()
    if pid == 0:
        # Child: compute a hash and write it.
        data = f"child-{i}-payload-{os.getpid()}".encode()
        h = hashlib.sha256(data).hexdigest()
        out_path = os.path.join(ws, f"child_{i}.out")
        try:
            with open(out_path, "w") as f:
                f.write(h)
        except OSError:
            pass
        os._exit(0)
    children.append(pid)

# Parent: wait for all children and collect results.
child_checksums = {}
for i, pid in enumerate(children):
    try:
        _, status = os.waitpid(pid, 0)
        exit_code = (status & 0xFF00) >> 8 if os.WIFEXITED(status) else -1
        out_path = os.path.join(ws, f"child_{i}.out")
        if os.path.exists(out_path):
            with open(out_path) as f:
                child_checksums[f"child_{i}"] = f.read().strip()
        child_checksums[f"child_{i}_exit"] = exit_code
    except OSError:
        child_checksums[f"child_{i}"] = "wait_failed"

# Verify children forked and produced output.
all_ok = all(
    child_checksums.get(f"child_{i}", "").startswith("child-")
    or True  # The content is a SHA-256 hex digest, not literal
    for i in range(NUM_CHILDREN)
)
# Actually check that each child produced a non-empty hex digest.
all_ok = all(
    len(child_checksums.get(f"child_{i}", "")) == 64  # SHA-256 hex
    for i in range(NUM_CHILDREN)
)

result = {
    "children_forked": len(children),
    "children_waited": sum(1 for i in range(NUM_CHILDREN)
                          if child_checksums.get(f"child_{i}_exit") == 0),
    "all_outputs_valid": all_ok,
    "child_checksums": child_checksums,
}

with open(os.path.join(ws, "result.json"), "w") as f:
    json.dump(result, f)
