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
  printf '<!-- provenance\nrequested_provider: %s\nserved_provider: %s\nmodel: m\n-->\n\nbody\n' "$1" "$1" > "$D/$2"
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
  [[ "$output" == *"no provenance block"* ]]
}

@test "provenance: a block claiming one provider while served by another FAILS" {
  # The failure with the evidence present and contradicting the name. A gate
  # that only checked for the presence of a block would pass this.
  printf '<!-- provenance\nrequested_provider: openai\nserved_provider: deepseek\nmodel: m\n-->\nbody\n' > "$D/12-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"claims 'sol' but its provenance says served by 'deepseek'"* ]]
}

@test "provenance: a block with no served_provider FAILS" {
  printf '<!-- provenance\nrequested_provider: openai\nmodel: m\n-->\nbody\n' > "$D/13-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no served_provider"* ]]
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
  printf '15-sol.md\n    reason\n' > "$D/UNVERIFIED"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"16-kimi.md"* ]]
  [[ "$output" != *"FAIL — 15-sol.md"* ]]
}

@test "provenance: model names map to their providers" {
  # 'sol' is a model of openai and 'kimi' of moonshot. A gate that compared the
  # filename token to served_provider literally would reject every correct file.
  _proven openai "17-sol.md"
  _proven moonshot "18-kimi.md"
  _proven claude "19-fable.md"
  run check_consultation_provenance "$D"
  echo "$output"; [ "$status" -eq 0 ]
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
  printf '<!-- provenance\nrequested_provider: openai\nserved_provider: openai\nmodel: m\nverified_by: scripts/consult.sh SELFTEST — no provider was contacted, NOT EVIDENCE\n-->\nbody\n' > "$D/33-sol.md"
  run check_consultation_provenance "$D"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SELFTEST"* ]]
}
