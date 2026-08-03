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
# (docs/review-pipeline-spec-v0.md). Tier 1A and Tier 1B make one model call
# each against a swappable provider (REVIEW_* environment) and record their
# status in per-phase artifacts; Tier 2 remains a stub recording "not_run"
# until a later PR wires escalation.

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
# Tier artifacts record findings for the operator, but v0 does not wire them
# into the verdict: verdict aggregation stays deterministic (finalize always
# writes an empty findings list) and finding-driven escalation stays inert.
has_blocking_finding=false
tier1_inconclusive=false     # tiers report complete/error only, never inconclusive

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

# ---- Tier functions ---------------------------------------------------------

# Provider configuration: the provider is swappable through the environment.
# Defaults are the DeepSeek OpenAI-compatible endpoint; the key falls back to
# DEEPSEEK_API_KEY so a builder environment that already carries it works
# unchanged. The nested default is deliberate: under `set -u` a bare
# $DEEPSEEK_API_KEY inside the default would abort when neither variable is
# set.
REVIEW_PROVIDER="${REVIEW_PROVIDER:-deepseek}"
REVIEW_MODEL="${REVIEW_MODEL:-deepseek-chat}"
REVIEW_API_KEY="${REVIEW_API_KEY:-${DEEPSEEK_API_KEY:-}}"
REVIEW_API_BASE="${REVIEW_API_BASE:-https://api.deepseek.com}"
# Model call timeout, from docs/review-pipeline-spec-v0.md ("Model call
# timeout: 300s per call"). Overridable so a test can exercise the timeout
# path without waiting five minutes.
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-300}"

# _write_tier_error <task> <artifact-path> <message> — record a failed tier as
# an "error" artifact. The runner's contract is "exit 0 always": a failed
# model call is a PARTIAL review, never a crash.
_write_tier_error() {
  local task="$1" artifact_path="$2" message="$3"
  python3 - "$run_id" "$task" "$artifact_path" "$message" <<'PYEOF'
import json, sys

run_id, task, path, message = sys.argv[1:5]
artifact = {
    "run_id": run_id,
    "task": task,
    "status": "error",
    "error": message,
}
with open(path, "w") as handle:
    json.dump(artifact, handle, indent=2)
    handle.write("\n")
PYEOF
}

# _tier_call <task> <stem> <system-prompt-file> <user-message-file> — one model
# call. Builds the request JSON, runs curl against the configured provider,
# then assembles the tier artifact from the response. Prints "complete" on
# success, "error" on failure; both paths exit 0 so a failed call is recorded,
# never a crash.
_tier_call() {
  local task="$1" stem="$2" system_file="$3" user_file="$4"
  local request_file="$run_dir/${stem}.request.json"
  local response_file="$run_dir/${stem}.response.json"
  local curl_log="$run_dir/${stem}.curl.log"
  local artifact_path="$run_dir/${stem}.json"

  if ! python3 - "$request_file" "$system_file" "$user_file" "$REVIEW_MODEL" <<'PYEOF'; then
import json, sys

request_path, system_path, user_path, model = sys.argv[1:5]
with open(system_path) as handle:
    system = handle.read()
with open(user_path) as handle:
    user = handle.read()
payload = {
    "model": model,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ],
}
with open(request_path, "w") as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    _write_tier_error "$task" "$artifact_path" "request build failed"
    printf 'error'
    return 0
  fi

  if ! curl --silent --show-error --max-time "$REVIEW_TIMEOUT" \
      --request POST \
      --url "${REVIEW_API_BASE}/v1/chat/completions" \
      --header "Authorization: Bearer ${REVIEW_API_KEY}" \
      --header "Content-Type: application/json" \
      --data "@$request_file" > "$response_file" 2>"$curl_log"; then
    _write_tier_error "$task" "$artifact_path" \
      "curl failed: $(tail -n1 "$curl_log" 2>/dev/null || true)"
    printf 'error'
    return 0
  fi

  if ! python3 - "$run_id" "$task" "$stem" "$REVIEW_PROVIDER" "$run_dir" <<'PYEOF'; then
