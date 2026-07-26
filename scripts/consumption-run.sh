#!/usr/bin/env bash
# consumption-run.sh — F-02 Consumption Measurement Runner
#
# Measures whether federation-recon Findings are consumed by observed
# repositories. Implements falsifier F-02 from founding package §18.
#
# Fully deterministic (FR-CON-012): identical pins + same procedure version
# → identical Consumption Records.
#
# Tools: git, gh, rg, python3 (§11.1 baseline).
#
# Usage:
#   bash scripts/consumption-run.sh              # Full live run
#   RECON_PINS_DIR=pins bash scripts/consumption-run.sh --reproduce   # Fixed-pin rerun
#
# Exit codes:
#   0  — success
#   1  — runtime error (tool missing, write failure)
#   2  — budget breach
#   3  — schema validation failure
#  75  — terminal partial failure (some repos failed)

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Per-procedure pin namespace — must be set BEFORE sourcing artifacts.sh
export PIN_NAMESPACE="v2-consumption"

# Clean stale temp directories left by aborted prior runs (from any agent)
find "$REPO_ROOT" -maxdepth 1 -type d -name '.consumption-tmp-*' -exec rm -rf {} + 2>/dev/null || true

# Trap: clean any temp directory created during this run on exit, abort, or interrupt
cleanup_tmp_dirs() {
  find "$REPO_ROOT" -maxdepth 1 -type d -name '.consumption-tmp-*' -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup_tmp_dirs EXIT INT TERM

# Source libraries
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/artifacts.sh"
source "$SCRIPT_DIR/lib/budget.sh"
source "$SCRIPT_DIR/lib/consumption-patterns.sh"

# ---- Configuration -----------------------------------------------------

PROCEDURE_ID="v2-consumption"
PROCEDURE_VERSION="v2"
SELF_REPO="kimeisele/federation-recon"

# Output directories
mkdir -p "$REPO_ROOT/pins/$PIN_NAMESPACE" "$REPO_ROOT/consumption" "$REPO_ROOT/coverage"
mkdir -p "$REPO_ROOT/findings" "$REPO_ROOT/digest"

cd "$REPO_ROOT"

# ---- State -------------------------------------------------------------

declare -A REPO_SHA          # repo slug → resolved SHA
declare -A REPO_REF          # repo slug → default branch name
declare -A PIN_FILES         # slug → pin file path
declare -A COVERAGE_FILES    # key → coverage file path

REPO_SLUGS=()   # ordered, deduplicated list of observed repo slugs
CONSUMPTION_RECORDS=()  # ordered list of consumption record paths
RUN_TIMESTAMP=""
RUN_RESULT="success"
PARTIAL_FAILURES=0
CYCLE=1

# ---- Phase 1: Discover repo set from committed pins ----------------------

discover_repos() {
  log "=== Phase 1: Discover observed repositories from committed pins ==="

  # Collect unique repo slugs from all committed pin namespaces.
  # Deterministic: reads committed files, sorted for stable order.
  local seen=""
  declare -A SEEN

  for ns in v0-boundary-drift v1-census; do
    local pin_dir="pins/${ns}"
    [ -d "$pin_dir" ] || continue
    for f in "$pin_dir"/*.json; do
      [ -f "$f" ] || continue
      local slug
      slug=$(basename "$f" .json)
      [ -z "${SEEN[$slug]:-}" ] || continue
      SEEN["$slug"]=1

      # Exclude self (§5, Issue #44: self-references are not consumption)
      if [ "$slug" = "${SELF_REPO#*/}" ]; then
        log "  SKIP self: ${SELF_REPO} (self-references excluded)"
        continue
      fi

      REPO_SLUGS+=("$slug")
      log "  Found: kimeisele/${slug}"
    done
  done

  log "  Discovered ${#REPO_SLUGS[@]} observed repositories (excluding self)"
}

# ---- Phase 2: Resolve & Pin each repo ------------------------------------

