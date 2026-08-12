#!/usr/bin/env python3
"""Build the bounded, read-only federation intelligence index.

Only immutable GitHub tree metadata at the committed v1-census pins is read.
The output is deliberately candidate-oriented: a path name is not proof that
a contract is exposed or that a dependency is actually used.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import tomllib


PROCEDURE_ID = "federation-intelligence-v0"
PROCEDURE_VERSION = "1"
MAX_CANDIDATES_PER_KIND = 128
MAX_SEMANTIC_BLOB_BYTES = 16 * 1024
CLUSTER = (
    ("kimeisele/agent-world", "agent-world"),
    ("kimeisele/agent-internet", "agent-internet"),
    ("kimeisele/agent-city", "agent-city"),
)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
KNOWN_ENTRYPOINTS = {
    "app.py", "cli.py", "index.js", "index.ts", "main.go", "main.py",
    "main.rs", "server.py",
}
KNOWN_CONTRACT_BASENAMES = {
    "CONSTITUTION.md", "FEDERATION_ROLES.md", "PUBLIC_FEDERATION_SURFACE.md",
    "REPO_BOUNDARIES.md", "agent-federation.json",
}
KNOWN_DEPENDENCY_MANIFESTS = {
    "Cargo.toml", "Gemfile", "Package.swift", "Pipfile", "Pipfile.lock",
    "composer.json", "go.mod", "package-lock.json", "package.json",
    "pnpm-lock.yaml", "poetry.lock", "pyproject.toml", "requirements.txt",
    "requirements-dev.txt", "yarn.lock",
}
SEMANTIC_TARGETS = (
    ("kimeisele/agent-internet", ".well-known/agent-federation.json", "internet_descriptor"),
    ("kimeisele/agent-internet", "data/federation/authority-descriptor-seeds.json", "authority_seeds"),
    ("kimeisele/agent-city", ".well-known/agent-federation.json", "city_descriptor"),
)
MANIFEST_TARGETS = tuple((repo, "pyproject.toml") for repo, _ in CLUSTER)
PACKAGE_TARGETS = {
    "nadi-kit": "kimeisele/steward-federation",
    "steward-protocol": "kimeisele/steward-protocol",
    "agent-internet": "kimeisele/agent-internet",
}
GIT_DEP_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*@\s*git\+https://github\.com/(kimeisele/[A-Za-z0-9_.-]+)\.git(?:#.*)?$")
DEP_NAME_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\[[A-Za-z0-9_.-]+(?:,[A-Za-z0-9_.-]+)*\])?(?:\s*(?:[<>=!~]=?|\^).*)?$")
MANIFEST_EDGE_ALLOWLIST = (
    ("kimeisele/agent-world", "runtime", "nadi-kit", "kimeisele/steward-federation"),
    ("kimeisele/agent-internet", "runtime", "nadi-kit", "kimeisele/steward-federation"),
    ("kimeisele/agent-internet", "substrate", "steward-protocol", "kimeisele/steward-protocol"),
    ("kimeisele/agent-city", "kernel", "steward-protocol", "kimeisele/steward-protocol"),
    ("kimeisele/agent-city", "browser", "agent-internet", "kimeisele/agent-internet"),
)
MANIFEST_EDGE_KIND = "declared_package_dependency"
TARGET_CAVEAT = "target revision is unbound and target content is not verified"
EXPECTED_CITY_URL = "https://raw.githubusercontent.com/kimeisele/agent-city/main/.well-known/agent-federation.json"
SEED_URL_RE = re.compile(r"^https://raw\.githubusercontent\.com/kimeisele/[a-z0-9][a-z0-9._-]*/main/\.well-known/agent-federation\.json$")


class InputError(Exception):
    """A pinned input cannot be trusted as a complete observation."""


def canonical_sha256(value: object) -> str:
    raw = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(raw).hexdigest()


def read_json(path: Path) -> dict:
    if path.is_symlink() or not path.is_file():
        raise InputError(f"pinned input is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise InputError(f"cannot read pinned input {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise InputError(f"pinned input is not an object: {path}")
    return value


def load_pin(pin_path: Path, repo: str) -> dict:
    pin = read_json(pin_path)
    required = ("repository", "requested_ref", "resolved_commit_sha", "observation_timestamp", "acquisition_method", "dirty_state_assertion")
    missing = [field for field in required if field not in pin]
    if missing:
        raise InputError(f"{pin_path}: missing pin fields: {', '.join(missing)}")
    if set(pin) != set(required):
        raise InputError(f"{pin_path}: unknown pin fields")
    if (pin["repository"] != repo or not isinstance(pin["requested_ref"], str)
            or not isinstance(pin["acquisition_method"], str)
            or not isinstance(pin["dirty_state_assertion"], bool)):
        raise InputError(f"{pin_path}: repository/ref does not match the fixed cluster")
    sha = pin["resolved_commit_sha"]
    if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
        raise InputError(f"{pin_path}: resolved_commit_sha is not a 40-character lowercase SHA")
    timestamp = pin["observation_timestamp"]
    if not isinstance(timestamp, str) or not timestamp.endswith("Z"):
        raise InputError(f"{pin_path}: observation_timestamp is not UTC")
    try:
        from datetime import datetime
        parsed = datetime.fromisoformat(timestamp[:-1] + "+00:00")
    except ValueError as exc:
        raise InputError(f"{pin_path}: invalid observation_timestamp") from exc
    if parsed.tzinfo is None:
        raise InputError(f"{pin_path}: observation_timestamp has no timezone")
    return pin


def read_api(repo: str, endpoint: str) -> dict:
    try:
        completed = subprocess.run(
            ["gh", "api", f"repos/{repo}/{endpoint}"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InputError(f"GitHub read failed for {repo}: {exc}") from exc
    if completed.returncode != 0:
        raise InputError(f"GitHub read failed for {repo}")
    try:
        value = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise InputError(f"GitHub response is not JSON for {repo}") from exc
    if not isinstance(value, dict):
        raise InputError(f"GitHub response is not an object for {repo}")
    return value


def read_commit(repo: str, commit_sha: str) -> dict:
    commit = read_api(repo, f"git/commits/{commit_sha}")
    if commit.get("sha") != commit_sha or not isinstance(commit.get("tree"), dict):
        raise InputError(f"commit response is not bound to pin for {repo}")
    tree_sha = commit["tree"].get("sha")
    if not isinstance(tree_sha, str) or not SHA_RE.fullmatch(tree_sha):
        raise InputError(f"commit response has no valid tree SHA for {repo}")
    return {"sha": commit_sha, "tree_sha": tree_sha}


def read_tree(repo: str, commit_sha: str, tree_sha: str) -> dict:
    tree = read_api(repo, f"git/trees/{tree_sha}?recursive=1")
    if tree.get("sha") != tree_sha or tree.get("truncated") is not False:
        raise InputError(f"Git tree response is incomplete or not bound to commit for {repo}")
    raw_entries = tree.get("tree")
    if not isinstance(raw_entries, list):
        raise InputError(f"Git tree response has no complete entry list for {repo}")

    entries = []
    seen = set()
    for raw in raw_entries:
        if not isinstance(raw, dict):
            raise InputError(f"malformed Git tree entry for {repo}")
        path = raw.get("path")
        mode = raw.get("mode")
        kind = raw.get("type")
        entry_sha = raw.get("sha")
        if not isinstance(path, str) or not path or "\x00" in path or path.startswith("/") or "\\" in path:
            raise InputError(f"unsafe Git tree path for {repo}")
        if path != PurePosixPath(path).as_posix() or "//" in path or path.startswith("./") or path.endswith("/"):
            raise InputError(f"non-canonical Git tree path for {repo}")
        if any(part == ".." for part in PurePosixPath(path).parts):
            raise InputError(f"traversal Git tree path for {repo}")
        if path in seen or not isinstance(mode, str) or kind not in {"blob", "tree", "commit"}:
            raise InputError(f"malformed or duplicate Git tree entry for {repo}")
        if not isinstance(entry_sha, str) or not re.fullmatch(r"^[0-9a-f]{7,64}$", entry_sha):
            raise InputError(f"malformed Git tree entry SHA for {repo}")
        item = {"path": path, "mode": mode, "type": kind, "sha": entry_sha}
        if "size" in raw:
            size = raw["size"]
            if isinstance(size, bool) or not isinstance(size, int) or size < 0:
                raise InputError(f"malformed Git tree entry size for {repo}")
            item["size"] = size
        entries.append(item)
        seen.add(path)
    entries.sort(key=lambda item: item["path"])
    counts = {"blob_count": 0, "tree_count": 0, "commit_count": 0}
    extension_counts = {}
    for entry in entries:
        counts[f"{entry['type']}_count"] += 1
        if entry["type"] == "blob":
            suffix = PurePosixPath(entry["path"]).suffix.lower() or "[none]"
            extension_counts[suffix] = extension_counts.get(suffix, 0) + 1
    return {
        "commit_sha": commit_sha,
        "sha": tree_sha,
        "total_entry_count": len(entries),
        "truncated": False,
        "counts": counts,
        "extension_counts": dict(sorted(extension_counts.items())),
        "entries": entries,
    }


def read_bound_blob(repo: str, entry: dict) -> tuple[bytes, int]:
    """Read one allowlisted blob and bind its Git object SHA and size."""
    blob_sha = entry.get("sha")
    expected_size = entry.get("size")
    if entry.get("type") != "blob" or not isinstance(blob_sha, str) or not SHA_RE.fullmatch(blob_sha):
        raise InputError(f"semantic target is not a valid blob for {repo}")
    if isinstance(expected_size, bool) or not isinstance(expected_size, int) or expected_size < 0 or expected_size > MAX_SEMANTIC_BLOB_BYTES:
        raise InputError(f"semantic blob size is unavailable or over limit for {repo}")
    response = read_api(repo, f"git/blobs/{blob_sha}")
    if response.get("sha") != blob_sha or response.get("encoding") != "base64" or not isinstance(response.get("content"), str):
        raise InputError(f"semantic blob response is not bound or base64 for {repo}")
    if response.get("size") != expected_size:
        raise InputError(f"semantic blob size does not match tree for {repo}")
    try:
        raw = base64.b64decode("".join(response["content"].split()), validate=True)
        text = raw.decode("utf-8")
    except (ValueError, UnicodeError) as exc:
        raise InputError(f"semantic blob is not valid UTF-8 JSON for {repo}") from exc
    object_sha = hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest()
    if object_sha != blob_sha or len(raw) != expected_size or len(raw) > MAX_SEMANTIC_BLOB_BYTES:
        raise InputError(f"semantic blob length or JSON shape is invalid for {repo}")
    return raw, expected_size


def read_blob(repo: str, entry: dict) -> tuple[bytes, int, dict]:
    raw, size = read_bound_blob(repo, entry)
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeError, json.JSONDecodeError) as exc:
        raise InputError(f"semantic blob is not valid UTF-8 JSON for {repo}") from exc
    if not isinstance(parsed, dict):
        raise InputError(f"semantic blob JSON shape is invalid for {repo}")
    return raw, size, parsed


def manifest_dependency(value: object) -> tuple[str, str, str] | None:
    if not isinstance(value, str) or len(value) > 512:
        return None
    direct = GIT_DEP_RE.fullmatch(value)
    if direct:
        name, target = direct.groups()
        return name.lower(), target, "direct_vcs_declaration"
    if not DEP_NAME_RE.fullmatch(value):
        return None
    name = re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*", value).group(0).lower()
    target = PACKAGE_TARGETS.get(name)
    return (name, target, "package_allowlist_mapping") if target else None


def manifest_index(root: Path, pins_root: Path, trees: dict[str, dict]) -> dict:
    observations = []
    declarations = set()
    for repo, path in MANIFEST_TARGETS:
        pin_path = pins_root / f"{repo.split('/')[-1]}.json"
        entry = next((item for item in trees[repo]["entries"] if item["path"] == path), None)
        if entry is None:
            raise InputError(f"manifest target is absent from pinned tree: {repo}:{path}")
        raw, size = read_bound_blob(repo, entry)
        try:
            document = tomllib.loads(raw.decode("utf-8"))
        except (tomllib.TOMLDecodeError, UnicodeError) as exc:
            raise InputError(f"manifest is not valid TOML for {repo}") from exc
        project = document.get("project")
        if not isinstance(project, dict):
            raise InputError(f"manifest has no project table for {repo}")
        dynamic = project.get("dynamic", [])
        if not isinstance(dynamic, list) or not all(isinstance(item, str) for item in dynamic):
            raise InputError(f"manifest dynamic metadata is malformed for {repo}")
        if "dependencies" in dynamic:
            raise InputError(f"manifest dynamic dependencies are unsupported for {repo}")
        values: list[tuple[str, str, str, str]] = []
        dependency_values = project.get("dependencies", [])
        if not isinstance(dependency_values, list) or not all(isinstance(item, str) for item in dependency_values):
            raise InputError(f"manifest dependencies are not a string list for {repo}")
        for item in dependency_values:
            parsed = manifest_dependency(item)
            if parsed:
                values.append(("runtime", parsed[0], parsed[1], parsed[2]))
        optional = project.get("optional-dependencies", {})
        if not isinstance(optional, dict) or any(not isinstance(k, str) or not isinstance(v, list) or not all(isinstance(x, str) for x in v) for k, v in optional.items()):
            raise InputError(f"manifest optional dependencies are malformed for {repo}")
        for group, group_values in optional.items():
            if len(group) > 128:
                raise InputError(f"manifest optional dependency group is too long for {repo}")
            for item in group_values:
                parsed = manifest_dependency(item)
                if parsed:
                    values.append((group, parsed[0], parsed[1], parsed[2]))
        manifest_id = "evidence-manifest-" + canonical_sha256({"repo": repo, "path": path, "sha": entry["sha"]})[:12]
        for group, package, target, resolution in values:
            declarations.add((repo, group, package, target, resolution))
        observations.append({
            "manifest_id": manifest_id,
            "node_id": repo,
            "repository_pin": pin_reference(root, pin_path),
            "path": path,
            "blob_sha": entry["sha"],
            "blob_size": size,
            "decoded_length": len(raw),
            "declaration_count": len(values),
            "declarations_sha256": canonical_sha256(sorted(values)),
        })
    edges = []
    for source, group, package, target in MANIFEST_EDGE_ALLOWLIST:
        if not any(item[:4] == (source, group, package, target) for item in declarations):
            continue
        resolution = next(item[4] for item in declarations if item[:4] == (source, group, package, target))
        target_scope = "indexed_source" if target == "kimeisele/agent-internet" else "external_out_of_scope"
        evidence = next(item["manifest_id"] for item in observations if item["node_id"] == source)
        edges.append({
            "from_node": source,
            "to_node": target,
            "kind": MANIFEST_EDGE_KIND,
            "status": "declared",
            "declaration": "pinned_pyproject_toml",
            "target_ref_mutable": True,
            "target_scope": target_scope,
            "target_resolution": resolution,
            "package": package,
            "dependency_group": group,
            "evidence_refs": [evidence],
            "confidence": confidence("high", "direct_pinned_observation", "manifest declaration is not proof of installed or runtime use", TARGET_CAVEAT),
        })
    edges.sort(key=lambda item: (item["from_node"], item["dependency_group"], item["package"], item["to_node"]))
    return {"observations": observations, "declared_edges": edges}


def confidence(level: str, basis: str, *caveats: str) -> dict:
    return {"level": level, "basis": basis, "caveats": list(caveats)}


def candidate(node_id: str, entry: dict, kind: str, evidence_id: str, basis: str) -> dict:
    if entry.get("type") != "blob" or not isinstance(entry.get("size"), int):
        raise InputError(f"candidate lacks immutable blob size: {entry.get('path', '<unknown>')}")
    return {
        "node_id": node_id,
        "path": entry["path"],
        "mode": entry["mode"],
        "type": entry["type"],
        "sha": entry["sha"],
        "size": entry["size"],
        "kind": kind,
        "inference_status": "candidate_only",
        "evidence_refs": [evidence_id],
        "confidence": confidence(
            "medium", basis,
            "path metadata does not prove runtime exposure or use",
        ),
    }


def pin_reference(root: Path, pin_path: Path) -> str:
    try:
        return str(pin_path.relative_to(root))
    except ValueError:
        # Fixture runs may deliberately place pins outside the repository;
        # retain the explicit input location rather than inventing a repo path.
        return str(pin_path)


def require_keys(value: object, expected: set[str], label: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        raise InputError(f"{label}: unknown or missing fields")


def canonical_posix_path(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "//" in value:
        raise InputError(f"{label} is not a canonical POSIX path")
    path = PurePosixPath(value)
    if value != path.as_posix() or value.startswith("/") or value.endswith("/") or any(part in {".", ".."} for part in path.parts):
        raise InputError(f"{label} is not a canonical POSIX path")
    return value


def canonical_pin_path(value: object) -> str:
    return canonical_posix_path(value, "repository_pin")


def validate_confidence(value: object, label: str) -> None:
    require_keys(value, {"level", "basis", "caveats"}, label)
    if value["level"] not in {"high", "medium", "low", "unknown"} or value["basis"] not in {"direct_pinned_observation", "path_name_heuristic", "cross_node_comparison", "inference", "unavailable"}:
        raise InputError(f"{label}: invalid confidence")
    if not isinstance(value["caveats"], list) or not all(isinstance(item, str) and len(item) <= 256 for item in value["caveats"]):
        raise InputError(f"{label}: invalid confidence caveats")


def validate_candidate(value: object, evidence_by_id: dict, expected_nodes: set[str], label: str) -> None:
    require_keys(value, {"node_id", "path", "mode", "type", "sha", "size", "kind", "inference_status", "evidence_refs", "confidence"}, label)
    if value["node_id"] not in expected_nodes or value["type"] != "blob" or value["inference_status"] != "candidate_only":
        raise InputError(f"{label}: invalid candidate identity")
    canonical_posix_path(value["path"], f"{label}.path")
    if not isinstance(value["mode"], str) or not isinstance(value["sha"], str) or not re.fullmatch(r"^[0-9a-f]{7,64}$", value["sha"]):
        raise InputError(f"{label}: invalid candidate blob metadata")
    if isinstance(value["size"], bool) or not isinstance(value["size"], int) or value["size"] < 0:
        raise InputError(f"{label}: invalid candidate size")
    if not isinstance(value["evidence_refs"], list) or not value["evidence_refs"]:
        raise InputError(f"{label}: missing evidence references")
    for ref in value["evidence_refs"]:
        if ref not in evidence_by_id or evidence_by_id[ref]["node_id"] != value["node_id"]:
            raise InputError(f"{label}: evidence reference does not match node")
    validate_confidence(value["confidence"], f"{label}.confidence")


def validate_index(index_path: Path, root: Path, pins_root: Path) -> None:
    index = read_json(index_path)
    require_keys(index, {"schema", "procedure", "procedure_id", "procedure_version", "run_timestamp", "scope", "nodes", "evidence", "entrypoints", "contracts", "dependencies", "semantic", "relations", "findings", "attention_items", "summary", "limitations"}, "index")
    if index["schema"] != "federation-intelligence-v0" or index["procedure_id"] != PROCEDURE_ID or index["procedure_version"] != PROCEDURE_VERSION or index["procedure"] != {"id": PROCEDURE_ID, "version": PROCEDURE_VERSION}:
        raise InputError("index: invalid procedure identity")
    expected_nodes = {repo for repo, _ in CLUSTER}
    require_keys(index["scope"], {"node_ids", "source_state", "current_branch_state_checked"}, "scope")
    if set(index["scope"]["node_ids"]) != expected_nodes or index["scope"]["source_state"] != "historical_pinned_commits" or index["scope"]["current_branch_state_checked"] is not False:
        raise InputError("scope: exact historical three-node scope required")
    if not isinstance(index["nodes"], list) or {node.get("node_id") for node in index["nodes"]} != expected_nodes or len(index["nodes"]) != len(expected_nodes):
        raise InputError("nodes: exact unique three-node scope required")
    node_by_id = {node["node_id"]: node for node in index["nodes"]}

    pins = {}
    for repo, node_id in CLUSTER:
        pins[node_id] = load_pin(pins_root / f"{node_id}.json", repo)
    expected_timestamp = max(pin["observation_timestamp"] for pin in pins.values())
    if index["run_timestamp"] != expected_timestamp:
        raise InputError("run_timestamp is not deterministically derived from pins")

    evidence_by_id = {}
    evidence_nodes = set()
    for evidence in index["evidence"]:
        require_keys(evidence, {"evidence_id", "repository_pin", "procedure_id", "procedure_version", "observation_type", "node_id", "commit_sha", "tree_sha", "entry_count", "value"}, "evidence")
        if evidence["evidence_id"] in evidence_by_id or evidence["node_id"] not in expected_nodes or evidence["procedure_id"] != PROCEDURE_ID or evidence["procedure_version"] != PROCEDURE_VERSION or evidence["observation_type"] != "path_inventory" or evidence["value"] != "pinned_git_tree_metadata":
            raise InputError("evidence: duplicate or invalid record")
        pin_ref = canonical_pin_path(evidence["repository_pin"])
        expected_ref = pin_reference(root, pins_root / f"{evidence['node_id'].split('/')[-1]}.json")
        if pin_ref != expected_ref:
            raise InputError("evidence: repository_pin does not match configured pin input")
        pin = load_pin(pins_root / f"{evidence['node_id'].split('/')[-1]}.json", evidence["node_id"])
        if evidence["commit_sha"] != pin["resolved_commit_sha"] or not SHA_RE.fullmatch(evidence["tree_sha"]):
            raise InputError("evidence: commit/pin binding is invalid")
        if isinstance(evidence["entry_count"], bool) or not isinstance(evidence["entry_count"], int) or evidence["entry_count"] < 0:
            raise InputError("evidence: invalid entry count")
        evidence_by_id[evidence["evidence_id"]] = evidence
        evidence_nodes.add(evidence["node_id"])
    if len(evidence_by_id) != len(expected_nodes) or evidence_nodes != expected_nodes:
        raise InputError("evidence: one unique record per node is required")

    for node in index["nodes"]:
        require_keys(node, {"node_id", "repository_pin", "pin_sha", "commit_sha", "requested_ref", "acquisition_method", "dirty_state_assertion", "pin_observation_timestamp", "source_state", "tree", "evidence_refs", "confidence"}, "node")
        node_id = node["node_id"]
        if node_id not in expected_nodes or node["source_state"] != "historical_pinned_commit":
            raise InputError("node: invalid identity/source state")
        pin_ref = canonical_pin_path(node["repository_pin"])
        expected_ref = pin_reference(root, pins_root / f"{node_id.split('/')[-1]}.json")
        if pin_ref != expected_ref:
            raise InputError(f"node {node_id}: repository_pin does not match configured pin input")
        pin = load_pin(pins_root / f"{node_id.split('/')[-1]}.json", node_id)
        if (node["pin_sha"] != pin["resolved_commit_sha"] or node["commit_sha"] != pin["resolved_commit_sha"]
                or node["requested_ref"] != pin["requested_ref"] or node["acquisition_method"] != pin["acquisition_method"]
                or node["dirty_state_assertion"] != pin["dirty_state_assertion"]
                or node["pin_observation_timestamp"] != pin["observation_timestamp"]):
            raise InputError(f"node {node_id}: pin content mismatch")
        require_keys(node["tree"], {"sha", "total_entry_count", "truncated", "counts", "extension_counts"}, f"node {node_id}.tree")
        if not SHA_RE.fullmatch(node["tree"]["sha"]) or node["tree"]["truncated"] is not False:
            raise InputError(f"node {node_id}: invalid tree binding")
        require_keys(node["tree"]["counts"], {"blob_count", "tree_count", "commit_count"}, f"node {node_id}.counts")
        counts = node["tree"]["counts"]
        if any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in counts.values()) or sum(counts.values()) != node["tree"]["total_entry_count"]:
            raise InputError(f"node {node_id}: invalid tree counts")
        if not isinstance(node["tree"]["extension_counts"], dict) or any(isinstance(value, bool) or not isinstance(value, int) or value < 0 for value in node["tree"]["extension_counts"].values()):
            raise InputError(f"node {node_id}: invalid extension counts")
        if sum(node["tree"]["extension_counts"].values()) != counts["blob_count"]:
            raise InputError(f"node {node_id}: extension counts do not match blobs")
        if not isinstance(node["evidence_refs"], list) or not node["evidence_refs"] or any(ref not in evidence_by_id or evidence_by_id[ref]["node_id"] != node_id for ref in node["evidence_refs"]):
            raise InputError(f"node {node_id}: evidence reference mismatch")
        validate_confidence(node["confidence"], f"node {node_id}.confidence")

    for evidence in evidence_by_id.values():
        node = node_by_id[evidence["node_id"]]
        if evidence["tree_sha"] != node["tree"]["sha"] or evidence["commit_sha"] != node["commit_sha"]:
            raise InputError("evidence: commit/tree binding does not match its node")

    require_keys(index["contracts"], {"observed", "candidates"}, "contracts")
    require_keys(index["dependencies"], {"observed_edges", "candidates"}, "dependencies")
    if index["contracts"]["observed"] != []:
        raise InputError("contracts.observed: this metadata-only slice must remain empty")
    for values, label in ((index["entrypoints"], "entrypoints"), (index["contracts"]["observed"], "contracts.observed"), (index["contracts"]["candidates"], "contracts.candidates"), (index["dependencies"]["candidates"], "dependencies.candidates")):
        if not isinstance(values, list) or len(values) > MAX_CANDIDATES_PER_KIND:
            raise InputError(f"{label}: candidate cap or shape violation")
        for number, value in enumerate(values):
            validate_candidate(value, evidence_by_id, expected_nodes, f"{label}[{number}]")
    require_keys(index["semantic"], {"observations", "checks"}, "semantic")
    semantic_by_id = {}
    known_semantic = {
        ("kimeisele/agent-internet", ".well-known/agent-federation.json", "internet_descriptor"),
        ("kimeisele/agent-internet", "data/federation/authority-descriptor-seeds.json", "authority_seeds"),
        ("kimeisele/agent-city", ".well-known/agent-federation.json", "city_descriptor"),
    }
    for observation in index["semantic"]["observations"]:
        record_type = observation.get("record_type") if isinstance(observation, dict) else None
        if record_type in {"internet_descriptor", "city_descriptor"}:
            expected = {"observation_id", "node_id", "repository_pin", "path", "blob_sha", "blob_size", "decoded_length", "record_type", "kind", "repo_id", "status", "endpoint_path"}
        elif record_type == "authority_seeds":
            expected = {"observation_id", "node_id", "repository_pin", "path", "blob_sha", "blob_size", "decoded_length", "record_type", "descriptor_url_count", "descriptor_urls_sha256", "matched_city_descriptor_url"}
        else:
            raise InputError("semantic observation: unknown record type")
        require_keys(observation, expected, "semantic observation")
        identity = (observation["node_id"], observation["path"], record_type)
        if identity not in known_semantic or observation["observation_id"] in semantic_by_id:
            raise InputError("semantic observation: duplicate or out-of-scope target")
        canonical_posix_path(observation["path"], "semantic observation.path")
        expected_ref = pin_reference(root, pins_root / f"{observation['node_id'].split('/')[-1]}.json")
        if observation["repository_pin"] != expected_ref or not SHA_RE.fullmatch(observation["blob_sha"]):
            raise InputError("semantic observation: pin or blob binding is invalid")
        for field in ("blob_size", "decoded_length"):
            if isinstance(observation[field], bool) or not isinstance(observation[field], int) or observation[field] < 0 or observation[field] > MAX_SEMANTIC_BLOB_BYTES:
                raise InputError("semantic observation: invalid bounded blob size")
        if observation["decoded_length"] != observation["blob_size"]:
            raise InputError("semantic observation: decoded length mismatch")
        if record_type in {"internet_descriptor", "city_descriptor"}:
            if any(not isinstance(observation[field], str) or len(observation[field]) > 256 for field in ("kind", "repo_id", "status")):
                raise InputError("semantic observation: descriptor fields must be bounded strings")
            if observation["endpoint_path"] is not None and (not isinstance(observation["endpoint_path"], str) or len(observation["endpoint_path"]) > 256):
                raise InputError("semantic observation: endpoint path must be a bounded string")
        if record_type == "authority_seeds" and (isinstance(observation["descriptor_url_count"], bool)
                or not isinstance(observation["descriptor_url_count"], int) or observation["descriptor_url_count"] < 0
                or observation["descriptor_url_count"] > 128 or not re.fullmatch(r"^[0-9a-f]{64}$", observation["descriptor_urls_sha256"])
                or observation["matched_city_descriptor_url"] not in {None, EXPECTED_CITY_URL}):
            raise InputError("semantic observation: invalid compact descriptor URL summary")
        semantic_by_id[observation["observation_id"]] = observation
    if set((item["node_id"], item["path"], item["record_type"]) for item in index["semantic"]["observations"]) != known_semantic:
        raise InputError("semantic observations: exact three-target set required")
    if not isinstance(index["semantic"]["checks"], list) or len(index["semantic"]["checks"]) != 1:
        raise InputError("semantic checks: exactly one bounded check required")
    check = index["semantic"]["checks"][0]
    require_keys(check, {"check_id", "kind", "status", "reason_code", "evidence_refs", "confidence"}, "semantic check")
    allowed_reasons = {"all_declarations_agree", "internet_descriptor_fields_mismatch", "seed_urls_malformed", "seed_urls_duplicate", "expected_city_seed_not_declared", "city_descriptor_fields_mismatch"}
    if check["kind"] != "declared_discovery_seed" or check["status"] not in {"observed", "unproven", "mismatch"} or check["reason_code"] not in allowed_reasons or not isinstance(check["evidence_refs"], list) or set(check["evidence_refs"]) != set(semantic_by_id):
        raise InputError("semantic check: invalid status or evidence binding")
    internet_observation = next(item for item in semantic_by_id.values() if item["record_type"] == "internet_descriptor")
    city_observation = next(item for item in semantic_by_id.values() if item["record_type"] == "city_descriptor")
    seed_observation = next(item for item in semantic_by_id.values() if item["record_type"] == "authority_seeds")
    if check["status"] == "observed":
        if (internet_observation["kind"], internet_observation["repo_id"], internet_observation["status"], internet_observation["endpoint_path"]) != ("agent_federation_descriptor", "kimeisele/agent-internet", "active", "data/federation/authority-descriptor-seeds.json"):
            raise InputError("semantic observation: internet descriptor fields are not exact")
        if (city_observation["kind"], city_observation["repo_id"], city_observation["status"]) != ("agent_federation_descriptor", "kimeisele/agent-city", "active"):
            raise InputError("semantic observation: city descriptor fields are not exact")
        if seed_observation["matched_city_descriptor_url"] != EXPECTED_CITY_URL:
            raise InputError("semantic check: observed result lacks exact matched city URL")
    require_keys(index["relations"], {"declared_edges", "manifest_observations"}, "relations")
    if not isinstance(index["relations"]["manifest_observations"], list) or len(index["relations"]["manifest_observations"]) != len(MANIFEST_TARGETS):
        raise InputError("relations: exact manifest observation set required")
    manifest_ids = set()
    for item in index["relations"]["manifest_observations"]:
        require_keys(item, {"manifest_id", "node_id", "repository_pin", "path", "blob_sha", "blob_size", "decoded_length", "declaration_count", "declarations_sha256"}, "manifest observation")
        if item["node_id"] not in expected_nodes or item["path"] != "pyproject.toml" or not SHA_RE.fullmatch(item["blob_sha"]):
            raise InputError("manifest observation: invalid identity or blob binding")
        expected_ref = pin_reference(root, pins_root / f"{item['node_id'].split('/')[-1]}.json")
        if item["repository_pin"] != expected_ref or item["manifest_id"] in manifest_ids:
            raise InputError("manifest observation: pin or identity mismatch")
        manifest_ids.add(item["manifest_id"])
        for field in ("blob_size", "decoded_length", "declaration_count"):
            if isinstance(item[field], bool) or not isinstance(item[field], int) or item[field] < 0 or item[field] > (MAX_SEMANTIC_BLOB_BYTES if field != "declaration_count" else 128):
                raise InputError("manifest observation: invalid bounded integer")
        if item["decoded_length"] != item["blob_size"] or not re.fullmatch(r"^[0-9a-f]{64}$", item["declarations_sha256"]):
            raise InputError("manifest observation: invalid digest or length")
    if len(manifest_ids) != len(MANIFEST_TARGETS):
        raise InputError("manifest observations: duplicate or missing target")
    semantic_edges = [edge for edge in index["relations"]["declared_edges"] if edge.get("kind") == "declared_discovery_seed"]
    manifest_edges = [edge for edge in index["relations"]["declared_edges"] if edge.get("kind") == MANIFEST_EDGE_KIND]
    if len(semantic_edges) + len(manifest_edges) != len(index["relations"]["declared_edges"]):
        raise InputError("relations: unknown declared edge kind")
    if check["status"] != "observed" and semantic_edges:
        raise InputError("relations: no declared edge is allowed for a non-observed check")
    if check["status"] == "observed":
        edges = semantic_edges
        if len(edges) != 1:
            raise InputError("semantic check: observed result requires one edge")
        edge = edges[0]
        require_keys(edge, {"from_node", "to_node", "kind", "status", "declaration", "target_ref_mutable", "evidence_refs", "confidence"}, "dependency edge")
        if (edge["from_node"], edge["to_node"], edge["kind"], edge["status"], edge["declaration"], edge["target_ref_mutable"]) != ("kimeisele/agent-internet", "kimeisele/agent-city", "declared_discovery_seed", "observed", "historical_pinned_sources", True) or set(edge["evidence_refs"]) != set(semantic_by_id):
            raise InputError("dependency edge: semantic declaration binding invalid")
    elif semantic_edges:
        raise InputError("relations: no edge is allowed for an unproven or mismatched semantic check")
    for edge in manifest_edges:
        require_keys(edge, {"from_node", "to_node", "kind", "status", "declaration", "target_ref_mutable", "target_scope", "target_resolution", "package", "dependency_group", "evidence_refs", "confidence"}, "manifest dependency edge")
        if (edge["kind"], edge["status"], edge["declaration"], edge["target_ref_mutable"]) != (MANIFEST_EDGE_KIND, "declared", "pinned_pyproject_toml", True):
            raise InputError("manifest dependency edge: invalid declaration semantics")
        if (edge["from_node"], edge["dependency_group"], edge["package"], edge["to_node"]) not in MANIFEST_EDGE_ALLOWLIST:
            raise InputError("manifest dependency edge: target is not in versioned allowlist")
        expected_scope = "indexed_source" if edge["to_node"] == "kimeisele/agent-internet" else "external_out_of_scope"
        expected_resolution = "direct_vcs_declaration" if edge["package"] == "nadi-kit" else "package_allowlist_mapping"
        if edge["target_scope"] != expected_scope or edge["target_resolution"] != expected_resolution:
            raise InputError("manifest dependency edge: target scope or resolution is invalid")
        if not isinstance(edge["evidence_refs"], list) or len(edge["evidence_refs"]) != 1 or edge["evidence_refs"][0] not in manifest_ids:
            raise InputError("manifest dependency edge: invalid manifest evidence reference")
        validate_confidence(edge["confidence"], "manifest dependency edge.confidence")
        if TARGET_CAVEAT not in edge["confidence"]["caveats"]:
            raise InputError("manifest dependency edge: target verification caveat is missing")
    if index["dependencies"]["observed_edges"] != []:
        raise InputError("dependencies: observed implementation/runtime edges must remain empty")
    if index["findings"] != [] or index["attention_items"] != []:
        raise InputError("findings/attention_items: this slice must remain empty")
    expected_summary = {
        "pins": 3,
        "observed_nodes": 3,
        "tree_entries": sum(node["tree"]["total_entry_count"] for node in index["nodes"]),
        "blob_entries": sum(node["tree"]["counts"]["blob_count"] for node in index["nodes"]),
        "entrypoint_candidates": len(index["entrypoints"]),
        "contract_candidates": len(index["contracts"]["candidates"]),
        "dependency_candidates": len(index["dependencies"]["candidates"]),
        "findings": 0,
        "semantic_checks": 1,
        "declared_relations": len(index["relations"]["declared_edges"]),
        "manifest_observations": len(index["relations"]["manifest_observations"]),
    }
    if index["summary"] != expected_summary:
        raise InputError("summary does not match indexed records")
    if not isinstance(index["limitations"], list) or not all(isinstance(item, str) and len(item) <= 256 for item in index["limitations"]):
        raise InputError("limitations: invalid shape")


def semantic_index(root: Path, pins_root: Path, trees: dict[str, dict]) -> dict:
    observations = []
    parsed = {}
    for repo, path, record_type in SEMANTIC_TARGETS:
        node_id = repo
        pin_path = pins_root / f"{node_id.split('/')[-1]}.json"
        tree = trees[node_id]
        entry = next((item for item in tree["entries"] if item["path"] == path), None)
        if entry is None:
            raise InputError(f"semantic target is absent from pinned tree: {repo}:{path}")
        raw, size, document = read_blob(repo, entry)
        observation_id = "evidence-semantic-" + canonical_sha256({"repo": repo, "path": path, "sha": entry["sha"]})[:12]
        common = {
            "observation_id": observation_id,
            "node_id": repo,
            "repository_pin": pin_reference(root, pin_path),
            "path": path,
            "blob_sha": entry["sha"],
            "blob_size": size,
            "decoded_length": len(raw),
        }
        if record_type in {"internet_descriptor", "city_descriptor"}:
            endpoints = document.get("endpoints") if isinstance(document.get("endpoints"), dict) else {}
            observations.append({**common, "record_type": record_type,
                                 "kind": document.get("kind"), "repo_id": document.get("repo_id"),
                                 "status": document.get("status"),
                                 "endpoint_path": endpoints.get("authority_descriptor_seeds")})
        else:
            observations.append({**common, "record_type": record_type})
        parsed[record_type] = document

    for item in observations:
        if item["record_type"] == "authority_seeds":
            urls = parsed["authority_seeds"].get("descriptor_urls")
            valid_urls = isinstance(urls, list) and all(isinstance(url, str) and SEED_URL_RE.fullmatch(url) for url in urls)
            duplicate_urls = valid_urls and len(urls) != len(set(urls))
            expected_count = urls.count(EXPECTED_CITY_URL) if isinstance(urls, list) else 0
            item["descriptor_url_count"] = len(urls) if isinstance(urls, list) else 0
            item["descriptor_urls_sha256"] = canonical_sha256(sorted(urls)) if valid_urls else "0" * 64
            item["matched_city_descriptor_url"] = EXPECTED_CITY_URL if valid_urls and expected_count == 1 else None
    internet = next(item for item in observations if item["record_type"] == "internet_descriptor")
    seeds = next(item for item in observations if item["record_type"] == "authority_seeds")
    city = next(item for item in observations if item["record_type"] == "city_descriptor")
    references = [item["observation_id"] for item in observations]
    descriptor_fields_ok = (
        internet["kind"] == "agent_federation_descriptor"
        and internet["repo_id"] == "kimeisele/agent-internet"
        and internet["status"] == "active"
        and internet["endpoint_path"] == "data/federation/authority-descriptor-seeds.json"
    )
    city_fields_ok = (
        city["kind"] == "agent_federation_descriptor"
        and city["repo_id"] == "kimeisele/agent-city"
        and city["status"] == "active"
    )
    urls = parsed["authority_seeds"].get("descriptor_urls")
    urls_ok = isinstance(urls, list) and all(isinstance(url, str) and SEED_URL_RE.fullmatch(url) for url in urls)
    duplicate_urls = urls_ok and len(urls) != len(set(urls))
    if not descriptor_fields_ok:
        status, reason = "mismatch", "internet_descriptor_fields_mismatch"
    elif not urls_ok:
        status, reason = "mismatch", "seed_urls_malformed"
    elif duplicate_urls:
        status, reason = "mismatch", "seed_urls_duplicate"
    elif EXPECTED_CITY_URL not in urls:
        status, reason = "unproven", "expected_city_seed_not_declared"
    elif not city_fields_ok:
        status, reason = "mismatch", "city_descriptor_fields_mismatch"
    else:
        status, reason = "observed", "all_declarations_agree"
    check = {
        "check_id": "semantic-check-declared-discovery-seed",
        "kind": "declared_discovery_seed",
        "status": status,
        "reason_code": reason,
        "evidence_refs": references,
        "confidence": confidence("medium" if status == "observed" else "low", "direct_pinned_observation",
                                   "historical declaration is not runtime dependency or current truth"),
    }
    return {"observations": observations, "checks": [check]}


def build_index(root: Path, pins_root: Path) -> dict:
    if not shutil_which("gh"):
        raise InputError("required GitHub read tool is unavailable: gh")
    nodes = []
    evidence = []
    entrypoints = []
    contract_candidates = []
    dependency_candidates = []
    trees = {}

    for repo, node_id in CLUSTER:
        pin_path = pins_root / f"{node_id}.json"
        pin = load_pin(pin_path, repo)
        pin_sha = pin["resolved_commit_sha"]
        commit = read_commit(repo, pin_sha)
        tree = read_tree(repo, pin_sha, commit["tree_sha"])
        trees[repo] = tree
        evidence_id = "evidence-intel-" + canonical_sha256({"repo": repo, "sha": pin_sha, "tree": tree["sha"]})[:12]
        evidence.append({
            "evidence_id": evidence_id,
            "repository_pin": pin_reference(root, pin_path),
            "procedure_id": PROCEDURE_ID,
            "procedure_version": PROCEDURE_VERSION,
            "observation_type": "path_inventory",
            "node_id": repo,
            "commit_sha": commit["sha"],
            "tree_sha": tree["sha"],
            "entry_count": tree["total_entry_count"],
            "value": "pinned_git_tree_metadata",
        })
        nodes.append({
            "node_id": repo,
            "repository_pin": pin_reference(root, pin_path),
            "pin_sha": pin_sha,
            "commit_sha": commit["sha"],
            "requested_ref": pin["requested_ref"],
            "acquisition_method": pin["acquisition_method"],
            "dirty_state_assertion": pin["dirty_state_assertion"],
            "pin_observation_timestamp": pin["observation_timestamp"],
            "source_state": "historical_pinned_commit",
            "tree": {
                "sha": tree["sha"],
                "total_entry_count": tree["total_entry_count"],
                "truncated": tree["truncated"],
                "counts": tree["counts"],
                "extension_counts": tree["extension_counts"],
            },
            "evidence_refs": [evidence_id],
            "confidence": confidence("high", "direct_pinned_observation"),
        })
        for entry in tree["entries"]:
            if entry["type"] != "blob":
                continue
            basename = PurePosixPath(entry["path"]).name
            if basename in KNOWN_ENTRYPOINTS:
                entrypoints.append(candidate(repo, entry, "entrypoint_name", evidence_id, "path_name_heuristic"))
            if basename in KNOWN_CONTRACT_BASENAMES:
                contract_candidates.append(candidate(repo, entry, "exposed_contract_path", evidence_id, "path_name_heuristic"))
            if basename in KNOWN_DEPENDENCY_MANIFESTS:
                dependency_candidates.append(candidate(repo, entry, "dependency_manifest", evidence_id, "path_name_heuristic"))

    nodes.sort(key=lambda item: item["node_id"])
    evidence.sort(key=lambda item: item["evidence_id"])
    for values in (entrypoints, contract_candidates, dependency_candidates):
        if len(values) > MAX_CANDIDATES_PER_KIND:
            raise InputError("candidate cap exceeded; refusing silent truncation")
        values.sort(key=lambda item: (item["node_id"], item["path"], item["kind"]))
    run_timestamp = max(node["pin_observation_timestamp"] for node in nodes)
    total_entries = sum(node["tree"]["total_entry_count"] for node in nodes)
    total_blobs = sum(node["tree"]["counts"]["blob_count"] for node in nodes)
    semantic = semantic_index(root, pins_root, trees)
    semantic_check = semantic["checks"][0]
    observed_edges = []
    if semantic_check["status"] == "observed":
        observed_edges.append({
            "from_node": "kimeisele/agent-internet",
            "to_node": "kimeisele/agent-city",
            "kind": "declared_discovery_seed",
            "status": "observed",
            "declaration": "historical_pinned_sources",
            "target_ref_mutable": True,
            "evidence_refs": semantic_check["evidence_refs"],
            "confidence": semantic_check["confidence"],
        })
    manifests = manifest_index(root, pins_root, trees)
    observed_edges.extend(manifests["declared_edges"])
    return {
        "schema": "federation-intelligence-v0",
        "procedure": {"id": PROCEDURE_ID, "version": PROCEDURE_VERSION},
        "procedure_id": PROCEDURE_ID,
        "procedure_version": PROCEDURE_VERSION,
        "run_timestamp": run_timestamp,
        "scope": {
            "node_ids": [repo for repo, _ in CLUSTER],
            "source_state": "historical_pinned_commits",
            "current_branch_state_checked": False,
        },
        "nodes": nodes,
        "evidence": evidence,
        "entrypoints": entrypoints,
        "contracts": {"observed": [], "candidates": contract_candidates},
        "dependencies": {"observed_edges": [], "candidates": dependency_candidates},
        "semantic": semantic,
        "relations": {"declared_edges": observed_edges, "manifest_observations": manifests["observations"]},
        "findings": [],
        "attention_items": [],
        "summary": {
            "pins": len(nodes),
            "observed_nodes": len(nodes),
            "tree_entries": total_entries,
            "blob_entries": total_blobs,
            "entrypoint_candidates": len(entrypoints),
            "contract_candidates": len(contract_candidates),
            "dependency_candidates": len(dependency_candidates),
            "findings": 0,
            "semantic_checks": len(semantic["checks"]),
            "declared_relations": len(observed_edges),
            "manifest_observations": len(manifests["observations"]),
        },
        "limitations": [
            "Tree metadata identifies candidate paths only; file contents and runtime wiring were not read.",
            "One declared discovery relation is historical and mutable; dependencies.observed_edges remains empty because no runtime or implementation dependency is asserted.",
            "The pin records are historical observations and do not claim current branch state.",
        ],
    }


def shutil_which(command: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        path = Path(directory) / command
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    return None


def verify_source(index_path: Path, root: Path, pins_root: Path) -> None:
    """Verify offline shape and exact membership against fresh immutable reads."""
    validate_index(index_path, root, pins_root)
    actual = read_json(index_path)
    expected = build_index(root, pins_root)
    if actual != expected:
        raise InputError("source verification mismatch: output differs from immutable pin/tree rebuild")


def write_atomic(output: Path, value: dict) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, output)
        directory_fd = os.open(output.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pins-root", default="pins/v1-census", type=Path)
    parser.add_argument("--output", default="digest/federation-intelligence-v0.json", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--validate-only", action="store_true", help="offline relational/integrity validation only")
    modes.add_argument("--verify-source", action="store_true", help="offline validation plus immutable commit/tree membership rebuild")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    pins_root = args.pins_root if args.pins_root.is_absolute() else root / args.pins_root
    output = args.output if args.output.is_absolute() else root / args.output
    try:
        if args.validate_only:
            validate_index(output, root, pins_root)
            print(f"OK — validated {output}")
            return 0
        if args.verify_source:
            verify_source(output, root, pins_root)
            print(f"OK — source-verified {output}")
            return 0
        write_atomic(output, build_index(root, pins_root))
    except InputError as exc:
        print(f"FAIL — federation intelligence input unavailable: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"FAIL — federation intelligence output unavailable: {exc}", file=sys.stderr)
        return 1
    print(f"OK — wrote {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