import json, os, re, sys

run_id, task, stem, provider, run_dir = sys.argv[1:6]
response_path = os.path.join(run_dir, stem + ".response.json")
artifact_path = os.path.join(run_dir, stem + ".json")

# A response that is not a chat completion (an API error, a timeout body, a
# redirect page) carries no model field; nothing can be attributed or
# recorded, so the tier is an error, not a silent success.
try:
    with open(response_path) as handle:
        response = json.load(handle)
    model = response["model"]
    content = response["choices"][0]["message"]["content"]
except Exception as exc:
    sys.stderr.write("review: unparseable %s response: %s\n" % (stem, exc))
    sys.exit(1)

# Findings extraction, best effort: numbered lines in the report are the
# findings, and a closing "verdict: APPROVE|REJECT" line is the direction the
# model chose. This is a record for the operator, not the verdict — the
# deterministic aggregator (scripts/review-verdict.sh) remains the only
# authority on the verdict word. A parsing hiccup must never crash the
# runner: unparseable content yields an empty findings array, not a failure.
findings = []
verdict_line = None
for line in content.splitlines():
    stripped = line.strip()
    m = re.match(r"^(\*\*)?verdict:\s*(approve|reject)(\*\*)?\s*$", stripped, re.IGNORECASE)
    if m:
        verdict_line = m.group(2).upper()
        continue
    # Headings ("## 1. ...") are structure, not findings.
    if re.match(r"^#{1,6}\s", stripped):
        continue
    # Numbered findings look like "1. ...", "2b. ...", "**2b. ...**".
    if re.match(r"^(\*\*)?\d{1,3}[a-z]?\.(\*\*)?\s", stripped):
        findings.append({"summary": stripped})

artifact = {
    "run_id": run_id,
    "task": task,
    "status": "complete",
    # Model provenance: the model field from the API RESPONSE, not the
    # requested REVIEW_MODEL. Future verification that the reviewer differs
    # from the builder reads this. Bootstrapping records only; no enforcement.
    "model": model,
    "provider": provider,
    "response_text": content,
    "findings": findings,
}
if verdict_line is not None:
    artifact["verdict_line"] = verdict_line

with open(artifact_path, "w") as handle:
    json.dump(artifact, handle, indent=2)
    handle.write("\n")
PYEOF
    _write_tier_error "$task" "$artifact_path" "unparseable response from ${REVIEW_PROVIDER}"
    printf 'error'
    return 0
  fi

  printf 'complete'
}

# The system prompts embed the questions they cover, quoted from
# governance/adversarial-review.md, so a review is reproducible: the same
# script version asks the same questions. The quotes are deliberately taken
# from the committed template rather than re-summarized — a prompt that
# re-declares a question in its own words can drift from the template while
# looking identical.

