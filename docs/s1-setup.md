# S1 Setup — macos-seatbelt backend

Four privileged steps the **owner** must perform by hand. Once done,
`python3 core/launcher.py` runs the canary suite and verifies the
backend.

---

## Step 1 — Create the unprivileged worker user

The worker needs its own UID and a dedicated group — never the owner's
UID (501 on this machine) or the `staff` group (GID 20).  Sharing either
would give the worker the owner's DAC identity and let `pkill -9 -u`
kill the owner's login session.

Pick a UID clearly outside the normal user range.  The highest UID
currently in use on this machine is 501, so 601 is safe:

```bash
# Create a dedicated group for the worker
sudo dscl . -create /Groups/_jcode_worker
sudo dscl . -create /Groups/_jcode_worker PrimaryGroupID 601
sudo dscl . -create /Groups/_jcode_worker RealName "Jcode Worker Group"

# Create the worker user with UID 601, owned by its own group
sudo dscl . -create /Users/_jcode_worker
sudo dscl . -create /Users/_jcode_worker UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_worker UniqueID 601
sudo dscl . -create /Users/_jcode_worker PrimaryGroupID 601
sudo dscl . -create /Users/_jcode_worker NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_worker RealName "Jcode Worker"
```

Do **not** append `_jcode_worker` to `staff` or any group the owner
belongs to.  The worker gets exactly one group — its own.

Verify — worker and owner must have different uid *and* gid:

```bash
echo "Owner: uid=$(id -u) gid=$(id -g)"
echo "Worker: uid=$(dscl . -read /Users/_jcode_worker UniqueID | awk '{print $2}') gid=$(dscl . -read /Users/_jcode_worker PrimaryGroupID | awk '{print $2}')"

# Confirm they differ
[ "$(id -u)" != "$(dscl . -read /Users/_jcode_worker UniqueID | awk '{print $2}')" ] && echo "PASS: different UIDs"
[ "$(id -g)" != "$(dscl . -read /Users/_jcode_worker PrimaryGroupID | awk '{print $2}')" ] && echo "PASS: different GIDs"

# Confirm worker is NOT in staff
dscl . -read /Groups/staff GroupMembership | grep -q _jcode_worker && echo "FAIL: worker in staff" || echo "PASS: worker not in staff"

# Confirm sudo -u _jcode_worker works
sudo -u _jcode_worker whoami
# Must print "_jcode_worker" without prompting for a password.
```

If `sudo -u _jcode_worker` prompts for a password, the user was created
with a shadow hash — delete it:

```bash
sudo dscl . -delete /Users/_jcode_worker Password
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
sudo mkdir -p "$BASE/canaries" "$BASE/profiles"
sudo chown root:wheel "$BASE/canaries" "$BASE/profiles"
sudo chmod 0755 "$BASE/canaries" "$BASE/profiles"

# Wrapper (root:wheel, 0755 — owner can read/execute but NOT write)
sudo cp "$REPO/core/worker_exec.sh" "$BASE/worker_exec.sh"
sudo chown root:wheel "$BASE/worker_exec.sh"
sudo chmod 0755 "$BASE/worker_exec.sh"

# Sandbox profile
sudo cp "$REPO/core/profiles/worker.sb" "$BASE/profiles/worker.sb"
sudo chown root:wheel "$BASE/profiles/worker.sb"
sudo chmod 0644 "$BASE/profiles/worker.sb"

# Canary scripts (the payloads that run inside the sandbox — from core/payloads/)
for f in "$REPO/core/payloads/"*.py; do
    sudo cp "$f" "$BASE/canaries/"
done
sudo chown root:wheel "$BASE/canaries/"*.py
sudo chmod 0444 "$BASE/canaries/"*.py
```

### 2c — Verify the wrapper

The wrapper is the ONLY command sudoers permits as `_jcode_worker`.  If
the owner could rewrite it, the sudoers line grants the owner arbitrary
execution as the worker — which is not a catastrophe since the owner is
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

