#!/usr/bin/env python3
"""Order validator — Execution Core S2.

Pure, deterministic, no shell, no network, no clock, no randomness.
Reads exactly two files: the order file (argv[1]) and core/policy.json.

Usage:
    python3 -m core.orders.validate <order-file>

Exit 0 — admissible, silent stderr.
Exit 1 — refused, first stderr line is the bare reason code.
"""

import json
import os
import re
import sys

# ── Constants ────────────────────────────────────────────────────────────────

SIZE_LIMIT = 65536
DEPTH_LIMIT = 8

UUID_RE = re.compile(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
)
SHA40_RE = re.compile(r'^[0-9a-f]{40}$')
SHA256_DIGEST_RE = re.compile(r'^sha256:[0-9a-f]{64}$')
DATETIME_RE = re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$')

BUILDER_NAMES = ('jcode', 'deepseek', 'builder', 'worker')
BUNDLE_PREFIX = '/usr/local/var/jcode-runs/bundles/'

TOP_LEVEL_FIELDS = {
    'schema', 'run_id', 'issue', 'base_sha', 'intent',
    'required_capabilities', 'limit_reductions', 'acceptance_bundle',
}
BUNDLE_FIELDS = {'digest', 'location', 'author', 'approved_by', 'created_at'}

# ── Policy loading ───────────────────────────────────────────────────────────

_POLICY_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    'policy.json',
)


def _load_policy():
    """Load core/policy.json.  Returns the parsed dict."""
    with open(_POLICY_PATH) as f:
        return json.load(f)


# ── Refusal ──────────────────────────────────────────────────────────────────


def _refuse(code, explanation):
    """Print refusal and exit 1.  First line is the code alone."""
    print(code, file=sys.stderr)
    print(explanation, file=sys.stderr)
    sys.exit(1)


# ── Depth pre‑scan ───────────────────────────────────────────────────────────


def _check_depth(text):
    """Return True iff the JSON text has nesting depth <= DEPTH_LIMIT.

    Counts braces and brackets, skipping the interior of strings.
    Escaped characters inside strings are handled correctly.
    """
    depth = 0
    in_string = False
    escape = False
    for ch in text:
        if escape:
            escape = False
            continue
        if ch == '\\' and in_string:
            escape = True
            continue
        if ch == '"':
            in_string = not in_string
            continue
        if in_string:
            continue
        if ch in '{[':
            depth += 1
            if depth > DEPTH_LIMIT:
                return False
        elif ch in '}]':
            depth -= 1
    return True


# ── Canonical JSON parser ────────────────────────────────────────────────────


def _parse_canonical(text):
    """Parse *text* as canonical JSON.

    Rejects:
      - empty input
      - nesting deeper than DEPTH_LIMIT
      - duplicate object keys (via object_pairs_hook)
      - NaN / Infinity (via parse_constant)
      - trailing data after the top-level document
      - a non‑object root

    Returns the parsed dict on success; calls _refuse and exits on failure.
    """
    if not text.strip():
        _refuse('E_JSON', 'Empty input is not valid JSON')

    if not _check_depth(text):
        _refuse('E_JSON',
                f'Nesting depth exceeds the limit of {DEPTH_LIMIT}')

    def object_pairs_hook(pairs):
        seen = set()
        for key, _value in pairs:
            if key in seen:
                _refuse('E_JSON', f'Duplicate object key: {key!r}')
            seen.add(key)
        return dict(pairs)

    def parse_constant(c):
        if c in ('NaN', 'Infinity', '-Infinity'):
            _refuse('E_JSON', f'{c} is not valid canonical JSON')
        # json module never calls parse_constant for anything else.
        _refuse('E_JSON', f'Unexpected constant: {c}')

    decoder = json.JSONDecoder(
        object_pairs_hook=object_pairs_hook,
        parse_constant=parse_constant,
    )

    try:
        obj, idx = decoder.raw_decode(text)
    except json.JSONDecodeError as exc:
        _refuse('E_JSON', f'Invalid JSON: {exc}')

    # Trailing data after the document
    remaining = text[idx:].strip()
    if remaining:
        _refuse('E_JSON', 'Trailing data after the JSON document')

    if not isinstance(obj, dict):
        _refuse('E_JSON',
                f'Root must be a JSON object, got {type(obj).__name__}')

    return obj


