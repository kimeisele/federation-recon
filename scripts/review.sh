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
# status in per-phase artifacts. The model returns strict JSON: findings with
# severity and, for blocking findings, a verification_command that is executed
# in the worktree before the verdict is assembled. Tier 2 remains a stub
# recording "not_run" until a later PR wires escalation.

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

# ---- Constants for the review pipeline --------------------------------------

# Risk classification is a separate concern (spec: "What this does NOT
# change"). LOW here is the pre-metadata default: the classifier below only
# runs once the PR metadata has been fetched, and every path that cannot
# fetch it (python3 missing, gh failure, unresolved head or base) records
# the unresolved count as LOW rather than inventing a third state (#236).
risk_class="LOW"
# Tier artifacts record structured JSON findings. Blocking findings carry a
# verification_command that is executed in the worktree, and only findings
# whose verification confirms them can escalate to Tier 2 or reject the PR.
# Verdict aggregation stays deterministic in scripts/review-verdict.sh;
# finalize never fabricates an empty findings list.
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
REVIEW_MODEL="${REVIEW_MODEL:-deepseek-v4-flash}"
# The thinking contract belongs to the MODEL, not the route (#227): a DeepSeek
# model carries the DeepSeek thinking fields on every route, and a non-DeepSeek
# model never does. A provider swap (opencode-go, other, ...) changes the
# endpoint, not what the model at the end of the route understands, so every
# thinking decision below keys on this flag instead of REVIEW_PROVIDER.
REVIEW_MODEL_IS_DEEPSEEK=false
case "$REVIEW_MODEL" in
  deepseek*) REVIEW_MODEL_IS_DEEPSEEK=true ;;
esac
REVIEW_API_KEY="${REVIEW_API_KEY:-${DEEPSEEK_API_KEY:-}}"
REVIEW_API_BASE="${REVIEW_API_BASE:-https://api.deepseek.com}"
# Model call timeout, from docs/review-pipeline-spec-v0.md ("Model call
# timeout: 300s per call"). Overridable so a test can exercise the timeout
# path without waiting five minutes.
REVIEW_TIMEOUT="${REVIEW_TIMEOUT:-300}"
REVIEW_TIER_COMPLETION_TOKEN_CAP="${REVIEW_TIER_COMPLETION_TOKEN_CAP:-8192}"
REVIEW_RUN_COMPLETION_TOKEN_CAP="${REVIEW_RUN_COMPLETION_TOKEN_CAP:-16384}"
REVIEW_DEEPSEEK_THINKING_MODE="${REVIEW_DEEPSEEK_THINKING_MODE:-disabled}"
if [ -n "${REVIEW_REASONING_EFFORT+x}" ]; then
  REVIEW_REASONING_EFFORT_EXPLICIT=true
  REVIEW_REASONING_EFFORT_VALUE="$REVIEW_REASONING_EFFORT"
else
  REVIEW_REASONING_EFFORT_EXPLICIT=false
  REVIEW_REASONING_EFFORT_VALUE=""
fi
config_error=""
if ! [[ "$REVIEW_TIER_COMPLETION_TOKEN_CAP" =~ ^[0-9]+$ ]] || [ "$REVIEW_TIER_COMPLETION_TOKEN_CAP" -le 0 ]; then
  config_error="invalid REVIEW_TIER_COMPLETION_TOKEN_CAP"
elif ! [[ "$REVIEW_RUN_COMPLETION_TOKEN_CAP" =~ ^[0-9]+$ ]] || [ "$REVIEW_RUN_COMPLETION_TOKEN_CAP" -le 0 ]; then
  config_error="invalid REVIEW_RUN_COMPLETION_TOKEN_CAP"
elif [ "$REVIEW_RUN_COMPLETION_TOKEN_CAP" -lt "$REVIEW_TIER_COMPLETION_TOKEN_CAP" ]; then
  config_error="REVIEW_RUN_COMPLETION_TOKEN_CAP is below tier cap"
elif [ "$REVIEW_MODEL_IS_DEEPSEEK" = true ] && ! [[ "$REVIEW_DEEPSEEK_THINKING_MODE" =~ ^(enabled|disabled)$ ]]; then
  config_error="invalid REVIEW_DEEPSEEK_THINKING_MODE"
elif [ "$REVIEW_MODEL_IS_DEEPSEEK" = true ] && [ "$REVIEW_DEEPSEEK_THINKING_MODE" = "disabled" ] && [ "$REVIEW_REASONING_EFFORT_EXPLICIT" = true ]; then
  config_error="DeepSeek reasoning effort requires enabled thinking mode"
elif [ "$REVIEW_MODEL_IS_DEEPSEEK" = true ] && [ "$REVIEW_DEEPSEEK_THINKING_MODE" = "enabled" ]; then
  if [ "$REVIEW_REASONING_EFFORT_EXPLICIT" = false ]; then
    REVIEW_REASONING_EFFORT_VALUE="high"
  elif ! [[ "$REVIEW_REASONING_EFFORT_VALUE" =~ ^(high|max)$ ]]; then
    config_error="invalid DeepSeek REVIEW_REASONING_EFFORT"
  fi
fi
requested_total=0

# JSON output mode: the model contract (both system prompts) is strict JSON,
# and the request advertises it via response_format so the provider does not
# wrap the answer in prose or markdown fencing. The parser always expects a
# JSON object; this flag only controls whether the format hint reaches the
# provider as a schema hint on the wire.
REVIEW_JSON_MODE="${REVIEW_JSON_MODE:-1}"

# Progress output to stderr so operators can distinguish "stuck" from "working".
_review_start="$(date +%s)"
_progress() {
  local elapsed="$(( $(date +%s) - _review_start ))"
  printf '[review %s] %3ds  %s\n' "$run_id" "$elapsed" "$*" >&2
}

