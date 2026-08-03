#!/usr/bin/env bats
# gate-fixpoint-isolation.bats — the reproduce fixpoint must not touch the
# source worktree (issue #176).
#
# gate.sh phase 4 used to run the reproduce scripts in the source checkout.
# A failed reproduce overwrote STATE.md, the digest, and
# claims/evidence/findings there; the gate detected the damage with
# tree_snapshot/tree_diff but could not restore what it had overwritten. The
# fix runs the work in a disposable git worktree at HEAD.
#
# These tests drive the REAL gate.sh --full end to end inside a disposable
# fixture repository whose HEAD carries deterministic stand-in reproduce
# scripts. The fixture is the gate's source worktree; the worktree the gate
# creates is where the damage would have happened. Nothing here reaches the
# network and the real suite is never invoked (the fixture has its own
# stand-in suite runner), so each run is fast and offline.
#
# ── Recursion guard ────────────────────────────────────────────────────
# The gate refuses to run from inside a bats test unless RECON_GATE_SELFTEST
# is set, and the fixture's stand-in suite runner keeps phase 3 from
# recursing into the real suite. The tests unset BATS_TEST_FILENAME when
# invoking the gate so the guard sees a normal invocation.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  # Each test gets its own sandbox; concurrent suite workers cannot collide.
  SANDBOX="$(cd "$BATS_TEST_TMPDIR" && pwd)"
}

teardown() {
  # Safety net: kill any background gate the tests may have left behind.
  for pid in $(jobs -pr); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}

# install_fake <dir> <name> <body-file> — a stand-in reproduce script.
# body-file holds the script's commands; the shebang and chmod are added here
# so every fake is executable and uniform.
install_fake() {
  local dir="$1" name="$2" body="$3"
  { printf '#!/usr/bin/env bash\n'; cat "$body"; } > "$dir/scripts/$name"
  chmod +x "$dir/scripts/$name"
}

# fake_noop <body-file> — the no-op stand-in used where a step must change
# nothing (node census, consumption, and any composer not under test).
fake_noop() {
  printf '#!/usr/bin/env bash\ntrue\n' > "$1"
}

# build_fixture <dir> <mode> — a disposable repository that looks like a
# federation-recon checkout: the real gate.sh, the real tree-state.sh, and a
# stand-in for every other gate dependency. <mode> selects the behavior of the
# stand-in reproduce scripts:
#   pass         — run1 == run2 == committed fixpoint
#   nondetermin  — run1 != run2
#   nonfixpoint  — both runs differ from the committed state
#   slow         — the first reproduce step writes a marker and sleeps
build_fixture() {
  local dir="$1" mode="$2"
  mkdir -p "$dir/scripts/lib" "$dir/scripts/test" "$dir/claims" "$dir/evidence"

  cp "$REPO_ROOT/scripts/gate.sh" "$dir/scripts/gate.sh"
  cp "$REPO_ROOT/scripts/lib/tree-state.sh" "$dir/scripts/lib/tree-state.sh"

  # The gate sources scripts/lib/test-runner.sh. The fixture has no real
  # suite, and the real one would recurse into this very file, so the fixture
  # carries a stand-in that reports one passing test — while still exercising
  # phase 3's own tree-diff check.
  cat > "$dir/scripts/lib/test-runner.sh" <<'EOF'
# Stand-in suite runner for the gate fixture: one passing test, no recursion.
run_suite() {
  printf 'ok 1 - fixture suite\n' > "$1"
  return 0
}
EOF

  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/validate-artifacts.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/scripts/ci-checks.sh"
  chmod +x "$dir/scripts/validate-artifacts.sh" "$dir/scripts/ci-checks.sh"

  # Committed artifact state the fixpoint must reproduce.
  printf 'fixture-state-v1\n' > "$dir/STATE.md"
  printf 'fixture-claim-v1\n' > "$dir/claims/fixture-claim.json"
  printf 'fixture-evidence-v1\n' > "$dir/evidence/fixture-evidence.json"

  case "$mode" in
    pass)
      # Every step rewrites the committed artifact state identically, so
      # before == run1 == run2 and the source tree is untouched.
      cat > "$SANDBOX/body-recon" <<'EOF'
