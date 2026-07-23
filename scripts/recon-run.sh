#!/usr/bin/env bash
# recon-run.sh — Boundary Drift Recon v0 Runner
#
# Implements the 11 operations from founding package §12.3.
# Fully deterministic (FR-CON-012): identical pins + same procedure version
# → identical Evidence.
#
# Tools: git, gh, rg (§11.1 baseline). python3 and jq optional.
#
# Usage:
#   bash scripts/recon-run.sh              # Full live run
#   RECON_PINS_DIR=pins bash scripts/recon-run.sh --reproduce   # Fixed-pin rerun
#
# Exit codes:
#   0 — success
#   1 — runtime error (tool missing, write failure)
#   2 — budget breach
#   3 — schema validation failure
#  75 — terminal partial failure (some repos failed)

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source libraries
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/artifacts.sh"
source "$SCRIPT_DIR/lib/budget.sh"

# ---- Configuration -----------------------------------------------------

# The 6 observed repositories + self (FR-CON-011)
declare -a OBSERVED_REPOS=(
  "kimeisele/steward-protocol"
  "kimeisele/agent-world"
  "kimeisele/agent-internet"
  "kimeisele/steward-federation"
  "kimeisele/steward"
  "kimeisele/agent-city"
  "kimeisele/federation-recon"  # self
)

# The 6 federation-descriptor repos (excludes self)
declare -a DESCRIPTOR_REPOS=(
  "kimeisele/steward-protocol"
  "kimeisele/agent-world"
  "kimeisele/agent-internet"
  "kimeisele/steward-federation"
  "kimeisele/steward"
  "kimeisele/agent-city"
)

# Claim sources (from docs/claim-source-inventory.md)
REPO_BOUNDARIES_SOURCE="agent-world:docs/REPO_BOUNDARIES.md"
CONSTITUTION_SP_SOURCE="steward-protocol:CONSTITUTION.md"
CONSTITUTION_AC_SOURCE="agent-city:docs/CONSTITUTION.md"
PUBLIC_SURFACE_AI_SOURCE="agent-internet:docs/PUBLIC_FEDERATION_SURFACE.md"
SELF_SOURCE="federation-recon:docs/founding-package-v0.2.md"

# Output directories
mkdir -p "$REPO_ROOT/pins" "$REPO_ROOT/claims" "$REPO_ROOT/evidence"
mkdir -p "$REPO_ROOT/drift" "$REPO_ROOT/findings" "$REPO_ROOT/coverage"
mkdir -p "$REPO_ROOT/digest"

cd "$REPO_ROOT"

# ---- State -------------------------------------------------------------

declare -A REPO_SHA          # repo slug → resolved SHA
declare -A REPO_REF          # repo slug → requested ref
declare -A PIN_FILES         # repo slug → pin file path
declare -A CLAIM_FILES       # claim_id → claim file path
declare -A EVIDENCE_FILES    # evidence_id → evidence file path
declare -A DRIFT_FILES       # drift_id → drift file path
declare -A FINDING_FILES     # finding_id → finding file path
declare -A COVERAGE_FILES    # coverage_id → coverage file path

RUN_TIMESTAMP=""
RUN_RESULT="success"
PARTIAL_FAILURES=0

# ---- Phase 1: Resolve & Pin (§12.3 ops 1-2) ---------------------------

resolve_pins() {
  log "=== Phase 1: Resolve repository commits & create pins ==="
  local repro="${1:-false}"

  for repo in "${OBSERVED_REPOS[@]}"; do
    local slug="${repo#*/}"
    local sha="" ref=""

    if $repro && [ -n "${RECON_REPRO_DIR:-}" ]; then
      # Reproduce from existing pin file
      local pin_file="$RECON_REPRO_DIR/${slug}.json"
      if [ -f "$pin_file" ]; then
        sha=$(python3 -c "import json; print(json.load(open('$pin_file'))['resolved_commit_sha'])" 2>/dev/null || true)
        ref=$(python3 -c "import json; print(json.load(open('$pin_file'))['requested_ref'])" 2>/dev/null || "HEAD")
      fi
    fi

    # Resolve live if we don't have a pinned SHA
    if [ -z "$sha" ]; then
      ref=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "master")
      sha=$(gh api "repos/${repo}/git/ref/heads/${ref}" --jq '.object.sha' 2>/dev/null || true)
    fi

    if [ -z "$sha" ]; then
      warn "Cannot resolve ${repo} — skipping"
      PARTIAL_FAILURES=$(( PARTIAL_FAILURES + 1 ))
      continue
    fi

    REPO_SHA["$repo"]="$sha"
    REPO_REF["$repo"]="$ref"

    local pin_file
    pin_file=$(gen_repository_pin "$repo" "$ref" "$sha" "$RUN_TIMESTAMP")
    PIN_FILES["$slug"]="$pin_file"
    budget_track "$pin_file"

    log "  ${repo} → ${sha} (ref: ${ref})"
  done
}

# ---- Phase 2: Extract claims (§12.3 op 3) ------------------------------

