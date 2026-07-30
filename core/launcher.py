#!/usr/bin/env python3
"""Execution Core launcher (S1: seatbelt canaries, per-run uid pool).

Every invocation runs the full canary suite — no skip flag, no env override,
no cached result.  Fail-closed.  Refusal messages name the missing capability,
the backend, and the exact policy field.

Concurrency up to pool size (8) is **permitted**.  Pool exhaustion results
in clean refusal.
"""

import importlib, json, os, sys

_CORE_DIR = os.path.dirname(os.path.abspath(__file__))
_POLICY_PATH = os.path.join(_CORE_DIR, "policy.json")
_CANARY_ORDER = ["pool_integrity", "no_network", "fs_confinement", "pid_limit",
                 "tree_kill", "kill_persistent", "symlink_egress", "ingress_symlink"]
_policy_cache = None


def _load_policy():
    global _policy_cache
    if _policy_cache is None:
        with open(_POLICY_PATH) as f:
            _policy_cache = json.load(f)
    return _policy_cache


def check_capabilities(required):
    """Return the list of *required* capabilities not in claimed_capabilities."""
    policy = _load_policy()
    claimed = set(policy.get("claimed_capabilities", []))
    return [c for c in required if c not in claimed]


# ── Refusal ────────────────────────────────────────────────────────────────

def _refuse(missing_caps):
    """Print refusal for each missing capability, then exit."""
    policy = _load_policy()
    backend = policy["backend"]
    for cap in missing_caps:
        reason = policy.get("unclaimable_capabilities", {}).get(
            cap, "not listed in claimed_capabilities"
        )
        print(
            f"REFUSED: capability '{cap}' not available on backend '{backend}'.\n"
            f"  Policy field 'unclaimable_capabilities.{cap}': {reason}\n"
            f"  To grant this capability, change 'unclaimable_capabilities' in\n"
            f"  {_POLICY_PATH} and ensure the corresponding canary passes.",
            file=sys.stderr,
        )
    sys.exit(1)


# ── Canary runner ──────────────────────────────────────────────────────────

def _run_one_canary(cap_name, backend):
    """Import and run a single canary module.  Returns (passed, reason)."""
    mod = importlib.import_module(f"canaries.{cap_name}")
    return mod.run(backend)


def _run_canary_suite():
    """Run all canaries.  Returns (passed_all, surviving_set)."""
    sys.path.insert(0, _CORE_DIR)

    import backends.macos_seatbelt as backend

    policy = _load_policy()
    claimed = set(policy.get("claimed_capabilities", []))

    # Snapshot the original set BEFORE running — this is the denominator.
    original_claimed = set(claimed)

    # Refuse to run if any claimed capability is not registered in _CANARY_ORDER.
    # Moved to BEFORE any canary runs (spec: §7).
    unregistered = set(claimed) - set(_CANARY_ORDER)
    if unregistered:
        for cap in sorted(unregistered):
            print(
                f"REFUSED: capability {cap!r} is claimed in policy but has no "
                f"registered canary in _CANARY_ORDER — no canary tests it"
            )
        print()
        print(
            f"Canary suite: {len(claimed) - len(unregistered)}/{len(claimed)} "
            f"capabilities confirmed.",
            file=sys.stderr,
        )
        return False, set()

    # Warn if a registered canary is not in claimed_capabilities — it will be
    # skipped, but the operator should know.
    missing_canaries = set(_CANARY_ORDER) - set(claimed)
    if missing_canaries:
        for cap in sorted(missing_canaries):
            print(
                f"WARNING: canary {cap!r} is registered in _CANARY_ORDER but "
                f"not listed in claimed_capabilities — will be skipped"
            )

    print(f"Backend: {policy['backend']}")
    print(f"Profile: /usr/local/var/jcode-runs/profiles/worker.sb")
    print()

    # ── Reconcile at startup ──────────────────────────────────────────
    reconcile_result = backend.reconcile()
    if reconcile_result["removed_runs"] or reconcile_result["released_slots"]:
        print(f"[launcher] reconcile: removed {reconcile_result['removed_runs']} orphan runs, "
              f"released {reconcile_result['released_slots']} orphan claims")
        if reconcile_result["errors"]:
            print(f"[launcher] reconcile: {reconcile_result['errors']} error(s) during reconciliation",
                  file=sys.stderr)
    print()

    for cap in _CANARY_ORDER:
        if cap not in claimed:
            print(f"  canary {cap}: SKIP (not claimed)")
            continue
        try:
            passed, reason = _run_one_canary(cap, backend)
            status = "PASS" if passed else "FAIL"
            print(f"  canary {cap}: {status}")
            print(f"           {reason}")
            if not passed:
                claimed.discard(cap)
        except Exception as exc:
            print(f"  canary {cap}: FAIL (exception: {exc})")
            claimed.discard(cap)
        print()

    total = len(original_claimed)
    surviving = len(claimed)
    print(f"Canary suite: {surviving}/{total} capabilities confirmed.")

    return surviving == total, claimed


# ── Main ───────────────────────────────────────────────────────────────────

def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    print("=== Execution Core S1 — Canary Suite (per-run uid pool) ===")
    print()

    import backends.macos_seatbelt as backend

    # ── Report pool status ───────────────────────────────────────────
    ps = backend.pool_status()
    free = sum(1 for s in ps.values() if s == "free")
    claimed = sum(1 for s in ps.values() if s == "claimed")
    quarantined = sum(1 for s in ps.values() if s == "quarantined")
    print(f"Pool: {free} free, {claimed} claimed, {quarantined} quarantined (8 total)")
    if ps:
        for name, status in sorted(ps.items()):
            print(f"  {name}: {status}")
    print()

    all_passed, _ = _run_canary_suite()

    if not all_passed:
        print("REFUSED: one or more canaries failed. Check output above for details.",
              file=sys.stderr)
        sys.exit(1)

    # ── Reconcile after suite ────────────────────────────────────────
    reconcile_result = backend.reconcile()
    if reconcile_result["removed_runs"] or reconcile_result["released_slots"]:
        print(f"[launcher] reconcile: removed {reconcile_result['removed_runs']} orphan runs, "
              f"released {reconcile_result['released_slots']} orphan claims")
    if reconcile_result["errors"]:
        print(f"[launcher] reconcile: {reconcile_result['errors']} error(s) during reconciliation",
              file=sys.stderr)
    else:
        print("reconcile(): zero orphans")
    print()

    # ── Check for degraded pool ─────────────────────────────────────
    ps = backend.pool_status()
    quarantined_slots = {name for name, status in ps.items() if status == "quarantined"}
    if quarantined_slots:
        print(f"Pool degraded: {len(quarantined_slots)} slot(s) quarantined — not ready.",
              file=sys.stderr)
        for name in sorted(quarantined_slots):
            q_dir = None
            for entry in os.listdir(backend._SLOTS_DIR):
                if entry.startswith(f"{name}.quarantined."):
                    q_dir = os.path.join(backend._SLOTS_DIR, entry)
                    break
            reason = "(unknown)"
            if q_dir:
                try:
                    with open(os.path.join(q_dir, "reason")) as f:
                        reason = f.read().strip()
                except OSError:
                    pass
            print(f"  {name}: {reason}", file=sys.stderr)
        sys.exit(1)

    print("All canaries complete.  Ready for orders (S2+).")
    if argv:
        missing = check_capabilities(argv)
        if missing:
            _refuse(missing)
        else:
            print("Capability check: all requested capabilities available.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
