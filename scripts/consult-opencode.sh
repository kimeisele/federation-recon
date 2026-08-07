#!/usr/bin/env bash
# consult-opencode.sh — independent review through OpenCode Go, fail closed.
#
# Usage:
#   consult-opencode.sh <model> <output.md> <prompt-file> <source-repo>
#
# The live JSON stream identifies a session but does not identify its route.
# The session-bound `opencode export` does. A report exists only when both
# sources agree on one completed session and the exported provider/model match
# what was requested. The model works in a disposable detached worktree; the
# supplied checkout is never its working directory.
set -uo pipefail

MODEL="${1:-}"
OUTPUT="${2:-}"
PROMPT="${3:-}"
SOURCE_REPO="${4:-}"
SERVICE_PROVIDER="opencode-go"
OPENCODE="${OPENCODE_BIN:-opencode}"
TIMEOUT_SECONDS="${OPENCODE_REVIEW_TIMEOUT_SECONDS:-900}"

if [ -z "$MODEL" ] || [ -z "$OUTPUT" ] || [ -z "$PROMPT" ] || [ -z "$SOURCE_REPO" ]; then
  echo "usage: $0 <model> <output.md> <prompt-file> <source-repo>" >&2
  exit 2
fi
case "$MODEL" in
  ''|*[!A-Za-z0-9._-]*) echo "consult-opencode: invalid model name" >&2; exit 2 ;;
esac
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "consult-opencode: timeout must be a positive integer" >&2; exit 2 ;;
esac
if [ "$TIMEOUT_SECONDS" -lt 1 ] || [ "$TIMEOUT_SECONDS" -gt 3600 ]; then
  echo "consult-opencode: timeout must be between 1 and 3600 seconds" >&2
  exit 2
fi
if [ "${CONSULT_AUTHORIZED:-}" != "1" ]; then
  echo "consult-opencode: REFUSED — paid consultation requires explicit owner authorization." >&2
  echo "  Set CONSULT_AUTHORIZED=1 after owner approval. See governance/reviewers.md." >&2
  exit 1
fi
[ -f "$PROMPT" ] || { echo "consult-opencode: prompt is not a regular file" >&2; exit 2; }
git -C "$SOURCE_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "consult-opencode: source is not a git worktree" >&2
  exit 2
}
SOURCE_DIRTY="$(git -C "$SOURCE_REPO" status --porcelain --untracked-files=normal 2>/dev/null)" || {
  echo "consult-opencode: source status is unavailable" >&2
  exit 2
}
if [ -n "$SOURCE_DIRTY" ]; then
  echo "consult-opencode: source is dirty; detached review would omit uncommitted bytes" >&2
  exit 2
fi

RAW="${OUTPUT}.raw.jsonl"
PROVENANCE="${OUTPUT}.provenance.json"
UNATTRIBUTED="${OUTPUT}.unattributed"
for path in "$OUTPUT" "${OUTPUT}.tmp" "$RAW" "$PROVENANCE" \
            "$UNATTRIBUTED" "${UNATTRIBUTED}.tmp"; do
  if [ -L "$path" ] || { [ -e "$path" ] && [ ! -f "$path" ]; }; then
    echo "consult-opencode: refusing unsafe output path: $path" >&2
    exit 2
  fi
  if [ -e "$path" ]; then
    echo "consult-opencode: refusing to overwrite existing output: $path" >&2
    exit 2
  fi
done

TMP="$(mktemp -d)" || exit 2
REVIEW_WT="$TMP/review-wt"
BODY="$TMP/body.txt"
SESSION_FILE="$TMP/session.txt"
META="$TMP/meta.txt"
WORKTREE_ADDED=false
CHILD_PID=""
CHILD_PGID=""

stop_child() {
  [ -n "$CHILD_PID" ] || return 0
  kill -0 "$CHILD_PID" 2>/dev/null || { CHILD_PID=""; CHILD_PGID=""; return 0; }
  [ -n "$CHILD_PGID" ] && kill -TERM -"$CHILD_PGID" 2>/dev/null || true
  kill -TERM "$CHILD_PID" 2>/dev/null || true
  sleep 2
  if kill -0 "$CHILD_PID" 2>/dev/null; then
    [ -n "$CHILD_PGID" ] && kill -KILL -"$CHILD_PGID" 2>/dev/null || true
    kill -KILL "$CHILD_PID" 2>/dev/null || true
  fi
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
  CHILD_PGID=""
}

