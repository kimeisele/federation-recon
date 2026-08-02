#!/usr/bin/env bats
# Oracle for #175. A transport failure is not an observation of absence.
#
# The production runners execute in an archived copy so this test cannot dirty
# the caller's checkout. Builder-owned files are overlaid from the working tree
# because acceptance runs before the builder patch is committed.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  TEST_ROOT="$(mktemp -d)"
  RUN_ROOT="$TEST_ROOT/repo"
  BIN="$TEST_ROOT/bin"
  mkdir -p "$RUN_ROOT" "$BIN"

  git -C "$REPO_ROOT" archive HEAD | tar -x -C "$RUN_ROOT"
  for path in \
    scripts/recon-run.sh \
    scripts/node-census-run.sh \
    scripts/lib/github-api.sh
  do
    [ -e "$REPO_ROOT/$path" ] || continue
    mkdir -p "$RUN_ROOT/$(dirname "$path")"
    cp "$REPO_ROOT/$path" "$RUN_ROOT/$path"
  done

  cat > "$BIN/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -u

if [ "${1:-}" != api ]; then
  printf '%s\n' '{"message":"unexpected fake-gh command","status":"500"}'
  exit 1
fi

endpoint="${2:-}"
counter_file="${FAKE_GH_COUNTER:?}"
count=0
[ ! -f "$counter_file" ] || count="$(cat "$counter_file")"
count=$((count + 1))
printf '%s' "$count" > "$counter_file"

emit_failure() {
  local status="$1"
  if [ "${FAKE_GH_MODE:-stable}" = varying ]; then
    printf '{"message":"API rate limit exceeded; request request-%s at 2026-08-02T21:11:%02dZ","status":"%s"}\n' "$count" "$count" "$status"
  elif [ "$status" = 404 ]; then
    printf '%s\n' '{"message":"Not Found","status":"404"}'
  else
    printf '%s\n' '{"message":"API rate limit exceeded; request stable","status":"403"}'
  fi
  exit 1
}

# The negative fixture fails two different evidence properties for one node:
# a tree count in recon and a descriptor read in census. Every other endpoint
# succeeds so the runners must preserve useful observations for unaffected
# nodes while marking only the failed node partial.
case "$endpoint" in
  repos/kimeisele/agent-city/git/trees/*)
    case "${FAKE_GH_MODE:-stable}" in stable|varying) emit_failure 403 ;; esac
    printf '%s\n' 7
    ;;
  repos/kimeisele/agent-city/contents/.well-known/agent-federation.json*)
    case "${FAKE_GH_MODE:-stable}" in
      stable|varying) emit_failure 403 ;;
      not_found) emit_failure 404 ;;
    esac
    ;;
  */contents/.well-known/agent-federation.json*)
    printf '%s\n' 'eyJyb2xlIjoiZml4dHVyZSIsInRpZXIiOiJ0ZXN0In0='
    ;;
  */contents/*)
    case "$*" in
      *"--jq .name"*) printf '%s\n' "${endpoint%%\?*}" | awk -F/ '{print $NF}' ;;
      *) printf '%s\n' 'IyBGaXh0dXJlCg==' ;;
    esac
    ;;
  */git/trees/*)
    printf '%s\n' 7
    ;;
  */git/ref/heads/*)
    printf '%040d\n' 1
    ;;
  repos/*)
    case "$*" in
      *"--jq .pushed_at"*) printf '%s\n' '2026-08-01T00:00:00Z' ;;
      *) printf '%s\n' main ;;
    esac
    ;;
  *)
    printf '%s\n' '{"message":"unhandled fake endpoint","status":"500"}'
    exit 1
    ;;
esac
FAKE_GH
  chmod +x "$BIN/gh"

  BEFORE_MISSING="$({ rg -l 'missing \.well-known/agent-federation\.json descriptor' "$RUN_ROOT/findings" 2>/dev/null || true; } | wc -l | tr -d ' ')"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

assert_transport_failure_is_not_evidence() {
  local mode="$1"
  export FAKE_GH_MODE="$mode"
  export FAKE_GH_COUNTER="$TEST_ROOT/gh-counter"
  export PATH="$BIN:$PATH"

  run env RECON_PINS_DIR=pins bash "$RUN_ROOT/scripts/recon-run.sh" --reproduce
  local recon_status="$status" recon_output="$output"
  [ "$recon_status" -eq 75 ]
  [[ "$recon_output" == *"kimeisele/"* ]]

  run env RECON_PINS_DIR=pins bash "$RUN_ROOT/scripts/node-census-run.sh" --reproduce
  local census_status="$status" census_output="$output"
  [ "$census_status" -eq 75 ]
  [[ "$census_output" == *"kimeisele/"* ]]

  if rg -n 'API rate limit exceeded|request-(stable|[0-9]+)' \
      "$RUN_ROOT/claims" "$RUN_ROOT/evidence" "$RUN_ROOT/findings" \
      "$RUN_ROOT/coverage" "$RUN_ROOT/digest" "$RUN_ROOT/STATE.md" 2>/dev/null; then
    echo "transport error body reached an artifact"
    return 1
  fi

  local after_missing
  after_missing="$({ rg -l 'missing \.well-known/agent-federation\.json descriptor' "$RUN_ROOT/findings" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  [ "$after_missing" -le "$BEFORE_MISSING" ]

  python3 - "$RUN_ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
expected = {
    ("boundary-drift-recon-v0", "pins/v0-boundary-drift/agent-city.json"),
    ("node-census-v1", "pins/v1-census/agent-city.json"),
}
seen = set()
for path in (root / "coverage").glob("*.json"):
    data = json.loads(path.read_text())
    key = (data.get("procedure_id"), data.get("repository_pin"))
    if key in expected and data.get("result") == "partial":
        seen.add(key)
if seen != expected:
    raise SystemExit(f"affected coverage was not partial: {sorted(expected - seen)}")

# An unaffected node still has affirmative descriptor evidence.
ok = False
for path in (root / "evidence").glob("*.json"):
    data = json.loads(path.read_text())
    if (data.get("repository_pin") == "pins/v1-census/steward-protocol.json"
            and data.get("observation_type") == "file_existence"
            and data.get("value") is True
            and ".well-known/agent-federation.json" in data.get("paths", [])):
        ok = True
if not ok:
    raise SystemExit("unaffected node lost its affirmative descriptor evidence")
PY
}

@test "GitHub boundary: a stable 403 cannot become absence or zero evidence" {
  assert_transport_failure_is_not_evidence stable
}

@test "GitHub boundary: changing 403 metadata cannot become observation data" {
  assert_transport_failure_is_not_evidence varying
}

@test "GitHub boundary: an explicit content 404 remains legitimate absence" {
  export FAKE_GH_MODE=not_found
  export FAKE_GH_COUNTER="$TEST_ROOT/gh-counter"
  export PATH="$BIN:$PATH"

  run env RECON_PINS_DIR=pins bash "$RUN_ROOT/scripts/node-census-run.sh" --reproduce
  [ "$status" -eq 0 ]

  local after_missing
  after_missing="$({ rg -l 'missing \.well-known/agent-federation\.json descriptor' "$RUN_ROOT/findings" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  [ "$after_missing" -gt "$BEFORE_MISSING" ]
  rg -q 'Node kimeisele/agent-city .*missing \.well-known/agent-federation\.json descriptor' "$RUN_ROOT/findings"
}
