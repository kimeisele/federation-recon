# S1 Setup — macos-seatbelt backend (per-run uid pool)

Eight privileged steps the **owner** must perform by hand. Once done,
`python3 core/launcher.py` runs the canary suite and verifies the
backend.

This document describes the **pool** architecture: eight unprivileged
slot users (`_jcode_w01`..`_jcode_w08`, uid 611..618) replace the
earlier singleton `_jcode_worker` user.  Each slot runs one sandbox;
concurrency up to pool size (8) is permitted.  Pool exhaustion results
in clean refusal, not a kill.

---

## Step 1 — Create the slot users

The pool uses eight dedicated UIDs (611..618), one per slot.  Each
gets its own group — never the owner's UID (501 on this machine) or
the `staff` group (GID 20).  Sharing either would give the worker the
owner's DAC identity and let `pkill -9 -u` kill the owner's login
session.

All eight UIDs are outside the normal user range (highest on this
machine is 501), so 611..618 is safe.

Create the slot user and group for `_jcode_w01` through `_jcode_w08`:

```bash
# Slot 1
sudo dscl . -create /Groups/_jcode_w01
sudo dscl . -create /Groups/_jcode_w01 PrimaryGroupID 611
sudo dscl . -create /Groups/_jcode_w01 RealName "Jcode Slot 1 Group"
sudo dscl . -create /Users/_jcode_w01
sudo dscl . -create /Users/_jcode_w01 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w01 UniqueID 611
sudo dscl . -create /Users/_jcode_w01 PrimaryGroupID 611
sudo dscl . -create /Users/_jcode_w01 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w01 RealName "Jcode Slot 1"

# Slot 2 — uid 612, gid 612
sudo dscl . -create /Groups/_jcode_w02
sudo dscl . -create /Groups/_jcode_w02 PrimaryGroupID 612
sudo dscl . -create /Groups/_jcode_w02 RealName "Jcode Slot 2 Group"
sudo dscl . -create /Users/_jcode_w02
sudo dscl . -create /Users/_jcode_w02 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w02 UniqueID 612
sudo dscl . -create /Users/_jcode_w02 PrimaryGroupID 612
sudo dscl . -create /Users/_jcode_w02 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w02 RealName "Jcode Slot 2"

# Slot 3 — uid 613, gid 613
sudo dscl . -create /Groups/_jcode_w03
sudo dscl . -create /Groups/_jcode_w03 PrimaryGroupID 613
sudo dscl . -create /Groups/_jcode_w03 RealName "Jcode Slot 3 Group"
sudo dscl . -create /Users/_jcode_w03
sudo dscl . -create /Users/_jcode_w03 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w03 UniqueID 613
sudo dscl . -create /Users/_jcode_w03 PrimaryGroupID 613
sudo dscl . -create /Users/_jcode_w03 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w03 RealName "Jcode Slot 3"

# Slot 4 — uid 614, gid 614
sudo dscl . -create /Groups/_jcode_w04
sudo dscl . -create /Groups/_jcode_w04 PrimaryGroupID 614
sudo dscl . -create /Groups/_jcode_w04 RealName "Jcode Slot 4 Group"
sudo dscl . -create /Users/_jcode_w04
sudo dscl . -create /Users/_jcode_w04 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w04 UniqueID 614
sudo dscl . -create /Users/_jcode_w04 PrimaryGroupID 614
sudo dscl . -create /Users/_jcode_w04 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w04 RealName "Jcode Slot 4"

# Slot 5 — uid 615, gid 615
sudo dscl . -create /Groups/_jcode_w05
sudo dscl . -create /Groups/_jcode_w05 PrimaryGroupID 615
sudo dscl . -create /Groups/_jcode_w05 RealName "Jcode Slot 5 Group"
sudo dscl . -create /Users/_jcode_w05
sudo dscl . -create /Users/_jcode_w05 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w05 UniqueID 615
sudo dscl . -create /Users/_jcode_w05 PrimaryGroupID 615
sudo dscl . -create /Users/_jcode_w05 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w05 RealName "Jcode Slot 5"

# Slot 6 — uid 616, gid 616
sudo dscl . -create /Groups/_jcode_w06
sudo dscl . -create /Groups/_jcode_w06 PrimaryGroupID 616
sudo dscl . -create /Groups/_jcode_w06 RealName "Jcode Slot 6 Group"
sudo dscl . -create /Users/_jcode_w06
sudo dscl . -create /Users/_jcode_w06 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w06 UniqueID 616
sudo dscl . -create /Users/_jcode_w06 PrimaryGroupID 616
sudo dscl . -create /Users/_jcode_w06 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w06 RealName "Jcode Slot 6"

# Slot 7 — uid 617, gid 617
sudo dscl . -create /Groups/_jcode_w07
sudo dscl . -create /Groups/_jcode_w07 PrimaryGroupID 617
sudo dscl . -create /Groups/_jcode_w07 RealName "Jcode Slot 7 Group"
sudo dscl . -create /Users/_jcode_w07
sudo dscl . -create /Users/_jcode_w07 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w07 UniqueID 617
sudo dscl . -create /Users/_jcode_w07 PrimaryGroupID 617
sudo dscl . -create /Users/_jcode_w07 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w07 RealName "Jcode Slot 7"

# Slot 8 — uid 618, gid 618
sudo dscl . -create /Groups/_jcode_w08
sudo dscl . -create /Groups/_jcode_w08 PrimaryGroupID 618
sudo dscl . -create /Groups/_jcode_w08 RealName "Jcode Slot 8 Group"
sudo dscl . -create /Users/_jcode_w08
sudo dscl . -create /Users/_jcode_w08 UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_w08 UniqueID 618
sudo dscl . -create /Users/_jcode_w08 PrimaryGroupID 618
sudo dscl . -create /Users/_jcode_w08 NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_w08 RealName "Jcode Slot 8"
```