cleanup() {
  stop_child
  if $WORKTREE_ADDED; then
    git -C "$SOURCE_REPO" worktree remove --force "$REVIEW_WT" >/dev/null 2>&1 || true
    git -C "$SOURCE_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

quarantine() {
  local reason="$1"
  {
    echo "UNATTRIBUTED CONSULTATION OUTPUT"
    echo "NOT A CONSULTATION"
    echo
    echo "reason: $reason"
    echo "requested_service_provider: $SERVICE_PROVIDER"
    echo "requested_model: $MODEL"
    echo
    echo "----------------------------------------------------------------"
    echo
    if [ -s "$BODY" ]; then cat "$BODY"; elif [ -s "$RAW" ]; then cat "$RAW"; fi
  } > "${UNATTRIBUTED}.tmp" || return 1
  mv "${UNATTRIBUTED}.tmp" "$UNATTRIBUTED" || return 1
  rm -f "${OUTPUT}.tmp"
  echo "consult-opencode: REFUSED — $reason; body kept at $UNATTRIBUTED" >&2
  return 0
}

git -C "$SOURCE_REPO" worktree add --detach "$REVIEW_WT" HEAD >/dev/null 2>&1 || {
  echo "consult-opencode: could not create disposable review worktree" >&2
  exit 2
}
WORKTREE_ADDED=true

set -m
"$OPENCODE" run --pure --model "$SERVICE_PROVIDER/$MODEL" --format json \
  --dir "$REVIEW_WT" "$(cat "$PROMPT")" > "$RAW" 2>&1 &
CHILD_PID=$!
CHILD_PGID="$(ps -o pgid= -p "$CHILD_PID" 2>/dev/null | tr -d ' ')"
set +m

TIMED_OUT=false
TICKS=0
MAX_TICKS=$((TIMEOUT_SECONDS * 10))
while kill -0 "$CHILD_PID" 2>/dev/null; do
  sleep 0.1
  TICKS=$((TICKS + 1))
  if [ "$TICKS" -ge "$MAX_TICKS" ]; then
    TIMED_OUT=true
    stop_child
    break
  fi
done
if $TIMED_OUT; then
  RUN_RC=124
else
  wait "$CHILD_PID" 2>/dev/null
  RUN_RC=$?
  CHILD_PID=""
  CHILD_PGID=""
fi

# Extract the report and bind it to exactly one syntactically valid stream
# session. A partial body is still extracted so a crash does not destroy a
# useful finding; it is quarantined rather than certified.
python3 - "$RAW" "$BODY" "$SESSION_FILE" <<'PY'
import json, sys
raw, body_path, session_path = sys.argv[1:]
sessions = set()
texts = []
finished = False
try:
    with open(raw, errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            item = json.loads(line)
            session = item.get("sessionID")
            if not isinstance(session, str) or not session:
                raise ValueError("line {} has no sessionID".format(number))
            sessions.add(session)
            part = item.get("part")
            if isinstance(part, dict) and part.get("type") == "text":
                text = part.get("text")
                if isinstance(text, str) and text:
                    texts.append(text)
            if (item.get("type") == "step_finish" and isinstance(part, dict)
                    and part.get("reason") == "stop"):
                finished = True
except Exception as exc:
    print("invalid stream: {}".format(exc), file=sys.stderr)
    sys.exit(4)

with open(body_path, "w") as handle:
    handle.write("\n".join(texts))
    if texts:
        handle.write("\n")
if len(sessions) != 1:
    print("ambiguous stream: expected one session, got {}".format(len(sessions)), file=sys.stderr)
    sys.exit(3)
with open(session_path, "w") as handle:
    handle.write(next(iter(sessions)))
if not finished:
    sys.exit(5)
PY
STREAM_RC=$?

if [ "$RUN_RC" -ne 0 ]; then
  if $TIMED_OUT; then
    quarantine "OpenCode run exceeded ${TIMEOUT_SECONDS}s and its process group was terminated" || true
  else
    quarantine "OpenCode run exited $RUN_RC" || true
  fi
  exit 1
fi
case "$STREAM_RC" in
  0) ;;
  3) quarantine "more than one or no stream session (ambiguous)" || true; exit 1 ;;
  5) quarantine "stream did not finish with reason=stop" || true; exit 1 ;;
  *) quarantine "stream evidence was missing or invalid" || true; exit 1 ;;
