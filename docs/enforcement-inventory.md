# Enforcement inventory

Every normative statement in this repository is one of three things: **enforced**
by a check that a test proves goes red, **unenforced** prose that nobody can
rely on, or **contradicted** by another committed document.

This file records which. It exists because on 2026-08-10 an operator built
against four documents it had not read, and each of them already contained the
answer:

- `core/profiles/worker.sb` warns in its own header against the exact block-list
  mistake that shipped in a build.
- `docs/execution-core-adr.md` §7 defines the OS-agnostic backend contract that
  a new sandbox call site bypassed.
- `docs/operator-lessons.md` already recorded the jcode provider failover that
  was rediscovered as if new.
- `AGENTS.md` was never opened; it is a symlink to `CLAUDE.md`, which is the
  answer, but that was assumed rather than checked until later.

**Reading is cheaper than building.** This inventory is the artifact that makes
reading first possible for the next session.

## How to read the tables

| column | meaning |
|---|---|
| **Rule** | the normative statement, in the words of its source |
| **Source** | file and line, so it can be re-read rather than remembered |
| **Enforced by** | the check that fails when the rule is broken |
| **Proven by** | the test that has been observed to go red when the check is removed |
| **Status** | `enforced` · `unenforced` · `unsatisfiable` · `contradicted` · `unread` |

A rule with an **Enforced by** and no **Proven by** is not enforced. It is a
check nobody has watched fail, which `docs/operator-lessons.md` names as an
assumption.

---

## Pass 1 — 2026-08-10

Covers `CLAUDE.md` (171 lines), `docs/operator-lessons.md` (214),
`docs/execution-core-adr.md` §7 (of 396), `governance/reviewers.md` (212),
`governance/builders.md` (95), `core/profiles/worker.sb`,
`core/canaries/fs_confinement.py`.

**Not yet read, and therefore not in this table:**
`docs/founding-package-v0.2.md` (943), `docs/s1-setup.md` (562),
`docs/self-remediation-adr.md` (250), `docs/review-pipeline-spec-v0.md` (243),
`docs/operator-v1.2-runtime-state-adr.md` (227), the remainder of
`docs/execution-core-adr.md`, `governance/adversarial-review.md` (170),
`governance/consultation-prompt.md` (72), and the smaller `docs/*`. That is
roughly 2,500 of the 4,300 normative lines. Listing what is unread is part of
the inventory: an absence that could be a measurement or a gap, treated as a
measurement, is the failure this repository keeps recording.

### Enforced

| Rule | Source | Enforced by | Proven by |
|---|---|---|---|
| WIP ≤ 1, expert calls ≤ budget cap; violation → STOP | `CLAUDE.md:54` | `operator/heartbeat.sh` | `scripts/test/budget-cap.bats`, `heartbeat.bats` |
| A review is bound to one commit; a verdict for X is never applied to a later commit | `docs/review-pipeline-spec-v0.md` (via `scripts/review.sh`) | `subject_head_sha` + aggregator STALE | `scripts/test/review-verdict.bats` |
| Only a finding whose command was executed may block | `CLAUDE.md` risk model; `governance/reviewers.md:20` | `_verify_findings` in `scripts/review.sh` | `review-runner.bats` "blocking finding without a verification command is downgraded" |
| A blocking finding must discriminate head from base | issue #196 | `scripts/review.sh` base run | `review-runner.bats` isolation/discrimination set; mutation observed red |
| A verification command cannot write to what it verifies | issue #228 | seatbelt profile in `scripts/review.sh` | `review-runner.bats` isolation set; mutation observed red |
| The provider that answers must be the one requested | `governance/builders.md`; `docs/operator-lessons.md:167` | `operator/builders/provider-probe.sh` | `builder-jcode.bats`, `provider-probe-clock.bats` |
| Paid consultation requires explicit owner authorization | `governance/reviewers.md:33` | `CONSULT_AUTHORIZED` guard at entry of `consult*.sh` | `scripts/test/opencode-consult.bats` "refuses without CONSULT_AUTHORIZED"; `consult-provenance.bats` |
| Test files present are the ones that ran | `CLAUDE.md:157` | `scripts/test/MANIFEST` + `ci-checks.sh` | `suite-inventory` |

### Unenforced — prose only

