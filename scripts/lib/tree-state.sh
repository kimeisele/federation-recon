#!/usr/bin/env bash
# tree-state.sh — snapshot and compare the working tree against HEAD.
#
# Source it, then call:
#   tree_snapshot                  # sorted description of tree deviation from HEAD
#   tree_diff <before> <after>     # print records in <after> but not <before>;
#                                  # returns 0 if identical, 1 if they differ.
#
# Both take/produce plain text so tests can feed them fixtures without git.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics. See #75.

# tree_snapshot — prints a stable, sorted description of the working tree's
# deviation from HEAD. Each record is labeled by kind:
#   status: <git status --porcelain line>
#   worktree: <path from git worktree list --porcelain>
# The main worktree is excluded; HEAD and branch lines are discarded
# (only the worktree path matters for leak detection).
tree_snapshot() {
  local main
  main="$(git rev-parse --show-toplevel 2>/dev/null)"
  {
    git status --porcelain 2>/dev/null | grep -v '^$' | sed 's/^/status: /'
    git worktree list --porcelain 2>/dev/null | awk -v main="$main" '
      /^worktree / { in_main = (substr($0, 10) == main); if (!in_main) printf "worktree: %s\n", substr($0, 10) }
    '
  } | sort
}

# tree_diff <before> <after> — prints the records present in <after> but not
# <before>, one per line; returns 0 if identical, 1 if they differ.
tree_diff() {
  local before="$1" after="$2"
  local added removed

  added=$(comm -13 \
    <(printf '%s\n' "$before" | sort) \
    <(printf '%s\n' "$after"  | sort) \
    | grep -v '^$' || true)

  removed=$(comm -23 \
    <(printf '%s\n' "$before" | sort) \
    <(printf '%s\n' "$after"  | sort) \
    | grep -v '^$' || true)

  if [ -z "$added" ] && [ -z "$removed" ]; then
    return 0
  fi

  [ -n "$added" ] && printf '%s\n' "$added"
  return 1
}
