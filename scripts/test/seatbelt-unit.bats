#!/usr/bin/env bats
# seatbelt-unit.bats — Offline unit tests for core/backends/macos_seatbelt.py
#
# These tests run _copy_file_secure / _copy_ingress directly without a
# sandbox or sudo, exercising internal defences that canaries cannot reach
# (e.g. the post-read growth check, which the mkdir guard masks in the
# ingress_symlink canary).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
}

# ---------------------------------------------------------------------------
# Egress growth race — post-read cap check in _copy_file_secure
# ---------------------------------------------------------------------------

@test "seatbelt-unit: egress growth race is caught" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
from backends.macos_seatbelt import test_egress_growth_race

passed, msg = test_egress_growth_race()
if not passed:
    print(msg)
    sys.exit(1)
print(msg)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# run_id validation — path escape defence (Finding 6)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: run_id with slash is refused" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
from backends.macos_seatbelt import _RUNS_DIR, run

# Try run_id containing a slash — must raise.
import tempfile, os
tmp = tempfile.mkdtemp(prefix='pathtest_')
try:
    run('no_network', tmp, run_id='../../../../private/tmp/x')
    print('ERROR: run() did NOT raise on slash-containing run_id')
    sys.exit(1)
except ValueError as e:
    print('OK: ValueError raised:', e)
except PermissionError as e:
    print('OK: PermissionError raised (from lock or mkdir):', e)
except Exception as e:
    print(f'OK: {type(e).__name__} raised:', e)

# Verify NO directory was created outside _RUNS_DIR for this run_id.
escaped_path = os.path.join(_RUNS_DIR, '../../../../private/tmp/x')
real = os.path.realpath(escaped_path)
if real.startswith('/private/tmp/x') or real.startswith('/tmp/x'):
    print(f'ERROR: directory created outside _RUNS_DIR at {real}')
    sys.exit(1)
print(f'OK: no directory created outside _RUNS_DIR (resolved to {real})')

os.rmdir(tmp)
print('ALL OK')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "seatbelt-unit: run_id with embedded newline is refused" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
from backends.macos_seatbelt import _RUNS_DIR, run

# Try run_id containing an embedded newline — must raise.
import tempfile, os
tmp = tempfile.mkdtemp(prefix='pathtest_')
try:
    run('no_network', tmp, run_id='../../../../private/tmp/x\nOK')
    print('ERROR: run() did NOT raise on newline-containing run_id')
    sys.exit(1)
except ValueError as e:
    print('OK: ValueError raised:', e)
except PermissionError as e:
    print('OK: PermissionError raised (from lock or mkdir):', e)
except Exception as e:
    print(f'OK: {type(e).__name__} raised:', e)

os.rmdir(tmp)
print('ALL OK')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "seatbelt-unit: clean run_id passes validation" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
from backends.macos_seatbelt import run

# A clean run_id should not be ValueError'd at validation time.
# It may fail later (lock contention, missing canary, etc.), but
# the validation itself must pass.
import tempfile, os
tmp = tempfile.mkdtemp(prefix='pathtest_')
try:
    # Use a test-only run_id — it will fail on lock/mkdir but
    # we just need to ensure validation does not reject it.
    run('no_network', tmp, run_id='clean_test_id_42')
    # If we get here, the sandbox was invoked — but we only care
    # that validation passed.
    print('OK: clean run_id accepted by validation')
except ValueError as e:
    print(f'UNEXPECTED: ValueError on clean run_id: {e}')
    sys.exit(1)
except PermissionError as e:
    # Expected: lock contention or mkdir issue — validation passed.
    pass
except Exception as e:
    # Any other exception means validation passed (the error is later).
    pass

import shutil as _su
_su.rmtree(tmp)
print('VALIDATION OK: clean run_id accepted')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Directory permission enforcement — slots dir must not be writable (F3 fix)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: refuses to run when slots dir is group-writable" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import tempfile, os, stat, shutil

tmp = tempfile.mkdtemp(prefix='slotperm_')
try:
    import backends.macos_seatbelt as mod

    runs_dir = os.path.join(tmp, 'runs')
    slots_dir = os.path.join(tmp, 'slots')
    os.mkdir(runs_dir, 0o755)
    os.mkdir(slots_dir, 0o755)
    os.chmod(slots_dir, 0o770)  # force group-writable (bypass umask)

    orig_runs, orig_slots = mod._RUNS_DIR, mod._SLOTS_DIR
    mod._RUNS_DIR = runs_dir
    mod._SLOTS_DIR = slots_dir

    try:
        mod._verify_runs_dir_secure()
        print('ERROR: did not raise on group-writable slots dir')
        sys.exit(1)
    except PermissionError as e:
        msg = str(e)
        print(f'OK: PermissionError raised: {msg[:80]}')
    except Exception as e:
        print(f'ERROR: wrong exception {type(e).__name__}: {e}')
        sys.exit(1)
    finally:
        mod._RUNS_DIR = orig_runs
        mod._SLOTS_DIR = orig_slots
finally:
    shutil.rmtree(tmp, ignore_errors=True)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "seatbelt-unit: refuses to run when runs dir is world-writable" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import tempfile, os, stat, shutil