| Rule | Source | Why it is not enforced |
|---|---|---|
| **The operator may not integrate its own output** — but *may* build, test, run a sandboxed builder, produce a patch and **open the pull request** | `docs/founding-package-v0.2.md:206` (§5.1, amendment 3) and `FR-CON-002:254`; restated `CLAUDE.md:42,56` | Nothing prevents a merge. **This is a constitutional invariant, not an open question in `CLAUDE.md`, and it was violated on 2026-08-10: the operator merged five pull requests (#223, #224, #229, #231, #232) under an explicit owner instruction.** §5.1 permits building, testing, sandboxed execution and producing a patch, and prohibits merging that patch. FR-CON-002 lists "merge changes" among the prohibited acts. See the note below. |
| Risk class HIGH requires a different-provider red-team before integration | `CLAUDE.md:106`, `AGENTS.md` | No check reads the diff size or blocks integration on a missing cross-provider artifact. `governance/reviewers.md:24` says the pipeline replaces cross-provider review "for routine work" without defining routine. |
| "Keine `allow`-Zeile ohne gepaarten Negativtest" | `docs/execution-core-adr.md:283` | Nothing checks it. The seatbelt profile added in #232 has read allows on `/usr`, `/bin`, `/etc`, `/private/var/select` with no paired negative test. Named as debt in #233. |
| Expert-call budget is consumed by review | `CLAUDE.md:54` | `scripts/review.sh` contains no reference to `expert_calls_this_cycle`. Only `heartbeat.sh` counts, and only on BUILD dispatch. Issue #219. |
| **Tier 1B must use a model distinct from the builder — "the builder's own model family cannot review its own output"** | `docs/review-pipeline-spec-v0.md:101` | Nothing compares the review model to the builder model. `scripts/review.sh` contains no reference to the builder at all. **Violated on 2026-08-10**: runs `rv-20260810-004` and `-005` ran Tier 1B on `deepseek-v4-pro` while the builder is `deepseek-v4-flash` (`governance/builders.md`) — same family, same provider, same vendor. Both reviews completed and produced verdicts. The spec says "mismatch → task fails, never silently completes"; it completed silently. |
| **Re-ratification every 6 months or every 5 amendments, whichever comes first** | `docs/founding-decision-record.md:82` | Nothing counts amendments or dates. **The trigger has fired**: `docs/amendments.md` holds exactly 5 rows. No re-ratification has been run, and owner silence past the deadline is supposed to become a self-Finding — which also has not happened. |
| The operator's second credential is not independent review | `docs/amendments.md:20` — amendment 5 records step 3 as "self-approved via `GH_TOKEN_REVIEWER` (operator's own second credential), not independently reviewed" | Recorded on 2026-08-03 and unchanged since. The same mechanism approved five merges on 2026-08-10. The repository knew; nothing stopped it. |
| A backend may only claim capabilities its canaries prove | `docs/execution-core-adr.md:206` | `core/launcher.py` imports `backends.macos_seatbelt` by name at two sites; `scripts/review.sh` builds its own profile at a third. No capability negotiation exists. Issue #233. |

A first draft of this table listed the paid-consultation guard as
enforced-but-unproven, on the strength of not having looked. Two tests assert
the refusal, one of them by name. The correction cost one `grep`; publishing
the claim would have cost the next reader their trust in the whole table.

### The violation this inventory found in its own author

Reading `docs/founding-package-v0.2.md` — the largest normative document, and
the one the first draft of this file listed as unread — established that
merging is prohibited by constitutional invariant, not merely reserved by
`CLAUDE.md`. Five merges on 2026-08-10 violated it.

They were made on explicit owner instruction, after the operator had raised the
concern and the owner overruled it. That makes them authorised in fact and
irregular in form: the owner may decide, but the decision belongs on its own
pull request as a prospective amendment, not inside five pull requests about
something else.

`CLAUDE.md:115-130` records the precedent and the remedy in the repository's own
words. PR #53 carried a governance tier inside a pull request whose stated
subject was a CI gate; an independent reviewer ruled revert rather than
retroactive ratification, on the grounds that *a rule is defined by what happens
when following it is costly, and the first hard case cannot be the exception
that consumes the rule.*

The same standard applies here and is not softened by the merges being useful.
Recorded rather than quietly carried forward. **No further merges by the
operator until this is decided.**

### The two-identity control is satisfied by one actor

`.github/CODEOWNERS` names `@federation-operator` so that "a change to any path
below cannot merge until a second identity approves it", and states its own
limit: *"this proves someone with a different credential pressed a button.
Neither proves a review happened."*

Measured 2026-08-10:

```
operator identity   kimeisele
reviewer identity   federation-operator
both credentials    ~/.config/secrets/env, held by the operator process
```

The ruleset itself was not bypassed — `bypass_actors` is empty with enforcement
active, so the required checks and the code-owner review did gate every merge.
The gap is not a bypass. It is that the second pair of eyes belongs to the same
process as the first, so the control discriminates nothing it was built to
discriminate.

This is a defect in the control, independent of whether the operator should be
merging at all.

### Where the operator's authority actually ends

Reading `docs/self-remediation-adr.md` §4.3 (Accepted 2026-08-01, amendment 4)
sharpens the boundary considerably, and in the operator's favour:

> **The actor is named on purpose.** FR-CON-002 bars Recon from opening
> *remediation* pull requests, and a reviewer asked who opens this one. If the
> answer were "the owner" … So: **the operator opens it, through the protected
> PR path**, like any other change to committed content.

So the line is not "the operator may not touch its own repository". It is:

