#!/usr/bin/env bash
# jcode.sh — Real jcode builder for Slice 1b.
#
# Invoked as: jcode.sh <worktree_path>
# Reads $WORK_ORDER from the environment (merged in #96).
#
# Writes its report as JSON to stdout: {"outcome": "...", "files_changed": [...]}
# Cost evidence (raw jcode usage before/after) goes to $RUN_DIR/builder_usage.txt
# if RUN_DIR is set (preferred but not guaranteed), otherwise a temp directory.
# JCODE_SCRATCH_DIR is set to a directory outside the worktree before invoking
# jcode; temp scratch and usage dirs are cleaned up on exit.
#
# bash 3.2, python3, and git only. No jq.
set -o errexit -o nounset -o pipefail

WORKTREE="${1:-}"
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 1. Read the work order
# -----------------------------------------------------------------
if [ -z "${WORK_ORDER:-}" ] || [ ! -f "$WORK_ORDER" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# Parse work order fields with python3
WO_DATA=$(python3 -c "
import json
wo = json.load(open('$WORK_ORDER'))
print(json.dumps({
    'issue': wo['issue'],
    'allowed': ' '.join(wo['allowed_paths']),
    'forbidden': ' '.join(wo['forbidden_paths']),
    'acceptance': '; '.join(wo['acceptance_commands'])
}))
" 2>/dev/null) || {
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
}

ISSUE=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['issue'])" 2>/dev/null)
ALLOWED=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['allowed'])" 2>/dev/null)
FORBIDDEN=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['forbidden'])" 2>/dev/null)
ACCEPTANCE=$(python3 -c "import json; print(json.loads('''$WO_DATA''')['acceptance'])" 2>/dev/null)

# -----------------------------------------------------------------
# 2. Set up directories outside the worktree
# -----------------------------------------------------------------
# RUN_DIR is preferred but not guaranteed; fall back to temp dirs.
if [ -n "${RUN_DIR:-}" ]; then
  SCRATCH_DIR="$RUN_DIR/builder-scratch"
  USAGE_FILE="$RUN_DIR/builder_usage.txt"
else
  SCRATCH_DIR="$(mktemp -d)"
  USAGE_DIR="$(mktemp -d)"
  USAGE_FILE="$USAGE_DIR/builder_usage.txt"
fi
mkdir -p "$SCRATCH_DIR"
export JCODE_SCRATCH_DIR="$SCRATCH_DIR"

# Cleanup trap — only remove temp dirs we own (not RUN_DIR-managed ones)
_cleanup_builder() {
  if [ -z "${RUN_DIR:-}" ]; then
    rm -rf "$SCRATCH_DIR" 2>/dev/null || true
    rm -rf "${USAGE_DIR:-}" 2>/dev/null || true
  fi
}
trap _cleanup_builder EXIT

# -----------------------------------------------------------------
# 3. Build the prompt
# -----------------------------------------------------------------
PROMPT="You are working on issue #${ISSUE} in this repository.

You may only modify files under these paths: ${ALLOWED}

PROHIBITION: You must NOT modify any files under these paths: ${FORBIDDEN}
Do not create, edit, or delete anything under a forbidden path for any reason.
If the task requires touching a forbidden path, stop and report failure — do not proceed.

After completing your changes, run these acceptance commands from the repository root to verify your work:
${ACCEPTANCE}

Complete the task described by the issue."

# -----------------------------------------------------------------
# 4. Provider
# -----------------------------------------------------------------
# Two routing contracts, chosen by JCODE_PROVIDER_PROFILE (#167):
#
#   - profile set: select a named OpenAI-compatible profile and model with
#     global jcode flags; the probe verifies its endpoint and model;
#   - profile unset: retain the legacy explicit provider/model flags.
#
# This used to set JCODE_PROVIDER as an environment variable and pass no model
# at all. Measured on 2026-07-31: `jcode run` does not read those variables,
# and with no -m it uses [provider] default_model from ~/.jcode/config.toml.
# That default now names the REVIEWER model, because an OAuth provider has to
# be the default for -p/-m to be honoured at all (governance/reviewers.md).
# So the old line would have built with the model meant to review the build.
PROFILE="${JCODE_PROVIDER_PROFILE:-}"
PROVIDER="${JCODE_PROVIDER:-deepseek}"
MODEL="${JCODE_MODEL:-deepseek-v4-flash}"

if [ -n "$PROFILE" ] && [ -z "${JCODE_EXPECTED_ENDPOINT:-}" ]; then
  echo "jcode.sh: profile selected without JCODE_EXPECTED_ENDPOINT — refusing unverified build." >&2
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 4b. Establish which provider will actually serve — BEFORE building
# -----------------------------------------------------------------
#
# `-p deepseek -m deepseek-v4-flash` was served by OpenRouter for all 399
# lines of Slice 1b's run wo-126-2, and `jcode provider current -p deepseek`
# reports `resolved_provider DeepSeek` — the tool's own resolver disagrees
# with its runtime, so the resolver is not evidence and the log is. See #159.
#
# The probe costs one call with a one-word prompt. There is no zero-token way
# to learn this, and paying it before the build is cheaper than discovering
# afterwards that the build was billed somewhere nobody chose.
#
# A mismatch ABORTS. Silent substitution of the provider is the same failure
# class as a base ref quietly falling back to another branch: the thing being
# compared, or paid for, is not the thing that was named.
PROBE_DIR="$(dirname "$0")"
PROVIDER_RECORD="${RUN_DIR:-$SCRATCH_DIR}/builder_provider.txt"
mkdir -p "$(dirname "$PROVIDER_RECORD")" 2>/dev/null || true

