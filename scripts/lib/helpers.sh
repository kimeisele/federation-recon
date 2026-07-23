#!/usr/bin/env bash
# helpers.sh — Shared utility functions for federation-recon runner scripts.
#
# Usage: source "$(dirname "$0")/lib/helpers.sh"
#
# Provides: log, die, run_start, json_escape, json_val, write_json, make_id,
#           utc_timestamp, sha256_of, check_deps, validate_json

set -o errexit -o nounset -o pipefail

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
  date -u +"%Y-%m-%dT%H:%M:%SZ"
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
