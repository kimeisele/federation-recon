"""
Canary: pool_integrity — verifies the slot pool is correctly configured.

Checks all eight slots exist with:
  - uid 611..618
  - shell /usr/bin/false
  - Group set exactly matches the macOS default baseline.
    Measured on this machine (2026-07-30):
      <slot> everyone localaccounts _lpoperator com.apple.sharepoint.group.1
    Apple's own _spotlight has the identical set, so assert equality.
  - sudo -n -u <slot> /usr/bin/id is REFUSED — a slot may run nothing.
    Note: this check is meaningless if run as uid 0 (root may switch
    identity without a password).  The canary asserts it is not running
    as uid 0 before trusting the result.

This is the drift check: pool setup can be canaried like everything else.
"""

import os
import subprocess
import sys

_SLOT_NAMES = ["_jcode_w01", "_jcode_w02", "_jcode_w03", "_jcode_w04",
               "_jcode_w05", "_jcode_w06", "_jcode_w07", "_jcode_w08"]
_SLOT_UIDS = [611, 612, 613, 614, 615, 616, 617, 618]

# Baseline group set measured on this machine (2026-07-30).
# Apple's own _spotlight has the identical set.
_BASELINE_GROUPS = frozenset({
    "everyone",
    "localaccounts",
    "_lpoperator",
    "com.apple.sharepoint.group.1",
})


def run(backend):
    # Assert we are not running as uid 0 — the sudo check below is
    # meaningless if root can switch identity without a password.
    if os.getuid() == 0:
        return False, (
            "pool_integrity check is meaningless when run as uid 0 "
            "(root may switch identity without a password) — "
            "must be run as a non-root user"
        )

    for idx, (name, expected_uid) in enumerate(zip(_SLOT_NAMES, _SLOT_UIDS), start=1):
        # ── Check existence ──────────────────────────────────────────
        dscl_cmd = ["dscl", ".", "-read", f"/Users/{name}"]
        result = subprocess.run(
            dscl_cmd,
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return False, (
                f"slot {name} does not exist — dscl returned "
                f"exit {result.returncode}: {result.stderr.strip()}"
            )

        # ── Check uid ────────────────────────────────────────────────
        uid_check = subprocess.run(
            ["dscl", ".", "-read", f"/Users/{name}", "UniqueID"],
            capture_output=True, text=True, timeout=5,
        )
        if uid_check.returncode != 0:
            return False, (
                f"slot {name}: cannot read UniqueID — "
                f"{uid_check.stderr.strip()}"
            )
        uid_value = uid_check.stdout.strip()
        # Expected format: "UniqueID: 611"
        parts = uid_value.split()
        if len(parts) < 2:
            return False, (
                f"slot {name}: cannot parse UniqueID value: {uid_value!r}"
            )
        try:
            actual_uid = int(parts[-1])
        except (ValueError, IndexError):
            return False, (
                f"slot {name}: UniqueID is not an integer: "
                f"{uid_value!r}"
            )
        if actual_uid != expected_uid:
            return False, (
                f"slot {name}: expected uid {expected_uid}, "
                f"got {actual_uid}"
            )

        # ── Check shell ──────────────────────────────────────────────
        shell_check = subprocess.run(
            ["dscl", ".", "-read", f"/Users/{name}", "UserShell"],
            capture_output=True, text=True, timeout=5,
        )
        shell_value = shell_check.stdout.strip()
        # Expected: "UserShell: /usr/bin/false"
        if "/usr/bin/false" not in shell_value:
            return False, (
                f"slot {name}: shell is not /usr/bin/false: "
                f"{shell_value!r}"
            )

        # ── Check group membership ───────────────────────────────────
        groups_check = subprocess.run(
            ["id", "-Gn", name],
            capture_output=True, text=True, timeout=5,
        )
        if groups_check.returncode != 0:
            return False, (
                f"slot {name}: id -Gn failed (exit {groups_check.returncode}): "
                f"{groups_check.stderr.strip()} — UNKNOWN, cannot determine groups"
            )

        groups_str = groups_check.stdout.strip()
        if not groups_str:
            return False, (
                f"slot {name}: id -Gn returned empty output — "
                "UNKNOWN, cannot determine groups"
            )

        actual_groups = frozenset(groups_str.split())
        expected_groups = _BASELINE_GROUPS | {name}

        if actual_groups != expected_groups:
            return False, (
                f"slot {name}: group set mismatch.  "
                f"Expected: {sorted(expected_groups)}.  "
                f"Got: {sorted(actual_groups)}.  "
                "Drift in slot group membership detected."
            )

        # ── Check sudo is refused ────────────────────────────────────
        sudo_check = subprocess.run(
            ["sudo", "-n", "-u", name, "/usr/bin/id"],
            capture_output=True, text=True, timeout=5,
        )
        # sudo should refuse — exit code non-zero, stderr contains
        # "a password is required" or similar.
        if sudo_check.returncode == 0:
            return False, (
                f"slot {name}: sudo -u {name} /usr/bin/id SUCCEEDED — "
                "a slot should not be able to run arbitrary commands.  "
                "The sudoers entry must grant only the specific wrappers."
            )

    return True, (
        f"all {len(_SLOT_NAMES)} slots verified: "
        f"uid {_SLOT_UIDS[0]}..{_SLOT_UIDS[-1]}, "
        "shell /usr/bin/false, "
        "group membership matches baseline, "
        "sudo -u <slot> /usr/bin/id refused"
    )
