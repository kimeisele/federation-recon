#!/usr/bin/env bats
#
# Paired tests for the verification confinement profile (#232, #233).
#
# `docs/execution-core-adr.md` §7.3 states the rule this file exists to satisfy:
#
#   Der Fäulnisvektor ist Druck, nicht Größe: ein breites `allow`, nachts
#   eingefügt, um zu entsperren — exakt so entstand das undichte Profil in der
#   Messung oben. **Keine `allow`-Zeile ohne gepaarten Negativtest.**
#
# The profile shipped in #232 had none. Every `allow` line below therefore gets
# two assertions: that it permits what it was added for (**preservation**), and
# that it does not reach past its subpath (**denial**).
#
# Both halves are mandatory and the reason is measured, not theoretical. §7.3
# again: "Ein Loch besteht jeden Erhaltungstest, eine Leiche besteht jeden
# Verweigerungstest — dieses Projekt hat eine Leiche ausgeliefert." A profile
# that fails to parse blocks everything and passes every denial test alone. An
# ad-hoc run of these checks on 2026-08-10 accidentally included a heredoc
# terminator in the profile and would have reported exactly that false pass;
# only the preservation half caught it.
#
# This suite reads the profile out of `scripts/review.sh` rather than carrying
# its own copy. `docs/operator-lessons.md`: a test that duplicates what it
# guards is not a test — it passes when production breaks.

setup_file() {
  export REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
}

setup() {
  command -v sandbox-exec >/dev/null \
    || skip "no sandbox-exec on this platform (see #233)"

  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export WT="$SANDBOX/wt" SCRATCH="$SANDBOX/scratch" OUTSIDE="$SANDBOX/outside"
  mkdir -p "$WT" "$SCRATCH" "$OUTSIDE"
  printf 'worktree content\n' > "$WT/file.txt"
  printf 'SECRETVALUE\n' > "$OUTSIDE/secret.txt"

  # The profile under test, extracted from the runner itself.
  PROFILE="$SANDBOX/verify.sb"
  awk '/^\(version 1\)$/,/^SBEOF$/' "$REPO_ROOT/scripts/review.sh" \
    | grep -v '^SBEOF$' > "$PROFILE"
  [ -s "$PROFILE" ] || fail "could not extract the profile from scripts/review.sh"
}

# sb <command> — run confined; echoes "allowed" or "blocked".
sb() {
  if sandbox-exec -f "$PROFILE" -D WT="$WT" -D SCRATCH="$SCRATCH" \
       /bin/sh -c "$1" >/dev/null 2>&1; then
    echo allowed
  else
    echo blocked
  fi
}

# ── the profile must parse ─────────────────────────────────────────────────
# Without this, every denial assertion below passes on a corpse.

@test "verify-profile: the extracted profile parses and permits work" {
  [ "$(sb "test -f $WT/file.txt")" = allowed ]
}

# ── (allow file-read* (subpath "/bin" "/usr/bin" …)) ───────────────────────

@test "verify-profile: tool paths readable — and no wider than their subpaths" {
  [ "$(sb '/bin/test -x /bin/sh')" = allowed ]
  [ "$(sb '/usr/bin/grep -q worktree '"$WT"'/file.txt')" = allowed ]
  # /usr is not allowed; only named subpaths under it are.
  [ "$(sb 'cat /usr/local/etc/* 2>/dev/null || cat /etc/hosts')" = blocked ]
}

@test "verify-profile: exec is confined to the same tool paths" {
  # A binary outside the allowed subpaths must not execute, even though the
  # profile grants process-exec* generously within them.
  cp /bin/echo "$WT/echo-copy" 2>/dev/null || skip "cannot stage a binary"
  [ "$(sb "$WT/echo-copy hi")" = blocked ]
}

# ── (allow file-read-metadata) — global, and the one that needs watching ───

