#!/usr/bin/env bash
# validate-artifacts.sh — Validate all output artifacts against canonical schemas.
#
# Usage: bash scripts/validate-artifacts.sh [--strict]
#
# Without --strict: validates syntax only if python3 is unavailable.
# With --strict: requires python3 with json module.

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"

cd "$REPO_ROOT"

STRICT=false
[ "${1:-}" = "--strict" ] && STRICT=true

if $STRICT && ! command -v python3 &>/dev/null; then
  die "Strict mode requires python3"
fi

echo "=== Artifact Schema Validation ==="
echo "Validating all artifacts against schemas/*.json"
echo ""

SCHEMA_DIR="schemas"
ERRORS=0
VALIDATED=0

validate_dir() {
  local dir="$1" schema="$2" label="$3"
  local count=0 err=0

  if [ ! -d "$dir" ]; then
    echo "  [SKIP] $label — directory $dir not found"
    return
  fi

  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue

    # Basic JSON syntax check
    if ! validate_json_syntax "$f"; then
      echo "  [FAIL] $label: $f — invalid JSON syntax"
      err=$(( err + 1 ))
      ERRORS=$(( ERRORS + 1 ))
      continue
    fi

    # Schema validation
    if [ -f "$schema" ]; then
      if validate_json_schema "$f" "$schema"; then
        count=$(( count + 1 ))
        VALIDATED=$(( VALIDATED + 1 ))
      else
        echo "  [FAIL] $label: $f — schema violation"
        err=$(( err + 1 ))
        ERRORS=$(( ERRORS + 1 ))
      fi
    else
      echo "  [WARN] $label: schema $schema not found — syntax check only"
      count=$(( count + 1 ))
      VALIDATED=$(( VALIDATED + 1 ))
    fi
  done

  if [ "$err" -eq 0 ]; then
    echo "  [OK] $label: ${count} valid"
  else
    echo "  [PARTIAL] $label: ${count} valid, ${err} errors"
  fi
}

# Validate each artifact type against its schema
# Pins are namespaced: pins/v0-boundary-drift/*.json, pins/v1-census/*.json
# Use find to reach into subdirectories.
validate_dir_pins() {
  local dir="$1" schema="$2" label="$3"
  local count=0 err=0

  if [ ! -d "$dir" ]; then
    echo "  [SKIP] $label — directory $dir not found"
    return
  fi

  while IFS= read -r -d '' f; do
    # Basic JSON syntax check
    if ! validate_json_syntax "$f"; then
      echo "  [FAIL] $label: $f — invalid JSON syntax"
      err=$(( err + 1 ))
      ERRORS=$(( ERRORS + 1 ))
      continue
    fi

    # Schema validation
    if [ -f "$schema" ]; then
      if validate_json_schema "$f" "$schema"; then
        count=$(( count + 1 ))
        VALIDATED=$(( VALIDATED + 1 ))
      else
        echo "  [FAIL] $label: $f — schema violation"
        err=$(( err + 1 ))
        ERRORS=$(( ERRORS + 1 ))
      fi
    else
      echo "  [WARN] $label: schema $schema not found — syntax check only"
      count=$(( count + 1 ))
      VALIDATED=$(( VALIDATED + 1 ))
    fi
  done < <(find "$dir" -name '*.json' -type f -print0 2>/dev/null || true)

  if [ "$err" -eq 0 ]; then
    echo "  [OK] $label: ${count} valid"
  else
    echo "  [PARTIAL] $label: ${count} valid, ${err} errors"
  fi
}

validate_dir_pins "pins" "$SCHEMA_DIR/repository-pin.schema.json" "Repository Pins"
validate_dir "claims" "$SCHEMA_DIR/claim-observation.schema.json" "Claim Observations"
validate_dir "evidence" "$SCHEMA_DIR/evidence.schema.json" "Evidence"
validate_dir "drift" "$SCHEMA_DIR/drift-record.schema.json" "Drift Records"
validate_dir "findings" "$SCHEMA_DIR/finding.schema.json" "Findings"
validate_dir "coverage" "$SCHEMA_DIR/coverage-record.schema.json" "Coverage Records"

# Referential integrity (#11): every repository_pin must resolve to a real pin
# file, so the Claim/Evidence -> Pin -> raw repo navigation chain is not broken.
# The schema only requires repository_pin to be a string; this checks it points
# somewhere real.
ref_err=0
for f in claims/*.json evidence/*.json; do
  [ -f "$f" ] || continue
  ref=$(python3 -c "import json;print(json.load(open('$f')).get('repository_pin',''))" 2>/dev/null)
  [ -z "$ref" ] && continue
  if [ ! -f "$ref" ]; then
    echo "  [FAIL] $f — repository_pin '$ref' does not resolve to a pin file"
    ref_err=$(( ref_err + 1 ))
    ERRORS=$(( ERRORS + 1 ))
  fi
done
if [ "$ref_err" -eq 0 ]; then
  echo "  [OK] Pin references: all resolve to existing pin files"
fi

# Validate machine-readable digest (no official schema yet — syntax check only)
if [ -f "digest/state-digest.json" ]; then
  if validate_json_syntax "digest/state-digest.json"; then
    echo "  [OK] Digest: valid JSON syntax"
  else
    echo "  [FAIL] Digest: invalid JSON"
    ERRORS=$(( ERRORS + 1 ))
  fi
fi

# Validate procedure sub-digests (composition contract)
if [ -d "digest" ]; then
  sub_digest_count=0
  sub_digest_err=0
  for f in digest/*.json; do
    [ -f "$f" ] || continue
    bn=$(basename "$f")
    # Skip the composed digest and internal state files
    [ "$bn" = "state-digest.json" ] && continue
    [ "$bn" = "census-run-state.json" ] && continue
    if validate_json_syntax "$f"; then
      sub_digest_count=$(( sub_digest_count + 1 ))
    else
      echo "  [FAIL] Sub-digest: $f — invalid JSON syntax"
      sub_digest_err=$(( sub_digest_err + 1 ))
      ERRORS=$(( ERRORS + 1 ))
    fi
  done
  if [ "$sub_digest_count" -gt 0 ]; then
    if [ "$sub_digest_err" -eq 0 ]; then
      echo "  [OK] Sub-digests: ${sub_digest_count} valid"
    else
      echo "  [PARTIAL] Sub-digests: ${sub_digest_count} valid, ${sub_digest_err} errors"
    fi
  fi
fi

echo ""
echo "=== Summary ==="
echo "  Total validated: ${VALIDATED}"
echo "  Errors: ${ERRORS}"

if [ "$ERRORS" -gt 0 ]; then
  echo "  Result: FAILED"
  exit 3
else
  echo "  Result: ALL VALID ✓"
  exit 0
fi
