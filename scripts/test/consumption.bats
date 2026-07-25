#!/usr/bin/env bats
# consumption.bats — Tests for F-02 Consumption Measurement
#
# Tests: schema validation, zero-consumption sub-digest, self-reference exclusion,
# consumption record content, cycle tracking.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  cd "$REPO_ROOT"
}

# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

@test "consumption-record schema is valid JSON" {
  python3 -c "import json; json.load(open('schemas/consumption-record.schema.json'))"
}

@test "consumption-record schema has all required fields" {
  python3 -c "
import json
with open('schemas/consumption-record.schema.json') as f:
    s = json.load(f)
req = s.get('required', [])
assert 'consumption_id' in req
assert 'referencing_repository' in req
assert 'referencing_file_path' in req
assert 'line_number' in req
assert 'referenced_finding_id' in req
assert 'reference_type' in req
assert 'repository_pin' in req
assert 'observed_at' in req
assert 'cycle' in req
"
}

@test "consumption-record schema reference_type enum is correct" {
  python3 -c "
import json
with open('schemas/consumption-record.schema.json') as f:
    s = json.load(f)
enum = s['properties']['reference_type']['enum']
assert 'finding_id' in enum
assert 'repo_reference' in enum
assert len(enum) == 2, f'Expected exactly 2 values, got {len(enum)}: {enum}'
# Must NOT contain the removed types
for bad in ['finding_path', 'drift_path', 'evidence_path', 'url_slug']:
    assert bad not in enum, f'Removed type {bad} still in enum'
"
}

@test "consumption-record schema forbids additional properties" {
  python3 -c "
import json
with open('schemas/consumption-record.schema.json') as f:
    s = json.load(f)
assert s.get('additionalProperties') == False
"
}

# ---------------------------------------------------------------------------
# Consumption record validation (if committed records exist)
# ---------------------------------------------------------------------------

