#!/usr/bin/env bash
# compose-digest.sh — Federation Digest Composer (slice-v2)
#
# Reads all digest/<procedure_id>.json sub-digests and produces:
#   - STATE.md           — human-readable ranked attention table
#   - digest/state-digest.json — machine-readable merged digest
#
# Fully deterministic (FR-CON-012): composer output = pure function of input
# sub-digests. No wall-clock timestamps, no LLM, no external I/O except reads.
#
# Usage:
#   bash scripts/compose-digest.sh
#
# Exit codes:
#   0 — success
#   1 — no sub-digests found or write failure
#   2 — JSON parse error in a sub-digest

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/helpers.sh"

cd "$REPO_ROOT"

# ---- Configuration -----------------------------------------------------

# Constitutional non-peers (§5): repositories deliberately not federation peers.
# The composer groups attention items targeting these into a separate section.
declare -a CONSTITUTIONAL_NON_PEERS=(
  "kimeisele/federation-recon"
)

# ---- JSON parsing (python3, deterministic) ----------------------------

# extract_field <json_string> <field> — output JSON field value (raw)
extract_field() {
  local json="$1" field="$2"
  python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d.get('$field','')))
" <<< "$json" 2>/dev/null || echo '""'
}

# parse_sub_digest <file> — parse one sub-digest file, output normalized JSON line
parse_sub_digest() {
  local file="$1"
  python3 -c "
import json, sys, os

with open('$file') as f:
    d = json.load(f)

pid = d.get('procedure_id', os.path.basename('$file').replace('.json',''))
pv  = d.get('procedure_version', '?')
ts  = d.get('run_timestamp', '')
items = d.get('attention_items', [])
summary = d.get('summary', {})

# Normalize each attention item
norm_items = []
for it in items:
    norm_items.append({
        'target': it.get('target', ''),
        'status': it.get('status', 'observed'),
        'attention_rank': int(it.get('attention_rank', 99)),
        'headline': it.get('headline', ''),
        'refs': it.get('refs', []),
        'non_peer': it.get('non_peer', False),
        'procedure_id': pid,
        'procedure_version': pv
    })

output = {
    'procedure_id': pid,
    'procedure_version': pv,
    'run_timestamp': ts,
    'attention_items': norm_items,
    'summary': summary
}
print(json.dumps(output))
" 2>/dev/null
}

# ---- Composition -------------------------------------------------------

