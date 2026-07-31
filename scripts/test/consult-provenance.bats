#!/usr/bin/env bats
# consult-provenance.bats — a consultation that cannot be attributed must not exist.
#
# On 2026-07-31 three consultations were filed as independent cross-provider
# reviews and none of them were. `jcode run -p openai -m gpt-5.6-sol` returned
# a plausible report with exit 0 while the log showed the request had been
# served by DeepSeek — the same provider as the builder whose code was under
# review. The flags are discarded whenever the configured default provider uses
# an API key, and resolution slides to the default model.
#
# That is fail-open. Nothing looked broken. It was caught by a human noticing
# that an untouched subscription quota contradicted two reviews supposedly run
# against it, not by any check in this repository.
#
# governance/reviewers.md already carried the rule — "a tool with silent
# provider failover cannot be the control that guarantees provider
# independence" — and the rule was applied to the provider called by direct API
# and not to the one called through the tool that has the failover. A rule that
# depends on remembering to apply it is not a control, which is why it is now
# a script that deletes its own output rather than a paragraph.
#
# Every test drives a fixture log. Verification must be testable without
# spending a token, or it will be tested rarely and trusted anyway.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  CONSULT="$REPO_ROOT/scripts/consult.sh"
  LOG="$BATS_TEST_TMPDIR/fake.log"
  OUT="$BATS_TEST_TMPDIR/out.md"
  PROMPT="$BATS_TEST_TMPDIR/prompt.txt"
  echo "irrelevant" > "$PROMPT"
  SESSION="session_test_1785500000000_deadbeefcafef00d"
}

# A log window that looks like the named provider served the request.
#
# The timestamp is deliberately in the FUTURE. consult.sh takes its mark after
# this file is written and selects log lines >= that mark, so a fixture stamped
# "now" loses the race whenever a second ticks between the two calls — which
# made this suite fail roughly one run in ten and pass the rest.
#
# That is the same defect repaired in state-gate.bats hours earlier: a test
# whose outcome is decided by the clock rather than by its subject. In a real
# run the log lines are always written after the mark, so a future stamp is the
# faithful simulation rather than a workaround.
_log_for() {
  # Every fixture line now carries the session id, because attribution is bound
  # to the request's own jcode session rather than to a time window. A window
  # is a claim about the clock; a concurrent session broke the first version
  # and it deleted the review that found the flaw.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  case "$1" in
    openai)   printf '[%s] [INFO] [ses:%s|prv:OpenAI|mod:gpt-5.6-sol] API stream opened in 0.03s\n' "$now" "$SESSION" ;;
    deepseek) printf '[%s] [INFO] [ses:%s] API stream attempt 1/3 (model: deepseek-v4-flash, endpoint: https://api.deepseek.com)\n' "$now" "$SESSION"
              printf '[%s] [INFO] [ses:%s|prv:OpenRouter|mod:deepseek] API stream opened in 0.03s\n' "$now" "$SESSION" ;;
    both)     printf '[%s] [INFO] [ses:%s|prv:OpenAI|mod:gpt-5.6-sol] opened\n' "$now" "$SESSION"
              printf '[%s] [INFO] [ses:%s|prv:OpenRouter|mod:deepseek] opened\n' "$now" "$SESSION" ;;
    empty)    : ;;
  esac > "$LOG"
}

@test "consult: the requested provider actually serving is accepted" {
  _log_for openai
  echo "REPORT BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  grep -q "served_provider: openai" "$OUT"
  grep -q "REPORT BODY" "$OUT"
}

@test "consult: a different provider serving is REFUSED and the output deleted" {
  # The 2026-07-31 failure, exactly. Asked for openai, deepseek answered, the
  # tool exited 0. This is the test the repository did not have.
  _log_for deepseek
  echo "PLAUSIBLE REPORT NOBODY SHOULD KEEP" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CONSULT REFUSED"* ]]
  [[ "$output" == *"served:    deepseek"* ]]
  [ ! -f "$OUT" ]
  [ ! -f "$OUT.stdout" ]
}