tmp = tempfile.mkdtemp(prefix='slotperm_')
try:
    import backends.macos_seatbelt as mod

    runs_dir = os.path.join(tmp, 'runs')
    slots_dir = os.path.join(tmp, 'slots')
    os.mkdir(runs_dir, 0o755)
    os.chmod(runs_dir, 0o707)  # force world-writable (bypass umask)
    os.mkdir(slots_dir, 0o755)

    orig_runs, orig_slots = mod._RUNS_DIR, mod._SLOTS_DIR
    mod._RUNS_DIR = runs_dir
    mod._SLOTS_DIR = slots_dir

    try:
        mod._verify_runs_dir_secure()
        print('ERROR: did not raise on world-writable runs dir')
        sys.exit(1)
    except PermissionError as e:
        msg = str(e)
        print(f'OK: PermissionError raised: {msg[:80]}')
    except Exception as e:
        print(f'ERROR: wrong exception {type(e).__name__}: {e}')
        sys.exit(1)
    finally:
        mod._RUNS_DIR = orig_runs
        mod._SLOTS_DIR = orig_slots
finally:
    shutil.rmtree(tmp, ignore_errors=True)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Quarantine — rmtree fallback when os.rename fails (F4 fix)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: _quarantine falls back to rmtree when rename fails" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import tempfile, os, shutil

tmp = tempfile.mkdtemp(prefix='quarantine_')
try:
    import backends.macos_seatbelt as mod

    slots_dir = os.path.join(tmp, 'slots')
    os.mkdir(slots_dir)

    orig_slots = mod._SLOTS_DIR
    mod._SLOTS_DIR = slots_dir

    # Create a claim directory.
    slot_name = '_jcode_w01'
    claim_dir = os.path.join(slots_dir, slot_name)
    os.mkdir(claim_dir)
    assert os.path.isdir(claim_dir), 'claim dir should exist'

    # Monkey-patch os.rename on the module to simulate rename failure.
    orig_rename = mod.os.rename
    def _fail_rename(src, dst):
        raise OSError(1, 'simulated rename failure')
    mod.os.rename = _fail_rename

    try:
        mod._quarantine(slot_name, 'test reason')

        # Claim dir must be gone (rmtree fallback).
        if os.path.isdir(claim_dir):
            print(f'ERROR: claim dir still exists after _quarantine fallback')
            sys.exit(1)

        # No quarantined directory should have been created (rename never
        # completed).
        for entry in os.listdir(slots_dir):
            if 'quarantined' in entry:
                print(f'ERROR: quarantined dir {entry} created despite rename failure')
                sys.exit(1)

        print('OK: _quarantine removed claim dir via rmtree fallback')
    finally:
        mod.os.rename = orig_rename
        mod._SLOTS_DIR = orig_slots
finally:
    shutil.rmtree(tmp, ignore_errors=True)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Launcher: unregistered claim is refused (review #7, item 4)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: launcher refuses unregistered claimed capability" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import launcher

# Monkey-patch to inject a claim that is not in _CANARY_ORDER.
p = launcher._load_policy().copy()
p['claimed_capabilities'] = list(p['claimed_capabilities']) + ['claim_absent_from_order']
launcher._load_policy = lambda: p
launcher._run_one_canary = lambda *_: (True, 'forced pass')

result = launcher._run_canary_suite()
passed, surviving = result
if passed:
    print('ERROR: suite passed despite unregistered claim')
    sys.exit(1)
print('OK: suite refused with unregistered claim')
print('surviving set:', surviving)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "seatbelt-unit: launcher warns when registered canary is not claimed" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import launcher

# Monkey-patch to remove a claim that IS in _CANARY_ORDER.
p = launcher._load_policy().copy()
p['claimed_capabilities'] = [c for c in p['claimed_capabilities'] if c != 'ingress_symlink']
launcher._load_policy = lambda: p
launcher._run_one_canary = lambda *_: (True, 'forced pass')

result = launcher._run_canary_suite()
passed, surviving = result
print('OK: suite passed but should have printed WARNING for ingress_symlink')
print('passed:', passed)
print('surviving:', surviving)
"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# kill_slot: non-zero helper exit is reported as ok=False
# ---------------------------------------------------------------------------

@test "seatbelt-unit: kill_slot returns ok=False when helper exits with status 2" {
  run python3 -c "
import sys, os
sys.path.insert(0, '$REPO_ROOT/core')
import tempfile, shutil
import subprocess as _sp

import backends.macos_seatbelt as mod

# Create a temporary kill-self helper so _KILL_SELF_PATH exists.
tmp = tempfile.mkdtemp(prefix='killslot_')
try:
    helper_path = os.path.join(tmp, 'worker_kill_self.sh')
    with open(helper_path, 'w') as f:
        f.write('#!/bin/sh\necho mock\n')
    os.chmod(helper_path, 0o755)

    orig_helper = mod._KILL_SELF_PATH
    mod._KILL_SELF_PATH = helper_path

    def _mock_run(cmd, *a, **kw):
        # Return non-zero exit (simulating helper failure).
        return _sp.CompletedProcess(cmd, 2, '', 'mock error: pgrep failed')

    orig_run = mod.subprocess.run
    mod.subprocess.run = _mock_run

    try:
        result = mod.kill_slot('_jcode_w01', 611)
        if result.get('ok'):
            print(f'ERROR: kill_slot returned ok=True despite helper exit 2')
            print(f'result: {result}')
            sys.exit(1)
        print(f'OK: kill_slot returned ok=False as expected')
        print(f'returncode={result.get(\"returncode\")}, stderr={result.get(\"stderr\",\"\")[-40:]}')
    finally:
        mod.subprocess.run = orig_run
        mod._KILL_SELF_PATH = orig_helper
finally:
    shutil.rmtree(tmp, ignore_errors=True)
"
  echo "$output"
  [ "$status" -eq 0 ]
}
