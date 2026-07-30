#!/usr/bin/env bats
# pin-gate.bats — Tests for the pin validation gate.
#
# Tests both directions per predicate: a valid pin set passes (exit 0), and a
# crafted pin set fails for the stated reason (exit 1).  Network-dependent
# predicates (reachability, monotonicity) are exercised via a mock gh command
# that injects pre-determined comparison results — the real network path is
# exercised by CI rather than by the unit tests.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE_DIR="$REPO_ROOT/scripts/test/fixtures/pin-gate"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/manifest-gate.sh"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/pin-gate.sh"
}

# ---- Mock gh ----------------------------------------------------------------
#
# Injects pre-determined comparison results so the unit tests do not hit the
# network.  The real gh network path is exercised by CI (scripts/ci-checks.sh).
#
# Map: repo/compare/REF...SHA → status
# "identical"  — the two refs point at the same commit
# "behind"     — SHA is an ancestor of REF (reachability pass)
# "ahead"      — SHA is a descendant of REF (monotonicity pass)
# "diverged"   — the two refs have diverged (both predicates fail)
mock_gh() {
  local args="$*"

  # --- Reachability comparisons (ref...sha) ---
  case "$args" in
    *"compare/main...2222222222222222222222222222222222222222"*)
      echo "behind" ;;
    *"compare/main...3333333333333333333333333333333333333333"*)
      echo "identical" ;;
    *"compare/main...4444444444444444444444444444444444444444"*)
      echo "identical" ;;
    *"compare/main...5555555555555555555555555555555555555555"*)
      echo "diverged" ;;
    # --- Monotonicity comparisons (old_sha...new_sha) ---
    *"compare/1111111111111111111111111111111111111111...2222222222222222222222222222222222222222"*)
      echo "ahead" ;;
    *"compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...3333333333333333333333333333333333333333"*)
      echo "ahead" ;;
    *"compare/4444444444444444444444444444444444444444...4444444444444444444444444444444444444444"*)
      echo "identical" ;;
    # Monotonicity failure: new sha is behind old sha (rollback)
    *"compare/2222222222222222222222222222222222222222...1111111111111111111111111111111111111111"*)
      echo "behind" ;;
    *)
      echo "error: unmatched mock gh: $args" >&2
      return 1 ;;
  esac
}
export -f mock_gh

# `gh` is overridden by a mock in each test that needs it.  The mock is
# installed in the test body by redefining `gh` as an alias to `mock_gh` or to
# a simpler inline function.  Tests that exercise the no-network path define gh
# as a function that always fails.