# _tier1a <worktree> — Tier 1A review analysis (read-only model call): the
# questions from governance/adversarial-review.md that need no code
# execution — intent vs implementation (Q4, Q7), claims vs evidence (Q1c,
# Q4b, Q4c), environment and workflows (Q2), failure modes (Q5, Q6),
# completeness (Q8), prior-round conditions (Q10, follow-up rounds only) and
# the general hazard sweep (Q11). The <worktree> argument is accepted for
# signature uniformity with _tier1b and unused: Tier 1A reads only the diff
# and the PR description.
_tier1a() {
  local stem="tier1a"
  local system_file="$run_dir/${stem}.system.txt"
  local user_file="$run_dir/${stem}.user.txt"
  local diff_file="$run_dir/${stem}.diff.txt"
  local body_file="$run_dir/${stem}.body.txt"
  local gh_log="$run_dir/${stem}.gh.log"

  if ! gh pr diff "$pr_number" > "$diff_file" 2>"$gh_log"; then
    _write_tier_error "review-analysis" "$run_dir/${stem}.json" \
      "gh pr diff failed: $(tail -n1 "$gh_log" 2>/dev/null || true)"
    printf 'error'
    return 0
  fi
  if ! gh pr view "$pr_number" --json body --jq '.body' > "$body_file" 2>>"$gh_log"; then
    _write_tier_error "review-analysis" "$run_dir/${stem}.json" \
      "gh pr view failed: $(tail -n1 "$gh_log" 2>/dev/null || true)"
    printf 'error'
    return 0
  fi

  cat > "$system_file" <<'PROMPT'
You are an independent red-team reviewer. You answer the READ-ONLY half of the
standing adversarial review template in governance/adversarial-review.md: the
questions that can be answered from the diff and the PR description without
executing anything. Do not modify any file.

Read CLAUDE.md and docs/operator-lessons.md before judging anything. The
change under review is the diff and description in the user message. It was
written by an AI operator or a builder it dispatched.

Answer these, in order of how much they matter:

**1c. Are the author's factual claims true?** Check every factual claim in the
PR description, the commit messages and any committed review artifact against
the repository, the data and the CI logs. This repository has shipped a PR whose
description asserted "CI rejects any PR..." while the gate never fired in CI, and
a remediation claim of "re-run live" that a timestamp disproved. Verifying the
mechanism is not verifying the author.

**2. Does it fire in the environment it was built for?** Local success is weak
evidence. For anything touching CI: does it run under a detached HEAD, a shallow
clone, an absent environment variable, a missing binary? Check the workflow
files, not the intent. A gate untested under real runner conditions is a prop.

**4. What does it prove, versus what does it claim?** State the gap plainly.
Overclaiming is worse than the underlying weakness, because it invites trust the
mechanism cannot carry. If the honest claim is much weaker than the apparent
one, the documentation must say so.

**4b. Do the change's factual premises hold?** Do not accept the premises the
change is built on. Recompute them. Open the data and read the outliers — the
single most damaging finding in this repository's history came from refusing the
claim "`correlation_id` is empty in all 9,874 messages", counting for oneself,
getting 9,873, and reading the one exception. A count is not a reading. Right
value and working instrument are different properties, and a mechanism can
report the correct number today while being incapable of reporting any other.

**4c. Read the substrate, not only the diff.** Most material findings here have
been in *unchanged* code the change newly depends on: an outbox cleared on
partial push, nonce state that dies with the process, a required field silently
backfilled, a scheduled job that never runs the new procedure. Read everything
the diff calls, everything meant to call the diff, the workflow files, and the
data it will run against. A diff-scoped review answers "how do you defeat this"
about new code and never learns it stands on sand.

**5. Which failure mode looks like success?** Find the paths where an error, an
absence or a missing dependency produces a plausible value instead of a refusal.
`|| true`, silent fallbacks, empty-result-on-error, defaults that fill in for
missing data. Each is a place where "it worked" and "it could not run" are
indistinguishable.

**6. What would nobody notice during a long unattended session?** No human is
watching. What accumulates, drifts, or silently degrades?

**7. Is this the right thing, not merely a correct thing?** A change can be
well-tested, fire in CI, be mutation-hardened and honestly documented — and still
entrench a bad interface, solve a problem nobody has, add an unsustainable
dependency, or ratchet the operator's authority. Every question above is
verification-shaped, because every defect that motivated them was. This one is
not. Answer it deliberately rather than letting it fall into "anything else".

**8. What is missing?** A diff shows what was added; it is structurally blind to
what was left out. The absent scheduled job, the absent positive control, the
absent question in a checklist. Ask what a complete version of this change would
contain that this one does not.

**10. If this is a follow-up round, were the prior conditions literally met?**
Quote each numbered condition from the previous review and state whether it was
satisfied in substance and in letter. Verifying the fix is the second half of
rejecting. If this is not a follow-up round, state that and move on.

**11. Anything else materially wrong or dangerous.**

Be blunt. Recommend rejection if warranted. A rubber-stamp review is worse than
no review, because it manufactures the appearance of a check.

If you approve **with conditions**, return `verdict: REJECT` and list them.
An `APPROVE` carrying unmet blocking conditions has already been merged past
once in this repository, because the reader stopped at the verdict line.

End with a line reading exactly `verdict: APPROVE` or `verdict: REJECT`.
PROMPT

  {
    printf '# PR #%s — Tier 1A: review analysis (read-only)\n\n' "$pr_number"
    printf '## PR description\n\n'
    cat "$body_file"
    printf '\n\n## PR diff\n\n'
    cat "$diff_file"
    printf '\n'
  } > "$user_file"

  _tier_call "review-analysis" "$stem" "$system_file" "$user_file"
}

