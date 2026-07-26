#!/usr/bin/env bash
# suite-inventory.sh — the test suite must match a committed list of its files.
#
# Source it, then call:
#   check_suite_inventory <manifest_file> [testdir]
#
# The runner reports what it ran. It cannot report what was supposed to run:
# delete a test file and the remaining ones still pass, quietly and green. The
# first answer to that was "deleting a file under scripts/ needs a code owner's
# approval", which is true and is not a control — approval establishes that
# somebody agreed to a diff, not that the suite is still complete. A bad rebase,
# a lost merge, or an `rm` in the wrong directory has nobody to agree with.
#
# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. See #75.
#
# ---------------------------------------------------------------------------
# Two independent reviews have taken versions of this check apart. Eight ways
# past it were executed, not theorised, and every one of them is a line below:
#
#   1. `comm`'s exit status was ignored. With `comm` unavailable the check
#      printed "OK — all 14 listed test files are present" and the required CI
#      job reported PASS.
#   2. `ls | xargs basename` split at whitespace: one file named `a b.bats`
#      satisfied a manifest listing `a` and `b.bats`.
#   3. The inventory compared names while the runner followed symlinks.
#      budget.bats -> heartbeat.bats: inventory green, gate green,
#      heartbeat.bats run twice, budget.bats never run.
#   4. A broken symlink passed unnoticed.
#   5. A duplicate entry restored the count. Deleting budget.bats and listing
#      heartbeat.bats twice passed the required job and the full gate, which
#      reported 230 tests instead of 243. Counting entries is not counting
#      files.
#   6. Entries were not constrained to names the runner can see. `../ci-checks.sh`,
#      `nested/required.bats` and `.required.bats` all satisfied the inventory
#      while the suite glob never ran them.
#   7. Two names can be one file: a hardlink, or `A.bats` and `a.bats` on a
#      case-insensitive filesystem.
#   8. The claim "no helper's absence can mean agreement" was still false while
#      the comparison used `[`, which is a builtin and can be disabled. With
#      `[` gone the check returned 0 and reported "all 0 listed test files".
#
#   9. `[[ "$a" < "$b" ]]` assumed two distinct strings always have an order.
#      Under de_DE.UTF-8 `ß.bats` and `ss.bats` are neither less nor greater, so
#      the pair was never compared, and on a case-folding filesystem those two
#      names are one file. Collation belongs to the locale, not the filesystem.
#  10. An inherited GLOBIGNORE hid a file from the enumeration glob silently.
#
# Hence: no external command participates in reaching a verdict, every
# comparison uses the `[[ ]]` keyword, which the shell cannot disable, pairs are
# selected by position rather than by ordering names, and GLOBIGNORE is
# neutralised. Enumeration is a glob and membership is a `case`.
#
# What that does not cover, because two rounds of claiming otherwise were wrong:
# an environment that pre-empts the shell's own builtins. An exported function
# named `read` or `return` defeats this function, and an exported `unset`
# defeats the countermeasure. A check running inside a shell somebody else
# configured cannot out-argue that shell; the boundary is CI, where the
# environment is provisioned rather than inherited. `scripts/ci-checks.sh`
# clears the accidental cases and says so.
# ---------------------------------------------------------------------------

