#!/usr/bin/env bats
# consultation-provenance.bats — the gate that would have caught 2026-07-31.
#
# Three consultations named a provider that had not answered them. They were
# committed, cited in a merge decision, and read as independent judgments. The
# repository had a written rule against exactly this and no mechanism behind
# it, so the rule held for the provider someone remembered to apply it to.
#
# These tests use fixture directories rather than the real one, so they keep
# testing the rule after the real directory changes.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  # shellcheck disable=SC1091
  source "$REPO_ROOT/scripts/lib/consultation-provenance.sh"
  D="$BATS_TEST_TMPDIR/consultations"
  mkdir -p "$D"
}

_proven() {
  # reviewer_claim is required and must agree with served_provider: the
  # authoritative claim lives in the record, not in the filename and not in
  # free text, because a body may mention any number of models.
  printf '<!-- provenance\nrequested_provider: %s\nserved_provider: %s\nreviewer_claim: %s\nmodel: m\n-->\n\nbody\n' "$1" "$1" "$1" > "$D/$2"
}

@test "provenance: a proven consultation passes" {
  _proven openai "10-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "provenance: a consultation naming a provider with no evidence FAILS" {
  # The 2026-07-31 artifact, exactly: a filename claiming a provider and
  # nothing in the file that could establish it.
  printf 'a plausible review\n' > "$D/11-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"11-sol.md"* ]]
  [[ "$output" == *"no provenance record"* ]]
}

@test "provenance: a block claiming one provider while served by another FAILS" {
  # The failure with the evidence present and contradicting the name. A gate
  # that only checked for the presence of a block would pass this.
  printf '<!-- provenance\nrequested_provider: openai\nserved_provider: deepseek\nreviewer_claim: openai\nmodel: m\n-->\nbody\n' > "$D/12-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contradict itself"* ]]
}

@test "provenance: a block with no served_provider FAILS" {
  printf '<!-- provenance\nrequested_provider: openai\nreviewer_claim: openai\nmodel: m\n-->\nbody\n' > "$D/13-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplete provenance record"* ]]
}

@test "provenance: an UNVERIFIED entry admits the file without proving it" {
  printf 'a review from before the control existed\n' > "$D/14-sol.md"
  printf '14-sol.md\n    produced before any evidence was recorded\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"registered as unproven"* ]]
}

@test "provenance: the register does not cover a file it does not name" {
  printf 'x\n' > "$D/15-sol.md"
  printf 'x\n' > "$D/16-kimi.md"
  printf '15-sol.md\n    a reason long enough to satisfy the register grammar\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"16-kimi.md"* ]]
  [[ "$output" != *"FAIL — 15-sol.md"* ]]
}

@test "provenance: the filename decides nothing at all" {
  # This used to assert that filename tokens were mapped to providers — 'sol'
  # to openai, 'kimi' to moonshot. The gate no longer reads filenames, because
  # a red-team both walked past the token list with a neutral name AND used a
  # neutral name to hide a record that contradicted the body.
  #
  # Rewritten rather than deleted, and inverted: a filename that flatly
  # disagrees with the record must now be irrelevant, because the record is the
  # authoritative claim. A test kept as scenery after its premise was removed is
  # the thing this file exists to catch elsewhere.
  _proven openai "17-kimi.md"        # named kimi, served openai
  _proven moonshot "18-sol.md"       # named sol, served moonshot
  _proven claude "19-totally-unrelated.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 carrying a consistency record"* ]]
}

