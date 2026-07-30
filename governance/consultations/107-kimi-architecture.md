# Consultation — S1 execution core, architecture judgment

- **Reviewer:** Kimi K3
- **Provider:** Moonshot — different provider from the operator (Anthropic) and from the reviewer of #107 (OpenAI)
- **Date:** 2026-07-30
- **Mode:** judgment only. No code, no diff, no repository access — deliberately, because Kimi is billed per token and this was a design question, not a review.
- **Invocation:** direct HTTPS to `api.moonshot.ai/v1/chat/completions`, `model: kimi-k3`. See the provenance note below; the invocation recorded in `governance/reviewers.md` did not work and failed over silently.

Sought because seven build rounds produced the same class of defect in new
disguises, and the operator could not judge from inside whether the approach was
sound or whether scaffolding was being stacked on scaffolding.

verdict: viable — but abandon an implementation family, not a capability

## What the operator takes as binding

**The rule, which names the defect class of the entire S1 effort:**

> No code path anywhere in the system may convert "I don't know" into "all clear."

Every recurring finding was one instance: `pkill` success ≠ dead tree; `pgrep`
error ≠ zero survivors; dead lock-holder PID ≠ no workers; stale lock deleted ≠
safe to start; "check not performed" ≠ blocked; and a canary that cannot
distinguish "killed by us" from "died on its own".

**Capabilities are transactions with two poles, not denial properties.** A hole
passes every preservation test; a corpse passes every denial test. The operator
had proposed one liveness canary; Kimi rejects that as relocating the blind spot
rather than removing it, and requires each claim to pair a denial with a
preservation probe:

| claim | denial | preservation |
|---|---|---|
| filesystem | write outside denied, and denied with `EPERM`/`EACCES` from Seatbelt — not `ENOENT` from a missing path | write inside succeeds, bytes read back and compared |
| network | egress denied | a network-free compute job completes with the correct result |
| fork containment | bomb capped | a job forking within budget succeeds |
| kill | escapee on slot A dies | **decoy on slot B survives and returns its correct result** |

The kill pair is the keystone: it tests the property the whole design exists to
provide, and it requires ≥2 free slots.

**Denial by the wrong mechanism is the same disease in denial form.** This had
already bitten twice independently — `write_outside` blocked by Unix permissions
rather than Seatbelt, and `FileNotFoundError` counted as confinement.

## Question 1 — per-run uid pool: yes, and it is the only sound primitive here

Not a workaround. Kimi enumerates the alternatives and each fails a hard
requirement: PIDs are recyclable (the seven rounds); process groups and sessions
are escapable in one `setsid()` call and Seatbelt cannot filter it; `kqueue`
`EVFILT_PROC` is userspace reconstruction with a fork-to-attach lag; launchd
per-job needs a user session or root daemon domain; Endpoint Security needs an
Apple-granted entitlement and a system extension, out of reach for one person.

uid is the only handle that is kernel-maintained, complete, and **inescapable by
the payload** — an unprivileged process cannot change its uid.

The operator's three objections, answered:

- *More accounts is more attack surface.* Surface is reachable behaviour, not
  account count. Locked accounts add nothing reachable; the payload already runs
  as a worker uid. The real delta is sudoers, kept near zero by one rule:
  **sudoers flows owner → (run as slot uid), never slot uid → anything.** The
  kill wrapper stays argument-less and is run *as the slot uid*, deriving its
  target from `id -u`, so no uid string crosses the sudo boundary and there is
  nothing to inject.
- *Setup can drift.* Canary the pool like everything else — slot exists, uid in
  range, shell `/usr/bin/false`, password locked, no unexpected groups,
  `visudo -c` clean, per-slot runas entry present. Drift becomes a loud
  precondition failure.
- *Exhaustion moves the failure.* That is the point. Today failures live on the
  **kill path**, where failure means survivors of untrusted code. Pool exhaustion
  lives on the **admission path**, where failure means no run starts and the
  caller sees a clean refusal. Move every failure you can to admission. Size to
  measured need — 8, not 16.

### Implementation, non-negotiable

1. **Slot claim by exclusive `mkdir`** under a slots directory — the primitive
   already trusted for ingress. At claim, assert `pgrep -u <slot>` is empty,
   which closes slot-reuse ABA.
2. **Kill protocol:** loop `pkill -STOP -u <self>` until a pass finds nothing
   new, then `pkill -9 -u <self>`. Not a heuristic: during STOP nothing dies, so
   the uid's population is monotonically non-decreasing and bounded by
   `RLIMIT_NPROC`; forks fail at the cap; the next full pass stops the world and
   stopped processes cannot fork. **The NPROC cap is what makes convergence
   bounded** — another reason per-run uids are load-bearing, since today the cap
   is shared and meaningless as isolation.
