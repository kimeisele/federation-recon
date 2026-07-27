# S1 Setup — macos-seatbelt backend

Three privileged steps the **owner** must perform by hand. Once done,
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

## Step 2 — Install the trusted wrapper

The wrapper `core/worker_exec.sh` is the ONLY executable permitted in
the sudoers line (Step 3).  It hard-codes the sandbox profile path and
computes the workspace from a validated run-id — the caller cannot
substitute either.

It must be owned by root and **not writable by the owner or the worker**.
If the owner could edit it, they could replace the profile path or drop
the `env -i` and inject environment variables across the boundary.
If the worker could edit it, the worker could escape its own sandbox.

```bash
# Install with root ownership; mode 0755 (rwxr-xr-x)
sudo chown root:wheel core/worker_exec.sh
sudo chmod 0755 core/worker_exec.sh

# Verify — owner must NOT be able to write it
ls -l core/worker_exec.sh
# Expected: -rwxr-xr-x  1 root  wheel  ... core/worker_exec.sh

# Verify it runs (will fail because run-id directory doesn't exist,
# but proves it's executable and validates the argument)
sudo -u _jcode_worker "$(pwd)/core/worker_exec.sh" test123
# Expected: "env: ... No such file or directory" (workspace dir missing)
#           NOT "command not found" and NOT a sudo password prompt.
```

---

## Step 3 — NOPASSWD sudoers line

Add this **exact** line to `/etc/sudoers.d/jcode-worker`, replacing
`<owner>` with your account name (not `%staff`):

```
<owner>  ALL=(_jcode_worker) NOPASSWD: /absolute/path/core/worker_exec.sh
```

Example for user `ss` with the repo at `/Users/ss/dev/kimeisele/federation-recon`:

```
ss  ALL=(_jcode_worker) NOPASSWD: /Users/ss/dev/kimeisele/federation-recon/core/worker_exec.sh
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
sudo -u _jcode_worker /absolute/path/core/worker_exec.sh test123
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

## Run the canary suite

```bash
cd /path/to/federation-recon
/usr/bin/python3 core/launcher.py
```

### Expected output

```
=== Execution Core S1 — Canary Suite ===

Backend: macos-seatbelt
Profile: /path/to/federation-recon/core/profiles/worker.sb

  canary no_network: PASS
           tcp_1.1.1.1_80: BLOCKED (...) | tcp_8.8.8.8_53: BLOCKED (...) | dns_example_com: BLOCKED (...)
  canary fs_confinement: PASS
           read_real_secret: BLOCKED (...) | read_planted_secret: BLOCKED (...) | list_home: BLOCKED (...) | write_outside: BLOCKED (...) | write_inside: ALLOWED (...)
  canary pid_limit: PASS
           fork bomb stopped after roughly N concurrent children in parent
  canary tree_kill: PASS
           escapee PID NNNNN was killed by kill_all(). uid-based kill survived the setsid+double-fork escape attempt.

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
