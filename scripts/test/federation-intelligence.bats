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
import base64
import hashlib
import json, sys
import os
endpoint, sha = sys.argv[1:]
tree_sha = "9999999999999999999999999999999999999999"
repo = "/".join(endpoint.split("/")[1:3])
city_url = "https://raw.githubusercontent.com/kimeisele/agent-city/main/.well-known/agent-federation.json"
descriptor = {"kind": "agent_federation_descriptor", "repo_id": repo, "status": "active", "endpoints": {"authority_descriptor_seeds": "data/federation/authority-descriptor-seeds.json"}}
if "WRONG_ENDPOINT" in os.environ:
    descriptor["endpoints"]["authority_descriptor_seeds"] = "wrong.json"
seeds = {"descriptor_urls": [city_url]}
if "MISSING_URL" in os.environ:
    seeds["descriptor_urls"] = []
if "DUPLICATE_URL" in os.environ:
    seeds["descriptor_urls"].append(city_url)
if "MALFORMED_URL" in os.environ:
    seeds["descriptor_urls"] = ["not-a-url"]
if "CITY_MISMATCH" in os.environ and "agent-city" in repo:
    descriptor["repo_id"] = "kimeisele/agent-world"
if "WRONG_STATUS" in os.environ:
    descriptor["status"] = "inactive"
if "WRONG_KIND" in os.environ:
    descriptor["kind"] = "forged_descriptor"
manifests = {
    "kimeisele/agent-world": b'''[project]\nname = "agent-world"\ndependencies = ["PyYAML>=6.0", "nadi-kit @ git+https://github.com/kimeisele/steward-federation.git"]\n[project.optional-dependencies]\ndev = ["pytest>=8.0"]\n''',
    "kimeisele/agent-internet": b'''[project]\nname = "agent-internet"\ndependencies = ["nadi-kit @ git+https://github.com/kimeisele/steward-federation.git#egg=nadi-kit"]\n[project.optional-dependencies]\nsubstrate = ["steward-protocol[web,crypto]"]\n''',
    "kimeisele/agent-city": b'''[project]\nname = "agent-city"\ndependencies = ["ecdsa>=0.18"]\n[project.optional-dependencies]\nkernel = ["steward-protocol[city]"]\nbrowser = ["agent-internet"]\n''',
}
if "MALFORMED_MANIFEST" in os.environ:
    manifests[repo] = b'[project\nname = "broken"'
if "WRONG_DEPENDENCY_TYPE" in os.environ:
    manifests[repo] = b'[project]\nname = "broken"\ndependencies = "nadi-kit"\n'
if "DYNAMIC_DEPENDENCIES" in os.environ:
    manifests[repo] = b'[project]\nname = "dynamic"\ndynamic = ["dependencies"]\n'
if "UNKNOWN_GIT_TARGET" in os.environ:
    manifests[repo] = b'''[project]\nname = "agent-world"\ndependencies = ["other @ git+https://github.com/kimeisele/other.git"]\n'''
payloads = {
    ".well-known/agent-federation.json": json.dumps(descriptor).encode(),
    "data/federation/authority-descriptor-seeds.json": json.dumps(seeds).encode(),
    "pyproject.toml": manifests[repo],
}
blob_ids = {path: hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest() for path, raw in payloads.items()}
if "/git/commits/" in endpoint:
    response = {"sha": "0000000000000000000000000000000000000000" if "BAD_COMMIT" in os.environ else sha, "tree": {"sha": tree_sha}}
    print(json.dumps(response))
    raise SystemExit
if "/git/blobs/" in endpoint:
    target = next((path for path, blob_sha in blob_ids.items() if blob_sha == sha), None)
    raw = payloads.get(target, b"{}")
    if "SAME_SIZE_BAD_CONTENT" in os.environ and raw:
        raw = raw[:-1] + (b"X" if raw[-1:] != b"X" else b"Y")
    content = base64.b64encode(raw).decode()
    if "BAD_BLOB_BASE64" in os.environ:
        content = "%%%"
    response = {"sha": "0000000000000000000000000000000000000000" if "BAD_BLOB_SHA" in os.environ else sha,
                "size": len(raw) + (1 if "BAD_BLOB_SIZE" in os.environ else 0),
                "encoding": "utf-8" if "BAD_BLOB_ENCODING" in os.environ else "base64", "content": content}
    print(json.dumps(response))
    raise SystemExit
