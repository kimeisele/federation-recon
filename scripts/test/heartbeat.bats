#!/usr/bin/env bats
# heartbeat.bats — Offline tests for the decide-only operator heartbeat.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/operator" "$WORKDIR/mockbin"
  cp "$REPO_ROOT/operator/heartbeat.sh" "$WORKDIR/operator/heartbeat.sh"
  chmod +x "$WORKDIR/operator/heartbeat.sh"

  export WORKDIR
  export MOCK_PRS='[]'
  export MOCK_ISSUES='[]'
  export MOCK_GH_FAIL_ON=''
  export MOCK_GH_CWD="$WORKDIR"
  export MOCK_GIT_DIRTY='clean'
  export MOCK_GIT_FAIL='false'
  export HEARTBEAT_NOW='2026-07-24T12:00:00Z'

  cat > "$WORKDIR/mockbin/gh" <<'GHSCRIPT'
#!/usr/bin/env bash
if [ -n "${MOCK_GH_CWD:-}" ] && [ "$PWD" != "$MOCK_GH_CWD" ]; then
  exit 4
fi
if [ -n "${GH_REPO:-}" ]; then
  exit 5
fi
if [ -n "${GH_HOST:-}" ]; then
  exit 6
fi
if [ "$MOCK_GH_FAIL_ON" = "all" ] || [ "$MOCK_GH_FAIL_ON" = "${1:-}" ]; then
  exit 1
fi
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "$MOCK_PRS" ;;
  "issue list") printf '%s\n' "$MOCK_ISSUES" ;;
  *) exit 2 ;;
esac
GHSCRIPT
  chmod +x "$WORKDIR/mockbin/gh"

  cat > "$WORKDIR/mockbin/git" <<'GITSCRIPT'
#!/usr/bin/env bash
if [ "${1:-}" = "-C" ]; then shift 2; fi
if [ "${1:-}" = "status" ]; then
  [ "$MOCK_GIT_FAIL" = "false" ] || exit 1
  [ "$MOCK_GIT_DIRTY" = "clean" ] || printf ' M operator/state.json\n'
  exit 0
fi
exec /usr/bin/git "$@"
GITSCRIPT
  chmod +x "$WORKDIR/mockbin/git"
}

teardown() {
  rm -rf "$WORKDIR"
}

_state() {
  local phase="${1:-1_CLASSIFY}" cycle="${2:-1}" used="${3:-0}" maximum="${4:-3}"
  printf '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"%s","cycle":%s,"budget":{"expert_calls_this_cycle":%s,"max_expert_calls":%s},"last_heartbeat":"2026-07-24T00:00:00Z","notes":""}' \
    "$phase" "$cycle" "$used" "$maximum"
}

_write_state() {
  local content="$1" path="${2:-$WORKDIR/operator/state.json}"
  printf '%s\n' "$content" > "$path"
}

_run_heartbeat() {
  PATH="$WORKDIR/mockbin:$PATH" \
    HEARTBEAT_NOW="$HEARTBEAT_NOW" \
    /bin/bash "$WORKDIR/operator/heartbeat.sh" "$@" 2>&1
}

@test "heartbeat: HOLD on a complete empty GitHub view" {
  _write_state "$(_state)"
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
}

@test "heartbeat: dry-run leaves the selected state byte-identical" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  run _run_heartbeat --dry-run
  after="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
  [ "$before" = "$after" ]
}

@test "heartbeat: explicit state file is advanced without touching the bootstrap seed" {
  _write_state "$(_state)"
  cp "$WORKDIR/operator/state.json" "$WORKDIR/runtime-state.json"
  seed_before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"

  run _run_heartbeat --state-file "$WORKDIR/runtime-state.json"
  [ "$status" -eq 0 ]
  [ "$seed_before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
  [ "$(python3 -c "import json; print(json.load(open('$WORKDIR/runtime-state.json'))['notes'])")" = "HOLD: no work" ]
}

@test "heartbeat: OPERATOR_STATE_FILE selects runtime state without touching the seed" {
  _write_state "$(_state)"
  cp "$WORKDIR/operator/state.json" "$WORKDIR/runtime-state.json"
  seed_before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export OPERATOR_STATE_FILE="$WORKDIR/runtime-state.json"

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [ "$seed_before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
  [ "$(python3 -c "import json; print(json.load(open('$WORKDIR/runtime-state.json'))['notes'])")" = "HOLD: no work" ]
}

@test "heartbeat: atomic state replacement preserves file permissions" {
  _write_state "$(_state)"
  chmod 0640 "$WORKDIR/operator/state.json"

  run _run_heartbeat
  [ "$status" -eq 0 ]
  [ "$(python3 -c "import os, stat; print(oct(stat.S_IMODE(os.stat('$WORKDIR/operator/state.json').st_mode)))")" = "0o640" ]
}

@test "heartbeat: rejects a symbolic-link state path" {
  _write_state "$(_state)" "$WORKDIR/runtime-state.json"
  ln -s "$WORKDIR/runtime-state.json" "$WORKDIR/operator/state.json"

  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not be a symbolic link"* ]]
}

@test "heartbeat: bootstrap advances locally without querying GitHub" {
  _write_state "$(_state 0_BOOTSTRAP 0)"
  export MOCK_GH_FAIL_ON='all'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: ADVANCE"* ]]
  [ "$(python3 -c "import json; print(json.load(open('$WORKDIR/operator/state.json'))['phase'])")" = "1_CLASSIFY" ]
}

@test "heartbeat: bootstrap STOPs on tracked or untracked dirt" {
  _write_state "$(_state 0_BOOTSTRAP 0)"
  export MOCK_GIT_DIRTY='dirty'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "heartbeat: bootstrap git status failure emits STOP and exits nonzero" {
  _write_state "$(_state 0_BOOTSTRAP 0)"
  export MOCK_GIT_FAIL='true'
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"repository status unavailable"* ]]
}

@test "heartbeat: rejects invalid JSON before GitHub access" {
  _write_state '{not-json'
  export MOCK_GH_FAIL_ON='all'
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: invalid state file"* ]]
}

@test "heartbeat: rejects an unsupported phase" {
  _write_state "$(_state 9_UNKNOWN)"
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"phase is missing or unsupported"* ]]
}