# ── Schema validation ────────────────────────────────────────────────────────


def _validate_schema(order, policy):
    """Validate *order* against the fixed order schema v1.

    Checks field presence, types, formats, and the capability enum.
    Calls _refuse(E_SCHEMA, …) on failure.
    """

    # ── Unknown top‑level fields ────────────────────────────────────────
    unknown = set(order.keys()) - TOP_LEVEL_FIELDS
    if unknown:
        _refuse('E_SCHEMA',
                'Unknown top-level field(s): ' + ', '.join(sorted(unknown)))

    # ── Required fields ─────────────────────────────────────────────────
    for field in ('schema', 'run_id', 'issue', 'base_sha', 'intent',
                  'required_capabilities', 'acceptance_bundle'):
        if field not in order:
            _refuse('E_SCHEMA', f'Missing required field: {field!r}')

    # ── schema ──────────────────────────────────────────────────────────
    if order['schema'] != 'execution-core/order/v1':
        _refuse('E_SCHEMA',
                f'Unknown schema version: {order["schema"]!r}')

    # ── run_id ──────────────────────────────────────────────────────────
    if (not isinstance(order['run_id'], str)
            or not UUID_RE.match(order['run_id'])):
        _refuse('E_SCHEMA',
                f'run_id must be an RFC 4122 lowercase UUID, '
                f'got {order["run_id"]!r}')

    # ── issue ───────────────────────────────────────────────────────────
    if not isinstance(order['issue'], int) or isinstance(order['issue'], bool):
        _refuse('E_SCHEMA',
                f'issue must be an integer, got {type(order["issue"]).__name__}')
    if order['issue'] < 1:
        _refuse('E_SCHEMA',
                f'issue must be >= 1, got {order["issue"]}')

    # ── base_sha ────────────────────────────────────────────────────────
    if (not isinstance(order['base_sha'], str)
            or not SHA40_RE.match(order['base_sha'])):
        _refuse('E_SCHEMA',
                f'base_sha must be exactly 40 lowercase hex characters, '
                f'got {order["base_sha"]!r}')

    # ── intent ──────────────────────────────────────────────────────────
    if not isinstance(order['intent'], str):
        _refuse('E_SCHEMA',
                f'intent must be a string, got {type(order["intent"]).__name__}')
    if not (1 <= len(order['intent']) <= 200):
        _refuse('E_SCHEMA',
                f'intent must be 1–200 characters, got {len(order["intent"])}')
    for i, ch in enumerate(order['intent']):
        if '\x00' <= ch <= '\x1f':
            _refuse('E_SCHEMA',
                    f'intent contains control character U+{ord(ch):04X} '
                    f'at position {i}')

    # ── required_capabilities ───────────────────────────────────────────
    caps = order['required_capabilities']
    if not isinstance(caps, list) or len(caps) == 0:
        _refuse('E_SCHEMA',
                'required_capabilities must be a non-empty array')

    # Item types BEFORE the duplicate check. set() over the raw list raised
    # TypeError on an unhashable item — a nested array — and the traceback
    # became the first line of stderr where the reason code belongs. Exit 1
    # was still fail-closed, but a caller reading line one for the code got a
    # stack frame. Vector 34 pins this order of operations.
    for cap in caps:
        if not isinstance(cap, str):
            _refuse('E_SCHEMA',
                    f'Each capability must be a string, '
                    f'got {type(cap).__name__}')

    if len(set(caps)) != len(caps):
        _refuse('E_SCHEMA',
                'required_capabilities contains duplicate items')

    # Build capability enum from policy at runtime
    claimed = set(policy.get('claimed_capabilities', []))
    unclaimable_keys = set(policy.get('unclaimable_capabilities', {}).keys())
    all_cap_names = claimed | unclaimable_keys

    for cap in caps:
        if cap not in all_cap_names:
            _refuse('E_SCHEMA',
                    f'Capability {cap!r} is not present in the policy '
                    f'(neither claimed nor unclaimable) — an invention')

    # ── limit_reductions (optional) ─────────────────────────────────────
    if 'limit_reductions' in order:
        lr = order['limit_reductions']
        if not isinstance(lr, dict):
            _refuse('E_SCHEMA',
                    'limit_reductions must be an object')
        policy_limits = policy.get('limits', {})
        for key, val in lr.items():
            if key not in policy_limits:
                _refuse('E_SCHEMA',
                        f'Unknown limit key in limit_reductions: {key!r}')
            if not isinstance(val, int) or isinstance(val, bool):
                _refuse('E_SCHEMA',
                        f'limit_reductions.{key} must be an integer, '
                        f'got {type(val).__name__}')
            if val < 0:
                _refuse('E_SCHEMA',
                        f'limit_reductions.{key} must be >= 0, got {val}')

    # ── acceptance_bundle ───────────────────────────────────────────────
    bundle = order['acceptance_bundle']
    if not isinstance(bundle, dict):
        _refuse('E_SCHEMA',
                'acceptance_bundle must be an object')

    unknown_bundle = set(bundle.keys()) - BUNDLE_FIELDS
    if unknown_bundle:
        _refuse('E_SCHEMA',
                'Unknown field(s) in acceptance_bundle: '
                + ', '.join(sorted(unknown_bundle)))

    for field in sorted(BUNDLE_FIELDS):
        if field not in bundle:
            _refuse('E_SCHEMA',
                    f'Missing required field in acceptance_bundle: {field!r}')

    # digest
    if (not isinstance(bundle['digest'], str)
            or not SHA256_DIGEST_RE.match(bundle['digest'])):
        _refuse('E_SCHEMA',
                'acceptance_bundle.digest must be sha256: followed by '
                '64 lowercase hex characters')

    # location — type only; provenance checks below
    if not isinstance(bundle['location'], str):
        _refuse('E_SCHEMA',
                'acceptance_bundle.location must be a string')

    # author
    if (not isinstance(bundle['author'], str)
            or not (1 <= len(bundle['author']) <= 64)):
        _refuse('E_SCHEMA',
                'acceptance_bundle.author must be 1–64 characters')
    for i, ch in enumerate(bundle['author']):
        if '\x00' <= ch <= '\x1f':
            _refuse('E_SCHEMA',
                    f'acceptance_bundle.author contains control character '
                    f'U+{ord(ch):04X} at position {i}')

    # approved_by
    if (not isinstance(bundle['approved_by'], str)
            or not (1 <= len(bundle['approved_by']) <= 64)):
        _refuse('E_SCHEMA',
                'acceptance_bundle.approved_by must be 1–64 characters')
    for i, ch in enumerate(bundle['approved_by']):
        if '\x00' <= ch <= '\x1f':
            _refuse('E_SCHEMA',
                    f'acceptance_bundle.approved_by contains control '
                    f'character U+{ord(ch):04X} at position {i}')

    # created_at
    if (not isinstance(bundle['created_at'], str)
            or not DATETIME_RE.match(bundle['created_at'])):
        _refuse('E_SCHEMA',
                'acceptance_bundle.created_at must be in '
                'YYYY-MM-DDTHH:MM:SSZ format')


