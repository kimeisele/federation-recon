#!/usr/bin/env bash
# node-census-run.sh — Federation Node Census v1 Runner
#
# Discovers all repos with GitHub topic `agent-federation-node`,
# collects flat metadata evidence per node, and produces a ranked
# Federation Digest sorted by "needs attention".
#
# Implements the 12 operations from procedures/node-census-v1.md.
# Fully deterministic (FR-CON-012): identical pins + same procedure version
# → identical Evidence.
#
# Tools: git, gh, rg, python3 (§11.1 baseline).
#
# Usage:
#   bash scripts/node-census-run.sh              # Full live census
#   RECON_PINS_DIR=pins bash scripts/node-census-run.sh --reproduce   # Fixed-pin rerun
#
# Exit codes:
#   0 — success
#   1 — runtime error (tool missing, write failure)
#   2 — budget breach
#   3 — schema validation failure
#  75 — terminal partial failure (some nodes failed)

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-procedure pin namespace — must be set BEFORE sourcing artifacts.sh
export PIN_NAMESPACE="v1-census"

# Source libraries
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/artifacts.sh"
source "$SCRIPT_DIR/lib/budget.sh"
source "$SCRIPT_DIR/lib/github-api.sh"
# Note: we do NOT source digest.sh — census digest is structurally different.

# ---- Configuration -----------------------------------------------------

PROCEDURE_ID="node-census-v1"
PROCEDURE_VERSION="v1"
STALE_DAYS="${RECON_STALE_DAYS:-60}"
SELF_REPO="kimeisele/federation-recon"

# Single source of truth for the adopted observed set.
# Reuses the same grep parsing pattern as manifest-gate.sh (scripts/lib/manifest-gate.sh).
# Chosen as the single reference so the manifest parsers stay in sync — the gate
# checks pin→manifest membership with the same regex, and the census reads the
# adopted set for recording scope from the same document. A hard-coded list here
# would drift from the manifest exactly as the census drifted from it before (#82).
MANIFEST_FILE="$REPO_ROOT/docs/repository-manifest.md"

# Output directories
mkdir -p "$REPO_ROOT/pins/$PIN_NAMESPACE" "$REPO_ROOT/evidence"
mkdir -p "$REPO_ROOT/findings" "$REPO_ROOT/coverage"
mkdir -p "$REPO_ROOT/digest"

cd "$REPO_ROOT"

# ---- State -------------------------------------------------------------

declare -A REPO_SHA          # repo slug → resolved SHA
declare -A REPO_REF          # repo slug → default branch name
declare -A REPO_UPDATED      # repo slug → last update timestamp
declare -A PIN_FILES         # slug → pin file path
declare -A EVIDENCE_FILES    # key → evidence file path
declare -A FINDING_FILES     # key → finding file path
declare -A COVERAGE_FILES    # key → coverage file path
declare -A NODE_OBS_FAILED   # slug → "1" if any GitHub observation read failed
declare -A NODE_OBS_REASON   # slug → human-readable reason for the failure

# Per-node census data for ranking
declare -A NODE_STATUS       # slug → ok|stale|error
declare -A NODE_ROLE         # slug → role from .well-known
declare -A NODE_TIER         # slug → tier/layer from .well-known
declare -A NODE_DISPLAY_NAME # slug → display_name from .well-known
declare -A NODE_DESCRIPTOR   # slug → true|false
declare -A NODE_CHARTER      # slug → true|false
declare -A NODE_LAST_COMMIT  # slug → ISO date

NODE_SLUGS=()        # ordered list of ALL discovered node slugs (unbounded)
ADOPTED_SLUGS=()     # subset of NODE_SLUGS present in the manifest adopted observed set
CANDIDATE_SLUGS=()   # discovered slugs NOT in the adopted set — written to candidates record
RUN_TIMESTAMP=""
RUN_RESULT="success"
PARTIAL_FAILURES=0

# mark_node_observation_failed <repo> <what>
#   Records an explicit observation failure for REPO (named in the log) and
#   routes the run to the partial/terminal exit path (75). The caller MUST NOT
#   have emitted a "missing descriptor" finding, an absence claim, or zero
#   evidence: a transport failure is not an observation of absence (#175).
mark_node_observation_failed() {
  local repo="$1" what="$2"
  local slug="${repo#*/}"
  if [ "${NODE_OBS_FAILED[$slug]:-0}" != "1" ]; then
    NODE_OBS_FAILED["$slug"]=1
    PARTIAL_FAILURES=$(( PARTIAL_FAILURES + 1 ))
  fi
  NODE_OBS_REASON["$slug"]="${what} failed"
  warn "  GitHub read failed for ${repo} (${what}) — no absence/zero observation recorded"
}

# ---- Phase 1: Discover nodes via GitHub topic (§12.3-ish op 1) ---------

discover_nodes() {
  log "=== Phase 1: Discover nodes via topic agent-federation-node ==="

  local search_json
  search_json=$(gh search repos "topic:agent-federation-node" \
    --json fullName,defaultBranch,updatedAt \
    --jq '.' 2>/dev/null || true)

  if [ -z "$search_json" ]; then
    die "gh search repos returned empty result — check gh auth and topic existence"
  fi

  # Parse each repo: fullName, defaultBranch, updatedAt
  local count=0
  while IFS= read -r line; do
    local fullname branch updated
    fullname=$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('fullName',''))" 2>/dev/null || true)
    branch=$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('defaultBranch','main'))" 2>/dev/null || echo "main")
    updated=$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('updatedAt',''))" 2>/dev/null || true)

    [ -z "$fullname" ] && continue

    local slug="${fullname#*/}"
    NODE_SLUGS+=("$slug")
    REPO_REF["$fullname"]="$branch"
    REPO_UPDATED["$fullname"]="$updated"
    count=$(( count + 1 ))
    log "  Found: $fullname (branch: $branch, updated: $updated)"
  done < <(printf '%s' "$search_json" | python3 -c "
import json, sys
arr = json.load(sys.stdin)
for item in arr:
    print(json.dumps(item))
" 2>/dev/null || true)

  log "  Discovered ${count} nodes via topic search"

  # FR-CON-011: add self
  local self_slug="${SELF_REPO#*/}"
  NODE_SLUGS+=("$self_slug")
  REPO_REF["$SELF_REPO"]="main"
  log "  Self-observation: added ${SELF_REPO} (FR-CON-011)"
}

