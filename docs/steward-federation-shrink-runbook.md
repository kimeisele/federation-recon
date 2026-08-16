# steward-federation repo-shrink runbook (Phase 1 + Phase 2)

> **ℹ️ Status 2026-08-16: NO LONGER LOAD-BEARING — kept as a safety copy.**
> All consumers now pin `nadi-kit @ v0.1.2` in the live `steward-federation`
> repo (org-wide verified: 0 archive references). This repo is no longer a
> production dependency; it remains as the permanent, branch-protected
> archive of the pre-collapse history. Do not delete it (rollback path for
> any future Phase 1 execution), but nothing loads from it anymore.

**Status: Phase 1 CANCELLED, Phase 2 REJECTED (owner decision 2026-08-16).**
Phase 0 (shallow checkout) is executed and merged. Phase 1 was cancelled
because the benefit was gone (Phase 0 removed the pain) and the org scan
proved the consumer model wrong (14+ repos, not 4). Phase 2 was replaced by
a 1.5 GB size alert in the heartbeat. This runbook remains as the scripted,
verifiable, reversible procedure **if the alert ever fires** — see §11–§13
for the decision record.

Do not execute this from an interactive agent session. It is a force-push
against a live hub that ~96 GitHub Actions runs per day depend on, and it is
practically irreversible once runners have pulled the new head. It requires a
maintenance window, a **pre-verified mirror**, and a named owner who presses
the button (FR-CON-002: recon observes, the owner remediates).

**Owner decision needed before Phase 1 (the "release conditions" in §6):**
who is the owner for this action, whether any audit/attestation obligation
attaches to the history, and who besides the hub consumes the history.

---

## 1. Why

- Current `main` tree is ~4 MB (106 blobs); the repo is ~731 MB server-side
  (API size) because of **~109,625 commits** of full-file JSON mailbox
  rewrites (~6.7 KB/commit ≈ 5–10 MB/day, growing; the repo crosses GitHub's
  "<1 GB ideally" guidance in ~1–4 months at current growth).
- Phase 0 (merged 2026-08-16, `fetch-depth: 1` in `hub-heartbeat.yml`)
  already removed the 96×/day full-history checkout cost. Phase 1 removes the
  stored history itself; Phase 2 keeps it from regrowing.

## 2. What survives a history collapse

Git objects are content-addressed. A fresh root commit carrying the exact
current `main` tree preserves:

- every **blob SHA** (e.g. `nadi_kit.py` = `47d8e3bbd9cb4256612df1e21ded38b3beb48aa3`),
- the **tree SHA** (`5dbec498e1d20e0b43bad7d0a13fa6f6e1bc90b9` at last snapshot).

Only **commit SHAs** change (109,625 → 1). The S1 blob pins set on
2026-08-16 across agent-city/agent-internet/agent-world fetch the blob by
content-addressed SHA, so they **survive** the collapse — verified by git's
object model and recorded pre/post values in §4.

## 3. Facts verified (2026-08-16, research brief + live API)

| Fact | Value |
|---|---|
| API size | 731,332 KB (~0.71–0.73 GB) |
| Commits on `main` | ~109,625 |
| Current tree | 4,062,801 bytes, 106 blobs; largest blob 156 KB |
| Consumers of `nadi_kit.py` | agent-city, agent-internet, agent-world — all fetch by `main` **branch name**, no commit-SHA pins; all relay via `git clone --depth=1` |
| SHA-pin consumers | none for commits; recon evidence pins (`pins/…`) self-heal on next census |
| Open issues in hub | 1,193 (real protocol backlog — preserved by in-place collapse) |
| Commit cadence | ~1 push/min (15-min heartbeats × multiple nodes) |

## 4. Pre/post SHA recipe (falsifiable)

Re-record these at execution time — the hub is pushed continuously, so the
snapshot must be taken and force-pushed in one short window.

```bash
# BEFORE (record current values):
HEAD_BEFORE=$(gh api repos/kimeisele/steward-federation/commits/main --jq .sha)
TREE_BEFORE=$(gh api repos/kimeisele/steward-federation/git/trees/main?recursive=1 \
  --jq '.tree[] | select(.path=="nadi_kit.py") | .sha' )  # nadi_kit.py blob SHA
# expected at last check: HEAD ~348dc6d8…, tree …/main = 5dbec498…, nadi_kit.py = 47d8e3bb…

# AFTER — the invariants that prove the collapse is safe:
#   git rev-parse main^{tree}      == TREE_BEFORE (tree SHA unchanged)
#   git rev-parse main:nadi_kit.py == 47d8e3bb…   (blob SHA unchanged)
#   git diff <old-main> <new-main>  is empty      (no content change)
```