@test "heartbeat: rejects negative or boolean budget counters" {
  _write_state '{"schema_version":1,"updated_at":"2026-07-24T00:00:00Z","phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":true,"max_expert_calls":3},"last_heartbeat":null,"notes":""}'
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"expert_calls_this_cycle"* ]]
}

@test "heartbeat: rejects missing required state fields" {
  _write_state '{"schema_version":1,"phase":"1_CLASSIFY","cycle":1,"budget":{"expert_calls_this_cycle":0,"max_expert_calls":3}}'
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"updated_at"* ]]
  [[ "$output" == *"notes"* ]]
}

@test "heartbeat: rejects invalid injected time before GitHub access" {
  _write_state "$(_state)"
  export HEARTBEAT_NOW='not-a-time'
  export MOCK_GH_FAIL_ON='all'
  run _run_heartbeat
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid HEARTBEAT_NOW"* ]]
}

@test "heartbeat: missing gh fails closed without changing state" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  mkdir "$WORKDIR/noghbin"
  for command_name in python3 dirname mktemp rm cat; do
    ln -s "$(command -v "$command_name")" "$WORKDIR/noghbin/$command_name"
  done

  run env PATH="$WORKDIR/noghbin" \
    HEARTBEAT_NOW="$HEARTBEAT_NOW" \
    /bin/bash "$WORKDIR/operator/heartbeat.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"gh not found"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: PR query failure emits STOP and exits nonzero" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export MOCK_GH_FAIL_ON='pr'
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"PR query failed"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: issue query failure emits STOP and exits nonzero" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export MOCK_GH_FAIL_ON='issue'
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"issue query failed"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: malformed GitHub JSON fails closed" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export MOCK_PRS='not-json'
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"malformed list response"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: malformed GitHub fields fail closed" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export MOCK_ISSUES='[{"number":1,"title":"bad labels","updatedAt":"2026-07-24T10:00:00Z","labels":["approved"]}]'
  run _run_heartbeat
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"malformed list response"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: GitHub failure in dry-run leaves state byte-identical" {
  _write_state "$(_state)"
  before="$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')"
  export MOCK_GH_FAIL_ON='pr'
  run _run_heartbeat --dry-run
  [ "$status" -eq 2 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [ "$before" = "$(shasum -a 256 "$WORKDIR/operator/state.json" | awk '{print $1}')" ]
}

@test "heartbeat: exactly one PR takes REVIEW priority over an approved issue" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":42,"updatedAt":"2026-07-24T10:00:00Z"}]'
  export MOCK_ISSUES='[{"number":32,"updatedAt":"2026-07-24T11:00:00Z","labels":[{"name":"approved"}]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REVIEW PR #42"* ]]
  [[ "$output" != *"BUILD"* ]]
}

@test "heartbeat: caller GH_REPO cannot redirect repository reads" {
  _write_state "$(_state)"
  export GH_REPO='foreign-owner/foreign-repo'
  run _run_heartbeat --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
}

@test "heartbeat: caller GH_HOST cannot redirect repository reads" {
  _write_state "$(_state)"
  export GH_HOST='evil-enterprise.example.com'
  run _run_heartbeat --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
}

@test "heartbeat: two open PRs STOP regardless of deterministic review order" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":42,"title":"newer","body":"","updatedAt":"2026-07-24T10:00:00Z"},{"number":7,"title":"older","body":"","updatedAt":"2026-07-23T10:00:00Z"}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"WIP cap"* ]]
}

