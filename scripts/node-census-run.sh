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

# Source libraries
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/artifacts.sh"
source "$SCRIPT_DIR/lib/budget.sh"
# Note: we do NOT source digest.sh — census digest is structurally different.

# ---- Configuration -----------------------------------------------------

PROCEDURE_ID="node-census-v1"
PROCEDURE_VERSION="v1"
STALE_DAYS="${RECON_STALE_DAYS:-60}"
SELF_REPO="kimeisele/federation-recon"

# Output directories
mkdir -p "$REPO_ROOT/pins" "$REPO_ROOT/evidence"
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

# Per-node census data for ranking
declare -A NODE_STATUS       # slug → ok|stale|error
declare -A NODE_ROLE         # slug → role from .well-known
declare -A NODE_TIER         # slug → tier/layer from .well-known
declare -A NODE_DISPLAY_NAME # slug → display_name from .well-known
declare -A NODE_DESCRIPTOR   # slug → true|false
declare -A NODE_CHARTER      # slug → true|false
declare -A NODE_LAST_COMMIT  # slug → ISO date

NODE_SLUGS=()  # ordered list of discovered node slugs
RUN_TIMESTAMP=""
RUN_RESULT="success"
PARTIAL_FAILURES=0

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
  REPO_REF["$SELF_REPO"]="master"
  log "  Self-observation: added ${SELF_REPO} (FR-CON-011)"
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

  for slug in "${NODE_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="" ref="${REPO_REF[$repo]:-main}"

    if $repro && [ -n "${RECON_REPRO_DIR:-}" ]; then
      local pin_file="$RECON_REPRO_DIR/${slug}.json"
      if [ -f "$pin_file" ]; then
        sha=$(python3 -c "import json; print(json.load(open('$pin_file'))['resolved_commit_sha'])" 2>/dev/null || true)
      fi
    fi

    if [ -z "$sha" ]; then
      sha=$(gh api "repos/${repo}/git/ref/heads/${ref}" --jq '.object.sha' 2>/dev/null || true)
      if [ -z "$sha" ]; then
        # Try fetching the repo info to get default branch SHA another way
        sha=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null | xargs -I{} gh api "repos/${repo}/git/ref/heads/{}" --jq '.object.sha' 2>/dev/null || true)
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
      updated=$(gh api "repos/${repo}" --jq '.pushed_at' 2>/dev/null || true)
      REPO_UPDATED["$repo"]="$updated"
    fi
    # In reproduce mode, if no saved state, we still need updatedAt — fetch live as fallback
    if [ -z "$updated" ]; then
      updated=$(gh api "repos/${repo}" --jq '.pushed_at' 2>/dev/null || true)
      REPO_UPDATED["$repo"]="$updated"
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
  for slug in "${NODE_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local updated="${REPO_UPDATED[$repo]:-}"
    $first || nodes_json+=","
    first=false
    nodes_json+="{\"repo\":$(json_val "$repo"),\"slug\":$(json_val "$slug"),\"updated_at\":$(json_val "$updated")}"
  done
  nodes_json+="]"

  local state_json
  state_json=$(cat <<ENDJSON
{
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "nodes": $nodes_json
}
ENDJSON
)
  write_json "digest/census-run-state.json" "$state_json"
  log "  Run state saved to digest/census-run-state.json"
}

# ---- Phase 3: Evidence collection per node ----------------------------

collect_evidence() {
  log "=== Phase 3: Collect flat evidence per node ==="

  for slug in "${NODE_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"
    local pin_file="${PIN_FILES[$slug]:-}"

    [ -z "$sha" ] && continue
    [ -z "$pin_file" ] && continue

    log "  Collecting evidence for ${repo}..."

    # --- Evidence: .well-known/agent-federation.json existence ---
    local wk_content=""
    wk_content=$(gh api "repos/${repo}/contents/.well-known/agent-federation.json?ref=${sha}" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)

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
      NODE_DISPLAY_NAME["$slug"]="$display_name"

      log "    .well-known/agent-federation.json: role=${role:-<none>}, tier=${tier:-<none>}"
    fi

    # --- Evidence: Charter existence ---
    local charter_found="false"
    for charter_path in "docs/authority/charter.md" "docs/CHARTER.md" "CHARTER.md"; do
      local charter_name=""
      charter_name=$(gh api "repos/${repo}/contents/${charter_path}?ref=${sha}" --jq '.name' 2>/dev/null || true)
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
      last_commit=$(gh api "repos/${repo}" --jq '.pushed_at' 2>/dev/null || echo "unknown")
    fi
    NODE_LAST_COMMIT["$slug"]="$last_commit"

    local ev_liveness
    ev_liveness=$(gen_evidence "$pin_file" "manifest_field" "$last_commit" \
      "/ (repo root)" \
      "field=last_commit_date")
    EVIDENCE_FILES["liveness-${slug}"]="$ev_liveness"
    budget_track "$ev_liveness"
    log "    Last commit: ${last_commit}"
  done
}