if [ -x "$PROBE_DIR/provider-probe.sh" ]; then
  PROBE_REQUEST="${PROFILE:-$PROVIDER}"
  if ! "$PROBE_DIR/provider-probe.sh" "$PROBE_REQUEST" "$MODEL" \
        "$PROVIDER_RECORD" "${BUILDER_PROBE_TIMEOUT:-180}" >/dev/null; then
    echo "jcode.sh: provider unverified or substituted — refusing to build." >&2
    cat "$PROVIDER_RECORD" >&2 2>/dev/null || true
    echo '{"outcome":"failed","files_changed":[]}'
    exit 1
  fi
else
  # The probe is not optional. A missing probe and a passing probe must not
  # produce the same outcome.
  echo "jcode.sh: provider-probe.sh missing — refusing to build unverified." >&2
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 5. Usage before
# -----------------------------------------------------------------
USAGE_BEFORE=$(jcode usage 2>&1 || true)

# -----------------------------------------------------------------
# 6. Invoke jcode
# -----------------------------------------------------------------
BUILD_WINDOW_FROM="$(date -u +"%Y-%m-%d %H:%M:%S")"
BUILD_OUTPUT_FILE="$(dirname "$USAGE_FILE")/builder_jcode_output.txt"
set +o errexit
if [ -n "$PROFILE" ]; then
  jcode --provider-profile "$PROFILE" --model "$MODEL" --quiet --no-update \
    -C "$WORKTREE" run "$PROMPT" >"$BUILD_OUTPUT_FILE" 2>&1
else
  jcode run -p "$PROVIDER" -m "$MODEL" --quiet -C "$WORKTREE" "$PROMPT" \
    >"$BUILD_OUTPUT_FILE" 2>&1
fi
JCODE_EXIT=$?
set -o errexit

# -----------------------------------------------------------------
# 7. Usage after
# -----------------------------------------------------------------
USAGE_AFTER=$(jcode usage 2>&1 || true)

# -----------------------------------------------------------------
# 8. Write usage files — the raw capture and the assembled record
# -----------------------------------------------------------------
mkdir -p "$(dirname "$USAGE_FILE")" 2>/dev/null || true
{
  echo "=== jcode usage BEFORE ==="
  printf '%s\n' "$USAGE_BEFORE"
  echo "=== jcode usage AFTER ==="
  printf '%s\n' "$USAGE_AFTER"
} > "$USAGE_FILE"

# The assembled record: provider, model, calls, and what could not be
# obtained, named. The runner refuses a run without it (#160).
printf '%s\n' "$USAGE_BEFORE" > "${USAGE_FILE}.before"
printf '%s\n' "$USAGE_AFTER"  > "${USAGE_FILE}.after"
if [ -x "$PROBE_DIR/usage-record.sh" ]; then
  "$PROBE_DIR/usage-record.sh" \
    "$(dirname "$USAGE_FILE")/builder_cost.txt" \
    "$BUILD_WINDOW_FROM" \
    "$PROVIDER_RECORD" \
    "${USAGE_FILE}.before" \
    "${USAGE_FILE}.after" \
    "$BUILD_OUTPUT_FILE" || true
fi

# -----------------------------------------------------------------
# 9. If jcode failed, report failure
# -----------------------------------------------------------------
if [ "$JCODE_EXIT" -ne 0 ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# -----------------------------------------------------------------
# 10. Determine what actually changed
# -----------------------------------------------------------------
CHANGED=$(git -C "$WORKTREE" status --porcelain --untracked-files=all 2>/dev/null || true)

if [ -z "$CHANGED" ]; then
  # Nothing changed — this is a failure, not a success
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

# Parse porcelain output: XY filename (status at pos 0-1, space at 2, path at 3).
# Pipe the shell-captured output into python so we never call git twice.
FILES_CHANGED=$(python3 -c "
import json, sys
lines = sys.stdin.read().strip().split('\n')
files = []
for line in lines:
    line = line.rstrip('\r')
    if not line.strip():
        continue
    # porcelain v1: XY path (status in col 0-1, space in col 2, path from col 3)
    if len(line) < 4:
        continue
    path = line[3:]
    # For renames: 'old -> new' — take the new side
    if ' -> ' in path:
        path = path.split(' -> ')[-1]
    # Strip surrounding quotes from C-style quoted paths
    path = path.strip('\"')
    files.append(path)
print(json.dumps(files) if files else '[]')
" <<< "$CHANGED" 2>/dev/null || echo "[]")

# If parsing produced nothing, that's also a failure
if [ "$FILES_CHANGED" = "[]" ] || [ -z "$FILES_CHANGED" ]; then
  echo '{"outcome":"failed","files_changed":[]}'
  exit 1
fi

python3 -c "
import json
print(json.dumps({
    'outcome': 'completed',
    'files_changed': $FILES_CHANGED
}))
"

exit 0
