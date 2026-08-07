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

@test "consult: refuses without CONSULT_AUTHORIZED" {
  unset CONSULT_AUTHORIZED 2>/dev/null || true
  _log_for openai
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"owner authorization"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: the requested provider actually serving is accepted" {
  _log_for openai
  echo "REPORT BODY" > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  grep -q "served_provider: openai" "$OUT"
  grep -q "reviewer_claim: openai" "$OUT"
  grep -q "^consistency_check:" "$OUT"
  grep -q "REPORT BODY" "$OUT"
}

@test "consult: a different provider serving is REFUSED and the output deleted" {
  # The 2026-07-31 failure, exactly. Asked for openai, deepseek answered, the
  # tool exited 0. This is the test the repository did not have.
  _log_for deepseek
  echo "PLAUSIBLE REPORT NOBODY SHOULD KEEP" > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no-log-activity"* || "$output" == *"undetermined"* ]]
  [ ! -f "$OUT" ]
}

@test "consult: an unreadable log is a refusal, not a shrug" {
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$BATS_TEST_TMPDIR/does-not-exist.log" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" deepseek deepseek-v4-flash "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "served_provider: deepseek" "$OUT"
  grep -q "reviewer_claim: deepseek" "$OUT"
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="" \
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "served_provider: openai" "$OUT"
  grep -q "reviewer_claim: openai" "$OUT"
  grep -q "^consistency_check:" "$OUT"
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ -f "$OUT" ]
  grep -q "served_provider: openai" "$OUT"
  grep -q "reviewer_claim: openai" "$OUT"
  grep -q "^consistency_check:" "$OUT"
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
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
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

# ── Round-2 blocking conditions, each with the executed attack behind it ───

@test "consult: an output path that is a directory is refused before anything runs" {
  # Executed by the red-team: `mv file dir/` succeeds by writing INSIDE it, and
  # `[ -s dir ]` is true because a directory has a size. consult exited 0 with
  # the requested artifact existing only as <output>/<output>.tmp.
  mkdir -p "$BATS_TEST_TMPDIR/asdir.md"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$BATS_TEST_TMPDIR/asdir.md" "$PROMPT"
  echo "$output"
  [ "$status" -eq 2 ]
  [[ "$output" == *"output path is a directory"* ]]
}

@test "consult: a failed quarantine write does not delete the body" {
  # Executed by the red-team: <output>.unattributed was made a directory, the
  # redirection failed, and the script deleted the only copy of the body while
  # printing "Body kept". The round-1 destruction defect on another branch.
  _log_for deepseek
  echo "FINDINGS NOBODY SHOULD LOSE" > "$OUT.stdout"
  mkdir -p "$OUT.unattributed"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"QUARANTINE FAILED"* ]]
  # The body survives where it was, rather than being deleted for a tidy log.
  [ -f "$OUT.stdout" ]
  grep -q "FINDINGS NOBODY SHOULD LOSE" "$OUT.stdout"
}

@test "consult: the session prefix length is measured, not assumed" {
  # The finding that rejected round 2: the script searched for a 24-character
  # session prefix while the log writes 20, matched nothing on every real run,
  # and refused two attributable reviews. The fixtures passed because they used
  # synthetic tags long enough for the constant.
  #
  # This drives a log written with the REAL truncation and a full-length
  # session id, which is the pair that failed.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  local full="session_mouse_1785528404066_0f57a143f3cff2d8"
  local truncated="${full:0:20}"
  printf '[%s] [INFO] [ses:%s|prv:OpenAI|mod:gpt-5.6-sol] real shape\n' "$now" "$truncated" > "$LOG"
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$full" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "served_provider: openai" "$OUT"
}

@test "consult: no prefix short enough to match is still a refusal" {
  # The floor matters in the other direction: shortening until something
  # matches would eventually match anything.
  local now; now="$(date -v+60S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d '+60 seconds' '+%Y-%m-%d %H:%M:%S')"
  printf '[%s] [INFO] [ses:session_unrelated_9999|prv:OpenAI|mod:gpt] other\n' "$now" > "$LOG"
  echo "BODY" > "$OUT.stdout"
  run env CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="session_mouse_1785528404066_0f57a143f3cff2d8" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [ ! -f "$OUT" ]
}

@test "consult: a report the agent wrote itself is not replaced by the transcript" {
  # In checkout mode the reviewing agent writes the artifact at the path it was
  # given. The first version always rebuilt the output from the captured
  # console transcript and moved it into place, destroying the report and
  # leaving a log of thinking-tokens and tool calls in its place. Two clean
  # reviews were lost that way before anyone noticed, and their findings had to
  # be read out of the transcript.
  _log_for openai
  printf 'THE AGENT REPORT\n\nverdict: REJECT\n' > "$OUT"
  printf 'console transcript, tool calls, token counts\n' > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "THE AGENT REPORT" "$OUT"
  grep -q "verdict: REJECT" "$OUT"
  grep -q "^served_provider: openai" "$OUT"
  # and the transcript survives beside it, as evidence rather than as the report
  [ -f "$OUT.transcript" ]
  grep -q "console transcript" "$OUT.transcript"
  ! grep -q "console transcript" "$OUT"
}

@test "consult: with no agent report, the transcript becomes the artifact" {
  _log_for openai
  rm -f "$OUT"
  printf 'the only output there was\n' > "$OUT.stdout"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q "the only output there was" "$OUT"
}

# ── Round-4 blocking conditions ────────────────────────────────────────────

@test "consult: a symlinked .tmp is refused, not written through" {
  # Round 4: "the material new defect — same class as round 1's destruction, on
  # the two redirect paths nobody guarded." Both `> ${OUTPUT}.tmp` and the
  # quarantine redirect follow a symlink and write wherever it points.
  _log_for openai
  printf 'AGENT REPORT\n' > "$OUT"
  printf 'transcript\n' > "$OUT.stdout"
  target="$BATS_TEST_TMPDIR/elsewhere.txt"
  printf 'DO NOT OVERWRITE ME\n' > "$target"
  ln -s "$target" "$OUT.tmp"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -ne 0 ]
  grep -q "DO NOT OVERWRITE ME" "$target"
}

@test "consult: a symlinked quarantine path is refused, not written through" {
  _log_for deepseek
  printf 'FINDINGS\n' > "$OUT.stdout"
  target="$BATS_TEST_TMPDIR/quarantine-elsewhere.txt"
  printf 'DO NOT OVERWRITE ME EITHER\n' > "$target"
  ln -s "$target" "$OUT.unattributed"
  run env CONSULT_AUTHORIZED=1 CONSULT_LOG="$LOG" CONSULT_SKIP_RUN=1 CONSULT_TEST_SESSION="$SESSION" \
      bash "$CONSULT" openai gpt-5.6-sol "$OUT" "$PROMPT"
  echo "$output"
  [ "$status" -eq 1 ]
  grep -q "DO NOT OVERWRITE ME EITHER" "$target"
  # and the body is not destroyed by a quarantine that could not be written
  [ -f "$OUT.stdout" ] || [ -f "$OUT.unattributed" ]
}
