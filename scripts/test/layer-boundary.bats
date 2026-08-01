#!/usr/bin/env bats
# layer-boundary.bats — core/ and the evidence layer must not import each other.
#
# The owner decided on 2026-08-01 (#148) that the execution layer stays in this
# repository rather than moving to its own, and that the boundary is enforced
# by a check instead of by a repository wall. This is that check.
#
# The measurement that made the decision cheap is the one this test freezes:
# at the time it was written, `core/` referenced nothing in the evidence layer
# and exactly one file outside `core/` referenced `core/` — and that file,
# scripts/gen-worker-limits.sh, generates core/worker_exec.sh and belongs to
# the execution layer by purpose. A boundary that holds today costs one test to
# keep; the same boundary rediscovered after S5 costs a refactor.
#
# ── What this establishes ──────────────────────────────────────────────────
#
# That neither layer can reach into the other by path. A sandbox escape in
# core/ cannot corrupt the artifacts whose reproducibility is the product
# (FR-CON-007), because nothing in core/ knows where they live.
#
# ── What it does NOT establish ─────────────────────────────────────────────
#
#   - Isolation at runtime. Both layers still run as the same user in the same
#     checkout. This is a coupling check, not a security boundary; the security
#     boundary is the sandbox (docs/execution-core-adr.md §7).
#   - That the evidence layer is safe from an escaped worker. An attacker with
#     the owner's uid does not need an import statement.
#   - Anything about dynamic reach: os.environ, a path assembled at runtime, a
#     subprocess invoking a script by a name built from parts. This greps for
#     literal paths, which is what a refactor written in good faith produces
#     and what a deliberate bypass would avoid.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
}

@test "layer-boundary: core/ and the evidence layer do not reference each other" {
  run python3 - "$REPO_ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]

# The evidence layer: the artifact tree the observatory produces, plus the
# procedures and the operator's decision layer. Named as directories, because
# that is what a path reference names.
EVIDENCE_DIRS = ('pins', 'evidence', 'findings', 'claims', 'digest',
                 'procedures', 'operator')

# Files that belong to the execution layer despite living under scripts/.
# gen-worker-limits.sh writes core/worker_exec.sh; the bats files test core/.
# Listing them is the honest form: the alternative is a rule that silently
# admits any future scripts/ file that mentions core/.
EXECUTION_LAYER_OUTSIDE_CORE = {
    'scripts/gen-worker-limits.sh',
    'scripts/test/launcher-order-gate.bats',
    'scripts/test/order-validator.bats',
    'scripts/test/order-vectors.bats',
    'scripts/test/seatbelt-unit.bats',
    'scripts/test/stray-processes.bats',
    'scripts/test/worker-limits.bats',
    'scripts/test/layer-boundary.bats',        # this file names both sides
}

CODE_EXT = ('.py', '.sh', '.bats', '.yml', '.yaml')

def code_files(start):
    for dirpath, dirnames, filenames in os.walk(start):
        dirnames[:] = [d for d in dirnames
                       if d not in ('.git', '__pycache__', '.runs', 'node_modules')]
        for fn in filenames:
            if fn.endswith(CODE_EXT):
                p = os.path.join(dirpath, fn)
                if not os.path.islink(p):
                    yield p

violations = []

# ── Direction 1: core/ must not reach into the evidence layer ──────────────
pattern_out = re.compile(r'\b(' + '|'.join(EVIDENCE_DIRS) + r')/')
for path in code_files(os.path.join(root, 'core')):
    rel = os.path.relpath(path, root)
    with open(path, encoding='utf-8', errors='replace') as f:
        for n, line in enumerate(f, 1):
            code = line.split('#', 1)[0]
            m = pattern_out.search(code)
            if m:
                violations.append(f'{rel}:{n}: core/ references {m.group(1)}/ — {line.strip()[:90]}')

# ── Direction 2: the evidence layer must not reach into core/ ──────────────
pattern_in = re.compile(r'\bcore/|from core\b|import core\b')
for d in EVIDENCE_DIRS + ('scripts',):
    start = os.path.join(root, d)
    if not os.path.isdir(start):
        continue
    for path in code_files(start):
        rel = os.path.relpath(path, root)
        if rel in EXECUTION_LAYER_OUTSIDE_CORE:
            continue
        with open(path, encoding='utf-8', errors='replace') as f:
            for n, line in enumerate(f, 1):
                code = line.split('#', 1)[0]
                if pattern_in.search(code):
                    violations.append(f'{rel}:{n}: the evidence layer references core/ — {line.strip()[:90]}')

# An empty walk and a clean tree produce the same empty list, and only one of
# them is evidence. Count what was actually examined.
examined = sum(1 for _ in code_files(os.path.join(root, 'core')))
if examined == 0:
    print('the walk found no files under core/ — the check did not run')
    sys.exit(2)

if violations:
    print(f'{len(violations)} boundary violation(s):')
    print('\n'.join('  ' + v for v in violations))
    sys.exit(1)

print(f'boundary clean: {examined} files under core/ examined, no crossing either way')
PY
  echo "$output"
  [ "$status" -eq 0 ]
}