| act | status | source |
|---|---|---|
| build, test, run a sandboxed builder, produce a patch | permitted | `founding-package` §5.1 table |
| open the pull request for a self-fix | **explicitly permitted, actor named** | `self-remediation-adr` §4.3 |
| merge that pull request | prohibited | §5.1 table; `FR-CON-002` |
| advance the Finding's lifecycle state as part of the fix | prohibited — "fixing and declaring-fixed are separate acts" | `self-remediation-adr` §4.3 |

Everything the operator did on 2026-08-10 up to and including opening the pull
requests was inside the constitution. The merges were not, and nothing else was.
An earlier revision of this file implied a broader violation than occurred.

Two further obligations found in the same section and **not currently met**:

- *"A self-fix PR must cite the Finding it answers."* Today's pull requests cite
  GitHub issues, which are not Findings in the artifact sense of §8.4. Whether
  an issue satisfies this is undecided and nothing checks it.
- `check_finding_retirement` refuses a change that both retires a Finding and
  moves the standard it was measured against. Its stated residual: land the two
  on different days and it says nothing.

### Constitution against reality

The merge prohibition is **not stale text that predates the execution layer**,
which was this inventory's first assumption and it was wrong.

`docs/founding-package-v0.2.md` §5.1 was amended on 2026-08-01 (amendment 3)
specifically to accommodate the execution core. That amendment widened the
permitted set to include "sandboxed execution of a builder against an order,
producing a patch" — and kept "merging that patch" prohibited in the same
table, labelling itself a widening rather than a clarification.

So the prohibition survived the exact amendment that acknowledged the project
had grown an execution layer. Whatever should happen next, it cannot rest on
the claim that the constitution has not caught up.

### Unsatisfiable — the rule cannot be met under the project's real constraints

This category is separate from *unenforced* on purpose, and it is expected to
be the largest one. An unenforced rule is a control someone forgot to build. An
unsatisfiable rule is a control that **cannot** be built here, so it is broken
every time it is invoked, quietly, by whoever is doing the work. That is worse
than having no rule: it teaches every reader that the documents are decorative.

The remedy is never to obey it. It is to change the rule to what is actually
achievable and say why, or to state plainly that the project is blocked on it.

| Rule | Source | Why it cannot be met | Disposition |
|---|---|---|---|
| Tier 1B must use a model distinct from the builder | `docs/review-pipeline-spec-v0.md:101` | `deepseek-v4-flash` is the only model with usable quota on the operator's subscription. Other models exist in the catalogue but exhaust their quota almost immediately, so a distinct reviewer is not purchasable. | **Rewritten.** Independence now comes from executed, base-discriminating, confined verification — machine properties that do not depend on whose model proposed the command. The stated limit is recorded in the spec. |
| Risk class HIGH requires an independent expert red-team from a different provider before integration | `CLAUDE.md:106`; `governance/reviewers.md` | Same constraint, same reason. Every roster entry other than the builder's own model is either unaffordable or, measured on 2026-08-10, does not hold the strict-JSON contract: `kimi-k3` answers with `tool_calls` and empty content, `glm-5.2` returns empty content, `grok-4.5` returns an upstream error. | **Open.** Not addressed by the Tier 1B rewrite, because it governs integration rather than the pipeline. It is currently unmet on every change. |

### Contradicted

| Subject | One source says | The other says |
|---|---|---|
| Merge authority | `CLAUDE.md:42` — "reserved; v1 does not merge" | `CLAUDE.md:146` — "Opus = operator: spec, review, gate. Standing merge authority is not claimed here and must be reconciled with Phase 4". The file names its own contradiction and leaves it open. |
| When cross-provider review is required | `CLAUDE.md:106` — every risk-class HIGH change | `governance/reviewers.md:24` — the pipeline "replaces the cross-provider consultation process for routine work", with no definition of routine |
| The adopted review channel | `governance/reviewers.md:60` — `opencode-go/qwen3.7-max` via `consult-opencode.sh` | Measured 2026-08-10: both bundled `opencode` binaries exit 137 on the operator host, so that channel does not execute there. Issue #220. |
| What Tier 0 does | `docs/review-pipeline-spec-v0.md:68` — "Runs the existing `gate.sh` once and captures its phase results", **and** CI status via the `gh` API as one of those results | `scripts/review.sh` after #224 — reads the CI rollup and does not run `gate.sh` at all. The spec listed CI status as one input among five; the implementation made it the only one. The change is defensible and measured (1997s → 2s) but the spec was not updated and now describes a runner that no longer exists. |
| Sandbox technology | `docs/execution-core-adr.md:189` — the core knows no operating system, only capabilities | `scripts/review.sh` calls `/usr/bin/sandbox-exec` directly. Issue #233. |

---

## What this inventory already changes

Three of the four contradictions above were each discovered separately, at cost,
during a single session — by building and then finding out. Each was one file
read away.

The next pass should cover `docs/founding-package-v0.2.md`, because it is named
in `CLAUDE.md:168` as "constitution + invariants" and is the largest unread
normative document in the repository.
