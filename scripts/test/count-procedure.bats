#!/usr/bin/env bats
# count-procedure.bats — Unit tests for scripts/lib/count_procedure.py
#
# Verifies per-procedure artifact attribution against the committed fixpoint:
#   pins by namespace subdir, evidence/coverage by procedure_id,
#   findings/drift via referenced evidence. Offline, deterministic.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
  cd "$REPO_ROOT"
}

run_counts() {
  python3 scripts/lib/count_procedure.py "$1" "$2"
}

field() {
  python3 -c "import json,sys;print(json.load(sys.stdin)['$1'])"
}

@test "v0: pins counted from its own namespace subdir (not flat pins/)" {
  result="$(run_counts boundary-drift-recon-v0 v0-boundary-drift)"
  expected="$(ls pins/v0-boundary-drift/*.json 2>/dev/null | wc -l | tr -d ' ')"
  [ "$(echo "$result" | field pins)" -eq "$expected" ]
  [ "$(echo "$result" | field pins)" -gt 0 ]
}

@test "v1: pins counted from its own namespace subdir" {
  result="$(run_counts node-census-v1 v1-census)"
  expected="$(ls pins/v1-census/*.json 2>/dev/null | wc -l | tr -d ' ')"
  [ "$(echo "$result" | field pins)" -eq "$expected" ]
}

@test "evidence is attributed by procedure_id, not commingled" {
  v0="$(run_counts boundary-drift-recon-v0 v0-boundary-drift | field evidence)"
  v1="$(run_counts node-census-v1 v1-census | field evidence)"
  total="$(ls evidence/*.json | wc -l | tr -d ' ')"
  # per-procedure counts must sum to the true disk total (no double-count)
  [ "$(( v0 + v1 ))" -eq "$total" ]
  # and they must differ (proving they are not both the commingled total)
  [ "$v0" -ne "$v1" ]
}

@test "coverage is attributed by procedure_id and sums to disk total" {
  v0="$(run_counts boundary-drift-recon-v0 v0-boundary-drift | field coverage)"
  v1="$(run_counts node-census-v1 v1-census | field coverage)"
  total="$(ls coverage/*.json | wc -l | tr -d ' ')"
  [ "$(( v0 + v1 ))" -eq "$total" ]
}

@test "an unknown procedure_id yields zero attributed artifacts" {
  result="$(run_counts no-such-procedure v0-boundary-drift)"
  [ "$(echo "$result" | field evidence)" -eq 0 ]
  [ "$(echo "$result" | field coverage)" -eq 0 ]
  [ "$(echo "$result" | field findings)" -eq 0 ]
}

@test "--sh emits five space-separated integers" {
  out="$(python3 scripts/lib/count_procedure.py boundary-drift-recon-v0 v0-boundary-drift --sh)"
  # exactly 5 fields, all integers
  [ "$(echo "$out" | wc -w | tr -d ' ')" -eq 5 ]
  for n in $out; do [[ "$n" =~ ^[0-9]+$ ]]; done
}
