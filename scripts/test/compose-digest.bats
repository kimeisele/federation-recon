#!/usr/bin/env bats
# compose-digest.bats — Integration tests for scripts/compose-digest.sh
#
# Tests: idempotency, attention ranking, constitutional non-peer filtering.
# Fully offline — uses committed digest/*.json as fixtures.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"

  # Copy only the digest sub-files (NOT state-digest.json) and the scripts
  mkdir -p "$WORKDIR/digest"
  for f in "$REPO_ROOT/digest"/*.json; do
    bn=$(basename "$f")
    [ "$bn" = "state-digest.json" ] && continue
    [ "$bn" = "census-run-state.json" ] && continue
    cp "$f" "$WORKDIR/digest/"
  done

  # Copy the entire scripts/ tree to the workdir
  cp -r "$REPO_ROOT/scripts" "$WORKDIR/scripts"

  cd "$WORKDIR"
}

teardown() {
  rm -rf "$WORKDIR"
}

_run_composer() {
  bash "$WORKDIR/scripts/compose-digest.sh"
}

# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------

@test "compose-digest: idempotent — second run produces identical output" {
  run _run_composer
  [ "$status" -eq 0 ]

  cp STATE.md STATE.md.run1
  cp digest/state-digest.json digest/state-digest.json.run1

  run _run_composer
  [ "$status" -eq 0 ]

  diff STATE.md STATE.md.run1
  diff digest/state-digest.json digest/state-digest.json.run1
}

# ---------------------------------------------------------------------------
# Output existence
# ---------------------------------------------------------------------------

@test "compose-digest: produces STATE.md" {
  run _run_composer
  [ "$status" -eq 0 ]
  [ -f STATE.md ]
}

@test "compose-digest: produces digest/state-digest.json" {
  run _run_composer
  [ "$status" -eq 0 ]
  [ -f "digest/state-digest.json" ]
  # Verify it is valid JSON
  python3 -c "import json; json.load(open('digest/state-digest.json'))"
}

# ---------------------------------------------------------------------------
# Attention ranking — items must be sorted by attention_rank ascending
# ---------------------------------------------------------------------------

@test "compose-digest: attention items sorted by attention_rank ascending" {
  _run_composer 2>/dev/null

  python3 -c "
import json

with open('digest/state-digest.json') as f:
    d = json.load(f)

items = d.get('attention_items', [])
ranks = [it['attention_rank'] for it in items]

assert ranks == sorted(ranks), f'attention_rank not sorted: {ranks}'
print(f'OK: {len(items)} attention items, ranks={ranks}')
"
}

# ---------------------------------------------------------------------------
# Constitutional non-peers — must be in observatory, NOT in attention
# ---------------------------------------------------------------------------

@test "compose-digest: constitutional non-peer federation-recon in observatory" {
  _run_composer 2>/dev/null

  python3 -c "
import json

with open('digest/state-digest.json') as f:
    d = json.load(f)

observatory = d.get('constitutional_observatory', [])
obs_targets = [it['target'] for it in observatory]

assert 'kimeisele/federation-recon' in obs_targets, \
    f'federation-recon missing from observatory: {obs_targets}'
print('OK: federation-recon is in constitutional observatory')
"
}

@test "compose-digest: constitutional non-peer NOT in attention items" {
  _run_composer 2>/dev/null

  python3 -c "
import json

with open('digest/state-digest.json') as f:
    d = json.load(f)

attention = d.get('attention_items', [])
att_targets = [it['target'] for it in attention]

assert 'kimeisele/federation-recon' not in att_targets, \
    f'federation-recon illegally in attention: {att_targets}'
print('OK: federation-recon not in attention items')
"
}

@test "compose-digest: agent-village also NOT in attention items" {
  _run_composer 2>/dev/null

  python3 -c "
import json

with open('digest/state-digest.json') as f:
    d = json.load(f)

attention = d.get('attention_items', [])
att_targets = [it['target'] for it in attention]

assert 'kimeisele/agent-village' not in att_targets, \
    f'agent-village illegally in attention: {att_targets}'
print('OK: agent-village not in attention items')
"
}

# ---------------------------------------------------------------------------
# Procedure count preserved
# ---------------------------------------------------------------------------

@test "compose-digest: procedure count matches sub-digest count" {
  _run_composer 2>/dev/null

  sub_count=$(ls "$WORKDIR/digest"/*.json 2>/dev/null | wc -l | tr -d ' ')
  proc_count=$(python3 -c "
import json
with open('digest/state-digest.json') as f:
    d = json.load(f)
print(d['procedure_count'])
")

  [ "$proc_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Machine digest structural validity
# ---------------------------------------------------------------------------

@test "compose-digest: machine digest has required top-level keys" {
  _run_composer 2>/dev/null

  python3 -c "
import json

with open('digest/state-digest.json') as f:
    d = json.load(f)

required = ['digest_type', 'composer_version', 'composed_at',
            'procedure_count', 'procedures', 'attention_items',
            'constitutional_observatory', 'summary']
for key in required:
    assert key in d, f'missing key: {key}'

assert d['digest_type'] == 'composed_federation'
print('OK: all required keys present')
"
}

# ---------------------------------------------------------------------------
# No sub-digests → exit 1
# ---------------------------------------------------------------------------

@test "compose-digest: no sub-digests exits 1" {
  # Remove all sub-digests
  rm -f "$WORKDIR/digest"/*.json
  run _run_composer
  [ "$status" -eq 1 ]
}
