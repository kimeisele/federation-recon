#!/usr/bin/env bash
# fake-pr-opener.sh — stands in for `gh pr create` in tests.
#
# Invoked as: fake-pr-opener.sh <run_dir>
# Prints a PR reference on stdout, which is what run.sh measures.
#
# Behaviour driven by environment variables so tests can make it misbehave:
#   FAKE_PR_EXIT     exit status. Default 0.
#   FAKE_PR_SILENT   set to 1 to exit 0 while printing nothing — the case that
#                    would otherwise record a PR that does not exist.
#
# It also appends to a file, so a second invocation is countable: opening two
# pull requests for one run is the failure that resumption must not cause.
set -o errexit -o nounset -o pipefail

RUN_DIR="${1:-}"
[ -n "$RUN_DIR" ] && [ -d "$RUN_DIR" ] || { echo "no run dir" >&2; exit 1; }

echo "opened at $(date -u +%s%N)" >> "$RUN_DIR/pr_opener_invocations.txt"

if [ "${FAKE_PR_SILENT:-0}" = "1" ]; then
  exit "${FAKE_PR_EXIT:-0}"
fi

echo "https://example.invalid/kimeisele/federation-recon/pull/9999"
exit "${FAKE_PR_EXIT:-0}"
