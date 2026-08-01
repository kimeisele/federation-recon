#!/usr/bin/env python3
"""Execution Core launcher (S1: seatbelt canaries, per-run uid pool).

Every invocation runs the full canary suite — no skip flag, no env override,
no cached result.  Fail-closed.  Refusal messages name the missing capability,
the backend, and the exact policy field.

Concurrency up to pool size (8) is **permitted**.  Pool exhaustion results
in clean refusal.
"""

import contextlib, importlib, io, json, os, sys

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

def validate_order(order_path):
    """Run the S2 order validator on *order_path*.

    Returns (returncode, stderr_text, order). *order* is the parsed dict the
    validator actually inspected, or None when the verdict was not admissible.

    Runs in-process: no subprocess, no shell. A refusal signals itself by
    exiting, so SystemExit is caught here and read as the status — the
    supervisor measuring the exit status itself rather than believing a
    reported one (ADR §6). Admission returns the order.

    The order comes back with the verdict because the launcher used to re-open
    the file afterwards with a plain json.load, and everything the validator
    established was assumed to hold for whatever bytes were at that path a
    moment later. ADR §5 requires a size check before EVERY read; the second
    read had none. See #128.
    """
    sys.path.insert(0, _CORE_DIR)
    import orders.validate as order_validate

    buf = io.StringIO()
    try:
        with contextlib.redirect_stderr(buf):
            order = order_validate.run_checks(order_path)
    except SystemExit as exc:
        # Only refusals leave this way now. A SystemExit(0) would mean the
        # validator exited successfully without returning the order, which is
        # a contract change and is reported as a refusal rather than admitted.
        rc = exc.code if isinstance(exc.code, int) else 1
        if rc == 0:
            return 1, buf.getvalue() + "validator exited 0 without returning an order\n", None
        return rc, buf.getvalue(), None
    return 0, buf.getvalue(), order


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]

    # ── The order gate ───────────────────────────────────────────────────
    #
    # An order file is required, and it is validated before anything else.
    # Not optional, and not a flag: an optional gate is bypassed by omitting
    # it, and then the gate is the thing that can be left out rather than the
    # order.
    #
    # This runs before the backend module is imported, so a refused order
    # cannot reach the backend even by accident — there is no backend loaded
    # to reach. `scripts/test/launcher-order-gate.bats` asserts exactly that, by
    # inspecting sys.modules after a refusal rather than by reading this
    # comment.
    #
    # Added because an independent red-team rejected the validator for having
    # no caller, and a second, from a third provider, ruled that deferring the
    # caller to the next slice was the defect rather than the schedule: "a
    # gate never exercised at a real boundary is a prop whether or not its
    # unit tests are green."
    if len(argv) != 1:
        print("Usage: python3 core/launcher.py <order-file>", file=sys.stderr)
        print("  The order is validated before any backend call. There is no "
              "mode that runs without one.", file=sys.stderr)
        return 2

    order_path = argv[0]
    rc, verr, order = validate_order(order_path)
    if rc != 0:
        code = (verr.strip().splitlines() or ["E_UNKNOWN"])[0]
        print(f"ORDER REFUSED: {code}", file=sys.stderr)
        print(verr, end="", file=sys.stderr)
        print("The backend was not consulted and no workspace was created.",
              file=sys.stderr)
        return 1

    # No second read. `order` is the dict the validator inspected — the same
    # bytes its verdict was about, not the bytes at that path now.
    if order is None:
        print("REFUSED: the validator reported admissible without returning the "
              "order it inspected. Its contract changed; refusing rather than "
              "re-reading the file, because re-reading is the defect (#128).",
              file=sys.stderr)
        return 1

    print("=== Execution Core S1 — Canary Suite (per-run uid pool) ===")
    print(f"Order {order['run_id']} admitted for issue #{order['issue']}")
    print()

    import backends.macos_seatbelt as backend

    # The launcher checks the order's capabilities itself rather than
    # inheriting the validator's verdict. Two independent refusals of the same
    # order are cheap; a single point that must be right is not.
    missing = check_capabilities(order["required_capabilities"])
    if missing:
        _refuse(missing)

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

    # ── Pre-flight: is the pool clean before anything is handed to it? ──
    #
    # This ran AFTER the canary suite until a red-team pointed out what the
    # refusal is for. A process surviving from a previous run means the pool's
    # isolation is already in question, and the response to that cannot be to
    # hand it a fresh workspace first and notice afterwards. Checked before the
    # suite, refused before the suite.
    #
    # Both branches are fail-closed and neither can be reached by a sandboxed
    # process choosing its own arguments: the decision rests on the uid the
    # kernel assigned, not on anything the process wrote about itself.
    pre = backend.reconcile()
    pre_status = pre.get("stray_status", "not checked")
    pre_strays = pre.get("stray_processes", [])
    if pre_status != "ok":
        print("REFUSED: the process check could not run, so the pool cannot be "
              f"shown clean before use — {pre_status}. Not measured is not the "
              "same as clean (ADR §6).", file=sys.stderr)
        return 1
    if pre_strays:
        print(f"REFUSED: {len(pre_strays)} sandbox-owned process(es) survive "
              "from a previous run. Handing a fresh workspace to a pool whose "
              "isolation is already in question is the one thing not to do.",
              file=sys.stderr)
        for p_ in pre_strays:
            print(f"  pid {p_['pid']} slot {p_['slot']} user {p_['user']} "
                  f"state {p_['state']}: {p_['command'][:120]}", file=sys.stderr)
        print("  A root-owned survivor cannot be killed from here — kill_slot "
              "acts as the slot user. See #129, and #134 for the reaper.",
              file=sys.stderr)
        return 1

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

    # "zero orphans" used to be printed here whenever no directory had to be
    # cleaned up. reconcile() counts directories; the line reads as a statement
    # about processes, and on 2026-07-31 it was printed while a root-owned
    # worker from a killed run was still alive. Seven hours. See #129.
    #
    # Each dimension now reports itself, and "could not look" never renders as
    # "nothing there".
    strays = reconcile_result.get("stray_processes", [])
    status = reconcile_result.get("stray_status", "not checked")
    dirs_clean = not reconcile_result["removed_runs"] and not reconcile_result["released_slots"]
    if dirs_clean:
        print("reconcile(): no orphan run directories or slot claims")

    # The scope is stated in the line itself. An earlier version printed
    # "no processes outlived their run" — a claim about all processes, made by
    # a check that saw only some of them. That is the same overstatement as the
    # "zero orphans" line it replaced, one level down. What is established is
    # narrower and is now what gets said: nothing is running under a sandbox
    # slot uid whose slot is not claimed.
    if status != "ok":
        print(f"reconcile(): process check did NOT run — {status}", file=sys.stderr)
    elif strays:
        print(f"reconcile(): {len(strays)} sandbox-owned process(es) outlived "
              f"their run:", file=sys.stderr)
        for p_ in strays:
            print(f"  pid {p_['pid']} slot {p_['slot']} user {p_['user']} "
                  f"state {p_['state']}: {p_['command'][:120]}", file=sys.stderr)
    else:
        print("reconcile(): no process is running under an unclaimed slot uid")
    print()

    # ── The report has a consumer ────────────────────────────────────────
    #
    # A red-team rejected the first version for stopping at the print: "a
    # report with no consumer, no exit code, no scheduler, whose false
    # positives train dismissal." It was right. A detector whose only output is
    # a line on stderr during an unattended run is the pathology this
    # repository keeps producing, not a cure for it.
    #
    # Both refusals are fail-closed, and neither can be reached by a sandboxed
    # process choosing its own arguments — the decision rests on the uid the
    # kernel assigned, not on anything the process wrote.
    if status != "ok":
        print("REFUSED: the process check could not run, so the pool cannot be "
              "shown clean. Not measured is not the same as clean (ADR §6).",
              file=sys.stderr)
        return 1
    if strays:
        print(f"REFUSED: {len(strays)} sandbox-owned process(es) survive from a "
              f"previous run. Handing a fresh workspace to a pool whose "
              f"isolation is already in question is the one thing not to do. A "
              f"root-owned survivor cannot be killed from here — kill_slot acts "
              f"as the slot user — so this needs an operator (#129) or the "
              f"reaper decision (#134).", file=sys.stderr)
        return 1

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

    # The capability check moved to the top, where it acts on the order's
    # declared capabilities before the backend is touched. Here it took a bare
    # argv list, so it checked whatever a caller happened to type rather than
    # what the run actually required, and it ran after the canaries — that is,
    # after the backend had already been exercised.
    print("All canaries complete.  The order's capabilities are proven.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
