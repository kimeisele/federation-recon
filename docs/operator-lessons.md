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

## Regenerate consultation diffs with the exclusion pathspec

**2026-07-30.** `git diff main...HEAD` without exclusion includes the previous
consultation diff artifact in its own diff, compounding the size on every
regeneration (2047 lines became 4756 in S1 — roughly half of it a copy of
itself).  A reviewer receiving that artifact is handed the old diff twice and
the new work once.

Canonical command:

```bash
git diff main...HEAD -- . ':(exclude)governance/consultations/*.diff'
```

The guard `scripts/test/consultation-diff-hygiene.bats` (registered in
MANIFEST) checks for this defect.  If it fails, regenerate with the exclusion
pathspec above.


## An observation that cannot be checked cannot be merged

**2026-07-30.** Five daily observations accumulated as open pull requests, none
mergeable, for two reasons that both looked like policy and were not.

The census opened its pull request with `${{ github.token }}`. GitHub does not
trigger workflows from events created by `GITHUB_TOKEN` — a deliberate guard
against a workflow triggering itself. So the observations received **zero**
checks while the branch ruleset required two, and were permanently `BLOCKED`.
Nothing was misconfigured in the ruleset; the identity of the token silently
decided that no check would ever run.

Separately, a live run's output was never a fixpoint: all three procedures froze
derived timestamps only in `--reproduce`, so a live run stamped each artifact
with the wall clock at the moment it was written while reproduce flattened them
to the run timestamp. An observation could not reproduce itself, so it could not
have passed the fixpoint check even if the check had run.

Two independent structural blocks, both invisible as long as nobody asked *why*
the queue was growing. The queue looked like a backlog. It was a delivery
failure, and an observatory whose record never lands has produced nothing.

**When a pull request shows no checks at all, ask who opened it before asking
what is wrong with the checks.**

## An environment variable silently outranks the credential you configured

**2026-07-30.** `gh secret set` failed with `HTTP 403: Resource not accessible by
personal access token`, pointing at the token that was being *stored* rather than
the one doing the storing.

The cause: `gh auth status` showed a keyring OAuth login with the `repo` scope,
which may write secrets. But `~/.config/secrets/env` also exports `GH_TOKEN`, and
**`gh` prefers the environment variable over the keyring**. That variable held a
fine-grained PAT without the Secrets permission. Measured, same command twice:

```
with GH_TOKEN in the environment:  HTTP 403
env -u GH_TOKEN:                   rc=0
```

The remedy is per-command: `env -u GH_TOKEN gh …`.

This is the second instance of the same shape in one day. `jcode run` ignored the
`JCODE_PROVIDER` / `JCODE_MODEL` variables recorded as its canonical invocation,
took a different path, and **failed over to a model from the operator's own
provider** — surfacing only because that model demanded credits. Both times a
tool consulted a source of configuration the operator was not thinking about, and
both times the error message named the wrong thing.

**When a credential error names the wrong actor, ask which credential the tool
actually picked up before adjusting permissions.** Permissions were never the
problem in either case.

## A search that skips a file reports the same thing as a search that finds nothing

While writing `core/orders/CONTRACT.md` I put a literal NUL byte into it — a
markdown line describing forbidden control characters, written with the
character instead of its name. Then:

```
grep -c intent core/orders/CONTRACT.md    → no output, exit 1
/usr/bin/grep -c intent CONTRACT.md       → 2
grep -ac intent CONTRACT.md               → 2
```

`grep` in this environment is a shell function wrapping ugrep with `-I`, which
skips files it classifies as binary. One NUL byte makes a 7 kB markdown file
binary. The file was skipped **silently**: no warning, no diagnostic, exit 1 —
byte-identical to the answer for a file that was read and did not match.

The same byte made an `Edit` on that line fail to match, and the two symptoms
looked like two unrelated tool problems.

**A zero-result search establishes nothing until you know the file was read.**
The failure mode is not "the tool lied" — it is that *not looked at* and *looked
at, absent* are the same output, and only one of them is evidence. The general
form is the one this document keeps recording under different names: an absence
that could be either a measurement or a gap, treated as a measurement.

Three habits, in order of cost:

- When a search of a file you just wrote comes back empty, suspect the search
  before the file.
- `/usr/bin/grep` and `grep -a` are the cross-checks, and they cost one command.
- Never write a control character into a text file to describe one. Write
  `U+0000`. The file that documents the hazard is the file that had it.

Related: the `sh -n` on a bash script, and the grep pipeline that counted
itself — three instances in which the *instrument*, not the code under test,
produced the wrong answer. The instrument is not outside the system.
