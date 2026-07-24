#!/usr/bin/env bash
# Deterministic helpers for comparing central role claims with node descriptors.

normalize_boundary_role() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr '_' ' ' \
    | sed 's/  */ /g; s/^ *//; s/ *$//'
}

# boundary_agreement_status <descriptor_present> <central_role> <self_role> <owner_boundary>
#
# Outputs one stable status token:
#   out_of_scope              descriptor is absent, so Issue #24 excludes the node
#   agreement                 exact normalized role match, or a boundary declaration exists
#   role_mismatch             both sides declare roles and they differ
#   absent_self_declaration   descriptor exists but declares neither field
boundary_agreement_status() {
  local descriptor_present="$1" central_role="$2" self_role="$3" owner_boundary="$4"

  if [ "$descriptor_present" != "true" ]; then
    printf 'out_of_scope'
    return
  fi

  if [ -n "$self_role" ]; then
    if [ "$(normalize_boundary_role "$central_role")" = "$(normalize_boundary_role "$self_role")" ]; then
      printf 'agreement'
    else
      printf 'role_mismatch'
    fi
    return
  fi

  if [ -n "$owner_boundary" ]; then
    printf 'agreement'
  else
    printf 'absent_self_declaration'
  fi
}
