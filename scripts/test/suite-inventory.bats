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

# A broken symlink that is NOT in the manifest reaches the check through the
# enumeration loop rather than the presence loop. Test 5 covers the listed case
# and left the enumeration guard free to be removed without any test noticing.
@test "suite-inventory: an unlisted broken symlink — returns 1" {
  mk a.bats
  man 'a.bats'
  ln -s nowhere.bats "$WORKDIR/tests/zz.bats"
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a regular file"* ]]
}

# Counting entries is not counting files: deleting budget.bats and listing
# heartbeat.bats twice restored the count, passed the required CI job, and ran
# thirteen fewer tests.
@test "suite-inventory: a duplicated manifest entry — returns 1" {
  mk a.bats
  man 'a.bats' 'a.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"listed more than once"* ]]
}

# An entry the suite glob cannot reach would satisfy the inventory while the
# test never runs — the outcome this check exists to prevent.
@test "suite-inventory: an entry with a path separator — returns 1" {
  mk a.bats
  mkdir -p "$WORKDIR/tests/nested"
  : >"$WORKDIR/tests/nested/b.bats"
  man 'a.bats' 'nested/b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"path separator"* ]]
}

# The target must EXIST, or the entry fails as "absent" and the guard under test
# is never reached — which is why removing that guard left this test green.
@test "suite-inventory: an entry escaping the test directory — returns 1" {
  mk a.bats
  : >"$WORKDIR/escape.bats"
  man 'a.bats' '../escape.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"path separator"* ]]
}

@test "suite-inventory: a hidden entry the suite glob never matches — returns 1" {
  mk a.bats
  : >"$WORKDIR/tests/.b.bats"
  man 'a.bats' '.b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hidden"* ]]
}

# Same trap: with README.md absent this passed through the missing-file check
# and proved nothing about the shape guard.
@test "suite-inventory: an entry that is not a .bats file — returns 1" {
  mk a.bats
  : >"$WORKDIR/tests/README.md"
  man 'a.bats' 'README.md'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a .bats file"* ]]
}

# Two names, one file: the count is right and a test is missing. `-ef` compares
# device and inode, so it sees through a hardlink and through the case-folding
# of a case-insensitive filesystem.
@test "suite-inventory: two manifest names hardlinked to one file — returns 1" {
  mk a.bats
  ln "$WORKDIR/tests/a.bats" "$WORKDIR/tests/b.bats"
  man 'a.bats' 'b.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"same file"* ]]
}

# Only meaningful where the filesystem folds case, which is the default on
# macOS and not the case on the Linux CI runner. Skipped rather than asserted
# where it cannot hold.
@test "suite-inventory: case-folded aliases on a case-insensitive filesystem — returns 1" {
  mk a.bats
  if [ ! -e "$WORKDIR/tests/A.bats" ]; then
    skip "filesystem is case-sensitive"
  fi
  man 'a.bats' 'A.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
}

# These three asserted only a nonzero status, which their fixtures produced for
# unrelated reasons; removing the guard under test left them green. Each now
# asserts the diagnosis it is named for.
# Reverting a single `[[ ]]` to `[` left all 22 tests green while restoring the
# original false pass. The property has to be asserted where it actually bites.
@test "suite-inventory: reaches a correct verdict with the [ builtin disabled" {
  mk a.bats
  man 'a.bats' 'b.bats'
  run bash -c "enable -n [ 2>/dev/null; PATH=''; source '$REPO_ROOT/scripts/lib/suite-inventory.sh'; check_suite_inventory '$WORKDIR/MANIFEST' '$WORKDIR/tests'"
  [ "$status" -eq 1 ]
}

# Collation is a property of the locale, not of the filesystem: under de_DE
# these two names are neither less nor greater, so the pair was never compared.
@test "suite-inventory: locale-incomparable names that are one file — returns 1" {
  mk 'ss.bats'
  # Two worlds, both valid fixtures for the same defect: on a case-sensitive
  # filesystem the two names are distinct and a hardlink makes them one inode;
  # on this Mac the filesystem folds ß onto ss, so the second name already
  # resolves to the first file and `ln` reports "File exists".
  if ! ln "$WORKDIR/tests/ss.bats" "$WORKDIR/tests/ß.bats" 2>/dev/null; then
    [ -e "$WORKDIR/tests/ß.bats" ] || skip "cannot construct the fixture here"
  fi
  man 'ss.bats' 'ß.bats'
  LC_ALL=de_DE.UTF-8 run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"same file"* ]]
}

@test "suite-inventory: an inherited GLOBIGNORE cannot hide a test file — returns 1" {
  mk a.bats; mk b.bats
  man 'a.bats'
  # The pattern must be the exact absolute path: GLOBIGNORE is matched against
  # the generated name and `*` does not cross a `/`. In CI that path is
  # entirely predictable, which is what makes this reachable.
  GLOBIGNORE="$WORKDIR/tests/b.bats" run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"b.bats"* ]]
}

@test "suite-inventory: missing manifest — returns 1, does not pass by default" {
  mk a.bats
  run check_suite_inventory "$WORKDIR/nope" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest not found"* ]]
}

@test "suite-inventory: missing test directory — returns 1" {
  man 'a.bats'
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/nodir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test directory not found"* ]]
}

@test "suite-inventory: manifest with only comments — returns 1" {
  mk a.bats
  man '# nothing here' ''
  run check_suite_inventory "$WORKDIR/MANIFEST" "$WORKDIR/tests"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no usable test files"* ]]
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