@test "consult: two providers in the window is ambiguous, not a pass" {
  # A consultation that cannot be pinned to one model is not a second opinion,
  # even when the one asked for is among them.
  _log_for both
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: nothing in the log is UNDETERMINED, never a pass" {
  # Not measured must never produce the same outcome as measured-and-fine.
  _log_for empty
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-log-activity"* || "$output" == *"undetermined"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: an unreadable log is a refusal, not a shrug" {
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$BATS_TEST_TMPDIR/does-not-exist.log" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unreadable-log"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: deepseek asked for and deepseek serving is accepted" {
  # The check must not simply prefer one provider — it compares.
  _log_for deepseek
  echo "BUILD REPORT" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" deepseek deepseek-v4-flash "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "served_provider: deepseek" "$OUT"
}

@test "consult: there is no flag that skips verification" {
  # The one property that cannot be left to discipline. If a bypass is ever
  # added, this test is where it becomes visible.
  run bash -c "grep -nE 'skip.?(verify|check)|--force|--no-verify|SKIP_VERIFY' '$CONSULT' | grep -v CONSULT_SKIP_RUN"
  echo "$output"
  [ -z "$output" ]
}

@test "consult: a refusal leaves no consultation, but keeps the body" {
  # This asserted that NOTHING survived a refusal, and the first version did
  # delete everything. That cost a twenty-five-kilobyte red-team report whose
  # findings had to be reconstructed from the part already read.
  #
  # The reasoning about CITATION was right and the conclusion about DESTRUCTION
  # was wrong. A refused body is unattributable, which is not the same as
  # worthless. It survives under an extension no gate, glob or reader treats as
  # a consultation.
  _log_for deepseek
  echo "FINDINGS NOBODY SHOULD LOSE" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [ ! -f "$OUT" ]                       # no consultation
  [ ! -f "$OUT.stdout" ]                # no half-written leftover
  [ -f "$OUT.unattributed" ]            # the body kept
  grep -q "FINDINGS NOBODY SHOULD LOSE" "$OUT.unattributed"
  grep -q "NOT A CONSULTATION" "$OUT.unattributed"
  # And it must not be mistaken for one by the gate, which looks at *.md only.
  [[ "$OUT.unattributed" != *.md ]]
}

@test "consult: a run that cannot be bound to a session is refused" {
  # Attribution is bound to the request's own jcode session. Without one the
  # log can only be filtered by time, and a concurrent session then makes the
  # answer ambiguous or wrong — which is exactly how the first version deleted
  # the review that found the flaw.
  _log_for openai
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not bind the run to a jcode session"* ]]
  [ ! -f "$OUT" ]
  # Every refusal path keeps the body. Mutation testing found that destroying
  # it on ONE branch went unnoticed because the test only covered another — and
  # destroying a finding is the mistake that cost a twenty-five-kilobyte report.
  [ -f "$OUT.unattributed" ]
  grep -q "NOT A CONSULTATION" "$OUT.unattributed"
}

@test "consult: another session in the same window cannot decide the verdict" {
  # The red-team's executed evasion: run your own provider session while being
  # reviewed and the time window contains two providers. Bound to a session id,
  # the other one is irrelevant rather than fatal.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  {
    printf '[%s] [INFO] [ses:%s|prv:OpenAI|mod:gpt-5.6-sol] ours\n' "$now" "$SESSION"
    printf '[%s] [INFO] [ses:session_other_1785500000000_ffffffffffffffff|prv:OpenRouter|mod:deepseek] theirs\n' "$now"
  } > "$LOG"
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "served_provider: openai" "$OUT"
}

# ── The builder's own invocation ───────────────────────────────────────────

@test "consult: the builder passes provider AND model as flags" {
  # It used to set JCODE_PROVIDER as an environment variable, which `jcode run`
  # does not read, and to pass no model at all — so it took the configured
  # default. That default now names the reviewer model, because an OAuth
  # provider must be the default for -p/-m to be honoured. The old line would
  # have built with the model meant to review the build.
  #
  # Comments are stripped before matching: this file explains the flags in
  # prose directly above the line that uses them, and a grep over the whole
  # file would be satisfied by the explanation.
  run bash -c "sed 's/#.*//' '$REPO_ROOT/operator/builders/jcode.sh' | grep -E 'jcode run .*-p .*-m '"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "consult: the builder does not rely on JCODE_PROVIDER reaching jcode" {
  # Reading the variable to compute a default is fine. Passing it as the
  # mechanism is not, because jcode run ignores it.
  run bash -c "sed 's/#.*//' '$REPO_ROOT/operator/builders/jcode.sh' | grep -E '^ *JCODE_(PROVIDER|MODEL)=.*jcode run'"
  echo "$output"
  [ -z "$output" ]
}

@test "consult: a large window is searched to the end" {
  # The regression for the defect that shipped in the first version and was
  # found on its first real dispatch.
  #
  # The extraction was `printf '%s\n' "$window" | grep -q …` under
  # `set -o pipefail`. grep -q exits at its first match, printf takes SIGPIPE,
  # the pipeline reports 141, and the `&&` never fires — so every provider came
  # back unmatched and a real twenty-minute review was deleted as
  # unattributable. It failed safe and it was useless.
  #
  # Every other test here passed throughout, because their fixtures are one or
  # two lines: printf finishes before grep can exit. **The tests passed because
  # the input was small.** This one is two thousand lines, which is the size of
  # a real window, and it is the only test that would have caught it.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  {
    for i in $(seq 1 2000); do
      printf '[%s] [INFO] [ses:%s|prv:OpenAI|mod:gpt-5.6-sol] line %d\n' "$now" "$SESSION" "$i"
    done
  } > "$LOG"
  echo "REPORT BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  grep -q "served_provider: openai" "$OUT"
}

@test "consult: a large window still catches the WRONG provider" {
  # The counterpart. A large window must not merely stop failing — it must
  # still refuse when the wrong provider answered, which is the case that
  # matters.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  {
    for i in $(seq 1 2000); do
      printf '[%s] [INFO] [ses:%s|prv:OpenRouter|mod:deepseek] line %d\n' "$now" "$SESSION" "$i"
    done
  } > "$LOG"
  echo "REPORT NOBODY SHOULD KEEP" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"served:    deepseek"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: extraction uses no pipe into a short-circuiting reader" {
  # The property, not the symptom. Under `set -o pipefail` any
  # `... | grep -q ...` can report failure for a reason that has nothing to do
  # with whether the pattern matched. Stated as a check so the next person to
  # reach for a pipe here finds out immediately.
  # Comments stripped first. The block above explains the defect by quoting the
  # broken construct, so a grep over the whole file matches the explanation —
  # the third time today a test has been satisfied by prose describing the
  # mechanism instead of by the mechanism.
  run bash -c "sed 's/#.*//' '$CONSULT' | grep -nE '\\| *grep -q'"
  echo "$output"
  [ -z "$output" ]
}
