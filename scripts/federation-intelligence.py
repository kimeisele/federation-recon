#!/usr/bin/env python3
"""Build the bounded, read-only federation intelligence index.

Only immutable GitHub tree metadata at the committed v1-census pins is read.
The output is deliberately candidate-oriented: a path name is not proof that
a contract is exposed or that a dependency is actually used.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile


PROCEDURE_ID = "federation-intelligence-v0"
PROCEDURE_VERSION = "1"
MAX_CANDIDATES_PER_KIND = 128
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
    require_keys(index, {"schema", "procedure", "procedure_id", "procedure_version", "run_timestamp", "scope", "nodes", "evidence", "entrypoints", "contracts", "dependencies", "findings", "attention_items", "summary", "limitations"}, "index")
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
    if index["dependencies"]["observed_edges"]:
        raise InputError("dependencies: no observed edge is allowed in this metadata-only slice")
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
    }
    if index["summary"] != expected_summary:
        raise InputError("summary does not match indexed records")
    if not isinstance(index["limitations"], list) or not all(isinstance(item, str) and len(item) <= 256 for item in index["limitations"]):
        raise InputError("limitations: invalid shape")


def build_index(root: Path, pins_root: Path) -> dict:
    if not shutil_which("gh"):
        raise InputError("required GitHub read tool is unavailable: gh")
    nodes = []
    evidence = []
    entrypoints = []
    contract_candidates = []
    dependency_candidates = []

    for repo, node_id in CLUSTER:
        pin_path = pins_root / f"{node_id}.json"
        pin = load_pin(pin_path, repo)
        pin_sha = pin["resolved_commit_sha"]
        commit = read_commit(repo, pin_sha)
        tree = read_tree(repo, pin_sha, commit["tree_sha"])
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
        },
        "limitations": [
            "Tree metadata identifies candidate paths only; file contents and runtime wiring were not read.",
            "No dependency edge is asserted without pinned content evidence.",
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
