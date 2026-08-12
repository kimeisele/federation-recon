#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/evidence" "$WORKDIR/findings"
  cd "$WORKDIR"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/artifacts.sh"
}

teardown() {
  rm -rf "$WORKDIR"
}

@test "gen_evidence: semantic paths distinguish equal values" {
  first="$(gen_evidence "pins/v1-census/node.json" file_existence true "descriptor.json")"
  second="$(gen_evidence "pins/v1-census/node.json" file_existence true "charter.json")"

  [ "$first" != "$second" ]
  [ -f "$first" ]
  [ -f "$second" ]
  [ "$(python3 -c "import json; print(json.load(open('$first'))['paths'][0])")" = "descriptor.json" ]
  [ "$(python3 -c "import json; print(json.load(open('$second'))['paths'][0])")" = "charter.json" ]
}

@test "gen_evidence: semantic hashes distinguish equal paths and values" {
  first="$(gen_evidence "pins/v1-census/node.json" manifest_field same "descriptor.json" "field=role")"
  second="$(gen_evidence "pins/v1-census/node.json" manifest_field same "descriptor.json" "field=tier")"

  [ "$first" != "$second" ]
  [ -f "$first" ]
  [ -f "$second" ]
}

@test "gen_evidence: field boundaries cannot collide through delimiters" {
  first="$(gen_evidence "pin:a" b c d e)"
  second="$(gen_evidence pin "a:b" c d e)"

  [ "$first" != "$second" ]
}

@test "gen_finding: duplicate evidence references are refused" {
  run gen_finding "duplicate" "ev-one,ev-one" test_domain
  [ "$status" -eq 1 ]
  [ ! -e findings/*.json ]
}