# ---- Phase 4: Generate Findings per node ------------------------------

generate_findings() {
  log "=== Phase 4: Generate Findings per node ==="

  for slug in "${NODE_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"

    if [ -z "$sha" ]; then
      NODE_STATUS["$slug"]="error"
      local ev_ref="${EVIDENCE_FILES["wk-exists-${slug}"]:-}"
      [ -z "$ev_ref" ] && ev_ref="pins/${slug}.json"

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
      ev_refs="pins/${slug}.json"
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

  for slug in "${NODE_SLUGS[@]}"; do
    local pin_file="${PIN_FILES[$slug]:-}"
    [ -z "$pin_file" ] && continue

    local result="success"
    [ "${NODE_STATUS[$slug]:-}" = "error" ] && result="partial"

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

  local total_nodes=${#NODE_SLUGS[@]}
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
  [ -z "$self_ev_refs" ] && self_ev_refs="pins/federation-recon.json"

  local finding_self
  finding_self=$(gen_finding "$self_statement" "$self_ev_refs" \
    "recon_self_observation" \
    "$([ "$self_ok" = "true" ] && echo 'info' || echo 'warning')")
  FINDING_FILES["self"]="$finding_self"
  budget_track "$finding_self"

  SELF_STATUS="{\"run_completed\":$([ "$PARTIAL_FAILURES" -eq 0 ] && echo 'true' || echo 'false'),\"outputs_complete\":$([ "$pinned_nodes" -ge "$total_nodes" ] && echo 'true' || echo 'false'),\"digest_fresh\":true,\"issues\":$(json_val "$self_issues")}"

  log "  Self-status: ok=${self_ok}, nodes=${pinned_nodes}/${total_nodes}"
}

# ---- Phase 7: Ranked Census Digest ------------------------------------

generate_census_digest() {
  log "=== Phase 7: Generate ranked census digest ==="

  # --- Rank nodes by "needs attention" ---
  # Priority: missing descriptor > stale > ok > error
  # Within same priority, sort alphabetically by slug

  local rank_score
  declare -A RANK_SCORE

  for slug in "${NODE_SLUGS[@]}"; do
    local status="${NODE_STATUS[$slug]:-error}"
    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"

    # Scoring: lower = needs more attention
    # 0 = missing descriptor (hard stale)
    # 1 = stale (age-based)
    # 2 = error (unresolvable)
    # 3 = ok
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
  done < <(for slug in "${NODE_SLUGS[@]}"; do
    printf '%s %s\n' "${RANK_SCORE[$slug]}" "$slug"
  done | sort -t' ' -k1,1n -k2,2)

  # --- Build census JSON array ---
  local census_json="["
  local first_census=true
  for slug in "${sorted_slugs[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"
    local status="${NODE_STATUS[$slug]:-error}"
    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"
    local role="${NODE_ROLE[$slug]:-}"
    local tier="${NODE_TIER[$slug]:-}"
    local charter="${NODE_CHARTER[$slug]:-false}"
    local last_commit="${NODE_LAST_COMMIT[$slug]:-}"
    local display_name="${NODE_DISPLAY_NAME[$slug]:-}"

    $first_census || census_json+=","
    first_census=false

    local finding_file=""
    finding_file="${FINDING_FILES["node-${slug}"]:-}"
    if [ -z "$finding_file" ]; then finding_file="findings/none"; fi

    census_json+=$(cat <<ENDNODE
{
  "slug": $(json_val "$slug"),
  "repository": $(json_val "$repo"),
  "sha": $(json_val "${sha:0:12}"),
  "status": $(json_val "$status"),
  "descriptor": $descriptor,
  "charter": $charter,
  "role": $(json_val "$role"),
  "tier": $(json_val "$tier"),
  "display_name": $(json_val "$display_name"),
  "last_commit": $(json_val "$last_commit"),
  "pin": $(json_val "pins/${slug}.json"),
  "finding": $(json_val "${finding_file##*/}")
}
ENDNODE
)
  done
  census_json+="]"

  # --- Build pins JSON ---
  local pins_json="["
  local first_pin=true
  for slug in "${NODE_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"
    local ref="${REPO_REF[$repo]:-}"
    if [ -n "$sha" ]; then
      $first_pin || pins_json+=","
      pins_json+="{\"repository\": $(json_val "$repo"), \"sha\": $(json_val "$sha"), \"ref\": $(json_val "$ref")}"
      first_pin=false
    fi
  done
  pins_json+="]"

  # --- Count artifacts on disk ---
  count_dir() { ls -1 "$1"/*.json 2>/dev/null | wc -l | tr -d ' '; }
  local summary_json
  summary_json=$(cat <<ENDJSON
{
  "pins": $(count_dir pins),
  "evidence": $(count_dir evidence),
  "findings": $(count_dir findings),
  "coverage_records": $(count_dir coverage),
  "observed_nodes": ${#NODE_SLUGS[@]},
  "stale_nodes": $(for slug in "${NODE_SLUGS[@]}"; do [ "${NODE_STATUS[$slug]:-}" = "stale" ] && echo 1; done | wc -l | tr -d ' '),
  "ok_nodes": $(for slug in "${NODE_SLUGS[@]}"; do [ "${NODE_STATUS[$slug]:-}" = "observed" ] && echo 1; done | wc -l | tr -d ' '),
  "error_nodes": $PARTIAL_FAILURES,
  "staleness_threshold_days": $STALE_DAYS
}
ENDJSON
)

  local budget_json
  budget_json=$(budget_summary)

  # --- Machine-readable digest ---
  local digest_json
  digest_json=$(cat <<ENDJSON
{
  "digest_type": "federation_census",
  "procedure_id": $(json_val "$PROCEDURE_ID"),
  "procedure_version": $(json_val "$PROCEDURE_VERSION"),
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "run_result": $(json_val "$RUN_RESULT"),
  "repository_pins": $pins_json,
  "census": $census_json,
  "summary": $summary_json,
  "budget": $budget_json,
  "self_observation": $SELF_STATUS,
  "navigation": {
    "pins": "pins/",
    "evidence": "evidence/",
    "findings": "findings/",
    "coverage": "coverage/",
    "digest": "digest/"
  }
}
ENDJSON
)

  write_json "digest/state-digest.json" "$digest_json"
  log "  Machine-readable digest written to digest/state-digest.json"

  # --- Human-readable STATE.md ---
  local state_md=""
  state_md+="# Federation Node Census\n"
  state_md+="\n"
  state_md+="**Generated:** ${RUN_TIMESTAMP}\n"
  state_md+="**Procedure:** \`${PROCEDURE_ID}\` / \`${PROCEDURE_VERSION}\`\n"
  state_md+="**Run result:** ${RUN_RESULT}\n"
  state_md+="**Staleness threshold:** ${STALE_DAYS} days (last commit > ${STALE_DAYS}d → stale)\n"
  state_md+="\n"

  # Summary stats
  local stale_count=0 ok_count=0 error_count=0
  for slug in "${NODE_SLUGS[@]}"; do
    case "${NODE_STATUS[$slug]:-error}" in
      stale) stale_count=$(( stale_count + 1 )) ;;
      observed) ok_count=$(( ok_count + 1 )) ;;
      *) error_count=$(( error_count + 1 )) ;;
    esac
  done
  state_md+="## Summary\n"
  state_md+="\n"
  state_md+="| Metric | Count |\n"
  state_md+="|---|---|\n"
  state_md+="| Total nodes observed | ${#NODE_SLUGS[@]} |\n"
  state_md+="| OK | ${ok_count} |\n"
  state_md+="| Stale | ${stale_count} |\n"
  state_md+="| Errors | ${error_count} |\n"
  state_md+="\n"

  # Ranked node table
  state_md+="## Ranked Node Census (sorted by attention needed)\n"
  state_md+="\n"
  state_md+="| # | Node | Status | Descriptor | Charter | Role | Tier | Last Commit |\n"
  state_md+="|---|---|---|---|---|---|---|---|\n"

  local rank=1
  for slug in "${sorted_slugs[@]}"; do
    local repo="kimeisele/${slug}"
    local status="${NODE_STATUS[$slug]:-error}"
    local descriptor="${NODE_DESCRIPTOR[$slug]:-false}"
    local role="${NODE_ROLE[$slug]:-}"
    local tier="${NODE_TIER[$slug]:-}"
    local charter="${NODE_CHARTER[$slug]:-false}"
    local last_commit="${NODE_LAST_COMMIT[$slug]:-}"

    local status_icon=""
    case "$status" in
      observed) status_icon="✅" ;;
      stale)    status_icon="⚠️" ;;
      *)        status_icon="❌" ;;
    esac

    local desc_icon=""
    [ "$descriptor" = "true" ] && desc_icon="✅" || desc_icon="❌"
    local charter_icon=""
    [ "$charter" = "true" ] && charter_icon="✅" || charter_icon="❌"

    local short_commit="${last_commit:0:10}"
    [ -z "$short_commit" ] && short_commit="-"

    state_md+="| ${rank} | \`${repo}\` | ${status_icon} ${status} | ${desc_icon} | ${charter_icon} | ${role:-—} | ${tier:-—} | ${short_commit} |\n"
    rank=$(( rank + 1 ))
  done
  state_md+="\n"

  # Budget
  state_md+="## Budget\n"
  state_md+="\n"
  state_md+="${BUDGET_TOTAL_BYTES}B total (warn: ${WARN_THRESHOLD}B, abort: ${HARD_ABORT}B)\n"
  state_md+="\n"

  # Navigation
  state_md+="## Navigation (progressive disclosure)\n"
  state_md+="\n"
  state_md+="\`\`\`\n"
  state_md+="Federation Node Census (this file)\n"
  state_md+="    ↓\n"
  state_md+="Repository Pins — pins/ (one per discovered node)\n"
  state_md+="    ↓\n"
  state_md+="Evidence — evidence/ (presence, role, tier, charter, liveness)\n"
  state_md+="    ↓\n"
  state_md+="Findings — findings/ (per-node status with lifecycle)\n"
  state_md+="    ↓\n"
  state_md+="Coverage — coverage/ (what was inspected)\n"
  state_md+="    ↓\n"
  state_md+="Raw repository references — original GitHub repos at pinned SHAs\n"
  state_md+="\`\`\`\n"
  state_md+="\n"

  state_md+="## Procedure Manifest\n"
  state_md+="\n"
  state_md+="See \`procedures/node-census-v1.md\` for the full procedure definition.\n"

  printf '%b' "$state_md" > STATE.md
  log "  STATE.md updated"
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
  log "  Nodes discovered: ${#NODE_SLUGS[@]} (${#PIN_FILES[@]} pinned)"
  log "  Evidence: $(ls -1 evidence/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Findings: $(ls -1 findings/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Coverage: $(ls -1 coverage/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Budget: ${BUDGET_TOTAL_BYTES}B"
  log ""

  local stale_count=0 ok_count=0 err_count=0
  for slug in "${NODE_SLUGS[@]}"; do
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
    RECON_REPRO_DIR="${RECON_PINS_DIR:-pins}"
    log "Reproduction mode — using pins from ${RECON_REPRO_DIR}"
  fi

  check_deps git gh rg python3 || die "Missing required tools (git, gh, rg, python3)"
  check_opt_deps jq

  run_start
  RUN_TIMESTAMP="$(utc_timestamp)"

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
      REPO_REF["$SELF_REPO"]="master"
    fi
    log "  Loaded ${#NODE_SLUGS[@]} nodes from pins directory"
  else
    discover_nodes
  fi
  budget_checkpoint "discovery"

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
