#!/usr/bin/env bats
# ci-checks-composer.bats — Prove that step [3/5] of ci-checks.sh fails closed
# when compose-digest.sh exits non-zero.
#
# The test does NOT run the real ci-checks.sh against the real repository. It
# builds a fixture directory with mktemp -d containing the files step [3/5]
# depends on, plus enough context for the surrounding steps to complete without
# aborting the whole script.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE="$(mktemp -d)"

  # Copy the entire scripts/ tree so ci-checks.sh and all its sourced
  # libraries and called executables are present.
  cp -r "$REPO_ROOT/scripts" "$FIXTURE/scripts"

  # Files step [3/5] touches.
  cp "$REPO_ROOT/STATE.md" "$FIXTURE/STATE.md"
  mkdir -p "$FIXTURE/digest"
  cp "$REPO_ROOT/digest/state-digest.json" "$FIXTURE/digest/state-digest.json"

  # Sub-digests the real composer reads (needed for the "real composer OK" test).
  for f in "$REPO_ROOT/digest"/*.json; do
    bn=$(basename "$f")
    [ "$bn" = "state-digest.json" ] && continue
    [ "$bn" = "census-run-state.json" ] && continue
    cp "$f" "$FIXTURE/digest/"
  done

  # Schemas for step [1/5] (validate-artifacts.sh).
  cp -r "$REPO_ROOT/schemas" "$FIXTURE/schemas"

  # Manifest for step [2/5] (pin → manifest membership).
  mkdir -p "$FIXTURE/docs"
  cp "$REPO_ROOT/docs/repository-manifest.md" "$FIXTURE/docs/repository-manifest.md"

  # Empty artifact directories so step [1/5] does not trip over missing dirs.
  mkdir -p "$FIXTURE/pins" \
           "$FIXTURE/claims" \
           "$FIXTURE/evidence" \
           "$FIXTURE/drift" \
           "$FIXTURE/findings" \
           "$FIXTURE/coverage" \
           "$FIXTURE/consumption"
}

teardown() {
  rm -rf "$FIXTURE"
}

# ---------------------------------------------------------------------------
# composer exits 1 → ci-checks.sh fails, names the composer, restores STATE.md
# ---------------------------------------------------------------------------

@test "ci-checks: composer exit 1 → fails, names composer, STATE.md unchanged" {
  # Replace compose-digest.sh with a script that just exits 1.
  echo '#!/usr/bin/env bash'  > "$FIXTURE/scripts/compose-digest.sh"
  echo 'exit 1'              >> "$FIXTURE/scripts/compose-digest.sh"
  chmod +x "$FIXTURE/scripts/compose-digest.sh"

  # Record STATE.md before the run.
  before_hash=$(shasum -a 256 "$FIXTURE/STATE.md" | awk '{print $1}')

  run bash "$FIXTURE/scripts/ci-checks.sh"

  # The overall script must exit non-zero.
  [ "$status" -ne 0 ]

  # The output must name the composer and its exit status.
  [[ "$output" == *"compose-digest.sh exited"* ]]

  # STATE.md must be byte-identical to before (the restore happened).
  after_hash=$(shasum -a 256 "$FIXTURE/STATE.md" | awk '{print $1}')
  [ "$before_hash" = "$after_hash" ]
}

# ---------------------------------------------------------------------------
# real composer → step [3/5] reports OK
# ---------------------------------------------------------------------------

@test "ci-checks: real composer → step 3 reports OK" {
  run bash "$FIXTURE/scripts/ci-checks.sh"

  # The step-3 output must contain the OK message, not the composer-exited message.
  [[ "$output" == *"OK — STATE.md and machine digest reproduce exactly from sub-digests"* ]]
  [[ "$output" != *"compose-digest.sh exited"* ]]
}
