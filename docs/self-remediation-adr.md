# ADR — Self-remediation: what Recon may repair about itself

**Status:** **Accepted** (2026-08-01). The scope is narrow and deliberately so:
it decides where the line between *maintenance* and *remediation* falls for
this repository, and nothing about any other repository.

*Accepted* rather than *Proposed* because the owner instructed on 2026-08-01
that this contradiction be settled by an ADR going "durch das Änderungslog wie
jeder andere", and because an independent cross-provider review returned
APPROVE against this text. A reviewer noted that the status was Accepted while
still under review; that was true of an earlier revision, and this one carries
the review it was missing (`governance/consultations/152.md`).

**Occasion:** PR #150 merged with a contradiction written into it rather than
smoothed over. §5.1 permits supervision of a sandboxed builder including
"orphan reconciliation"; FR-CON-002's carve-out forbids Recon from healing
itself "in response to its own observations". A supervisor that detects an
orphan of its own run and cleans it up satisfies both descriptions. The
reviewer of #150 found it; the owner decided it should be resolved by an ADR
rather than by rewording.

---

## 1. What is actually in dispute

Not a hypothetical. `reconcile()` in `core/backends/macos_seatbelt.py:872`
does three things:

| effect | target |
|---|---|
| removes a run directory whose id no longer matches a claimed slot | `runs/<run_id>/` under the sandbox state root |
| releases a slot claim no live run holds | `slots/<n>/` under the same root |
| **reports** processes running under an unclaimed slot uid | nothing — it prints |

It is called at launcher startup and after every run
(`core/launcher.py:108,259,288`). It does not touch repository content, does
not open a pull request, does not read `findings/`, and **does not kill
anything** — the killing question is #134 and is OWNER-ONLY / STOP.

So the contradiction is real but narrow: the thing §5.1 permits and the
carve-out appears to forbid is *the supervisor deleting its own bookkeeping
directories after its own crash.*

The wider question the contradiction exposes is not narrow at all, and a
reviewer of #150 put it as a reductio worth quoting:

> the census finds federation-recon's sandbox permits egress and records it as
> a Finding; the fix PR is now constitutionally prohibited — so it will be
> relabeled "maintenance," and the line dissolves on contact with the first
> security defect.

Any resolution that cannot answer that is not a resolution.

---

## 2. The two candidate fassungen

### (a) FR-CON-002 gains an exception for effects on Recon's own runtime

FR-CON-002 reads: *"Recon may not modify observed repositories, open
remediation pull requests, merge changes, or execute healing actions."* Under
(a) the invariant is scoped by **where the effect lands**: another repository,
or this repository's *content*, or this repository's *runtime state*. The
third is exempt.

- **Fundstelle for the shape:** §5.1 draws a test of the same *kind* for
  "executor" — *"the line is drawn by whose repository the effect lands in,
  not by whether a process starts"* (`docs/founding-package-v0.2.md` §5.1).
  It is not the same line: §5.1's is two-way (this repository or another),
  (a)'s is three-way (another repository / this one's content / this one's
  runtime). Same kind of test along a new axis, which is a weaker claim than
  an earlier draft made and is the accurate one.
- **Fundstelle for the boundary being checkable:** `scripts/test/layer-boundary.bats`
  already enforces that `core/` references nothing in the evidence layer, in
  either direction. "Runtime state" is therefore not a rhetorical category —
  it is the set of paths `core/` is permitted to touch, and a check exists
  that fails when that set grows into the artifact tree.

### (b) Orphan reconciliation leaves §5.1; each case becomes an owner decision

Under (b) §5.1's permitted column loses "orphan reconciliation", and a crashed
run's leftovers wait for the owner, as #134 does.

- **Fundstelle for the precedent:** #134 is exactly this treatment for the
  *process* case, and it has held — the reaper is not built, the sandbox
  reports strays and stops (`core/launcher.py:316-324`).
- **Fundstelle for the cost:** `reconcile()` runs at every launcher startup and
  after every run (`core/launcher.py:108,259,288`). Under (b), each run that
  *finds* an orphan becomes a governance event — not each run, which is what
  an earlier draft said and a reviewer corrected. The rate is the crash rate,
  which is also #134's rate, and #134 has held.

### (a+b) the hybrid, weighed because it exists

The narrowing in §4.3 — protect the record, permit the repair — is logically
separable from the exemption. **(b) plus the narrowing answers the reductio
too**, and an earlier draft of this ADR weighed only the diagonal of a
two-by-two, which is not weighing two fassungen. Stated properly, the matrix
is *exemption × narrowing*, the narrowing is required in every quadrant that
survives, and the remaining question is only whether the runtime exemption is
worth having on top of it.

---

## 3. Weighing them against each other

**Reviewability.** (b) is trivially reviewable and (a) requires defining
"runtime state" precisely enough that it cannot swallow the artifact tree.
That definition exists as a check rather than a sentence, which is the form
this repository has learned to trust. **Slight edge to (a)**, but only because
the check already exists; without it (b) would win here.

**Blast radius.** (a) permits a program to delete directories without asking.
(b) permits none. On the face of it (b) is safer — but the directories in
question are created by the same program in the same run, and the alternative
to deleting them is accumulating them. **Even.**

**Does it survive the reductio?** This is where they separate. (b) does not
answer it at all: it says nothing about the security-Finding case, because it
only removes one clause from §5.1. (a) answers it only if the carve-out is
*also* narrowed to what its own rationale supports. The rationale in
FR-CON-002 is: *"a node that repairs what it reports has no independent record
of the defect."* That supports a rule about **the record**, not about the
repair. **(a), with the narrowing, is the only one that answers it.**

