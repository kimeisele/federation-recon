# Amendment log

Append-only. One line per adopted change to `CLAUDE.md`,
`docs/founding-package-v0.2.md`, or an accepted ADR.

Its purpose is to make constitutional drift **countable**. Each amendment is
reviewed in isolation; the trajectory is not. A sequence of individually
reasonable amendments, each approved, is the ordinary way a constitution ends up
far from what was adopted — and nothing else in this repository holds the
baseline.

Adoption baseline: see `docs/founding-decision-record.md`.

| # | Date | PR | Change | Consultation |
|---|---|---|---|---|
| 1 | 2026-07-25 | **#53** | Delegated judgment section; ENVELOPE risk tier; consultation machinery — **NOT VALIDLY ADOPTED**, see below | [governance/consultations/53.md](../governance/consultations/53.md) |
| 2 | 2026-07-30 | **#107** | `docs/execution-core-adr.md` accepted — Recon gains an execution layer over its own working tree. **Recorded 2026-08-01, two days late**, see below | [107-sol.md](../governance/consultations/107-sol.md), [107-kimi-architecture.md](../governance/consultations/107-kimi-architecture.md), [107-kimi-adoption.md](../governance/consultations/107-kimi-adoption.md) |
| 3 | 2026-08-01 | *this PR* | §5 and FR-CON-002 made decidable for the execution layer and for self-observation | pending — see PR |

> **Amendment 2 was accepted on 2026-07-30 and entered here on 2026-08-01.**
>
> This log declares accepted ADRs to be its own subject matter, in its second
> sentence. `docs/execution-core-adr.md` has read **Status: Accepted** since
> 2026-07-30 and appeared nowhere in this table until an external reviewer
> asked which invariant permits process supervision (#148) and the honest
> answer required looking.
>
> Nothing was concealed and nothing was disputed: the ADR is in the tree, it
> carries four review rounds from a second provider and two opinions from a
> third, and PR #107 is public. What failed is narrower and worse. **The one
> mechanism this repository has for making constitutional drift countable was
> not operated during the largest change of direction since founding** — not
> bypassed, not overruled, simply not thought of, because an ADR feels like a
> design document and the log is filed under governance.
>
> That is the same defect as amendment 1 one level up. #53 walked a
> constitutional change through a door nobody was watching; this walked one
> through a door nobody had counted as a door. A log that depends on someone
> remembering to write in it records exactly the changes made by people who
> remember.
>
> `check_amendment_log` now fails CI when a file under `docs/` reaches
> `Status: Accepted` without a table row here. **That is not "the gap is
> closed", which is what this note said first.** An independent reviewer found
> three ways through the first version — a filename outside `*adr*.md`, an
> unbolded `Status:` label that was skipped in silence, and a prose mention
> that satisfied a `grep` with no row, no date and no PR. All three are fixed
> and each is a regression test.
>
> What remains open by design: **edits to `CLAUDE.md` and to the founding
> package are still logged from memory.** That is the larger category, and it
> includes amendment 3 in the row above. Extending the check there means
> deciding which edits are constitutional, and that judgment does not belong
> in a grep. Stated here rather than left for the next reviewer to find.

> **Amendment 1 is on `main` but was never validly adopted.** This log previously
> recorded it as arriving through PR #42. It did not. #42 correctly held it back
> for the conditions its own ENVELOPE tier requires and never merged; the text
> reached `main` inside PR #53, a pull request whose stated subject was a CI gate.
>
> It satisfied none of its tier: one cross-provider approval instead of two, no
> 72-hour open period, no owner acknowledgment. The first reviewer's committed
> artifact carried a numbered finding stating that merging on green CI alone would
> violate the tier the diff creates; the operator read the verdict line and merged.
>
> A second independent reviewer, from a third provider, was asked retroactively
> whether to ratify or revert, and ruled **revert**
> ([governance/consultations/55-sol-ratification.md](../governance/consultations/55-sol-ratification.md)):
> *"A constitution whose first ENVELOPE amendment is accepted despite violating
> ENVELOPE has announced that ENVELOPE is optional whenever compliance is
> inconvenient."*
>
> Pending remediation, the CI gate introduced alongside this text continues to
> operate fail-closed — a stricter machine control may keep blocking during
> regularisation. It confers no merge, governance, or constitutional authority,
> and the amendment is not valid retroactively. See #55.
