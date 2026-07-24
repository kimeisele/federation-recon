#!/usr/bin/env bash
# artifacts.sh — Artifact generator functions for boundary-drift-recon-v0.
#
# Source after helpers.sh. Provides:
#   gen_repository_pin, gen_claim_observation, gen_evidence,
#   gen_drift_record, gen_finding, gen_coverage_record
#
# Each function writes one artifact file and returns its path.

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- Configuration (read from procedure manifest) ----------------------

PROCEDURE_ID="boundary-drift-recon-v0"
PROCEDURE_VERSION="v0"

# Per-procedure pin namespace (set by runner before sourcing).
# v0 writes pins/v0-boundary-drift/<slug>.json
# v1 writes pins/v1-census/<slug>.json
PIN_NAMESPACE="${PIN_NAMESPACE:-}"

# ---- Repository Pin (§8.1) ---------------------------------------------
# gen_repository_pin <repo_slug> <ref> <sha> <timestamp> [dirty]
gen_repository_pin() {
  local repo="$1" ref="$2" sha="$3" ts="$4" dirty="${5:-false}"
  local pin_id; pin_id="$(make_id "pin" "${repo}@${sha}")"
  local json
  json=$(cat <<ENDJSON
{
  "repository": $(json_val "$repo"),
  "requested_ref": $(json_val "$ref"),
  "resolved_commit_sha": $(json_val "$sha"),
  "observation_timestamp": $(json_val "$ts"),
  "acquisition_method": "gh-api",
  "dirty_state_assertion": $dirty
}
ENDJSON
  )
  local slug="${repo#*/}"
  local file
  if [ -n "$PIN_NAMESPACE" ]; then
    file="pins/${PIN_NAMESPACE}/${slug}.json"
  else
    file="pins/${slug}.json"
  fi
  write_json "$file" "$json"
  log "Pin: $repo → $sha ($file)"
  printf '%s' "$file"
}

# ---- Claim Observation (§8.3) ------------------------------------------
# gen_claim_observation <source_repo> <source_path> <claim_text> <repo_pin_id> <timestamp>
gen_claim_observation() {
  local repo="$1" path="$2" text="$3" pin_id="$4" ts="$5"
  # Include full claim text for a collision-free deterministic ID.
  # (A prefix like ${text:0:80} would let two distinct claims sharing an
  #  80-char prefix collide to the same file — silent overwrite, and a
  #  determinism hazard under FR-CON-012.)
  local id_input="${repo}:${path}:${text}"
  local claim_id; claim_id="$(make_id "claim" "$id_input")"
  local json
  json=$(cat <<ENDJSON
{
  "claim_id": $(json_val "$claim_id"),
  "source_repository": $(json_val "$repo"),
  "source_path": $(json_val "$path"),
  "claim_text": $(json_val "$text"),
  "observed_at": $(json_val "$ts"),
  "repository_pin": $(json_val "$pin_id")
}
ENDJSON
  )
  local file="claims/${claim_id}.json"
  write_json "$file" "$json"
  log "Claim: $repo:$path → $file"
  printf '%s' "$file"
}

# ---- Evidence (§8.2) ---------------------------------------------------
# gen_evidence <pin_id> <obs_type> <value> [paths] [hashes]
gen_evidence() {
  local pin_id="$1" obs_type="$2" value="$3" paths="${4:-}" hashes="${5:-}"
  local ev_id; ev_id="$(make_id "ev" "${pin_id}:${obs_type}:$(sha256_of "${value}")")"
  local json_paths="" json_hashes=""

  if [ -n "$paths" ]; then
    json_paths=', "paths": ['
    local first=true IFS=',' p
    IFS=',' read -ra path_arr <<< "$paths"
    for p in "${path_arr[@]}"; do
      $first && json_paths+='"'"$(json_escape "$p")"'"' || json_paths+=', "'"$(json_escape "$p")"'"'
      first=false
    done
    json_paths+=']'
  fi

  if [ -n "$hashes" ]; then
    json_hashes=', "hashes": {'
    local first=true IFS=' ' h
    for h in $hashes; do
      local key="${h%%=*}" val="${h#*=}"
      $first && json_hashes+="$(json_val "$key"): $(json_val "$val")" || json_hashes+=", $(json_val "$key"): $(json_val "$val")"
      first=false
    done
    json_hashes+='}'
  fi

  local json
  json=$(cat <<ENDJSON
{
  "evidence_id": $(json_val "$ev_id"),
  "repository_pin": $(json_val "$pin_id"),
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "observation_type": $(json_val "$obs_type"),
  "value": $(json_val "$value")$json_paths$json_hashes
}
ENDJSON
  )
  local file="evidence/${ev_id}.json"
  write_json "$file" "$json"
  log "Evidence: ${obs_type} → $file"
  printf '%s' "$file"
}