compose() {
  log "=== Federation Digest Composer ==="

  mkdir -p digest

  # Collect all sub-digests (exclude state-digest.json which is the output)
  local sub_files=()
  for f in digest/*.json; do
    [ -f "$f" ] || continue
    local bn
    bn=$(basename "$f")
    [ "$bn" = "state-digest.json" ] && continue
    [ "$bn" = "census-run-state.json" ] && continue  # internal state, not a sub-digest
    sub_files+=("$f")
  done

  if [ ${#sub_files[@]} -eq 0 ]; then
    log "No sub-digests found in digest/ — nothing to compose"
    exit 1
  fi

  log "Found ${#sub_files[@]} sub-digest(s):"
  for f in "${sub_files[@]}"; do
    log "  - $f"
  done

  # Parse all sub-digests and collect into a merged structure
  local all_items_json="["
  local procedures_json="["
  local first_proc=true
  local newest_ts=""

  for f in "${sub_files[@]}"; do
    local parsed
    parsed=$(parse_sub_digest "$f")

    local pid pv ts items summary
    pid=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['procedure_id'])" <<< "$parsed" 2>/dev/null || echo "?")
    pv=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['procedure_version'])" <<< "$parsed" 2>/dev/null || echo "?")
    ts=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['run_timestamp'])" <<< "$parsed" 2>/dev/null || echo "")
    summary=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['summary']))" <<< "$parsed" 2>/dev/null || echo "{}")

    # Track newest timestamp
    if [ -z "$newest_ts" ] || [[ "$ts" > "$newest_ts" ]]; then
      newest_ts="$ts"
    fi

    # Add procedure section
    $first_proc || procedures_json+=","
    first_proc=false
    procedures_json+="{\"procedure_id\":\"$pid\",\"procedure_version\":\"$pv\",\"run_timestamp\":\"$ts\",\"summary\":$summary}"

    # Collect attention items
    local pitems
    pitems=$(python3 -c "
import json, sys
d = json.load(sys.stdin)
items = d.get('attention_items', [])
for it in items:
    it['procedure_id'] = d['procedure_id']
    it['procedure_version'] = d['procedure_version']
print(json.dumps(items))
" <<< "$parsed" 2>/dev/null || echo "[]")

    if [ "$pitems" != "[]" ]; then
      # Strip outer brackets to merge into all_items_json
      local inner
      inner=$(python3 -c "import json,sys; arr=json.load(sys.stdin); print(','.join(json.dumps(x) for x in arr))" <<< "$pitems" 2>/dev/null || echo "")
      if [ -n "$inner" ]; then
        [ "$all_items_json" = "[" ] || all_items_json+=","
        all_items_json+="$inner"
      fi
    fi
  done

  all_items_json+="]"
  procedures_json+="]"

  # Split into peer items and non-peer items
  local split_result
  split_result=$(python3 -c "
import json, sys

all_items = json.loads('$all_items_json')
non_peers_set = set($(python3 -c "import json; print(json.dumps($(for np in "${CONSTITUTIONAL_NON_PEERS[@]}"; do printf '"%s",' "$np"; done | sed 's/,$//')))" 2>/dev/null || echo "[]"))

peer_items = []
non_peer_items = []

for it in all_items:
    target = it.get('target', '')
    is_non_peer = it.get('non_peer', False) or target in non_peers_set
    if is_non_peer:
        non_peer_items.append(it)
    else:
        peer_items.append(it)

# Sort peer items by attention_rank ascending, then by procedure_id
peer_items.sort(key=lambda x: (x.get('attention_rank', 99), x.get('procedure_id', '')))

# Non-peer items also sorted by rank
non_peer_items.sort(key=lambda x: (x.get('attention_rank', 99), x.get('procedure_id', '')))

result = {
    'peer_items': peer_items,
    'non_peer_items': non_peer_items,
    'total_peer': len(peer_items),
    'total_non_peer': len(non_peer_items)
}
print(json.dumps(result))
" 2>/dev/null)

  local peer_items_json non_peer_items_json peer_count non_peer_count
  peer_items_json=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['peer_items']))" <<< "$split_result" 2>/dev/null || echo "[]")
  non_peer_items_json=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d['non_peer_items']))" <<< "$split_result" 2>/dev/null || echo "[]")
  peer_count=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['total_peer'])" <<< "$split_result" 2>/dev/null || echo 0)
  non_peer_count=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['total_non_peer'])" <<< "$split_result" 2>/dev/null || echo 0)

  log "Peer attention items: ${peer_count}, non-peer (observatory): ${non_peer_count}"

  # ---- Generate STATE.md ----

  local state_md=""
  state_md+="# Federation Digest\n"
  state_md+="\n"
  state_md+="**Composed:** ${newest_ts}\n"
  state_md+="**Procedures:** ${#sub_files[@]} (see digest/ for per-procedure details)\n"
  state_md+="**Attention items:** ${peer_count} (${non_peer_count} observatory)\n"
  state_md+="\n"

  # Per-procedure summary table
  state_md+="## Procedure Summary\n"
  state_md+="\n"
  state_md+="| Procedure | Version | Timestamp | Summary |\n"
  state_md+="|---|---|---|---|\n"

  python3 -c "
import json, sys

procs = json.loads('$procedures_json')
for p in procs:
    pid = p.get('procedure_id','?')
    pv = p.get('procedure_version','?')
    ts = p.get('run_timestamp','')[:16]
    summary = p.get('summary',{})
    # Render summary as compact k=v pairs
    parts = []
    for k,v in sorted(summary.items()):
        parts.append(f'{k}={v}')
    summary_str = ', '.join(parts) if parts else '-'
    print(f'| \`{pid}\` | \`{pv}\` | {ts} | {summary_str} |')
" 2>/dev/null >> /dev/stdout

  # Read the output and append to state_md
  local proc_table
  proc_table=$(python3 -c "
import json, sys

procs = json.loads('$procedures_json')
lines = []
for p in procs:
    pid = p.get('procedure_id','?')
    pv = p.get('procedure_version','?')
    ts = p.get('run_timestamp','')[:16]
    summary = p.get('summary',{})
    parts = []
    for k,v in sorted(summary.items()):
        parts.append(f'{k}={v}')
    summary_str = ', '.join(parts) if parts else '-'
    lines.append(f'| \`{pid}\` | \`{pv}\` | {ts} | {summary_str} |')
for l in lines:
    print(l)
" 2>/dev/null)
  state_md+="${proc_table}"
  state_md+=$'\n\n'

  # Ranked attention table (peer items)
  state_md+="## Ranked Attention (needs operator decision)\n"
  state_md+="\n"

  if [ "$peer_count" -eq 0 ]; then
    state_md+="✅ No attention items. All observed nodes and boundaries are current.\n"
    state_md+="\n"
  else
    state_md+="| # | Target | Status | Procedure | Headline | Evidence |\n"
    state_md+="|---|---|---|---|---|---|\n"

    local rank=1
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local target status pid headline refs
      target=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('target',''))" <<< "$line" 2>/dev/null || echo "")
      status=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" <<< "$line" 2>/dev/null || echo "")
      pid=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('procedure_id',''))" <<< "$line" 2>/dev/null || echo "")
      headline=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('headline',''))" <<< "$line" 2>/dev/null || echo "")
      refs=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); refs=d.get('refs',[]); print(', '.join(refs[:3]))" <<< "$line" 2>/dev/null || echo "")

      local status_icon=""
      case "$status" in
        observed)   status_icon="✅" ;;
        stale)      status_icon="⚠️" ;;
        superseded) status_icon="🔄" ;;
        *)          status_icon="❓" ;;
      esac

      state_md+="| ${rank} | \`${target}\` | ${status_icon} ${status} | \`${pid}\` | ${headline} | ${refs} |"$'\n'
      rank=$(( rank + 1 ))
    done < <(python3 -c "
import json, sys
items = json.loads('$peer_items_json')
for it in items:
    print(json.dumps(it))
" 2>/dev/null)
    state_md+=$'\n'
  fi

  # Constitutional Observatory section
  if [ "$non_peer_count" -gt 0 ]; then
    state_md+="## Constitutional Observatory\n"
    state_md+="\n"
    state_md+="These repositories are constitutional non-peers (§5). They are tracked for\n"
    state_md+="liveness (FR-CON-011) but are not ranked as federation attention items.\n"
    state_md+="\n"
    state_md+="| # | Target | Status | Procedure | Headline |\n"
    state_md+="|---|---|---|---|---|\n"

    local rank=1
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local target status pid headline
      target=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('target',''))" <<< "$line" 2>/dev/null || echo "")
      status=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" <<< "$line" 2>/dev/null || echo "")
      pid=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('procedure_id',''))" <<< "$line" 2>/dev/null || echo "")
      headline=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('headline',''))" <<< "$line" 2>/dev/null || echo "")

      local status_icon=""
      case "$status" in
        observed)   status_icon="✅" ;;
        stale)      status_icon="⚠️" ;;
        superseded) status_icon="🔄" ;;
        *)          status_icon="❓" ;;
      esac

      state_md+="| ${rank} | \`${target}\` | ${status_icon} ${status} | \`${pid}\` | ${headline} |"$'\n'
      rank=$(( rank + 1 ))
    done < <(python3 -c "
import json, sys
items = json.loads('$non_peer_items_json')
for it in items:
    print(json.dumps(it))
" 2>/dev/null)
    state_md+=$'\n'
  fi

  # Budget
  state_md+="## Budget\n"
  state_md+="\n"
  # Sum budget info from sub-digests if available, otherwise note
  state_md+="Per-procedure budget details are in the machine-readable digest and individual sub-digests.\n"
  state_md+="See \`digest/state-digest.json\` and \`digest/<procedure_id>.json\`.\n"
  state_md+="\n"

  # Navigation
  state_md+="## Navigation (progressive disclosure)\n"
  state_md+="\n"
  state_md+="\`\`\`\n"
  state_md+="Federation Digest (this file)\n"
  state_md+="    ↓\n"
  state_md+="Per-procedure sub-digests — digest/<procedure_id>.json\n"
  state_md+="    ↓\n"
  state_md+="Findings — findings/ (interpreted observations with lifecycle)\n"
  state_md+="    ↓\n"
  state_md+="Evidence — evidence/ (deterministic observations)\n"
  state_md+="    ↓\n"
  state_md+="Repository Pins — pins/ (exact commit references)\n"
  state_md+="    ↓\n"
  state_md+="Raw repository references — original GitHub repos at pinned SHAs\n"
  state_md+="\`\`\`\n"
  state_md+="\n"

  # Links section
  state_md+="## Sub-digests\n"
  state_md+="\n"
  for f in "${sub_files[@]}"; do
    local bn
    bn=$(basename "$f")
    local pid
    pid="${bn%.json}"
    state_md+="- [\`${pid}\`](${f})\n"
  done
  state_md+="\n"

  state_md+="## Composition Contract\n"
  state_md+="\n"
  state_md+="See \`procedures/DIGEST_CONTRACT.md\` for how procedures contribute to this digest.\n"

  printf '%b' "$state_md" > STATE.md
  log "STATE.md written"

  # ---- Generate machine-readable digest ----

  local merged_json
  merged_json=$(python3 -c "
import json

peer_items = json.loads('$peer_items_json')
non_peer_items = json.loads('$non_peer_items_json')
procedures = json.loads('$procedures_json')

output = {
    'digest_type': 'composed_federation',
    'composer_version': 'v2',
    'composed_at': '$newest_ts',
    'procedure_count': ${#sub_files[@]},
    'procedures': procedures,
    'attention_items': peer_items,
    'constitutional_observatory': non_peer_items,
    'summary': {
        'total_attention_items': len(peer_items),
        'total_observatory_items': len(non_peer_items),
        'total_procedures': ${#sub_files[@]}
    }
}
print(json.dumps(output, indent=2))
" 2>/dev/null)

  write_json "digest/state-digest.json" "$merged_json"
  log "digest/state-digest.json written"

  log ""
  log "=== Composition complete ==="
  log "  Peer attention items: ${peer_count}"
  log "  Observatory items: ${non_peer_count}"
  log "  Procedures: ${#sub_files[@]}"
  log "  Outputs: STATE.md, digest/state-digest.json"
}

# ---- Main --------------------------------------------------------------

compose