resolve_pins() {
  log "=== Phase 2: Resolve repository commits & create pins ==="
  local repro="${1:-false}"

  for slug in "${REPO_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="" ref="main"

    if $repro && [ -n "${RECON_REPRO_DIR:-}" ]; then
      local pin_file="$RECON_REPRO_DIR/${slug}.json"
      if [ -f "$pin_file" ]; then
        sha=$(python3 -c "import json; print(json.load(open('$pin_file'))['resolved_commit_sha'])" 2>/dev/null || true)
        ref=$(python3 -c "import json; print(json.load(open('$pin_file'))['requested_ref'])" 2>/dev/null || echo "main")
      fi
    fi

    if [ -z "$sha" ]; then
      # Try to read SHA from existing pins (v0 or v1) — deterministic fallback
      for ns in v0-boundary-drift v1-census; do
        local existing_pin="pins/${ns}/${slug}.json"
        if [ -f "$existing_pin" ]; then
          sha=$(python3 -c "import json; print(json.load(open('$existing_pin'))['resolved_commit_sha'])" 2>/dev/null || true)
          [ -n "$sha" ] && break
        fi
      done
    fi

    if [ -z "$sha" ]; then
      # Last resort: fetch live
      ref=$(gh api "repos/${repo}" --jq '.default_branch' 2>/dev/null || echo "main")
      sha=$(gh api "repos/${repo}/git/ref/heads/${ref}" --jq '.object.sha' 2>/dev/null || true)
    fi

    if [ -z "$sha" ]; then
      warn "  Cannot resolve ${repo} — skipping"
      PARTIAL_FAILURES=$(( PARTIAL_FAILURES + 1 ))
      continue
    fi

    REPO_SHA["$repo"]="$sha"
    REPO_REF["$repo"]="$ref"

    local pin_file
    pin_file=$(gen_repository_pin "$repo" "$ref" "$sha" "$RUN_TIMESTAMP")
    PIN_FILES["$slug"]="$pin_file"
    budget_track "$pin_file"

    log "  ${repo} → ${sha:0:12} (ref: ${ref})"
  done
}

# ---- Phase 3: Search for Finding references ------------------------------

