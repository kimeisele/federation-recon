#!/usr/bin/env bash
# manifest-gate.sh — Pin → manifest membership gate.
#
# Source after helpers.sh. Provides:
#   check_pin_manifest_membership <manifest_file> <pins_glob>
#
# Parses the manifest's adopted observed set table and verifies every
# pin file under <pins_glob> (e.g. "pins/*/*.json") corresponds to a
# repository listed there.  The manifest is the single source of truth;
# this file contains no hardcoded repository list.
#
# Exit: 0 if all pins are in the adopted set, 1 if any pin is unlisted
#       or the manifest cannot be parsed.

# Deliberately no `set` here: this file is sourced, and `set` acts on the
# sourcing shell. A library must not change its caller's failure semantics. See #75.

# _manifest_adopted_slugs <manifest_file>
# Prints the list of repository slugs adopted in the manifest, one per line.
# Exposed so downstream libraries (pin-gate.sh) reuse the same parser rather
# than writing a second one — two parsers of the same document will drift,
# which is how the census drifted in the first place.
_manifest_adopted_slugs() {
  local manifest_file="$1"

  # Extract repository slugs from the adopted-observed-set table.
  # Table rows have the shape: | `kimeisele/<slug>` | ... | yes |
  # Parse the first backtick-delimited column, strip the kimeisele/ prefix.
  # grep, not rg: ci-checks.sh is the fast OFFLINE gate and must not acquire
  # new external dependencies. rg is absent from the invariants CI job, where
  # this failed closed with "could not parse any adopted repository" — correct
  # behaviour, wrong dependency. grep is everywhere.
  grep -E '^\| `kimeisele/' "$manifest_file" \
  | sed -n 's/^| `kimeisele\/\([^`]*\)` .*/\1/p' \
  | sort
}

# check_pin_manifest_membership <manifest_file> <pins_glob>
# Returns 0 when every pin slug is listed in the manifest's adopted set.
# On failure prints diagnostic lines to stderr and returns 1.
check_pin_manifest_membership() {
  local manifest_file="$1"
  local pins_glob="$2"

  if [ ! -f "$manifest_file" ]; then
    echo "FAIL — manifest file not found: $manifest_file" >&2
    return 1
  fi

  local allowed_slugs
  allowed_slugs="$(_manifest_adopted_slugs "$manifest_file")"

  if [ -z "$allowed_slugs" ]; then
    echo "FAIL — could not parse any adopted repository from manifest: $manifest_file" >&2
    return 1
  fi

  local offenders=""
  for pin_file in $pins_glob; do
    [ -f "$pin_file" ] || continue
    local slug
    slug="$(basename "$pin_file" .json)"
    if ! printf '%s\n' "$allowed_slugs" | grep -qxF "$slug"; then
      offenders="${offenders}  ${pin_file} → repository '${slug}' not in manifest adopted observed set"$'\n'
    fi
  done

  if [ -n "$offenders" ]; then
    echo "FAIL — pins found for repositories not in the manifest adopted observed set:" >&2
    printf '%s' "$offenders" >&2
    echo "  Manifest source: $manifest_file" >&2
    echo "  Adopted slugs: $(printf '%s\n' "$allowed_slugs" | tr '\n' ' ')" >&2
    return 1
  fi

  echo "OK — all pins correspond to manifest-adopted repositories"
  return 0
}