3. **Release protocol:** `pgrep -u <slot>` must report empty within a timeout.
   Exit 0 and 1 are the only non-fatal outcomes; any error means unknown, and
   unknown means **quarantine the slot, do not release it, log for the human**.
4. **Full rlimit bundle before `exec`** — rlimits survive `exec` and
   `sandbox-exec` does not reset them. And the honest gap: there is no cap on
   aggregate disk written. A dedicated APFS volume with a quota is the native
   answer; otherwise stop claiming disk containment.
5. **Replace finally-block cleanup with a reconciler.** "Finally blocks don't
   run; sweepers do." With a pool the legitimate state is enumerable — N slots ×
   current run — so a reconciler converges the filesystem against slot state and
   deletes everything else. The 60 stale directories were a structural error, not
   a bug.

### What gets deleted

The singleton lock, PID-liveness inference, sweep ordering, and exception-path
cleanup. Concurrency up to pool size becomes **permitted** — a capability
upgrade, not merely a fix.

## Provenance note — the recorded invocation was broken

`governance/reviewers.md` prescribed
`JCODE_PROVIDER=moonshotai JCODE_MODEL=kimi-k3 jcode run`, verbatim, with an
explicit warning never to reconstruct it. Measured on 2026-07-30:

- The environment variables are not read by `jcode run`; it takes `-p` / `-m`.
- The provider id is `moonshot-ai`, not `moonshotai`.
- `MOONSHOT_API_KEY` lives in `~/.config/secrets/env`, which jcode does not read.
- The invocation **failed over to Anthropic Fable 5** and only surfaced because
  that model demanded credits. With credits available it would have returned a
  plausible answer that would have been recorded as a Kimi judgment — the same
  provider as the operator, defeating the requirement entirely.
- `jcode run -p moonshot-ai` then hung: 17 minutes, 0.0% CPU, zero network
  connections, zero bytes out.
- The direct API call initially returned HTTP 400: `kimi-k3` accepts only
  `temperature: 1`.

The lesson is not the flags. **A tool with silent provider failover cannot be the
control that guarantees provider independence** — its success proves nothing
about who answered. A direct call to a named endpoint with that provider's key
does, and the response carries the model id.

## Raw answer

## Question 1: Yes — and it's not a trade, it's the only sound primitive on this platform

Your instinct is right, but frame it correctly: a per-run uid pool is not a workaround, it is *the* macOS primitive for kill-with-certainty. Enumerate the alternatives and each fails a hard requirement:

- **pid** — recyclable, unstable, exactly the failure you've had seven rounds of.
- **process group / session** — escapable in one syscall. Any payload can call `setsid()` and walk out of `kill(-pgid)`. Seatbelt cannot filter this. Dead on arrival against adversarial code.
- **kqueue `EVFILT_PROC` / `NOTE_FORK` tracking** — userspace reconstruction of membership with a lag between fork and attach. Better than `pgrep` polling, strictly worse than kernel-maintained membership.
- **launchd per-job** — jobs-as-another-uid require a user session or a root daemon domain. Wrong tool on a laptop.
- **Endpoint Security** — the "real" answer, but it requires an Apple-granted entitlement and a system extension. Not available to a one-person project.

uid is the only handle that is kernel-maintained, complete (the kernel always knows the full membership), and **inescapable by the payload** — an unprivileged process cannot change its uid to anything but itself. Adopt the pool.

Your three objections, answered:

**"More accounts is more attack surface."** Surface is *reachable behavior*, not account count. Sixteen locked accounts (shell `/usr/bin/false`, no password, no home that matters, no group memberships, zero sudoers entries granting *them* anything) add essentially nothing reachable — the payload already runs as a worker uid and can already do everything that uid can do. The real delta is the sudoers file. Keep it near zero with one rule: **sudoers flows owner→(run as slot uid), never slot uid→anything.** And preserve your best current property — the kill wrapper stays no-argument. Run it *as the slot uid* (`sudo -u _jcode_w07 kill-self`) and have it derive its target from `id -u`. No uid string ever crosses the sudo boundary; there is nothing to inject.

**"Setup can drift."** You already have the discipline for this: unproven capabilities cause refusal. The pool is setup *state*, so canary it like everything else — at startup, verify each slot account exists, uid in range, shell false, password locked, no unexpected groups, `visudo -c` clean, per-slot runas entries present. Drift becomes a loud precondition failure instead of silent degradation.

**"Exhaustion moves the failure."** Yes — and that is the entire point. Where a failure lives determines its cost. Today your failures live on the *kill path*, where failure means survivors of untrusted code running on your laptop. Pool exhaustion lives on the *admission path*, where failure means: no run starts, no state exists, the caller sees a clean refusal. You want every failure you can possibly move relocated to admission. Size the pool to measured need — 8, not 16, unless you have data — because smaller pool, less state, and exhaustion is safe anyway.

Non-negotiables for the implementation:

