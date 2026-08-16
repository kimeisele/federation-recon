# steward-federation repo-shrink runbook (Phase 1 + Phase 2)

**Status: NOT EXECUTED — owner decision pending.** This is the runbook for a
one-time history collapse of `kimeisele/steward-federation` (Phase 1) and a
periodic re-baseline job (Phase 2). It is written in advance so the operation
is scripted, verifiable, and reversible — not improvised under pressure.

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
|---|---|
| Phase 0 (`fetch-depth: 1`) | **EXECUTED** 2026-08-16 (steward-federation#1201, merged) |
| Phase 1 (in-place collapse + archive) | **PENDING** — blocked on §6 release conditions |
| Phase 2 (periodic squash) | **PENDING** — blocked on the audit/reproducibility policy question |

*Evidence: research brief (2026-08-16); Phase 0 merge; §4 pre/post SHA values.*
