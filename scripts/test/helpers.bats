#!/usr/bin/env bats
# helpers.bats — Unit tests for scripts/lib/helpers.sh
#
# Tests: json_val, utc_timestamp, make_id, _sha256_str, sha256_of

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
}

# ---------------------------------------------------------------------------
# json_val
# ---------------------------------------------------------------------------

@test "json_val: empty string returns null" {
  result="$(json_val '')"
  [ "$result" = "null" ]
}

@test "json_val: string 'null' returns null" {
  result="$(json_val 'null')"
  [ "$result" = "null" ]
}

@test "json_val: boolean true passes through unquoted" {
  result="$(json_val 'true')"
  [ "$result" = "true" ]
}

@test "json_val: boolean false passes through unquoted" {
  result="$(json_val 'false')"
  [ "$result" = "false" ]
}

@test "json_val: positive integer is unquoted" {
  result="$(json_val '42')"
  [ "$result" = "42" ]
}

@test "json_val: zero is unquoted" {
  result="$(json_val '0')"
  [ "$result" = "0" ]
}

@test "json_val: negative integer is unquoted" {
  result="$(json_val '-17')"
  [ "$result" = "-17" ]
}

@test "json_val: ordinary string is quoted" {
  result="$(json_val 'hello')"
  [ "$result" = '"hello"' ]
}

@test "json_val: string with double-quote is escaped" {
  result="$(json_val 'say "hi"')"
  [ "$result" = '"say \"hi\""' ]
}

@test "json_val: string with backslash is escaped" {
  result="$(json_val 'a\b')"
  [ "$result" = '"a\\b"' ]
}

@test "json_val: string with newline is escaped" {
  # json_escape replaces literal newline with \n
  result="$(json_escape $'line1\nline2')"
  # The escaped string should contain the literal characters backslash + n
  [[ "$result" == *'\n'* ]] || [[ "$result" == *'\\n'* ]]
}

# ---------------------------------------------------------------------------
# utc_timestamp
# ---------------------------------------------------------------------------

@test "utc_timestamp: returns frozen timestamp when RECON_FROZEN_TS is set" {
  export RECON_FROZEN_TS="2025-01-15T12:00:00Z"
  result="$(utc_timestamp)"
  [ "$result" = "2025-01-15T12:00:00Z" ]
}

@test "utc_timestamp: returns wall-clock format when RECON_FROZEN_TS is not set" {
  unset RECON_FROZEN_TS
  result="$(utc_timestamp)"
  # Must match ISO-8601 format: YYYY-MM-DDTHH:MM:SSZ
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "utc_timestamp: empty RECON_FROZEN_TS falls back to wall-clock" {
  export RECON_FROZEN_TS=""
  result="$(utc_timestamp)"
  [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

# ---------------------------------------------------------------------------
# make_id
# ---------------------------------------------------------------------------

@test "make_id: same inputs produce deterministic output" {
  a="$(make_id 'test' 'alpha')"
  b="$(make_id 'test' 'alpha')"
  [ "$a" = "$b" ]
  [[ "$a" == test-* ]]
  [ "${#a}" -eq 17 ]  # "test-" + 12 hex chars
}

@test "make_id: different unique strings produce different IDs" {
  a="$(make_id 'test' 'alpha')"
  b="$(make_id 'test' 'beta')"
  [ "$a" != "$b" ]
}

@test "make_id: different prefixes produce different IDs" {
  a="$(make_id 'ev' 'data')"
  b="$(make_id 'cov' 'data')"
  [ "$a" != "$b" ]
  [[ "$a" == ev-* ]]
  [[ "$b" == cov-* ]]
}

# ---------------------------------------------------------------------------
# _sha256_str / sha256_of
# ---------------------------------------------------------------------------

@test "_sha256_str: empty string returns all-zeros hash" {
  result="$(_sha256_str '')"
  [ "$result" = "0000000000000000000000000000000000000000000000000000000000000000" ]
  [ "${#result}" -eq 64 ]
}

@test "sha256_of: deterministic — same input, same output" {
  a="$(sha256_of 'hello world')"
  b="$(sha256_of 'hello world')"
  [ "$a" = "$b" ]
  [ "${#a}" -eq 64 ]
}

@test "sha256_of: different inputs produce different hashes" {
  a="$(sha256_of 'apple')"
  b="$(sha256_of 'orange')"
  [ "$a" != "$b" ]
}

# ---------------------------------------------------------------------------
# _is_pure_integer
# ---------------------------------------------------------------------------

@test "_is_pure_integer: positive integer is detected" {
  _is_pure_integer '123'
}

@test "_is_pure_integer: negative integer is detected" {
  _is_pure_integer '-99'
}

@test "_is_pure_integer: zero is detected" {
  _is_pure_integer '0'
}

@test "_is_pure_integer: string with letters is rejected" {
  run _is_pure_integer 'abc'
  [ "$status" -eq 1 ]
}

@test "_is_pure_integer: float is rejected" {
  run _is_pure_integer '3.14'
  [ "$status" -eq 1 ]
}

@test "_is_pure_integer: empty string is rejected" {
  run _is_pure_integer ''
  [ "$status" -eq 1 ]
}
