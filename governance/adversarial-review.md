# Adversarial review template

Standing prompt for red-teaming **code, gates and mechanisms**. The sibling of
`governance/consultation-prompt.md`, which covers constitutional text.

Send this verbatim, plus the complete raw diff. Never a summary of the diff.

## Why this exists in this exact shape

On 2026-07-25 this repository produced seven defects in one day. Every one had
the same shape: **something returned the right-looking answer for the wrong
reason.**

- A consumption sensor counted coincidental words and reported 63 findings, none real.
- Its replacement used a regex that could never match, and reported zero forever.
- The test written to catch that carried its own copy of the pattern, so it passed regardless.
- Its fixture put the target on the same line as a second pattern, so it passed through the wrong channel.
- A CI gate never fired in CI at all, and its inaugural act was to be evaded by its own author.
- Tests passed locally and failed on CI because the environment was an unstated input.
- A hash function silently substituted a different file version when its input was missing.

None was an architectural misjudgement. None was carelessness — each was
produced attentively, reviewed, and shipped. What they defeated was *reading*.
What caught them, without exception, was a machine or a model that did not write
them.

So the questions below are not "is this correct". Asking "is this correct"
returns "yes" for every defect on that list.

---

## The prompt

You are an independent red-team reviewer. Do not modify any file except the
report named at the end. Do not commit, push, or merge.

Read `CLAUDE.md`, `docs/operator-lessons.md`, and the relevant procedure docs
before judging anything. The change under review is the raw diff appended below,
in full. It was written by an AI operator or a builder it dispatched.

Answer these, in order of how much they matter:

**1. How do you defeat this?** Not "is it correct" — assume a motivated party who
wants the outcome the mechanism forbids. Enumerate the cheapest evasions. Mark
each one you actually executed, and say how long it took. An evasion you
demonstrated is worth more than five you imagined.

**2. Does it fire in the environment it was built for?** Local success is weak
evidence. For anything touching CI: does it run under a detached HEAD, a shallow
clone, an absent environment variable, a missing binary? Check the workflow
files, not the intent. A gate untested under real runner conditions is a prop.

**3. Which of its checks are untested?** Break each check in turn and confirm the
suite goes red. Any check whose removal leaves the tests green is not tested,
whatever the coverage says. Report the mutations you ran and what happened. If a
test re-declares a pattern, constant or command line that production also
declares, it passes when production breaks — say so.

**4. What does it prove, versus what does it claim?** State the gap plainly.
Overclaiming is worse than the underlying weakness, because it invites trust the
mechanism cannot carry. If the honest claim is much weaker than the apparent
one, the documentation must say so.

**5. Which failure mode looks like success?** Find the paths where an error, an
absence or a missing dependency produces a plausible value instead of a refusal.
`|| true`, silent fallbacks, empty-result-on-error, defaults that fill in for
missing data. Each is a place where "it worked" and "it could not run" are
indistinguishable.

**6. What would nobody notice during a long unattended session?** No human is
watching. What accumulates, drifts, or silently degrades?

**7. Anything else materially wrong or dangerous.**

Be blunt. Recommend rejection if warranted. A rubber-stamp review is worse than
no review, because it manufactures the appearance of a check.

If you approve **with conditions**, return `verdict: REJECT` and list them.
An `APPROVE` carrying unmet blocking conditions has already been merged past
once in this repository, because the reader stopped at the verdict line.

End with a line reading exactly `verdict: APPROVE` or `verdict: REJECT`.

---

## For the operator receiving the review

Read the whole document, not the verdict line. That specific failure — reading
`verdict: APPROVE` and merging past a numbered blocking condition below it —
put an unratified constitutional amendment onto `main`. See #55.
