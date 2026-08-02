#!/usr/bin/env bats
# Oracle for #173. The builder may implement the adapter; it may not edit this
# file. Every case drives a fake OpenCode CLI, so proving the control costs no
# token and does not depend on a configured provider.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  CONSULT="$REPO_ROOT/scripts/consult-opencode.sh"
  BIN="$BATS_TEST_TMPDIR/bin"
  OUT="$BATS_TEST_TMPDIR/review.md"
  PROMPT="$BATS_TEST_TMPDIR/prompt.md"
  SOURCE="$BATS_TEST_TMPDIR/source"
  ARGS="$BATS_TEST_TMPDIR/args"
  mkdir -p "$BIN" "$SOURCE"
  printf 'Review the change and end with a verdict.\n' > "$PROMPT"

  git -C "$SOURCE" init -q
  git -C "$SOURCE" config user.email test@example.invalid
  git -C "$SOURCE" config user.name test
  printf 'base\n' > "$SOURCE/base.txt"
  git -C "$SOURCE" add base.txt
  git -C "$SOURCE" commit -qm base

  cat > "$BIN/opencode" <<'FAKE'
#!/usr/bin/env bash
set -u
mode="${FAKE_MODE:-ok}"
case "${1:-}" in
  run)
    printf '%s\n' "$*" > "$FAKE_ARGS"
    dir=""
    shift
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--dir" ]; then dir="$2"; shift 2; else shift; fi
    done
    [ -n "$dir" ] && printf 'contained\n' > "$dir/reviewer-touch"
    printf '%s\n' '{"type":"step_start","sessionID":"ses_review_123","part":{"type":"step-start"}}'
    if [ "$mode" = run_fail ]; then
      printf '%s\n' '{"type":"text","sessionID":"ses_review_123","part":{"type":"text","text":"PARTIAL FINDING"}}'
      exit 9
    fi
    if [ "$mode" = hang ]; then
      printf '%s\n' '{"type":"text","sessionID":"ses_review_123","part":{"type":"text","text":"PARTIAL BEFORE HANG"}}'
      sleep 30
      exit 0
    fi
    if [ "$mode" = ambiguous ]; then
      printf '%s\n' '{"type":"text","sessionID":"ses_other_456","part":{"type":"text","text":"OTHER"}}'
    fi
    body='Finding: bounded review completed.\nverdict: APPROVE'
    [ "$mode" = no_verdict ] && body='Finding: bounded review completed.'
    printf '{"type":"text","sessionID":"ses_review_123","part":{"type":"text","text":"%s"}}\n' "$body"
    printf '%s\n' '{"type":"step_finish","sessionID":"ses_review_123","part":{"type":"step-finish","reason":"stop","tokens":{"total":12,"input":4,"output":8},"cost":0.25}}'
    ;;
  export)
    [ "$mode" = export_fail ] && exit 7
    provider=opencode-go
    model=qwen3.7-max
    [ "$mode" = wrong_provider ] && provider=deepseek
    [ "$mode" = wrong_model ] && model=deepseek-v4-flash
    printf '{"info":{"id":"ses_review_123","model":{"providerID":"%s","id":"%s"},"cost":0.25,"tokens":{"input":4,"output":8}},"messages":[{"info":{"role":"assistant","providerID":"%s","modelID":"%s","finish":"stop","sessionID":"ses_review_123"}}]}\n' "$provider" "$model" "$provider" "$model"
    ;;
  *) exit 64 ;;
esac
FAKE
  chmod +x "$BIN/opencode"
  export OPENCODE_BIN="$BIN/opencode" FAKE_ARGS="$ARGS"
}

teardown() {
  git -C "$SOURCE" worktree prune 2>/dev/null || true
}

run_consult() {
  run env FAKE_MODE="${1:-ok}" OPENCODE_BIN="$OPENCODE_BIN" FAKE_ARGS="$FAKE_ARGS" \
    OPENCODE_REVIEW_TIMEOUT_SECONDS="${2:-5}" \
    bash "$CONSULT" qwen3.7-max "$OUT" "$PROMPT" "$SOURCE"
  echo "$output"
}