@test "provenance: files naming no provider are checked too, and must be registered" {
  # This asserted the opposite until a red-team walked past the gate by
  # choosing a filename outside the token list. Every .md is now checked; a
  # file that genuinely makes no provider claim says so in the register, which
  # costs one line and removes an entire class of evasion.
  printf 'a prompt, not a consultation\n' > "$D/20.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"20.md"* ]]

  printf '20.md\n    a prompt rather than a consultation; it claims no provider\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "provenance: a missing directory is a failure, not an empty pass" {
  run check_consultation_provenance "$BATS_TEST_TMPDIR/does-not-exist"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "provenance: the real consultations directory passes today" {
  # Not a tautology: it fails the moment a new consultation lands without
  # evidence and without an entry, which is the whole point.
  run check_consultation_provenance "$REPO_ROOT/governance/consultations"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "provenance: the register records WHY, not just WHICH" {
  # A register of bare filenames would be a mute allowlist. Every entry has to
  # carry a reason, or the register becomes the loophole it is meant not to be.
  run python3 -c "
import re, sys
lines = open('$REPO_ROOT/governance/consultations/UNVERIFIED').read().split('\n')
bare = []
for i, l in enumerate(lines):
    if not (l.endswith('.md') and not l.startswith('#')):
        continue
    # A run of filenames may share one reason — the reason follows the last of
    # them. Walk forward past any further filenames, then require prose.
    j = i + 1
    while j < len(lines) and lines[j].endswith('.md') and not lines[j].startswith('#'):
        j += 1
    tail = [x for x in lines[j:j+4] if x.strip() and not x.endswith('.md')
            and not x.startswith('#') and not x.startswith('##')]
    if not tail or len(' '.join(tail).strip()) < 40:
        bare.append(l)
assert not bare, 'entries with no reason: %s' % bare
print('every register entry carries a reason')
"
  echo "$output"; [ "$status" -eq 0 ]
}

@test "provenance: a file whose name avoids the token list is still checked" {
  # The red-team's gate evasion, executed: the first version inferred the claim
  # from the filename against a token list, so `137-independent-review.md` was
  # never looked at. A gate a filename can walk past is a naming convention.
  #
  # Demonstrated on this repository's own corpus, too: 105.md, 107.md, 42.md,
  # 53.md, 66.md and 71.md each name a reviewer in their body and none in their
  # filename. Six artifacts no check had ever examined.
  printf 'a plausible review by some model\n' > "$D/30-independent-review.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"30-independent-review.md"* ]]
}

@test "provenance: a comment naming a file is not an allowlist entry" {
  # Also executed by the red-team. The lookup was `grep -qF "$base"`, so a
  # comment mentioning a filename admitted it. The register is a list of claims
  # the repository has stopped making; a prose mention is not such a claim.
  printf 'x\n' > "$D/31-sol.md"
  printf '# we should look at 31-sol.md one day\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"31-sol.md"* ]]

  # And an anchored, uncommented entry does admit it.
  printf '31-sol.md\n    a reason long enough to say something real about it\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "provenance: a partial filename in the register does not admit a file" {
  printf 'x\n' > "$D/32-sol.md"
  printf 'x\n' > "$D/32-sol.md.backup.md"
  printf '32-sol.md\n    reason enough to be a real entry in this register\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"32-sol.md.backup.md"* ]]
}

@test "provenance: a SELFTEST block is not evidence" {
  # consult.sh stamps SELFTEST when its test path is used, because that path
  # contacts no provider. The red-team forged an accepted artifact through it;
  # the stamp is what makes the forgery visible here.
  printf '<!-- provenance\nrequested_provider: openai\nserved_provider: openai\nreviewer_claim: openai\nmodel: m\nconsistency_check: scripts/consult.sh SELFTEST — no provider was contacted, NOT EVIDENCE\n-->\nbody\n' > "$D/33-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SELFTEST"* ]]
}

# ── Round-2 gate omissions, each executed by the reviewer in about a second ─

@test "provenance: a nested markdown file is checked" {
  mkdir -p "$D/sub"
  printf 'unproven\n' > "$D/sub/review.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sub/review.md"* ]]
}

@test "provenance: a hidden markdown file is checked" {
  printf 'unproven\n' > "$D/.review.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *".review.md"* ]]
}

@test "provenance: an uppercase or long extension is checked" {
  printf 'unproven\n' > "$D/review.MD"
  printf 'unproven\n' > "$D/other.markdown"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"review.MD"* ]]
  [[ "$output" == *"other.markdown"* ]]
}

