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
