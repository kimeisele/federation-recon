# Adversarial review template

Standing prompt for red-teaming **code, gates and mechanisms**. The sibling of
`governance/consultation-prompt.md`, which covers constitutional text.

**Checkout mode, not diff mode.** Run this as an agent inside a working
checkout, with the ability to execute commands. Questions 1 and 3 demand
*executed* evasions and *run* mutations; a reviewer holding only a diff can
only imagine them, and imagined answers are worth a fraction of executed ones
while looking identical in the report. If a review must be run without a
checkout, every answer to 1, 3 and 8 must be explicitly labelled **not
executed**. The cheaper mode is the weaker one and will win by default unless
this is stated.

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

**1b. Is the diff itself the attack?** Question 1 points outward at a
hypothetical attacker. Point it at the author too: does this change weaken,
narrow, bypass or delete any existing check — an added `|| true`, a narrowed
trigger path, a test removed as "flaky", a widened permission, a file list that
quietly omits one entry? Does the author benefit from that? The most probable
self-interested change is not a bad new mechanism; it is a small loosening of an
existing one.

**1c. Are the author's factual claims true?** Check every factual claim in the
PR description, the commit messages and any committed review artifact against
the repository, the data and the CI logs. This repository has shipped a PR whose
description asserted "CI rejects any PR..." while the gate never fired in CI, and
a remediation claim of "re-run live" that a timestamp disproved. Verifying the
mechanism is not verifying the author.

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

**4b. Do the change's factual premises hold?** Do not accept the premises the
change is built on. Recompute them. **Open the data and read the outliers** — the
single most damaging finding in this repository's history came from refusing the
claim "`correlation_id` is empty in all 9,874 messages", counting for oneself,
getting 9,873, and reading the one exception. A count is not a reading. Right
value and working instrument are different properties, and a mechanism can
report the correct number today while being incapable of reporting any other.

**4c. Read the substrate, not only the diff.** Most material findings here have
been in *unchanged* code the change newly depends on: an outbox cleared on
partial push, nonce state that dies with the process, a required field silently
backfilled, a scheduled job that never runs the new procedure. Read everything
the diff calls, everything meant to call the diff, the workflow files, and the
data it will run against. A diff-scoped review answers "how do you defeat this"
about new code and never learns it stands on sand.

**5. Which failure mode looks like success?** Find the paths where an error, an
absence or a missing dependency produces a plausible value instead of a refusal.
`|| true`, silent fallbacks, empty-result-on-error, defaults that fill in for
missing data. Each is a place where "it worked" and "it could not run" are
indistinguishable.

**6. What would nobody notice during a long unattended session?** No human is
watching. What accumulates, drifts, or silently degrades?

**7. Is this the right thing, not merely a correct thing?** A change can be
well-tested, fire in CI, be mutation-hardened and honestly documented — and still
entrench a bad interface, solve a problem nobody has, add an unsustainable
dependency, or ratchet the operator's authority. Every question above is
verification-shaped, because every defect that motivated them was. This one is
not. Answer it deliberately rather than letting it fall into "anything else".

**8. What is missing?** A diff shows what was added; it is structurally blind to
what was left out. The absent scheduled job, the absent positive control, the
absent question in a checklist. Ask what a complete version of this change would
contain that this one does not.

**9. Run the new mechanism against the change that introduces it.** One command,
outsized hit rate: this repository shipped a gate that failed its own PR. If the
change adds a check, execute it against its own diff.

**10. If this is a follow-up round, were the prior conditions literally met?**
Quote each numbered condition from the previous review and state whether it was
satisfied in substance and in letter. Verifying the fix is the second half of
rejecting.

**11. Anything else materially wrong or dangerous.**

Be blunt. Recommend rejection if warranted. A rubber-stamp review is worse than
no review, because it manufactures the appearance of a check.

If you approve **with conditions**, return `verdict: REJECT` and list them.
An `APPROVE` carrying unmet blocking conditions has already been merged past
once in this repository, because the reader stopped at the verdict line.

End with a line reading exactly `verdict: APPROVE` or `verdict: REJECT`.

---

## For the operator receiving the review

Not "read carefully". This repository's own thesis is that such instructions do
not work: `docs/operator-lessons.md` said "do not verify by proxy" and its author
violated it hours later. Holding every reviewed mechanism to *method, not prose*
while holding the operator's own obligation to prose is the contradiction this
section previously contained.

**The obligation is mechanical.** Before merging, commit a point-by-point
response that quotes each numbered finding from the review and states, for each,
one of: fixed (with the commit), rejected (with the reason), or deferred (with
the issue number). A finding that is not quoted has not been read. The failure
this replaces — reading `verdict: APPROVE` and merging past a numbered blocking
condition beneath it — put an unratified constitutional amendment onto `main`
(#55).

## Known gap

Nothing triggers this template. No workflow invokes it and no gate requires its
report, so by the standard of question 2 it is a prop: a review prompt that no
process invokes fires exactly as often as someone remembers. The consultation
gate covers constitutional files only. Until code red-team reports have a
required committed path, their absence is not greppable and this document is a
convention, not a control. Tracked as a follow-up; stated here rather than
omitted, because a checklist that hides its own edges is more dangerous than one
that admits them.
