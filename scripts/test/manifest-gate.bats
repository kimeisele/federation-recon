#!/usr/bin/env bats
# manifest-gate.bats — Tests for the pin → manifest membership gate.
#
# The gate verifies that every pin under pins/*/ corresponds to a repository
# listed in the manifest's adopted observed set. This test proves both the
# positive (green) and negative (red) paths using the shared library, not a
# duplicate of the logic (see docs/operator-lessons.md).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/manifest-gate.sh"
}

# ---------------------------------------------------------------------------
# Positive: the committed tree passes
# ---------------------------------------------------------------------------

@test "manifest-gate: committed pins all correspond to manifest-adopted repos" {
  run check_pin_manifest_membership \
    "$REPO_ROOT/docs/repository-manifest.md" \
    "$REPO_ROOT/pins/*/*.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative: a pin for an unlisted repository is caught
# ---------------------------------------------------------------------------

@test "manifest-gate: fails when a pin for an unlisted repo is present" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Copy the manifest into the workdir so the gate can parse it.
  cp "$REPO_ROOT/docs/repository-manifest.md" "$WORKDIR/manifest.md"

  # Create a pins namespace directory with one valid adopted pin and one
  # pin whose slug is NOT in the manifest's adopted observed set.
  mkdir -p "$WORKDIR/pins/test-ns"

  # Valid pin (steward is in the manifest)
  cat > "$WORKDIR/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"a007a1428745b9bf342ae1c086e6d717338669a3","observation_timestamp":"2026-07-24T15:23:48Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  # Fixture pin: agent-unicorn is NOT in the manifest adopted observed set.
  # This is the mutation that must cause the gate to fail.
  cat > "$WORKDIR/pins/test-ns/agent-unicorn.json" <<'JSON'
{"repository":"kimeisele/agent-unicorn","requested_ref":"main","resolved_commit_sha":"0000000000000000000000000000000000000000","observation_timestamp":"2026-07-25T00:00:00Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  run check_pin_manifest_membership \
    "$WORKDIR/manifest.md" \
    "$WORKDIR/pins/*/*.json"
  [ "$status" -ne 0 ]
  # The error output must name the offending pin and repository.
  [[ "$output" == *"agent-unicorn"* ]]
  [[ "$output" == *"not in manifest adopted observed set"* ]]
}
