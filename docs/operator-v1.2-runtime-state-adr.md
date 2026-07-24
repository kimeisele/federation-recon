# Operator v1.2 — Durable Runtime-State and Recovery Contract

**Status:** PROPOSED — 2026-07-24
**Issue:** [#35](https://github.com/kimeisele/federation-recon/issues/35)
**Consistency gates:** `CLAUDE.md`, `operator/heartbeat.sh`, Issue #29

---

## 0. Context

Operator v1.1 is decide-only: it reads a validated state file and read-only GitHub metadata, emits one `ACTION`, optionally advances the state file. The committed `operator/state.json` is a bootstrap seed; `--state-file` already supports a separate runtime path. It never executes actions.

This ADR defines the v1.2 contract for durable runtime state across process/session loss, single-writer concurrency, crash recovery, auditability, schema migration, and fail-closed errors — without a database, cross-repository writes, or GitHub-backed runtime persistence.

---

## 1. Bootstrap Seed vs. Runtime Checkpoint

The committed `operator/state.json` (schema v1) is the **immutable bootstrap seed**, never mutated. Runtime state lives at a separate path (default `operator/.runtime/state.json`).

**Initialization** is `heartbeat.sh --init-runtime`: creates parent dir if absent (under lock, see §3), atomically writes state file migrated to schema v2, exits. No directory deletion.

**Normal heartbeat** requires the runtime state file. Absent or invalid JSON → exit 1. No auto-initialization.

**`--init-runtime --force`** re-initializes from seed: writes current state to a tempfile, fsyncs it, atomically replaces `state.json.bak`, directory-fsyncs, then atomically replaces the state file from seed. The lock is never deleted.

**`--state-file PATH`** selects an alternative path; `--init-runtime` and `--force` honor it. All paths reject symlinks via `lstat`-style validation before any read, write, or cleanup. Custom paths must reside on a stable local durable filesystem — durability is the caller's responsibility. Paths on ephemeral filesystems (e.g. `/tmp`) are explicitly supported only for testing.

**`--break-lock`** removes a lock directory after verifying the owning PID is dead. It does **not** acquire the lock, so it cannot deadlock. Use when boot identity is unavailable and the lock is stuck.

### Honest durability

The runtime checkpoint survives process exit / session loss / reboot as a local file. GitHub backs only the seed. `--init-runtime --force` from seed loses accumulated runtime history. Process-kill durability relies on POSIX `rename` atomicity. Power-loss durability requires file+directory fsync on a local filesystem; on filesystems that don't guarantee this, a power failure may revert to the prior valid checkpoint.

---

## 2. Durability Boundary

| Concern | Mechanism |
|---|---|
| Process exit / session loss / reboot | File on disk; no daemon |
| Concurrency | `mkdir` lock directory (§3) |
| Corruption | Atomic replacement + JSON validation on every read |
| Loss | Explicit `--init-runtime --force`; never silent |

**Permissions:** parent dir `0700`, state/backup/lock-metadata files `0600`, lock dir `0700`. Owner-only. Gitignored.

**Path validation** (before any read, write, `rm`, or `mkdir -p`):

1. For each existing ancestor component from the filesystem root to the target path: `lstat` → reject if symlink or not a directory. No owner/mode check on ancestors — only symlink traversal is prevented.
2. Identify the runtime parent directory (e.g. `operator/.runtime/` for the default path, or the dirname of a custom `--state-file`). Verify it is a real directory, not a symlink, and owned by `$(id -u)`.
3. Create only missing suffix components under the last validated ancestor with `umask 077; mkdir -p`.
4. Revalidate the final directory — verify ownership and `0700` mode.

State, backup, lock, and tempfile paths are all validated before use.

---

## 3. Single-Writer Locking

POSIX `mkdir` atomicity provides advisory locking. Lock directory: `$(dirname "$STATE_FILE")/heartbeat.lock/`. Pure Bash 3.2+, no external tools.

### Lock protocol

```
1. Validate parent dir per §2 path validation.
2. If parent absent: umask 077; mkdir -p; revalidate.
3. lock_dir = "$parent_dir/heartbeat.lock/"
4. Attempt mkdir "$lock_dir"
   → Success: write $$, boot_id, acquired_at into $lock_dir/; register EXIT trap rm -rf.
   → EEXIST: read $lock_dir/pid, $lock_dir/boot_id
     a. kill -0 $pid → lock valid: exit 2 (contention)
     b. pid dead + boot_id matches current boot → stale: rm -rf $lock_dir, retry mkdir
     c. pid dead + boot_id differs + boot_id trusted → stale (no process survives reboot):
        rm -rf $lock_dir, retry mkdir
     d. pid dead + boot_id unavailable/unreadable/untrusted → exit 1
        (operator runs --break-lock to clear, then retry)
```

### Boot identity

| OS | Method | Property |
|---|---|---|
| Linux | `/proc/sys/kernel/random/boot_id` | UUID, unique per boot |
| macOS | `sysctl -n kern.boottime` (seconds) | Not unique per boot; in the extreme-edge case of two boots in the same second, case (c) above treats the lock as same-boot and falls through to same-boot stale logic — harmless |

If neither method returns a value, boot identity is unavailable → case (d), fail closed.

### Safety property

No stale lock is broken while any process holds the owner PID (`kill -0 $pid` returns 0 is a prerequisite). If PID is reused by an unrelated process, `kill -0` returns 0 → conservative false contention (exit 2), not lock theft. At operator timescales (minutes between heartbeats), same-boot PID reuse is improbable. This is an availability limitation, not a safety gap.

### Coverage

Lock covers `--init-runtime`, `--init-runtime --force`, and normal heartbeat. `--dry-run` skips the lock. `--break-lock` reads lock metadata but does not acquire the lock. Custom `--state-file` derives the lock path from its parent directory.

---

## 4. Crash States and Recovery

**Process-kill guarantee:** `tempfile.mkstemp` → `json.dump` → `flush` → `fsync` → `os.replace`. POSIX `rename` is atomic — a reader sees only the complete old or complete new file. Stale tempfiles (`operator/.runtime/.heartbeat-state-*`) are cleaned at startup (after path validation, under lock).

**Power-loss behavior:** After `os.replace`, a directory fsync follows (`os.open(dir, O_RDONLY)` → `os.fsync`). On filesystems that honor this, the new state is durable. On filesystems that don't, power loss may revert to the prior valid checkpoint. No data corruption occurs in the process-kill case; power-loss outcomes are filesystem-conditional.

**`--force` backup ordering:** Current state is written to a tempfile, file-fsynced, atomically replaced as `state.json.bak`, directory-fsynced, and only then is the state file replaced from seed. A crash before backup completion loses nothing. A crash between backup and seed-replace leaves `state.json.bak` durable.

**Directory-fsync failure:** After `os.replace` succeeds, `_HB_FSYNC_FAIL_INJECT=1` causes the Python helper to exit 1 before the directory `fsync` call, simulating a real fsync failure. The new state is on disk (rename succeeded), but commit is uncertain — either old or new valid state survives, neither corrupt. Heartbeat exits 1 with a diagnostic.

---

## 5. Compact Auditability

Schema v2 adds `previous_checkpoint`: a fixed-size snapshot of every mutable field (phase, cycle, `expert_calls_this_cycle`, `max_expert_calls`, `last_heartbeat`, `updated_at`, `notes`) before each `write_state`. Nested `previous_checkpoint` is stripped. `null` after `--init-runtime`. Not committed to Git.

No append-only log, no GitHub-backed audit trail, no cryptographic chain.

---

## 6. Schema Migration

During `--init-runtime`, v1 seed → v2 runtime: set `schema_version: 2`, add `"previous_checkpoint": null`. Normal heartbeat validates runtime `schema_version`; unknown → exit 1. Seed never rewritten.

---

## 7. Failure Semantics

| Exit | Meaning |
|---|---|
| 0 | Normal decision (HOLD, ADVANCE, REVIEW, BUILD, SWEEP, policy STOP) |
| 1 | Local irrecoverable — operator must act |
| 2 | Transient — retry may succeed |

No error path emits BUILD/REVIEW/SWEEP/ADVANCE. Common errors:

| Error | Exit | State mutated? |
|---|---|---|
| Missing/corrupt state, invalid JSON/schema, symlink path, wrong owner | 1 | No |
| Lock from live process | 2 | No |
| Lock stuck (boot identity unavailable) | 1 | No — use `--break-lock` |
| Write/disk failure before `os.replace` | 1 | No (original intact) |
| Directory fsync failure after `os.replace` | 1 | **Uncertain:** old or new valid |
| GitHub unavailable | 2 | No |

---

## 8. Considered Alternatives

| Alternative | Rejected because |
|---|---|
| SQLite | Binary dep, migration tooling, non-human-readable |
| GitHub-backed runtime state | Write-scope creds, noisy history, network dependency |
| Append-only audit log | Second file, rotation logic; `previous_checkpoint` suffices |
| `fcntl.flock` via short Python | Lock fd closes when Python exits |
| Lease timeout | False lock-breaks on slow GitHub API |
| No locking | Cron doesn't guarantee non-overlap |

---

## 9. Invariants

| # | Invariant | Verification |
|---|---|---|
| D1.1 | Seed never mutated | SHA-256 before/after any invocation |
| D1.2 | `--init-runtime` creates valid v2 state from seed | Delete state file only, run `--init-runtime` |
| D1.3 | Normal heartbeat without runtime state: exit 1, no file | Delete state file, run heartbeat |
| D1.4 | `--force` backs up to `state.json.bak`, replaces from seed | Advance state, `--force`, verify bak matches pre-force, state is fresh |
| D1.5 | Symlinked paths rejected | `ln -s /tmp/evil state.json`, run heartbeat → exit 1 |
| D2.1 | State file always valid JSON after process kill | `kill -9` at random points during `write_state`; every surviving file parses |
| D2.2 | `git status` shows no `.runtime/` files | Run heartbeat, `git status --porcelain` |
| D2.3 | Permissions: dir `0700`, state `0600` | `ls -ld` / `ls -l` after write |
| D3.1 | Concurrent heartbeat: exit 2, state unchanged | Background heartbeat with `sleep` after lock; second heartbeat |
| D3.2 | Lock released on normal exit | Sequential heartbeats, second acquires lock |
| D3.3 | Same-boot `kill -9`: next heartbeat recovers | Background + kill -9 + second heartbeat |
| D3.4 | Cross-boot stale lock: auto-recovered | Create lock with dead PID + different boot_id; heartbeat proceeds |
| D3.5 | `--init-runtime` and normal serialized by lock | Background init with sleep; normal heartbeat → exit 2 |
| D3.6 | `--dry-run` skips lock | Background heartbeat with sleep; dry-run completes |
| D3.7 | `--break-lock` removes stuck lock | Create lock with dead PID + missing boot_id; `--break-lock` removes it; heartbeat proceeds |
| D4.1 | Stale tempfiles cleaned at startup | Create fake `.heartbeat-state-XXXXXX`; heartbeat removes it |
| D4.2 | `_HB_FSYNC_FAIL_INJECT`: exit 1, no misleading ACTION | Set env, run heartbeat; assert exit 1, no BUILD/REVIEW/SWEEP/ADVANCE |
| D5.1 | `previous_checkpoint` has all pre-write mutable fields | Populate known state; heartbeat; verify all fields match |
| D5.2 | `previous_checkpoint` null after `--init-runtime` | Delete state, `--init-runtime` |
| D5.3 | No nested `previous_checkpoint` | Advance twice; inspect; only one level |
| D6.1 | v1 seed → v2 runtime on `--init-runtime` | Delete state, `--init-runtime`; verify schema v2 + null checkpoint |
| D6.2 | Unknown schema → exit 1 | State with `schema_version: 99` |
| D7.1 | No work-dispatching ACTION on any error | Static review of all `exit`/`die` sites |
| D7.2 | Write failure before `os.replace`: state intact | Make parent read-only; SHA-256 unchanged |

---

## 10. Deployment Assumptions

- Single-user machine; `0700`/`0600` protect against same-user accident, not multi-user malice.
- Local filesystem honoring `fsync` (file+directory) and `mkdir` atomicity. NFS/FUSE may weaken guarantees.
- Single-machine; `mkdir` lock is filesystem-local.
- Seed integrity via PR review + branch ruleset.
- No credentials or secrets in state file.

---

## 11. Follow-Up Issues

| # | Scope |
|---|---|
| 35.1 | `--init-runtime` with lstat path validation, umask 077 parent creation, lock-domain-aware init, `--force` with crash-safe backup ordering, add `operator/.runtime/` to `.gitignore` |
| 35.2 | `mkdir` lock with boot_id/boottime stale detection, `--break-lock`, EXIT trap |
| 35.3 | `previous_checkpoint` in `write_state` with all mutable fields, nested stripping |
| 35.4 | Directory fsync, `0600` chmod, `_HB_FSYNC_FAIL_INJECT` hook |
| 35.5 | Bats tests for all 24 invariants (D1.1–D7.2) |
| 35.6 | Update `CLAUDE.md` for runtime-state convention, lock, `--break-lock`, recovery |
| 35.7 | Regression: all existing heartbeat tests pass |

---

## 12. Decision

**PROPOSED.** 24 testable invariants across 7 decisions. Minimal (one new directory, one new JSON object, Bash 3.2+ + Python3 stdlib only). Local-FS durability honestly distinguished from GitHub-backed seed. No claimed mechanism is absent.