@test "opencode consult: binds an accepted report to the exported session provider and model" {
  run_consult ok
  [ "$status" -eq 0 ]
  [ -s "$OUT" ]
  [ -s "$OUT.provenance.json" ]
  [ -s "$OUT.raw.jsonl" ]
  grep -q '^served_provider: opencode-go$' "$OUT"
  grep -q '^served_model: qwen3.7-max$' "$OUT"
  grep -q '^session: ses_review_123$' "$OUT"
  grep -q '^cost: 0.25$' "$OUT"
  grep -q '^verdict: APPROVE$' "$OUT"
  grep -q -- '--pure' "$ARGS"
  grep -q -- '--model opencode-go/qwen3.7-max' "$ARGS"
  grep -q -- '--format json' "$ARGS"
  grep -q -- '--dir ' "$ARGS"
  ! grep -q -- "--dir $SOURCE\([[:space:]]\|$\)" "$ARGS"
  [ ! -e "$SOURCE/reviewer-touch" ]
  [ "$(git -C "$SOURCE" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "opencode consult: refuses a different served provider and preserves the body as unattributed" {
  run_consult wrong_provider
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
  grep -q 'NOT A CONSULTATION' "$OUT.unattributed"
  grep -q 'bounded review completed' "$OUT.unattributed"
}

@test "opencode consult: refuses a different served model" {
  run_consult wrong_model
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
}

@test "opencode consult: more than one stream session is ambiguous" {
  run_consult ambiguous
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [[ "$output" == *"ambiguous"* || "$output" == *"more than one"* ]]
}

@test "opencode consult: missing export evidence is a refusal, not success" {
  run_consult export_fail
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
}

@test "opencode consult: a crashed run keeps partial output but creates no consultation" {
  run_consult run_fail
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
  grep -q 'PARTIAL FINDING' "$OUT.unattributed"
  [ -s "$OUT.raw.jsonl" ]
}

@test "opencode consult: its own clock kills a hanging review process group" {
  start="$(date +%s)"
  run_consult hang 1
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 1 ]
  [ "$elapsed" -lt 10 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
  grep -q 'PARTIAL BEFORE HANG' "$OUT.unattributed"
  [ "$(git -C "$SOURCE" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ]
}

@test "opencode consult: a completed answer without a final verdict is refused" {
  run_consult no_verdict
  [ "$status" -eq 1 ]
  [ ! -e "$OUT" ]
  [ -s "$OUT.unattributed" ]
}

@test "opencode consult: a symlinked output is refused before the model runs" {
  TARGET="$BATS_TEST_TMPDIR/target"
  printf 'untouched\n' > "$TARGET"
  ln -s "$TARGET" "$OUT"
  run_consult ok
  [ "$status" -eq 2 ]
  [ "$(cat "$TARGET")" = untouched ]
  [ ! -e "$ARGS" ]
}

@test "opencode consult: a dirty source is refused because detached HEAD would omit it" {
  printf 'not committed\n' > "$SOURCE/dirty.txt"
  run_consult ok
  [ "$status" -eq 2 ]
  [ ! -e "$OUT" ]
  [ ! -e "$ARGS" ]
}

@test "opencode consult: there is no verification bypass and the roster pins the invocation" {
  run bash -c "grep -nEi 'skip.?(verify|check)|--no-verify|SKIP_VERIFY' '$CONSULT'"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q 'opencode-go/qwen3.7-max' "$REPO_ROOT/governance/reviewers.md"
  grep -q 'consult-opencode.sh' "$REPO_ROOT/governance/reviewers.md"
  grep -qi 'service provider' "$REPO_ROOT/governance/reviewers.md"
  grep -qi 'upstream model' "$REPO_ROOT/governance/reviewers.md"
}