# ── Capability check ─────────────────────────────────────────────────────────


def _validate_capabilities(order, policy):
    """Refuse any required capability the backend does not claim.

    Capabilities that do not exist in the policy at all are schema failures
    and have already been caught by _validate_schema.  Here we only check
    capabilities that *are* in the policy but not in claimed_capabilities.
    """
    claimed = set(policy.get('claimed_capabilities', []))
    backend = policy.get('backend', 'unknown')
    unclaimable = policy.get('unclaimable_capabilities', {})

    for cap in order['required_capabilities']:
        if cap not in claimed:
            reason = unclaimable.get(
                cap, 'not listed in claimed_capabilities'
            )
            _refuse(
                'E_CAPABILITY_UNPROVEN',
                f"Capability {cap!r} is not available on backend "
                f"{backend!r}.\n"
                f"  Policy field 'unclaimable_capabilities.{cap}': "
                f"{reason}\n"
                f"  To grant this capability, change "
                f"'unclaimable_capabilities' in\n"
                f"  {_POLICY_PATH} and ensure the corresponding canary "
                f"passes.",
            )


# ── Limit check ──────────────────────────────────────────────────────────────


def _validate_limits(order, policy):
    """Refuse reductions that would leave a non-positive effective limit."""
    if 'limit_reductions' not in order:
        return
    policy_limits = policy.get('limits', {})
    for key, reduction in order['limit_reductions'].items():
        effective = policy_limits[key] - reduction
        if effective <= 0:
            _refuse(
                'E_LIMIT',
                f'limit_reductions.{key}={reduction} would reduce the '
                f'policy limit of {policy_limits[key]} to {effective}, '
                f'which is non‑positive',
            )


