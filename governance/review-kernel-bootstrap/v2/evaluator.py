#!/usr/bin/env python3
"""Sealed, non-authoritative RECOVERY-2 bootstrap reference evaluator.

This is deliberately independent of the candidate runner and candidate schema.
It consumes only the wrapper vectors in this directory and returns one closed
outcome per vector.  The owner must merge this oracle before any candidate
kernel can be considered for activation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import stat
from datetime import datetime
from pathlib import Path

VERSION = "r2-bootstrap-evaluator-1"
SHA40 = re.compile(r"^[0-9a-f]{40,64}$")
RUN_ID = re.compile(r"^rv-[0-9]{8}-[0-9]{3}$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
TASKS = ("tier0", "review-analysis", "adversarial-execution", "tier2")
TASK_TIERS = {"tier0": 0, "review-analysis": 1, "adversarial-execution": 1, "tier2": 2}
MANDATORY = ("tier0", "review-analysis", "adversarial-execution")
STATUSES = {"pass", "complete", "fail", "error", "not_run"}
STORED_OUTCOMES = {"APPROVE", "REJECT", "PARTIAL", "STALE", "HOLD"}
FINDINGS = ("id", "tier", "task", "severity", "claimed_severity", "summary", "verification_status")
EVIDENCE = ("task", "run_id", "subject_head_sha", "provider", "model", "provenance", "cost_usd", "token_usage", "evidence_sha256")
TOKENS = ("prompt", "completion", "reasoning")
PROVIDER_TASKS = ("review-analysis", "adversarial-execution")
BUDGET = ("reservation_id", "reservation_status", "actual_usage_complete", "run_id", "subject_head_sha", "reservation_sha256", "provider_evidence")
SHA64 = re.compile(r"^[0-9a-f]{64}$")


def _exact(value: object, keys: tuple[str, ...]) -> bool:
    return isinstance(value, dict) and set(value) == set(keys)


def _integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _nonempty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value)


def _finite_json(value: object) -> bool:
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, dict):
        return all(_finite_json(key) and _finite_json(item) for key, item in value.items())
    if isinstance(value, list):
        return all(_finite_json(item) for item in value)
    return True


def _canonical_sha(value: object) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _valid_digest(value: object) -> bool:
    return isinstance(value, str) and SHA64.fullmatch(value) is not None


def _valid_budget(value: object, run_id: str, head_sha: str) -> bool:
    if not _exact(value, BUDGET) or not _nonempty_string(value["reservation_id"]):
        return False
    if value["reservation_status"] != "committed" or value["actual_usage_complete"] is not True:
        return False
    if value["run_id"] != run_id or value["subject_head_sha"] != head_sha or not _valid_digest(value["reservation_sha256"]):
        return False
    evidence = value["provider_evidence"]
    if not _exact(evidence, PROVIDER_TASKS):
        return False
    for task, item in evidence.items():
        if not _exact(item, EVIDENCE):
            return False
        if item["task"] != task or item["run_id"] != run_id or item["subject_head_sha"] != head_sha:
            return False
        if not _nonempty_string(item["provider"]) or not _nonempty_string(item["model"]) or not _nonempty_string(item["provenance"]):
            return False
        if item["run_id"] not in item["provenance"] or item["task"] not in item["provenance"]:
            return False
        if isinstance(item["cost_usd"], bool) or not isinstance(item["cost_usd"], (int, float)):
            return False
        if not math.isfinite(item["cost_usd"]) or item["cost_usd"] < 0:
            return False
        tokens = item["token_usage"]
        if not _exact(tokens, TOKENS) or not all(_integer(tokens[key]) and tokens[key] >= 0 for key in TOKENS):
            return False
        evidence_core = {key: item[key] for key in EVIDENCE if key != "evidence_sha256"}
        if not _valid_digest(item["evidence_sha256"]) or item["evidence_sha256"] != _canonical_sha(evidence_core):
            return False
    budget_core = {key: value[key] for key in BUDGET if key != "reservation_sha256"}
    return value["reservation_sha256"] == _canonical_sha(budget_core)


def _valid_finding(value: object, tasks: object) -> bool:
    if not _exact(value, FINDINGS):
        return False
    if not _nonempty_string(value["id"]) or not _integer(value["tier"]) or not 0 <= value["tier"] <= 2:
        return False
    if value["task"] not in TASK_TIERS or tasks[value["task"]] == "not_run":
        return False
    if value["tier"] != TASK_TIERS[value["task"]]:
        return False
    if value["severity"] not in {"blocking", "non-blocking"}:
        return False
    if value["claimed_severity"] not in {"blocking", "non-blocking"}:
        return False
    if not isinstance(value["summary"], str):
        return False
    return value["verification_status"] in {"confirmed", "rejected", "inconclusive", "not_run", "error"}


def _valid_verdict(value: object) -> bool:
    keys = ("schema", "run_id", "pr_number", "subject_head_sha", "risk_class", "timestamp", "tasks", "findings", "budget", "verdict")
    if not _exact(value, keys) or value["schema"] != "review-verdict-v2":
        return False
    if not _nonempty_string(value["run_id"]) or not RUN_ID.fullmatch(value["run_id"]):
        return False
    if not _integer(value["pr_number"]) or value["pr_number"] < 1:
        return False
    if not isinstance(value["subject_head_sha"], str) or not SHA40.fullmatch(value["subject_head_sha"]):
        return False
    if value["risk_class"] not in {"LOW", "HIGH"} or not isinstance(value["timestamp"], str) or not TIMESTAMP.fullmatch(value["timestamp"]):
        return False
    try:
        timestamp = datetime.strptime(value["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    if timestamp.strftime("%Y%m%d") != value["run_id"][3:11]:
        return False
    tasks = value["tasks"]
    if not _exact(tasks, TASKS) or any(tasks[name] not in STATUSES for name in TASKS):
        return False
    findings = value["findings"]
    finding_ids = [item.get("id") for item in findings if isinstance(item, dict)] if isinstance(findings, list) else []
    if not isinstance(findings, list) or len(finding_ids) != len(findings) or any(not isinstance(item, str) for item in finding_ids) or len(set(finding_ids)) != len(findings):
        return False
    if not all(_valid_finding(item, tasks) for item in findings):
        return False
    if not _valid_budget(value["budget"], value["run_id"], value["subject_head_sha"]):
        return False
    return value["verdict"] in STORED_OUTCOMES


def evaluate(vector: object) -> str:
    if not _exact(vector, ("id", "current_head_sha", "verdict")):
        return "HOLD"
    if not _nonempty_string(vector["id"]):
        return "HOLD"
    current = vector["current_head_sha"]
    if not isinstance(current, str) or not SHA40.fullmatch(current):
        return "HOLD"
    verdict = vector["verdict"]
    if not _finite_json(verdict) or not _valid_verdict(verdict):
        return "HOLD"
    if verdict["subject_head_sha"] != current:
        return "STALE"

    tasks = verdict["tasks"]
    findings = verdict["findings"]
    if tasks["tier0"] == "fail":
        return "REJECT"
    for finding in findings:
        effective_blocking = finding["severity"] == "blocking" or finding["claimed_severity"] == "blocking"
        if effective_blocking and finding["verification_status"] == "confirmed":
            return "REJECT"
        if finding["verification_status"] in {"inconclusive", "not_run", "error"}:
            return "HOLD"

    if any(tasks[name] not in {"pass", "complete"} for name in MANDATORY):
        return "HOLD"
    if verdict["risk_class"] == "HIGH":
        return "HOLD"
    if tasks["tier2"] != "not_run":
        return "HOLD"
    return "APPROVE"


def _regular_file(path: Path) -> bool:
    return not path.is_symlink() and path.is_file() and stat.S_ISREG(path.stat().st_mode)


def _load_vectors(path: Path) -> dict[str, str]:
    vectors = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(vectors, list):
        raise ValueError("vectors must be a list")
    outcomes: dict[str, str] = {}
    for vector in vectors:
        identifier = vector.get("id") if isinstance(vector, dict) else None
        if not isinstance(identifier, str) or identifier in outcomes:
            raise ValueError("vector ids must be unique strings")
        outcomes[identifier] = evaluate(vector)
    return outcomes


def _verified_corpus(root: Path) -> tuple[dict[str, str], str]:
    root = root.resolve()
    manifest_path = root / "manifest.json"
    if not _regular_file(manifest_path):
        raise ValueError("sealed manifest is missing or not regular")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = ["manifest.json", "vectors.json", "expected.json", "digests.json", "evaluator.py"]
    if manifest.get("files") != files:
        raise ValueError("manifest file order is not the sealed order")
    entries = sorted(child.name for child in root.iterdir())
    if entries != sorted(files) or any(not _regular_file(root / name) for name in files):
        raise ValueError("sealed oracle directory contains an unexpected or non-regular file")

    corpus_files = ["manifest.json", "vectors.json", "expected.json", "evaluator.py"]
    if manifest.get("corpus_files") != corpus_files:
        raise ValueError("manifest corpus order is not sealed")
    if manifest.get("harness") != "scripts/test/review-kernel-bootstrap.bats":
        raise ValueError("sealed harness path is invalid")
    harness = root.parents[2] / manifest["harness"]
    if not _regular_file(harness):
        raise ValueError("sealed harness is missing or not regular")
    digests = json.loads((root / "digests.json").read_text(encoding="utf-8"))
    digest_keys = {"digest_version", "corpus_sha256", "harness_sha256", *[name + "_sha256" for name in corpus_files]}
    if set(digests) != digest_keys or digests.get("digest_version") != "sha256-name-nul-bytes-nul-v1":
        raise ValueError("sealed digest record shape is invalid")
    for name in corpus_files:
        digest = hashlib.sha256((root / name).read_bytes()).hexdigest()
        if digests[name + "_sha256"] != digest or not SHA64.fullmatch(digests[name + "_sha256"]):
            raise ValueError(f"sealed digest mismatch: {name}")
    harness_digest = hashlib.sha256(harness.read_bytes()).hexdigest()
    if digests["harness_sha256"] != harness_digest or not SHA64.fullmatch(digests["harness_sha256"]):
        raise ValueError("sealed digest mismatch: harness")
    corpus = hashlib.sha256()
    for name in corpus_files:
        corpus.update(name.encode("utf-8"))
        corpus.update(b"\0")
        corpus.update((root / name).read_bytes())
        corpus.update(b"\0")
    if digests["corpus_sha256"] != corpus.hexdigest():
        raise ValueError("sealed corpus digest mismatch")
    return _load_vectors(root / "vectors.json"), "CORPUS_INTEGRITY_VERIFIED"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--vectors", type=Path)
    group.add_argument("--corpus-root", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.vectors is None and args.corpus_root is None:
            raise ValueError("--corpus-root is required for corpus integrity mode")
        if args.vectors is None:
            outcomes, input_mode = _verified_corpus(args.corpus_root)
        elif args.corpus_root is not None:
            raise ValueError("--vectors and --corpus-root are mutually exclusive")
        else:
            outcomes, input_mode = _load_vectors(args.vectors), "UNSEALED_FIXTURE"
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"reference evaluator input error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps({"evaluator_version": VERSION, "input_mode": input_mode, "outcomes": outcomes}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
