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
| **Status** | `enforced` · `unenforced` · `contradicted` · `unread` |

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
| "v1 does not merge" (Phase 4 reserved) | `CLAUDE.md:42,56` | Nothing prevents a merge. The operator merged five pull requests on 2026-08-10 under an explicit owner instruction. The rule and the practice disagree and the text has not been changed to match. |
| Risk class HIGH requires a different-provider red-team before integration | `CLAUDE.md:106`, `AGENTS.md` | No check reads the diff size or blocks integration on a missing cross-provider artifact. `governance/reviewers.md:24` says the pipeline replaces cross-provider review "for routine work" without defining routine. |
| "Keine `allow`-Zeile ohne gepaarten Negativtest" | `docs/execution-core-adr.md:283` | Nothing checks it. The seatbelt profile added in #232 has read allows on `/usr`, `/bin`, `/etc`, `/private/var/select` with no paired negative test. Named as debt in #233. |
| Expert-call budget is consumed by review | `CLAUDE.md:54` | `scripts/review.sh` contains no reference to `expert_calls_this_cycle`. Only `heartbeat.sh` counts, and only on BUILD dispatch. Issue #219. |
| A backend may only claim capabilities its canaries prove | `docs/execution-core-adr.md:206` | `core/launcher.py` imports `backends.macos_seatbelt` by name at two sites; `scripts/review.sh` builds its own profile at a third. No capability negotiation exists. Issue #233. |

A first draft of this table listed the paid-consultation guard as
enforced-but-unproven, on the strength of not having looked. Two tests assert
the refusal, one of them by name. The correction cost one `grep`; publishing
the claim would have cost the next reader their trust in the whole table.

### Contradicted

| Subject | One source says | The other says |
|---|---|---|
| Merge authority | `CLAUDE.md:42` — "reserved; v1 does not merge" | `CLAUDE.md:146` — "Opus = operator: spec, review, gate. Standing merge authority is not claimed here and must be reconciled with Phase 4". The file names its own contradiction and leaves it open. |
| When cross-provider review is required | `CLAUDE.md:106` — every risk-class HIGH change | `governance/reviewers.md:24` — the pipeline "replaces the cross-provider consultation process for routine work", with no definition of routine |
| The adopted review channel | `governance/reviewers.md:60` — `opencode-go/qwen3.7-max` via `consult-opencode.sh` | Measured 2026-08-10: both bundled `opencode` binaries exit 137 on the operator host, so that channel does not execute there. Issue #220. |
| Sandbox technology | `docs/execution-core-adr.md:189` — the core knows no operating system, only capabilities | `scripts/review.sh` calls `/usr/bin/sandbox-exec` directly. Issue #233. |

---

## What this inventory already changes

Three of the four contradictions above were each discovered separately, at cost,
during a single session — by building and then finding out. Each was one file
read away.

The next pass should cover `docs/founding-package-v0.2.md`, because it is named
in `CLAUDE.md:168` as "constitution + invariants" and is the largest unread
normative document in the repository.
