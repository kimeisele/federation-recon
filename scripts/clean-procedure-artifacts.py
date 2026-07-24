#!/usr/bin/env python3
"""Remove the previous derived artifact set for one procedure.

Shared artifact directories require relationship-aware cleanup. Files are
selected by procedure_id or pin namespace, then dependent drift and finding
records are selected from their references. Repository pins and digests remain
in place because reproduce mode needs them as inputs and overwrites them.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def artifact_id(path: Path, data: dict) -> str:
    for key, value in data.items():
        if key.endswith("_id") and isinstance(value, str):
            return value
    return path.stem


def ref_id(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return Path(value).stem


def select_outputs(root: Path, procedure_id: str, pin_prefix: str) -> set[Path]:
    selected: set[Path] = set()
    claim_ids: set[str] = set()
    evidence_ids: set[str] = set()
    coverage_ids: set[str] = set()

    for directory, id_set, predicate in (
        ("claims", claim_ids, lambda d: str(d.get("repository_pin", "")).startswith(pin_prefix)),
        ("evidence", evidence_ids, lambda d: d.get("procedure_id") == procedure_id),
        ("coverage", coverage_ids, lambda d: d.get("procedure_id") == procedure_id),
    ):
        for path in sorted((root / directory).glob("*.json")):
            data = load_json(path)
            if data is not None and predicate(data):
                selected.add(path)
                id_set.add(artifact_id(path, data))

    for path in sorted((root / "drift").glob("*.json")):
        data = load_json(path)
        if data is None:
            continue
        if data.get("claim_observation") in claim_ids or data.get("evidence") in evidence_ids:
            selected.add(path)

    supporting_ids = evidence_ids | coverage_ids
    for path in sorted((root / "findings").glob("*.json")):
        data = load_json(path)
        if data is None:
            continue
        refs = data.get("evidence_refs", [])
        if isinstance(refs, list) and any(ref_id(ref) in supporting_ids for ref in refs):
            selected.add(path)

    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--procedure-id", required=True)
    parser.add_argument("--pin-prefix", required=True)
    parser.add_argument("--keep-file")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    selected = select_outputs(root, args.procedure_id, args.pin_prefix)
    keep: set[Path] = set()
    if args.keep_file:
        for line in Path(args.keep_file).read_text().splitlines():
            if line.strip():
                keep.add((root / line.strip()).resolve())
    selected = {path for path in selected if path.resolve() not in keep}
    counts: dict[str, int] = {}
    for path in sorted(selected):
        counts[path.parent.name] = counts.get(path.parent.name, 0) + 1
        path.unlink()

    summary = ", ".join(f"{name}={count}" for name, count in sorted(counts.items()))
    print(f"pruned superseded {args.procedure_id} outputs: {summary or 'none'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
