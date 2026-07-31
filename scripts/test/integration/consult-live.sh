#!/usr/bin/env bash
# consult-live.sh — the one test that spends money and needs the network.
#
# Round 2 of the red-team on PR #137 rejected the control primarily because it
# failed in the environment it was written for, while 413 fixture-driven tests
# stayed green:
#
#   "A real integration test must invoke real jcode and read the actual emitted
#    tag. Fixtures that repeat a guessed truncation constant are precisely the
#    'test duplicates what it guards' failure described in
#    docs/operator-lessons.md."
#
# Correct. The fixtures encoded a session-prefix length of 24 that the operator
# had assumed; the log writes 20; every fixture passed and every real dispatch
# was refused.
#
# So this exists, and it is deliberately NOT in scripts/test/MANIFEST: running
# it costs provider tokens and requires network, and a suite that quietly bills
# the owner on every commit is its own defect. It is run by hand, and its result
# belongs in the pull request that changes anything about attribution.
#
#   bash scripts/test/integration/consult-live.sh
#
# Exit 0 means a real dispatch to a real provider was correctly attributed by
# reading the real log.

set -uo pipefail
cd "$(dirname "$0")/../../.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/live.md"
PROMPT="$TMP/prompt.txt"
printf 'Reply with exactly: LIVE_OK. Do not use any tools.\n' > "$PROMPT"

echo "== live dispatch: openai/gpt-5.6-sol =="
if ! bash scripts/consult.sh openai gpt-5.6-sol "$OUT" "$PROMPT"; then
  echo "FAIL — a real dispatch was not attributable." >&2
  echo "  This is the round-2 rejection reproduced: the control refuses its own" >&2
  echo "  live run while the fixture suite is green." >&2
  exit 1
fi

for field in "served_provider: openai" "reviewer_claim: openai" "^consistency_check:" "^session: session_"; do
  if ! grep -q "$field" "$OUT"; then
    echo "FAIL — the artifact lacks '$field'" >&2
    exit 1
  fi
done

session="$(sed -n 's/^session:[[:space:]]*//p' "$OUT" | head -1)"
log="$(sed -n 's/^log:[[:space:]]*//p' "$OUT" | head -1)"
echo "== the cited evidence must be checkable by a third party =="
found=0
for n in "${#session}" 28 24 20 16; do
  [ "$n" -le "${#session}" ] || continue
  if grep -qF "ses:${session:0:$n}" "$log" 2>/dev/null; then found=1; break; fi
done
if [ "$found" -ne 1 ]; then
  echo "FAIL — the artifact cites a session that does not appear in the log it cites" >&2
  exit 1
fi

echo "PASS — real dispatch, attributed from the real log, evidence re-checkable"
echo "  session: $session"
echo "  log:     $log"
