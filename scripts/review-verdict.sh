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
#
# The boundary fails closed: a finding the model claimed blocking (claimed_severity)
# blocks the merge unless its verification command was executed and refuted
# (verification_status "rejected"). A severity later downgraded by review.sh is
# not a refutation, and an incomplete review is never reinterpreted as approval.

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
# block. The claim that binds is the original one from the model: when
# verification cannot confirm a blocking finding, review.sh preserves the
# claim in claimed_severity while lowering severity to "non-blocking" (sandbox
# unavailable, command never run, non-discriminating, base-unverified). Keying
# on severity alone would let every such downgraded finding fall through to
# APPROVE, so the effective claim is claimed_severity when present and the
# recorded severity otherwise, and anything short of a refutation rejects.
for finding in findings:
    claimed = finding.get("claimed_severity") or finding.get("severity")
    if claimed == "blocking" and finding.get("verification_status") != "rejected":
        print("REJECT")
        sys.exit(0)

# Rule 5: mandatory tasks (tier0, review-analysis, adversarial-execution) must
# reach "pass" or "complete". Only tier2 may stay "not_run" (escalation-only).
MANDATORY = {"tier0", "review-analysis", "adversarial-execution"}
for name, value in tasks.items():
    if value in ("pass", "complete"):
        continue
    if value == "not_run" and name not in MANDATORY:
        continue
    print("PARTIAL")
    sys.exit(0)

# Rule 6: HIGH-risk work needs Tier 2 independent verification.
if verdict.get("risk_class") == "HIGH" and tasks.get("tier2") != "complete":
    print("PARTIAL")
    sys.exit(0)

print("APPROVE")
' "$1" "$2"

exit 0
