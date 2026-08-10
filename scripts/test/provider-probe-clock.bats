#!/usr/bin/env bats
#
# The probe's log window must be read on the same clock jcode writes (#222).
#
# jcode stamps its log lines, and names its log file, in local time. The probe
# compares its window against those stamps as strings. When the window was
# taken with `date -u`, a host at UTC+2 opened it two hours early, admitted
# routes from unrelated earlier calls, and reported AMBIGUOUS — refusing every
# build. In CI the offset is zero and nothing failed, which is why it survived.
#
# These tests pin the clock relationship rather than the offset: they run under
# a TZ with a non-zero offset and assert the probe still sees exactly its own
# call.

setup() {
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  PROBE="$REPO_ROOT/operator/builders/provider-probe.sh"

  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export JCODE_LOG_DIR="$SANDBOX/logs"
  mkdir -p "$JCODE_LOG_DIR" "$SANDBOX/bin"

  # A host whose local time is well ahead of UTC. Under the old code the
  # window opened 9 hours early.
  export TZ="Asia/Tokyo"

  # Stub jcode: writes one route line stamped in LOCAL time, exactly as the
  # real tool does, then exits 0.
  cat > "$SANDBOX/bin/jcode" <<'STUB'
#!/usr/bin/env bash
stamp="$(date +"%Y-%m-%d %H:%M:%S")"
log="$JCODE_LOG_DIR/jcode-$(date +%Y-%m-%d).log"
printf '[%s.000] [INFO] API stream attempt 1/3 over HTTPS transport (model: %s, endpoint: %s, auth: TEST_KEY)\n' \
  "$stamp" "${STUB_MODEL:-deepseek-v4-flash}" "${STUB_ENDPOINT:-https://opencode.ai/zen/go/v1}" >> "$log"
printf 'ok\n'
exit 0
STUB
  chmod +x "$SANDBOX/bin/jcode"
  export JCODE_BIN="$SANDBOX/bin/jcode"

  OUT="$SANDBOX/probe.txt"
}

_field() { grep -E "^$1:" "$OUT" | sed -E "s/^$1:[[:space:]]*//"; }

@test "probe-clock: a route logged in local time is inside the window" {
  export JCODE_PROVIDER_PROFILE=federation-opencode-go
  export JCODE_EXPECTED_ENDPOINT=https://opencode.ai/zen/go/v1
  run bash "$PROBE" federation-opencode-go deepseek-v4-flash "$OUT" 60
  [ "$status" -eq 0 ]
  [ "$(_field verdict)" = "match" ]
  [ "$(_field resolved_endpoint)" = "https://opencode.ai/zen/go/v1" ]
}

@test "probe-clock: a route logged before the window is not admitted" {
  # An unrelated earlier call, one hour back on the local clock. Under the UTC
  # window this landed inside and made the result AMBIGUOUS.
  local log="$JCODE_LOG_DIR/jcode-$(date +%Y-%m-%d).log"
  printf '[%s.000] [INFO] API stream attempt 1/3 over HTTPS transport (model: deepseek-v4-flash, endpoint: https://api.deepseek.com, auth: OLD)\n' \
    "$(date -v-1H +"%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d '1 hour ago' +"%Y-%m-%d %H:%M:%S")" >> "$log"

  export JCODE_PROVIDER_PROFILE=federation-opencode-go
  export JCODE_EXPECTED_ENDPOINT=https://opencode.ai/zen/go/v1
  run bash "$PROBE" federation-opencode-go deepseek-v4-flash "$OUT" 60
  [ "$status" -eq 0 ]
  [ "$(_field verdict)" = "match" ]
}

@test "probe-clock: the window is taken on the same clock as the log file name" {
  export JCODE_PROVIDER_PROFILE=federation-opencode-go
  export JCODE_EXPECTED_ENDPOINT=https://opencode.ai/zen/go/v1
  run bash "$PROBE" federation-opencode-go deepseek-v4-flash "$OUT" 60
  # The log the probe says it read must be the file the stub actually wrote.
  [ -s "$(_field log)" ]
  [ "$(_field log)" = "$JCODE_LOG_DIR/jcode-$(date +%Y-%m-%d).log" ]
}

@test "probe-clock: a genuinely different endpoint is still refused" {
  # The fix must not widen what counts as a match.
  export STUB_ENDPOINT=https://api.deepseek.com
  export JCODE_PROVIDER_PROFILE=federation-opencode-go
  export JCODE_EXPECTED_ENDPOINT=https://opencode.ai/zen/go/v1
  run bash "$PROBE" federation-opencode-go deepseek-v4-flash "$OUT" 60
  [ "$status" -ne 0 ]
  [ "$(_field verdict)" = "MISMATCH" ]
}
