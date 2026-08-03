#!/usr/bin/env bash
# review.sh — the review runner: orchestrates one review of a pull request.
#
# Inert by design: manually invoked only, no heartbeat wiring, and the LLM
# never enters the dispatcher (CLAUDE.md). Heartbeat signals when a review is
# needed; this script is where the review happens, outside the dispatcher.
#
#   bash scripts/review.sh --pr <N>
#
# Exit 0 always, even on errors: an unreviewable PR is recorded as a PARTIAL
# verdict, never a crash. The only non-zero exit is a usage error.
#
# Verdict and per-phase artifacts are written to
# ~/.local/share/federation-recon/reviews/, never inside the repository:
# writing a review result must never change the branch under review
# (docs/review-pipeline-spec-v0.md). The script reads no reviewer credential
# and makes no model call — Tier 1A/1B and Tier 2 are stubs that record
# "not_run" until the adoption PR.

set -euo pipefail
cd "$(dirname "$0")/.."

# ---- 1. Arguments --------------------------------------------------------

usage() {
  echo "usage: bash scripts/review.sh --pr <N>" >&2
  echo "  --pr <N>  GitHub PR number to review (required)" >&2
}

pr_number=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      if [ "$#" -lt 2 ]; then
        usage
        exit 1
      fi
      pr_number="$2"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

