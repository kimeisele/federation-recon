# S1 Setup — macos-seatbelt backend

Two privileged steps the **owner** must perform by hand. Once done,
`python3 core/launcher.py` runs the canary suite and verifies the
backend.

---

## Step 1 — Create the unprivileged worker user

```bash
sudo dscl . -create /Users/_jcode_worker
sudo dscl . -create /Users/_jcode_worker UserShell /usr/bin/false
sudo dscl . -create /Users/_jcode_worker UniqueID 501
sudo dscl . -create /Users/_jcode_worker PrimaryGroupID 20
sudo dscl . -create /Users/_jcode_worker NFSHomeDirectory /var/empty
sudo dscl . -create /Users/_jcode_worker RealName "Jcode Worker"
sudo dscl . -append /Groups/staff GroupMembership _jcode_worker
```

Choose a UniqueID not already in use.  Check with `dscl . -list /Users UniqueID`.

Verify:

```bash
dscl . -read /Users/_jcode_worker
# Shell must be /usr/bin/false, HomeDirectory /var/empty.
sudo -u _jcode_worker whoami
# Must print "_jcode_worker" without prompting for a password.
```

If `sudo -u _jcode_worker` prompts for a password, the user was created
with a shadow hash — delete it:

```bash
sudo dscl . -delete /Users/_jcode_worker Password
```

---

## Step 2 — NOPASSWD sudoers line

Add this **exact** line to `/etc/sudoers.d/jcode-worker`:

```
%staff  ALL=(_jcode_worker) NOPASSWD: /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/sandbox-exec *
```

Then fix permissions:

```bash
sudo chown root:wheel /etc/sudoers.d/jcode-worker
sudo chmod 440 /etc/sudoers.d/jcode-worker
```

Verify:

```bash
sudo -l
# Must show the jcode-worker entry without prompting for a password.
sudo -u _jcode_worker env -i PATH=/usr/bin:/bin /usr/bin/true
# Must succeed without prompting.
```

The wildcard `*` is intentionally narrow: it only matches arguments
after `sandbox-exec`.  It does **not** grant arbitrary `sudo -u
_jcode_worker` — the full command prefix is fixed.

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
