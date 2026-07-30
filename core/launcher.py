#!/usr/bin/env python3
"""Execution Core launcher (S1: seatbelt canaries).

Every invocation runs the full canary suite — no skip flag, no env override,
no cached result.  Fail-closed.  Refusal messages name the missing capability,
the backend, and the exact policy field.
"""

import importlib, json, os, sys

_CORE_DIR = os.path.dirname(os.path.abspath(__file__))
_POLICY_PATH = os.path.join(_CORE_DIR, "policy.json")
_CANARY_ORDER = ["no_network", "fs_confinement", "pid_limit", "tree_kill", "symlink_egress", "ingress_symlink"]
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

    print(f"Backend: {policy['backend']}")
    print(f"Profile: /usr/local/var/jcode-runs/profiles/worker.sb")
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

    print("=== Execution Core S1 — Canary Suite ===")
    print()

    all_passed, _ = _run_canary_suite()

    if not all_passed:
        print("REFUSED: one or more canaries failed. Check output above for details.",
              file=sys.stderr)
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