## 5. Phase 1 — one-time in-place history collapse (owner-executed)

> **Gate before starting:** the mirror in step 2 must exist, be pushed, and be
> cross-checked (§6 release conditions) — *before* any force-push, not after.

```bash
set -euo pipefail
# 0. maintenance window; announce; confirm nobody is mid-push (hub pushes are
#    TTL'd ephemeral messages, buffer 144 — losing one relay is acceptable by
#    design; losing the window race is what we are minimizing).

# 1. Snapshot values (record §4 before-values)
# 2. Archive full history FIRST:
gh repo create kimeisele/steward-federation-history --public --description \
  "Archived full history of kimeisele/steward-federation (pre-collapse)"
git clone --mirror https://github.com/kimeisele/steward-federation.git /tmp/hub-mirror
git -C /tmp/hub-mirror remote add archive https://github.com/kimeisele/steward-federation-history.git
git -C /tmp/hub-mirror push --mirror archive
# VERIFY before proceeding:
test "$(git -C /tmp/hub-mirror rev-parse main)" = "$HEAD_BEFORE"   # archive head == hub head

# 3. In the mirror, collapse history to a fresh root with the same tree:
cd /tmp/hub-mirror
NEW_ROOT=$(git commit-tree "$(git rev-parse main^{tree})" -m "baseline: relay hub snapshot $(date -u +%F)")
# 4. Move main, drop other refs, force-push:
git branch -f main "$NEW_ROOT"
git push --force origin main
# (refs/pull/* push failures are expected and harmless)
# 5. Verify (§4 AFTER recipe):
test "$(git rev-parse main^{tree})" = "$TREE_BEFORE"
test "$(git rev-parse main:nadi_kit.py)" = "47d8e3bbd9cb4256612df1e21ded38b3beb48aa3"
git diff --quiet "$HEAD_BEFORE" main   # empty
# 6. GitHub-side GC: old objects may linger (refs/pull/* keep them reachable);
#    size drops gradually. Optional: Support ticket for a GC / PR-ref deref.
# 7. Announce: commit SHAs are now ephemeral; pin by file-path-on-main, never
#    by commit SHA (same rule as Phase 2).
```

Rollback (if something breaks after step 4): the full history survives in
`kimeisele/steward-federation-history`; restore = force-push its `main` back.
Re-running Phase 1 is idempotent (content-addressed).

## 6. Release conditions — must ALL hold before Phase 1

- [ ] **Named owner** for the action (FR-CON-002) — who presses the button.
- [ ] **Audit/attestation check**: no audit, compliance, or evidence
      obligation requires the *original* commit chain of the hub. If an
      obligation exists, the archive repo preserves the history, but confirm
      that preserving it in a *separate* repo satisfies the requirement.
- [ ] **Consumer check**: nobody besides the four known repos pulls the hub
      history (or has pinned hub commit SHAs in automation, docs, or issues).
      Grep hub issues/README/docs for `[0-9a-f]{40}` commit references first.
- [ ] **Mirror verified**: `steward-federation-history` exists, is public,
      holds the full mirror, and its head equals the hub head at snapshot time.
- [ ] **Maintenance window** announced; low-activity time; retry budget.
- [ ] Branch protection on the hub allows the force-push (toggle if needed,
      re-enable immediately after).
- [ ] Owner has read the risks in §8.

## 7. Phase 2 — periodic re-baseline (policy decision, NOT scheduled)

Phase 2 is **not a technical choice — it is a policy choice.** A weekly
squash job keeps the live repo at ~10–50 MB forever, but it **permanently
destroys reproducibility of the relay history on the live repo**. If any
audit or evidence obligation attaches to the federation records, the correct
answer is: keep the live repo small by the one-time Phase 1, leave the
full history in the archive repo, and do **not** run periodic squashes.