# ---- Drift Record (§8.5) -----------------------------------------------
# gen_drift_record <claim_id> <evidence_id> <difference> [detected_at]
gen_drift_record() {
  local claim_id="$1" ev_id="$2" diff_desc="$3" detected_at="${4:-}"
  [ -z "$detected_at" ] && detected_at="$(utc_timestamp)"
  local drift_id; drift_id="$(make_id "drift" "${claim_id}:${ev_id}")"
  local json
  json=$(cat <<ENDJSON
{
  "drift_id": $(json_val "$drift_id"),
  "claim_observation": $(json_val "$claim_id"),
  "evidence": $(json_val "$ev_id"),
  "difference": $(json_val "$diff_desc"),
  "detected_at": $(json_val "$detected_at")
}
ENDJSON
  )
  local file="drift/${drift_id}.json"
  write_json "$file" "$json"
  log "Drift: $diff_desc → $file"
  printf '%s' "$file"
}

# ---- Finding (§8.4) ----------------------------------------------------
# gen_finding <statement> <evidence_refs> <domain> [severity] [lifecycle_state] [supersedes]
gen_finding() {
  local statement="$1" evidence_refs="$2" domain="$3"
  local severity="${4:-info}" lifecycle="${5:-observed}" supersedes="${6:-}"
  local finding_id; finding_id="$(make_id "finding" "$(sha256_of "${statement}:${domain}")")"
  local created_at; created_at="$(utc_timestamp)"

  # Build evidence_refs JSON array
  local ev_json='['
  local first=true IFS=',' r
  IFS=',' read -ra ev_arr <<< "$evidence_refs"
  for r in "${ev_arr[@]}"; do
    $first && ev_json+="$(json_val "$r")" || ev_json+=", $(json_val "$r")"
    first=false
  done
  ev_json+=']'

  local supersedes_json=""
  [ -n "$supersedes" ] && supersedes_json=", \"supersedes\": $(json_val "$supersedes")"

  local json
  json=$(cat <<ENDJSON
{
  "finding_id": $(json_val "$finding_id"),
  "lifecycle_state": $(json_val "$lifecycle"),
  "statement": $(json_val "$statement"),
  "evidence_refs": $ev_json,
  "domain": $(json_val "$domain"),
  "severity": $(json_val "$severity"),
  "created_at": $(json_val "$created_at")$supersedes_json
}
ENDJSON
  )
  local file="findings/${finding_id}.json"
  write_json "$file" "$json"
  log "Finding: [${lifecycle}] ${statement} → $file"
  printf '%s' "$file"
}

# ---- Coverage Record (§8.6) --------------------------------------------
# gen_coverage_record <pin_id> <result> [capabilities_used] [capabilities_missing]
gen_coverage_record() {
  local pin_id="$1" result="$2" caps_used="${3:-}" caps_missing="${4:-}"
  local cov_id; cov_id="$(make_id "cov" "${pin_id}:${result}")"
  local inspected_at; inspected_at="$(utc_timestamp)"

  local caps_used_json='[]' caps_missing_json='[]'

  if [ -n "$caps_used" ]; then
    caps_used_json='['
    local first=true IFS=',' c
    IFS=',' read -ra cu_arr <<< "$caps_used"
    for c in "${cu_arr[@]}"; do
      $first && caps_used_json+="$(json_val "$c")" || caps_used_json+=", $(json_val "$c")"
      first=false
    done
    caps_used_json+=']'
  fi

  if [ -n "$caps_missing" ]; then
    caps_missing_json='['
    local first=true IFS=',' c
    IFS=',' read -ra cm_arr <<< "$caps_missing"
    for c in "${cm_arr[@]}"; do
      $first && caps_missing_json+="$(json_val "$c")" || caps_missing_json+=", $(json_val "$c")"
      first=false
    done
    caps_missing_json+=']'
  fi

  local json
  json=$(cat <<ENDJSON
{
  "coverage_id": $(json_val "$cov_id"),
  "repository_pin": $(json_val "$pin_id"),
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "capabilities_used": $caps_used_json,
  "capabilities_missing": $caps_missing_json,
  "result": $(json_val "$result"),
  "inspected_at": $(json_val "$inspected_at")
}
ENDJSON
  )
  local file="coverage/${cov_id}.json"
  write_json "$file" "$json"
  log "Coverage: ${result} → $file"
  printf '%s' "$file"
}
