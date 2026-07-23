#!/usr/bin/env bash
# digest.sh — Federation Digest generation for federation-recon.
#
# Source after helpers.sh and artifacts.sh. Provides:
#   gen_machine_digest, gen_state_md

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# ---- Machine-readable digest -------------------------------------------
# gen_machine_digest <run_ts> <run_result> <pins_json> <summary_counts_json> <budget_json> <self_status_json>
#   pins_json: JSON array of {repo, sha, ref}
#   summary_counts_json: JSON object of artifact counts
#   budget_json: output of budget_summary
#   self_status_json: JSON object with self-observation status
gen_machine_digest() {
  local run_ts="$1" run_result="$2" pins_json="$3" summary_json="$4" budget_json="$5" self_status_json="$6"

  local digest
  digest=$(cat <<ENDJSON
{
  "digest_type": "federation",
  "procedure_id": "boundary-drift-recon-v0",
  "procedure_version": "v0",
  "run_timestamp": $(json_val "$run_ts"),
  "run_result": $(json_val "$run_result"),
  "repository_pins": $pins_json,
  "summary": $summary_json,
  "budget": $budget_json,
  "self_observation": $self_status_json,
  "navigation": {
    "pins": "pins/",
    "claims": "claims/",
    "evidence": "evidence/",
    "drift": "drift/",
    "findings": "findings/",
    "coverage": "coverage/",
    "digest": "digest/"
  }
}
ENDJSON
  )

  local file="digest/state-digest.json"
  write_json "$file" "$digest"
  log "Machine-readable digest written to $file"
  printf '%s' "$file"
}

# ---- Human-readable STATE.md -------------------------------------------
# gen_state_md <run_ts> <run_result> <pins_list> <findings_summary> <drift_summary> <self_status> <budget_summary>
gen_state_md() {
  local run_ts="$1" run_result="$2" pins_list="$3" findings_summary="$4" drift_summary="$5" self_status="$6" budget_line="$7"

  cat > STATE.md <<ENDMD
# Federation Digest

**Generated:** $run_ts
**Procedure:** \`boundary-drift-recon-v0\` / \`v0\`
**Run result:** $run_result
**Self-observation status:** $self_status

## Observed repositories

$pins_list

## Findings summary

$findings_summary

## Drift summary

$drift_summary

## Budget

$budget_line

## Navigation (progressive disclosure)

\`\`\`
Federation Digest (this file)
    ↓
Repository Pins — pins/ (one per observed repo)
    ↓
Claim Observations — claims/ (extracted from claim sources)
    ↓
Evidence — evidence/ (deterministic observations)
    ↓
Drift Records — drift/ (where claim ≠ observation)
    ↓
Findings — findings/ (interpreted observations)
    ↓
Coverage — coverage/ (what was inspected)
    ↓
Raw repository references — original GitHub repos at pinned SHAs
\`\`\`

## Links

| Artifact | Directory | Schema |
|---|---|---|
| Repository Pins | \`pins/\` | \`schemas/repository-pin.schema.json\` |
| Claim Observations | \`claims/\` | \`schemas/claim-observation.schema.json\` |
| Evidence | \`evidence/\` | \`schemas/evidence.schema.json\` |
| Drift Records | \`drift/\` | \`schemas/drift-record.schema.json\` |
| Findings | \`findings/\` | \`schemas/finding.schema.json\` |
| Coverage Records | \`coverage/\` | \`schemas/coverage-record.schema.json\` |
| Machine-readable Digest | \`digest/state-digest.json\` | — |

## Procedure Manifest

See \`procedures/boundary-drift-recon-v0.md\` for the full procedure definition.
ENDMD
  log "STATE.md updated"
}