printf 'fixture-state-v1\n' > STATE.md
mkdir -p claims
printf 'fixture-claim-v1\n' > claims/fixture-claim.json
EOF
      install_fake "$dir" recon-run.sh "$SANDBOX/body-recon"
      fake_noop "$SANDBOX/body-node"
      install_fake "$dir" node-census-run.sh "$SANDBOX/body-node"
      fake_noop "$SANDBOX/body-consumption"
      install_fake "$dir" consumption-run.sh "$SANDBOX/body-consumption"
      cat > "$SANDBOX/body-compose" <<'EOF'
printf 'fixture-state-v1\n' > STATE.md
EOF
      install_fake "$dir" compose-digest.sh "$SANDBOX/body-compose"
      ;;
    nondetermin)
      # Every invocation rewrites STATE.md with a fresh value: run1 != run2.
      cat > "$SANDBOX/body-recon" <<'EOF'
printf 'fixture-state-%s-%s\n' "$RANDOM" "$RANDOM" > STATE.md
EOF
      install_fake "$dir" recon-run.sh "$SANDBOX/body-recon"
      fake_noop "$SANDBOX/body-node"
      install_fake "$dir" node-census-run.sh "$SANDBOX/body-node"
      fake_noop "$SANDBOX/body-consumption"
      install_fake "$dir" consumption-run.sh "$SANDBOX/body-consumption"
      fake_noop "$SANDBOX/body-compose"
      install_fake "$dir" compose-digest.sh "$SANDBOX/body-compose"
      ;;
    nonfixpoint)
      # Every run writes a different artifact state than what is committed.
      cat > "$SANDBOX/body-recon" <<'EOF'
printf 'fixture-state-v2\n' > STATE.md
mkdir -p claims
printf 'fixture-claim-v2\n' > claims/fixture-claim.json
EOF
      install_fake "$dir" recon-run.sh "$SANDBOX/body-recon"
      fake_noop "$SANDBOX/body-node"
      install_fake "$dir" node-census-run.sh "$SANDBOX/body-node"
      fake_noop "$SANDBOX/body-consumption"
      install_fake "$dir" consumption-run.sh "$SANDBOX/body-consumption"
      fake_noop "$SANDBOX/body-compose"
      install_fake "$dir" compose-digest.sh "$SANDBOX/body-compose"
      ;;
    slow)
      # The first step marks that run() has started, then hangs so the test
      # can interrupt the gate mid-reproduce.
      cat > "$SANDBOX/body-recon" <<'EOF'
printf 'fixture-state-v1\n' > STATE.md
printf 'started\n' > marker.txt
sleep 600
EOF
      install_fake "$dir" recon-run.sh "$SANDBOX/body-recon"
      cat > "$SANDBOX/body-node" <<'EOF'
sleep 600
EOF
      install_fake "$dir" node-census-run.sh "$SANDBOX/body-node"
      fake_noop "$SANDBOX/body-consumption"
      install_fake "$dir" consumption-run.sh "$SANDBOX/body-consumption"
      fake_noop "$SANDBOX/body-compose"
      install_fake "$dir" compose-digest.sh "$SANDBOX/body-compose"
      ;;
    *) false "unknown fixture mode: $mode" ;;
  esac
  rm -f "$SANDBOX"/body-*

  git -C "$dir" init -q
  git -C "$dir" config user.email "gate-fixture@test"
  git -C "$dir" config user.name "Gate Fixture"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "fixture"
}

# run_gate <fixture> — invoke the fixture's real gate.sh --full as a normal
# process: BATS_TEST_FILENAME unset (the gate refuses to run from inside a
# bats test), TMPDIR redirected so every LOGDIR and worktree the gate creates
# lands inside the test sandbox, CWD anywhere (gate.sh cd's to its own root).
run_gate() {
  local dir="$1"
  env -u BATS_TEST_FILENAME TMPDIR="$SANDBOX/tmp" bash "$dir/scripts/gate.sh" --full
}

