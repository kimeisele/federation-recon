#!/usr/bin/env bats
#
# The verdict boundary must fail closed (#236 RECOVERY-2).
#
# Reproduced 2026-08-10: a blocking finding that could not be confined is
# downgraded by scripts/review.sh to severity="non-blocking",
# verification_status="inconclusive", keeping the original only in
# claimed_severity. scripts/review-verdict.sh Rule 4 tests `severity`, not
# `claimed_severity`, so the downgraded finding is skipped and the run returns
# APPROVE. On any host without sandbox-exec (Linux CI included) every blocking
# finding takes that path.
#
# The contract these tests pin: a finding the model CLAIMED blocking blocks the
# merge unless its command was executed and REFUTED (verification_status
# "rejected"). Every unresolved state — inconclusive, not_run, confirmed, or a
# severity silently lowered after the claim — must not produce APPROVE.
#
# These are written to be RED against the aggregator as it stands, and they say
# so: the fail-open is the defect, not the fixture.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  SCRIPT="$REPO_ROOT/scripts/review-verdict.sh"
  SHA="failclosed0000"
  TMP="$BATS_TEST_TMPDIR"
}

# _verdict <findings-json> — a LOW-risk, otherwise-healthy verdict carrying the
# given findings array, bound to $SHA. Everything except the finding is green,
# so the only thing that can move the result is the finding.
_verdict() {
  cat > "$TMP/v.json" <<JSON
{
  "subject_head_sha": "$SHA",
  "risk_class": "LOW",
  "tasks": {"tier0":"pass","review-analysis":"complete","adversarial-execution":"complete","tier2":"not_run"},
  "findings": $1
}
JSON
  run bash "$SCRIPT" "$TMP/v.json" "$SHA"
  [ "$status" -eq 0 ]
}

@test "fail-closed: a blocking finding downgraded for a missing sandbox does not APPROVE" {
  _verdict '[{"claimed_severity":"blocking","severity":"non-blocking","verification_status":"inconclusive","summary":"[sandbox-unavailable] could not confine"}]'
  [ "$output" != "APPROVE" ]
}

@test "fail-closed: a non-discriminating downgrade does not APPROVE" {
  _verdict '[{"claimed_severity":"blocking","severity":"non-blocking","verification_status":"inconclusive","summary":"[non-discriminating] passes at base and head"}]'
  [ "$output" != "APPROVE" ]
}

@test "fail-closed: a base-unverified downgrade does not APPROVE" {
  _verdict '[{"claimed_severity":"blocking","severity":"non-blocking","verification_status":"inconclusive","summary":"[base-unverified] base worktree unavailable"}]'
  [ "$output" != "APPROVE" ]
}

@test "fail-closed: a claimed-blocking finding never run does not APPROVE" {
  _verdict '[{"claimed_severity":"blocking","severity":"non-blocking","verification_status":"not_run","summary":"no verification command"}]'
  [ "$output" != "APPROVE" ]
}

@test "fail-closed: a still-blocking confirmed finding rejects (regression guard)" {
  _verdict '[{"claimed_severity":"blocking","severity":"blocking","verification_status":"confirmed","summary":"executed, fails at base, passes at head"}]'
  [ "$output" = "REJECT" ]
}

@test "fail-closed: a refuted finding is the one legitimate pass" {
  # verification_status "rejected" means the command ran and exited non-zero at
  # the head: examined and disproved. This is the only state that clears a
  # claimed-blocking finding, and it must still clear it or the runner can
  # never approve anything.
  _verdict '[{"claimed_severity":"blocking","severity":"non-blocking","verification_status":"rejected","summary":"executed and refuted at head"}]'
  [ "$output" = "APPROVE" ]
}

@test "fail-closed: a genuinely non-blocking finding does not block (regression guard)" {
  # No claim of blocking anywhere: an ordinary non-blocking observation must
  # not be swept up by a rule keyed on claimed_severity.
  _verdict '[{"severity":"non-blocking","verification_status":"not_run","summary":"style nit"}]'
  [ "$output" = "APPROVE" ]
}