# ── Bundle provenance ────────────────────────────────────────────────────────


def _validate_bundle_provenance(order):
    """Check bundle provenance rules (ADR §10, CONTRACT.md §5).

    Three checks the validator can decide from the order alone:
      1. location must start with the required absolute prefix
         (and must not contain path traversal).
      2. location must not contain '..' segments.
      3. author must not match a builder identity (case‑insensitive
         substring).
    """
    bundle = order['acceptance_bundle']
    location = bundle['location']

    if not location.startswith(BUNDLE_PREFIX):
        _refuse(
            'E_BUNDLE_PROVENANCE',
            f'acceptance_bundle.location must start with '
            f'{BUNDLE_PREFIX!r}, got {location!r}',
        )

    # Path‑traversal check — a prefix match alone passes "../" escapes.
    segments = location.split('/')
    if '..' in segments:
        _refuse(
            'E_BUNDLE_PROVENANCE',
            f'acceptance_bundle.location contains path traversal: '
            f'{location!r}',
        )

    # Author identity check
    author_lower = bundle['author'].lower()
    for name in BUILDER_NAMES:
        if name in author_lower:
            _refuse(
                'E_BUNDLE_PROVENANCE',
                f'acceptance_bundle.author {bundle["author"]!r} matches '
                f'a builder identity ({name!r} — case‑insensitive '
                f'substring match).  The acceptance bundle must not be '
                f'authored by the builder under test (ADR §10).',
            )


# ── Main entry ───────────────────────────────────────────────────────────────


def validate(order_path):
    """Run the full validation pipeline on *order_path*.

    Checks are ordered per CONTRACT.md §2 (earlier row wins):
      1. E_SIZE  — byte limit
      2. E_JSON  — canonical parse
      3. E_SCHEMA — schema conformance
      4. E_CAPABILITY_UNPROVEN — unclaimed capability
      5. E_LIMIT — non‑positive effective limit
      6. E_BUNDLE_PROVENANCE — bundle provenance
    """

    # 1. Read raw bytes ──────────────────────────────────────────────────
    try:
        with open(order_path, 'rb') as f:
            raw = f.read()
    except FileNotFoundError:
        _refuse('E_SIZE', f'File not found: {order_path}')
    except OSError as exc:
        _refuse('E_SIZE', f'Cannot read file: {exc}')

    # 2. Size check (before the parser sees a byte) ──────────────────────
    if len(raw) > SIZE_LIMIT:
        _refuse('E_SIZE',
                f'File size {len(raw)} exceeds the limit of {SIZE_LIMIT} '
                f'bytes')

    # 3. Decode ──────────────────────────────────────────────────────────
    try:
        text = raw.decode('utf-8')
    except UnicodeDecodeError:
        _refuse('E_JSON', 'File is not valid UTF‑8')

    # 4. Parse canonical JSON ────────────────────────────────────────────
    order = _parse_canonical(text)

    # 5. Schema ──────────────────────────────────────────────────────────
    policy = _load_policy()
    _validate_schema(order, policy)

    # 6. Capabilities ────────────────────────────────────────────────────
    _validate_capabilities(order, policy)

    # 7. Limits ──────────────────────────────────────────────────────────
    _validate_limits(order, policy)

    # 8. Bundle provenance ───────────────────────────────────────────────
    _validate_bundle_provenance(order)

    # Admissible — silent exit 0
    sys.exit(0)


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if len(argv) != 1:
        print('Usage: python3 -m core.orders.validate <order-file>',
              file=sys.stderr)
        sys.exit(1)
    validate(argv[0])


if __name__ == '__main__':
    main()