# ---- Adopted set from manifest (reuses manifest-gate.sh's grep pattern) --

# parse_manifest_adopted_slugs <manifest_file>
# Prints the sorted list of repository slugs in the manifest's adopted observed set.
# Returns 0 on success, 1 if the manifest is missing, unparseable, or empty.
# Uses the identical grep/sed pattern as check_pin_manifest_membership in
# scripts/lib/manifest-gate.sh to keep the two parsers in deterministic sync.
parse_manifest_adopted_slugs() {
  local manifest_file="$1"

  if [ ! -f "$manifest_file" ]; then
    log "  Manifest file not found: $manifest_file"
    return 1
  fi

  # Extract repository slugs from the adopted-observed-set table.
  # Table rows have the shape: | `kimeisele/<slug>` | ... | yes |
  # Parse the first backtick-delimited column, strip the kimeisele/ prefix.
  # Same pattern as manifest-gate.sh: grep for | `kimeisele/ lines,
  # then sed extracts the slug between backticks.
  local slugs
  slugs=$(
    grep -E '^\| `kimeisele/' "$manifest_file" \
    | sed -n 's/^| `kimeisele\/\([^`]*\)` .*/\1/p' \
    | sort -u
  )

  if [ -z "$slugs" ]; then
    log "  Could not parse any adopted repository from manifest: $manifest_file"
    return 1
  fi

  printf '%s\n' "$slugs"
}

# ---- Candidates record for non-adopted discoveries -----------------------

# write_candidates_record
# Writes digest/census-candidates.json listing every discovered slug that is
# NOT in the manifest's adopted observed set.
#
# Location choice: digest/census-candidates.json is a sibling of per-node
# coverage records under coverage/.  The pin→manifest gate (manifest-gate.sh)
# only inspects pins/*.json and pins/*/*.json, so this path is invisible to it.
# Putting it in coverage/ keeps it alongside the per-node coverage artefacts
# without risking a false-positive gate failure.
#
# The record is sorted deterministically by slug, uses the frozen RUN_TIMESTAMP
# for its observation_date (identical in live and reproduce mode), and contains
# no live mutable data (no pushed_at, no commit SHAs) — satisfying the
# FR-CON-012 reproduce-fixpoint constraint.
write_candidates_record() {
  log "=== Writing candidates record: ${#CANDIDATE_SLUGS[@]} non-adopted slugs ==="

  # Sort candidates deterministically by slug
  local sorted_slugs=()
  while IFS= read -r slug; do
    sorted_slugs+=("$slug")
  done < <(printf '%s\n' "${CANDIDATE_SLUGS[@]}" | sort)

  # Build candidates array JSON
  local candidates_json=""
  local first=true
  for slug in "${sorted_slugs[@]}"; do
    if $first; then
      first=false
    else
      candidates_json+=","
    fi
    candidates_json+=$'\n'"    {"
    candidates_json+=$'\n'"      \"slug\": $(json_val "$slug"),"
    candidates_json+=$'\n'"      \"discovery_source\": \"topic-search\","
    candidates_json+=$'\n'"      \"observation_date\": $(json_val "$RUN_TIMESTAMP")"
    candidates_json+=$'\n'"    }"
  done

  local json
  json=$(cat <<ENDJSON
{
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "candidates": [${candidates_json}
  ]
}
ENDJSON
  )

  write_json "digest/census-candidates.json" "$json"
  log "  Candidates record written to digest/census-candidates.json"
}

# ---- Phase 2: Resolve & Pin each node --------------------------------