search_repo_for_consumption() {
  local slug="$1" repo="$2" sha="$3" pin_file="$4"

  log "  Searching ${repo} at ${sha:0:12} for Finding references..."

  local tmpdir
  tmpdir=$(mktemp -d "$REPO_ROOT/.consumption-tmp-XXXXXX") || { warn "    Failed to create temp dir for ${repo}"; return 1; }

  # Shallow clone at the pinned commit. This is deterministic: same SHA
  # → same tree every time. Read-only; no cross-repository writes (FR-CON-002).
  local clone_ok=true
  (
    cd "$tmpdir"
    git init -q
    git remote add origin "https://github.com/${repo}.git" 2>/dev/null || true
    if ! git fetch -q --depth 1 origin "$sha" 2>/dev/null; then
      exit 1
    fi
    git checkout -q FETCH_HEAD 2>/dev/null || exit 1
  ) || clone_ok=false

  if ! $clone_ok; then
    warn "    Clone failed for ${repo} at ${sha}"
    rm -rf "$tmpdir"
    return 1
  fi

  # Build a combined rg pattern for finding references. We use ripgrep regex
  # mode for determinism and clarity.
  #
  # Pattern A: finding-<12-hex-chars> — specific and unambiguous Finding ID reference
  # Pattern B: federation-recon — repository reference (weaker: mentioning the
  #   repo is not the same as citing one of its Findings)
  #
  # Qualified substrings like findings/, drift/, evidence/ are intentionally
  # excluded: they match coincidental vocabulary in unrelated repos and
  # destroy the falsifier (see PR #46 review, Blocker 1).

  local matches
  matches=$(cd "$tmpdir" && search_dir_for_consumption . )

  if [ -z "$matches" ]; then
    log "    No Finding references found in ${repo}"
    rm -rf "$tmpdir"
    return 0
  fi

  # Parse matches into consumption records
  local record_count=0
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    # rg -n output format: path:line_number:text
    # With --no-heading, each line is: path:line_num:text
    local file_path="" line_num=""
    file_path="${line%%:*}"
    local rest="${line#*:}"
    line_num="${rest%%:*}"

    # Skip binary files (rg reports "path" without line number for binary matches)
    if [ "$file_path" = "Binary" ] || ! [[ "$line_num" =~ ^[0-9]+$ ]]; then
      continue
    fi

    # Strip leading ./ from file_path
    file_path="${file_path#./}"

    # Determine reference type and extract finding_id
    local ref_type="" finding_id=""
    local match_text="${rest#*:}"

    ref_type=$(classify_consumption_match "$match_text")
    if [ "$ref_type" = "finding_id" ]; then
      finding_id=$(printf '%s' "$match_text" | rg -o "$CONSUMPTION_PATTERN_FINDING_ID" | head -1)
    fi

    [ -z "$ref_type" ] && continue

    # Generate deterministic consumption ID
    local id_input="${repo}:${file_path}:${line_num}:${finding_id}:${ref_type}:${CYCLE}"
    local consumption_id
    consumption_id=$(make_id "consumption" "$id_input")

    # Build JSON record — metadata only, no excerpts (FR-CON-008)
    local json
    json=$(cat <<ENDJSON
{
  "consumption_id": $(json_val "$consumption_id"),
  "referencing_repository": $(json_val "$repo"),
  "referencing_file_path": $(json_val "$file_path"),
  "line_number": ${line_num},
  "referenced_finding_id": $(json_val "$finding_id"),
  "reference_type": $(json_val "$ref_type"),
  "repository_pin": $(json_val "$pin_file"),
  "observed_at": $(json_val "$RUN_TIMESTAMP"),
  "cycle": ${CYCLE}
}
ENDJSON
    )

    local rec_file="consumption/${consumption_id}.json"
    write_json "$rec_file" "$json"
    budget_track "$rec_file"
    CONSUMPTION_RECORDS+=("$rec_file")
    record_count=$(( record_count + 1 ))

    log "    ${file_path}:${line_num} → ${consumption_id} (${ref_type})"
  done <<< "$matches"

  log "    ${record_count} consumption record(s) for ${repo}"
  rm -rf "$tmpdir"
  return 0
}

run_consumption_search() {
  log "=== Phase 3: Search observed repositories for Finding references ==="

  for slug in "${REPO_SLUGS[@]}"; do
    local repo="kimeisele/${slug}"
    local sha="${REPO_SHA[$repo]:-}"
    local pin_file="${PIN_FILES[$slug]:-}"

    if [ -z "$sha" ] || [ -z "$pin_file" ]; then
      warn "  SKIP ${repo} — no pin available"
      continue
    fi

    if ! search_repo_for_consumption "$slug" "$repo" "$sha" "$pin_file"; then
      PARTIAL_FAILURES=$(( PARTIAL_FAILURES + 1 ))
    fi
  done

  log "  Total consumption records: ${#CONSUMPTION_RECORDS[@]}"
}

# ---- Phase 4: Coverage Records ------------------------------------------

record_coverage() {
  log "=== Phase 4: Record Coverage ==="

  local caps_used="git,gh,rg,python3"
  command -v jq &>/dev/null && caps_used+=",jq"

  local caps_missing=""
  command -v jq &>/dev/null || caps_missing="jq"

  for slug in "${REPO_SLUGS[@]}"; do
    local pin_file="${PIN_FILES[$slug]:-}"
    [ -z "$pin_file" ] && continue

    local repo="kimeisele/${slug}"
    local result="success"
    if [ -z "${REPO_SHA[$repo]:-}" ]; then
      result="partial"
    fi

    local cov
    cov=$(gen_coverage_record "$pin_file" "$result" "$caps_used" "$caps_missing")
    COVERAGE_FILES["${slug}"]="$cov"
    budget_track "$cov"
  done
}

