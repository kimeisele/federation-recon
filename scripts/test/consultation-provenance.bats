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

@test "provenance: files that name no provider are not checked" {
  printf 'a prompt, not a consultation\n' > "$D/20.md"
  printf 'operator response\n' > "$D/21-operator-response.md"
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
    if l.endswith('.md') and not l.startswith('#'):
        tail = [x for x in lines[i+1:i+4] if x.strip() and not x.endswith('.md')]
        if not tail or len(' '.join(tail).strip()) < 40:
            bare.append(l)
assert not bare, 'entries with no reason: %s' % bare
print('every register entry carries a reason')
"
  echo "$output"; [ "$status" -eq 0 ]
}
