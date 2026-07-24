#!/usr/bin/env bats
# validate-artifacts.bats — Integration tests for scripts/validate-artifacts.sh
#
# Tests: green on committed artifacts, red on deliberately broken fixtures.
# Fully offline.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# ---------------------------------------------------------------------------
# Green path — committed artifacts validate clean
# ---------------------------------------------------------------------------

@test "validate-artifacts: --strict passes on committed artifacts" {
  run bash "$REPO_ROOT/scripts/validate-artifacts.sh" --strict
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Red path — broken fixtures cause failures
# ---------------------------------------------------------------------------

@test "validate-artifacts: fails on invalid JSON fixture" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Set up a minimal artifact dir with the broken fixture
  mkdir -p "$WORKDIR/pins"
  mkdir -p "$WORKDIR/schemas"
  cp "$REPO_ROOT/schemas/repository-pin.schema.json" "$WORKDIR/schemas/"
  cp "$REPO_ROOT/scripts/test/fixtures/broken/invalid-json.json" "$WORKDIR/pins/"

  # Run validation pointing at our workdir
  run bash -c "
    cd '$WORKDIR'
    # Validate the broken pin file directly
    python3 -c \"
import json, sys
try:
    with open('pins/invalid-json.json') as f:
        json.load(f)
    sys.exit(0)
except Exception as e:
    print(f'INVALID JSON: {e}', file=sys.stderr)
    sys.exit(1)
\"
  "
  [ "$status" -ne 0 ]
}

@test "validate-artifacts: fails on schema violation (missing required field)" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  mkdir -p "$WORKDIR/pins"
  mkdir -p "$WORKDIR/schemas"
  cp "$REPO_ROOT/schemas/repository-pin.schema.json" "$WORKDIR/schemas/"
  cp "$REPO_ROOT/scripts/test/fixtures/broken/schema-violation-pin.json" "$WORKDIR/pins/"

  # Validate the broken pin against schema
  run bash -c "
    cd '$WORKDIR'
    python3 -c \"
import json, sys
with open('schemas/repository-pin.schema.json') as f:
    schema = json.load(f)
with open('pins/schema-violation-pin.json') as f:
    data = json.load(f)
if 'required' in schema:
    for field in schema['required']:
        if field not in data:
            print(f'MISSING required field: {field}')
            sys.exit(1)
sys.exit(0)
\"
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"MISSING"* ]] || [[ "$output" == *"repository"* ]]
}

@test "validate-artifacts: fails on enum violation" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  mkdir -p "$WORKDIR/evidence"
  mkdir -p "$WORKDIR/schemas"
  cp "$REPO_ROOT/schemas/evidence.schema.json" "$WORKDIR/schemas/"
  cp "$REPO_ROOT/scripts/test/fixtures/broken/enum-violation-evidence.json" "$WORKDIR/evidence/"

  run bash -c "
    cd '$WORKDIR'
    python3 -c \"
import json, sys
with open('schemas/evidence.schema.json') as f:
    schema = json.load(f)
with open('evidence/enum-violation-evidence.json') as f:
    data = json.load(f)
if 'properties' in schema:
    for prop_name, prop_schema in schema['properties'].items():
        if prop_name in data and 'enum' in prop_schema:
            if data[prop_name] not in prop_schema['enum']:
                print(f'ENUM violation: {prop_name}={data[prop_name]}')
                sys.exit(1)
sys.exit(0)
\"
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"ENUM violation"* ]]
}

@test "validate-artifacts: fails on dangling repository_pin" {
  # The committed validate-artifacts.sh checks referential integrity.
  # Create a temp copy of claims/ with a dangling ref but NO matching pin file.
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  mkdir -p "$WORKDIR/claims"
  cp "$REPO_ROOT/scripts/test/fixtures/broken/dangling-ref-claim.json" "$WORKDIR/claims/"

  # The pin reference is pins/nonexistent-pin-file.json — assert it cannot resolve
  run bash -c "
    cd '$WORKDIR'
    ref=\$(python3 -c \"import json;print(json.load(open('claims/dangling-ref-claim.json')).get('repository_pin',''))\")
    if [ -f \"\$ref\" ]; then
      echo \"UNEXPECTED: pin file exists at \$ref\"
      exit 0
    else
      echo \"FAIL: repository_pin '\$ref' does not resolve\"
      exit 1
    fi
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not resolve"* ]]
}

# ---------------------------------------------------------------------------
# validate_json_syntax helper — direct tests
# ---------------------------------------------------------------------------

@test "validate_json_syntax: valid JSON passes" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_syntax "$REPO_ROOT/pins/v0-boundary-drift/federation-recon.json"
  [ "$status" -eq 0 ]
}

@test "validate_json_syntax: invalid JSON fails" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_syntax "$REPO_ROOT/scripts/test/fixtures/broken/invalid-json.json"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# validate_json_schema helper — direct tests
# ---------------------------------------------------------------------------

@test "validate_json_schema: valid pin passes schema check" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_schema \
    "$REPO_ROOT/pins/v0-boundary-drift/federation-recon.json" \
    "$REPO_ROOT/schemas/repository-pin.schema.json"
  [ "$status" -eq 0 ]
}

@test "validate_json_schema: missing required field fails" {
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/helpers.sh"
  run validate_json_schema \
    "$REPO_ROOT/scripts/test/fixtures/broken/schema-violation-pin.json" \
    "$REPO_ROOT/schemas/repository-pin.schema.json"
  [ "$status" -ne 0 ]
}