# _write_tier_error <task> <artifact-path> <message> — record a failed tier as
# an "error" artifact. The runner's contract is "exit 0 always": a failed
# model call is a PARTIAL review, never a crash.
_write_tier_error() {
  local task="$1" artifact_path="$2" message="$3"
  python3 - "$run_id" "$task" "$artifact_path" "$message" "${_current_requested_tokens:-null}" "$REVIEW_PROVIDER" "$REVIEW_MODEL" "$REVIEW_DEEPSEEK_THINKING_MODE" "$REVIEW_REASONING_EFFORT_VALUE" "$REVIEW_MODEL_IS_DEEPSEEK" <<'PYEOF'
import json, sys

run_id, task, path, message, requested, provider, requested_model, thinking_mode, effort, model_is_deepseek = sys.argv[1:11]
artifact = {
    "run_id": run_id,
    "task": task,
    "status": "error",
    "error": message,
    "requested_max_tokens": None if requested == "null" else int(requested),
    "provider": provider,
    "requested_model": requested_model,
    "response_model": None,
    "thinking_mode": thinking_mode if model_is_deepseek == "true" else None,
    "reasoning_effort": effort or None,
    "timing": {"prompt_tokens": None, "completion_tokens": None, "reasoning_tokens": None, "finish_reason": None},
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
  local reserved_total
  reserved_total="$(python3 - "$run_dir" <<'PYEOF'
import glob, json, sys
total = 0
for path in glob.glob(sys.argv[1] + "/*.request.json"):
    try:
        total += int(json.load(open(path)).get("max_tokens", 0))
    except Exception:
        pass
print(total)
PYEOF
)"
  local remaining=$((REVIEW_RUN_COMPLETION_TOKEN_CAP - reserved_total))
  if [ "$remaining" -le 0 ]; then
    python3 - "$run_id" "$task" "$artifact_path" <<'PYEOF'
import json, sys
json.dump({"run_id": sys.argv[1], "task": sys.argv[2], "status": "not_run", "reason": "run completion cap exhausted"}, open(sys.argv[3], "w"), indent=2)
PYEOF
    printf 'not_run'
    return 0
  fi
  _current_requested_tokens=$((remaining < REVIEW_TIER_COMPLETION_TOKEN_CAP ? remaining : REVIEW_TIER_COMPLETION_TOKEN_CAP))
  requested_total=$((requested_total + _current_requested_tokens))

  if ! python3 - "$request_file" "$system_file" "$user_file" "$REVIEW_MODEL" "$REVIEW_JSON_MODE" "$_current_requested_tokens" "$REVIEW_PROVIDER" "$REVIEW_REASONING_EFFORT_VALUE" "$REVIEW_REASONING_EFFORT_EXPLICIT" "$REVIEW_DEEPSEEK_THINKING_MODE" "$REVIEW_MODEL_IS_DEEPSEEK" <<'PYEOF'; then
import json, sys

request_path, system_path, user_path, model, json_mode, max_tokens, provider, effort, effort_explicit, thinking_mode, model_is_deepseek = sys.argv[1:12]
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
if json_mode == "1":
    payload["response_format"] = {"type": "json_object"}
payload["max_tokens"] = int(max_tokens)
# The thinking fields belong to the model, not the route (#227): a DeepSeek
# model gets them on every provider, a non-DeepSeek model never does, and an
# explicitly requested reasoning effort passes through to non-DeepSeek models.
if model_is_deepseek == "true" and thinking_mode == "disabled":
    payload["thinking"] = {"type": "disabled"}
elif model_is_deepseek == "true":
    payload["thinking"] = {"type": "enabled"}
    payload["reasoning_effort"] = effort
elif effort_explicit == "true":
    payload["reasoning_effort"] = effort
with open(request_path, "w") as handle:
    json.dump(payload, handle, indent=2)
PYEOF
    _write_tier_error "$task" "$artifact_path" "request build failed"
    printf 'error'
    return 0
  fi

  local call_start call_end elapsed_seconds
  call_start="$(date +%s)"
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
  call_end="$(date +%s)"
  elapsed_seconds="$((call_end - call_start))"

  if ! python3 - "$run_id" "$task" "$stem" "$REVIEW_PROVIDER" "$run_dir" "$elapsed_seconds" "$REVIEW_MODEL" "$_current_requested_tokens" "$REVIEW_REASONING_EFFORT_VALUE" "$REVIEW_DEEPSEEK_THINKING_MODE" "$REVIEW_MODEL_IS_DEEPSEEK" <<'PYEOF'; then
import json, os, sys

run_id, task, stem, provider, run_dir = sys.argv[1:6]
elapsed_seconds = int(sys.argv[6]) if len(sys.argv) > 6 else None
requested_model, requested_max_tokens, requested_effort, thinking_mode, model_is_deepseek = sys.argv[7:12]
response_path = os.path.join(run_dir, stem + ".response.json")
artifact_path = os.path.join(run_dir, stem + ".json")

# A response that is not a chat completion (an API error, a timeout body, a
# redirect page) carries no model field; nothing can be attributed or
# recorded, so the tier is an error, not a silent success.
response = {}
try:
    with open(response_path) as handle:
        response = json.load(handle)
    model = response["model"]
    content = response["choices"][0]["message"]["content"]
    finish_reason = response["choices"][0].get("finish_reason")
except Exception as exc:
    artifact = {"run_id": run_id, "task": task, "status": "error", "error": "unparseable response: %s" % exc,
                "provider": provider, "requested_model": requested_model, "response_model": response.get("model"),
                "requested_max_tokens": int(requested_max_tokens), "thinking_mode": thinking_mode if model_is_deepseek == "true" else None, "reasoning_effort": requested_effort or None,
                "timing": {"elapsed_seconds": elapsed_seconds, "prompt_tokens": response.get("usage", {}).get("prompt_tokens"),
                            "completion_tokens": response.get("usage", {}).get("completion_tokens"),
                            "reasoning_tokens": response.get("usage", {}).get("completion_tokens_details", {}).get("reasoning_tokens"),
                            "finish_reason": response.get("choices", [{}])[0].get("finish_reason") if response.get("choices") else None}}
    json.dump(artifact, open(artifact_path, "w"), indent=2); open(artifact_path, "a").write("\n")
    sys.exit(1)

# A "length" finish_reason means the completion was cut off: the model
# stopped mid-JSON. Half an object is neither parsable nor trustworthy, so
# the tier is an error, never an empty-findings approval. A provider-reported
# completion count at or above the requested cap is also fail-closed: the
# request-side cap remains the hard reservation, while this guards against
# accepting a response that reports using the entire reserved allowance.
if finish_reason == "length":
    error = "truncated response (finish_reason: length)"
else:
    error = None

usage = response.get("usage", {})
completion_tokens = usage.get("completion_tokens")
if error is None and type(completion_tokens) is int and completion_tokens >= int(requested_max_tokens):
    error = "completion usage reached requested maximum (completion_tokens: %d, requested_max_tokens: %s)" % (completion_tokens, requested_max_tokens)

# The model contract (system prompt) is strict JSON: a JSON object with
# "findings" and "commentary". Anything else is a contract violation and an
# error, NOT empty findings — a model that stopped following the format
# decided nothing. The parsed object is preserved as response_json.
try:
    parsed = json.loads(content)
    if not isinstance(parsed, dict):
        raise ValueError("content is not a JSON object")
    findings = parsed.get("findings", [])
    if not isinstance(findings, list):
        raise ValueError("findings field is not a list")
except Exception as exc:
    if error is None:
        error = "non-JSON content: %s" % exc

if error:
    artifact = {"run_id": run_id, "task": task, "status": "error", "error": error,
                "provider": provider, "requested_model": requested_model, "response_model": model,
                "requested_max_tokens": int(requested_max_tokens), "thinking_mode": thinking_mode if model_is_deepseek == "true" else None, "reasoning_effort": requested_effort or None,
                "timing": {"elapsed_seconds": elapsed_seconds, "prompt_tokens": usage.get("prompt_tokens"),
                            "completion_tokens": usage.get("completion_tokens"), "reasoning_tokens": usage.get("completion_tokens_details", {}).get("reasoning_tokens"),
                            "finish_reason": finish_reason}}
    json.dump(artifact, open(artifact_path, "w"), indent=2); open(artifact_path, "a").write("\n")
    sys.exit(1)

artifact = {
    "run_id": run_id,
    "task": task,
    "status": "complete",
    "model": model,
    "requested_model": requested_model,
    "provider": provider,
    "response_model": model,
    "requested_max_tokens": int(requested_max_tokens),
    "thinking_mode": thinking_mode if model_is_deepseek == "true" else None,
    "reasoning_effort": requested_effort or None,
    "findings": findings,
    "commentary": parsed.get("commentary", ""),
    "response_json": parsed,
    "timing": {
        "elapsed_seconds": elapsed_seconds,
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "reasoning_tokens": usage.get("completion_tokens_details", {}).get("reasoning_tokens"),
        "finish_reason": finish_reason,
    },
}

with open(artifact_path, "w") as handle:
    json.dump(artifact, handle, indent=2)
    handle.write("\n")
PYEOF
    if [ ! -e "$artifact_path" ]; then
      _write_tier_error "$task" "$artifact_path" "unparseable response from ${REVIEW_PROVIDER}"
    fi
    printf 'error'
    return 0
  fi

  printf 'complete'
}