@test "verify-profile: metadata is global but never grants content" {
  # Preservation: metadata anywhere is what path resolution needs.
  [ "$(sb "test -e $OUTSIDE/secret.txt")" = allowed ]
  # Denial: the same path's content stays unreadable.
  [ "$(sb "cat $OUTSIDE/secret.txt")" = blocked ]
  [ "$(sb "grep -q SECRETVALUE $OUTSIDE/secret.txt")" = blocked ]
}

# ── (allow file-read* (subpath (param "WT"))) ──────────────────────────────

@test "verify-profile: the worktree is readable and not writable" {
  [ "$(sb "cat $WT/file.txt")" = allowed ]
  [ "$(sb "printf x >> $WT/file.txt")" = blocked ]
  [ "$(sb "rm -f $WT/file.txt")" = blocked ]
  [ "$(cat "$WT/file.txt")" = "worktree content" ]
}

# ── (allow file-read* file-write* (subpath (param "SCRATCH"))) ─────────────

@test "verify-profile: scratch is writable and does not extend past itself" {
  [ "$(sb "echo x > $SCRATCH/f")" = allowed ]
  [ "$(sb "printf x >> $OUTSIDE/secret.txt")" = blocked ]
  [ "$(cat "$OUTSIDE/secret.txt")" = "SECRETVALUE" ]
}

# ── (deny network*) — with its own preservation load ───────────────────────
#
# §7.3 requires a standalone preservation probe for no_network, because in the
# execution core it shares one with fs_confinement: "Ein Fehler in dieser
# Payload färbt daher beide Canaries rot … die beiden Fähigkeiten sind dadurch
# nicht unabhängig belegt." The probe is mandatory *before* the next profile
# change, which makes it a precondition of everything #233 leads to.
#
# Independence here means the preservation load touches no file the
# fs_confinement assertions depend on: pure computation through an interpreter,
# nothing read, nothing written.

@test "verify-profile: no_network preserves compute that touches no file" {
  [ "$(sb '/usr/bin/python3 -c "import sys; sys.exit(0 if sum(range(1000))==499500 else 1)"')" = allowed ]
}

@test "verify-profile: network reachability is unavailable — and why that is the weaker claim" {
  # The strong claim — "(deny network*) is what stops the connection" — cannot
  # be established inside this profile, and saying so is the point.
  #
  # Measured: /usr/bin/python3 runs, but `import socket` dies with
  # PermissionError, because the stdlib lives under /usr/lib and the profile
  # grants /usr/bin, /usr/libexec, /bin and CommandLineTools only. So a failed
  # connection attempt is indistinguishable from a tool that could not load —
  # the same shape as docs/operator-lessons.md's "a search that skips a file
  # reports the same thing as a search that finds nothing".
  #
  # An earlier revision of this file asserted `exit != 0` for a socket connect
  # and for getaddrinfo. Both passed, and both passed on the import failure,
  # not on the network rule. They are removed rather than left looking strong.
  #
  # What is honestly assertable is the conjunction: nothing in this confinement
  # reaches the network, whether because the rule denies it or because no tool
  # can get far enough to try. For a verification command that is the property
  # that matters; for the `no_network` capability of the execution core it is
  # not, and that capability is claimed by a backend with its own canary
  # (core/canaries/no_network.py), not by this profile.
  [ "$(sb '/usr/bin/python3 -c "import socket"')" = blocked ]
  if command -v curl >/dev/null; then
    [ "$(sb 'curl -s --max-time 5 https://api.github.com')" = blocked ]
  fi
}

# ── the fs_confinement must-hold list, run against this profile ────────────
#
# core/canaries/fs_confinement.py names these for the execution-core backend.
# The review runner is a second confinement with a different threat model, and
# holding it to the same list is the differential check that a single
# implementation cannot provide.

@test "verify-profile: fs_confinement must-hold list" {
  [ "$(sb 'cat ~/.config/secrets/env')" = blocked ]
  [ "$(sb 'ls ~/')" = blocked ]
  [ "$(sb 'ls /Library/Keychains')" = blocked ]
  [ "$(sb 'ls /private/tmp')" = blocked ]
}