# assert_no_leaked_worktree <fixture> <tmpdir>
# The disposable worktree must leave no registration in git and no directory
# on disk. <tmpdir> is the sandbox TMPDIR the gate was run with.
assert_no_leaked_worktree() {
  local dir="$1" tmp="$2"
  run git -C "$dir" worktree list --porcelain
  [[ "$output" != *"gate-reproduce"* ]] || {
    echo "a gate-reproduce worktree is still registered:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
  run find "$tmp" -maxdepth 1 -type d -name 'gate-reproduce.*'
  [ -z "$output" ] || {
    echo "a gate-reproduce directory was left behind:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
}

# assert_diagnostic_logs <fixture-output> <tmpdir>
# A failed run must leave per-step logs at an explicit path that the gate
# prints. <fixture-output> is the captured gate output.
assert_diagnostic_logs() {
  local output="$1" tmp="$2" logdir
  [[ "$output" == *"reproduce evidence"* ]] || {
    echo "gate output does not name the reproduce evidence path"
    false
  }
  logdir="$(find "$tmp" -maxdepth 1 -type d -name 'gate.*' ! -name 'gate-reproduce.*' | head -1)"
  [ -n "$logdir" ] || {
    echo "no gate log dir under $tmp"
    false
  }
  [ -f "$logdir/reproduce-recon.log" ]
  [ -f "$logdir/reproduce-census.log" ]
  [ -f "$logdir/reproduce-consumption.log" ]
  [ -f "$logdir/reproduce-digest.log" ]
  [ -f "$logdir/reproduce-hashes.txt" ]
}

@test "gate-fixpoint: pass — source tree clean after reproduce, worktree removed" {
  local dir="$SANDBOX/repo" tmp="$SANDBOX/tmp"
  mkdir -p "$tmp"
  build_fixture "$dir" pass

  run run_gate "$dir"
  [ "$status" -eq 0 ] || {
    echo "gate exited $status — output:"
    printf '%s\n' "$output" | tail -20 | sed 's/^/  /'
    false
  }
  [[ "$output" == *"committed == run1 == run2, tree clean"* ]]
  [[ "$output" == *"GATE: PASS"* ]]

  # The source worktree is exactly the committed state.
  run git -C "$dir" status --porcelain
  [ -z "$output" ] || {
    echo "source worktree is dirty after a passing gate:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
  assert_no_leaked_worktree "$dir" "$tmp"
}

@test "gate-fixpoint: nondeterministic reproduce fails without touching the source" {
  local dir="$SANDBOX/repo" tmp="$SANDBOX/tmp"
  mkdir -p "$tmp"
  build_fixture "$dir" nondetermin

  run run_gate "$dir"
  local gate_output="$output"
  [ "$status" -ne 0 ]
  [[ "$gate_output" == *"not deterministic"* ]]

  # The source is untouched: before the gate and after, the only diff against
  # HEAD is nothing at all.
  run git -C "$dir" status --porcelain
  [ -z "$output" ] || {
    echo "the reproduce run dirtied the source worktree:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
  assert_no_leaked_worktree "$dir" "$tmp"
  assert_diagnostic_logs "$gate_output" "$tmp"
}

@test "gate-fixpoint: non-fixpoint reproduce fails without touching the source" {
  local dir="$SANDBOX/repo" tmp="$SANDBOX/tmp"
  mkdir -p "$tmp"
  build_fixture "$dir" nonfixpoint

  run run_gate "$dir"
  local gate_output="$output"
  [ "$status" -ne 0 ]
  [[ "$gate_output" == *"committed artifacts are not the fixpoint"* ]]

  run git -C "$dir" status --porcelain
  [ -z "$output" ] || {
    echo "the reproduce run dirtied the source worktree:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
  assert_no_leaked_worktree "$dir" "$tmp"
  assert_diagnostic_logs "$gate_output" "$tmp"
}

@test "gate-fixpoint: unrelated uncommitted changes survive the gate" {
  local dir="$SANDBOX/repo" tmp="$SANDBOX/tmp"
  mkdir -p "$tmp"
  build_fixture "$dir" pass

  # User dirt: a tracked file modified and an untracked file added.
  printf 'tracked content\n' > "$dir/notes.txt"
  git -C "$dir" add notes.txt
  git -C "$dir" commit -qm "add notes"
  printf 'user change\n' >> "$dir/notes.txt"
  printf 'untracked\n' > "$dir/unrelated.txt"
  local before
  before="$(git -C "$dir" status --porcelain | sort)"
  [[ "$before" == *"M notes.txt"* ]] || false "precondition: notes.txt must be dirty"
  [[ "$before" == *"?? unrelated.txt"* ]] || false "precondition: unrelated.txt must be untracked"

  run run_gate "$dir"
  [ "$status" -eq 0 ] || {
    echo "gate exited $status — output:"
    printf '%s\n' "$output" | tail -20 | sed 's/^/  /'
    false
  }

  local after
  after="$(git -C "$dir" status --porcelain | sort)"
  [ "$before" = "$after" ] || {
    echo "the gate changed the working tree:"
    echo "before:"; printf '%s\n' "$before" | sed 's/^/  /'
    echo "after:";  printf '%s\n' "$after"  | sed 's/^/  /'
    false
  }
  grep -q "user change" "$dir/notes.txt"
  [ -f "$dir/unrelated.txt" ]
  assert_no_leaked_worktree "$dir" "$tmp"
}

@test "gate-fixpoint: SIGTERM removes the reproduce worktree and leaves the source clean" {
  local dir="$SANDBOX/repo" tmp="$SANDBOX/tmp"
  mkdir -p "$tmp"
  build_fixture "$dir" slow

  # Pre-existing user dirt: the interrupted gate must not disturb it either.
  printf 'user change\n' >> "$dir/STATE.md"

  env -u BATS_TEST_FILENAME TMPDIR="$tmp" bash "$dir/scripts/gate.sh" --full &
  local gate_pid=$!

  # Wait for the disposable worktree to appear and its first reproduce step
  # to have started (marker.txt is written by the stand-in recon-run.sh with
  # the worktree as CWD).
  # Resolve symlinks: macOS mktemp returns /var/folders/... but git worktree
  # list --porcelain resolves to /private/var/folders/...
  local main_resolved
  main_resolved="$(cd "$dir" && pwd -P)"
  local wt_path=""
  local i=0
  while [ "$i" -lt 600 ]; do
    wt_path="$(git -C "$dir" worktree list --porcelain 2>/dev/null | awk -v main="$main_resolved" '/^worktree / && $2 != main { print $2; exit }')"
    if [ -n "$wt_path" ] && [ -f "$wt_path/marker.txt" ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if [ -z "$wt_path" ] || [ ! -f "$wt_path/marker.txt" ]; then
    kill -TERM "$gate_pid" 2>/dev/null || true
    wait "$gate_pid" 2>/dev/null || true
    false "the reproduce worktree never appeared"
  fi

  kill -TERM "$gate_pid"
  wait "$gate_pid" 2>/dev/null || true

  # The gate's trap removes the worktree in the work subshell; the parent may
  # exit a moment earlier. Poll briefly before asserting so a loaded machine
  # does not turn a completed cleanup into a flake.
  local j=0
  while [ -e "$wt_path" ] && [ "$j" -lt 50 ]; do
    sleep 0.1
    j=$((j + 1))
  done

  # The disposable worktree is gone — no registration, no directory.
  assert_no_leaked_worktree "$dir" "$tmp"
  [ ! -e "$wt_path" ]

  # The source shows exactly the one pre-existing record and nothing else.
  run git -C "$dir" status --porcelain
  printf '%s\n' "$output" | grep -qx " M STATE.md" || {
    echo "expected exactly 'M STATE.md' after the interrupted gate, got:"
    printf '%s\n' "$output" | sed 's/^/  /'
    false
  }
  [ "$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')" = "1" ]
}