@test "heartbeat: REVIEWs one recent open PR" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":42,"title":"Test PR","body":"Closes #29","updatedAt":"2026-07-24T10:00:00Z"}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REVIEW PR #42"* ]]
}

@test "heartbeat: WIP cap STOPs before other work when more than one PR is open" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":1,"title":"one","body":"","updatedAt":"2026-07-24T10:00:00Z"},{"number":2,"title":"two","body":"","updatedAt":"2026-07-24T11:00:00Z"}]'
  export MOCK_ISSUES='[{"number":32,"title":"approved","updatedAt":"2026-07-24T11:00:00Z","labels":[{"name":"approved"}]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"WIP cap"* ]]
}

@test "heartbeat: BUILDs the oldest approved issue when WIP is zero" {
  _write_state "$(_state)"
  export MOCK_ISSUES='[{"number":33,"title":"newer","updatedAt":"2026-07-24T11:00:00Z","labels":[{"name":"approved"}]},{"number":29,"title":"older","updatedAt":"2026-07-23T11:00:00Z","labels":[{"name":"approved"}]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: BUILD issue #29"* ]]
}

@test "heartbeat: STOPs when the expert-call budget is exhausted" {
  _write_state "$(_state 1_CLASSIFY 1 3 3)"
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: STOP"* ]]
  [[ "$output" == *"budget cap"* ]]
}

@test "heartbeat: stale PR detection uses updatedAt activity" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":8,"title":"stale","body":"","updatedAt":"2026-07-10T00:00:00Z"}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: SWEEP PR #8"* ]]
}

@test "heartbeat: recently updated PR is reviewed rather than swept" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":8,"title":"old creation irrelevant","body":"","updatedAt":"2026-07-24T11:00:00Z"}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REVIEW PR #8"* ]]
  [[ "$output" != *"SWEEP"* ]]
}

@test "heartbeat: exactly seven days without PR activity is not stale" {
  _write_state "$(_state)"
  export MOCK_PRS='[{"number":8,"updatedAt":"2026-07-17T12:00:00Z"}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: REVIEW PR #8"* ]]
  [[ "$output" != *"SWEEP"* ]]
}

@test "heartbeat: stale issue detection uses updatedAt activity" {
  _write_state "$(_state)"
  export MOCK_ISSUES='[{"number":10,"title":"stale","updatedAt":"2026-07-01T00:00:00Z","labels":[]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: SWEEP issue #10"* ]]
}

@test "heartbeat: exactly fourteen days without issue activity is not stale" {
  _write_state "$(_state)"
  export MOCK_ISSUES='[{"number":10,"updatedAt":"2026-07-10T12:00:00Z","labels":[{"name":"approved"}]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: BUILD issue #10"* ]]
  [[ "$output" != *"SWEEP"* ]]
}

@test "heartbeat: stale selection is deterministic by updatedAt then number" {
  _write_state "$(_state)"
  export MOCK_ISSUES='[{"number":12,"title":"same time","updatedAt":"2026-07-01T00:00:00Z","labels":[]},{"number":9,"title":"same time","updatedAt":"2026-07-01T00:00:00Z","labels":[]}]'
  run _run_heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: SWEEP issue #9"* ]]
}

@test "heartbeat: consumed untrusted label text is data and never shell syntax" {
  _write_state "$(_state)"
  marker="$WORKDIR/should-not-exist"
  export MOCK_ISSUES="[{\"number\":42,\"updatedAt\":\"2026-07-24T10:00:00Z\",\"labels\":[{\"name\":\"\$(touch $marker)\"}]}]"
  run _run_heartbeat --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ACTION: HOLD"* ]]
  [ ! -e "$marker" ]
}

@test "heartbeat: same inputs and injected time produce the same dry-run output" {
  _write_state "$(_state)"
  first="$(_run_heartbeat --dry-run)"
  second="$(_run_heartbeat --dry-run)"
  [ "$first" = "$second" ]
}

@test "heartbeat: unknown arguments fail explicitly" {
  _write_state "$(_state)"
  run _run_heartbeat --execute
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "heartbeat: missing or nonexistent state-file arguments fail explicitly" {
  _write_state "$(_state)"

  run _run_heartbeat --state-file
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires a path"* ]]

  run _run_heartbeat --state-file "$WORKDIR/missing.json"
  [ "$status" -eq 1 ]
  [[ "$output" == *"state file not found"* ]]
}

@test "heartbeat: state write failure emits no misleading action" {
  [ "$(id -u)" -ne 0 ] || skip "root bypasses directory write permissions"
  _write_state "$(_state)"
  chmod 0500 "$WORKDIR/operator"
  run _run_heartbeat
  chmod 0700 "$WORKDIR/operator"

  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to write state file"* ]]
  [[ "$output" != *"ACTION:"* ]]
}