Decision required: **does anything need the relay history to be
reproducible over time?** If yes → Phase 1 once + archive; no Phase 2. If no →
Phase 2 as an optional bounded job, paired with the documented invariant:

> **No consumer may pin a steward-federation commit SHA.** Pins must be by
> file-path-on-main (blob SHAs are stable; commit SHAs are ephemeral).

If Phase 2 is approved, the minimal shape is a weekly `workflow_dispatch`
job in `hub-heartbeat.yml` (not a separate repo):

```yaml
  rebaseline:
    if: github.event_name == 'schedule' && <weekly-cron>
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 1 }
      - run: |
          NEW_ROOT=$(git commit-tree "$(git rev-parse main^{tree})" \
            -m "baseline: weekly squash $(date -u +%F)")
          git push --force-with-lease origin "$NEW_ROOT:main"
```

`--force-with-lease`, low-activity window, and the same §4 verify recipe each
cycle. `--force-with-lease` is mandatory (a plain `--force` could clobber a
concurrent relay push).

## 8. Risks

| Severity | Risk | Mitigation |
|---|---|---|
| HIGH | Live-writer race: ~1 push/min; fetch→push window can clobber a concurrent relay push | Snapshot immediately before force-push; `--force-with-lease`; low-activity window; messages are TTL'd (2 h) and buffer-capped (144) by design |
| HIGH | All 109,625 commit SHAs die; any unexamined automation breaks silently | §6 consumer check before; "no commit-SHA pins" rule after; grep hub issues/docs |
| MEDIUM | GitHub-side retention: old objects reachable via `refs/pull/*`; API size drops gradually, not instantly | Expect it; plan for it; optional Support GC |
| MEDIUM | Branch protection blocks the force-push | Toggle for the push only; re-enable immediately |
| LOW | Archive repo adds ~0.7 GB second repo to the mesh | Recon posture: observe only (FR-CON-002) — this is owner action |
| LOW | Not a secret purge: history rewrite does not remove secrets from the archive clone | Out of scope; noted for the owner |

## 9. Target sizes

- After Phase 1: `.git` ≈ 4–10 MB (API size drops as GitHub re-packs).
- After Phase 2 weekly squash (if approved): bounded ≈ 10–50 MB indefinitely.
- Without any phase: crosses ~1 GB in 1–4 months; hub CI full-checkout cost
  already removed by Phase 0.

## 10. Owner decision record