tree = [
        {"path": ".well-known/agent-federation.json", "mode": "100644", "type": "blob", "sha": blob_ids[".well-known/agent-federation.json"], "size": len(payloads[".well-known/agent-federation.json"])},
        {"path": "data/federation/authority-descriptor-seeds.json", "mode": "100644", "type": "blob", "sha": blob_ids["data/federation/authority-descriptor-seeds.json"], "size": len(payloads["data/federation/authority-descriptor-seeds.json"])},
        {"path": "docs/PUBLIC_FEDERATION_SURFACE.md", "mode": "100644", "type": "blob", "sha": "2222222222222222222222222222222222222222", "size": 128},
        {"path": "package.json", "mode": "100644", "type": "blob", "sha": "3333333333333333333333333333333333333333", "size": 256},
        {"path": "src/main.py", "mode": "100644", "type": "blob", "sha": "4444444444444444444444444444444444444444", "size": 512},
        {"path": "pyproject.toml", "mode": "100644", "type": "blob", "sha": blob_ids["pyproject.toml"], "size": len(payloads["pyproject.toml"])},
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
assert all(n["tree"]["counts"]["blob_count"] == 6 for n in index["nodes"])
assert index["dependencies"]["observed_edges"] == []
semantic_edge = next(edge for edge in index["relations"]["declared_edges"] if edge["kind"] == "declared_discovery_seed")
assert len(index["relations"]["declared_edges"]) == 6
assert semantic_edge["target_ref_mutable"] is True
assert index["semantic"]["checks"][0]["status"] == "observed"
seed = next(item for item in index["semantic"]["observations"] if item["record_type"] == "authority_seeds")
assert "descriptor_urls" not in seed and seed["matched_city_descriptor_url"].endswith("agent-city/main/.well-known/agent-federation.json")
assert "display_name" not in json.dumps(index)
assert "description" not in json.dumps(index)
assert all(c["inference_status"] == "candidate_only" for c in index["contracts"]["candidates"])
assert all(c["inference_status"] == "candidate_only" for c in index["dependencies"]["candidates"])
assert all(c["type"] == "blob" and isinstance(c["size"], int) and len(c["sha"]) == 40 for c in index["contracts"]["candidates"])
assert any(c["path"] == "src/main.py" for c in index["entrypoints"])
assert any(c["path"] == ".well-known/agent-federation.json" for c in index["contracts"]["candidates"])
assert all(e["value"] == "pinned_git_tree_metadata" for e in index["evidence"])
assert len(index["relations"]["manifest_observations"]) == 3
assert len(index["relations"]["declared_edges"]) == 6
assert index["dependencies"]["observed_edges"] == []
assert {e["package"] for e in index["relations"]["declared_edges"] if e["kind"] == "declared_package_dependency"} == {"nadi-kit", "steward-protocol", "agent-internet"}
for edge in index["relations"]["declared_edges"]:
    if edge["kind"] != "declared_package_dependency":
        continue
    assert edge["target_scope"] == ("indexed_source" if edge["to_node"] == "kimeisele/agent-internet" else "external_out_of_scope")
    assert edge["target_resolution"] == ("direct_vcs_declaration" if edge["package"] == "nadi-kit" else "package_allowlist_mapping")
    assert edge["target_ref_mutable"] is True
    assert "target revision is unbound and target content is not verified" in edge["confidence"]["caveats"]
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

@test "semantic falsifiers produce bounded non-edge results" {
  for mode in WRONG_ENDPOINT MISSING_URL DUPLICATE_URL MALFORMED_URL CITY_MISMATCH WRONG_STATUS WRONG_KIND; do
    run env "$mode=1" PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
      --pins-root "$WORKDIR/pins" --output "$WORKDIR/$mode.json"
    [ "$status" -eq 0 ]
    python3 - "$WORKDIR/$mode.json" <<'PY'
import json, sys
path = sys.argv[1]
index = json.load(open(path))
for item in index["nodes"] + index["evidence"] + index["semantic"]["observations"]:
    item["repository_pin"] = f"pins/v1-census/{item['node_id'].split('/')[-1]}.json"
for item in index["relations"]["manifest_observations"]:
    item["repository_pin"] = f"pins/v1-census/{item['node_id'].split('/')[-1]}.json"
json.dump(index, open(path, "w"), indent=2)
PY
    run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
      --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/$mode.json"
    [ "$status" -eq 0 ]
    python3 - "$WORKDIR/$mode.json" "$mode" <<'PY'
import json, sys
index, mode = json.load(open(sys.argv[1])), sys.argv[2]
check = index["semantic"]["checks"][0]
assert check["status"] == ("unproven" if mode == "MISSING_URL" else "mismatch")
assert index["dependencies"]["observed_edges"] == []
assert not any(edge["kind"] == "declared_discovery_seed" for edge in index["relations"]["declared_edges"])
assert all("description" not in item for item in index["semantic"]["observations"])
PY
  done
}

@test "semantic blob transport and content binding fail closed" {
  for mode in BAD_BLOB_SHA BAD_BLOB_SIZE BAD_BLOB_ENCODING BAD_BLOB_BASE64 SAME_SIZE_BAD_CONTENT; do
    printf 'sentinel\n' > "$WORKDIR/$mode.json"
    run env "$mode=1" PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
      --pins-root "$WORKDIR/pins" --output "$WORKDIR/$mode.json"
    [ "$status" -ne 0 ]
    grep -qx 'sentinel' "$WORKDIR/$mode.json"
  done
}

@test "manifest parser rejects malformed and typed dependency input" {
  for mode in MALFORMED_MANIFEST WRONG_DEPENDENCY_TYPE DYNAMIC_DEPENDENCIES; do
    printf 'sentinel\n' > "$WORKDIR/$mode.json"
    run env "$mode=1" PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
      --pins-root "$WORKDIR/pins" --output "$WORKDIR/$mode.json"
    [ "$status" -ne 0 ]
    grep -qx 'sentinel' "$WORKDIR/$mode.json"
  done
}

@test "unknown manifest git target produces no allowlist edge" {
  run env UNKNOWN_GIT_TARGET=1 PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --pins-root "$WORKDIR/pins" --output "$WORKDIR/unknown.json"
  [ "$status" -eq 0 ]
  python3 - "$WORKDIR/unknown.json" <<'PY'
import json, sys
index = json.load(open(sys.argv[1]))
assert not any(edge["from_node"] == "kimeisele/agent-world" and edge["kind"] == "declared_package_dependency" for edge in index["relations"]["declared_edges"])
assert index["dependencies"]["observed_edges"] == []
PY
}

@test "validate-only rejects manifest target scope and resolution mismatches" {
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
edge = next(edge for edge in index["relations"]["declared_edges"] if edge["kind"] == "declared_package_dependency" and edge["to_node"] == "kimeisele/agent-internet")
edge["target_scope"] = "external_out_of_scope"
edge["target_resolution"] = "direct_vcs_declaration"
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"target scope or resolution is invalid"* ]]
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
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
for observation in index["semantic"]["observations"]:
    observation["repository_pin"] = f"pins/v1-census/{observation['node_id'].split('/')[-1]}.json"
for manifest in index["relations"]["manifest_observations"]:
    manifest["repository_pin"] = f"pins/v1-census/{manifest['node_id'].split('/')[-1]}.json"
index["contracts"]["observed"].append({})
json.dump(index, open(path, "w"), indent=2)
PY
  run env PATH="$WORKDIR/bin:$PATH" python3 "$REPO_ROOT/scripts/federation-intelligence.py" \
    --validate-only --pins-root "$REPO_ROOT/pins/v1-census" --output "$WORKDIR/index.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"contracts.observed"* ]]
}
