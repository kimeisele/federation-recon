#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "cross-node drift attention items reference the matching finding and bare evidence IDs" {
  run python3 - "$REPO_ROOT" <<'PY'
import glob
import json
import os
import sys

root = sys.argv[1]
digest = json.load(open(os.path.join(root, "digest/v0-boundary-drift.json")))
items = digest["attention_items"]

for drift_path in glob.glob(os.path.join(root, "drift/*.json")):
    drift = json.load(open(drift_path))
    relative_drift = "drift/" + os.path.basename(drift_path)
    matches = [item for item in items if relative_drift in item.get("refs", [])]
    assert len(matches) == 1, (relative_drift, matches)

    finding_refs = [ref for ref in matches[0]["refs"] if ref.startswith("findings/")]
    assert len(finding_refs) == 1, matches[0]
    finding = json.load(open(os.path.join(root, finding_refs[0])))
    evidence_refs = finding.get("evidence_refs", [])
    assert drift["evidence"] in evidence_refs, (drift, finding)
    assert all("/" not in ref and not ref.endswith(".json") for ref in evidence_refs), finding

targets = {item["target"] for item in items if item.get("attention_rank") == 1}
assert targets == {"kimeisele/steward", "kimeisele/agent-internet"}, targets
PY
  [ "$status" -eq 0 ]
}
