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
# The hash is computed from the exact file bytes (sha256sum-compatible);
# the result can be verified with:  sha256sum CLAUDE.md
#
# Returns the hex hash on stdout, empty on failure.
# FR-CON-012: the SHA is a committed pin, never HEAD.  If the pinned commit
# does not contain the file, this function prints a diagnostic to stderr and
# returns empty.  There is no fallback — a missing file at the pinned commit
# must be a distinct, recorded outcome, never a hash of a different version.
# (operator-lessons.md: "a check that returns the right-looking answer for the
# wrong reason"; "|| true around a tool invocation makes 'tool missing'
# indistinguishable from 'found nothing'").
constitution_file_hash() {
  local sha="$1" path="$2"

  # Verify the pinned commit exists.
  if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    warn "constitution_file_hash: pinned commit ${sha} not available" >&2
    printf ''
    return
  fi

  # Verify the file exists at the pinned commit.
  if ! git cat-file -e "${sha}:${path}" 2>/dev/null; then
    warn "constitution_file_hash: ${path} absent at pinned commit ${sha}" >&2
    printf ''
    return
  fi

  # Hash the exact bytes.  Piped directly from git — no shell variable
  # interpolation, no trailing-newline stripping, no quoting ambiguity.
  git show "${sha}:${path}" 2>/dev/null \
    | python3 -c "import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())" 2>/dev/null
}