Do **not** append any slot user to `staff` or any group the owner
belongs to.  Each slot gets exactly one group — its own.

Verify:

```bash
for slot in _jcode_w01 _jcode_w02 _jcode_w03 _jcode_w04 _jcode_w05 _jcode_w06 _jcode_w07 _jcode_w08; do
    echo "Slot $slot: uid=$(dscl . -read /Users/$slot UniqueID | awk '{print $2}') gid=$(dscl . -read /Users/$slot PrimaryGroupID | awk '{print $2}')"
done

# Confirm they differ from owner
echo "Owner: uid=$(id -u) gid=$(id -g)"
for slot in _jcode_w01 _jcode_w02 _jcode_w03 _jcode_w04 _jcode_w05 _jcode_w06 _jcode_w07 _jcode_w08; do
    uid_val=$(dscl . -read /Users/$slot UniqueID | awk '{print $2}')
    [ "$(id -u)" != "$uid_val" ] && echo "PASS: $slot different UID" || echo "FAIL: $slot same UID as owner"
done
```

If `sudo -u _jcode_w01` prompts for a password, remove the shadow hash:

```bash
for slot in _jcode_w01 _jcode_w02 _jcode_w03 _jcode_w04 _jcode_w05 _jcode_w06 _jcode_w07 _jcode_w08; do
    sudo dscl . -delete /Users/$slot Password 2>/dev/null || true
done
```

---

## Step 2 — Create the trusted base directory and install artifacts

The sandbox boundary depends on a root-owned base directory whose
ancestors are not world-writable.  `/tmp` is world-writable (`drwxrwxrwt`)
— any local user can pre-create or symlink paths under it.  We must not
execute anything from a location an attacker can influence.

The base directory lives at `/usr/local/var/jcode-runs`.  Its ancestors
(`/usr`, `/usr/local`, `/usr/local/var`) are system directories; none
are world-writable.

### 2a — Create the base directory

```bash
sudo mkdir -p /usr/local/var/jcode-runs
sudo chown root:wheel /usr/local/var/jcode-runs
sudo chmod 0771 /usr/local/var/jcode-runs
```

