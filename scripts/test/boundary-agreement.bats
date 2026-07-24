#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/boundary-agreement.sh"
}

@test "boundary agreement: role normalization ignores case and underscores" {
  [ "$(normalize_boundary_role 'City_Runtime')" = "city runtime" ]
  [ "$(boundary_agreement_status true 'City Runtime' 'city_runtime' '')" = "agreement" ]
}

@test "boundary agreement: differing explicit roles are drift" {
  [ "$(boundary_agreement_status true 'Autonomous Engine' 'operator' 'steward_surface')" = "role_mismatch" ]
}

@test "boundary agreement: owner boundary without role is a declaration" {
  [ "$(boundary_agreement_status true 'World Governance' '' 'world_governance_surface')" = "agreement" ]
}

@test "boundary agreement: descriptor without either field is absent self-declaration" {
  [ "$(boundary_agreement_status true 'Control Plane + Projection' '' '')" = "absent_self_declaration" ]
}

@test "boundary agreement: missing descriptor is outside Issue 24 scope" {
  [ "$(boundary_agreement_status false 'Control Plane + Projection' '' '')" = "out_of_scope" ]
}
