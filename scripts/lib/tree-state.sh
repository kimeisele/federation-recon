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

# tree_diff <before> <after> — prints every record the two snapshots disagree
# about, one per line, each prefixed: `+ ` for a record present only in
# <after>, `- ` for one present only in <before>. Returns 0 if identical, 1 if
# they differ.
#
# It used to compute both halves, fail on either, and print only the additions.
# A step that removed a record — a stale worktree pruned, a leftover file
# cleaned up — therefore failed the gate with a blank list of what it saw. See
# #121: the only available response to a blocking check whose evidence is an
# empty line is to run it again and hope, which is the habit this repository
# exists to prevent.
#
# The prefixes exist because the two directions are different events. An
# addition is a leak: the step left something behind. A removal is a step
# reaching outside its own workspace to delete state it did not create. Both
# are worth stopping for and neither should be reported as the other.
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

  [ -n "$added" ]   && printf '%s\n' "$added"   | sed 's/^/+ /'
  [ -n "$removed" ] && printf '%s\n' "$removed" | sed 's/^/- /'
  return 1
}

# tree_change_kind <diff-output> — names what a tree_diff result contains:
# "left records behind", "removed records", or "left records behind and removed
# others". Prints nothing for empty input. Lets a caller say which of the two
# events it is looking at instead of one word covering both.
tree_change_kind() {
  local diff_output="$1" has_added=0 has_removed=0
  # Anchored per line: a path may legitimately contain "+ " or "- " anywhere
  # but the first two columns, and a substring test would read those as a
  # direction the diff never reported.
  printf '%s\n' "$diff_output" | grep -q '^+ ' && has_added=1
  printf '%s\n' "$diff_output" | grep -q '^- ' && has_removed=1
  if [ "$has_added" = 1 ] && [ "$has_removed" = 1 ]; then
    printf 'left records behind and removed others'
  elif [ "$has_added" = 1 ]; then
    printf 'left records behind'
  elif [ "$has_removed" = 1 ]; then
    printf 'removed records it did not create'
  fi
}

# tree_status_records <snapshot> — prints only the status: records from a
# snapshot (as produced by tree_snapshot). Prints nothing when there are none.
# Always returns 0; emptiness is the answer, not an error.
tree_status_records() {
  local snap="$1"
  printf '%s\n' "$snap" | grep '^status:' || true
}