Mode `0771` means:
- Owner (root): read, write, execute
- Group (wheel): read, write, execute (can create per-run directories)
- Others: execute only (can traverse to known subpaths)

Only root and wheel members can list the directory or create entries
inside it.  On a single-user macOS machine, wheel contains only root
and the owner.  Per-run directories underneath are created by the
owner (a wheel member), mode `0777`, so the worker can read and write
its own workspace.  The sandbox profile — not Unix permissions — is
the confinement boundary for what runs inside.

Verify:

```bash
ls -ld /usr/local/var/jcode-runs
# Expected: drwxrwx--x  ... root  wheel  ... /usr/local/var/jcode-runs

# Confirm it is not world-writable (the 'other' permission digit is not 7)
[ "$(stat -f '%Mp' /usr/local/var/jcode-runs | tail -c 2)" != "7" ] && echo "PASS: not world-writable"

# Confirm it is root-owned
[ "$(stat -f '%Su' /usr/local/var/jcode-runs)" = "root" ] && echo "PASS: root-owned"
```

### 2b — Create subdirectories and install files

```bash
REPO="/path/to/federation-recon"
BASE="/usr/local/var/jcode-runs"

# Subdirectories
sudo mkdir -p "$BASE/canaries" "$BASE/profiles" "$BASE/runs" "$BASE/slots"
sudo chown root:wheel "$BASE/canaries" "$BASE/profiles" "$BASE/runs" "$BASE/slots"
sudo chmod 0755 "$BASE/canaries" "$BASE/profiles"
sudo chmod 0770 "$BASE/runs" "$BASE/slots"

# Wrapper (root:wheel, 0755 — owner can read/execute but NOT write)
sudo cp "$REPO/core/worker_exec.sh" "$BASE/worker_exec.sh"
sudo chown root:wheel "$BASE/worker_exec.sh"
sudo chmod 0755 "$BASE/worker_exec.sh"

# Sandbox profile
sudo cp "$REPO/core/profiles/worker.sb" "$BASE/profiles/worker.sb"
sudo chown root:wheel "$BASE/profiles/worker.sb"
sudo chmod 0644 "$BASE/profiles/worker.sb"

# Kill-self helper (per-slot wrapper, NOT a uid-based kill)
sudo cp "$REPO/core/worker_kill_self.sh" "$BASE/worker_kill_self.sh"
sudo chown root:wheel "$BASE/worker_kill_self.sh"
sudo chmod 0755 "$BASE/worker_kill_self.sh"

# Canary scripts (the payloads that run inside the sandbox — from core/payloads/)
for f in "$REPO/core/payloads/"*.py; do
    sudo cp "$f" "$BASE/canaries/"
done
sudo chown root:wheel "$BASE/canaries/"*.py
sudo chmod 0444 "$BASE/canaries/"*.py
```

### 2c — Verify the wrapper

The wrapper is the ONLY command sudoers permits as any slot user.  If
the owner could rewrite it, the sudoers line grants the owner arbitrary
execution as the slot — which is not a catastrophe since the owner is
trusted, but it means the wrapper must not live at a path a *worker* or
any other local user can influence.

```bash
# Wrapper is root-owned and not owner-writable
ls -l /usr/local/var/jcode-runs/worker_exec.sh
# Expected: -rwxr-xr-x  1 root  wheel  ... worker_exec.sh

# Verify — owner must NOT be able to write it
[ ! -w /usr/local/var/jcode-runs/worker_exec.sh ] && echo "PASS: not owner-writable"

# Canary scripts are root-owned and read-only
ls -l /usr/local/var/jcode-runs/canaries/
# Expected: -r--r--r--  1 root  wheel  ... for each .py file
```

---

## Step 3 — NOPASSWD sudoers entries

Add these lines to `/etc/sudoers.d/jcode-worker`, replacing `<owner>`
with your account name (not `%staff`):

```
<owner>  ALL=(_jcode_w01) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w02) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w03) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w04) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w05) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w06) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w07) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
<owner>  ALL=(_jcode_w08) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
```

