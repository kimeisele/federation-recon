# Operator lessons

Durable, hard-won knowledge for anyone operating this repository — human or
agent. Not a constitution (`CLAUDE.md`) and not a decision record
(`docs/founding-decision-record.md`): this is the file that stops a future
session from re-learning something the hard way.

It lives in the repository on purpose. Agent memory is local, unversioned,
invisible to every other agent and to CI, and gone the moment the machine
changes. For a project whose stated purpose is not losing the overview, keeping
its operating knowledge outside its own repository was a structural gap.

Append when something is learned at real cost. Delete when it stops being true.

---

## Verify by running, not by reasoning

**2026-07-25.** Three defects in one session shared one shape: something
returned the right-looking answer for the wrong reason.

1. A claim that `stat -f` before `stat -c` corrupts byte accounting on Linux CI.
   Filed as a defect, used to call a change a blocker. Wrong — the repository's
   own green `reproduce-fixpoint` job already proved macOS and Linux agree.
2. A review approving the ripgrep pattern `finding-[0-9a-f]\{12\}` as "specific
   and unambiguous". In Rust regex an escaped brace is a *literal* brace, so it
   could never match a Finding ID and the F-02 count was pinned to zero forever.
3. A positive-control test written to catch (2) that carried its own copy of the
   pattern, so it passed no matter what production did — and a fixture with the
   Finding ID on the same line as the repository slug, so the test passed
   through the wrong channel even when the right one was broken.

Every one was a single command away from being settled. Reasoning about tool
semantics from memory — regex dialects, flag behaviour, GNU vs BSD, quoting — is
where this operator is least reliable and most confident.

**Apply:** run it before asserting it. State unverified claims as unverified.

## Do not verify a property by proxy

The three worst mistakes of 2026-07-25 were all the same move: checking something
*adjacent* to the claim instead of the claim itself.

- Reasoned about what `stat -f` does on Linux instead of running it.
- Reviewed *which* regex to keep instead of testing whether the survivor matched.
- Counted how many messages had a populated `correlation_id` instead of reading
  the one that did.

The third was the most expensive. The reconnaissance was itself the check, and a
`grep` for the field walked straight past an unsigned message from an unknown
source sitting in a production mailbox — a live example of the attack the
resulting specification was written to prevent. An independent reviewer found it
by opening the data.

A count is not a reading. A green check is not a working check. "Which one is
correct" is not "does it work".

**Apply:** when a claim is about data, open the data — especially the outliers,
which are where the finding usually is. When a claim is about behaviour, execute
it. When a check passes, ask what would make it fail and confirm that it does.

## Find the oracle before claiming a cross-platform defect

The `reproduce-fixpoint` job runs on `ubuntu-latest`, regenerates every artifact
from committed pins, and diffs against the committed set — which was generated
on macOS. It is therefore a **macOS-versus-Linux equivalence check on every
PR**, not a Linux-versus-Linux one. Any cross-platform divergence reaching a
committed artifact fails it.

Consult it before theorising. It is cheaper than being wrong in public.

## A test that duplicates what it guards is not a test

If a test re-declares a pattern, a command line, or a constant that production
also declares, it passes when production breaks. Share the definition — see
`scripts/lib/consumption-patterns.sh` — and prove the sharing works by
**mutation**: break the production value and confirm the suite goes red. A
positive control that has never been observed to fail is an assumption.

Related: `|| true` around a tool invocation makes "tool missing" indistinguishable
from "found nothing". Assert the dependency exists.

## The red-team requirement earns its cost

`CLAUDE.md` requires independent review from a different provider for risk-class
HIGH work. On the day it was first exercised it caught a defect the operator had
personally reviewed and approved, and a second one in the operator's own fix.

This is not a failure of care. The author of a specification cannot audit their
own blind spot — that is structural, and no amount of diligence substitutes for
a reviewer who did not write the thing.

Reviewers must be a **different provider**, not merely a different model:
Fable 5 shares a provider with an Anthropic-hosted operator and is therefore not
independent for operator-authored work. `governance/reviewers.md` has the roster.

## Check the manifest before believing a scope claim

Twice in one session the operator was about to report scope violations that were
not there — a procedure inheriting an already-committed observed set, and a bash
idiom already used throughout the codebase. Both were minutes of checking away.

Being wrong in a review costs more than the check does.