check_suite_inventory() {
  local manifest_file="$1" testdir="${2:-scripts/test}"
  local line name base f a b expected="" seen="" rc=0 n_expected=0
  local missing="" unlisted="" irregular="" invalid="" duplicate="" aliased=""

  # GLOBIGNORE removes matches from a glob silently, and it can be injected from
  # the environment. The enumeration below is a glob, so an inherited value could
  # hide a test file from the "present but unlisted" half of the check without
  # any error anywhere. Neutralised for the duration of this function.
  local GLOBIGNORE=

  if [[ ! -f "$manifest_file" ]]; then
    echo "FAIL — suite manifest not found: $manifest_file" >&2
    return 1
  fi
  if [[ ! -d "$testdir" ]]; then
    echo "FAIL — test directory not found: $testdir" >&2
    return 1
  fi

  # Read the manifest. Comments and surrounding whitespace are stripped, which
  # also removes a trailing CR from a file that travelled through Windows.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue

    # An entry must be a name the suite glob can actually reach. A path, a
    # parent reference or a leading dot names something the runner will never
    # execute, so listing it would satisfy the inventory while the test sits
    # there unrun — the exact outcome this check exists to prevent.
    case "$line" in
      */*)    invalid="${invalid}  ${line} (contains a path separator)
"; rc=1; continue ;;
      .*)     invalid="${invalid}  ${line} (hidden; the suite glob never matches it)
"; rc=1; continue ;;
      *.bats) ;;
      *)      invalid="${invalid}  ${line} (not a .bats file)
"; rc=1; continue ;;
    esac

    # A repeated entry restores the count while a file is missing.
    case "
$seen" in
      *"
$line
"*) duplicate="${duplicate}  ${line}
"; rc=1; continue ;;
    esac
    seen="${seen}${line}
"

    expected="${expected}${line}
"
    n_expected=$(( n_expected + 1 ))
  done < "$manifest_file"

  if [[ "$n_expected" == 0 ]]; then
    echo "FAIL — suite manifest lists no usable test files: $manifest_file" >&2
    [[ -n "$invalid" ]] && printf '%s' "$invalid" >&2
    return 1
  fi

  # Every listed file must be present, and present as a regular file. A symlink
  # that resolves is still wrong: it makes one test run twice and another not at
  # all while every name and count still looks right.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    f="$testdir/$name"
    if [[ -L "$f" ]]; then
      irregular="${irregular}  ${name} (symlink)
"
      rc=1
    elif [[ ! -f "$f" ]]; then
      missing="${missing}  ${name}
"
      rc=1
    fi
  done <<EOF
$expected
EOF

  # Distinct names, one file. A hardlink, or `A.bats` and `a.bats` on a
  # case-insensitive filesystem: the count is right and a test is missing.
  # `-ef` compares device and inode, so it sees through both.
  #
  # Pairs are selected by position, not by comparing the names. `[[ "$a" < "$b" ]]`
  # assumed two distinct strings always have an order; under de_DE.UTF-8,
  # `ß.bats` and `ss.bats` are neither less nor greater, so the pair was skipped
  # and the two names — one file on a case-folding filesystem — passed as
  # distinct. Collation is a property of the locale, not of the filesystem.
  local i=0 j
  while IFS= read -r a; do
    [[ -n "$a" ]] || continue
    i=$(( i + 1 ))
    j=0
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      j=$(( j + 1 ))
      [[ "$j" -gt "$i" ]] || continue    # each unordered pair once, no ordering of names
      if [[ -e "$testdir/$a" && -e "$testdir/$b" && "$testdir/$a" -ef "$testdir/$b" ]]; then
        aliased="${aliased}  ${a} and ${b} are the same file
"
        rc=1
      fi
    done <<EOF
$expected
EOF
  done <<EOF
$expected
EOF

  # And every test file present must be listed, so that adding a test without
  # recording it fails too. Otherwise the manifest decays into a list of the
  # files somebody remembered.
  for f in "$testdir"/*.bats; do
    # An unmatched glob leaves the literal pattern, which is neither -e nor -L.
    # A broken symlink is -L but not -e, and must be reported rather than
    # skipped: skipping is how a missing test file stays invisible.
    [[ -e "$f" || -L "$f" ]] || continue
    base="${f##*/}"
    if [[ -L "$f" || ! -f "$f" ]]; then
      case "
$irregular" in
        *"
  $base ("*) ;;
        *) irregular="${irregular}  ${base} (not a regular file)
" ;;
      esac
      rc=1
      continue
    fi
    # Membership without an external command: the expected list is newline
    # delimited, so a full-line match is a substring match on "\nname\n".
    case "
$expected" in
      *"
$base
"*) ;;
      *) unlisted="${unlisted}  ${base}
"; rc=1 ;;
    esac
  done

  if [[ "$rc" != 0 ]]; then
    echo "FAIL — the test suite does not match $manifest_file:" >&2
    [[ -n "$missing" ]]   && { echo "  listed but absent:" >&2;    printf '%s' "$missing" >&2; }
    [[ -n "$unlisted" ]]  && { echo "  present but unlisted:" >&2; printf '%s' "$unlisted" >&2; }
    [[ -n "$irregular" ]] && { echo "  not a regular file:" >&2;   printf '%s' "$irregular" >&2; }
    [[ -n "$invalid" ]]   && { echo "  not a usable entry:" >&2;   printf '%s' "$invalid" >&2; }
    [[ -n "$duplicate" ]] && { echo "  listed more than once:" >&2; printf '%s' "$duplicate" >&2; }
    [[ -n "$aliased" ]]   && { echo "  two names, one file:" >&2;  printf '%s' "$aliased" >&2; }
    echo "  Adding or removing a test is a deliberate act; record it in $manifest_file." >&2
    return 1
  fi

  echo "OK — all $n_expected listed test files are present, regular and distinct"
  return 0
}