And the kill-self wrappers (one per slot):

```
<owner>  ALL=(_jcode_w01) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w02) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w03) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w04) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w05) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w06) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w07) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
<owner>  ALL=(_jcode_w08) NOPASSWD: /usr/local/var/jcode-runs/worker_kill_self.sh ""
```

Then fix permissions:

```bash
sudo chown root:wheel /etc/sudoers.d/jcode-worker
sudo chmod 440 /etc/sudoers.d/jcode-worker
```

The trailing `""` on the kill-self entries is load-bearing: it prevents
the command from being run with any argument.  The kill-self wrapper
hard-codes its own target uid via `id -u` and takes no arguments.

Verify:

```bash
sudo -l
# Must show the 16 entries without prompting for a password.

# Wrapper is permitted for slot 1
sudo -u _jcode_w01 /usr/local/var/jcode-runs/worker_exec.sh test123 no_network
# Expected: runs (fails on missing workspace dir — that's fine)

# Direct sandbox-exec MUST be REFUSED — this proves the sudoers line
# has no wildcards that allow bypassing the wrapper.
sudo -u _jcode_w01 /usr/bin/sandbox-exec -f /dev/null /usr/bin/true
# Expected: "Sorry, user <owner> is not allowed to execute ..."
```

The refusal of direct `sandbox-exec` is the key security check: it
confirms the caller cannot supply an arbitrary profile (`-f`) or
workspace directory (`-D`).  Only the wrapper's hard-coded profile and
computed workspace are ever used.

**Where it goes:** `/etc/sudoers.d/jcode-worker` (not directly in
`/etc/sudoers`).  macOS `sudo` reads `/etc/sudoers.d/*` via `#includedir`.

---

## Step 4 — Verify the whole boundary

This step confirms that every component of the trusted base is in place
and correctly owned.

```bash
BASE="/usr/local/var/jcode-runs"

echo "=== Base directory ==="
ls -ld "$BASE"
# drwxrwx--x  root  wheel

echo "=== Wrapper ==="
ls -l "$BASE/worker_exec.sh"
# -rwxr-xr-x  root  wheel

echo "=== Kill-self helper ==="
ls -l "$BASE/worker_kill_self.sh"
# -rwxr-xr-x  root  wheel

echo "=== Profile ==="
ls -l "$BASE/profiles/worker.sb"
# -rw-r--r--  root  wheel

echo "=== Canary scripts ==="
ls -l "$BASE/canaries/"
# -r--r--r--  root  wheel  fs_confinement.py
# -r--r--r--  root  wheel  ingress_symlink.py
# -r--r--r--  root  wheel  kill_persistent.py
# -r--r--r--  root  wheel  no_network.py
# -r--r--r--  root  wheel  pid_limit.py
# -r--r--r--  root  wheel  pool_integrity.py
# -r--r--r--  root  wheel  symlink_egress.py
# -r--r--r--  root  wheel  tree_kill.py

echo "=== Slot users ==="
dscl . -list /Users | grep _jcode_w

echo "=== Boundary check ==="
# At setup time no per-run directories exist.  Everything under the
# base should be non-world-writable.  Per-run directories created at
# runtime are mode 0777 (the sandbox profile handles confinement).
find "$BASE" -perm -o+w -ls
# Expected: no output (or only per-run dirs from a concurrent run)

# The wrapper is not writable by anyone but root
[ "$(stat -f '%p' "$BASE/worker_exec.sh" | cut -c 3-9)" = "755" ] \
    && echo "PASS: wrapper mode 0755"

# The canary directory is not writable by any slot user
for slot in _jcode_w01 _jcode_w02 _jcode_w03 _jcode_w04 _jcode_w05 _jcode_w06 _jcode_w07 _jcode_w08; do
    sudo -u "$slot" touch "$BASE/canaries/test_write" 2>&1 \
        && echo "FAIL: $slot can write to canary dir" \
        || true
done
echo "PASS: no slot can write to canary dir"
```