# A PR number must be a positive integer; reject 0, negatives, and junk.
if ! [[ "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
  usage
  exit 1
fi

# ---- 2. Run ID and output directory --------------------------------------

# REVIEW_DIR follows the spec: ~/.local/share/federation-recon/reviews/.
# ${HOME} is used rather than ~ so the location is explicit and tests can
# point HOME at a sandbox instead of a real user's review history.
REVIEW_DIR="${HOME}/.local/share/federation-recon/reviews"
today="$(date +%Y%m%d)"

# The sequence number comes from the review output directory itself: the next
# NNN after the highest run for today, zero-padded to three digits.
next_seq=1
for d in "$REVIEW_DIR"/rv-${today}-*; do
  [ -d "$d" ] || continue
  n="${d##*-}"
  if [[ "$n" =~ ^[0-9]{3}$ ]]; then
    v=$((10#$n))
    if [ "$v" -ge "$next_seq" ]; then
      next_seq=$((v + 1))
    fi
  fi
done
run_id="rv-${today}-$(printf '%03d' "$next_seq")"
run_dir="$REVIEW_DIR/$run_id"
mkdir -p "$run_dir"

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---- Constants for the stub pipeline --------------------------------------

# Risk classification is a separate concern (spec: "What this does NOT
# change"); until a classifier exists every run records LOW.
risk_class="LOW"
has_blocking_finding=false   # the stubs produce no findings
tier1_inconclusive=false     # the stubs never report inconclusive

# ---- python3 dependency ---------------------------------------------------

# The verdict artifact is assembled with python3 (spec step 9). If it is
# missing the review cannot record its outcome; write a schema-conforming
# PARTIAL verdict with the shell itself and exit 0 — "exit 0 always" is the
# runner's contract, and an incomplete review stays incomplete, never green.
if ! command -v python3 >/dev/null 2>&1; then
  cat > "$run_dir/verdict.json" <<EOF
{
  "schema": "review-verdict-v1",
  "run_id": "$run_id",
  "pr_number": $pr_number,
  "subject_head_sha": "unresolved",
  "risk_class": "LOW",
  "timestamp": "$timestamp",
  "tasks": {
    "tier0": "error",
    "review-analysis": "not_run",
    "adversarial-execution": "not_run",
    "tier2": "not_run"
  },
  "findings": [],
  "verdict": "PARTIAL"
}
EOF
  echo "review: python3 is required (verdict assembly) and is not installed" >&2
  echo "Review $run_id for PR #$pr_number (head SHA unresolved): PARTIAL"
  echo "Artifacts: $run_dir/"
  exit 0
fi

# ---- Tier stubs (functions) -----------------------------------------------

# _tier1a <worktree> — Tier 1A review analysis (read-only model call):
# intent vs implementation, claims vs evidence, environment and workflows,
# failure modes, completeness. The <worktree> argument is the disposable
# checkout at the subject HEAD SHA, for the real implementation.
# STUB: model call deferred to adoption PR
_tier1a() {
  python3 - "$run_id" <<'PYEOF' > "$run_dir/tier1a.json"
import json, sys
artifact = {
    "run_id": sys.argv[1],
    "task": "review-analysis",
    "status": "not_run",
    "stub": True,
    "note": "STUB: model call deferred to adoption PR",
}
json.dump(artifact, sys.stdout, indent=2)
PYEOF
  printf 'not_run'
}

# _tier1b <worktree> — Tier 1B adversarial execution (checkout model call):
# evasion attempts, mutation testing, self-application, run in the disposable
# worktree.
# STUB: model call deferred to adoption PR
_tier1b() {
  python3 - "$run_id" <<'PYEOF' > "$run_dir/tier1b.json"
import json, sys
artifact = {
    "run_id": sys.argv[1],
    "task": "adversarial-execution",
    "status": "not_run",
    "stub": True,
    "note": "STUB: model call deferred to adoption PR",
}
json.dump(artifact, sys.stdout, indent=2)
PYEOF
  printf 'not_run'
}

# _tier2 <worktree> — Tier 2 independent verification (escalation only:
# risk_class HIGH, a blocking finding, or an inconclusive Tier 1). Uses a
# model from a different provider than Tier 1.
# STUB: escalation model call deferred to adoption PR
_tier2() {
  python3 - "$run_id" <<'PYEOF' > "$run_dir/tier2.json"
import json, sys
artifact = {
    "run_id": sys.argv[1],
    "task": "tier2",
    "status": "not_run",
    "stub": True,
    "note": "STUB: escalation model call deferred to adoption PR",
}
json.dump(artifact, sys.stdout, indent=2)
PYEOF
  printf 'not_run'
}

# ---- Verdict assembly and aggregation (functions) -------------------------

# write_verdict <subject_sha> <tier0> <tier1a> <tier1b> <tier2> — assemble the
# verdict artifact via python3 so escaping cannot corrupt the JSON. The stored
# `verdict` field is a placeholder; the aggregator recomputes it from tasks
# and findings rather than trusting the stored copy.
write_verdict() {
  local subject_sha="$1" t0="$2" t1a="$3" t1b="$4" t2="$5"
  python3 - "$run_id" "$pr_number" "$subject_sha" "$risk_class" "$timestamp" \
    "$t0" "$t1a" "$t1b" "$t2" "$run_dir/verdict.json" <<'PYEOF'
import json, sys

(run_id, pr_number, subject_sha, risk_class, timestamp,
 t0, t1a, t1b, t2, out_path) = sys.argv[1:11]

verdict = {
    "schema": "review-verdict-v1",
    "run_id": run_id,
    "pr_number": int(pr_number),
    "subject_head_sha": subject_sha,
    "risk_class": risk_class,
    "timestamp": timestamp,
    "tasks": {
        "tier0": t0,
        "review-analysis": t1a,
        "adversarial-execution": t1b,
        "tier2": t2,
    },
    "findings": [],
    "verdict": "PARTIAL",
}

with open(out_path, "w") as handle:
    json.dump(verdict, handle, indent=2)
    handle.write("\n")
PYEOF
}

# update_verdict_field <word> — write the aggregated word back into the
# artifact. The field is informational; the aggregator remains the authority,
# but the artifact must not lie about what the run decided.
update_verdict_field() {
  local word="$1"
  python3 - "$run_dir/verdict.json" "$word" <<'PYEOF'
import json, sys

path, word = sys.argv[1], sys.argv[2]
verdict = json.load(open(path))
verdict["verdict"] = word
with open(path, "w") as handle:
    json.dump(verdict, handle, indent=2)
    handle.write("\n")
PYEOF
}

# finalize <subject_sha> <tier0> <tier1a> <tier1b> <tier2> — write the verdict
# artifact and run the deterministic aggregation (spec step 10). Prints
# exactly the aggregated word.
finalize() {
  local subject_sha="$1" t0="$2" t1a="$3" t1b="$4" t2="$5" word
  write_verdict "$subject_sha" "$t0" "$t1a" "$t1b" "$t2"
  word="$(bash scripts/review-verdict.sh "$run_dir/verdict.json" "$subject_sha")"
  update_verdict_field "$word"
  printf '%s' "$word"
}

# ---- 3. PR metadata -------------------------------------------------------

# A review is bound to a specific commit: the PR's head SHA. A verdict for
# commit X is never applied to a later commit on the same PR — the aggregator
# refuses (STALE) when the stored SHA does not match the current head.
if ! head_sha="$(gh pr view "$pr_number" --json headRefOid --jq '.headRefOid' 2>"$run_dir/gh.log")" || [ -z "$head_sha" ]; then
  # gh failed or returned nothing: the review cannot start. Record a PARTIAL
  # verdict bound to no commit and exit 0 — the review is incomplete, never a
  # crash. A later process comparing this verdict against the PR's real head
  # sees a mismatch and marks it STALE, which is the correct fate for a
  # review that never started.
  verdict_word="$(finalize "unresolved" "error" "not_run" "not_run" "not_run")"
  echo "Review $run_id for PR #$pr_number (head SHA unresolved): $verdict_word"
  echo "Artifacts: $run_dir/"
  exit 0
fi

# ---- 4. Disposable worktree -----------------------------------------------

# Mutating checks (evasion, mutation testing, self-application) run in a
# disposable git worktree at the subject HEAD SHA; a timeout or crash
# destroys the worktree, never the primary checkout. Same pattern as
# scripts/gate.sh (the reproduce fixpoint). The path is canonicalized with
# pwd -P because macOS mktemp may return a symlinked /var/folders path while
# git resolves /private/var/folders.
wt_dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-worktree.XXXXXX")" && pwd -P)"

# Remove the worktree on every exit path — pass, fail, signal — via the EXIT
# trap alone; no explicit call is needed. On INT/TERM the cleanup is followed
# by exit with 128+SIGNO: a signal-killed review must not keep running against
# a worktree it has already removed.
review_cleanup() {
  git worktree remove --force "$wt_dir" 2>/dev/null || {
    # The removal failed (e.g. the directory is already gone); unregister
    # whatever stale admin state the failed remove left behind.
    git worktree prune 2>/dev/null || true
  }
  rm -rf "$wt_dir" 2>/dev/null || true
}
trap review_cleanup EXIT
trap 'review_cleanup; exit 130' INT
trap 'review_cleanup; exit 143' TERM

tier0_status="error"
tier1a_status="not_run"
tier1b_status="not_run"
tier2_status="not_run"

if git worktree add "$wt_dir" "$head_sha" --detach --quiet 2>"$run_dir/worktree.log"; then
  # ---- 5. Tier 0 — run the gate ------------------------------------------
  # The gate runs in the worktree with the worktree as CWD, in a subshell so
  # the cd cannot leak into the primary checkout. Exit mapping: 0 -> pass;
  # non-zero with a gate script present -> fail (the gate ran and failed);
  # anything else -> error (the gate could not run at all, e.g. a broken
  # worktree).
  if ( cd "$wt_dir" && bash scripts/gate.sh --full ) > "$run_dir/tier0.log" 2>&1; then
    tier0_status="pass"
  elif [ -f "$wt_dir/scripts/gate.sh" ]; then
    tier0_status="fail"
  fi

  # ---- 6. Tier 1A — review analysis (stub) -------------------------------
  tier1a_status="$(_tier1a "$wt_dir")"

  # ---- 7. Tier 1B — adversarial execution (stub) -------------------------
  tier1b_status="$(_tier1b "$wt_dir")"

  # ---- 8. Tier 2 — independent verification (stub) -----------------------
  # Escalation triggers (spec §Tier 2): risk_class HIGH, a blocking finding,
  # or an inconclusive Tier 1. risk_class is hardcoded LOW and the stubs
  # produce no findings, so Tier 2 is not called.
  if [ "$risk_class" = "HIGH" ] || [ "$has_blocking_finding" = "true" ] || [ "$tier1_inconclusive" = "true" ]; then
    tier2_status="$(_tier2 "$wt_dir")"
  fi
fi

# ---- 9 + 10. Verdict JSON and deterministic aggregation -------------------
verdict_word="$(finalize "$head_sha" "$tier0_status" "$tier1a_status" "$tier1b_status" "$tier2_status")"

# ---- 11. Summary ----------------------------------------------------------
echo "Review $run_id for PR #$pr_number ($head_sha): $verdict_word"
echo "Artifacts: $run_dir/"

# The EXIT trap removes the worktree. The review is recorded either way.
exit 0