esac

SESSION="$(cat "$SESSION_FILE")"
LAST_LINE="$(sed '/^[[:space:]]*$/d' "$BODY" | tail -1)"
case "$LAST_LINE" in
  "verdict: APPROVE"|"verdict: REJECT") ;;
  *) quarantine "report has no exact final verdict" || true; exit 1 ;;
esac

"$OPENCODE" export "$SESSION" > "$PROVENANCE" 2>/dev/null
EXPORT_RC=$?
if [ "$EXPORT_RC" -ne 0 ] || [ ! -s "$PROVENANCE" ]; then
  quarantine "session export evidence unavailable" || true
  exit 1
fi

python3 - "$PROVENANCE" "$SESSION" "$SERVICE_PROVIDER" "$MODEL" "$META" <<'PY'
import json, sys
path, session, provider, model, meta_path = sys.argv[1:]
try:
    with open(path) as handle:
        data = json.load(handle)
    info = data["info"]
    route = info["model"]
    if info.get("id") != session:
        raise ValueError("exported session does not match stream")
    if route.get("providerID") != provider or route.get("id") != model:
        raise ValueError("exported provider/model does not match request")
    assistants = [m.get("info", {}) for m in data.get("messages", [])
                  if m.get("info", {}).get("role") == "assistant"]
    if not assistants:
        raise ValueError("export contains no assistant message")
    for item in assistants:
        if (item.get("sessionID") != session or item.get("providerID") != provider
                or item.get("modelID") != model):
            raise ValueError("assistant route is missing, mixed, or mismatched")
    if assistants[-1].get("finish") != "stop":
        raise ValueError("assistant did not finish normally")
    tokens = info.get("tokens") or {}
    values = [info.get("cost", "unavailable"), tokens.get("input", "unavailable"),
              tokens.get("output", "unavailable")]
    with open(meta_path, "w") as handle:
        handle.write("\n".join(str(v) for v in values))
        handle.write("\n")
except Exception as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(1)
PY
VERIFY_RC=$?
if [ "$VERIFY_RC" -ne 0 ]; then
  quarantine "exported provider/model/session evidence mismatched" || true
  exit 1
fi

COST="$(sed -n '1p' "$META")"
INPUT_TOKENS="$(sed -n '2p' "$META")"
OUTPUT_TOKENS="$(sed -n '3p' "$META")"
{
  echo '<!-- provenance'
  echo "requested_provider: $SERVICE_PROVIDER"
  echo "served_provider: $SERVICE_PROVIDER"
  echo "reviewer_claim: $SERVICE_PROVIDER"
  echo "model: $MODEL"
  echo "consistency_check: session export matches the completed stream session, service provider, and requested model"
  echo "log: $RAW; session export: $PROVENANCE"
  echo '-->'
  echo
  echo "served_model: $MODEL"
  echo "service_provider: $SERVICE_PROVIDER"
  echo "upstream_model: $MODEL"
  echo "upstream_model_provider: asserted by service metadata, not independently established"
  echo "isolation: disposable git worktree; not an OS sandbox"
  echo "session: $SESSION"
  echo "cost: $COST"
  echo "input_tokens: $INPUT_TOKENS"
  echo "output_tokens: $OUTPUT_TOKENS"
  echo "provenance: $PROVENANCE"
  echo "consistency_check: match"
  echo "body_rendering: line-leading provenance-opener and quarantine-sentinel quotations are prefixed with a Markdown blockquote marker; raw response remains verbatim in the JSONL stream and session export"
  echo
  echo "---"
  echo
  sed -e '/^[[:space:]]*<!-- provenance[[:space:]]*$/s/^/> /' \
      -e '/^[[:space:]]*UNATTRIBUTED CONSULTATION OUTPUT/s/^/> /' "$BODY"
} > "${OUTPUT}.tmp" || { quarantine "could not assemble consultation" || true; exit 1; }
mv "${OUTPUT}.tmp" "$OUTPUT" || { quarantine "could not publish consultation" || true; exit 1; }

echo "consult-opencode: accepted $SERVICE_PROVIDER/$MODEL session $SESSION" >&2
exit 0