---

## Step 5 — Install the kill-self helper

The backend uses `worker_kill_self.sh` to kill every process owned by a
slot.  Each invocation runs AS the slot uid via `sudo -u <slot>`; the
wrapper reads `id -u` to determine which uid to kill.  No uid string
crosses the sudo boundary.

### 5a — Install the script (already done in Step 2b, shown here for reference)

```bash
REPO="/path/to/federation-recon"
BASE="/usr/local/var/jcode-runs"

sudo cp "$REPO/core/worker_kill_self.sh" "$BASE/worker_kill_self.sh"
sudo chown root:wheel "$BASE/worker_kill_self.sh"
sudo chmod 0755 "$BASE/worker_kill_self.sh"
```

Root ownership is critical: the caller must not be able to rewrite
what sudoers permits.

### 5b — Verify the sudoers entries (already done in Step 3)

```bash
# Run from / — sudo hands the helper the caller's working directory,
# and if the slot user cannot read that directory /bin/sh writes a
# "shell-init: error retrieving current directory" complaint to stderr
# before the script's own `cd /` can run. The backend passes cwd="/"
# for exactly this reason, and judges the kill by an empty stderr.
(cd / && sudo -n -u _jcode_w01 /usr/local/var/jcode-runs/worker_kill_self.sh)
# Expected: exit 0 or 1 (no slot processes), no stderr, no prompt.

# The same command WITH any argument is REFUSED.
sudo -n -u _jcode_w01 /usr/local/var/jcode-runs/worker_kill_self.sh --help
# Expected: "sudo: a password is required"

# An arbitrary command as a slot user is still REFUSED.
sudo -n -u _jcode_w01 /bin/sh
# Expected: "sudo: a password is required"
```

---

## Step 6 — Verify pool integrity

Before running the full canary suite, confirm all eight slot users are
correctly configured:

```bash
cd /path/to/federation-recon
/usr/bin/python3 -c "
from core.backends.macos_seatbelt import pool_status, _SLOT_NAMES
print('Pool slots:', _SLOT_NAMES)
print('Status:', pool_status())
"
```

Expected output:
```
Pool slots: ['_jcode_w01', '_jcode_w02', '_jcode_w03', '_jcode_w04', '_jcode_w05', '_jcode_w06', '_jcode_w07', '_jcode_w08']
Status: {'_jcode_w01': 'free', '_jcode_w02': 'free', '_jcode_w03': 'free', '_jcode_w04': 'free', '_jcode_w05': 'free', '_jcode_w06': 'free', '_jcode_w07': 'free', '_jcode_w08': 'free'}
```

All eight should be `free`.  Any slot showing `claimed` or `quarantined`
means a previous run left state behind — run `reconcile()` or clean the
slots directory manually.

---

## Step 7 — Run the canary suite

```bash
cd /path/to/federation-recon
/usr/bin/python3 core/launcher.py
```

### Expected output

```
=== Execution Core S1 — Canary Suite (per-run uid pool) ===

Pool: 8 free, 0 claimed, 0 quarantined (8 total)
  _jcode_w01: free
  _jcode_w02: free
  ...

Backend: macos-seatbelt
Profile: /usr/local/var/jcode-runs/profiles/worker.sb

  canary pool_integrity: PASS
           all 8 slots verified: uid 611..618, ...
  canary no_network: PASS
           denial — ... | preservation — ...
  canary fs_confinement: PASS
           read_real_secret: BLOCKED (...) | ... | write_inside: ALLOWED (...)
  canary pid_limit: PASS
           denial — fork bomb stopped ... | preservation — ...
  canary tree_kill: PASS
           denial — escapee PID ... killed and gone.  preservation — decoy alive.
  canary kill_persistent: PASS
           kill_slot reduced regenerating processes to zero on ...
  canary symlink_egress: PASS
           backend refused symlink egress: not a regular file: ...
  canary ingress_symlink: PASS
           Phase 1 — backend refused pre-created run directory: ...

Canary suite: 8/8 capabilities confirmed.
reconcile(): zero orphans

Pool: 8 free, 0 claimed, 0 quarantined (8 total)

All canaries complete.  Ready for orders (S2+).
```

