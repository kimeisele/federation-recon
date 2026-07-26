# AGENTS.md

Entry point for any agent operating this repository, regardless of vendor.

`CLAUDE.md` is this repository's **constitution** — the risk envelope, the
operator loop, the limits. It is read by one vendor's tooling because of its
filename, not because its contents are vendor-specific. Read it. Everything in
it applies to you.

## Start here, in this order

| File | What it is |
|---|---|
| `docs/operator-handover.md` | how an operator works here: spec, dispatch, gate, integrate |
| `CLAUDE.md` | constitution, risk classes, what is never auto-executed |
| `docs/operator-lessons.md` | what previous sessions learned expensively |
| `STATE.md` | current federation state, the composed digest |
| the open work-log issue | narrative of the last session, decisions and why |

Then:

```
bash scripts/gate.sh          # every check that must pass before anything merges
bash scripts/gate.sh --full   # adds the reproduce fixpoint (needs network)
```

## The one thing to understand before touching anything

This repository has documented **ten defects** whose shared shape is: *something
returned the right-looking answer for the wrong reason.* A sensor that counted
coincidental words. A regex that could never match. A test carrying its own copy
of the pattern it was written to guard. A CI gate that never fired in CI. A hash
function that silently substituted a different file version.

Not one of them was found by care. Every one was found by executing something,
by mutating a check to see whether it fails, or by a model from a different
vendor that did not write the code.

So the operating rule here is not "be careful". It is:

- **run it** — when a claim depends on how a tool behaves, execute it; never
  reason from memory about regex dialects, flag semantics, or platform features;
- **mutate it** — a check you have never seen fail is an assumption. Break what
  it guards and confirm it goes red;
- **have someone else look** — risk class HIGH requires review by a model from a
  different provider, using `governance/adversarial-review.md`. The author of a
  specification cannot audit their own blind spot.

## Vendor neutrality

Nothing here depends on a particular model. The gate is a shell script, the
checks are shell and Python, the reviewers are named by the *property* they must
have — a different provider, no session context — rather than by brand
(`governance/reviewers.md` holds the current roster, deliberately outside the
constitution so it can rot without amending anything).

If you are a different vendor's agent than the last one: you are expected to
operate at the same standard, and everything you need is in the repository
rather than in a chat transcript. If you find that untrue, that is a defect
worth filing.