# ---- 7.5 Finding verification ---------------------------------------------

# Blocking findings are executed in the worktree, never trusted on the model's
# word: a blocking claim without a verification_command, or one that times out
# or errors, is downgraded to non-blocking and marked inconclusive. Verified
# findings get a per-finding log (verify.<stem>.<i>.log) recording the command,
# its exit code, and stdout/stderr.
#
# Verification discriminates the head from the base (#196): the command runs
# at the head and, when it confirms the defect there, again at the base of the
# PR. A command that also passes at the base confirms nothing about this PR —
# it is tautological or predates the diff — so the finding is downgraded to
# non-blocking and marked inconclusive. Only a command that fails at the base
# proves the diff introduced the defect (confirmed). A head failure rejects
# the finding without ever running the base command.
REVIEW_VERIFY_TIMEOUT="${REVIEW_VERIFY_TIMEOUT:-30}"
REVIEW_VERIFY_MAX="${REVIEW_VERIFY_MAX:-20}"
# Verification commands run confined, never as the invoking user with the
# worktree writable (#228): run rv-20260810-004 confirmed five blocking
# findings whose commands silently rewrote the tree they were verifying.
# REVIEW_SANDBOX_BIN is the seatbelt launcher; if it is missing the review
# fails closed — nothing is verified unconfined.
REVIEW_SANDBOX_BIN="${REVIEW_SANDBOX_BIN:-/usr/bin/sandbox-exec}"

