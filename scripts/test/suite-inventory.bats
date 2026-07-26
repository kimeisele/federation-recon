#!/usr/bin/env bats
#
# Regression tests for scripts/lib/suite-inventory.sh.
#
# The first implementation of this check was reverted from PR #73 after a
# reviewer found four ways past it. Each of those four has a test here, because
# the check exists precisely to be the thing nobody looks at again.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  WORKDIR="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$WORKDIR/tests"

  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/suite-inventory.sh"
}

teardown() {
  rm -rf "$WORKDIR"
}

mk()  { : >"$WORKDIR/tests/$1"; }
man() { printf '%s\n' "$@" >"$WORKDIR/MANIFEST"; }

@test "suite-inventory: disk matches the manifest — returns 0" {
  mk a.bats; mk b.bats
  man '# a comment' '' 'a.bats' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
}

@test "suite-inventory: a listed test file was deleted — returns 1 and names it" {
  mk a.bats
  man 'a.bats' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"listed but absent"* ]]
  [[ "$output" == *"b.bats"* ]]
}

# Otherwise the manifest decays into a list of the files somebody remembered.
@test "suite-inventory: a test file exists but is unlisted — returns 1" {
  mk a.bats; mk b.bats
  man 'a.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"present but unlisted"* ]]
  [[ "$output" == *"b.bats"* ]]
}

# Reviewer finding 3, the one that disproved the previous version's claim:
# budget.bats -> heartbeat.bats left every name and count correct while one test
# ran twice and another never ran.
@test "suite-inventory: a listed file replaced by a symlink — returns 1" {
  mk a.bats
  ln -s a.bats "$WORKDIR/tests/b.bats"
  man 'a.bats' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a regular file"* ]] || [[ "$output" == *"symlink"* ]]
}

# Reviewer finding 4.
@test "suite-inventory: a broken symlink — returns 1, is not skipped" {
  mk a.bats
  ln -s nowhere.bats "$WORKDIR/tests/b.bats"
  man 'a.bats' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# Reviewer finding 2: `ls | xargs basename` split at the space, so one file
# named "a b.bats" satisfied a manifest listing "a" and "b.bats".
@test "suite-inventory: a filename containing a space is one name, not two" {
  mk 'a b.bats'
  man 'a' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

@test "suite-inventory: a filename containing a space, correctly listed — returns 0" {
  mk 'a b.bats'
  man 'a b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
}

# Reviewer finding 1 was an ignored `comm` exit status. The answer was to use no
# external command at all, so the property to hold is that an empty PATH cannot
# turn a mismatch into agreement.
@test "suite-inventory: no external commands are needed to reach a verdict" {
  mk a.bats
  man 'a.bats' 'b.bats'
  PATH="" run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

@test "suite-inventory: missing manifest — returns 1, does not pass by default" {
  mk a.bats
  run check_suite_inventory "$WORKDIR/nope" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

@test "suite-inventory: missing test directory — returns 1" {
  man 'a.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/nodir"
  [ "$status" -eq 1 ]
}

@test "suite-inventory: manifest with only comments — returns 1" {
  mk a.bats
  man '# nothing here' ''
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# A manifest that travelled through Windows must not fail for the wrong reason.
@test "suite-inventory: CRLF line endings in the manifest — returns 0" {
  mk a.bats; mk b.bats
  printf 'a.bats\r\nb.bats\r\n' >"$WORKDIR/MANIFEST"
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
}

@test "suite-inventory: trailing whitespace and a missing final newline — returns 0" {
  mk a.bats; mk b.bats
  printf 'a.bats   \n   b.bats' >"$WORKDIR/MANIFEST"
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 0 ]
}

# The real repository, not a fixture. If this fails, the manifest is stale.
@test "suite-inventory: the committed manifest matches the committed suite" {
  run check_suite_inventory "$REPO_ROOT/scripts/test/MANIFEST" "$REPO_ROOT/scripts/test"
  [ "$status" -eq 0 ]
}