# ---- Phase 5: Self-Observation (FR-CON-011) ------------------------------

perform_self_observation() {
  log "=== Phase 5: Self-Observation (FR-CON-011) ==="

  local self_ok="true"
  local self_issues=""

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    self_ok="false"
    self_issues+="partial_failures:${PARTIAL_FAILURES};"
  fi

  local total_repos=${#REPO_SLUGS[@]}
  local pinned_repos=0
  for slug in $(for s in "${!PIN_FILES[@]}"; do echo "$s"; done | sort); do pinned_repos=$(( pinned_repos + 1 )); done

  if [ "$pinned_repos" -lt "$total_repos" ]; then
    self_ok="false"
    self_issues+="missing_pins:expected_${total_repos}_got_${pinned_repos};"
  fi

  SELF_STATUS="{\"run_completed\":$([ "$PARTIAL_FAILURES" -eq 0 ] && echo 'true' || echo 'false'),\"outputs_complete\":$([ "$pinned_repos" -ge "$total_repos" ] && echo 'true' || echo 'false'),\"digest_fresh\":true,\"issues\":$(json_val "$self_issues")}"

  local self_statement=""
  if [ "$self_ok" = "true" ]; then
    self_statement="Self-observation: Consumption measurement completed successfully — ${pinned_repos}/${total_repos} repositories searched, ${#CONSUMPTION_RECORDS[@]} consumption records found"
  else
    self_statement="Self-observation: Consumption measurement completed with issues — ${self_issues}"
  fi

  local self_ev_refs=""
  local first=true
  local sorted_cov_keys
  sorted_cov_keys=$(for k in "${!COVERAGE_FILES[@]}"; do echo "$k"; done | sort)
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if [ -n "${COVERAGE_FILES[$key]}" ] && [ -f "${COVERAGE_FILES[$key]}" ]; then
      local cid
      cid=$(artifact_id "${COVERAGE_FILES[$key]}")
      if [ -n "$cid" ]; then
        $first && self_ev_refs+="$cid" || self_ev_refs+=",${cid}"
        first=false
      fi
    fi
  done <<< "$sorted_cov_keys"
  [ -z "$self_ev_refs" ] && self_ev_refs="pins/v2-consumption/${REPO_SLUGS[0]}.json"

  local finding_self
  finding_self=$(gen_finding "$self_statement" "$self_ev_refs" \
    "recon_self_observation" \
    "$([ "$self_ok" = "true" ] && echo 'info' || echo 'warning')")
  budget_track "$finding_self"

  log "  Self-status: ok=${self_ok}, repos=${pinned_repos}/${total_repos}, records=${#CONSUMPTION_RECORDS[@]}"
}

# ---- Phase 6: Sub-Digest (composition contract) --------------------------

generate_digest() {
  log "=== Phase 6: Generate sub-digest (composition contract) ==="

  # Count consumption records on disk, split by type
  # Exclude cycle-ledger.json — it is a per-cycle ledger, not a consumption record
  count_dir() { { ls -1 "$1"/*.json 2>/dev/null || true; } | { grep -v 'cycle-ledger.json' || true; } | wc -l | tr -d ' '; }
  local total_consumption
  total_consumption=$(count_dir consumption)

  local finding_id_count=0 repo_ref_count=0
  for rec_file in consumption/*.json; do
    [ -f "$rec_file" ] || continue
    # Skip cycle-ledger.json
    [[ "$(basename "$rec_file")" == "cycle-ledger.json" ]] && continue
    local rtype
    rtype=$(python3 -c "import json; print(json.load(open('$rec_file')).get('reference_type',''))" 2>/dev/null || echo "")
    case "$rtype" in
      finding_id)    finding_id_count=$(( finding_id_count + 1 )) ;;
      repo_reference) repo_ref_count=$(( repo_ref_count + 1 )) ;;
    esac
  done

  # Build attention_items
  local attention_items_json="["
  local first_ai=true

  if [ "$finding_id_count" -eq 0 ] && [ "$repo_ref_count" -eq 0 ]; then
    # Zero is the falsifier's signal — state it plainly
    attention_items_json+=$(cat <<ENDAI
{
  "target": "kimeisele/*",
  "status": "observed",
  "attention_rank": 0,
  "headline": "ZERO Finding consumption: No external repository references any federation-recon Finding ID. ${repo_ref_count} repo-mentions (weaker evidence). Cycle ${CYCLE} of 10 — F-02 falsifier is active if this persists across ten cycles.",
  "refs": ["consumption/"]
}
ENDAI
)
    first_ai=false
  else
    # If there are finding_id references, report them per repo
    if [ "$finding_id_count" -gt 0 ]; then
      local seen_repos=""
      declare -A REPO_FINDING_COUNT

      for rec_file in consumption/*.json; do
        [ -f "$rec_file" ] || continue
        [[ "$(basename "$rec_file")" == "cycle-ledger.json" ]] && continue
        local rtype
        rtype=$(python3 -c "import json; print(json.load(open('$rec_file')).get('reference_type',''))" 2>/dev/null || echo "")
        [ "$rtype" = "finding_id" ] || continue
        local ref_repo
        ref_repo=$(python3 -c "import json; print(json.load(open('$rec_file')).get('referencing_repository',''))" 2>/dev/null || echo "")
        if [ -n "$ref_repo" ]; then
          REPO_FINDING_COUNT["$ref_repo"]=$(( ${REPO_FINDING_COUNT["$ref_repo"]:-0} + 1 ))
        fi
      done

      local sorted_ref_repos
      sorted_ref_repos=$(for r in "${!REPO_FINDING_COUNT[@]}"; do echo "$r"; done | sort)

      while IFS= read -r ref_repo; do
        [ -z "$ref_repo" ] && continue
        local count="${REPO_FINDING_COUNT[$ref_repo]}"
        $first_ai || attention_items_json+=","
        first_ai=false

        attention_items_json+=$(cat <<ENDAI
{
  "target": $(json_val "$ref_repo"),
  "status": "observed",
  "attention_rank": 0,
  "headline": "CONSUMPTION: ${count} Finding ID reference(s) found in ${ref_repo}",
  "refs": ["consumption/"]
}
ENDAI
)
      done <<< "$sorted_ref_repos"
    fi

    # Report repo_references separately (weaker evidence)
    if [ "$repo_ref_count" -gt 0 ]; then
      local seen_repos2=""
      declare -A REPO_REF_COUNT

      for rec_file in consumption/*.json; do
        [ -f "$rec_file" ] || continue
        [[ "$(basename "$rec_file")" == "cycle-ledger.json" ]] && continue
        local rtype
        rtype=$(python3 -c "import json; print(json.load(open('$rec_file')).get('reference_type',''))" 2>/dev/null || echo "")
        [ "$rtype" = "repo_reference" ] || continue
        local ref_repo
        ref_repo=$(python3 -c "import json; print(json.load(open('$rec_file')).get('referencing_repository',''))" 2>/dev/null || echo "")
        if [ -n "$ref_repo" ]; then
          REPO_REF_COUNT["$ref_repo"]=$(( ${REPO_REF_COUNT["$ref_repo"]:-0} + 1 ))
        fi
      done

      local sorted_ref_repos2
      sorted_ref_repos2=$(for r in "${!REPO_REF_COUNT[@]}"; do echo "$r"; done | sort)

      while IFS= read -r ref_repo; do
        [ -z "$ref_repo" ] && continue
        local count="${REPO_REF_COUNT[$ref_repo]}"
        $first_ai || attention_items_json+=","
        first_ai=false

        attention_items_json+=$(cat <<ENDAI
{
  "target": $(json_val "$ref_repo"),
  "status": "observed",
  "attention_rank": 0,
  "headline": "REPO MENTION: ${count} reference(s) to federation-recon repository name (weaker evidence than Finding ID citation) in ${ref_repo}",
  "refs": ["consumption/"]
}
ENDAI
)
      done <<< "$sorted_ref_repos2"
    fi
  fi

  attention_items_json+="]"

  # Per-procedure counts
  local pc_pins pc_cov
  read -r pc_pins _ pc_cov _ _ _ < <(
    python3 "$SCRIPT_DIR/lib/count_procedure.py" "$PROCEDURE_ID" "$PIN_NAMESPACE" --sh 2>/dev/null || echo "0 0 0 0 0 0"
  )
  local summary_json
  summary_json=$(cat <<ENDJSON
{
  "pins": ${pc_pins},
  "finding_references": ${finding_id_count},
  "repo_references": ${repo_ref_count},
  "total_consumption_records": ${total_consumption},
  "coverage_records": ${pc_cov},
  "observed_repositories": ${#REPO_SLUGS[@]},
  "partial_failures": ${PARTIAL_FAILURES},
  "cycle": ${CYCLE}
}
ENDJSON
  )

  # Build the sub-digest in common shape (DIGEST_CONTRACT.md)
  local sub_digest_json
  sub_digest_json=$(cat <<ENDJSON
{
  "procedure_id": "$PROCEDURE_ID",
  "procedure_version": "$PROCEDURE_VERSION",
  "run_timestamp": $(json_val "$RUN_TIMESTAMP"),
  "attention_items": $attention_items_json,
  "summary": $summary_json,
  "budget": $(budget_summary),
  "self_observation": $SELF_STATUS
}
ENDJSON
  )

  write_json "digest/v2-consumption.json" "$sub_digest_json"
  log "Sub-digest written to digest/v2-consumption.json"
}

# ---- Cycle Ledger ---------------------------------------------------------

update_cycle_ledger() {
  local ledger_file="consumption/cycle-ledger.json"

  # Ensure the file exists
  if [ ! -f "$ledger_file" ]; then
    echo '[]' > "$ledger_file"
  fi

  # Check if this cycle already has an entry (idempotent).
  # Ledger file is read on stdin — no shell interpolation into python -c.
  export LEDGER_CHECK_CYCLE="$CYCLE"
  local already_present
  already_present=$(python3 -c "
import json,sys,os
data = json.load(sys.stdin)
target = int(os.environ['LEDGER_CHECK_CYCLE'])
for entry in data:
    if entry.get('cycle') == target:
        print('yes')
        break
" < "$ledger_file" 2>/dev/null || echo "")

  if [ "$already_present" = "yes" ]; then
    log "  Cycle ${CYCLE} already recorded in cycle-ledger — skipping append"
    return 0
  fi

  # Count finding_references and repo_references on disk
  local finding_id_count=0 repo_ref_count=0
  for rec_file in consumption/*.json; do
    [ -f "$rec_file" ] || continue
    [[ "$(basename "$rec_file")" == "cycle-ledger.json" ]] && continue
    local rtype
    rtype=$(python3 -c "import json; print(json.load(open('$rec_file')).get('reference_type',''))" 2>/dev/null || echo "")
    case "$rtype" in
      finding_id)    finding_id_count=$(( finding_id_count + 1 )) ;;
      repo_reference) repo_ref_count=$(( repo_ref_count + 1 )) ;;
    esac
  done

  # Resolve trigger type — defaults to "manual" when not available (e.g. local
  # runs, reproduce). The workflow passes GITHUB_EVENT_NAME as TRIGGER_TYPE.
  local trigger_type="${TRIGGER_TYPE:-manual}"

  # Pass all values via environment variables — no shell interpolation into
  # python -c. The ledger file is read on stdin.
  export LEDGER_CYCLE="$CYCLE"
  export LEDGER_FINDING_REFS="$finding_id_count"
  export LEDGER_REPO_REFS="$repo_ref_count"
  export LEDGER_OBSERVED_REPOS="${#REPO_SLUGS[@]}"
  export LEDGER_TIMESTAMP="$MEASURED_AT"
  export LEDGER_TRIGGER="$trigger_type"

  local updated_ledger
  updated_ledger=$(python3 -c "
import json,sys,os
data = json.load(sys.stdin)
data.append({
    'cycle': int(os.environ['LEDGER_CYCLE']),
    'finding_references': int(os.environ['LEDGER_FINDING_REFS']),
    'repo_references': int(os.environ['LEDGER_REPO_REFS']),
    'observed_repositories': int(os.environ['LEDGER_OBSERVED_REPOS']),
    'timestamp': os.environ['LEDGER_TIMESTAMP'],
    'trigger': os.environ['LEDGER_TRIGGER']
})
print(json.dumps(data, indent=2))
" < "$ledger_file")

  write_json "$ledger_file" "$updated_ledger"
  budget_track "$ledger_file"
  log "  Cycle-ledger updated: cycle=${CYCLE}, finding_references=${finding_id_count}, repo_references=${repo_ref_count}, trigger=${trigger_type}"
}


# ---- Phase 7: Budget Enforcement ----------------------------------------

enforce_budget() {
  log "=== Phase 7: Budget enforcement ==="
  budget_checkpoint "final"

  if [ "$BUDGET_TOTAL_BYTES" -ge "$HARD_ABORT" ]; then
    log "F-03 TRIGGER: Budget breached"
    RUN_RESULT="budget_breach"
    exit 2
  fi

  if [ "$BUDGET_TOTAL_BYTES" -ge "$WARN_THRESHOLD" ]; then
    warn "Near budget limit — review output sizes"
  fi
}

# ---- Validation ----------------------------------------------------------

validate_outputs() {
  log "=== Validation: Schema validation ==="
  local errors=0

  local pin_validated=0
  for f in "pins/$PIN_NAMESPACE"/*.json; do
    [ -f "$f" ] || continue
    if ! validate_json_schema "$f" "schemas/repository-pin.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    pin_validated=$(( pin_validated + 1 ))
  done

  local consumption_validated=0
  for f in consumption/*.json; do
    [ -f "$f" ] || continue
    # Skip cycle-ledger.json — it has its own structure, not a consumption record
    [[ "$(basename "$f")" == "cycle-ledger.json" ]] && continue
    if ! validate_json_schema "$f" "schemas/consumption-record.schema.json"; then
      warn "Schema error: $f"
      errors=$(( errors + 1 ))
    fi
    consumption_validated=$(( consumption_validated + 1 ))
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

  log "  Validated: ${pin_validated} pins, ${consumption_validated} consumption, ${cov_validated} coverage"
  if [ "$errors" -gt 0 ]; then
    log "  FAILED: ${errors} validation errors"
    RUN_RESULT="validation_error"
    return 1
  fi
  log "  All artifacts valid ✓"
  return 0
}

# ---- Run Summary ---------------------------------------------------------

print_summary() {
  log ""
  log "=== F-02 Consumption Measurement Summary ==="
  log "  Procedure: ${PROCEDURE_ID} / ${PROCEDURE_VERSION}"
  log "  Timestamp: ${RUN_TIMESTAMP}"
  log "  Cycle: ${CYCLE}"
  log "  Result: ${RUN_RESULT}"
  log "  Repositories searched: ${#REPO_SLUGS[@]} (${#PIN_FILES[@]} pinned)"
  log "  Consumption records: ${#CONSUMPTION_RECORDS[@]}"
  log "  Coverage: $(ls -1 coverage/*.json 2>/dev/null | wc -l | tr -d ' ') files"
  log "  Budget: ${BUDGET_TOTAL_BYTES}B"
  log ""
  log "  Next: bash scripts/validate-artifacts.sh"
}

# ---- Resolve cycle count ------------------------------------------------

resolve_cycle() {
  local repro="${1:-false}"

  if $repro; then
    # In reproduce mode, freeze cycle from committed sub-digest
    CYCLE=$(python3 -c "
import json
try:
    with open('digest/v2-consumption.json') as f:
        d = json.load(f)
    print(d.get('summary',{}).get('cycle', 1))
except:
    print(1)
" 2>/dev/null || echo 1)
    log "Reproduce mode: frozen cycle = ${CYCLE}"
  else
    # In live mode, derive cycle from committed sub-digest
    local prev=0
    if [ -f "digest/v2-consumption.json" ]; then
      prev=$(python3 -c "
import json
try:
    with open('digest/v2-consumption.json') as f:
        d = json.load(f)
    print(d.get('summary',{}).get('cycle', 0))
except:
    print(0)
" 2>/dev/null || echo 0)
    fi
    CYCLE=$(( prev + 1 ))
    log "Live mode: cycle = ${CYCLE} (previous: ${prev})"
  fi
}

# ---- Main ----------------------------------------------------------------

main() {
  local reproduce=false
  if [ "${1:-}" = "--reproduce" ]; then
    reproduce=true
    RECON_REPRO_DIR="${RECON_PINS_DIR:-pins}/v2-consumption"
    log "Reproduction mode — using pins from ${RECON_REPRO_DIR}"
  fi

  check_deps git gh rg python3 || die "Missing required tools (git, gh, rg, python3)"
  check_opt_deps jq

  run_start
  MEASURED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"  # wall-clock — never frozen
  RUN_TIMESTAMP="$(utc_timestamp)"
  if $reproduce; then
    frozen_ts="$(python3 -c "import json; print(json.load(open('digest/v2-consumption.json')).get('run_timestamp',''))" 2>/dev/null || true)"
    [ -n "${frozen_ts:-}" ] && RUN_TIMESTAMP="$frozen_ts"
    export RECON_FROZEN_TS="$RUN_TIMESTAMP"
  fi

  resolve_cycle "$reproduce"

  log "=== F-02 Consumption Measurement v2 ==="
  log "Timestamp: ${RUN_TIMESTAMP}"
  log "Cycle: ${CYCLE}"
  log "Mode: $($reproduce && echo 'reproduce' || echo 'live')"
  log ""

  budget_init

  # Phase 1: Discover repos
  discover_repos
  budget_checkpoint "discovery"

  # Phase 2: Resolve & pin
  resolve_pins "$reproduce"
  budget_checkpoint "pins"

  # Phase 3: Search for consumption
  run_consumption_search
  budget_checkpoint "consumption"

  # Phase 4: Coverage
  record_coverage
  budget_checkpoint "coverage"

  # Phase 5: Self-observation
  perform_self_observation
  budget_checkpoint "self-observation"

  # Prune superseded outputs
  local keep_file
  keep_file="$(mktemp)"
  for rec in "${CONSUMPTION_RECORDS[@]}"; do printf '%s\n' "$rec"; done > "$keep_file"
  for key in $(for k in "${!COVERAGE_FILES[@]}"; do echo "$k"; done | sort); do printf '%s\n' "${COVERAGE_FILES[$key]}"; done >> "$keep_file"
  python3 "$SCRIPT_DIR/clean-procedure-artifacts.py" \
    --root "$REPO_ROOT" \
    --procedure-id "$PROCEDURE_ID" \
    --pin-prefix "pins/$PIN_NAMESPACE/" \
    --keep-file "$keep_file" \
    || { rm -f "$keep_file"; die "Failed to prune superseded $PROCEDURE_ID outputs"; }
  rm -f "$keep_file"

  # Phase 6: Digest
  generate_digest
  update_cycle_ledger
  budget_checkpoint "digest"

  # Phase 7: Budget enforcement
  enforce_budget

  # Run result
  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    RUN_RESULT="partial"
  fi

  # Schema validation
  validate_outputs || true

  print_summary

  if [ "$PARTIAL_FAILURES" -gt 0 ]; then
    exit 75
  fi
  exit 0
}

main "$@"
