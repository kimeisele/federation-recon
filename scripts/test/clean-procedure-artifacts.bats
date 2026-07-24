#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR"/{claims,evidence,coverage,drift,findings}
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "procedure cleanup removes v0 outputs and preserves unrelated procedure files" {
  cat > "$WORKDIR/claims/v0.json" <<'JSON'
{"claim_id":"claim-v0","repository_pin":"pins/v0-boundary-drift/node.json"}
JSON
  cat > "$WORKDIR/evidence/v0.json" <<'JSON'
{"evidence_id":"ev-v0","procedure_id":"boundary-drift-recon-v0"}
JSON
  cat > "$WORKDIR/coverage/v0.json" <<'JSON'
{"coverage_id":"cov-v0","procedure_id":"boundary-drift-recon-v0"}
JSON
  cat > "$WORKDIR/drift/v0.json" <<'JSON'
{"drift_id":"drift-v0","claim_observation":"claim-v0","evidence":"ev-v0"}
JSON
  cat > "$WORKDIR/findings/v0-evidence.json" <<'JSON'
{"finding_id":"finding-v0-a","evidence_refs":["evidence/ev-v0.json"]}
JSON
  cat > "$WORKDIR/findings/v0-coverage.json" <<'JSON'
{"finding_id":"finding-v0-b","evidence_refs":["cov-v0"]}
JSON
  cat > "$WORKDIR/evidence/v1.json" <<'JSON'
{"evidence_id":"ev-v1","procedure_id":"node-census-v1"}
JSON
  cat > "$WORKDIR/findings/v1.json" <<'JSON'
{"finding_id":"finding-v1","evidence_refs":["ev-v1"]}
JSON
  printf '%s\n' 'evidence/v0.json' > "$WORKDIR/keep.txt"

  run python3 "$REPO_ROOT/scripts/clean-procedure-artifacts.py" \
    --root "$WORKDIR" \
    --procedure-id boundary-drift-recon-v0 \
    --pin-prefix pins/v0-boundary-drift/ \
    --keep-file "$WORKDIR/keep.txt"
  [ "$status" -eq 0 ]
  [ ! -e "$WORKDIR/claims/v0.json" ]
  [ -e "$WORKDIR/evidence/v0.json" ]
  [ ! -e "$WORKDIR/coverage/v0.json" ]
  [ ! -e "$WORKDIR/drift/v0.json" ]
  [ ! -e "$WORKDIR/findings/v0-evidence.json" ]
  [ ! -e "$WORKDIR/findings/v0-coverage.json" ]
  [ -e "$WORKDIR/evidence/v1.json" ]
  [ -e "$WORKDIR/findings/v1.json" ]
}
