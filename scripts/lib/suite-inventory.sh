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
# A previous implementation of this check was reverted from PR #73 after an
# independent review found four ways past it, all executed. Each shaped the code
# below, so they are recorded rather than summarised:
#
#   1. It used `comm`, and ignored its exit status. With `comm` unavailable the
#      check printed "OK — all 14 listed test files are present" and the
#      required CI job reported PASS. A fail-open in the one place that must not
#      have one.
#   2. It enumerated with `ls | xargs basename`, which splits at whitespace. One
#      file named `a b.bats` satisfied a manifest listing `a` and `b.bats`.
#   3. It compared names while the runner followed symlinks. Replacing
#      budget.bats with a link to heartbeat.bats left the inventory green, the
#      gate green, heartbeat.bats run twice and budget.bats never run.
#   4. A broken symlink passed unnoticed.
#
# Hence: no external command participates in the comparison. Enumeration is a
# glob, membership is a shell `case`, and every entry must be a regular file.
# There is no helper here whose absence or failure could be mistaken for
# agreement, because there is no helper.
# ---------------------------------------------------------------------------

check_suite_inventory() {
  local manifest_file="$1" testdir="${2:-scripts/test}"
  local line name base f expected="" rc=0 n_expected=0
  local missing="" unlisted="" irregular=""

  if [ ! -f "$manifest_file" ]; then
    echo "FAIL — suite manifest not found: $manifest_file" >&2
    return 1
  fi
  if [ ! -d "$testdir" ]; then
    echo "FAIL — test directory not found: $testdir" >&2
    return 1
  fi

  # Read the manifest. Comments and surrounding whitespace are stripped, which
  # also removes a trailing CR from a file that travelled through Windows.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    expected="${expected}${line}
"
    n_expected=$(( n_expected + 1 ))
  done < "$manifest_file"

  if [ "$n_expected" = 0 ]; then
    echo "FAIL — suite manifest lists no test files: $manifest_file" >&2
    return 1
  fi

  # Every listed file must be present, and present as a regular file. A symlink
  # that resolves is still wrong: it makes one test run twice and another not at
  # all while every name and count still looks right.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    f="$testdir/$name"
    if [ -L "$f" ]; then
      irregular="${irregular}  ${name} (symlink)
"
      rc=1
    elif [ ! -f "$f" ]; then
      missing="${missing}  ${name}
"
      rc=1
    fi
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
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="${f##*/}"
    if [ -L "$f" ] || [ ! -f "$f" ]; then
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
      *)
        unlisted="${unlisted}  ${base}
"
        rc=1 ;;
    esac
  done

  if [ "$rc" != 0 ]; then
    echo "FAIL — the test suite does not match $manifest_file:" >&2
    [ -n "$missing" ]   && { echo "  listed but absent:" >&2;      printf '%s' "$missing" >&2; }
    [ -n "$unlisted" ]  && { echo "  present but unlisted:" >&2;   printf '%s' "$unlisted" >&2; }
    [ -n "$irregular" ] && { echo "  not a regular file:" >&2;     printf '%s' "$irregular" >&2; }
    echo "  Adding or removing a test is a deliberate act; record it in $manifest_file." >&2
    return 1
  fi

  echo "OK — all $n_expected listed test files are present and regular"
  return 0
}
