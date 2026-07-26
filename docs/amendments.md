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