resolve_pins() {
  log "=== Phase 2: Resolve & pin each node ==="
  local repro="${1:-false}"

  # In reproduce mode, load previously saved update timestamps
  if $repro && [ -f "digest/census-run-state.json" ]; then
    log "  Loading update timestamps from digest/census-run-state.json"
    while IFS= read -r line; do
      local r updated
      r=$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('repo',''))" 2>/dev/null || true)
      updated=$(printf '%s' "$line" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('updated_at',''))" 2>/dev/null || true)
      [ -n "$r" ] && [ -n "$updated" ] && REPO_UPDATED["$r"]="$updated"
    done < <(python3 -c "
import json
with open('digest/census-run-state.json') as f:
    state = json.load(f)
for n in state.get('nodes',[]):
    print(json.dumps(n))
" 2>/dev/null || true)
  fi

  for slug in "${ADOPTED_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="" ref="${REPO_REF[$repo]:-main}"

    if $repro && [ -n "${RECON_REPRO_DIR:-}" ]; then
      local pin_file="$RECON_REPRO_DIR/${slug}.json"
      if [ -f "$pin_file" ]; then
        sha=$(python3 -c "import json; print(json.load(open('$pin_file'))['resolved_commit_sha'])" 2>/dev/null || true)
      fi
    fi

    if [ -z "$sha" ]; then
      # Try the requested ref, then fall back to the repo's default branch.
      sha="$(gh_api_read "repos/${repo}/git/ref/heads/${ref}" --jq '.object.sha')" || sha=""
      if [ -z "$sha" ]; then
        local default_branch=""
        default_branch="$(gh_api_read "repos/${repo}" --jq '.default_branch')" || default_branch=""
        if [ -n "$default_branch" ]; then
          sha="$(gh_api_read "repos/${repo}/git/ref/heads/${default_branch}" --jq '.object.sha')" || sha=""
        fi
      fi
    fi

    if [ -z "$sha" ]; then
      warn "  Cannot resolve ${repo} — skipping"
      PARTIAL_FAILURES=$(( PARTIAL_FAILURES + 1 ))
      NODE_STATUS["$slug"]="error"
      continue
    fi

    REPO_SHA["$repo"]="$sha"

    # Also get updatedAt — in reproduce mode use loaded state, otherwise fetch live
    local updated="${REPO_UPDATED[$repo]:-}"
    if [ -z "$updated" ] && ! $repro; then
      updated="$(gh_api_read "repos/${repo}" --jq '.pushed_at')" || updated=""
      REPO_UPDATED["$repo"]="$updated"
    fi
    # In reproduce mode, if no saved state, we still need updatedAt — fetch live as fallback
    if [ -z "$updated" ]; then
      updated="$(gh_api_read "repos/${repo}" --jq '.pushed_at')" || updated=""
      REPO_UPDATED["$repo"]="$updated"
      if [ -z "$updated" ]; then
        # A failed liveness read must not become "unknown": mark the node partial.
        mark_node_observation_failed "$repo" "pushed_at fetch"
      fi
    fi

    local pin_file
    pin_file=$(gen_repository_pin "$repo" "$ref" "$sha" "$RUN_TIMESTAMP")
    PIN_FILES["$slug"]="$pin_file"
    budget_track "$pin_file"

    log "  ${repo} → ${sha:0:12} (ref: ${ref})"
  done
}

# ---- Phase 2.5: Save run state for reproducibility --------------------

save_run_state() {
  log "=== Saving run state for reproducibility ==="
  local nodes_json="["
  local first=true
  for slug in "${ADOPTED_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local updated="${REPO_UPDATED[$repo]:-}"
    $first || nodes_json+=","
    first=false
    nodes_json+="{\"repo\":$(json_val "$repo"),\"slug\":$(json_val "$slug"),\"updated_at\":$(json_val "$updated")}"
  done
  nodes_json+="]"

  # Candidates must be persisted, not just loaded. The reproduce path already
  # reads state["candidates"]; without this writer it read an empty list and the
  # candidates record collapsed from seven entries to one. Slug only — no
  # mutable fields — so the record reproduces byte-identically.
  local candidates_json="["
  local cfirst=true
  for slug in "${CANDIDATE_SLUGS[@]}"; do
    $cfirst || candidates_json+=","
    cfirst=false
    candidates_json+="$(json_val "$slug")"
  done
  candidates_json+="]"

  local state_json
  state_json=$(cat <<ENDJSON
{
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "nodes": $nodes_json,
  "candidates": $candidates_json
}
ENDJSON
)
  write_json "digest/census-run-state.json" "$state_json"
  log "  Run state saved to digest/census-run-state.json"
}

# ---- Phase 3: Evidence collection per node ----------------------------

