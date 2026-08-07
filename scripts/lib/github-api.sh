#!/usr/bin/env bash
# github-api.sh — checked GitHub read boundary for the observatory runners.
#
# Issue #175: a transport failure is not an observation of absence. The only
# API signal a runner may treat as legitimate absence is an explicit HTTP 404
# from a content endpoint. Every other failure — 403 rate limit, 5xx, network
# error, non-JSON body, or a success that yields no usable value — must surface
# as an explicit observation failure so the procedure exits through its
# documented partial/terminal failure path (exit 75) instead of writing
# negative evidence, a zero count, or a "missing descriptor" finding.
#
# Callers run with `set -o errexit -o nounset -o pipefail`. This file is
# deliberately `set`-free like the other sourced libraries (#75): a library
# must not change its caller's failure semantics.
#
# Provides:
#   gh_api_read <endpoint> [--jq <filter>]
#   gh_api_read_int <endpoint> [--jq <filter>]
#   gh_api_read_content <endpoint>
#   GH_API_OK / GH_API_FAILURE / GH_API_NOT_FOUND

# gh_api_read exit codes — callers compare against these names, never raw
# numbers, so the boundary contract reads the same at every call site.
GH_API_OK=0
GH_API_FAILURE=1
GH_API_NOT_FOUND=2

# is_pure_integer <value> — true if VALUE is only ASCII digits (a semantically
# numeric observation such as a repository-root entry count).
is_pure_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# gh_api_read <endpoint> [--jq <filter>]
#   Run `gh api` at ENDPOINT, optionally filtering the response with --jq.
#   Success:        prints the (filtered) body, returns $GH_API_OK.
#   HTTP 404:       prints nothing, returns $GH_API_NOT_FOUND. This is the
#                   only case a content read may treat as legitimate absence.
#   Any other:      prints nothing, returns $GH_API_FAILURE. Nothing about the
#                   failure is emitted to stdout, so an error body can never
#                   be captured as an observation value.
gh_api_read() {
  local endpoint="$1"
  shift
  local jq_filter=""
  if [ "${1:-}" = "--jq" ]; then
    jq_filter="${2:-}"
    shift 2
  fi

  local out err
  out="$(mktemp "${TMPDIR:-/tmp}/gh-api-read.XXXXXX")" || return $GH_API_FAILURE
  err="$(mktemp "${TMPDIR:-/tmp}/gh-api-err.XXXXXX")" || { rm -f "$out"; return $GH_API_FAILURE; }

  local -a gh_args=("$endpoint")
  if [ -n "$jq_filter" ]; then
    gh_args+=(--jq "$jq_filter")
  fi

  if gh api "${gh_args[@]}" >"$out" 2>"$err"; then
    if [ -s "$out" ]; then
      cat "$out"
      rm -f "$out" "$err"
      return $GH_API_OK
    fi
    # gh exited 0 but produced no value — that is not an observation either.
    rm -f "$out" "$err"
    return $GH_API_FAILURE
  fi

  # gh failed. Classify the failure from the error payload without emitting
  # it. GitHub API error bodies are JSON with a "status" field; gh's own CLI
  # errors (network, auth, transport) go to stderr and carry no status.
  local status=""
  status="$(python3 -c "
import json, sys
for path in sys.argv[1:]:
    try:
        with open(path, 'rb') as fh:
            raw = fh.read()
        if not raw:
            continue
        d = json.loads(raw.decode('utf-8', 'replace'))
        s = d.get('status') if isinstance(d, dict) else None
        if isinstance(s, int) or (isinstance(s, str) and s.isdigit()):
            print(s)
            break
    except Exception:
        continue
" "$out" "$err" 2>/dev/null || true)"

  if [ -z "$status" ]; then
    # gh reports transport status as "HTTP 404" even when its stderr is not a
    # bare GitHub JSON object. Match that explicit status only: generic prose
    # containing "Not Found" is not sufficient evidence of an HTTP 404.
    if rg -q 'HTTP 404' "$err" "$out" 2>/dev/null; then
      rm -f "$out" "$err"
      return $GH_API_NOT_FOUND
    fi
    rm -f "$out" "$err"
    return $GH_API_FAILURE
  fi

  rm -f "$out" "$err"
  if [ "$status" = "404" ]; then
    return $GH_API_NOT_FOUND
  fi
  return $GH_API_FAILURE
}

# gh_api_read_int <endpoint> [--jq <filter>]
#   Like gh_api_read, but additionally asserts the successful payload is a
#   pure non-negative integer. Semantically numeric values (e.g. the
#   repository-root entry count) are validated BEFORE artifact generation; a
#   non-integer success payload is an observation failure, never a value.
gh_api_read_int() {
  local endpoint="$1"
  shift
  local jq_filter=""
  if [ "${1:-}" = "--jq" ]; then
    jq_filter="${2:-}"
    shift 2
  fi

  local value="" rc=0
  if [ -n "$jq_filter" ]; then
    value="$(gh_api_read "$endpoint" --jq "$jq_filter")" || rc=$?
  else
    value="$(gh_api_read "$endpoint")" || rc=$?
  fi
  if [ "$rc" -ne $GH_API_OK ]; then
    return "$rc"
  fi
  if ! is_pure_integer "$value"; then
    return $GH_API_FAILURE
  fi
  printf '%s' "$value"
  return $GH_API_OK
}

# gh_api_read_content <endpoint>
#   Read a GitHub contents endpoint (base64-encoded "content" field) and
#   decode it in one step.
#   Success:  prints the decoded content, returns $GH_API_OK.
#   HTTP 404: prints nothing, returns $GH_API_NOT_FOUND (legitimate absence).
#   Other:    prints nothing, returns $GH_API_FAILURE.
gh_api_read_content() {
  local endpoint="$1"
  local b64="" rc=0
  b64="$(gh_api_read "$endpoint" --jq '.content')" || rc=$?
  if [ "$rc" -ne $GH_API_OK ]; then
    return "$rc"
  fi
  # BSD base64 accepts malformed input such as "%%%" and exits zero.  Use
  # Python's strict decoder so a successful API response cannot turn corrupt
  # content into an observation of an empty/missing file.
  if ! printf '%s' "$b64" | python3 -c '
import base64
import sys

raw = b"".join(sys.stdin.buffer.read().split())
try:
    decoded = base64.b64decode(raw, validate=True)
except Exception:
    raise SystemExit(1)
if not decoded:
    raise SystemExit(1)
sys.stdout.buffer.write(decoded)
'; then
    return $GH_API_FAILURE
  fi
  return $GH_API_OK
}
