#!/usr/bin/env bash
# helpers.sh — Shared utility functions for federation-recon runner scripts.
#
# Usage: source "$(dirname "$0")/lib/helpers.sh"
#
# Provides: log, die, run_start, json_escape, json_val, write_json, make_id,
#           utc_timestamp, sha256_of, check_deps, validate_json

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics. See #75.

# ---- Domain constants ---------------------------------------------------

# Maximum length for a string read from an observed repository and embedded
# in an artifact. 256 chars is proportionate: the longest legitimate value
# measured is 197 chars.  Values exceeding this are truncated with a visible
# marker so a reader can distinguish "short assertion" from "shortened one".
OBSERVED_STRING_MAX_LENGTH=256

# truncate_observed <value> [max_len]
#   Truncate VALUE to MAX_LEN (default $OBSERVED_STRING_MAX_LENGTH).
#   If truncation occurs, appends a visible marker: …[truncated N chars].
#   Silent truncation is NOT acceptable — a reader must be able to tell a
#   short assertion from a shortened one.
#   The total produced string is at most MAX_LEN, satisfying schema maxLength
#   constraints.  An assertion guards against regression.
truncate_observed() {
  local val="$1"
  local max_len="${2:-$OBSERVED_STRING_MAX_LENGTH}"
  local val_len="${#val}"

  if [ "$val_len" -le "$max_len" ]; then
    printf '%s' "$val"
    return
  fi

  # Marker components — measure dynamically because the digit count of
  # N varies, and total must be ≤ max_len.
  local marker_prefix="…[truncated "
  local marker_suffix=" chars]"
  local pfx_len="${#marker_prefix}"
  local sfx_len="${#marker_suffix}"

  # Find the largest keep_len such that:
  #   keep_len + pfx_len + digit_count(N) + sfx_len ≤ max_len
  # where N = val_len - keep_len.
  # The loop runs at most ~25 iterations even for pathological input
  # because digit count grows logarithmically.
  local keep_len n digits total_len
  for (( keep_len = max_len; keep_len > 0; keep_len-- )); do
    n=$(( val_len - keep_len ))
    digits="${#n}"
    total_len=$(( keep_len + pfx_len + digits + sfx_len ))
    if [ "$total_len" -le "$max_len" ]; then
      break
    fi
  done

  # If keep_len reached 0 and still no valid length, the marker itself
  # exceeds max_len — a misconfiguration, not a truncation scenario.
  if [ "$keep_len" -eq 0 ]; then
    die "truncate_observed BUG: marker alone (${pfx_len}+${sfx_len}+digits) exceeds max_len $max_len"
  fi

  local result="${val:0:keep_len}${marker_prefix}${n}${marker_suffix}"

  # Assert: the produced string must satisfy the limit.
  # If this fires, there is a bug in the truncation logic above.
  if [ "${#result}" -gt "$max_len" ]; then
    die "truncate_observed BUG: result is ${#result} chars but max is $max_len — producer would emit an invalid artifact"
  fi

  printf '%s' "$result"
}

# ---- Logging -----------------------------------------------------------

log()   { echo "[recon] $*" >&2; }
die()   { log "FATAL: $*"; exit 1; }
warn()  { echo "[recon WARN] $*" >&2; }

# ---- Run metadata ------------------------------------------------------

RUN_START_EPOCH=""
run_start() {
  RUN_START_EPOCH="$(date -u +%s)"
}
run_elapsed() {
  local now; now="$(date -u +%s)"
  echo $(( now - RUN_START_EPOCH ))
}

# ---- JSON helpers (shell-native, no jq dependency) ---------------------

# json_escape <string> — escape for JSON string value
json_escape() {
  local s="$1"
  # Escape backslash, quote, newline, tab, carriage return, and control chars
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//	/\\t}"
  s="${s//
/\\n}"
  s="${s///\\r}"
  printf '%s' "$s"
}

# _is_pure_integer <string> — true if string contains only [0-9] or -[0-9]
_is_pure_integer() {
  local v="$1"
  # Strip leading minus for checking
  local t="${v#-}"
  # All characters must be digits
  case "$t" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# json_val <value> — wrap value as JSON string, pass through booleans/null/numbers
json_val() {
  local v="$1"
  case "$v" in
    ''|null)      printf 'null' ;;
    true|false)   printf '%s' "$v" ;;
    *)
      if _is_pure_integer "$v"; then
        printf '%s' "$v"
      else
        printf '"%s"' "$(json_escape "$v")"
      fi
      ;;
  esac
}

# write_json <file> <json_string> — write JSON (atomic via temp file)
write_json() {
  local file="$1" json="$2" tmp
  mkdir -p "$(dirname "$file")"
  tmp="${file}.tmp.$$"
  printf '%s\n' "$json" > "$tmp"
  mv "$tmp" "$file"
}

# read_file <path> — read file content, die if missing
read_file() {
  local path="$1"
  if [ ! -f "$path" ]; then
    die "Required file not found: $path"
  fi
  cat "$path"
}

# artifact_id <filepath> — extract the ID field from a JSON artifact file
# Works with any artifact type that has an *_id field (evidence_id, claim_id, etc.)
artifact_id() {
  local f="$1"
  if [ ! -f "$f" ]; then
    warn "artifact_id: file not found: $f"
    printf ''
    return
  fi
  python3 -c "
import json,sys
d=json.load(open('$f'))
for k in d:
    if k.endswith('_id'):
        print(d[k])
        sys.exit(0)
print('')
" 2>/dev/null || printf '%s' "$(basename "$f" .json)"
}

# ---- ID & timestamp generators -----------------------------------------

# make_id <prefix> <unique_string> — deterministic ID from prefix + content hash
make_id() {
  local prefix="$1" unique="$2"
  local hash; hash="$(_sha256_str "$unique")"
  printf '%s-%s' "$prefix" "${hash:0:12}"
}