# ---------------------------------------------------------------------------
# Predicate 1: Membership — positive
# ---------------------------------------------------------------------------
@test "pin-gate: membership — valid pins all correspond to manifest-adopted repos" {
  # Use a clean workdir with the fixture manifest and the fixture pin set.
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"

  run check_pin_manifest_membership \
    "$WORKDIR/manifest.md" \
    "$WORKDIR/pins/*/*.json"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Predicate 1: Membership — negative
# ---------------------------------------------------------------------------
@test "pin-gate: membership — fails when a pin for an unlisted repo is present" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"

  # Copy valid pins.
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"

  # Add a pin for a slug NOT in the fixture manifest.
  cat > "$WORKDIR/pins/test-ns/agent-unicorn.json" <<'JSON'
{"repository":"kimeisele/agent-unicorn","requested_ref":"main","resolved_commit_sha":"0000000000000000000000000000000000000000","observation_timestamp":"2026-07-25T00:00:00Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  run check_pin_manifest_membership \
    "$WORKDIR/manifest.md" \
    "$WORKDIR/pins/*/*.json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent-unicorn"* ]]
  [[ "$output" == *"not in manifest adopted observed set"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 2: Reachability — positive
# ---------------------------------------------------------------------------
@test "pin-gate: reachability — pass when sha is reachable from ref" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"

  # Mock gh to return success for all reachability comparisons.
  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Predicate 2: Reachability — negative
# ---------------------------------------------------------------------------
@test "pin-gate: reachability — fails when sha is not reachable from ref" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"
  # Copy only the steward pin (adopted slug), but change its sha to one
  # the mock returns as "diverged".
  cat > "$WORKDIR/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"5555555555555555555555555555555555555555","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reachability"* ]]
  [[ "$output" == *"5555555555555555555555555555555555555555"* ]]
  [[ "$output" == *"not reachable"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 3: Monotonicity — positive
# ---------------------------------------------------------------------------
@test "pin-gate: monotonicity — pass when new sha is descendant of old sha" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns" "$WORKDIR/prev-pins"
  # Current pins: steward with sha 222..., agent-city with sha 333...
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"
  # Previous pins: steward with sha 111..., agent-city with sha aaaa...
  cp "$FIXTURE_DIR/prev-pins/"*.json "$WORKDIR/prev-pins/"

  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md" "$WORKDIR/prev-pins"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Predicate 3: Monotonicity — negative
# ---------------------------------------------------------------------------
@test "pin-gate: monotonicity — fails when new sha is ancestor of old sha (rollback)" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns" "$WORKDIR/prev-pins"

  # Current: steward sha = 111111... (older commit, but still reachable from main)
  cat > "$WORKDIR/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"1111111111111111111111111111111111111111","observation_timestamp":"2026-07-29T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON
  # Previous: steward sha = 222222... (newer commit — so current is behind)
  cat > "$WORKDIR/prev-pins/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"2222222222222222222222222222222222222222","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  # Mock must handle both:
  #   - reachability: compare/main...1111... (sha is behind main → "behind")
  #   - monotonicity: compare/2222...1111... (new is behind old → "behind")
  gh() {
    local args="$*"
    case "$args" in
      *"compare/main...1111111111111111111111111111111111111111"*)
        echo "behind" ;;
      *"compare/2222222222222222222222222222222222222222...1111111111111111111111111111111111111111"*)
        echo "behind" ;;
      *)
        echo "error: unmatched mock gh in mono-negative: $args" >&2
        return 1 ;;
    esac
  }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md" "$WORKDIR/prev-pins"
  [ "$status" -eq 1 ]
  [[ "$output" == *"monotonicity"* ]]
  [[ "$output" == *"moved backwards"* ]]
  [[ "$output" == *"steward"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 4: Bounded change — positive (no added/removed pins)
# ---------------------------------------------------------------------------
@test "pin-gate: bounded change — pass when no pin files added or removed" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns" "$WORKDIR/prev-pins"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"
  # Previous has same set of slugs — agent-city, steward, agent-world.
  cp "$FIXTURE_DIR/prev-pins/"*.json "$WORKDIR/prev-pins/"

  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md" "$WORKDIR/prev-pins"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Predicate 4: Bounded change — negative (pin file added without manifest change)
# ---------------------------------------------------------------------------
@test "pin-gate: bounded change — fails when pin file added without manifest change" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # The actual repo root has git history.  To simulate "manifest unchanged",
  # we commit the manifest to a temporary git repo so git diff --quiet returns 0.
  git init "$WORKDIR/repo" >/dev/null 2>&1
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/repo/manifest.md"
  mkdir -p "$WORKDIR/repo/pins/test-ns" "$WORKDIR/repo/prev-pins"
  # Current pins: steward + agent-city (adopted slugs)
  cat > "$WORKDIR/repo/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"2222222222222222222222222222222222222222","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON
  cat > "$WORKDIR/repo/pins/test-ns/agent-city.json" <<'JSON'
{"repository":"kimeisele/agent-city","requested_ref":"main","resolved_commit_sha":"3333333333333333333333333333333333333333","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON
  # Previous has only steward — agent-city is the "new" pin.
  cp "$WORKDIR/repo/pins/test-ns/steward.json" "$WORKDIR/repo/prev-pins/steward.json"

  # Commit the manifest and previous pins so git sees them as committed.
  cd "$WORKDIR/repo"
  git config user.email "test@test" && git config user.name "test"
  git add manifest.md prev-pins/steward.json
  git commit -m "base" >/dev/null 2>&1
  # Now add agent-city.json to pins (after commit = manifest unchanged).
  git add pins/test-ns/agent-city.json
  cd - >/dev/null

  # Mock gh for reachability: all current sha must be reachable from main.
  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/repo/pins/*/*.json" "$WORKDIR/repo/manifest.md" "$WORKDIR/repo/prev-pins"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bounded change"* ]]
  [[ "$output" == *"added without manifest change"* ]]
}