@test "committed consumption records validate against schema (if any)" {
  for f in consumption/*.json; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == "cycle-ledger.json" ]] && continue
    run python3 -c "
import json, sys
with open('schemas/consumption-record.schema.json') as sf:
    schema = json.load(sf)
with open('$f') as df:
    data = json.load(df)
for field in schema.get('required', []):
    assert field in data, f'MISSING required field: {field} in $f'
# Check enum
enum = schema['properties']['reference_type']['enum']
assert data.get('reference_type') in enum, f'Invalid reference_type in $f'
# Check additional properties
for key in data:
    assert key in schema['properties'], f'Unknown property {key} in $f'
"
    [ "$status" -eq 0 ]
  done
}

# ---------------------------------------------------------------------------
# Positive control: a real Finding ID MUST produce a consumption record
# ---------------------------------------------------------------------------

@test "positive control: real Finding ID is detected by production search pattern" {
  local fixture_dir="$REPO_ROOT/scripts/test/fixtures/consumption-positive"

  # This is the EXACT rg invocation from search_repo_for_consumption (line 191-194).
  # We test it against a fixture to prove the instrument can detect real Finding IDs.
  run bash -c "
    cd '$fixture_dir'
    rg -n --no-heading --sort path --hidden \
      -e 'finding-[0-9a-f]{12}' \
      -e 'federation-recon' \
      . 2>/dev/null || true
  "

  # The fixture contains finding-0fc027b8a436 → rg MUST produce output
  [ -n "$output" ]
  # The output must contain the file path and the Finding ID
  [[ "$output" =~ doc\.md ]]
  [[ "$output" =~ finding-0fc027b8a436 ]]
}

# ---------------------------------------------------------------------------
# Negative control: finding-a{12} (literal braces) MUST NOT match
# ---------------------------------------------------------------------------

@test "negative control: literal 'finding-a{12}' is NOT detected by production search pattern" {
  local fixture_dir="$REPO_ROOT/scripts/test/fixtures/consumption-negative"

  run bash -c "
    cd '$fixture_dir'
    rg -n --no-heading --sort path --hidden \
      -e 'finding-[0-9a-f]{12}' \
      -e 'federation-recon' \
      . 2>/dev/null || true
  "

  # The literal-braces.md file contains 'finding-a{12}' which has literal braces,
  # NOT a 12-char hex string. ripgrep with Rust regex must NOT match this.
  # Assert: the only possible match would be for 'federation-recon', and there
  # is none, so output must be empty.
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Reference-type classification: finding_id vs repo_reference
# ---------------------------------------------------------------------------

@test "reference-type classification: Finding ID match classifies as finding_id" {
  # Simulate the classification logic from search_repo_for_consumption (lines 226-232)
  local match_text="see finding-0fc027b8a436 for details"
  local ref_type=""

  if printf '%s' "$match_text" | rg -q 'finding-[0-9a-f]{12}'; then
    ref_type="finding_id"
  elif printf '%s' "$match_text" | rg -q 'federation-recon'; then
    ref_type="repo_reference"
  fi

  [ "$ref_type" = "finding_id" ]
}

@test "reference-type classification: repo mention classifies as repo_reference" {
  local match_text="uses federation-recon as a dependency"
  local ref_type=""

  if printf '%s' "$match_text" | rg -q 'finding-[0-9a-f]{12}'; then
    ref_type="finding_id"
  elif printf '%s' "$match_text" | rg -q 'federation-recon'; then
    ref_type="repo_reference"
  fi

  [ "$ref_type" = "repo_reference" ]
}

# ---------------------------------------------------------------------------
# Falsifier: unqualified substrings must NOT produce consumption records
# ---------------------------------------------------------------------------

@test "falsifier: file containing 'evidence/' produces NO consumption record" {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "This file mentions evidence/ in passing — not a Finding reference." > "$tmpdir/test.md"

  run bash -c "
    cd '$tmpdir'
    rg -n --no-heading --sort path --hidden \
      -e 'finding-[0-9a-f]{12}' \
      -e 'federation-recon' \
      . 2>/dev/null || true
  "
  [ -z "$output" ]
  rm -rf "$tmpdir"
}

@test "falsifier: file containing 'drift/' produces NO consumption record" {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "The drift/ directory contains drift records." > "$tmpdir/test.md"

  run bash -c "
    cd '$tmpdir'
    rg -n --no-heading --sort path --hidden \
      -e 'finding-[0-9a-f]{12}' \
      -e 'federation-recon' \
      . 2>/dev/null || true
  "
  [ -z "$output" ]
  rm -rf "$tmpdir"
}

@test "falsifier: file containing 'findings/' produces NO consumption record" {
  local tmpdir
  tmpdir=$(mktemp -d)
  echo "See the findings/ section for details." > "$tmpdir/test.md"

  run bash -c "
    cd '$tmpdir'
    rg -n --no-heading --sort path --hidden \
      -e 'finding-[0-9a-f]{12}' \
      -e 'federation-recon' \
      . 2>/dev/null || true
  "
  [ -z "$output" ]
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Sub-digest shape (if committed)
# ---------------------------------------------------------------------------

@test "v2-consumption sub-digest has required fields (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "
import json
with open('digest/v2-consumption.json') as f:
    d = json.load(f)
assert d.get('procedure_id') == 'v2-consumption'
assert 'procedure_version' in d
assert 'run_timestamp' in d
assert 'attention_items' in d
assert 'summary' in d
assert 'budget' in d
assert 'self_observation' in d
"
}

@test "v2-consumption sub-digest summary has finding_references, repo_references, and cycle (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "
import json
with open('digest/v2-consumption.json') as f:
    d = json.load(f)
summary = d.get('summary', {})
assert 'finding_references' in summary
assert 'repo_references' in summary
assert 'total_consumption_records' in summary
assert 'cycle' in summary
assert isinstance(summary['finding_references'], int)
assert isinstance(summary['repo_references'], int)
assert isinstance(summary['total_consumption_records'], int)
assert isinstance(summary['cycle'], int)
# The total must equal the sum of the two counts
assert summary['total_consumption_records'] == summary['finding_references'] + summary['repo_references'], \
    f\"total ({summary['total_consumption_records']}) != finding ({summary['finding_references']}) + repo ({summary['repo_references']})\"
"
}

@test "v2-consumption sub-digest is valid JSON (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "import json; json.load(open('digest/v2-consumption.json'))"
}

# ---------------------------------------------------------------------------
# Zero-consumption: must render plainly, not as empty section
# ---------------------------------------------------------------------------

@test "v2-consumption sub-digest renders zero finding_references as explicit (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "
import json
with open('digest/v2-consumption.json') as f:
    d = json.load(f)
count = d.get('summary', {}).get('finding_references', -1)
if count == 0:
    # Zero must have attention items stating the fact
    items = d.get('attention_items', [])
    assert len(items) > 0, 'Zero finding_references must produce attention items'
    headline = items[0].get('headline', '')
    assert 'ZERO' in headline, f'Zero finding_references headline must say ZERO: {headline}'
    print('OK: zero finding_references explicitly rendered')
else:
    print(f'SKIP: finding_references count = {count}, not testing zero case')
"
}

# ---------------------------------------------------------------------------
# Self-reference exclusion
# ---------------------------------------------------------------------------

@test "committed consumption records never reference federation-recon (self-exclusion)" {
  for f in consumption/*.json; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == "cycle-ledger.json" ]] && continue
    python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
ref_repo = d.get('referencing_repository', '')
assert ref_repo != 'kimeisele/federation-recon', \
    f'Self-reference found in $f: {ref_repo}'
"
  done
}

# ---------------------------------------------------------------------------
# No excerpts rule (FR-CON-008)
# ---------------------------------------------------------------------------

@test "consumption record schema does not include source excerpts" {
  python3 -c "
import json
with open('schemas/consumption-record.schema.json') as f:
    s = json.load(f)
props = s.get('properties', {})
# Must not have a field for matched text/content/excerpt
for forbidden in ['matched_text', 'content', 'excerpt', 'source', 'match']:
    assert forbidden not in props, f'Forbidden property {forbidden} in schema'
print('OK: no excerpt fields in schema')
"
}

# ---------------------------------------------------------------------------
# Cycle is stored in each record
# ---------------------------------------------------------------------------

@test "committed consumption records all have cycle field (if any)" {
  for f in consumption/*.json; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == "cycle-ledger.json" ]] && continue
    python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
cycle = d.get('cycle')
assert cycle is not None, f'Missing cycle in $f'
assert isinstance(cycle, int), f'cycle must be int in $f'
assert cycle >= 1, f'cycle must be >= 1 in $f'
"
  done
}
