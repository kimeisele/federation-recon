#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORKDIR="$(mktemp -d)"
  mkdir -p "$WORKDIR/pins" "$WORKDIR/bin"
  cp "$REPO_ROOT/pins/v1-census/agent-world.json" "$WORKDIR/pins/"
  cp "$REPO_ROOT/pins/v1-census/agent-internet.json" "$WORKDIR/pins/"
  cp "$REPO_ROOT/pins/v1-census/agent-city.json" "$WORKDIR/pins/"
  cat > "$WORKDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = api ] || exit 2
[ -z "${FAIL_TREE:-}" ] || exit 1
endpoint="${2:-}"
sha="${endpoint##*/git/}"
sha="${sha##*/}"
sha="${sha%%\?*}"
python3 - "$endpoint" "$sha" <<'PY'
import json, sys
import os
endpoint, sha = sys.argv[1:]
tree_sha = "9999999999999999999999999999999999999999"
if "/git/commits/" in endpoint:
    response = {"sha": "0000000000000000000000000000000000000000" if "BAD_COMMIT" in os.environ else sha, "tree": {"sha": tree_sha}}
    print(json.dumps(response))
    raise SystemExit
tree = [
        {"path": ".well-known/agent-federation.json", "mode": "100644", "type": "blob", "sha": "1111111111111111111111111111111111111111", "size": 64},
        {"path": "docs/PUBLIC_FEDERATION_SURFACE.md", "mode": "100644", "type": "blob", "sha": "2222222222222222222222222222222222222222", "size": 128},
        {"path": "package.json", "mode": "100644", "type": "blob", "sha": "3333333333333333333333333333333333333333", "size": 256},
        {"path": "src/main.py", "mode": "100644", "type": "blob", "sha": "4444444444444444444444444444444444444444", "size": 512},
        {"path": "src", "mode": "040000", "type": "tree", "sha": "5555555555555555555555555555555555555555"}
]
if "MANY_ENTRIES" in __import__("os").environ:
    tree.extend({"path": f"generated/{i:03d}/main.py", "mode": "100644", "type": "blob", "sha": f"{i:040x}", "size": i} for i in range(129))
if "PATH_ALIAS" in os.environ:
    tree.append({"path": "./src/main.py", "mode": "100644", "type": "blob", "sha": "6666666666666666666666666666666666666666", "size": 3})
print(json.dumps({
    "sha": "8888888888888888888888888888888888888888" if "BAD_TREE" in os.environ else tree_sha,
    "truncated": "TRUNCATED" in os.environ,
    "tree": tree
}))
PY
EOF
  chmod +x "$WORKDIR/bin/gh"
}

teardown() {
  rm -rf "$WORKDIR"
}

run_index() {
  env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --pins-root "$WORKDIR/pins" --output "$1"
}

@test "federation intelligence index is deterministic and separates candidates from observations" {
  run run_index "$WORKDIR/index-a.json"
  [ "$status" -eq 0 ]
  run run_index "$WORKDIR/index-b.json"
  [ "$status" -eq 0 ]
  cmp "$WORKDIR/index-a.json" "$WORKDIR/index-b.json"

  python3 - "$WORKDIR/index-a.json" "$REPO_ROOT/schemas/federation-intelligence.schema.json" <<'PY'
import json, sys
index = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
assert schema["properties"]["schema"]["const"] == index["schema"]
assert index["schema"] == "federation-intelligence-v0"
assert index["scope"]["source_state"] == "historical_pinned_commits"
assert index["scope"]["current_branch_state_checked"] is False
assert len(index["nodes"]) == 3
assert all(n["source_state"] == "historical_pinned_commit" for n in index["nodes"])
assert all(n["tree"]["sha"] == "9999999999999999999999999999999999999999" for n in index["nodes"])
assert all(n["commit_sha"] == n["pin_sha"] for n in index["nodes"])
assert all(n["dirty_state_assertion"] is False for n in index["nodes"])
assert all("tree_entries" not in n for n in index["nodes"])
assert all(n["tree"]["counts"]["blob_count"] == 4 for n in index["nodes"])
assert index["dependencies"]["observed_edges"] == []
assert all(c["inference_status"] == "candidate_only" for c in index["contracts"]["candidates"])
assert all(c["inference_status"] == "candidate_only" for c in index["dependencies"]["candidates"])
assert all(c["type"] == "blob" and isinstance(c["size"], int) and len(c["sha"]) == 40 for c in index["contracts"]["candidates"])
assert any(c["path"] == "src/main.py" for c in index["entrypoints"])
assert any(c["path"] == ".well-known/agent-federation.json" for c in index["contracts"]["candidates"])
assert all(e["value"] == "pinned_git_tree_metadata" for e in index["evidence"])
PY
}

