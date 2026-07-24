#!/usr/bin/env python3
"""Per-procedure artifact counts for a sub-digest summary.

The artifact directories evidence/, coverage/, findings/ are shared by all
procedures, so a naive file count commingles them (and, once pins/ became
per-procedure namespaced, a flat count of pins/ returns 0). This attributes
each artifact to the procedure that produced it:

  - pins      : counted from the procedure's own namespace  pins/<namespace>/
  - evidence  : filtered by procedure_id
  - coverage  : filtered by procedure_id
  - findings  : attributed via the procedure_id of their referenced evidence
                (findings carry no procedure_id of their own)

Deterministic: counts do not depend on filesystem order.

Usage: count_procedure.py <procedure_id> <pin_namespace>
Prints: {"pins": N, "evidence": N, "coverage": N, "findings": N}
"""
import json
import sys
import glob
import os


def _load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {}


def main():
    proc = sys.argv[1]
    namespace = sys.argv[2]

    pins = len(glob.glob(f"pins/{namespace}/*.json"))

    evidence_docs = {p: _load(p) for p in glob.glob("evidence/*.json")}
    evidence = sum(1 for d in evidence_docs.values() if d.get("procedure_id") == proc)
    coverage = sum(
        1 for p in glob.glob("coverage/*.json") if _load(p).get("procedure_id") == proc
    )

    # evidence_id -> procedure_id, to attribute findings by their evidence_refs
    ev_proc = {
        d.get("evidence_id"): d.get("procedure_id") for d in evidence_docs.values()
    }

    def finding_procedure(doc):
        for ref in doc.get("evidence_refs", []):
            eid = os.path.basename(ref)[:-5] if ref.endswith(".json") else ref
            p = ev_proc.get(eid)
            if p:
                return p
        return None

    findings = sum(
        1 for p in glob.glob("findings/*.json") if finding_procedure(_load(p)) == proc
    )

    def drift_procedure(doc):
        ref = doc.get("evidence", "")
        eid = os.path.basename(ref)[:-5] if ref.endswith(".json") else ref
        return ev_proc.get(eid)

    drift = sum(
        1 for p in glob.glob("drift/*.json") if drift_procedure(_load(p)) == proc
    )

    if "--sh" in sys.argv:
        # space-separated: pins evidence coverage findings drift
        print(f"{pins} {evidence} {coverage} {findings} {drift}")
    else:
        print(json.dumps({"pins": pins, "evidence": evidence, "coverage": coverage,
                          "findings": findings, "drift": drift}))


if __name__ == "__main__":
    main()
