#!/usr/bin/env bash
# constitution.sh — Shared constitution observation functions.
#
# Source after helpers.sh. Provides:
#   constitution_file_hash <sha> <path>
#
# issue #45: Recon observes its own constitution via content hashing.
# Single source of truth — both recon-run.sh and constitution-observation.bats
# source this file so a test cannot pass when production breaks.

# Hash a constitutional file at the given git commit SHA.
# Uses git show to get the committed content, NOT the working tree.
# The hash is computed ONLY from the file content; no artifact is included.
constitution_file_hash() {
  local sha="$1" path="$2"
  # Try the pinned SHA first for determinism (FR-CON-012).
  # Fall back to HEAD if the pinned commit is not available locally
  # (e.g. during branch development or shallow clones).
  local content
  content=$(git show "${sha}:${path}" 2>/dev/null) || true
  if [ -z "$content" ]; then
    content=$(git show "HEAD:${path}" 2>/dev/null) || true
  fi
  if [ -z "$content" ]; then
    printf ''
    return
  fi
  printf '%s' "$content" | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())" 2>/dev/null
}