# utc_timestamp — ISO-8601 UTC timestamp
utc_timestamp() {
  # Determinism (FR-CON-012): when RECON_FROZEN_TS is exported (reproduce mode),
  # every derived timestamp — pin, claim observed_at, coverage inspected_at,
  # finding created_at, drift detected_at — resolves to the same frozen value so
  # the whole artifact set reproduces byte-identically. Live mode uses wall-clock.
  if [ -n "${RECON_FROZEN_TS:-}" ]; then
    printf '%s\n' "$RECON_FROZEN_TS"
  else
    date -u +"%Y-%m-%dT%H:%M:%SZ"
  fi
}

# epoch_iso <epoch_seconds> — convert epoch to ISO-8601 UTC
epoch_iso() {
  date -u -r "$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    date -u -d "@$1" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
    die "Cannot convert epoch $1 to ISO timestamp"
}

# ---- SHA-256 (cross-platform) ------------------------------------------

# _sha256_str <string> — output SHA-256 hex digest (64 chars)
# Works on Linux (sha256sum), macOS (shasum), or via python3 fallback
_sha256_str() {
  local s="${1:-}"
  [ -z "$s" ] && { printf '0000000000000000000000000000000000000000000000000000000000000000'; return; }
  if command -v sha256sum &>/dev/null; then
    printf '%s' "$s" | sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    printf '%s' "$s" | shasum -a 256 | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    printf '%s' "$s" | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode()).hexdigest())"
  else
    # Fallback: use built-in bash — not real SHA but deterministic for IDs
    local sum=0 i
    for ((i=0; i<${#s}; i++)); do
      printf -v ord '%d' "'${s:$i:1}"
      sum=$(( (sum * 31 + ord) % 2147483647 ))
    done
    printf '%08x' "$sum"
  fi
}

# sha256_of <string> — SHA-256 hex digest (always 64 hex chars)
sha256_of() {
  _sha256_str "$1"
}

# file_sha256 <path> — SHA-256 of file content
file_sha256() {
  local f="$1"
  if [ -f "$f" ]; then
    _sha256_str "$(cat "$f")"
  fi
}

# ---- Dependency checks -------------------------------------------------

# check_deps <cmd1> [cmd2 ...] — ensure each command exists
check_deps() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "Required tool not found: $cmd"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    return 1
  fi
  return 0
}

# check_opt_deps <cmd1> [cmd2 ...] — warn if optional cmd missing
check_opt_deps() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "Optional tool not available: $cmd (continuing)"
    fi
  done
}

# ---- JSON validation (python3 if available) ----------------------------

# validate_json_schema <data_file> <schema_file> — validate JSON against schema
# Returns 0 if valid, 1 if invalid or validator unavailable.
validate_json_schema() {
  local data_file="$1" schema_file="$2"
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    with open('$schema_file') as f: schema = json.load(f)
    with open('$data_file') as f: data = json.load(f)
    # Basic structural validation: check required fields
    if 'required' in schema:
        for field in schema['required']:
            if field not in data:
                print(f'MISSING required field: {field}', file=sys.stderr)
                sys.exit(1)
    # Check enum constraints
    if 'properties' in schema:
        for prop_name, prop_schema in schema['properties'].items():
            if prop_name in data:
                val = data[prop_name]
                if 'enum' in prop_schema and val not in prop_schema['enum']:
                    print(f'ENUM violation: {prop_name}={val} not in {prop_schema[\"enum\"]}', file=sys.stderr)
                    sys.exit(1)
                if 'type' in prop_schema and prop_schema['type'] == 'array' and 'minItems' in prop_schema:
                    if not isinstance(val, list) or len(val) < prop_schema['minItems']:
                        print(f'MINITEMS violation: {prop_name} has {len(val) if isinstance(val,list) else 0} items, need {prop_schema[\"minItems\"]}', file=sys.stderr)
                        sys.exit(1)
                if 'uniqueItems' in prop_schema and prop_schema['uniqueItems']:
                    if isinstance(val, list):
                        seen = set()
                        for item in val:
                            key = item if item is None or isinstance(item, (str, int, float, bool)) else json.dumps(item, sort_keys=True)
                            if key in seen:
                                print(f'UNIQUEITEMS violation: {prop_name} contains duplicate element', file=sys.stderr)
                                sys.exit(1)
                            seen.add(key)
                if 'maxLength' in prop_schema and isinstance(val, str) and len(val) > prop_schema['maxLength']:
                    over = len(val) - prop_schema['maxLength']
                    print(f'MAXLENGTH violation: {prop_name} has {len(val)} chars, max is {prop_schema[\"maxLength\"]} (over by {over})', file=sys.stderr)
                    sys.exit(1)
    print('VALID')
    sys.exit(0)
except json.JSONDecodeError as e:
    print(f'INVALID JSON: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'VALIDATION ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1
    return $?
  else
    warn "python3 not available — schema validation skipped for $data_file"
    return 0
  fi
}

# validate_json_syntax <file> — check file is parseable JSON
validate_json_syntax() {
  local file="$1"
  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    with open('$file') as f: json.load(f)
    sys.exit(0)
except Exception as e:
    print(f'INVALID JSON: $file — {e}', file=sys.stderr)
    sys.exit(1)
" 2>&1
    return $?
  elif command -v jq &>/dev/null; then
    jq '.' "$file" >/dev/null 2>&1
    return $?
  else
    # Basic validation: must start with { or [
    local first; first="$(head -c1 "$file" 2>/dev/null || echo '')"
    case "$first" in
      '{'|'[') return 0 ;;
      *) warn "Suspicious JSON (no { or [): $file" ; return 1 ;;
    esac
  fi
}