`8/8 capabilities confirmed` and zero quarantined slots means pass.
Anything else is fail.

### Canary inventory

Each canary proves one capability of the isolation boundary:

| Canary | What it proves |
|---|---|
| `pool_integrity` | All eight slot users exist with correct uid, shell, and group membership; sudo -u <slot> commands are refused. |
| `no_network` | The sandbox profile blocks TCP and DNS; a network-free compute job completes correctly. |
| `fs_confinement` | The sandbox profile blocks reads of secrets, home, keychains, private-tmp, and writes outside the workspace; writes inside the workspace succeed (preservation, verified by per-run checksum). |
| `pid_limit` | `ulimit -u` (RLIMIT_NPROC) enforced in the wrapper stops a fork bomb; a job forking within budget completes. |
| `tree_kill` | Per-slot kill terminates a daemonised grandchild that escaped the original process group; other slots' processes survive. |
| `kill_persistent` | The STOP-then-KILL protocol clears a churning process population with continuous PID turnover. |
| `symlink_egress` | The egress path rejects symlinks — `O_NOFOLLOW` + `S_ISREG` prevents confused-deputy exfiltration. |
| `ingress_symlink` | The ingress path rejects pre-existing run directories — `os.mkdir` without `exist_ok` and `O_EXCL|O_NOFOLLOW` on write prevent writing through a worker-planted symlink. |

### File inventory

Files installed under `/usr/local/var/jcode-runs/`:

| Path | Mode | Owner | Purpose |
|---|---|---|---|
| `worker_exec.sh` | `0755` | `root:wheel` | Gateway wrapper (the only command sudoers permits as a slot user) |
| `worker_kill_self.sh` | `0755` | `root:wheel` | Per-slot kill wrapper (uses `id -u` to determine target uid) |
| `profiles/worker.sb` | `0644` | `root:wheel` | Apple Seatbelt sandbox profile |
| `canaries/*.py` | `0444` | `root:wheel` | Payload scripts executed inside the sandbox (not the canary orchestrators — those run from the repo)
| `runs/` | `0770` | `root:wheel` | Per-run inner workspaces (created at runtime, mode 0777) |
| `slots/` | `0770` | `root:wheel` | Slot claim directories (one per active run) |

### Refusal demo

```bash
/usr/bin/python3 core/launcher.py mem_limit package_network
```

Expected stderr:

```
REFUSED: capability 'mem_limit' not available on backend 'macos-seatbelt'.
  Policy field 'unclaimable_capabilities.mem_limit': RLIMIT_AS raises ValueError on macOS. ...
REFUSED: capability 'package_network' not available on backend 'macos-seatbelt'.
  Policy field 'unclaimable_capabilities.package_network': not built
```

---

## Step 8 — Maintain

### Adding or removing a slot

If you add or remove slots, update:
1. `core/backends/macos_seatbelt.py`: `_SLOT_NAMES`, `_SLOT_UIDS`, `_SLOT_MAP`
2. The dscl user/group creation above
3. `/etc/sudoers.d/jcode-worker` (add/remove sudoers entries)

### Restoring a quarantined slot

A quarantined slot shows as `quarantined` in pool status.  To restore it
(only after confirming the reason is resolved):

```bash
sudo rm -rf /usr/local/var/jcode-runs/slots/_jcode_w01.quarantined.*
```

Then run the canary suite again — the slot will be available.

### Troubleshooting

If a canary fails:
1. Check the error message — it names the specific check and expectation.
2. Check pool status: `python3 -c "from core.backends.macos_seatbelt import pool_status; print(pool_status())"`
3. For slot-level errors, check `/usr/local/var/jcode-runs/slots/` for quarantined entries.
4. Run `python3 -c "from core.backends.macos_seatbelt import reconcile; print(reconcile())"` to clean orphaned state.