collect_evidence() {
  log "=== Phase 3: Collect flat evidence per node ==="

  for slug in "${ADOPTED_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"
    local pin_file="${PIN_FILES[$slug]:-}"

    [ -z "$sha" ] && continue
    [ -z "$pin_file" ] && continue

    log "  Collecting evidence for ${repo}..."

    # --- Evidence: .well-known/agent-federation.json existence ---
    # A transport failure (HTTP 403/5xx) is NOT a missing descriptor: no
    # file_existence=false evidence and no "missing descriptor" finding may be
    # emitted; the node is marked partial (#175). Only an explicit 404 is
    # legitimate absence.
    local wk_content="" wk_rc=0
    wk_content="$(gh_api_read_content "repos/${repo}/contents/.well-known/agent-federation.json?ref=${sha}")" || wk_rc=$?
    if [ "$wk_rc" -eq $GH_API_FAILURE ]; then
      mark_node_observation_failed "$repo" ".well-known descriptor fetch"
      continue
    fi

    if [ -z "$wk_content" ]; then
      NODE_DESCRIPTOR["$slug"]="false"
      local ev_wk
      ev_wk=$(gen_evidence "$pin_file" "file_existence" "false" \
        ".well-known/agent-federation.json")
      EVIDENCE_FILES["wk-exists-${slug}"]="$ev_wk"
      budget_track "$ev_wk"
      log "    .well-known/agent-federation.json: MISSING"
    else
      NODE_DESCRIPTOR["$slug"]="true"
      local ev_wk
      ev_wk=$(gen_evidence "$pin_file" "file_existence" "true" \
        ".well-known/agent-federation.json")
      EVIDENCE_FILES["wk-exists-${slug}"]="$ev_wk"
      budget_track "$ev_wk"

      # --- Evidence: role from .well-known ---
      local role=""
      role=$(printf '%s' "$wk_content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    r = d.get('role','')
    if not r:
        r = d.get('kind','')
    print(r)
except: print('')
" 2>/dev/null || echo "")
      role="$(truncate_observed "$role")"
      NODE_ROLE["$slug"]="$role"

      local ev_role
      ev_role=$(gen_evidence "$pin_file" "manifest_field" "$role" \
        ".well-known/agent-federation.json" \
        "field=role")
      EVIDENCE_FILES["role-${slug}"]="$ev_role"
      budget_track "$ev_role"

      # --- Evidence: tier/layer from .well-known ---
      local tier=""
      tier=$(printf '%s' "$wk_content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    t = d.get('tier','')
    if not t:
        t = d.get('layer','')
    print(t)
except: print('')
" 2>/dev/null || echo "")
      tier="$(truncate_observed "$tier")"
      NODE_TIER["$slug"]="$tier"

      local ev_tier
      ev_tier=$(gen_evidence "$pin_file" "manifest_field" "$tier" \
        ".well-known/agent-federation.json" \
        "field=tier_or_layer")
      EVIDENCE_FILES["tier-${slug}"]="$ev_tier"
      budget_track "$ev_tier"

      # --- Evidence: display_name from .well-known ---
      local display_name=""
      display_name=$(printf '%s' "$wk_content" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('display_name',''))
except: print('')
" 2>/dev/null || echo "")
      display_name="$(truncate_observed "$display_name")"
      NODE_DISPLAY_NAME["$slug"]="$display_name"

      log "    .well-known/agent-federation.json: role=${role:-<none>}, tier=${tier:-<none>}"
    fi

    # --- Evidence: Charter existence ---
    local charter_found="false"
    for charter_path in "docs/authority/charter.md" "docs/CHARTER.md" "CHARTER.md"; do
      local charter_name="" charter_rc=0
      charter_name="$(gh_api_read "repos/${repo}/contents/${charter_path}?ref=${sha}" --jq '.name')" || charter_rc=$?
      if [ "$charter_rc" -eq $GH_API_FAILURE ]; then
        # A transport failure is not "no charter at this path": mark partial.
        mark_node_observation_failed "$repo" "charter fetch (${charter_path})"
        break
      fi
      if [ -n "$charter_name" ]; then
        charter_found="true"
        break
      fi
    done
    NODE_CHARTER["$slug"]="$charter_found"

    local ev_charter
    ev_charter=$(gen_evidence "$pin_file" "file_existence" "$charter_found" \
      "docs/authority/charter.md")
    EVIDENCE_FILES["charter-${slug}"]="$ev_charter"
    budget_track "$ev_charter"
    log "    Charter: ${charter_found}"

    # --- Evidence: last commit date (liveness) ---
    local last_commit="${REPO_UPDATED[$repo]:-}"
    if [ -z "$last_commit" ]; then
      last_commit="$(gh_api_read "repos/${repo}" --jq '.pushed_at')" || last_commit=""
      if [ -z "$last_commit" ]; then
        # A failed liveness read must not become "unknown" evidence.
        mark_node_observation_failed "$repo" "pushed_at fetch"
      fi
    fi
    NODE_LAST_COMMIT["$slug"]="$last_commit"

    if [ -n "$last_commit" ]; then
      local ev_liveness
      ev_liveness=$(gen_evidence "$pin_file" "manifest_field" "$last_commit" \
        "/ (repo root)" \
        "field=last_commit_date")
      EVIDENCE_FILES["liveness-${slug}"]="$ev_liveness"
      budget_track "$ev_liveness"
      log "    Last commit: ${last_commit}"
    fi
  done
}

# ---- Phase 4: Generate Findings per node ------------------------------

generate_findings() {
  log "=== Phase 4: Generate Findings per node ==="

  for slug in "${ADOPTED_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"

    # A node with a failed GitHub observation gets a failure finding — never a
    # "missing descriptor" finding, which would assert absence the transport
    # failure did not establish (#175).
    if [ "${NODE_OBS_FAILED[$slug]:-0}" = "1" ]; then
      NODE_STATUS["$slug"]="error"
      local ev_ref="${EVIDENCE_FILES["wk-exists-${slug}"]:-}"
      [ -z "$ev_ref" ] && ev_ref="pins/v1-census/${slug}.json"

      local finding_fail
      finding_fail=$(gen_finding "Node ${repo} observation incomplete — ${NODE_OBS_REASON[$slug]:-GitHub read failure}; no absence or zero observation recorded" \
        "$ev_ref" "node_census" "warning" "observed")
      FINDING_FILES["error-${slug}"]="$finding_fail"
      budget_track "$finding_fail"
      continue
    fi

    if [ -z "$sha" ]; then
      NODE_STATUS["$slug"]="error"
      local ev_ref="${EVIDENCE_FILES["wk-exists-${slug}"]:-}"
      [ -z "$ev_ref" ] && ev_ref="pins/v1-census/${slug}.json"

      local finding_error
      finding_error=$(gen_finding "Node ${repo} could not be resolved — no commit SHA obtained" \
        "$ev_ref" "node_census" "warning" "observed")
      FINDING_FILES["error-${slug}"]="$finding_error"
      budget_track "$finding_error"
      continue
    fi

    # Determine staleness: stale if descriptor missing OR last commit > STALE_DAYS ago
    local status="observed"
    local statement=""
    local severity="info"

    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"
    local last_commit="${NODE_LAST_COMMIT[$slug]:-}"

    # Check staleness by commit date
    if [ -n "$last_commit" ] && [ "$last_commit" != "unknown" ]; then
      local commit_epoch now_epoch
      commit_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_commit" +%s 2>/dev/null || \
                     date -d "$last_commit" +%s 2>/dev/null || echo 0)
      now_epoch=$(date -u +%s)
      local age_days=$(( (now_epoch - commit_epoch) / 86400 ))

      if [ "$age_days" -gt "$STALE_DAYS" ]; then
        status="stale"
      fi
    fi

    # Missing descriptor always means stale
    if [ "$descriptor" = "false" ]; then
      status="stale"
    fi

    NODE_STATUS["$slug"]="$status"

    # Build finding statement
    local role="${NODE_ROLE[$slug]:-unknown}"
    local tier="${NODE_TIER[$slug]:-}"
    local charter="${NODE_CHARTER[$slug]:-false}"
    local display_name="${NODE_DISPLAY_NAME[$slug]:-}"

    if [ "$status" = "stale" ]; then
      severity="warning"
      if [ "$descriptor" = "false" ]; then
        statement="Node ${repo} is STALE — missing .well-known/agent-federation.json descriptor"
      else
        statement="Node ${repo} is STALE — last commit older than ${STALE_DAYS} days (${last_commit})"
      fi
    else
      statement="Node ${repo} is OK — descriptor present, role=${role}, tier=${tier:-none}, charter=${charter}, last commit ${last_commit}"
    fi

    # Collect evidence refs for this node
    local ev_refs=""
    local first=true
    for ekey in "wk-exists-${slug}" "role-${slug}" "tier-${slug}" "charter-${slug}" "liveness-${slug}"; do
      local eref="${EVIDENCE_FILES[$ekey]:-}"
      if [ -n "$eref" ] && [ -f "$eref" ]; then
        local eid
        eid=$(artifact_id "$eref")
        if [ -n "$eid" ]; then
          $first && ev_refs+="$eid" || ev_refs+=",${eid}"
          first=false
        fi
      fi
    done
    # Fallback to pin
    if $first; then
      ev_refs="pins/v1-census/${slug}.json"
    fi

    local finding
    finding=$(gen_finding "$statement" "$ev_refs" "node_census" "$severity" "$status")
    FINDING_FILES["node-${slug}"]="$finding"
    budget_track "$finding"

    log "  ${repo}: status=${status}, role=${role}, tier=${tier:-none}"
  done
}

# ---- Phase 5: Coverage Records ----------------------------------------

record_coverage() {
  log "=== Phase 5: Record Coverage ==="

  local caps_used="git,gh,rg,python3"
  command -v jq &>/dev/null && caps_used+=",jq"

  local caps_missing=""
  command -v jq &>/dev/null || caps_missing="jq"

  for slug in "${ADOPTED_SLUGS[@]}"; do
    local pin_file="${PIN_FILES[$slug]:-}"
    [ -z "$pin_file" ] && continue

    local result="success"
    if [ "${NODE_OBS_FAILED[$slug]:-0}" = "1" ] || [ "${NODE_STATUS[$slug]:-}" = "error" ]; then
      result="partial"
    fi

    local cov
    cov=$(gen_coverage_record "$pin_file" "$result" "$caps_used" "$caps_missing")
    COVERAGE_FILES["${slug}"]="$cov"
    budget_track "$cov"
  done
}

# ---- Phase 6: Self-Observation (FR-CON-011) ---------------------------

perform_self_observation() {
  log "=== Phase 6: Self-Observation (FR-CON-011) ==="

  local self_ok="true"
  local self_issues=""

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    self_ok="false"
    self_issues+="partial_node_failures:${PARTIAL_FAILURES};"
  fi

  local total_nodes=${#ADOPTED_SLUGS[@]}
  local pinned_nodes=0
  for slug in "${!PIN_FILES[@]}"; do pinned_nodes=$(( pinned_nodes + 1 )); done

  if [ "$pinned_nodes" -lt "$total_nodes" ]; then
    self_ok="false"
    self_issues+="missing_pins:expected_${total_nodes}_got_${pinned_nodes};"
  fi

  local self_statement=""
  if [ "$self_ok" = "true" ]; then
    self_statement="Self-observation: Federation Node Census completed successfully — ${pinned_nodes}/${total_nodes} nodes observed"
  else
    self_statement="Self-observation: Federation Node Census completed with issues — ${self_issues}"
  fi

  local self_ev_refs=""
  local first=true
  for key in "${!COVERAGE_FILES[@]}"; do
    if [ -n "${COVERAGE_FILES[$key]}" ] && [ -f "${COVERAGE_FILES[$key]}" ]; then
      local cid
      cid=$(artifact_id "${COVERAGE_FILES[$key]}")
      if [ -n "$cid" ]; then
        $first && self_ev_refs+="$cid" || self_ev_refs+=",${cid}"
        first=false
      fi
    fi
  done
  [ -z "$self_ev_refs" ] && self_ev_refs="pins/v1-census/federation-recon.json"

  local finding_self
  finding_self=$(gen_finding "$self_statement" "$self_ev_refs" \
    "recon_self_observation" \
    "$([ "$self_ok" = "true" ] && echo 'info' || echo 'warning')")
  FINDING_FILES["self"]="$finding_self"
  budget_track "$finding_self"

  SELF_STATUS="{\"run_completed\":$([ "$PARTIAL_FAILURES" -eq 0 ] && echo 'true' || echo 'false'),\"outputs_complete\":$([ "$pinned_nodes" -ge "$total_nodes" ] && echo 'true' || echo 'false'),\"digest_fresh\":true,\"issues\":$(json_val "$self_issues")}"

  log "  Self-status: ok=${self_ok}, nodes=${pinned_nodes}/${total_nodes}"
}

# ---- Phase 7: Census Sub-Digest (composition contract) -----------------

generate_census_digest() {
  log "=== Phase 7: Generate census sub-digest (composition contract) ==="

  # --- Rank nodes by "needs attention" ---
  # Priority: missing descriptor > stale > ok > error
  # Within same priority, sort alphabetically by slug

  local rank_score
  declare -A RANK_SCORE

  for slug in "${ADOPTED_SLUGS[@]}"; do
    local status="${NODE_STATUS[$slug]:-error}"
    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"

    # Scoring: lower = needs more attention
    case "$status" in
      stale)
        if [ "$descriptor" = "false" ]; then
          RANK_SCORE["$slug"]=0
        else
          RANK_SCORE["$slug"]=1
        fi
        ;;
      error)  RANK_SCORE["$slug"]=2 ;;
      *)      RANK_SCORE["$slug"]=3 ;;
    esac
  done

  # Build sorted node list
  local sorted_slugs=()
  while IFS=' ' read -r score s; do
    sorted_slugs+=("$s")
  done < <(for slug in "${ADOPTED_SLUGS[@]}"; do
    printf '%s %s\n' "${RANK_SCORE[$slug]}" "$slug"
  done | sort -t' ' -k1,1n -k2,2)

  # --- Build attention_items for the common sub-digest shape ---
  local attention_items_json="["
  local first_ai=true

  # Constitutional non-peers (§5, Issue #6): federation-recon, agent-village
  # These should not be flagged for missing descriptors
  local constitutional_non_peers="federation-recon agent-village"

  for slug in "${sorted_slugs[@]}"; do
    local repo="kimeisele/${slug}"
    local status="${NODE_STATUS[$slug]:-error}"
    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"
    local role="${NODE_ROLE[$slug]:-}"
    local tier="${NODE_TIER[$slug]:-}"
    local charter="${NODE_CHARTER[$slug]:-false}"
    local last_commit="${NODE_LAST_COMMIT[$slug]:-}"

    # Determine if this node is a constitutional non-peer
    local is_non_peer="false"
    # shellcheck disable=SC2199
    if [[ " $constitutional_non_peers " == *" $slug "* ]]; then
      is_non_peer="true"
    fi

    # Skip OK nodes — they don't need operator attention
    if [ "$status" = "observed" ]; then
      continue
    fi

    # Build headline
    local headline=""
    local attn_rank=99
    local attn_status="$status"

    if [ "$status" = "error" ]; then
      if [ "${NODE_OBS_FAILED[$slug]:-0}" = "1" ]; then
        headline="Node ${repo} observation incomplete — ${NODE_OBS_REASON[$slug]:-GitHub read failure}"
      else
        headline="Node ${repo} could not be resolved"
      fi
      attn_rank=5
    elif [ "$status" = "stale" ]; then
      if [ "$descriptor" = "false" ]; then
        if [ "$is_non_peer" = "true" ]; then
          headline="Constitutional non-peer ${repo} — no descriptor expected (§5)"
          attn_status="observed"
          attn_rank=90  # low priority — expected
        else
          headline="Node ${repo} is missing .well-known/agent-federation.json descriptor"
          attn_rank=0
        fi
      else
        # Stale by age
        local age_str=""
        if [ -n "$last_commit" ] && [ "$last_commit" != "unknown" ]; then
          age_str=" (last commit: ${last_commit:0:10})"
        fi
        headline="Node ${repo} is stale — last commit > ${STALE_DAYS}d ago${age_str}"
        attn_rank=1
      fi
    else
      headline="Node ${repo} status: ${status}"
      attn_rank=10
    fi

    # Find the finding ref for this node
    local finding_file="${FINDING_FILES["node-${slug}"]:-}"
    local finding_ref="findings/"
    if [ -n "$finding_file" ] && [ -f "$finding_file" ]; then
      finding_ref="findings/$(basename "$finding_file")"
    fi

    $first_ai || attention_items_json+=","
    first_ai=false

    local non_peer_json=""
    if [ "$is_non_peer" = "true" ]; then
      non_peer_json=', "non_peer": true'
    fi

    attention_items_json+=$(cat <<ENDAI
{
  "target": $(json_val "$repo"),
  "status": $(json_val "$attn_status"),
  "attention_rank": ${attn_rank}${non_peer_json},
  "headline": $(json_val "$headline"),
  "refs": [$(json_val "$finding_ref")]
}
ENDAI
)
  done

  attention_items_json+="]"

  # --- Count artifacts on disk ---
  count_dir() { { ls -1 "$1"/*.json 2>/dev/null || true; } | wc -l | tr -d ' '; }

  local stale_count=0 ok_count=0 error_count=0
  for slug in "${ADOPTED_SLUGS[@]}"; do
    case "${NODE_STATUS[$slug]:-error}" in
      stale) stale_count=$(( stale_count + 1 )) ;;
      observed) ok_count=$(( ok_count + 1 )) ;;
      *) error_count=$(( error_count + 1 )) ;;
    esac
  done

  # Per-procedure counts: pins are namespaced; evidence/coverage/findings live in
  # shared dirs and are attributed by procedure_id (see scripts/lib/count_procedure.py).
  local pc_pins pc_ev pc_cov pc_find pc_drift
  read -r pc_pins pc_ev pc_cov pc_find pc_drift _consumption < <(
    python3 "$SCRIPT_DIR/lib/count_procedure.py" "$PROCEDURE_ID" "$PIN_NAMESPACE" --sh 2>/dev/null || echo "0 0 0 0 0 0"
  )
  local summary_json
  summary_json=$(cat <<ENDJSON
{
  "pins": ${pc_pins},
  "evidence": ${pc_ev},
  "findings": ${pc_find},
  "coverage_records": ${pc_cov},
  "observed_nodes": ${#ADOPTED_SLUGS[@]},
  "stale_nodes": ${stale_count},
  "ok_nodes": ${ok_count},
  "error_nodes": ${error_count},
  "staleness_threshold_days": ${STALE_DAYS}
}
ENDJSON
  )

  # --- Build the sub-digest in common shape (DIGEST_CONTRACT.md) ---
  local sub_digest_json
  sub_digest_json=$(cat <<ENDJSON
{
  "procedure_id": "v1-census",
  "procedure_version": "v1",
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "attention_items": $attention_items_json,
  "summary": $summary_json,
  "budget": $(budget_summary),
  "self_observation": $SELF_STATUS
}
ENDJSON
  )

  write_json "digest/v1-census.json" "$sub_digest_json"
  log "Sub-digest written to digest/v1-census.json"
}

# ---- Phase 8: Schema Validation ---------------------------------------

validate_outputs() {
  log "=== Phase 8: Schema validation ==="
  local errors=0

  for f in pins/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/repository-pin.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
  done

  for f in evidence/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/evidence.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
  done

  for f in findings/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/finding.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
  done

  for f in coverage/*.json; do
    [ -f "$f" ] || continue
    # digest/census-candidates.json is a different structure (candidates list,
    # not a per-node coverage record). It has its own schema; skip it here.
    [[ "$(basename "$f")" == "census-candidates.json" ]] && continue
    if ! validate_json_schema "$f" "schemas/coverage-record.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
  done

  local total=$(( $(ls -1 pins/*.json 2>/dev/null | wc -l) + $(ls -1 evidence/*.json 2>/dev/null | wc -l) + $(ls -1 findings/*.json 2>/dev/null | wc -l) + $(ls -1 coverage/*.json 2>/dev/null | wc -l) ))
  log "  Validated ${total} artifacts, ${errors} errors"

  if [ "$errors" -gt 0 ]; then
    RUN_RESULT="validation_error"
    return 1
  fi
  log "  All artifacts valid ✓"
  return 0
}

# ---- Phase 9: Budget Enforcement --------------------------------------

enforce_budget() {
  log "=== Phase 9: Budget enforcement ==="
  budget_checkpoint "final"

  if [ "$BUDGET_TOTAL_BYTES" -ge "$HARD_ABORT" ]; then
    log "F-03 TRIGGER: Budget breached despite manifest-only storage"
    RUN_RESULT="budget_breach"
    exit 2
  fi

  if [ "$BUDGET_TOTAL_BYTES" -ge "$WARN_THRESHOLD" ]; then
    warn "Near budget limit — review output sizes"
  fi
}

# ---- Run Summary -------------------------------------------------------

print_summary() {
  log ""
  log "=== Federation Node Census Summary ==="
  log "  Procedure: ${PROCEDURE_ID} / ${PROCEDURE_VERSION}"
  log "  Timestamp: ${RUN_TIMESTAMP}"
  log "  Result: ${RUN_RESULT}"
  log "  Nodes discovered: ${#NODE_SLUGS[@]}"
  log "  Adopted and recorded: ${#ADOPTED_SLUGS[@]} (${#PIN_FILES[@]} pinned)"
  log "  Candidates (non-adopted): ${#CANDIDATE_SLUGS[@]}"
  log "  Evidence: $(ls -1 evidence/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Findings: $(ls -1 findings/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Coverage: $(ls -1 coverage/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Budget: ${BUDGET_TOTAL_BYTES}B"
  log ""

  local stale_count=0 ok_count=0 err_count=0
  for slug in "${ADOPTED_SLUGS[@]}"; do
    case "${NODE_STATUS[$slug]:-error}" in
      stale) stale_count=$(( stale_count + 1 )) ;;
      observed) ok_count=$(( ok_count + 1 )) ;;
      *) err_count=$(( err_count + 1 )) ;;
    esac
  done
  log "  OK: ${ok_count} | Stale: ${stale_count} | Errors: ${err_count}"
  log ""
  log "  Next: bash scripts/validate-artifacts.sh"
}

# ---- Main --------------------------------------------------------------

main() {
  local reproduce=false
  if [ "${1:-}" = "--reproduce" ]; then
    reproduce=true
    RECON_REPRO_DIR="${RECON_PINS_DIR:-pins}/v1-census"
    log "Reproduction mode — using pins from ${RECON_REPRO_DIR}"
  fi

  check_deps git gh rg python3 || die "Missing required tools (git, gh, rg, python3)"
  check_opt_deps jq

  run_start
  RUN_TIMESTAMP="$(utc_timestamp)"
  if $reproduce; then
    # Determinism (FR-CON-012): reuse the persisted run timestamp so pins and
    # claim observed_at reproduce byte-identically instead of re-stamping.
    frozen_ts="$(python3 -c "import json; print(json.load(open('digest/census-run-state.json')).get('run_timestamp',''))" 2>/dev/null || true)"
    [ -n "${frozen_ts:-}" ] && RUN_TIMESTAMP="$frozen_ts"
  fi

  # Freeze ALL derived timestamps (coverage/finding/drift) to the run timestamp,
  # in BOTH modes. Previously only reproduce froze them, so a live run stamped
  # each finding with the wall clock at the moment it was created while reproduce
  # flattened them all to the run timestamp. Any run lasting longer than a second
  # then failed the fixpoint — measured at 28 s of drift once the census grew a
  # manifest parse. All artifacts of one observation carry that observation's
  # time; that is what an observation timestamp means.
  export RECON_FROZEN_TS="$RUN_TIMESTAMP"

  log "=== Federation Node Census v1 ==="
  log "Timestamp: ${RUN_TIMESTAMP}"
  log "Mode: $($reproduce && echo 'reproduce' || echo 'live')"
  log "Staleness threshold: ${STALE_DAYS} days"
  log ""

  budget_init

  # Phase 1: Discover nodes
  if $reproduce; then
    # In reproduce mode, infer nodes from existing pin files
    log "=== Phase 1 (reproduce): Load nodes from existing pins ==="
    for f in "${RECON_REPRO_DIR}"/*.json; do
      [ -f "$f" ] || continue
      local slug
      slug=$(basename "$f" .json)
      local repo="kimeisele/${slug}"
      NODE_SLUGS+=("$slug")
      REPO_REF["$repo"]="main"
    done
    # Ensure self is included
    local self_found=false
    for slug in "${NODE_SLUGS[@]}"; do
      [ "$slug" = "federation-recon" ] && self_found=true
    done
    if ! $self_found; then
      NODE_SLUGS+=("federation-recon")
      REPO_REF["$SELF_REPO"]="main"
    fi
    log "  Loaded ${#NODE_SLUGS[@]} nodes from pins directory"
  else
    discover_nodes
  fi
  budget_checkpoint "discovery"

  # ---- Compute adopted set from manifest (#82) -------------------------
  # Discovery was unbounded (all topic-search results + self). Now we bound
  # recording: only slugs in the manifest's adopted observed set proceed to
  # pinning, evidence, findings, coverage, and digest. Non-adopted
  # discoveries go to the candidates record instead of being silently dropped.
  ADOPTED_SLUGS=()
  CANDIDATE_SLUGS=()

  if $reproduce; then
    # Reproduce mode: all pin-derived slugs are adopted by definition — they
    # came from committed pin files that already passed the pin→manifest gate.
    # Skip the manifest parse-and-validate dance; just use NODE_SLUGS as-is.
    ADOPTED_SLUGS=("${NODE_SLUGS[@]}")
    # Candidates cannot be rediscovered here — no topic search runs in reproduce
    # mode — so they are read back from the run state the live run persisted.
    # Emptying them instead made the candidates record collapse from seven
    # entries to one, which is a silent loss of an observation.
    CANDIDATE_SLUGS=()
    if [ -f "digest/census-run-state.json" ]; then
      mapfile -t CANDIDATE_SLUGS < <(python3 -c "
import json
try:
    st = json.load(open('digest/census-run-state.json'))
except Exception:
    raise SystemExit(0)
for s in st.get('candidates', []):
    print(s)
" 2>/dev/null || true)
    fi
    log "  Reproduce mode: ${#ADOPTED_SLUGS[@]} pin-derived slugs adopted, ${#CANDIDATE_SLUGS[@]} candidates from saved state"
  else
    # Live mode: parse the manifest and classify discoveries.
    local manifest_slugs
    manifest_slugs=$(parse_manifest_adopted_slugs "$MANIFEST_FILE") || {
      die "Could not parse any adopted repository from ${MANIFEST_FILE} —" \
        "census cannot determine which nodes it is authorised to record." \
        "Refusing to run with an empty authorisation set."
    }

    # Build lookup table
    declare -A IS_ADOPTED
    while IFS= read -r slug; do
      [ -n "$slug" ] && IS_ADOPTED["$slug"]=1
    done < <(printf '%s\n' "$manifest_slugs")

    # Classify each discovered slug
    for slug in "${NODE_SLUGS[@]}"; do
      if [ "${IS_ADOPTED[$slug]:-}" = "1" ]; then
        ADOPTED_SLUGS+=("$slug")
      else
        CANDIDATE_SLUGS+=("$slug")
      fi
    done

    if [ "${#ADOPTED_SLUGS[@]}" -eq 0 ]; then
      die "Adopted set is empty — ${MANIFEST_FILE} contains no adopted repositories." \
        "Census cannot record any nodes. An empty census would look like a" \
        "successful run that observed a federation of zero nodes, which is a" \
        "silent failure. Fix the manifest before running the census."
    fi

    log "  Manifest scope: ${#ADOPTED_SLUGS[@]} adopted, ${#CANDIDATE_SLUGS[@]} candidates (${#NODE_SLUGS[@]} discovered)"
  fi

  # Canonical order for BOTH modes. Sorting only the live branch left reproduce
  # on pin-directory order, so the same seven nodes still produced two
  # sequences. Discovery order — and directory order — are accidents and must
  # never reach an artifact.
  mapfile -t ADOPTED_SLUGS < <(printf '%s\n' "${ADOPTED_SLUGS[@]}" | LC_ALL=C sort)
  if [ "${#CANDIDATE_SLUGS[@]}" -gt 0 ]; then
    mapfile -t CANDIDATE_SLUGS < <(printf '%s\n' "${CANDIDATE_SLUGS[@]}" | LC_ALL=C sort)
  fi

  # Phase 2: Resolve & pin
  resolve_pins "$reproduce"
  budget_checkpoint "pins"

  # Phase 3: Collect evidence
  collect_evidence
  save_run_state
  budget_checkpoint "evidence"

  # Phase 4: Generate findings
  generate_findings
  budget_checkpoint "findings"

  # Phase 5: Coverage
  record_coverage
  budget_checkpoint "coverage"

  # Candidates record: non-adopted discoveries are visible here rather than
  # silently dropped. (#82) Written after coverage so the log states both
  # counts (adopted-and-recorded vs candidates) together.
  write_candidates_record

  # Phase 6: Self-observation
  perform_self_observation
  budget_checkpoint "self-observation"

  # Phase 7: Census digest
  generate_census_digest
  budget_checkpoint "digest"

  # Phase 8: Validation
  validate_outputs || true  # don't abort, record in run result

  # Phase 9: Budget enforcement
  enforce_budget

  # Final run result
  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    RUN_RESULT="partial"
  fi

  print_summary

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    exit 75
  fi
  exit 0
}

main "$@"
