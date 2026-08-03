#!/usr/bin/env bash
# review-verdict.sh — Deterministic verdict aggregation for the review pipeline.
#
# Usage: bash scripts/review-verdict.sh <verdict-json-path> <current-pr-head-sha>
#
# Implements ONLY the deterministic aggregation rules from
# docs/review-pipeline-spec-v0.md §"Verdict aggregation (deterministic, no
# model)". No model calls, no worktrees, no git operations — the decision is a
# pure function of the verdict JSON and the current PR head SHA.
#
# Prints exactly one word — APPROVE, REJECT, PARTIAL, or STALE — and exits 0
# always. PARTIAL is never approval: unreadable input and under-specified
# reviews stay incomplete rather than being reinterpreted as green.
#
# The stored `verdict` field is informational (it records what the run wrote);
# the final word is recomputed here so aggregation cannot be swayed by a
# hand-edited verdict line.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "PARTIAL"
  exit 0
fi

# "Exit 0 always" is part of the contract. A missing interpreter is a review
# that cannot run — an incomplete review stays PARTIAL, never a crash.
if ! command -v python3 >/dev/null 2>&1; then
  echo "PARTIAL"
  exit 0
fi

python3 -c '
import json, sys

path, current_head = sys.argv[1], sys.argv[2]

try:
    with open(path) as handle:
        verdict = json.load(handle)
except Exception:
    print("PARTIAL")
    sys.exit(0)

# Rule 1: a verdict bound to a different commit is stale.
if verdict.get("subject_head_sha") != current_head:
    print("STALE")
    sys.exit(0)

tasks = verdict.get("tasks", {})
findings = verdict.get("findings", [])

# Rule 2: Tier 0 is mandatory; a failed gate is a rejection.
if tasks.get("tier0") == "fail":
    print("REJECT")
    sys.exit(0)

# Rule 3: an errored Tier 0 did not complete; nothing is decided.
if tasks.get("tier0") == "error":
    print("PARTIAL")
    sys.exit(0)

# Rule 4: an unresolved blocking finding is a rejection. A finding whose
# verification_status is "rejected" was examined and refuted, so it does not
# block.
for finding in findings:
    if (finding.get("severity") == "blocking"
            and finding.get("verification_status")
            in ("confirmed", "inconclusive", "not_run")):
        print("REJECT")
        sys.exit(0)

# Rule 5: any task that is neither healthy ("pass"/"complete") nor a permitted
# "not_run" leaves the review partial.
for name, value in tasks.items():
    if value not in ("pass", "complete") and value != "not_run":
        print("PARTIAL")
        sys.exit(0)

# Rule 6: HIGH-risk work needs Tier 2 independent verification.
if verdict.get("risk_class") == "HIGH" and tasks.get("tier2") != "complete":
    print("PARTIAL")
    sys.exit(0)

print("APPROVE")
' "$1" "$2"

exit 0