# ---------------------------------------------------------------------------
# All predicates: full green pass with mock gh
# ---------------------------------------------------------------------------
@test "pin-gate: full green pass with all four predicates" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns" "$WORKDIR/prev-pins"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"
  cp "$FIXTURE_DIR/prev-pins/"*.json "$WORKDIR/prev-pins/"

  gh() { mock_gh "$@"; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md" "$WORKDIR/prev-pins"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK — all pins correspond"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 3: Monotonicity — negative via git show (no previous_pins_dir)
# ---------------------------------------------------------------------------
@test "pin-gate: monotonicity — fails on rollback detected via git show when no previous_pins_dir" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN

  # Init a git repo with the previous pin committed.
  git init "$WORKDIR/repo" >/dev/null 2>&1
  mkdir -p "$WORKDIR/repo/pins/test-ns"
  # Commit a pin with sha 2222...
  cat > "$WORKDIR/repo/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"2222222222222222222222222222222222222222","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON
  cd "$WORKDIR/repo"
  git config user.email "test@test" && git config user.name "test"
  git add pins/test-ns/steward.json
  git commit -m "base pin" >/dev/null 2>&1

  # Now overwrite the working copy with an older sha (rollback).
  cat > "$WORKDIR/repo/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"1111111111111111111111111111111111111111","observation_timestamp":"2026-07-29T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON
  cd - >/dev/null

  # Copy manifest into the repo.
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/repo/manifest.md"
  git -C "$WORKDIR/repo" add manifest.md
  git -C "$WORKDIR/repo" commit -m "add manifest" >/dev/null 2>&1

  # Mock gh: reachability for 1111... is "behind"; monotonicity compare of
  # 2222...1111... is "behind" → rollback detected.
  gh() {
    local args="$*"
    case "$args" in
      *"compare/main...1111111111111111111111111111111111111111"*)
        echo "behind" ;;
      *"compare/2222222222222222222222222222222222222222...1111111111111111111111111111111111111111"*)
        echo "behind" ;;
      *)
        echo "error: unmatched mock gh in mono-git-show: $args" >&2
        return 1 ;;
    esac
  }
  export -f gh

  # Call without previous_pins_dir — relies on git show HEAD:...
  run check_pin_validity "$WORKDIR/repo/pins/*/*.json" "$WORKDIR/repo/manifest.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"monotonicity"* ]]
  [[ "$output" == *"moved backwards"* ]]
  [[ "$output" == *"2222222222222222222222222222222222222222"* ]]
  [[ "$output" == *"1111111111111111111111111111111111111111"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 2: Reachability — 404 is FAIL, not UNKNOWN
# ---------------------------------------------------------------------------
@test "pin-gate: reachability — HTTP 404 from gh is FAIL, not UNKNOWN" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"

  # Pin with a sha from an unrelated repository.
  cat > "$WORKDIR/pins/test-ns/steward.json" <<'JSON'
{"repository":"kimeisele/steward","requested_ref":"main","resolved_commit_sha":"bb5c948eb4d9d0cf2858e2f16c4c6b4c0e4b7e2a","observation_timestamp":"2026-07-30T18:21:54Z","acquisition_method":"gh-api","dirty_state_assertion":false}
JSON

  # gh returns HTTP 404 (as it would for a commit sha from a foreign repo).
  gh() {
    echo "HTTP 404: Not Found" >&2
    return 1
  }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"reachability"* ]]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" != *"UNKNOWN"* ]]
  [[ "$output" == *"bb5c948eb4d9d0cf2858e2f16c4c6b4c0e4b7e2a"* ]]
}

# ---------------------------------------------------------------------------
# Predicate 2: Reachability — transport error is UNKNOWN
# ---------------------------------------------------------------------------
@test "pin-gate: reachability — transport error is UNKNOWN, not FAIL" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"

  # gh returns a transport error (connection refused, timeout, etc. — not 404).
  gh() {
    echo "gh: connection refused" >&2
    return 1
  }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md"
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" == *"network unavailable"* ]]
}

# ---------------------------------------------------------------------------
@test "pin-gate: network unavailable returns UNKNOWN and exits 2" {
  WORKDIR="$(mktemp -d)"
  trap "rm -rf $WORKDIR" RETURN
  cp "$FIXTURE_DIR/manifest.md" "$WORKDIR/manifest.md"
  mkdir -p "$WORKDIR/pins/test-ns" "$WORKDIR/prev-pins"
  cp "$FIXTURE_DIR/pin-ns/"*.json "$WORKDIR/pins/test-ns/"
  cp "$FIXTURE_DIR/prev-pins/"*.json "$WORKDIR/prev-pins/"

  # gh always fails → network unavailable.
  gh() { return 1; }
  export -f gh

  run check_pin_validity "$WORKDIR/pins/*/*.json" "$WORKDIR/manifest.md" "$WORKDIR/prev-pins"
  [ "$status" -eq 2 ]
  [[ "$output" == *"UNKNOWN"* ]]
  [[ "$output" != *"FAIL — membership"* ]]
}