@test "unavailable pinned tree leaves no partial output and preserves an existing output" {
  printf 'sentinel\n' > "$WORKDIR/index.json"
  run env FAIL_TREE=1 PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --pins-root "$WORKDIR/pins" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  grep -qx 'sentinel' "$WORKDIR/index.json"
  [[ "$output" == *"input unavailable"* ]]
}

@test "missing pinned input fails before writing an index" {
  rm "$WORKDIR/pins/agent-city.json"
  run run_index "$WORKDIR/missing.json"
  [ "$status" -ne 0 ]
  [ ! -e "$WORKDIR/missing.json" ]
  [[ "$output" == *"input unavailable"* ]]
}

@test "candidate cap fails closed instead of silently truncating" {
  printf 'sentinel\n' > "$WORKDIR/capped.json"
  run env MANY_ENTRIES=1 PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --pins-root "$WORKDIR/pins" --output "$WORKDIR/capped.json"
  [ "$status" -ne 0 ]
  grep -qx 'sentinel' "$WORKDIR/capped.json"
  [[ "$output" == *"candidate cap exceeded"* ]]
}

@test "commit, tree binding, truncation, and canonical paths fail closed" {
  for mode in BAD_COMMIT BAD_TREE TRUNCATED PATH_ALIAS; do
    printf 'sentinel\n' > "$WORKDIR/$mode.json"
    run env "$mode=1" PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
      --pins-root "$WORKDIR/pins" --output "$WORKDIR/$mode.json"
    [ "$status" -ne 0 ]
    grep -qx 'sentinel' "$WORKDIR/$mode.json"
  done
}

@test "validate-only rejects an evidence reference that does not resolve" {
  run run_index "$WORKDIR/index.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/index.json" "$REPO_ROOT/pins/v1-census" <<'PY'
import json, sys
path, pins = sys.argv[1:]
index = json.load(open(path))
for node in index["nodes"]:
    node["repository_pin"] = f"pins/v1-census/{node['node_id'].split('/')[-1]}.json"
for evidence in index["evidence"]:
    evidence["repository_pin"] = f"pins/v1-census/{evidence['node_id'].split('/')[-1]}.json"
index["entrypoints"][0]["evidence_refs"] = ["missing-evidence"]
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"evidence reference"* ]]
}

@test "validate-only rejects evidence with a mismatched tree binding" {
  run run_index "$WORKDIR/index.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/index.json" <<'PY'
import json, sys
path = sys.argv[1]
index = json.load(open(path))
for node in index["nodes"]:
    node["repository_pin"] = f"pins/v1-census/{node['node_id'].split('/')[-1]}.json"
for evidence in index["evidence"]:
    evidence["repository_pin"] = f"pins/v1-census/{evidence['node_id'].split('/')[-1]}.json"
index["evidence"][0]["tree_sha"] = "8888888888888888888888888888888888888888"
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"commit/tree binding"* ]]
}

@test "verify-source rejects a candidate metadata mutation" {
  run run_index "$WORKDIR/index.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/index.json" <<'PY'
import json, sys
path = sys.argv[1]
index = json.load(open(path))
for node in index["nodes"]:
    node["repository_pin"] = f"pins/v1-census/{node['node_id'].split('/')[-1]}.json"
for evidence in index["evidence"]:
    evidence["repository_pin"] = f"pins/v1-census/{evidence['node_id'].split('/')[-1]}.json"
index["entrypoints"][0]["sha"] = "7777777777777777777777777777777777777777"
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --verify-source --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source verification mismatch"* ]]
}

@test "validate-only rejects a candidate path alias" {
  run run_index "$WORKDIR/index.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/index.json" <<'PY'
import json, sys
path = sys.argv[1]
index = json.load(open(path))
for node in index["nodes"]:
    node["repository_pin"] = f"pins/v1-census/{node['node_id'].split('/')[-1]}.json"
for evidence in index["evidence"]:
    evidence["repository_pin"] = f"pins/v1-census/{evidence['node_id'].split('/')[-1]}.json"
index["entrypoints"][0]["path"] = "./src/main.py"
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"entrypoints[0].path is not a canonical POSIX path"* ]]
}

@test "validate-only rejects an observed contract record" {
  run run_index "$WORKDIR/index.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/index.json" <<'PY'
import json, sys
path = sys.argv[1]
index = json.load(open(path))
for node in index["nodes"]:
    node["repository_pin"] = f"pins/v1-census/{node['node_id'].split('/')[-1]}.json"
for evidence in index["evidence"]:
    evidence["repository_pin"] = f"pins/v1-census/{evidence['node_id'].split('/')[-1]}.json"
index["contracts"]["observed"].append({})
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contracts.observed"* ]]
}