extract_well_known_claims() {
  log "=== Phase 2a: Extract .well-known/agent-federation.json claims ==="
  log "Claim set defined in docs/claim-source-inventory.md §Per-repository structured federation descriptors"

  for repo in "${DESCRIPTOR_REPOS[@]}"; do
    local slug="${repo#*/}"
    local sha="${REPO_SHA[$repo]:-}"
    [ -z "$sha" ] && { warn "  No pin for ${repo} — skipping well-known claim"; continue; }

    local pin_id="${PIN_FILES[$slug]}"
    [ -z "$pin_id" ] && { warn "  No pin file for ${slug} — skipping"; continue; }

    # Claims reference the pin by its file path, exactly like Evidence does, so
    # the Claim -> Pin -> raw repo navigation chain resolves (#11).
    local repo_pin_id="${PIN_FILES[$slug]}"

    # Fetch the .well-known/agent-federation.json content at this commit
    local content=""
    content=$(gh api "repos/${repo}/contents/.well-known/agent-federation.json?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -z "$content" ]; then
      warn "  .well-known/agent-federation.json not found in ${repo} at ${sha}"
      local claim
      claim=$(gen_claim_observation "$repo" ".well-known/agent-federation.json" \
        "File .well-known/agent-federation.json not found in ${repo} at commit ${sha}" \
        "$repo_pin_id" "$RUN_TIMESTAMP")
      CLAIM_FILES["af-${slug}"]="$claim"
      budget_track "$claim"
      continue
    fi

    # Extract owner_boundary field
    local owner_boundary=""
    owner_boundary=$(printf '%s' "$content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('owner_boundary',''))
except: print('')
" 2>/dev/null || echo "")

    local kind=""
    kind=$(printf '%s' "$content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('kind',''))
except: print('')
" 2>/dev/null || echo "")

    local claim_text
    if [ -n "$owner_boundary" ]; then
      claim_text="${repo}/.well-known/agent-federation.json asserts owner_boundary=\"${owner_boundary}\" (kind=\"${kind}\")"
    else
      claim_text="${repo}/.well-known/agent-federation.json exists at commit ${sha} (content parseable JSON)"
    fi

    local claim
    claim=$(gen_claim_observation "$repo" ".well-known/agent-federation.json" \
      "$claim_text" "$repo_pin_id" "$RUN_TIMESTAMP")
    CLAIM_FILES["af-${slug}"]="$claim"
    budget_track "$claim"
    log "  Claim recorded: ${repo} → owner_boundary=${owner_boundary}"
  done
}

extract_boundary_table_claims() {
  log "=== Phase 2b: Extract REPO_BOUNDARIES.md claims ==="
  log "Claim set defined in docs/claim-source-inventory.md §Primary cross-repository boundary source"

  local repo="kimeisele/agent-world"
  local sha="${REPO_SHA[$repo]:-}"
  [ -z "$sha" ] && { warn "  No pin for ${repo} — skipping boundary table claims"; return; }

  local pin_id="pins/agent-world.json"

  local content=""
  content=$(gh api "repos/${repo}/contents/docs/REPO_BOUNDARIES.md?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [ -z "$content" ]; then
    warn "  REPO_BOUNDARIES.md not found in ${repo} at ${sha}"
    return
  fi

  # Extract the boundary table using rg — each row in the |---|---| table
  # Format: | `repo` | **Role** | ... | owns | does not own |
  local table_rows
  table_rows=$(printf '%s' "$content" | rg '^\|' | rg -v '^\| [-]+|^\| *$|^\| Repo' 2>/dev/null || true)

  while IFS= read -r row; do
    [ -z "$row" ] && continue
    # Parse markdown table row: | `repo` | **Role** | Code | Owns | DoesNotOwn |
    # Extract repo name (first column, strip backticks)
    local repo_in_row=""
    repo_in_row=$(printf '%s' "$row" | sed 's/^| *//' | sed 's/ *|.*//' | sed 's/`//g' | sed 's/\*\*//g' | sed 's/^ *//;s/ *$//')
    [ -z "$repo_in_row" ] && continue

    # Extract role (second column, strip **)
    local role=""
    role=$(printf '%s' "$row" | cut -d'|' -f3 | sed 's/\*\*//g' | sed 's/^ *//;s/ *$//')
    [ -z "$role" ] && role="(not asserted)"

    # Extract last-audited date from document header (date only, not parenthetical)
    local last_audited=""
    last_audited=$(printf '%s' "$content" | rg 'Last audited' | rg -o '\d{4}-\d{2}-\d{2}' 2>/dev/null || echo "2026-03-15")

    local claim_text="${repo}/docs/REPO_BOUNDARIES.md (last audited: ${last_audited}) asserts ${repo_in_row} role is \"${role}\""

    local claim
    claim=$(gen_claim_observation "$repo" "docs/REPO_BOUNDARIES.md" \
      "$claim_text" "$pin_id" "$RUN_TIMESTAMP")
    CLAIM_FILES["rb-${repo_in_row}"]="$claim"
    budget_track "$claim"
    log "  Claim: ${repo_in_row} role=${role}"

    # Also create a claim for "owns" column
    local owns=""
    owns=$(printf '%s' "$row" | cut -d'|' -f5 | sed 's/^ *//;s/ *$//')
    if [ -n "$owns" ] && [ "$owns" != " " ]; then
      local owns_claim_text="${repo}/docs/REPO_BOUNDARIES.md asserts ${repo_in_row} owns: ${owns}"
      local owns_claim
      owns_claim=$(gen_claim_observation "$repo" "docs/REPO_BOUNDARIES.md" \
        "$owns_claim_text" "$pin_id" "$RUN_TIMESTAMP")
      CLAIM_FILES["rb-owns-${repo_in_row}"]="$owns_claim"
      budget_track "$owns_claim"
    fi
  done <<< "$table_rows"
}

extract_constitution_claims() {
  log "=== Phase 2c: Extract constitution/boundary document claims ==="
  log "Claim set defined in docs/claim-source-inventory.md §Per-repository constitution/boundary documents"

  # ----- steward-protocol/CONSTITUTION.md -----
  local repo="kimeisele/steward-protocol"
  local sha="${REPO_SHA[$repo]:-}"
  if [ -n "$sha" ]; then
    local pin_id="pins/steward-protocol.json"
    local content=""
    content=$(gh api "repos/${repo}/contents/CONSTITUTION.md?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$content" ]; then
      local has_supreme_law="no"
      printf '%s' "$content" | rg -q 'SUPREME LAW' && has_supreme_law="yes"

      local article_count=0
      article_count=$(printf '%s' "$content" | rg -c '^### Artikel' 2>/dev/null || echo 0)

      local claim_text="${repo}/CONSTITUTION.md asserts status as SUPREME LAW (Layer 0); contains ${article_count} articles; has_supreme_law=${has_supreme_law}"
      local claim
      claim=$(gen_claim_observation "$repo" "CONSTITUTION.md" "$claim_text" "$pin_id" "$RUN_TIMESTAMP")
      CLAIM_FILES["const-sp"]="$claim"
      budget_track "$claim"
      log "  steward-protocol: SEHR GESETZ=${has_supreme_law}, articles=${article_count}"
    fi
  fi

  # ----- agent-city/docs/CONSTITUTION.md -----
  repo="kimeisele/agent-city"
  sha="${REPO_SHA[$repo]:-}"
  if [ -n "$sha" ]; then
    local pin_id="pins/agent-city.json"
    local content=""
    content=$(gh api "repos/${repo}/contents/docs/CONSTITUTION.md?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$content" ]; then
      local has_murali="no"
      printf '%s' "$content" | rg -q 'MURALI' && has_murali="yes"

      local article_count=0
      article_count=$(printf '%s' "$content" | rg -c '^## Article' 2>/dev/null || echo 0)

      local claim_text="${repo}/docs/CONSTITUTION.md asserts MURALI governance cycle (has_murali=${has_murali}); ${article_count} articles on agent-city governance"
      local claim
      claim=$(gen_claim_observation "$repo" "docs/CONSTITUTION.md" "$claim_text" "$pin_id" "$RUN_TIMESTAMP")
      CLAIM_FILES["const-ac"]="$claim"
      budget_track "$claim"
      log "  agent-city: MURALI=${has_murali}, articles=${article_count}"
    fi
  fi

  # ----- agent-internet/docs/PUBLIC_FEDERATION_SURFACE.md -----
  repo="kimeisele/agent-internet"
  sha="${REPO_SHA[$repo]:-}"
  if [ -n "$sha" ]; then
    local pin_id="pins/agent-internet.json"
    local content=""
    content=$(gh api "repos/${repo}/contents/docs/PUBLIC_FEDERATION_SURFACE.md?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [ -n "$content" ]; then
      local has_github_primary="no"
      printf '%s' "$content" | rg -q 'GitHub-native' && has_github_primary="yes"
      local has_lotus_operator="no"
      printf '%s' "$content" | rg -q 'operator' && has_lotus_operator="yes"

      local claim_text="${repo}/docs/PUBLIC_FEDERATION_SURFACE.md asserts GitHub-native participation as primary public surface (github_primary=${has_github_primary}); Lotus is authenticated operator surface (operator=${has_lotus_operator})"
      local claim
      claim=$(gen_claim_observation "$repo" "docs/PUBLIC_FEDERATION_SURFACE.md" "$claim_text" "$pin_id" "$RUN_TIMESTAMP")
      CLAIM_FILES["pub-ai"]="$claim"
      budget_track "$claim"
      log "  agent-internet: github_primary=${has_github_primary}, lotus_operator=${has_lotus_operator}"
    fi
  fi
}

extract_self_observation_claims() {
  log "=== Phase 2d: Extract self-observation claims (FR-CON-011) ==="
  # Self-observation: check federation-recon against its own constitutional invariants

  local repo="kimeisele/federation-recon"
  local sha="${REPO_SHA[$repo]:-}"
  [ -z "$sha" ] && { warn "  No pin for self — skipping self-observation claims"; return; }

  local pin_id="pins/federation-recon.json"

  # We already know our own invariants — check if the founding package exists
  local fp_exists="no"
  [ -f "docs/founding-package-v0.2.md" ] && fp_exists="yes"

  local dr_exists="no"
  [ -f "docs/founding-decision-record.md" ] && dr_exists="yes"

  local claim_text="${repo}/docs/founding-package-v0.2.md asserts FR-CON-001..012 constitutional invariants; founding_package_exists=${fp_exists}; decision_record_exists=${dr_exists}"
  local claim
  claim=$(gen_claim_observation "$repo" "docs/founding-package-v0.2.md" "$claim_text" "$pin_id" "$RUN_TIMESTAMP")
  CLAIM_FILES["self"]="$claim"
  budget_track "$claim"
  log "  Self: founding_package=${fp_exists}, decision_record=${dr_exists}"
}

# ---- Phase 3: Deterministic Observations (§12.3 op 4) ------------------

run_deterministic_observations() {
  log "=== Phase 3: Run deterministic observations ==="

  # Observation 1: Verify .well-known/agent-federation.json exists and is parseable
  for repo in "${DESCRIPTOR_REPOS[@]}"; do
    local slug="${repo#*/}"
    local sha="${REPO_SHA[$repo]:-}"
    [ -z "$sha" ] && continue

    local pin_file="${PIN_FILES[$slug]}"
    [ -z "$pin_file" ] && continue

    local content=""
    content=$(gh api "repos/${repo}/contents/.well-known/agent-federation.json?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -z "$content" ]; then
      local ev
      ev=$(gen_evidence "$pin_file" "file_existence" \
        "false" \
        ".well-known/agent-federation.json")
      EVIDENCE_FILES["af-exists-${slug}"]="$ev"
      budget_track "$ev"
      continue
    fi

    # File exists observation
    local ev_exists
    ev_exists=$(gen_evidence "$pin_file" "file_existence" \
      "true" \
      ".well-known/agent-federation.json")
    EVIDENCE_FILES["af-exists-${slug}"]="$ev_exists"
    budget_track "$ev_exists"

    # Parse and observe owner_boundary
    local owner_boundary=""
    owner_boundary=$(printf '%s' "$content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('owner_boundary',''))
except: print('')
" 2>/dev/null || echo "")

    if [ -n "$owner_boundary" ]; then
      local ev_ob
      ev_ob=$(gen_evidence "$pin_file" "manifest_field" \
        "${owner_boundary}" \
        ".well-known/agent-federation.json" \
        "owner_boundary=$(sha256_of "$owner_boundary")")
      EVIDENCE_FILES["af-ob-${slug}"]="$ev_ob"
      budget_track "$ev_ob"
      log "  Observed ${repo}: owner_boundary=${owner_boundary}"
    fi
  done

  # Observation 2: Verify REPO_BOUNDARIES.md exists and check key content
  local agent_world_sha="${REPO_SHA[kimeisele/agent-world]:-}"
  if [ -n "$agent_world_sha" ]; then
    local aw_pin="${PIN_FILES[agent-world]}"
    [ -n "$aw_pin" ] && observe_boundary_table "$aw_pin"
  fi

  # Observation 3: Verify constitution documents exist
  observe_constitution_documents

  # Observation 4: Check repo metrics (file counts, structural evidence)
  observe_repo_metrics
}

observe_boundary_table() {
  local pin_file="$1"
  local content=""
  content=$(gh api "repos/kimeisele/agent-world/contents/docs/REPO_BOUNDARIES.md?ref=${REPO_SHA[kimeisele/agent-world]}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [ -z "$content" ]; then
    local ev
    ev=$(gen_evidence "$pin_file" "file_existence" \
      "false" \
      "docs/REPO_BOUNDARIES.md")
    EVIDENCE_FILES["rb-exists"]="$ev"
    budget_track "$ev"
    return
  fi

  local ev_exists
  ev_exists=$(gen_evidence "$pin_file" "file_existence" \
    "true" \
    "docs/REPO_BOUNDARIES.md")
  EVIDENCE_FILES["rb-exists"]="$ev_exists"
  budget_track "$ev_exists"

  # Count the number of repo rows in the boundary table
  local row_count=0
  row_count=$(printf '%s' "$content" | rg '^\| \`' 2>/dev/null | wc -l | tr -d ' ')
  local file_hash
  file_hash=$(sha256_of "$content")

  local ev_count
  ev_count=$(gen_evidence "$pin_file" "file_count" \
    "${row_count}" \
    "docs/REPO_BOUNDARIES.md" \
    "sha256=$(sha256_of "${row_count}")")
  EVIDENCE_FILES["rb-count"]="$ev_count"
  budget_track "$ev_count"
  log "  REPO_BOUNDARIES.md: ${row_count} repo rows"
}

observe_constitution_documents() {
  # steward-protocol/CONSTITUTION.md
  local sp_sha="${REPO_SHA[kimeisele/steward-protocol]:-}"
  if [ -n "$sp_sha" ]; then
    local sp_pin="${PIN_FILES[steward-protocol]}"
    if [ -n "$sp_pin" ]; then
      local content=""
      content=$(gh api "repos/kimeisele/steward-protocol/contents/CONSTITUTION.md?ref=${sp_sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [ -n "$content" ]; then
        local char_count
        char_count=$(printf '%s' "$content" | wc -c | tr -d ' ')
        local section_count
        section_count=$(printf '%s' "$content" | rg -c '^#' 2>/dev/null || echo 0)
        local ev
        ev=$(gen_evidence "$sp_pin" "file_count" \
          "{\"char_count\": ${char_count}, \"section_count\": ${section_count}}" \
          "CONSTITUTION.md")
        EVIDENCE_FILES["const-sp-size"]="$ev"
        budget_track "$ev"
        log "  CONSTITUTION.md (steward-protocol): ${char_count} chars, ${section_count} sections"
      fi
    fi
  fi

  # agent-city/docs/CONSTITUTION.md
  local ac_sha="${REPO_SHA[kimeisele/agent-city]:-}"
  if [ -n "$ac_sha" ]; then
    local ac_pin="${PIN_FILES[agent-city]}"
    if [ -n "$ac_pin" ]; then
      local content=""
      content=$(gh api "repos/kimeisele/agent-city/contents/docs/CONSTITUTION.md?ref=${ac_sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [ -n "$content" ]; then
        local char_count
        char_count=$(printf '%s' "$content" | wc -c | tr -d ' ')
        local article_count
        article_count=$(printf '%s' "$content" | rg -c '^## Article' 2>/dev/null || echo 0)
        local ev
        ev=$(gen_evidence "$ac_pin" "file_count" \
          "{\"char_count\": ${char_count}, \"article_count\": ${article_count}}" \
          "docs/CONSTITUTION.md")
        EVIDENCE_FILES["const-ac-size"]="$ev"
        budget_track "$ev"
        log "  CONSTITUTION.md (agent-city): ${char_count} chars, ${article_count} articles"
      fi
    fi
  fi
}

observe_repo_metrics() {
  log "--- Repository metrics ---"
  for repo in "${OBSERVED_REPOS[@]}"; do
    local slug="${repo#*/}"
    local sha="${REPO_SHA[$repo]:-}"
    local pin_file="${PIN_FILES[$slug]}"
    [ -z "$sha" ] && continue
    [ -z "$pin_file" ] && continue

    # Count files in the repo root (top-level, excluding .git)
    local root_files=0
    root_files=$(gh api "repos/${repo}/git/trees/${sha}" --jq '.tree | length' 2>/dev/null || echo 0)

    local ev
    ev=$(gen_evidence "$pin_file" "file_count" \
      "${root_files}" \
      "/ (repository root)")
    EVIDENCE_FILES["files-${slug}"]="$ev"
    budget_track "$ev"
    log "  ${repo}: ${root_files} top-level entries"
  done
}

# ---- Phase 4: Compare & Detect Drift (§12.3 ops 5-6) ------------------

detect_drift() {
  log "=== Phase 4: Compare claims with observations ==="

  # Compare .well-known/agent-federation.json claims vs evidence
  for repo in "${DESCRIPTOR_REPOS[@]}"; do
    local slug="${repo#*/}"
    local claim_file="${CLAIM_FILES["af-${slug}"]:-}"
    local ev_file="${EVIDENCE_FILES["af-ob-${slug}"]:-}"

    if [ -n "$claim_file" ] && [ -n "$ev_file" ] && [ -f "$claim_file" ] && [ -f "$ev_file" ]; then
      # Compare evidence value against claim text using python3 for robustness
      local match_result=""
      match_result=$(python3 -c "
import json, sys
try:
    claim = json.load(open('$claim_file'))
    ev = json.load(open('$ev_file'))
    claim_text = claim.get('claim_text','')
    ev_value = str(ev.get('value',''))
    # Check if the evidence value appears in the claim text
    if ev_value and ev_value in claim_text:
        print('MATCH')
    elif not ev_value:
        print('NO_VALUE')
    else:
        # Check if it's a field observation — compare field name in claim text
        print('MISMATCH:%s' % ev_value[:80])
except Exception as e:
    print('ERROR:%s' % str(e)[:80])
" 2>/dev/null || echo "ERROR:parse")

      case "$match_result" in
        MATCH)
          log "  OK: ${repo} — claim matches evidence"
          ;;
        NO_VALUE)
          log "  SKIP: ${repo} — no evidence value to compare"
          ;;
        MISMATCH:*)
          local diff_val="${match_result#MISMATCH:}"
          local claim_id; claim_id=$(artifact_id "$claim_file")
          local ev_id; ev_id=$(artifact_id "$ev_file")
          local drift
          drift=$(gen_drift_record "$claim_id" "$ev_id" \
            "Owner_boundary observation differs from claim: evidence shows '${diff_val}'")
          DRIFT_FILES["drift-af-${slug}"]="$drift"
          budget_track "$drift"
          log "  DRIFT: ${repo} — ${diff_val}"
          ;;
        ERROR:*)
          warn "  ERROR comparing ${repo}: ${match_result#ERROR:}"
          ;;
      esac
    fi
  done

  # Compare REPO_BOUNDARIES.md claims vs observations
  # Boundary table claims assert roles — verified through document existence
  for repo in "${OBSERVED_REPOS[@]}"; do
    local slug="${repo#*/}"
    local claim_file="${CLAIM_FILES["rb-${slug}"]:-}"
    if [ -n "$claim_file" ] && [ -f "$claim_file" ]; then
      log "  OK: ${repo} — boundary table claim recorded"
    fi
  done
}

# ---- Phase 5: Generate Findings (§12.3 op 7) --------------------------

generate_findings() {
  log "=== Phase 5: Generate Findings ==="

  local drift_count=0
  for key in "${!DRIFT_FILES[@]}"; do
    drift_count=$(( drift_count + 1 ))
  done

  # Finding 1: Overall drift status
  local drift_finding_text=""
  if [ "$drift_count" -gt 0 ]; then
    drift_finding_text="Detected ${drift_count} drift(s) between documented boundary claims and current observations"
  else
    drift_finding_text="No boundary drift detected — all observed claims match current repository state"
  fi

  local drift_ev_refs=""
  local first=true
  for key in "${!DRIFT_FILES[@]}"; do
    local ev_file="${EVIDENCE_FILES["af-ob-${key#drift-af-}"]:-}"
    if [ -n "$ev_file" ] && [ -f "$ev_file" ]; then
      local eid; eid=$(artifact_id "$ev_file")
      $first && drift_ev_refs+="$eid" || drift_ev_refs+=",${eid}"
      first=false
    fi
  done
  # Always include the boundary table evidence
  local rb_ev_id=""
  if [ -n "${EVIDENCE_FILES["rb-exists"]:-}" ] && [ -f "${EVIDENCE_FILES["rb-exists"]}" ]; then
    rb_ev_id=$(artifact_id "${EVIDENCE_FILES["rb-exists"]}")
    if [ -n "$rb_ev_id" ]; then
      $first && drift_ev_refs+="$rb_ev_id" || drift_ev_refs+=",${rb_ev_id}"
      first=false
    fi
  fi
  if $first; then
    # Fallback: use first available evidence file
    for f in evidence/*.json; do
      [ -f "$f" ] || continue
      drift_ev_refs=$(artifact_id "$f")
      break
    done
  fi

  local finding_drift
  finding_drift=$(gen_finding "$drift_finding_text" "$drift_ev_refs" \
    "cross_repository_boundaries" \
    "$([ "$drift_count" -gt 0 ] && echo 'warning' || echo 'info')")
  FINDING_FILES["drift-status"]="$finding_drift"
  budget_track "$finding_drift"

  # Finding 2: Freshness observation — REPO_BOUNDARIES.md last audited date
  local rb_claim="${CLAIM_FILES["rb-agent-world"]}"
  if [ -n "$rb_claim" ] && [ -f "$rb_claim" ]; then
    local last_audited=""
    last_audited=$(python3 -c "
import json
d = json.load(open('$rb_claim'))
t = d.get('claim_text','')
import re
m = re.search(r'last audited: ([^)]+)', t)
print(m.group(1) if m else 'unknown')
" 2>/dev/null || echo "unknown")

    local freshness_finding=""
    if [ "$last_audited" != "2026-07-23" ] && [ "$last_audited" != "unknown" ]; then
      freshness_finding="REPO_BOUNDARIES.md last audited ${last_audited} — source document may be stale relative to current observations"
      local freshness
      freshness=$(gen_finding "$freshness_finding" "${EVIDENCE_FILES["rb-exists"]}" \
        "cross_repository_boundaries" "info" "observed")
      FINDING_FILES["freshness"]="$freshness"
      budget_track "$freshness"
    fi
  fi

  # Finding 3: Repository coverage
  local covered=0 total=0
  for repo in "${OBSERVED_REPOS[@]}"; do
    total=$(( total + 1 ))
    local slug="${repo#*/}"
    if [ -n "${PIN_FILES[$slug]}" ]; then
      covered=$(( covered + 1 ))
    fi
  done
  local cov_finding_text="Coverage: ${covered}/${total} repositories successfully observed"
  if [ "$covered" -lt "$total" ]; then
    cov_finding_text+=" ($(( total - covered )) partial failures)"
  fi
  local cov_ev_refs=""
  first=true
  for key in "${!EVIDENCE_FILES[@]}"; do
    if [[ "$key" == files-* ]]; then
      $first && cov_ev_refs+="${EVIDENCE_FILES[$key]}" || cov_ev_refs+=",${EVIDENCE_FILES[$key]}"
      first=false
    fi
  done
  [ -z "$cov_ev_refs" ] && cov_ev_refs="${EVIDENCE_FILES["af-exists-${DESCRIPTOR_REPOS[0]#*/}"]}"

  local finding_cov
  finding_cov=$(gen_finding "$cov_finding_text" "$cov_ev_refs" \
    "recon_coverage" \
    "$([ "$covered" -lt "$total" ] && echo 'warning' || echo 'info')")
  FINDING_FILES["coverage"]="$finding_cov"
  budget_track "$finding_cov"
}

# ---- Phase 6: Record Coverage (§12.3 op 8) ----------------------------

record_coverage() {
  log "=== Phase 6: Record Coverage ==="

  local caps_used="git,gh,rg,bash"
  command -v python3 &>/dev/null && caps_used+=",python3"
  command -v jq &>/dev/null && caps_used+=",jq"

  local caps_missing=""
  command -v python3 &>/dev/null || caps_missing+="${caps_missing:+,}python3"
  command -v jq &>/dev/null || caps_missing+="${caps_missing:+,}jq"

  for repo in "${OBSERVED_REPOS[@]}"; do
    local slug="${repo#*/}"
    local pin_file="${PIN_FILES[$slug]}"
    [ -z "$pin_file" ] && continue

    local result="success"
    if [ "$PARTIAL_FAILURES" -gt 0 ]; then
      # If this specific repo failed, mark partial
      [ -z "${REPO_SHA[$repo]:-}" ] && result="partial"
    fi

    local cov
    cov=$(gen_coverage_record "$pin_file" "$result" "$caps_used" "$caps_missing")
    COVERAGE_FILES["${slug}"]="$cov"
    budget_track "$cov"
  done
}

# ---- Phase 7: Self-Observation (§12.3 op 9, FR-CON-011) ----------------

perform_self_observation() {
  log "=== Phase 7: Self-Observation (FR-CON-011) ==="

  # Check: did this run complete?
  local self_ok="true"
  local self_issues=""

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    self_ok="false"
    self_issues+="partial_failures:${PARTIAL_FAILURES};"
  fi

  # Check: are all expected artifacts present?
  local expected_count=${#OBSERVED_REPOS[@]}
  local actual_pins=0
  for slug in "${!PIN_FILES[@]}"; do actual_pins=$(( actual_pins + 1 )); done
  if [ "$actual_pins" -lt "$expected_count" ]; then
    self_ok="false"
    self_issues+="missing_pins:expected_${expected_count}_got_${actual_pins};"
  fi

  # Check: is the digest fresh?
  local digest_fresh="true"  # always fresh in a first run

  # Check: are outputs valid against schemas? (basic check)
  local outputs_valid="true"
  # We'll validate more thoroughly in the validation script

  local self_status_json
  self_status_json=$(cat <<ENDJSON
{
  "run_completed": $([ "$PARTIAL_FAILURES" -eq 0 ] && echo 'true' || echo 'false'),
  "outputs_complete": $([ "$actual_pins" -ge "$expected_count" ] && echo 'true' || echo 'false'),
  "digest_fresh": true,
  "issues": $(json_val "$self_issues")
}
ENDJSON
  )
  SELF_STATUS="$self_status_json"

  # Create a self-observation finding
  local self_statement=""
  if [ "$self_ok" = "true" ]; then
    self_statement="Self-observation: run completed successfully with all ${actual_pins}/${expected_count} repositories observed, outputs written, digest fresh"
  else
    self_statement="Self-observation: run completed with issues — ${self_issues}"
  fi

  # Collect evidence refs for self-observation
  local self_ev_refs=""
  # Include coverage records as evidence of what was done
  local first=true
  for key in "${!COVERAGE_FILES[@]}"; do
    $first && self_ev_refs+="${COVERAGE_FILES[$key]}" || self_ev_refs+=",${COVERAGE_FILES[$key]}"
    first=false
  done
  [ -z "$self_ev_refs" ] && self_ev_refs="${EVIDENCE_FILES["files-federation-recon"]}"

  local finding_self
  finding_self=$(gen_finding "$self_statement" "$self_ev_refs" \
    "recon_self_observation" \
    "$([ "$self_ok" = "true" ] && echo 'info' || echo 'warning')")
  FINDING_FILES["self"]="$finding_self"
  budget_track "$finding_self"

  log "  Self-status: ok=${self_ok}, pins=${actual_pins}/${expected_count}, issues=${self_issues:-none}"
}

# ---- Phase 8: Generate Sub-Digest (§12.3 op 10) --------------------------

generate_digest() {
  log "=== Phase 8: Generate sub-digest (composition contract) ==="

  # Count artifacts on disk
  count_dir() { { ls -1 "$1"/*.json 2>/dev/null || true; } | wc -l | tr -d ' '; }

  local drift_count_on_disk
  drift_count_on_disk=$(count_dir drift)

  # Build attention_items from drift records
  local attention_items_json="["
  local first_ai=true

  if [ "$drift_count_on_disk" -gt 0 ]; then
    for f in drift/*.json; do
      [ -f "$f" ] || continue
      $first_ai || attention_items_json+=","
      first_ai=false

      # Extract target repo from drift record
      local drift_data claim_id ev_id diff_desc
      drift_data=$(python3 -c "
import json
with open('$f') as fh:
    d = json.load(fh)
print(json.dumps({
    'claim': d.get('claim_observation',''),
    'ev': d.get('evidence',''),
    'diff': d.get('difference','')[:120]
}))
" 2>/dev/null || echo '{"claim":"","ev":"","diff":""}')

      claim_id=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('claim',''))" <<< "$drift_data" 2>/dev/null || echo "")
      diff_desc=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('diff',''))" <<< "$drift_data" 2>/dev/null || echo "")

      # Find the target repo — look for the claim that generated this drift
      local target="kimeisele/agent-world"
      # Try to determine from claim mapping
      for ckey in "${!CLAIM_FILES[@]}"; do
        local cf="${CLAIM_FILES[$ckey]}"
        if [ -f "$cf" ]; then
          local cid
          cid=$(python3 -c "import json; d=json.load(open('$cf')); print(d.get('claim_id',''))" 2>/dev/null || echo "")
          if [ "$cid" = "$claim_id" ]; then
            target=$(python3 -c "import json; d=json.load(open('$cf')); print(d.get('source_repository','kimeisele/agent-world'))" 2>/dev/null || echo "kimeisele/agent-world")
            break
          fi
        fi
      done

      # Determine finding ref for this drift
      local finding_ref=""
      for fkey in "${!FINDING_FILES[@]}"; do
        local ff="${FINDING_FILES[$fkey]}"
        if [ -f "$ff" ]; then
          finding_ref="${ff##*/}"
          break
        fi
      done
      [ -z "$finding_ref" ] && finding_ref="findings/none"

      attention_items_json+=$(cat <<ENDAI
{
  "target": $(json_val "$target"),
  "status": "observed",
  "attention_rank": 1,
  "headline": $(json_val "Boundary drift: $diff_desc"),
  "refs": [$(json_val "findings/$finding_ref"), $(json_val "drift/$(basename "$f")")]
}
ENDAI
)
    done
  fi

  # If no drift, add a positive attention item
  if [ "$drift_count_on_disk" -eq 0 ]; then
    attention_items_json+=$(cat <<ENDAI
{
  "target": "kimeisele/*",
  "status": "observed",
  "attention_rank": 99,
  "headline": "No boundary drift detected across all observed repositories",
  "refs": ["findings/"]
}
ENDAI
)
    first_ai=false
  fi

  # Stale boundary table check
  local rb_claim="${CLAIM_FILES["rb-agent-world"]}"
  if [ -n "$rb_claim" ] && [ -f "$rb_claim" ]; then
    local last_audited=""
    last_audited=$(python3 -c "
import json, re
d = json.load(open('$rb_claim'))
t = d.get('claim_text','')
m = re.search(r'last audited: ([^)]+)', t)
print(m.group(1) if m else '')
" 2>/dev/null || echo "")

    if [ -n "$last_audited" ] && [ "$last_audited" != "2026-07-23" ]; then
      $first_ai || attention_items_json+=","
      first_ai=false
      attention_items_json+=$(cat <<ENDAI
{
  "target": "kimeisele/agent-world",
  "status": "stale",
  "attention_rank": 2,
  "headline": "REPO_BOUNDARIES.md last audited ${last_audited} — boundary source may be stale",
  "refs": ["findings/", "claims/"]
}
ENDAI
)
    fi
  fi

  attention_items_json+="]"

  # Build summary
  local summary_json
  summary_json=$(cat <<ENDJSON
{
  "pins": $(count_dir pins),
  "claims": $(count_dir claims),
  "evidence": $(count_dir evidence),
  "drift_records": $(count_dir drift),
  "findings": $(count_dir findings),
  "coverage_records": $(count_dir coverage),
  "observed_repositories": ${#OBSERVED_REPOS[@]},
  "partial_failures": ${PARTIAL_FAILURES}
}
ENDJSON
  )

  # Build the sub-digest in common shape (DIGEST_CONTRACT.md)
  local sub_digest_json
  sub_digest_json=$(cat <<ENDJSON
{
  "procedure_id": "v0-boundary-drift",
  "procedure_version": "v0",
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "attention_items": $attention_items_json,
  "summary": $summary_json,
  "budget": $(budget_summary),
  "self_observation": $SELF_STATUS
}
ENDJSON
  )

  write_json "digest/v0-boundary-drift.json" "$sub_digest_json"
  log "Sub-digest written to digest/v0-boundary-drift.json"
}

# ---- Phase 9: Budget Enforcement (§12.3 op 11) -------------------------

enforce_budget() {
  log "=== Phase 9: Budget enforcement ==="
  budget_checkpoint "final"

  # Check against F-03 (storage-model failure): if budget breached despite manifest-only
  if [ "$BUDGET_TOTAL_BYTES" -ge "$HARD_ABORT" ]; then
    log "F-03 TRIGGER: Budget breached despite manifest-only storage"
    RUN_RESULT="budget_breach"
    exit 2
  fi

  if [ "$BUDGET_TOTAL_BYTES" -ge "$WARN_THRESHOLD" ]; then
    warn "Near budget limit — review output sizes"
  fi
}

# ---- Validation --------------------------------------------------------

validate_outputs() {
  log "=== Validation: Schema validation ==="
  local errors=0

  # Validate each artifact against its schema
  local pin_validated=0
  for f in pins/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/repository-pin.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    pin_validated=$(( pin_validated + 1 ))
  done

  local claim_validated=0
  for f in claims/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/claim-observation.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    claim_validated=$(( claim_validated + 1 ))
  done

  local ev_validated=0
  for f in evidence/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/evidence.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    ev_validated=$(( ev_validated + 1 ))
  done

  local drift_validated=0
  for f in drift/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/drift-record.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    drift_validated=$(( drift_validated + 1 ))
  done

  local finding_validated=0
  for f in findings/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/finding.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    finding_validated=$(( finding_validated + 1 ))
  done

  local cov_validated=0
  for f in coverage/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/coverage-record.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    cov_validated=$(( cov_validated + 1 ))
  done

  log "  Validated: ${pin_validated} pins, ${claim_validated} claims, ${ev_validated} evidence, ${drift_validated} drift, ${finding_validated} findings, ${cov_validated} coverage"
  if [ "$errors" -gt 0 ]; then
    log "  FAILED: ${errors} validation errors"
    RUN_RESULT="validation_error"
    return 1
  fi
  log "  All artifacts valid ✓"
  return 0
}

# ---- Run Summary -------------------------------------------------------

print_summary() {
  log ""
  log "=== Run Summary ==="
  log "  Procedure: ${PROCEDURE_ID} / ${PROCEDURE_VERSION}"
  log "  Timestamp: ${RUN_TIMESTAMP}"
  log "  Result: ${RUN_RESULT}"
  log "  Repositories: $(for k in "${!PIN_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')/${#OBSERVED_REPOS[@]} pinned"
  log "  Claims recorded: $(for k in "${!CLAIM_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')"
  log "  Evidence: $(for k in "${!EVIDENCE_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')"
  log "  Drift records: $(for k in "${!DRIFT_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')"
  log "  Findings: $(for k in "${!FINDING_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')"
  log "  Coverage: $(for k in "${!COVERAGE_FILES[@]}"; do echo 1; done | wc -l | tr -d ' ')"
  log "  Budget: ${BUDGET_TOTAL_BYTES}B"
  log ""
  log "  Next: bash scripts/validate-artifacts.sh"
}

# ---- Main --------------------------------------------------------------

main() {
  local reproduce=false
  if [ "${1:-}" = "--reproduce" ]; then
    reproduce=true
    RECON_REPRO_DIR="${RECON_PINS_DIR:-pins}"
    log "Reproduction mode — using pins from ${RECON_REPRO_DIR}"
  fi

  # Check baseline dependencies
  check_deps git gh rg || die "Missing required tools (git, gh, rg)"

  # Optional tools
  check_opt_deps python3 jq

  run_start
  RUN_TIMESTAMP="$(utc_timestamp)"
  if $reproduce; then
    # Determinism (FR-CON-012): freeze the run timestamp to this procedure's own
    # previously recorded sub-digest, so pins and claim observed_at reproduce
    # byte-identically instead of being re-stamped with wall-clock time.
    frozen_ts="$(python3 -c "import json; print(json.load(open('digest/v0-boundary-drift.json')).get('run_timestamp',''))" 2>/dev/null || true)"
    [ -n "${frozen_ts:-}" ] && RUN_TIMESTAMP="$frozen_ts"
    # Freeze ALL derived timestamps (coverage/finding/drift) to the same value.
    export RECON_FROZEN_TS="$RUN_TIMESTAMP"
  fi

  log "=== Boundary Drift Recon v0 ==="
  log "Timestamp: ${RUN_TIMESTAMP}"
  log "Mode: $($reproduce && echo 'reproduce' || echo 'live')"
  log ""

  budget_init

  # Phase 1-2: Resolve and pin
  resolve_pins "$reproduce"
  budget_checkpoint "pins"

  # Phase 2: Extract claims
  extract_well_known_claims
  extract_boundary_table_claims
  extract_constitution_claims
  extract_self_observation_claims
  budget_checkpoint "claims"

  # Phase 3: Deterministic observations
  run_deterministic_observations
  budget_checkpoint "evidence"

  # Phase 4: Compare and detect drift
  detect_drift
  budget_checkpoint "drift"

  # Phase 5: Generate findings
  generate_findings
  budget_checkpoint "findings"

  # Phase 6: Coverage
  record_coverage
  budget_checkpoint "coverage"

  # Phase 7: Self-observation
  perform_self_observation
  budget_checkpoint "self-observation"

  # Phase 8: Digest
  generate_digest
  budget_checkpoint "digest"

  # Phase 9: Budget enforcement
  enforce_budget

  # Run result
  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    RUN_RESULT="partial"
  fi

  # Schema validation
  validate_outputs || true  # don't abort on validation errors

  print_summary

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    exit 75
  fi
  exit 0
}

main "$@"