@test "provenance: a symlink is refused, live or dangling" {
  _proven openai "40-sol.md"
  ln -s "$D/40-sol.md" "$D/41-live-link.md"
  ln -s "$D/nowhere.md" "$D/42-dangling.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"41-live-link.md is a symlink"* ]]
  [[ "$output" == *"42-dangling.md is a symlink"* ]]
}

@test "provenance: a provenance block must open the file" {
  # The renamed-quarantine attack: a body with a block further down passed.
  printf 'some review body\n\n<!-- provenance\nserved_provider: openai\nreviewer_claim: openai\nmodel: m\n-->\n' > "$D/43-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not start the file"* ]]
}

@test "provenance: a renamed quarantine is refused" {
  printf 'UNATTRIBUTED CONSULTATION OUTPUT — NOT A CONSULTATION\n\nbody\n' > "$D/44-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quarantine sentinel"* ]]
}

@test "provenance: two provenance blocks are refused" {
  printf '<!-- provenance\nserved_provider: openai\nreviewer_claim: openai\nmodel: m\n-->\nbody\n<!-- provenance\nserved_provider: deepseek\n-->\n' > "$D/45-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"provenance blocks"* ]]
}

@test "provenance: the record must name its reviewer, and not contradict itself" {
  # The neutral-filename attack: a body claiming Sol with a record saying
  # DeepSeek passed, because the claim was inferred from the filename. The
  # authoritative claim now lives in the record.
  printf '<!-- provenance\nserved_provider: deepseek\nreviewer_claim: openai\nmodel: m\n-->\nReviewer: Sol 5.6\n' > "$D/46-independent-review.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"must not contradict itself"* ]]

  printf '<!-- provenance\nserved_provider: deepseek\nmodel: m\n-->\nbody\n' > "$D/46-independent-review.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplete provenance record"* ]]
}

@test "provenance: the register matches literally, not as a regex" {
  # Executed: the register said `attackXmd` and it admitted `attack.md`,
  # because the filename was handed to grep as a basic regular expression.
  printf 'unproven\n' > "$D/attack.md"
  printf 'attackXmd\n    a reason long enough to look like a real register entry\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"attack.md"* ]]
}

@test "provenance: an empty inventory is a failure, not a pass" {
  # A broken enumeration and a clean directory give the same answer, and only
  # one of them is good news.
  rm -f "$D"/*.md "$D"/UNVERIFIED 2>/dev/null || true
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty inventory"* ]]
}

# ── Round-3 executed evasions ──────────────────────────────────────────────

@test "provenance: body lines cannot supply the record's fields" {
  # Executed: the opener and requested_provider appeared first, the block
  # CLOSED, and body lines later supplied served_provider, reviewer_claim and
  # model. The parser read the whole file, so the body wrote the record.
  printf '<!-- provenance\nrequested_provider: openai\n-->\n\nserved_provider: openai\nreviewer_claim: openai\nmodel: m\n' > "$D/50-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"incomplete provenance record"* ]]
}

@test "provenance: an unclosed block is refused" {
  # Without a closer every line of the body is inside the record.
  printf '<!-- provenance\nserved_provider: openai\nreviewer_claim: openai\nmodel: m\n\nbody with no closer\n' > "$D/51-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"never closed"* ]]
}

@test "provenance: a duplicated field is refused rather than resolved" {
  # Executed: served_provider appeared twice, openai then deepseek, and
  # `head -1` silently chose openai. Which copy counts is not a question a
  # record should be able to raise.
  printf '<!-- provenance\nserved_provider: openai\nserved_provider: deepseek\nreviewer_claim: openai\nmodel: m\n-->\nbody\n' > "$D/52-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"repeats provenance field"* ]]
}

@test "provenance: CRLF line endings do not smuggle values through" {
  # Executed: the opener used LF while the field lines used CRLF, and the
  # carriage returns survived into the values.
  printf '<!-- provenance\r\nserved_provider: openai\r\nreviewer_claim: openai\r\nmodel: m\r\n-->\r\nbody\r\n' > "$D/53-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "provenance: a register entry with no reason does not admit a file" {
  # Executed: an unproven file was registered with no reason at all and the
  # gate admitted it. A bare filename makes no claim about anything.
  printf 'unproven\n' > "$D/54-sol.md"
  printf '54-sol.md\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no reason"* ]]

  printf '54-sol.md\n    produced before any evidence was recorded, and not re-runnable\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "provenance: the gate uses no pipe into a short-circuiting reader" {
  # The third instance in one day. `tr … | grep -q` reports 141 under
  # `set -o pipefail`, because grep exits at its first match and tr takes
  # SIGPIPE — so a present closer read as absent and the gate rejected two
  # reports whose `-->` sat on line 10.
  #
  # Comments stripped first: this block explains the defect by naming the
  # construct, which is how the equivalent test was first satisfied by prose.
  run bash -c "sed 's/#.*//' '$REPO_ROOT/scripts/lib/consultation-provenance.sh' | grep -nE '\\| *grep -q'"
  echo "$output"
  [ -z "$output" ]
}