1. **Slot claim by exclusive `mkdir`** under a slots directory — the same primitive you already trust for ingress. At claim, assert `pgrep -u <slot>` is empty. This closes the slot-reuse ABA (slot released with undead processes, next run inherits them).
2. **Kill protocol, in the wrapper:** loop `pkill -STOP -u <self>` until a pass finds nothing new, then `pkill -9 -u <self>`. This is not a heuristic — during the STOP phase nothing dies, so the uid's population is monotonically non-decreasing and bounded by `RLIMIT_NPROC`; forks start failing at the cap; the next full pass stops the world, and stopped processes cannot fork. The NPROC cap is what makes convergence bounded, which is another reason per-run uids are load-bearing: today the cap is shared and meaningless as isolation.
3. **Release protocol:** after KILL, `pgrep -u <slot>` must report empty within a timeout (zombies reap fast under launchd). `pgrep` exit codes 0 and 1 are the only non-fatal outcomes. Any error means **unknown**, and unknown means *quarantine the slot, do not release it, log for the human*. Which brings me to the thing you should actually write on the wall:

**Every one of your five recurring findings is the same bug wearing different clothes: treating absence of evidence as evidence of absence.** `pkill` success ≠ dead tree. `pgrep` error ≠ zero survivors. Dead lock-holder PID ≠ no workers. Stale lock deleted ≠ safe to start. The pool fixes identity; it does not fix this epistemics. Adopt a global rule: no code path anywhere in the system may convert "I don't know" into "all clear." That rule, plus the pool, retires the category.

4. **Set the full rlimit bundle in the launcher** before `exec` (`NPROC` ~128/256, `AS`, `FSIZE`, `CPU`) — rlimits survive `exec` and `sandbox-exec` doesn't reset them. Note the honest gap: you currently have no cap on *aggregate* disk written during a run. If you claim disk containment, a small dedicated APFS volume with a quota is the native answer; otherwise stop claiming it.
5. **Replace finally-block cleanup with a reconciler.** Finally blocks don't run; sweepers do. With a pool, the universe of legitimate state is enumerable — 8 slots × current run — so a reconciler that runs at startup and after every run can converge the filesystem against slot state and delete everything else. Your 60 stale directories happened because cleanup was on a path exceptions bypass. That is a structural error, not a bug; fix the structure.

What gets **deleted**: the singleton lock (concurrency up to pool size is now *permitted* — this is a capability upgrade, not just a fix), PID-liveness inference, sweep ordering, and exception-path cleanup.

## Question 2: One liveness canary is a patch. The contract is what's wrong.

Your proposal fixes the vacuity at the suite level only. A single positive job proves the sandbox is *alive somewhere*; it does not prove each capability is alive *where that capability claims to operate*. Hardening can break writes to a workspace subdirectory while your one canary writes at the top level and stays green. You've just relocated the blind spot.

The deeper error: you've conceived capabilities as *denial properties of the sandbox*. A capability is not a property; it's a **transaction with two poles** — given this input, the system must refuse outcome X *and* still deliver outcome Y. Both failure modes satisfy one pole alone: a hole passes every preservation test, a corpse passes every denial test. You proved the second half yourself. So restate the contract as a set of pairs, and fail the suite unless both halves of every pair are proven:

- **Filesystem:** write outside workspace denied (assert `EPERM`/`EACCES` from Seatbelt, not `ENOENT` from a missing path — a denial produced by the wrong mechanism is the same vacuity disease in denial form) ∧ write inside workspace succeeds, bytes read back and compared.
- **Network:** egress denied ∧ a network-free compute job completes with the correct result.
- **Fork containment:** bomb capped ∧ a job that forks *within* budget succeeds — you deny bombs, not forking.
- **Kill (the keystone):** start a decoy long-running job on slot B; launch an escapee on slot A; kill A; assert A is dead *and B is still running and produces its correct result*. This single canary tests the property the entire pool exists to provide. The suite therefore requires ≥2 free slots. Fine.

And make your save systematic: it was an *evidence string* that caught the 0600 failure. So every canary — denial or preservation — emits an evidence object (expected vs. observed: errno, signal, output checksum), and the harness asserts on content, never on exit codes alone. Exit-code assertions in the harness are the same `pgrep`-error→success bug one layer up.

## Verdict on viability

The scaffolding can be made sound on macOS without narrowing the capability set you're actually claiming — network-denied, filesystem-confined, fork-capped, certainly-killable, concurrent — *provided* you accept two narrowings that aren't really losses: concurrency is bounded by the pool with loud refusal past it, and no capability enters the contract unless its denial can be paired with a preservation probe. What you must abandon is not a capability but an implementation family: PIDs as identity, lock files as mutual exclusion, shared-uid sweeps, and finally-block cleanup. The pool deletes the first three; the reconciler deletes the fourth; the "unknown ≠ clear" rule deletes the class they all came from.
