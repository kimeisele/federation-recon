#!/usr/bin/env bats
# tree-state.bats — Unit tests for scripts/lib/tree-state.sh
#
# Tests: tree_snapshot, tree_diff
# All diff tests use fixture strings — no git required.
# Snapshot tests use a temporary git repo.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/tree-state.sh"
}

# ---------------------------------------------------------------------------
# tree_diff — fixture-string tests (no git)
# ---------------------------------------------------------------------------

@test "tree_diff: identical snapshots return 0 and print nothing" {
  snap="$(printf '?? foo\n M bar')"
  run tree_diff "$snap" "$snap"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tree_diff: record added in after returns 1 and prints the new record" {
  before="?? foo"
  after="$(printf '?? foo\n?? baz')"
  run tree_diff "$before" "$after"
  [ "$status" -eq 1 ]
  [ "$output" = "?? baz" ]
}

@test "tree_diff: record removed in after returns 1" {
  before="$(printf '?? foo\n?? bar')"
  after="?? foo"
  run tree_diff "$before" "$after"
  [ "$status" -eq 1 ]
}

@test "tree_diff: reordered but equal content returns 0" {
  before="$(printf '?? foo\n?? bar\n?? baz')"
  after="$(printf '?? baz\n?? foo\n?? bar')"
  run tree_diff "$before" "$after"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "tree_diff: empty before, non-empty after returns 1 and prints every record" {
  before=""
  after="$(printf '?? alpha\n?? beta')"
  run tree_diff "$before" "$after"
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
  echo "$output" | grep -q '?? alpha'
  echo "$output" | grep -q '?? beta'
}

# ---------------------------------------------------------------------------
# tree_snapshot — git-based tests (hermetic: every git op in mktemp -d)
# ---------------------------------------------------------------------------

@test "tree_snapshot: clean repo prints nothing; untracked file appears" {
  d="$(mktemp -d "${TMPDIR:-/tmp}/bats-treesnap.XXXXXX")"
  cd "$d"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  git commit --allow-empty -m "init" -q

  run tree_snapshot
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  touch untracked-file
  run tree_snapshot
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'untracked-file'

  cd /
  rm -rf "$d"
}

@test "tree_snapshot: includes and excludes registered worktrees" {
  d="$(mktemp -d "${TMPDIR:-/tmp}/bats-treesnap.XXXXXX")"
  cd "$d"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  git commit --allow-empty -m "init" -q

  # Create a worktree; the snapshot must name it.
  wt="$(mktemp -d "${TMPDIR:-/tmp}/bats-wt.XXXXXX")"
  git worktree add "$wt" >/dev/null 2>&1
  run tree_snapshot
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'worktree'

  # Remove it; the snapshot must not name it.
  git worktree remove -f "$wt" >/dev/null 2>&1
  run tree_snapshot
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'worktree'

  cd /
  rm -rf "$d" "$wt"
}

@test "tree_snapshot: worktree with clean tree yields zero status: records" {
  d="$(mktemp -d "${TMPDIR:-/tmp}/bats-treesnap.XXXXXX")"
  cd "$d"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  git commit --allow-empty -m "init" -q

  wt="$(mktemp -d "${TMPDIR:-/tmp}/bats-wt.XXXXXX")"
  git worktree add "$wt" >/dev/null 2>&1

  run tree_snapshot
  [ "$status" -eq 0 ]
  # Snapshot is non-empty (has worktree records).
  [ -n "$output" ]
  # Every line is labeled — HEAD/branch lines would appear bare.
  ! printf '%s\n' "$output" | grep -qv '^\(status:\|worktree:\)'
  # Zero status: records on a clean tree.
  status_count="$(printf '%s\n' "$output" | grep -c '^status:' || true)"
  [ "$status_count" -eq 0 ]

  cd /
  rm -rf "$d" "$wt"
}

@test "tree_snapshot: worktree plus untracked file yields exactly one status: record" {
  d="$(mktemp -d "${TMPDIR:-/tmp}/bats-treesnap.XXXXXX")"
  cd "$d"
  git init -q
  git config user.email "test@test"
  git config user.name "Test"
  git commit --allow-empty -m "init" -q

  wt="$(mktemp -d "${TMPDIR:-/tmp}/bats-wt.XXXXXX")"
  git worktree add "$wt" >/dev/null 2>&1

  touch stray-file
  run tree_snapshot
  [ "$status" -eq 0 ]
  # Exactly one status: record.
  status_count="$(printf '%s\n' "$output" | grep -c '^status:' || true)"
  [ "$status_count" -eq 1 ]
  # That record names the untracked file.
  printf '%s\n' "$output" | grep '^status:' | grep -q 'stray-file'

  cd /
  rm -rf "$d" "$wt"
}
