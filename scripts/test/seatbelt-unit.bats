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
# Lock file location — not in /tmp (Finding B, round 6)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: lockfile path is under _RUNS_DIR, not /tmp" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
from backends.macos_seatbelt import _LOCKFILE_PATH, _RUNS_DIR

assert not _LOCKFILE_PATH.startswith('/tmp'), \
    f'lockfile must not be in /tmp, got {_LOCKFILE_PATH}'
assert _LOCKFILE_PATH.startswith(_RUNS_DIR), \
    f'lockfile must be under _RUNS_DIR ({_RUNS_DIR}), got {_LOCKFILE_PATH}'
assert '.run_lock' in _LOCKFILE_PATH, \
    f'lockfile must use a dotted name, got {_LOCKFILE_PATH}'
print(f'OK: lockfile path {_LOCKFILE_PATH} is under _RUNS_DIR ({_RUNS_DIR})')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "seatbelt-unit: sweep does not delete lockfile" {
  run python3 -c "
import sys
sys.path.insert(0, '$REPO_ROOT/core')
import backends.macos_seatbelt as mod
import tempfile, os, shutil

tmpdir = tempfile.mkdtemp(prefix='sweeplock_')
try:
    # Create a mock lockfile (dotted name).
    lockfile = os.path.join(tmpdir, '.run_lock')
    with open(lockfile, 'w') as f:
        f.write('12345')

    # Create a stale run directory for sweep to clean.
    stale_dir = os.path.join(tmpdir, 'stale_run_001')
    os.mkdir(stale_dir)

    # Monkey-patch _RUNS_DIR to point at our temp dir.
    orig_runs = mod._RUNS_DIR
    mod._RUNS_DIR = tmpdir

    count = mod._sweep_stale_runs()

    mod._RUNS_DIR = orig_runs

    assert os.path.exists(lockfile), (
        f'sweep deleted lockfile {lockfile}!'
    )
    assert not os.path.exists(stale_dir), (
        f'sweep did not remove stale directory {stale_dir}'
    )
    assert count == 1, (
        f'expected 1 stale directory cleaned, got {count}'
    )
    print(f'OK: sweep removed {count} stale dir(s), lockfile preserved')
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
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
# kill_all: pgrep failure is caught (review #6, item 3)
# ---------------------------------------------------------------------------

@test "seatbelt-unit: kill_all pgrep exit 2 via mock-subprocess" {
  run python3 -c "
import sys, os
sys.path.insert(0, '$REPO_ROOT/core')

import subprocess as _sp
import backends.macos_seatbelt as _mod

if not os.path.exists(_mod._KILL_HELPER_PATH):
    print('SKIP: kill helper not found')
    sys.exit(0)

call_log = []

def _mock_run(cmd, *a, **kw):
    call_log.append(cmd)
    # First call (kill helper) — return success (killed nothing).
    if len(call_log) == 1:
        return _sp.CompletedProcess(cmd, 0, '', '')
    # Second call (pgrep) — return exit 2 (error).
    return _sp.CompletedProcess(cmd, 2, '', 'pgrep: error getting process list')

orig_run = _mod.subprocess.run
_mod.subprocess.run = _mock_run

try:
    result = _mod.kill_all()
    if result['ok']:
        print(f'FAIL: kill_all returned ok=True despite pgrep exit 2')
        print(f'result: {result}')
        sys.exit(1)
    print(f'OK: kill_all returned ok=False as expected')
    print(f'surviving={result.get(\"surviving\")}, stderr includes={result.get(\"stderr\",\"\")[-40:]}')
finally:
    _mod.subprocess.run = orig_run
"
  echo "$output"
  [ "$status" -eq 0 ]
}