# ── Round-3 conditions still open: written first, builder implements ───────

@test "provenance: markdown under an unreadable directory is not silently skipped" {
  # Round 3, executed: `find` cannot descend into a directory it may not read,
  # and printed nothing while the gate reported success. Files hidden that way
  # are invisible, and invisible is the one thing this gate exists to prevent.
  mkdir -p "$D/locked"
  printf 'unproven\n' > "$D/locked/hidden.md"
  chmod 000 "$D/locked"
  run check_consultation_provenance "$D"
  chmod 755 "$D/locked"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"locked"* ]]
}

@test "provenance: a symlinked directory is refused, not traversed" {
  mkdir -p "$D/real"
  printf 'unproven\n' > "$D/real/inside.md"
  ln -s "$D/real" "$D/linked"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"linked"* ]]
}

@test "provenance: the quarantine sentinel is refused anywhere in the header region" {
  # The policy header says "anywhere in the file"; the implementation checks
  # the first three lines. Round 3 put it on line four and it passed. Either
  # the check or the policy has to move — the test says which.
  printf 'x\n\n\n\nUNATTRIBUTED CONSULTATION OUTPUT — NOT A CONSULTATION\n\nbody\n' > "$D/60-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"quarantine sentinel"* ]]
}

@test "provenance: a filename containing a newline is handled, not split" {
  # find -print0 exists for this. A path that splits mid-name either escapes
  # the check or produces a nonsense one, and both are worse than an error.
  printf 'unproven\n' > "$D/weird
name.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"weird"* ]]
}

@test "provenance: a file added during the scan is not silently omitted" {
  # Round 3 executed it and round 4 kept it blocking: 1,200 files were checked
  # while `late.md` was created mid-scan, and the gate exited 0 having never
  # looked at it. An enumeration that reports success about a set it did not
  # finish observing is the defect this whole gate exists for.
  for i in $(seq 1 60); do _proven openai "bulk-$i-sol.md"; done
  ( sleep 0.3; printf 'unproven\n' > "$D/late.md" ) &
  run check_consultation_provenance "$D"
  wait
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "provenance: the OK line does not use the word the repository renounced" {
  # Round 4: "the downgrade is incomplete where the gate speaks — the library's
  # own OK line prints '$proven with a provenance record', and the variable and
  # the word the repository renounced still mint the summary."
  #
  # The header says this is a consistency alarm and not proof of independence.
  # The success line has to say the same thing.
  _proven openai "70-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 0 ]
  # The POSITIVE claim, not the substring. This first asserted that "proven"
  # did not appear at all, which also forbids "registered as unproven" — the
  # honest half of the sentence. The test was wrong and the implementation was
  # right; a blunt assertion that rejects the correct wording is a test that
  # would have driven the code somewhere worse.
  [[ "$output" != *"with a provenance record"* ]]
  ! [[ "$output" =~ [0-9]+\ proven ]]
  # and it must still say the honest half
  [[ "$output" == *"unproven"* || "$output" == *"unverified"* ]]
}
