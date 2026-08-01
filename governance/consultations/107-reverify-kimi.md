<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body — no tool with silent failover in the path
log: not applicable
-->

# Re-review — S1 sandbox isolation backend (#107)

**The review whose independence can no longer be asserted.** `107-sol.md` was
committed on a day when the dispatch tool was silently serving requests from
the builder's own provider. No log exists for the previous day and no
per-artifact evidence was recorded, so it can be neither shown nor excluded
(#135). A first re-review attempt through OpenAI was refused by provider
content policy for asking to construct a bypass (#140).

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 5189, completion 12975 |
| Mode | **diff mode — the reviewer executed nothing**, and labelled it |

---

# Independent red-team review — S1 seatbelt backend (diff mode, nothing executed)

## 1. Cheapest escapes

**a. Egress-symlink exfiltration (cheapest, no network needed).** Worker runs `os.symlink("/Users/<owner>/.ssh/id_rsa", os.path.join(ws, "notes.txt"))` and exits. `_copy_egress` runs **as the owner** on the host. If it follows symlinks (`shutil.copy`, `copyfile` without `O_NOFOLLOW`), the host itself reads the secret into the job workspace. The sandbox needs no network — the host exfiltrates for it. `_copy_egress` is not in the diff. **NOT EXECUTED.** Refutation: canary that plants a symlink to a 0600 owner-only file; if its bytes appear in the copied-back workspace, the claim fails.

**b. Ingress-symlink variant.** Job submission contains a symlink; `_copy_ingress` as owner follows it; the secret lands in `inner_ws`, which is then `chmod 0777` and is `file-read*` in the profile. Worker copies it into `result.json`. **NOT EXECUTED** (helper not shown). Refutation: same test, ingress side.

**c. Fork-race against the kill protocol.** Two processes that respawn each other in a tight loop. `kill_slot` runs *as the slot uid* via a helper not shown; nothing anywhere shows the required SIGSTOP-all-then-SIGKILL sequence or atomic `kill(-1, ...)`. An enumeration-based kill races a respawner indefinitely (NPROC=64 caps population, not regeneration rate), the 10 s deadline expires, slot quarantines. Repeat 8×: deliberate total backend DoS. **NOT EXECUTED.** Refutation: adversarial respawner converges to stable-empty well within deadline.

**d. Disk-fill.** `while True: open(f"f{i}","wb").write(b"0"*10*2**20)` — FSIZE caps each file, nothing caps count. Host-wide DoS. Admitted as unclaimed, but no compensating control exists.

**e. Metadata recon, no exploit needed.** `(allow file-read-metadata)` is **unconditional** — `os.stat`/`os.listdir` the entire filesystem, write the map to `result.json`. This one is established by the profile text alone.

**Weakest claimed capability: `fs_confinement`** — provably not confined (metadata oracle) while the canary (read → EPERM) passes. Runner-up: `kill_persistent` (c).

## 2. Claimed but not established

**`symlink_egress` and `ingress_symlink` are architecturally unprovable by an in-sandbox canary.** The canary exits *before* egress copying happens; it cannot observe the property it claims to prove. Both claims rest entirely on host-side helpers absent from this diff. This is the worst case named in the brief: policy asserts, canary "passes," mechanism unknown. Additionally `fs_confinement` (above). `pid_limit` depends on Darwin enforcing RLIMIT_NPROC per-uid — plausible but **NOT EXECUTED**; refuted by a fork-bomb canary observing >64 live processes.

## 3. Outside the uid cleanup scope

- **Run-dir content after death.** `inner_ws` is 0777: *any local user* can plant/replace files between worker death and egress copy. Cleanup scoped to `pgrep -u` never inspects content.
- **POSIX named semaphores / shm (`sem_open`, `shm_open`)** survive process death, are invisible to `pgrep`, and nothing shown ever unlinks them.
- **`escapee.pid` as confused deputy.** Worker writes an arbitrary integer there. If any host-side harness code kills that pid as owner/root without verifying `uid == slot_uid`, the worker names pid 1 or the supervisor. Not shown — must be verified.
- **The root sudo parent and the supervisor itself.** `teardown=False` callers are "responsible" for cleanup; if the supervisor crashes after the 1 s sleep, a live adversary slot persists with no reaper shown (`reconcile()` only cleans claims).
- **Persistence via launchd** if `system.sb` grants the bootstrap mach lookup — **NOT EXECUTED**; refuted by attempting `bootstrap_check_in`/agent registration from inside.

## 4. Failure mode that looks like success

`_release_slot` **proceeds with polling even when `kill_slot` returned ok=False** (documented behavior). If the kill path is broken (sudoers drift, helper deleted) but the slot happened to drain naturally, release reports success: kill mechanism dead, everything green, nobody re-attests. Second: a payload writes `result.json` claiming success, then hangs; watchdog fires; the pre-written "success" artifact is copied back. Ordering of watchdog vs egress processing is not shown.

## 5. What nobody notices in a long session

- Run dirs are never deleted in anything shown — disk creeps (0777 dirs, 10 MiB × N files).
- POSIX shm/sem leak per run, reboot-only cleanup.
- Quarantine is monotonic: pool drains 8→0, reported only via `print(..., file=sys.stderr)` — invisible in a daemonized supervisor. Same "no log exists" failure that triggered this re-review, reproduced inside the component.
- `system.sb` is private API; a macOS update mid-uptime can change its grants, and canaries run only at setup — claims silently stale.
- Constants already drifting: wrapper `ulimit -f 10240` (512-byte blocks → 5 MiB) vs policy `rlimit_fsize_bytes: 10485760` (10 MiB). Two sources of truth, already disagreeing. **NOT EXECUTED**; refuted by writing past 5 MiB and observing SIGXFSZ timing.

## 6. Missing

- The host-side copy helpers **in the reviewed diff**, with lstat + `O_NOFOLLOW` + regular-file-only enforcement — two claims depend on them.
- SIGSTOP→SIGKILL (or `kill(-1)`) kill helper, shown and adversarially tested.
- ACLs (`chmod +a` per slot uid) instead of 0777.
- Total-volume quota via a `du` watchdog; run-dir deletion/chmod-back after egress.
- `-n` on the run-path sudo (absent; hangs on a password prompt with inherited stdin otherwise).
- Root-owned append-only audit log: run_id, slot, profile/wrapper/canary hashes, kill results; plus periodic canary re-attestation and an un-quarantine path.
- Single source for limits (policy.json → wrapper), and collection of seatbelt denial logs.

## 7. Trust boundary placement

Location is defensible (sudo + seatbelt + per-run uids). Material is not: the profile's "deny default" claim is false in effect — the real policy is `system.sb ∪ local allows`, and `system.sb`'s mach/sysctl grants are unaudited here; `sandbox-exec` is deprecated and unpinned; 0777 ignores every other local user; and two of eight claims live in code outside the drawn boundary. A boundary on undocumented API, attested once at setup, is a boundary on sand.

verdict: REJECT