# _tier1b <worktree> — Tier 1B adversarial execution (checkout analysis): the
# questions from governance/adversarial-review.md that demand executed
# evasions and run mutations — evasion attempts (Q1, Q1b), mutation testing
# (Q3) and self-application (Q9).
#
# IMPORTANT: the model call does NOT get shell access. The worktree path and
# file listing are shown, and the model returns the commands it WOULD run in
# that worktree and the predicted outcomes. Actual execution is a future
# enhancement; the artifact records the plan, not a claim that anything ran.
_tier1b() {
  local wt_dir="$1"
  local stem="tier1b"
  local system_file="$run_dir/${stem}.system.txt"
  local user_file="$run_dir/${stem}.user.txt"
  local diff_file="$run_dir/${stem}.diff.txt"
  local listing_file="$run_dir/${stem}.files.txt"
  local gh_log="$run_dir/${stem}.gh.log"

  if ! gh pr diff "$pr_number" > "$diff_file" 2>"$gh_log"; then
    _write_tier_error "adversarial-execution" "$run_dir/${stem}.json" \
      "gh pr diff failed: $(tail -n1 "$gh_log" 2>/dev/null || true)"
    printf 'error'
    return 0
  fi
  if ! ( cd "$wt_dir" && git ls-files ) > "$listing_file" 2>>"$gh_log"; then
    _write_tier_error "adversarial-execution" "$run_dir/${stem}.json" \
      "worktree listing failed: $(tail -n1 "$gh_log" 2>/dev/null || true)"
    printf 'error'
    return 0
  fi

  cat > "$system_file" <<'PROMPT'
You are an independent red-team reviewer. You answer the EXECUTING half of the
standing adversarial review template in governance/adversarial-review.md: the
questions that demand executed evasions and run mutations.

You do NOT have shell access in this mode. A disposable git worktree at the PR
head commit is described in the user message (path and file listing). Return a
structured analysis: for every command you WOULD run in that worktree, give the
exact command, the predicted outcome, and the conclusion you would draw.
Actual execution is a future enhancement; your report is the plan of attack
with execution intent, not a claim that the commands ran. Label every command
whose execution is load-bearing for your conclusion, so an executing runner
knows what must run before your verdict can be trusted.

Read CLAUDE.md and docs/operator-lessons.md before judging anything. The
change under review is the diff in the user message. It was written by an AI
operator or a builder it dispatched.

Answer these, in order of how much they matter:

**1. How do you defeat this?** Not "is it correct" — assume a motivated party who
wants the outcome the mechanism forbids. Enumerate the cheapest evasions. Give
the exact command you would run in the worktree to demonstrate each, and how
long it would take. An evasion you can demonstrate is worth more than five you
imagined.

**1b. Is the diff itself the attack?** Question 1 points outward at a
hypothetical attacker. Point it at the author too: does this change weaken,
narrow, bypass or delete any existing check — an added `|| true`, a narrowed
trigger path, a test removed as "flaky", a widened permission, a file list that
quietly omits one entry? Does the author benefit from that? The most probable
self-interested change is not a bad new mechanism; it is a small loosening of an
existing one.

**3. Which of its checks are untested?** Break each check in turn and confirm the
suite goes red. Any check whose removal leaves the tests green is not tested,
whatever the coverage says. Give the exact mutation command for each check and
the test invocation that must go red. If a test re-declares a pattern, constant
or command line that production also declares, it passes when production breaks —
say so.

**9. Run the new mechanism against the change that introduces it.** One command,
outsized hit rate: this repository shipped a gate that failed its own PR. If the
change adds a check, give the exact command to execute it against its own diff.

Be blunt. Recommend rejection if warranted. A rubber-stamp review is worse than
no review, because it manufactures the appearance of a check.

If you approve **with conditions**, return `verdict: REJECT` and list them.
An `APPROVE` carrying unmet blocking conditions has already been merged past
once in this repository, because the reader stopped at the verdict line.

End with a line reading exactly `verdict: APPROVE` or `verdict: REJECT`.
PROMPT

  {
    printf '# PR #%s — Tier 1B: adversarial execution analysis (checkout mode)\n\n' "$pr_number"
    printf '## Worktree\n\n'
    printf 'A disposable git worktree at the PR head commit exists at:\n\n    %s\n\n' "$wt_dir"
    printf '## Worktree file listing\n\n'
    cat "$listing_file"
    printf '\n\n## PR diff\n\n'
    cat "$diff_file"
    printf '\n'
  } > "$user_file"

  _tier_call "adversarial-execution" "$stem" "$system_file" "$user_file"
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
# verdict artifact via python3 so escaping cannot corrupt the JSON. Collects
# findings from tier artifacts and promotes verdict_line: REJECT to a blocking
# finding so the aggregator can act on it.
write_verdict() {
  local subject_sha="$1" t0="$2" t1a="$3" t1b="$4" t2="$5"
  python3 - "$run_id" "$pr_number" "$subject_sha" "$risk_class" "$timestamp" \
    "$t0" "$t1a" "$t1b" "$t2" "$run_dir" <<'PYEOF'
import json, os, sys

(run_id, pr_number, subject_sha, risk_class, timestamp,
 t0, t1a, t1b, t2, run_dir) = sys.argv[1:11]
out_path = os.path.join(run_dir, "verdict.json")

TIER_MAP = {
    "tier1a": {"tier": 1, "task": "review-analysis"},
    "tier1b": {"tier": 1, "task": "adversarial-execution"},
    "tier2":  {"tier": 2, "task": "tier2"},
}

findings = []
for stem, meta in TIER_MAP.items():
    artifact_path = os.path.join(run_dir, stem + ".json")
    if not os.path.isfile(artifact_path):
        continue
    try:
        with open(artifact_path) as fh:
            artifact = json.load(fh)
    except Exception:
        continue

    if artifact.get("verdict_line") == "REJECT":
        findings.append({
            "id": "%s-verdict" % stem,
            "tier": meta["tier"],
            "task": meta["task"],
            "severity": "blocking",
            "summary": "reviewer returned verdict: REJECT",
            "verification_status": "confirmed",
        })

    for i, raw in enumerate(artifact.get("findings", []), 1):
        findings.append({
            "id": "%s-%03d" % (stem, i),
            "tier": meta["tier"],
            "task": meta["task"],
            "severity": "non-blocking",
            "summary": raw.get("summary", "(unparseable)")[:500],
            "verification_status": "not_run",
        })

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
    "findings": findings,
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

  # ---- 6. Tier 1A — review analysis (model call) --------------------------
  tier1a_status="$(_tier1a "$wt_dir")"

  # ---- 7. Tier 1B — adversarial execution (model call) --------------------
  tier1b_status="$(_tier1b "$wt_dir")"

  # ---- 8. Tier 2 — independent verification (stub) -----------------------
  # Escalation triggers (spec §Tier 2): risk_class HIGH, a blocking finding
  # (verdict_line REJECT from Tier 1), or an inconclusive Tier 1 (error).
  for _stem in tier1a tier1b; do
    _artifact="$run_dir/${_stem}.json"
    if [ -f "$_artifact" ]; then
      _vl="$(python3 -c "import json; print(json.load(open('$_artifact')).get('verdict_line',''))" 2>/dev/null || true)"
      [ "$_vl" = "REJECT" ] && has_blocking_finding=true
    fi
  done
  if [ "$tier1a_status" = "error" ] || [ "$tier1b_status" = "error" ]; then
    tier1_inconclusive=true
  fi
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
