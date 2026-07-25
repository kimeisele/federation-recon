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
assert 'finding_path' in enum
assert 'drift_path' in enum
assert 'evidence_path' in enum
assert 'url_slug' in enum
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

@test "v2-consumption sub-digest summary has consumption_records and cycle (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "
import json
with open('digest/v2-consumption.json') as f:
    d = json.load(f)
summary = d.get('summary', {})
assert 'consumption_records' in summary
assert 'cycle' in summary
assert isinstance(summary['consumption_records'], int)
assert isinstance(summary['cycle'], int)
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

@test "v2-consumption sub-digest renders zero-count as explicit (if present)" {
  if [ ! -f "digest/v2-consumption.json" ]; then
    skip "No committed v2-consumption sub-digest — skipping"
  fi
  python3 -c "
import json
with open('digest/v2-consumption.json') as f:
    d = json.load(f)
count = d.get('summary', {}).get('consumption_records', -1)
if count == 0:
    # Zero must have attention items stating the fact
    items = d.get('attention_items', [])
    assert len(items) > 0, 'Zero consumption must produce attention items'
    headline = items[0].get('headline', '')
    assert 'ZERO' in headline, f'Zero consumption headline must say ZERO: {headline}'
    print('OK: zero consumption explicitly rendered')
else:
    print(f'SKIP: consumption count = {count}, not testing zero case')
"
}

# ---------------------------------------------------------------------------
# Self-reference exclusion
# ---------------------------------------------------------------------------

@test "committed consumption records never reference federation-recon (self-exclusion)" {
  for f in consumption/*.json; do
    [ -f "$f" ] || continue
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