| Decision | State |
|---|---|---|
| Phase 0 (`fetch-depth: 1`) | **EXECUTED** 2026-08-16 (steward-federation#1201, merged) |
| Phase 1 (in-place collapse + archive) | **CANCELLED 2026-08-16** — benefit gone, not deferred. See §11. |
| Phase 2 (periodic squash) | **REJECTED 2026-08-16** — would permanently destroy reproducibility; replaced by the 1.5 GB size alert (steward-federation#1203). See §12. |

*Evidence: research brief (2026-08-16); Phase 0 merge; §4 pre/post SHA values.*

## 11. Why Phase 1 is cancelled, not deferred (2026-08-16)

Owner decision: the collapse is **cancelled**, and the reason is not caution —
it is that the benefit is gone.

- Phase 0 already eliminated the 0.5–0.7 GB checkout 96×/day — that *was*
  the pain. What Phase 1 would still buy is only a smaller number on the
  repo-size page.
- Against that stands a force-push on a live hub with **8 active commit-SHA
  pins** (now repointed to the archive, §13) and — the decisive finding —
  proof that the consumer model was wrong: the org scan found **14+ consumer
  repos**, not the 4 assumed. If the scan found that, the question is what it
  did *not* find.
- No cosmetic gain is worth an irreversible intervention into a system that
  is demonstrably not fully known.

Status: the hub stays as-is (731 MB, growing ~5–10 MB/day). The 1.5 GB alert
(§12) is the tripwire; if it ever fires, this runbook and the now-routine
consumer scan are the response.

## 12. Phase-2 replacement: size alert (2026-08-16)

Owner decision: **no** to the weekly squash — automated, recurring history
destruction on a live hub is a permanently sharp knife for a problem that
occurs once a year. Instead:

- `hub-heartbeat.yml` gained a repo-size guard (steward-federation#1203):
  `gh api …/size` > 1.5 GB → run fails with an alert referencing this runbook.
- If it fires: run the manual, owner-gated Phase 1 from §5 (the archive repo
  `steward-federation-history` already exists, is branch-protected, and holds
  the verified full mirror), then re-run the consumer scan from §6.

**Update (2026-08-16, later): failure-alarm before size-alarm.** The real
finding of this whole exercise was not repo size: the hub heartbeat had been
failing since 2026-08-13 (race bug) and **nobody noticed** — it was only
found because Phase 1 disabled and re-enabled the workflow. A failing run is
only visible if someone looks, and a *missing* run raises nothing at all.
Two alerting mechanisms now ship in the hub (steward-federation#1204):

- **Failure alert**: `hub-heartbeat.yml` gains an `if: failure()` step that
  opens or reuses a single alert issue.
- **Dead-man check** (the important one): `heartbeat-watchdog.yml` runs
  hourly, independent of the heartbeat, and alerts when no successful run
  exists in the last 2 h — a disabled workflow, dead schedule, or stuck
  runner all surface.

Both find alert issues by the dedicated `heartbeat-alert` label, never by
title search (the first live run proved title search collides with unrelated
issues; steward-federation#1205 fixed it and #1197 was reopened). Since
steward-federation#1207 the automation **never closes issues** — alerts are
opened/reused/commented only; closing is human-only.

## 13. Commit-SHA pins repointed to the archive (2026-08-16)

> **ℹ️ Status 2026-08-16: NO LONGER LOAD-BEARING — safety copy only.**
> All consumers were repointed to `nadi-kit @ v0.1.2` in the live repo
> (org-wide scan: 0 references to this archive remain in any consumer). It
> is no longer a production dependency. It stays as the permanent,
> branch-protected archive of the pre-collapse history — never delete it
> (rollback path), but it is not load-bearing anymore.

The org-wide consumer scan found commit-SHA pins that a collapse would have
broken: `nadi-kit @ git+…@<commit>` and one raw-URL pin. Because pip needs a
commit/tag/branch (a blob SHA does not work), the correct repoint target is
the **immutable archive** `kimeisele/steward-federation-history` (permanent,
read-only `main`, branch-protected) — strictly better than a pin on a mutable
live repo, independent of any collapse. All three pinned commits
(`c613577b…`, `1249eca2…`, `e1321e57…`) were verified present in the archive
before repointing. One PR per repo, all merged:

| Repo | PR |
|---|---|
| federation-hq | #64 |
| agent-template | #24 |
| agent-template-acceptance-node-02 | #1 |
| agent-template-acceptance-node-03 | #2 |
| agent-template-acceptance-node-04 | #2 |
| agent-template-acceptance-node-05 | #4 |
| agent-template-proof-node-01 | #342 |
| agent-red-team | #374 |
| agent-village | #405 |

Also fixed while the hub was under maintenance: the pre-existing heartbeat
race-recovery bug (`git pull --rebase` failed on unstaged changes since the
2026-08-13 hub rework; fixed with `--autostash`, steward-federation#1202).

## 14. Org-wide pin move to the v0.1.2 tag (2026-08-16, Block A)

After the archive repoints (§13), a versioned-tag migration replaced every
commit/blob/archive pin with the immutable annotated tag `v0.1.2` in the
live `steward-federation` repo (commit `03008a5a`, `nadi_kit.py` blob
`47d8e3bb…`). Content-identical — every prior pin already resolved to that
blob — so the change is a pin-notation move, not a version change.

**Result (org-wide scan, verified at remote heads):** 16 consumer repos,
0 unpinned `main` fetches, 0 archive references; all pip/git/raw pins point
to `@v0.1.2` or `/v0.1.2/`. `steward-federation` itself is the source (uses
its own checked-out `nadi_kit.py`). `agent-arena` is the exception: it
**vendors** `nadi_kit.py` 0.1.0 into the repo and is not on the tag
`[UNBEKANNT: pending decision]`. `mahaclaw`/`vibe-agency`/`steward-test` are
relay-only, no nadi_kit execution.

**RING0 note:** `steward-protocol` changes RING0 files directly on main with
a matching register re-bless (kernel_hashes.json); a PR touching a RING0
file is structurally rejected by the TOTAL LOCKDOWN check. Since 2026-08-16
a `.github/CODEOWNERS` names `federation-operator` for the register and RING0
surface, so a second identity must approve those paths.