# Wrapper runs (will fail on missing run-id directory — that's fine)
sudo -u _jcode_worker /usr/local/var/jcode-runs/worker_exec.sh test123 no_network
# Expected: "env: ... No such file or directory" (workspace dir missing)
#           NOT "command not found" and NOT a sudo password prompt.
```

---

## Step 3 — NOPASSWD sudoers line

Add this **exact** line to `/etc/sudoers.d/jcode-worker`, replacing
`<owner>` with your account name (not `%staff`):

```
<owner>  ALL=(_jcode_worker) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
```

Example for user `ss`:

```
ss  ALL=(_jcode_worker) NOPASSWD: /usr/local/var/jcode-runs/worker_exec.sh
```

Then fix permissions:

```bash
sudo chown root:wheel /etc/sudoers.d/jcode-worker
sudo chmod 440 /etc/sudoers.d/jcode-worker
```

Verify:

```bash
sudo -l
# Must show the worker_exec.sh entry without prompting for a password.

# Wrapper is permitted
sudo -u _jcode_worker /usr/local/var/jcode-runs/worker_exec.sh test123 no_network
# Expected: runs (fails on missing workspace dir — that's fine)

# Direct sandbox-exec MUST be REFUSED — this proves the sudoers line
# has no wildcards that allow bypassing the wrapper.
sudo -u _jcode_worker /usr/bin/sandbox-exec -f /dev/null /usr/bin/true
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

echo "=== Profile ==="
ls -l "$BASE/profiles/worker.sb"
# -rw-r--r--  root  wheel

echo "=== Canary scripts ==="
ls -l "$BASE/canaries/"
# -r--r--r--  root  wheel  _fake_attacker.py
# -r--r--r--  root  wheel  fs_confinement.py
# -r--r--r--  root  wheel  no_network.py
# -r--r--r--  root  wheel  pid_limit.py
# -r--r--r--  root  wheel  tree_kill.py

echo "=== Boundary check ==="
# At setup time no per-run directories exist.  Everything under the
# base should be non-world-writable.  Per-run directories created at
# runtime are mode 0777 (the sandbox profile handles confinement).
find "$BASE" -perm -o+w -ls
# Expected: no output (or only per-run dirs from a concurrent run)

# The wrapper is not writable by anyone but root
[ "$(stat -f '%p' "$BASE/worker_exec.sh" | cut -c 3-9)" = "755" ] \
    && echo "PASS: wrapper mode 0755"

# The canary directory is not writable by the worker
sudo -u _jcode_worker touch "$BASE/canaries/test_write" 2>&1 \
    && echo "FAIL: worker can write to canary dir" \
    || echo "PASS: worker cannot write to canary dir"
```

---

## Run the canary suite

```bash
cd /path/to/federation-recon
/usr/bin/python3 core/launcher.py
```

### Expected output

```
=== Execution Core S1 — Canary Suite ===

Backend: macos-seatbelt
Profile: /usr/local/var/jcode-runs/profiles/worker.sb

  canary no_network: PASS
           tcp_1.1.1.1_443: BLOCKED (...) | dns_example_com: BLOCKED (...)
  canary fs_confinement: PASS
           read_real_secret: BLOCKED (...) | read_planted_secret: BLOCKED (...) | list_home: BLOCKED (...) | list_keychains: BLOCKED (...) | list_private_tmp: BLOCKED (...) | write_outside: BLOCKED (...) | write_inside: ALLOWED (...)
  canary pid_limit: PASS
           fork bomb stopped after N concurrent children in parent (rlimit enforced)
  canary tree_kill: PASS
           escapee PID NNNNN was alive before kill_all and gone after. uid-based kill survived the setsid+double-fork escape attempt.

Canary suite: 4/4 capabilities confirmed.

All canaries complete.  Ready for orders (S2+).
```

`4/4 capabilities confirmed` means pass.  Anything else is fail.

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

## Tree-kill mechanism

The backend uses `pkill -9 -u _jcode_worker` to kill every process
owned by the worker user.  `kill(-pgid)` alone is insufficient: a child
that calls `setsid()` then double-forks creates a grandchild in a new
session and process group, unreachable via the original pgid.  `pkill
-u` kills by uid — which the escapee cannot shed on macOS (no user
namespaces).  The `tree_kill` canary verifies this by spawning exactly
such an escapee and confirming it dies.
