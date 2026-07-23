#!/usr/bin/env bash
# CI gate — fast, offline invariants that must hold for every commit.
#
#   1. Every committed artifact validates against schemas/*.json (strict).
#      Catches the class of defect where invalid JSON or a schema violation
#      ships because strict validation was not run before the merge claim.
#   2. The composed Federation Digest is idempotent: STATE.md and
#      digest/state-digest.json must be a pure function of the per-procedure
#      sub-digests (digest/<id>.json). If re-running the composer changes them,
#      the committed digest is stale or hand-edited — reject it.
#
# Full end-to-end --reproduce determinism (which requires network + gh to fetch
# pinned repository contents) is intentionally NOT run here so the PR gate stays
# fast and offline. See scripts/verify-determinism.sh for that deeper check.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== [1/2] strict artifact validation =="
if bash scripts/validate-artifacts.sh --strict; then
  echo "  OK"
else
  echo "  FAIL — artifacts do not validate against schemas/*.json"
  fail=1
fi

echo
echo "== [2/2] composed digest idempotency =="
tmp="$(mktemp -d)"
cp STATE.md "$tmp/STATE.md"
cp digest/state-digest.json "$tmp/state-digest.json"
bash scripts/compose-digest.sh >/dev/null 2>&1
if diff -q "$tmp/STATE.md" STATE.md >/dev/null 2>&1 \
   && diff -q "$tmp/state-digest.json" digest/state-digest.json >/dev/null 2>&1; then
  echo "  OK — STATE.md and machine digest reproduce exactly from sub-digests"
else
  echo "  FAIL — composed digest is stale or non-deterministic."
  echo "         Run 'bash scripts/compose-digest.sh' and commit the result."
  # Restore committed versions so the runner's tree is left clean.
  cp "$tmp/STATE.md" STATE.md
  cp "$tmp/state-digest.json" digest/state-digest.json
  fail=1
fi
rm -rf "$tmp"

echo
if [ "$fail" = 0 ]; then
  echo "CI checks: PASS"
  exit 0
else
  echo "CI checks: FAIL"
  exit 1
fi