# _verify_findings <worktree> <base-worktree> — execute every blocking
# finding's verification_command in the head worktree and stamp the finding
# with its result: confirmed (exit 0 at head, non-zero at base), rejected
# (non-zero at head, base never runs), or inconclusive (downgraded). When the
# base worktree is empty the finding cannot be discriminated, so it is marked
# [base-unverified] without running anything: running only the head half
# would re-confirm the exact tautologies #196 exists to catch.
#
# Every command runs under seatbelt with the worktree readable and NOT
# writable, plus a scratch directory it may write to (same deny-default
# mechanism as core/profiles/worker.sb). One finding's command therefore
# cannot change the tree that every later finding is evaluated against, and a
# command that tries — git checkout, sed -i, printf >> — fails with the write
# instead of silently rewriting the subject. The sandbox also denies writes
# and reads outside the worktree and scratch, and denies the network. If the
# sandbox cannot be established (missing binary, broken profile, unreadable
# worktree) the review fails closed: no command runs unconfined and every
# blocking finding is marked [sandbox-unavailable] inconclusive.
_verify_findings() {
  local wt_dir="$1" base_wt_dir="${2:-}"
  for _stem in tier1a tier1b; do
    local artifact="$run_dir/${_stem}.json"
    [ -f "$artifact" ] || continue
    if ! python3 - "$artifact" "$wt_dir" "$base_wt_dir" "$run_dir" "$_stem" \
      "$REVIEW_VERIFY_TIMEOUT" "$REVIEW_VERIFY_MAX" <<'PYEOF'
import json, os, subprocess, sys

artifact_path, wt_dir, base_wt_dir, run_dir, stem = sys.argv[1:6]
timeout_s, max_cmds = int(sys.argv[6]), int(sys.argv[7])

with open(artifact_path) as fh:
    artifact = json.load(fh)

findings = artifact.get("findings", [])
cmd_count = 0

# ---- Confinement (#228) ----------------------------------------------------
# A verification command runs sandboxed: the worktree is readable and NOT
# writable, a scratch directory is the only writable place, and everything
# else — writes, reads of secrets, the network — is denied by default. If the
# sandbox cannot be established, the review fails closed: nothing runs
# unconfined, and every blocking finding is recorded inconclusive.
sandbox_bin = os.environ.get("REVIEW_SANDBOX_BIN", "/usr/bin/sandbox-exec")
sandbox_profile = os.environ.get("REVIEW_VERIFY_PROFILE", "")
sandbox_scratch = os.environ.get("REVIEW_VERIFY_SCRATCH", "")
sandbox_gitdir = os.environ.get("REVIEW_VERIFY_GITDIR", "")

confined = (
    os.path.isfile(sandbox_bin)
    and os.access(sandbox_bin, os.X_OK)
    and bool(sandbox_profile) and os.path.isfile(sandbox_profile)
    and bool(sandbox_scratch) and os.path.isdir(sandbox_scratch)
)
# Minimal environment, mirroring core/worker_exec.sh's env -i discipline: the
# sandboxed process gets nothing from the review's environment, HOME is moved
# into the scratch so git never reads the invoking user's ~/.gitconfig, and
# TMPDIR is moved in too so temp files stay writable inside the sandbox. PATH
# puts the Command Line Tools first so `git` resolves to the real CLT binary:
# the /usr/bin/git shim goes through xcrun, which tries to write a cache file
# into the user temp dir, is denied by the sandbox, and pollutes stderr with
# "Operation not permitted" even when git succeeds — the denial sniffer below
# would misread that noise as a failed command.
confine_env = {"PATH": "/Library/Developer/CommandLineTools/usr/bin:/usr/bin:/bin", "HOME": sandbox_scratch, "TMPDIR": sandbox_scratch}

def confined_argv(cwd):
    argv = [sandbox_bin, "-f", sandbox_profile,
            "-D", "WT=" + cwd, "-D", "SCRATCH=" + sandbox_scratch]
    if sandbox_gitdir:
        argv += ["-D", "GITDIR=" + sandbox_gitdir]
    argv += ["/bin/bash", "-c"]
    return argv

if confined:
    # Probe the profile once before anything runs: a sandbox that cannot even
    # start `true` must not have findings attributed to it, and the probe
    # shares the exact argv the findings will use.
    try:
        probe = subprocess.run(
            confined_argv(wt_dir) + ["true"],
            cwd=wt_dir,
            env=confine_env,
            timeout=timeout_s,
            capture_output=True,
        )
        confined = probe.returncode == 0
    except Exception:
        confined = False

if not confined:
    for i, finding in enumerate(findings):
        if not isinstance(finding, dict) or finding.get("severity") != "blocking":
            continue
        log_path = os.path.join(run_dir, "verify.%s.%d.log" % (stem, i))
        with open(log_path, "wb") as log:
            log.write(b"=== command ===\n")
            log.write(finding.get("verification_command", "").encode() + b"\n")
            log.write(b"=== confinement ===\n")
            log.write(b"sandbox unavailable; command not run\n")
        finding["claimed_severity"] = "blocking"
        finding["verification_status"] = "inconclusive"
        finding["severity"] = "non-blocking"
        finding["summary"] = "[sandbox-unavailable] " + finding.get("summary", "")
    artifact["findings"] = findings
    with open(artifact_path, "w") as fh:
        json.dump(artifact, fh, indent=2)
        fh.write("\n")
    sys.exit(0)

for i, finding in enumerate(findings):
    if not isinstance(finding, dict):
        findings[i] = {"severity": "non-blocking", "summary": "(malformed)", "verification_status": "not_run"}
        continue
    sev = finding.get("severity", "non-blocking")
    cmd = finding.get("verification_command", "")

    if sev != "blocking":
        finding["verification_status"] = "not_run"
        continue

    if not cmd or not cmd.strip():
        finding["claimed_severity"] = "blocking"
        finding["severity"] = "non-blocking"
        finding["verification_status"] = "inconclusive"
        finding["summary"] = "[unverified] " + finding.get("summary", "")
        continue

    cmd_count += 1
    if cmd_count > max_cmds:
        finding["claimed_severity"] = "blocking"
        finding["severity"] = "non-blocking"
        finding["verification_status"] = "inconclusive"
        finding["summary"] = "[unverified] " + finding.get("summary", "")
        continue

    log_path = os.path.join(run_dir, "verify.%s.%d.log" % (stem, i))
    log = open(log_path, "wb")
    log.write(b"=== command ===\n")
    log.write(cmd.encode() + b"\n")

    # Without the base revision the claim cannot be discriminated, so no
    # half-measure: do not run the head half alone and call that verification.
    if not base_wt_dir:
        log.write(b"=== base ===\n")
        log.write(b"base revision unavailable; cannot discriminate\n")
        log.close()
        finding["claimed_severity"] = "blocking"
        finding["severity"] = "non-blocking"
        finding["verification_status"] = "inconclusive"
        finding["summary"] = "[base-unverified] " + finding.get("summary", "")
        continue

    try:
        result = subprocess.run(
            confined_argv(wt_dir) + [cmd],
            cwd=wt_dir,
            env=confine_env,
            timeout=timeout_s,
            capture_output=True,
        )
        log.write(b"=== exit code (head): %d ===\n" % result.returncode)
        log.write(b"=== stdout (head) ===\n")
        log.write(result.stdout)
        log.write(b"=== stderr (head) ===\n")
        log.write(result.stderr)

        if result.returncode != 0:
            if b"Operation not permitted" in result.stderr:
                # The sandbox refused an operation the command needed, so the
                # command never ran to completion. This is not a refutation —
                # "the defect is absent" would claim more than ran. It is a
                # failed verification: the #228 property in executable form,
                # a command that tries to mutate the subject is never
                # confirmed, and a command the sandbox stopped is inconclusive.
                log.write(b"=== sandbox denial (head) ===\n")
                log.write(b"stderr reports an operation the sandbox denied; finding inconclusive\n")
                finding["claimed_severity"] = "blocking"
                finding["verification_status"] = "inconclusive"
                finding["severity"] = "non-blocking"
                finding["summary"] = "[sandbox-denied] " + finding.get("summary", "")
            else:
                # The defect is not reproduced at the head: the finding is
                # refuted and the base command never runs.
                finding["verification_status"] = "rejected"
            log.close()
            continue

        log.write(b"=== command (base) ===\n")
        log.write(cmd.encode() + b"\n")
        try:
            base_result = subprocess.run(
                confined_argv(base_wt_dir) + [cmd],
                cwd=base_wt_dir,
                env=confine_env,
                timeout=timeout_s,
                capture_output=True,
            )
            log.write(b"=== exit code (base): %d ===\n" % base_result.returncode)
            log.write(b"=== stdout (base) ===\n")
            log.write(base_result.stdout)
            log.write(b"=== stderr (base) ===\n")
            log.write(base_result.stderr)
            if base_result.returncode != 0:
                # Present at the head, absent at the base: the diff
                # introduced it.
                finding["verification_status"] = "confirmed"
            else:
                # Present at both revisions: the command discriminates
                # nothing about this PR.
                finding["claimed_severity"] = "blocking"
                finding["verification_status"] = "inconclusive"
                finding["severity"] = "non-blocking"
                finding["summary"] = "[non-discriminating] " + finding.get("summary", "")
        except subprocess.TimeoutExpired:
            log.write(b"=== base timeout ===\n")
            finding["claimed_severity"] = "blocking"
            finding["verification_status"] = "inconclusive"
            finding["severity"] = "non-blocking"
            finding["summary"] = "[base-timeout] " + finding.get("summary", "")
        except Exception as exc:
            log.write(("=== base error: %s ===\n" % exc).encode())
            finding["claimed_severity"] = "blocking"
            finding["verification_status"] = "inconclusive"
            finding["severity"] = "non-blocking"
            finding["summary"] = "[base-unverified] " + finding.get("summary", "")
        finally:
            log.close()
    except subprocess.TimeoutExpired:
        log.write(b"=== head timeout ===\n")
        log.close()
        finding["claimed_severity"] = "blocking"
        finding["verification_status"] = "inconclusive"
        finding["severity"] = "non-blocking"
        finding["summary"] = "[timeout] " + finding.get("summary", "")
    except Exception as exc:
        log.write(("=== head error: %s ===\n" % exc).encode())
        log.close()
        finding["claimed_severity"] = "blocking"
        finding["verification_status"] = "inconclusive"
        finding["severity"] = "non-blocking"
        finding["summary"] = "[error: %s] %s" % (exc, finding.get("summary", ""))

artifact["findings"] = findings
with open(artifact_path, "w") as fh:
    json.dump(artifact, fh, indent=2)
    fh.write("\n")
PYEOF
    then
      echo "WARNING: verification failed for $_stem; findings not verified" >&2
    fi
  done
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

You MUST respond with a JSON object. Your response must be valid JSON and nothing else — no markdown fencing, no preamble, no trailing text.

Return your analysis as:

{"findings":[{"question":"4c","severity":"blocking","category":"substrate-dependency","file":"scripts/review.sh","line":685,"summary":"One-sentence description of the defect","verification_command":"shell command that exits 0 if the defect is real, non-zero if not"}],"commentary":"Your full analysis text here."}

Rules:
- severity "blocking" means this defect must prevent merge. You MUST provide a verification_command for every blocking finding. A blocking claim without a command will be downgraded to non-blocking.
- severity "non-blocking" is an observation or suggestion. No verification_command needed.
- verification_command: a self-contained shell command that runs in the PR worktree and exits 0 if the defect is real, non-zero if it is not. It will be executed. Do not fake it.
- question: which adversarial-review.md question this finding addresses (1, 1b, 1c, 2, 3, 4, 4b, 4c, 5, 6, 7, 8, 9, 10, 11).
- file and line are optional but preferred.
- An empty findings array is a valid response if nothing is wrong.
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
# that worktree and the predicted outcomes. Blocking findings must carry a
# verification_command; _verify_findings executes those in the worktree after
# the call so a blocking claim is checked, not trusted.
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

You MUST respond with a JSON object. Your response must be valid JSON and nothing else — no markdown fencing, no preamble, no trailing text.

Return your analysis as:

{"findings":[{"question":"4c","severity":"blocking","category":"substrate-dependency","file":"scripts/review.sh","line":685,"summary":"One-sentence description of the defect","verification_command":"shell command that exits 0 if the defect is real, non-zero if not"}],"commentary":"Your full analysis text here."}

Rules:
- severity "blocking" means this defect must prevent merge. You MUST provide a verification_command for every blocking finding. A blocking claim without a command will be downgraded to non-blocking.
- severity "non-blocking" is an observation or suggestion. No verification_command needed.
- verification_command: a self-contained shell command that runs in the PR worktree and exits 0 if the defect is real, non-zero if it is not. It will be executed. Do not fake it.
- question: which adversarial-review.md question this finding addresses (1, 1b, 1c, 2, 3, 4, 4b, 4c, 5, 6, 7, 8, 9, 10, 11).
- file and line are optional but preferred.
- An empty findings array is a valid response if nothing is wrong.
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

_write_tier_not_run() {
  python3 - "$run_id" "$1" "$run_dir/$2.json" "$3" <<'PYEOF'
import json, sys
json.dump({"run_id": sys.argv[1], "task": sys.argv[2], "status": "not_run", "reason": sys.argv[4]}, open(sys.argv[3], "w"), indent=2)
PYEOF
}

# _tier0_status <pr-json> — derive Tier 0 from the CI status rollup that came
# in the same `gh pr view` response as the head SHA. Prints exactly one word:
#
#   pass   every check COMPLETED with conclusion SUCCESS, NEUTRAL or SKIPPED
#   fail   some check COMPLETED with conclusion FAILURE, TIMED_OUT, CANCELLED,
#          ACTION_REQUIRED or STARTUP_FAILURE — CI ran and rejected the commit
#   error  a check not yet COMPLETED, an empty/missing/unparseable rollup, or
#          a conclusion that is neither a pass nor a listed failure — nothing
#          is known, and an empty rollup is never a vacuous pass
_tier0_status() {
  printf '%s' "$1" | python3 -c '
import json, sys

PASS_CONCLUSIONS = ("SUCCESS", "NEUTRAL", "SKIPPED")
FAIL_CONCLUSIONS = ("FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE")

try:
    data = json.load(sys.stdin)
except Exception:
    print("error")
    sys.exit(0)

rollup = data.get("statusCheckRollup")
if not isinstance(rollup, list) or not rollup:
    print("error")
    sys.exit(0)

saw_pending = False
for check in rollup:
    if not isinstance(check, dict):
        print("error")
        sys.exit(0)
    conclusion = check.get("conclusion")
    if conclusion in FAIL_CONCLUSIONS:
        # Failures are scanned first: if CI ran and rejected the commit, that
        # is the strongest known signal even while another check is running.
        print("fail")
        sys.exit(0)
    if check.get("status") != "COMPLETED":
        saw_pending = True
    elif conclusion not in PASS_CONCLUSIONS:
        # COMPLETED with a conclusion that is neither a pass nor a listed
        # failure (null, missing, unknown): the state is unknown, not green.
        print("error")
        sys.exit(0)

if saw_pending:
    print("error")
else:
    print("pass")
'
}

# ---- Verdict assembly and aggregation (functions) -------------------------

# write_verdict <subject_sha> <tier0> <tier1a> <tier1b> <tier2> — assemble the
# verdict artifact via python3 so escaping cannot corrupt the JSON. Passes
# tier findings through with their severity and verification status so the
# deterministic aggregator can act on verified blocking findings.
write_verdict() {
  local subject_sha="$1" t0="$2" t1a="$3" t1b="$4" t2="$5"
  python3 - "$run_id" "$pr_number" "$subject_sha" "$risk_class" "$timestamp" \
    "$t0" "$t1a" "$t1b" "$t2" "$run_dir" "$REVIEW_TIER_COMPLETION_TOKEN_CAP" "$REVIEW_RUN_COMPLETION_TOKEN_CAP" "$requested_total" "$REVIEW_PROVIDER" "$REVIEW_DEEPSEEK_THINKING_MODE" "$REVIEW_REASONING_EFFORT_VALUE" "$config_error" "$REVIEW_MODEL_IS_DEEPSEEK" <<'PYEOF'
import json, os, sys

(run_id, pr_number, subject_sha, risk_class, timestamp,
 t0, t1a, t1b, t2, run_dir, tier_cap, run_cap, requested_total, provider, thinking_mode, effort, config_error, model_is_deepseek) = sys.argv[1:19]
out_path = os.path.join(run_dir, "verdict.json")

TIER_MAP = {
    "tier1a": {"tier": 1, "task": "review-analysis"},
    "tier1b": {"tier": 1, "task": "adversarial-execution"},
    "tier2":  {"tier": 2, "task": "tier2"},
}

findings = []
known = {"prompt_tokens": 0, "completion_tokens": 0, "reasoning_tokens": 0}
actual_usage_complete = True
for stem, meta in TIER_MAP.items():
    artifact_path = os.path.join(run_dir, stem + ".json")
    if not os.path.isfile(artifact_path):
        continue
    try:
        with open(artifact_path) as fh:
            artifact = json.load(fh)
    except Exception:
        continue
    timing = artifact.get("timing", {})
    if os.path.isfile(os.path.join(run_dir, stem + ".request.json")):
        if type(timing.get("prompt_tokens")) is not int or type(timing.get("completion_tokens")) is not int:
            actual_usage_complete = False
    for key in known:
        value = timing.get(key)
        if type(value) is int:
            known[key] += value

    for i, raw in enumerate(artifact.get("findings", []), 1):
        if not isinstance(raw, dict):
            continue
        findings.append({
            "id": "%s-%03d" % (stem, i),
            "tier": meta["tier"],
            "task": meta["task"],
            "severity": raw.get("severity", "non-blocking"),
            "summary": raw.get("summary", "(unparseable)")[:500],
            "verification_status": raw.get("verification_status", "not_run"),
        })

requested_total = 0
for path in __import__("glob").glob(os.path.join(run_dir, "*.request.json")):
    try:
        requested_total += int(json.load(open(path)).get("max_tokens", 0))
    except Exception:
        pass

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
if not config_error:
    verdict["budget"] = {
        "configured_tier_completion_token_cap": int(tier_cap),
        "configured_run_completion_token_cap": int(run_cap),
        "requested_total": int(requested_total),
        "actual_known_totals": known,
        "actual_usage_complete": actual_usage_complete,
        "thinking_mode": thinking_mode if model_is_deepseek == "true" else None,
        "reasoning_effort": effort or None,
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
#
# The head SHA, the base SHA, the CI status rollup, and the diff line counts
# come from the SAME `gh pr view` response. Fetched in separate calls they can
# straddle a push, and Tier 0 would then report a conclusion belonging to a
# commit that is not the one under review (#195). Verification also needs the
# base SHA, and it must travel with the head SHA: a base fetched later could
# belong to a different revision of the PR (#196). The risk classifier reads
# additions and deletions from this same response so the risk input is bound
# to the reviewed commit too (#236).
_progress "starting review of PR #$pr_number"
if ! pr_json="$(gh pr view "$pr_number" --json headRefOid,baseRefOid,statusCheckRollup,additions,deletions 2>"$run_dir/gh.log")"; then
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

# The response must be a JSON object carrying headRefOid. Anything else — a
# bare SHA, a redirect page, an API error body — means the review cannot
# start; it records the same unresolved PARTIAL as a gh failure.
if ! head_sha="$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    sha = json.load(sys.stdin).get("headRefOid", "")
except Exception:
    sha = ""
print(sha)
')" || [ -z "$head_sha" ]; then
  verdict_word="$(finalize "unresolved" "error" "not_run" "not_run" "not_run")"
  echo "Review $run_id for PR #$pr_number (head SHA unresolved): $verdict_word"
  echo "Artifacts: $run_dir/"
  exit 0
fi

# The base SHA must be present for verification to discriminate the head from
# the base (#196). A missing baseRefOid is a metadata resolution failure, not
# a review of the commit: the head SHA resolved, so it is recorded, but no
# finding can be verified against a base that is not there, no model call is
# made, and no worktree is created.
base_sha="$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    sha = json.load(sys.stdin).get("baseRefOid", "")
except Exception:
    sha = ""
print(sha)
')"
if [ -z "$base_sha" ]; then
  verdict_word="$(finalize "$head_sha" "error" "not_run" "not_run" "not_run")"
  echo "Review $run_id for PR #$pr_number (base SHA unresolved): $verdict_word"
  echo "Artifacts: $run_dir/"
  exit 0
fi

# ---- 3b. Risk classification from diff size --------------------------------
# Rule 6 of the aggregator — HIGH work needs Tier 2 complete — can only fire
# if risk_class is actually HIGH. The mechanical trigger (CLAUDE.md): a diff
# over 200 lines is HIGH. Additions and deletions come from the same
# `gh pr view` response as the head SHA, so the risk input is bound to the
# reviewed commit (#236). A missing or unparseable count keeps the LOW
# default: the aggregator's fail-closed behaviour covers the unresolved case,
# and a later pass can tighten it. No third state (#236).
additions="$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("additions")
except Exception:
    v = None
print(v if isinstance(v, int) else "")
')"
deletions="$(printf '%s' "$pr_json" | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin).get("deletions")
except Exception:
    v = None
print(v if isinstance(v, int) else "")
')"
if [ -n "$additions" ] && [ -n "$deletions" ]; then
  if [ $((10#$additions + 10#$deletions)) -gt 200 ]; then
    risk_class="HIGH"
  else
    risk_class="LOW"
  fi
fi
_progress "risk: $risk_class ($additions+$deletions lines)"

# ---- 4. Disposable worktree -----------------------------------------------

# Mutating checks (evasion, mutation testing, self-application) run in a
# disposable git worktree at the subject HEAD SHA; a timeout or crash
# destroys the worktree, never the primary checkout. Same pattern as
# scripts/gate.sh (the reproduce fixpoint). The path is canonicalized with
# pwd -P because macOS mktemp may return a symlinked /var/folders path while
# git resolves /private/var/folders.
wt_dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-worktree.XXXXXX")" && pwd -P)"
base_wt_dir=""

# Remove the worktrees on every exit path — pass, fail, signal — via the EXIT
# trap alone; no explicit call is needed. On INT/TERM the cleanup is followed
# by exit with 128+SIGNO: a signal-killed review must not keep running against
# a worktree it has already removed.
review_cleanup() {
  if [ -n "${verify_scratch:-}" ]; then
    rm -rf "$verify_scratch" 2>/dev/null || true
  fi
  if [ -n "${base_wt_dir:-}" ]; then
    git worktree remove --force "$base_wt_dir" 2>/dev/null || git worktree prune 2>/dev/null || true
    rm -rf "$base_wt_dir" 2>/dev/null || true
  fi
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

_progress "worktree at ${head_sha:0:12}"
if git worktree add "$wt_dir" "$head_sha" --detach --quiet 2>"$run_dir/worktree.log"; then
  # ---- 4b. Base worktree -------------------------------------------------
  # Verification discriminates the head from the base (#196): a blocking
  # finding's command runs at both revisions, and a command that also passes
  # at the base confirms nothing about this PR. The base worktree is a
  # disposable sibling of the head one, removed by the same EXIT trap. When
  # the base SHA cannot be checked out the review still completes, but every
  # blocking finding is downgraded to [base-unverified].
  base_wt_dir="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-base-worktree.XXXXXX")" && pwd -P)"
  if ! git worktree add "$base_wt_dir" "$base_sha" --detach --quiet 2>"$run_dir/base-worktree.log"; then
    rm -rf "$base_wt_dir" 2>/dev/null || true
    git worktree prune 2>/dev/null || true
    base_wt_dir=""
  fi

  # ---- 5. Tier 0 — CI status for the subject commit ----------------------
  # Tier 0 reads the CI conclusion for the exact commit under review from the
  # status rollup that came with the head SHA. It does NOT re-run
  # scripts/gate.sh locally: that re-ran a gate GitHub Actions had already run
  # green on the same commit (1997 of 2001 seconds in rv-20260809-009), and a
  # local re-derivation under operator conditions inherited the reviewer's own
  # environment (#221) and locale (#217). CI ran under controlled conditions;
  # its conclusion is the source of truth, and a broken local gate is
  # irrelevant to Tier 0.
  tier0_status="$(_tier0_status "$pr_json")"
  {
    printf 'tier0: CI status rollup for %s\n' "$head_sha"
    printf 'tier0: %s\n' "$tier0_status"
    printf '%s\n' "$pr_json"
  } > "$run_dir/tier0.log"
  _progress "tier0: $tier0_status"

  # ---- 6. Tier 1A — review analysis (model call) --------------------------
  if [ -n "$config_error" ]; then
    _write_tier_error "review-analysis" "$run_dir/tier1a.json" "$config_error"
    tier1a_status="error"
  else
    _progress "tier1a: model call starting ($REVIEW_MODEL via $REVIEW_PROVIDER)"
    tier1a_status="$(_tier1a "$wt_dir")"
    _progress "tier1a: $tier1a_status"
  fi

  # ---- 7. Tier 1B — adversarial execution (model call) --------------------
  if [ -n "$config_error" ]; then
    _write_tier_not_run "adversarial-execution" tier1b "invalid review configuration"
  elif [ "$tier1a_status" = "error" ]; then
    _write_tier_not_run "adversarial-execution" tier1b "Tier 1A error"
  else
    _progress "tier1b: model call starting"
    tier1b_status="$(_tier1b "$wt_dir")"
    _progress "tier1b: $tier1b_status"
  fi

  # ---- 7.5 Verify findings -------------------------------------------------
  # Execute every blocking finding's verification_command in the head worktree
  # and, for a command that confirms the defect there, again at the base, so
  # only discriminating findings can drive the verdict or escalation (#196).
  # Each command runs confined (#228): the worktree is read-only, a scratch
  # directory is the only writable place, and a missing sandbox fails closed —
  # nothing is verified unconfined.
  if [ "$tier1a_status" = "complete" ] || [ "$tier1b_status" = "complete" ]; then
    verify_profile="$run_dir/verify.sb"
    verify_scratch="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/review-verify-scratch.XXXXXX")" && pwd -P)"
    # The sandbox profile lets the confined git read the repository it needs:
    # a worktree keeps its object database outside itself and reaches into the
    # main repository through the gitdir file. The common git dir is the one
    # place that covers both the head and the base worktree.
    verify_gitdir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$verify_gitdir" ]; then
      verify_gitdir="$(cd "$verify_gitdir" 2>/dev/null && pwd -P || true)"
    fi
    cat > "$verify_profile" <<'SBEOF'
(version 1)
(deny default)
(import "system.sb")
(deny network*)
(allow process-fork)
(allow process-exec* (subpath "/bin"))
(allow process-exec* (subpath "/usr/bin"))
(allow process-exec* (subpath "/usr/libexec"))
(allow process-exec* (subpath "/Library/Developer/CommandLineTools"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/usr/bin"))
(allow file-read* (subpath "/usr/libexec"))
(allow file-read* (subpath "/Library/Developer/CommandLineTools"))
(allow file-read-metadata)
(allow file-read* (subpath (param "WT")))
(allow file-read* file-write* (subpath (param "SCRATCH")))
SBEOF
    if [ -n "$verify_gitdir" ]; then
      printf '(allow file-read* (subpath (param "GITDIR")))\n' >> "$verify_profile"
    fi
    export REVIEW_SANDBOX_BIN
    export REVIEW_VERIFY_PROFILE="$verify_profile"
    export REVIEW_VERIFY_SCRATCH="$verify_scratch"
    export REVIEW_VERIFY_GITDIR="$verify_gitdir"
    _progress "verification: executing finding commands"
    _verify_findings "$wt_dir" "$base_wt_dir"
    _progress "verification: complete"
  fi

  # ---- 8. Tier 2 — independent verification (stub) -----------------------
  # Escalation triggers (spec §Tier 2): risk_class HIGH, a confirmed blocking
  # finding, an inconclusive finding (unverifiable claim), or a Tier 1 error.
  for _stem in tier1a tier1b; do
    _artifact="$run_dir/${_stem}.json"
    if [ -f "$_artifact" ]; then
      _escalate="$(python3 -c "
import json
a = json.load(open('$_artifact'))
findings = a.get('findings', [])
has_confirmed = any(
    f.get('severity')=='blocking' and f.get('verification_status')=='confirmed'
    for f in findings)
has_inconclusive = any(f.get('verification_status')=='inconclusive' for f in findings)
print('yes' if has_confirmed or has_inconclusive else 'no')
" 2>/dev/null || echo no)"
      [ "$_escalate" = "yes" ] && has_blocking_finding=true
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
_progress "finalizing verdict"
verdict_word="$(finalize "$head_sha" "$tier0_status" "$tier1a_status" "$tier1b_status" "$tier2_status")"
_progress "verdict: $verdict_word"

# ---- 11. Post commit status ------------------------------------------------
# GH_TOKEN_REVIEWER posts as federation-operator; the status context
# "review-pipeline" can become a required check in branch protection.
# APPROVE → success, REJECT/PARTIAL → failure, infra error → error.
if [ -n "${GH_TOKEN_REVIEWER:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  case "$verdict_word" in
    APPROVE) _status_state="success" ;;
    REJECT)  _status_state="failure" ;;
    *)       _status_state="error"   ;;
  esac
  if ! GH_TOKEN="$GH_TOKEN_REVIEWER" gh api -X POST \
      "repos/${GITHUB_REPOSITORY}/statuses/$head_sha" \
      -f state="$_status_state" \
      -f context="review-pipeline" \
      -f description="$verdict_word ($run_id)" \
      > "$run_dir/status.log" 2>&1; then
    echo "review: WARNING — status post failed ($(tail -n1 "$run_dir/status.log" 2>/dev/null))" >&2
  fi
elif [ -z "${GITHUB_REPOSITORY:-}" ]; then
  echo "review: status not posted — GITHUB_REPOSITORY not set" >&2
fi

# ---- 12. Summary ----------------------------------------------------------
echo "Review $run_id for PR #$pr_number ($head_sha): $verdict_word"
echo "Artifacts: $run_dir/"

# The EXIT trap removes the worktree. The review is recorded either way.
exit 0