**Gameability.** The reviewer's objection to the current text was that it
discriminates by *which file the observation was recorded in* — route the
observation through a non-Finding channel and remediation becomes maintenance.
(b) inherits that defect untouched. (a) removes it, because it discriminates
by effect rather than by paperwork. **Decisive for (a).**

**Cost of being wrong.** If (a) is too permissive, the failure is a supervisor
that cleans up too eagerly and destroys evidence of its own crash. That is a
real cost and it is bounded by FR-CON-007: whatever `reconcile()` removes is
not evidence, because evidence is committed and reproducible and `runs/` is
neither. If (b) is too strict, the failure is a rule everyone routes around,
which is #53's failure mode and the more expensive one. **Edge to (a).**

---

## 4. Decision

**(a), with the carve-out narrowed to what its rationale supports.**

Concretely, FR-CON-002 for this repository:

1. **Runtime state is exempt.** Recon may create, mutate and delete the
   sandbox's own bookkeeping — `runs/`, `slots/`, claim files, worktrees under
   `operator/.runs/` — without an owner decision, at any time, including in
   response to its own observation that they are stale. This is bookkeeping,
   not healing.
2. **Repository content is not.** A change to committed files goes through the
   protected PR path, as everything does.

   The safety argument runs in **one direction only**: the exempt set contains
   nothing committed. It is *not* "everything uncommitted" — the operator's
   own notes, drafts and scratch files are uncommitted and are not Recon's to
   delete. The exempt set is exactly the enumeration in point 1 and grows only
   by amending it.

   An earlier draft of this ADR wrote "the exempt set is precisely the set
   that is not committed", inside the operative grant, pointing outward. A
   reviewer caught it: that is the phrase-that-can-grow failure, written into
   the document claiming to avoid it, and it would have been the first
   citation in any future dispute.
3. **A Finding about Recon may be fixed, and the operator may open that PR.**
   What is forbidden is altering, suppressing, or retracting the *record* —
   the Finding, its evidence, its lifecycle state. Fixing the defect it
   describes is permitted and must be, because the alternative is a repository
   that cannot repair its own security bugs. The independent-record concern is
   satisfied by the record surviving, not by the defect surviving.

   **The actor is named on purpose.** FR-CON-002 bars Recon from opening
   *remediation* pull requests, and a reviewer asked who opens this one. If
   the answer were "the owner", (a) would smuggle back option (b)'s
   per-event owner cost at exactly the seam (b) was rejected for. So: the
   operator opens it, through the protected PR path, like any other change to
   committed content. The remediation clause is unchanged for **observed**
   repositories, which is what it was written about; for this repository the
   protected path is the control, and it is the same control that governs
   every other commit here. A self-fix PR must cite the Finding it answers.

   The Finding's lifecycle state is **not** the operator's to advance as part
   of that fix. Fixing and declaring-fixed are separate acts, and only the
   first is permitted here.
4. **Killing a process is not covered by any of this.** #134 remains
   OWNER-ONLY / STOP. `reconcile()` reports strays and stops; it does not
   reap. The exemption is for directories, and the distinction is not
   cosmetic — a directory belongs to Recon, a process may belong to anyone.

### What this does not decide

- Whether the reaper of #134 should exist. Untouched.
- Anything about observed repositories. FR-CON-002's first clause is unchanged
  and absolute.
- Whether "runtime state" should be enumerated as a path list in code rather
  than described here. It should, eventually; today `layer-boundary.bats`
  bounds it from the other side, which is weaker and is stated as such.

### The residual honest gaps — plural, and the second one was found by review

**1. Retirement as obsolete.** A determined operator can fix the defect and
then argue the Finding no longer describes anything, retiring it. Nothing here
prevents that; what it does is make retiring the Finding the visible act
rather than an implied one.

**2. Baseline-amendment laundering.** A "fix" can amend the *standard* instead
of the mechanism — document that sandbox egress is sanctioned. The record is
never altered, suppressed or retracted, so §4.3 is satisfied to the letter,
but its referent is redefined and the Finding is then obsolete by a different
route: gap 1 changes the world and keeps the standard, this keeps the world
and changes the standard. It attacks the rationale directly, because the
record is independent while the benchmark is not.

It is unforbiddable in the sense that matters — no ADR should bind the owner's
power to amend a standard — but it is not unsplittable, and that is where the
control went.

**`check_finding_retirement` refuses a change that both retires a Finding and
moves the standard it was measured against.** Either alone passes; together
they are the laundering move. Splitting them costs two pull requests and buys
the thing the single diff was designed to avoid: after the split, the
retirement PR stands on its own and says, on its own, that a Finding is being
retired because a standard moved — which is a claim someone can refuse.

*"Should the standard change?"* and *"is this still a defect?"* are different
questions, and a reviewer asked both at once tends to answer neither.

What that check does **not** do, and the ADR is not going to pretend otherwise:
land the standard change on Monday and the retirement on Tuesday and it says
nothing. A rule that made the sequence impossible would also forbid
legitimately retiring a Finding after a legitimate standard change, and that
must remain possible.

What the split does buy is precise, and an earlier draft of this paragraph
claimed more than it: **two independent reviews instead of one**, because each
pull request passes the consultation gate on its own. It does **not** buy any
guarantee that the pair is evaluated as a pair. Tuesday's diff contains a bare
state flip; the causal claim — *this is obsolete because the standard moved* —
lives in Monday's, and nothing mechanically links them. A reviewer put that
exactly, and it is the residual to fix next: requiring a retirement to cite the
amendment that made it obsolete, and checking the citation resolves. Filed, not
built.

The amendment log still counts the standard change, which is the weaker half
and was the only half this section had when it was written.

An earlier draft of this section was titled "the residual honest gap",
singular. A document whose whole authority is candor about its own ceiling
does not get to undercount its ceilings.
