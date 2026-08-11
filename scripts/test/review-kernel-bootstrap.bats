#!/usr/bin/env bats
# Runner for the sealed RECOVERY-2 bootstrap oracle. This test does not import
# or execute the candidate kernel; it compares the reference evaluator with
# its frozen vectors and expected outcomes.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  ORACLE="$REPO_ROOT/governance/review-kernel-bootstrap/v2"
  EVALUATOR="$ORACLE/evaluator.py"
  VECTORS="$ORACLE/vectors.json"
  EXPECTED="$ORACLE/expected.json"
  DIGESTS="$ORACLE/digests.json"
  SEAL_PATHS=(
    governance/review-kernel-bootstrap/v2/manifest.json
    governance/review-kernel-bootstrap/v2/vectors.json
    governance/review-kernel-bootstrap/v2/expected.json
    governance/review-kernel-bootstrap/v2/digests.json
    governance/review-kernel-bootstrap/v2/evaluator.py
    scripts/test/review-kernel-bootstrap.bats
    scripts/test/MANIFEST
  )
}

commit_seal_check() {
  local root="$1" canonical="${2:-1}" head expected actual path
  root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$canonical" -eq 0 ] || [ "$root" = "$REPO_ROOT" ] || return 1
  head="$(git -C "$root" rev-parse --verify HEAD 2>/dev/null)" || return 1
  [[ "$head" =~ ^[0-9a-f]{40,64}$ ]] || return 1
  [ -z "$(git -C "$root" status --porcelain --untracked-files=all 2>/dev/null)" ] || return 1
  expected="$(printf '%s\n' "${SEAL_PATHS[@]}" | LC_ALL=C sort)"
  actual="$(git -C "$root" ls-tree -r --name-only "$head" -- "${SEAL_PATHS[@]}" | LC_ALL=C sort)"
  [ "$actual" = "$expected" ] || return 1
  for path in "${SEAL_PATHS[@]}"; do
    [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || return 1
  done
  git -C "$root" diff --quiet "$head" -- "${SEAL_PATHS[@]}" || return 1
  printf '%s\n' "$head"
}

run_corpus_evaluator() {
  local head blob_evaluator
  head="$(commit_seal_check "$REPO_ROOT" 2>/dev/null)" || {
    echo "FAIL — commit seal unavailable; root commit and clean tracked worktree required" >&2
    return 1
  }
  blob_evaluator="$BATS_TEST_TMPDIR/evaluator-from-$head.py"
  git -C "$REPO_ROOT" show "$head:governance/review-kernel-bootstrap/v2/evaluator.py" >"$blob_evaluator" || return 1
  python3 "$blob_evaluator" --corpus-root "$ORACLE"
}

make_seal_fixture() {
  local root="$1" path
  for path in "${SEAL_PATHS[@]}"; do
    mkdir -p "$root/$(dirname "$path")"
    cp "$REPO_ROOT/$path" "$root/$path"
  done
  git -C "$root" init -q
  git -C "$root" config user.email test@example.invalid
  git -C "$root" config user.name Test
  git -C "$root" add -- "${SEAL_PATHS[@]}"
  git -C "$root" commit -qm baseline
}

@test "commit-sealed corpus evaluation requires the clean tracked root" {
  run run_corpus_evaluator
  [ "$status" -eq 0 ]
  python3 - "$output" "$EXPECTED" "$ORACLE/manifest.json" "$VECTORS" <<'PY'
import json
import sys
actual = json.loads(sys.argv[1])
expected = json.load(open(sys.argv[2]))
manifest = json.load(open(sys.argv[3]))
vectors = json.load(open(sys.argv[4]))
assert actual["evaluator_version"] == "r2-bootstrap-evaluator-1"
assert actual["input_mode"] == "CORPUS_INTEGRITY_VERIFIED"
assert actual["outcomes"] == expected
assert manifest["evaluator_version"] == actual["evaluator_version"]
ids = {vector["id"] for vector in vectors}
assert set(expected) == ids
properties = manifest["properties"]
assert all(set(item) == {"id", "vectors"} for item in properties)
assert len({item["id"] for item in properties}) == len(properties)
refs = {ref for item in properties for ref in item["vectors"]}
assert refs == ids
assert manifest["files"] == ["manifest.json", "vectors.json", "expected.json", "digests.json", "evaluator.py"]
assert manifest["corpus_files"] == ["manifest.json", "vectors.json", "expected.json", "evaluator.py"]
assert manifest["harness"] == "scripts/test/review-kernel-bootstrap.bats"
assert manifest["outcome_enum"] == ["APPROVE", "REJECT", "HOLD", "STALE"]
assert manifest["stored_verdict_enum"] == ["APPROVE", "REJECT", "PARTIAL", "STALE", "HOLD"]
rules = manifest["mutation_rules"]
for fragment in ("reservation_id", "inconclusive", "provider/model", "run_id date"):
    assert any(fragment in rule for rule in rules), fragment
for fragment in ("Synthetic records", "production adapter", "fail closed", "Provider changes alone", "Guard+Owner-Audit+adversarial review", "freeze/activation Guard-PR v2"):
    assert fragment in manifest["non_coverage"], fragment

groups = {
    "APPROVE": {"approve", "partial-stored", "provider-mismatch", "sha64", "fabricated-provenance"},
    "REJECT": {"blocking-confirmed", "tier0-fail"},
    "STALE": {"stale"},
    "HOLD": {"blocking-inconclusive", "blocking-not-run", "budget-head-mismatch", "budget-run-mismatch", "claimed-blocking-downgraded", "cost-missing", "cost-negative", "duplicate-finding-id", "evidence-digest-mismatch", "extra-field", "finding-error", "finding-unrun", "high-tier2-not-run", "legacy-v1", "malformed-sha", "mandatory-incomplete", "missing-reservation", "missing-tasks", "nonblocking-inconclusive", "reservation-digest-mismatch", "run-date-mismatch", "tier0-error", "tier0-unavailable", "tier2-complete", "tier2-error", "tokens-boolean", "unavailable-current", "unknown-stored", "usage-incomplete", "wrong-finding-tier", "wrong-findings-type", "wrong-pr"},
}
assert set().union(*groups.values()) == ids
assert sum(len(group) for group in groups.values()) == len(ids)
for outcome, identifiers in groups.items():
    assert all(actual["outcomes"][identifier] == outcome for identifier in identifiers), outcome
PY
}

@test "bootstrap oracle digests bind evaluator, corpus, and manifest" {
  python3 - "$ORACLE" "$DIGESTS" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
record = json.load(open(sys.argv[2]))
manifest = json.load(open(root / "manifest.json"))
names = ["manifest.json", "vectors.json", "expected.json", "evaluator.py"]
assert set(record) == {"digest_version", "corpus_sha256", "harness_sha256", *[name + "_sha256" for name in names]}
assert record["digest_version"] == "sha256-name-nul-bytes-nul-v1"
assert manifest["files"] == ["manifest.json", "vectors.json", "expected.json", "digests.json", "evaluator.py"]
assert manifest["corpus_files"] == names
assert record["harness_sha256"] == hashlib.sha256((root.parents[2] / "scripts/test/review-kernel-bootstrap.bats").read_bytes()).hexdigest()
for name in names:
    digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assert record[name + "_sha256"] == digest, name
h = hashlib.sha256()
for name in names:
    h.update(name.encode())
    h.update(b"\0")
    h.update((root / name).read_bytes())
    h.update(b"\0")
assert record["corpus_sha256"] == h.hexdigest()
PY
}

@test "harness reports commit seal only for a clean tracked root" {
  local head
  head="$(commit_seal_check "$REPO_ROOT")"
  echo "SEALED_AT_COMMIT head_sha=$head"
  [[ "$head" =~ ^[0-9a-f]{40,64}$ ]]
}

@test "commit seal blocks corpus mutation and evaluator symlink before blob execution" {
  local fixture head blob fake
  fixture="$BATS_TEST_TMPDIR/clean-seal"
  mkdir -p "$fixture"
  make_seal_fixture "$fixture"
  head="$(commit_seal_check "$fixture" 0)"
  [ -n "$head" ]
  blob="$BATS_TEST_TMPDIR/blob-evaluator.py"
  git -C "$fixture" show "$head:governance/review-kernel-bootstrap/v2/evaluator.py" >"$blob"
  run python3 "$blob" --corpus-root "$fixture/governance/review-kernel-bootstrap/v2"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"input_mode":"CORPUS_INTEGRITY_VERIFIED"'* ]]

  printf '\nmutation\n' >> "$fixture/governance/review-kernel-bootstrap/v2/vectors.json"
  run commit_seal_check "$fixture" 0
  [ "$status" -ne 0 ]

  fixture="$BATS_TEST_TMPDIR/symlink-seal"
  mkdir -p "$fixture"
  make_seal_fixture "$fixture"
  unlink "$fixture/governance/review-kernel-bootstrap/v2/evaluator.py"
  ln -s manifest.json "$fixture/governance/review-kernel-bootstrap/v2/evaluator.py"
  run commit_seal_check "$fixture" 0
  [ "$status" -ne 0 ]

  fixture="$BATS_TEST_TMPDIR/fake-git-copy"
  mkdir -p "$fixture"
  make_seal_fixture "$fixture"
  fake="$BATS_TEST_TMPDIR/fake-git-copy-clone"
  cp -R "$fixture" "$fake"
  run commit_seal_check "$fake"
  [ "$status" -ne 0 ]
}

@test "bootstrap oracle mutation discrimination rejects missing reservation" {
  mutated="$BATS_TEST_TMPDIR/mutated-vectors.json"
  cp "$VECTORS" "$mutated"
  python3 - "$mutated" <<'PY'
import json
import sys
path = sys.argv[1]
vectors = json.load(open(path))
for vector in vectors:
    if vector["id"] == "approve":
        del vector["verdict"]["budget"]["reservation_id"]
        break
else:
    raise SystemExit("approve vector not found")
json.dump(vectors, open(path, "w"), indent=2)
PY
  run python3 "$EVALUATOR" --vectors "$mutated"
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["input_mode"] == "UNSEALED_FIXTURE"
assert result["outcomes"]["approve"] == "HOLD"
PY
}

@test "bootstrap oracle covers relational, identity, finding, and provider mutations" {
  python3 - "$VECTORS" "$BATS_TEST_TMPDIR/provider-varied.json" <<'PY'
import copy
import hashlib
import json
import sys

source, target = sys.argv[1:]
vectors = json.load(open(source))
def digest(value):
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return hashlib.sha256(payload).hexdigest()
for vector in vectors:
    if vector["id"] == "approve":
        item = vector["verdict"]["budget"]["provider_evidence"]["review-analysis"]
        item["provider"] = "alternate-provider"
        item["evidence_sha256"] = digest({key: item[key] for key in item if key != "evidence_sha256"})
        budget = vector["verdict"]["budget"]
        budget["reservation_sha256"] = digest({key: budget[key] for key in budget if key != "reservation_sha256"})
        break
else:
    raise SystemExit("approve vector not found")
json.dump(vectors, open(target, "w"), ensure_ascii=False, indent=2)
PY
  run python3 "$EVALUATOR" --vectors "$BATS_TEST_TMPDIR/provider-varied.json"
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys
outcomes = json.loads(sys.argv[1])["outcomes"]
assert json.loads(sys.argv[1])["input_mode"] == "UNSEALED_FIXTURE"
assert outcomes["approve"] == "APPROVE"
for identifier in ("unknown-stored", "finding-error", "nonblocking-inconclusive", "finding-unrun", "duplicate-finding-id", "wrong-finding-tier", "run-date-mismatch", "budget-run-mismatch", "budget-head-mismatch", "evidence-digest-mismatch", "reservation-digest-mismatch"):
    assert outcomes[identifier] == "HOLD", identifier
assert outcomes["tier0-error"] == "HOLD"
assert outcomes["provider-mismatch"] == "APPROVE"
PY
}

@test "bootstrap evaluator has no candidate-kernel dependency" {
  ! grep -qE 'scripts/review-verdict\.sh|schemas/review-verdict\.schema\.json' "$EVALUATOR"
}

@test "an external evaluator copy cannot enter corpus mode without an explicit root" {
  external="$BATS_TEST_TMPDIR/external/v2/evaluator.py"
  mkdir -p "$(dirname "$external")"
  cp "$EVALUATOR" "$external"
  run python3 "$external"
  [ "$status" -ne 0 ]
}

@test "explicit --corpus-root verifies corpus integrity without commit authority" {
  run python3 "$EVALUATOR" --corpus-root "$ORACLE"
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys
assert json.loads(sys.argv[1])["input_mode"] == "CORPUS_INTEGRITY_VERIFIED"
PY
}

@test "bootstrap evaluator rejects non-finite and negative cost mutations" {
  mutated="$BATS_TEST_TMPDIR/nonfinite-vectors.json"
  python3 - "$VECTORS" "$mutated" <<'PY'
import json
import sys
vectors = json.load(open(sys.argv[1]))
for vector in vectors:
    if vector["id"] == "approve":
        vector["verdict"]["budget"]["provider_evidence"]["review-analysis"]["cost_usd"] = float("nan")
        break
json.dump(vectors, open(sys.argv[2], "w"), allow_nan=True)
PY
  run python3 "$EVALUATOR" --vectors "$mutated"
  [ "$status" -eq 0 ]
  python3 - "$output" <<'PY'
import json
import sys
result = json.loads(sys.argv[1])
assert result["input_mode"] == "UNSEALED_FIXTURE"
assert result["outcomes"]["approve"] == "HOLD"
PY
}
