#!/usr/bin/env bats
# order-vectors.bats — integrity of the S2 order-validation oracle.
#
# These tests do NOT run a validator. No validator exists yet, and that is
# deliberate: CONTRACT.md is written before the implementation so the party
# being graded cannot author the grade (#103).
#
# What can be established before an implementation exists is whether the
# oracle is intact — that every vector is accounted for, that the codes it
# expects are the codes the contract defines, and that no vector has quietly
# become harmless. A vector suite nobody checks is a suite that decays into
# agreement with whatever gets built.
#
# The suite that actually runs the vectors against the validator arrives with
# the implementation, in scripts/test/order-validator.bats, and is written by
# the same hand as these vectors rather than by the builder.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd -P)"
  VEC="$REPO_ROOT/core/orders/vectors"
}

# The closed set from CONTRACT.md §2, restated here on purpose. Two
# independent copies that must agree is the point: a code added to one and not
# the other is drift between what the contract promises and what is tested,
# and test 8 below is what notices.
CODES="E_SIZE E_JSON E_SCHEMA E_CAPABILITY_UNPROVEN E_LIMIT E_BUNDLE_PROVENANCE"

@test "order-vectors: manifest is canonical JSON with the expected shape" {
  run python3 -c "
import json,sys
m=json.load(open('$VEC/manifest.json'))
assert set(m) == {'note','reject','accept'}, sorted(m)
assert isinstance(m['reject'], dict) and m['reject']
assert isinstance(m['accept'], dict) and m['accept']
print(len(m['reject']), 'reject,', len(m['accept']), 'accept')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: every reject vector on disk is listed, and every listed one exists" {
  run python3 -c "
import json,os
m=json.load(open('$VEC/manifest.json'))
disk=set(os.listdir('$VEC/reject'))
listed=set(m['reject'])
assert disk==listed, ('on disk but unlisted: %s | listed but absent: %s'
                      % (sorted(disk-listed), sorted(listed-disk)))
print(len(disk),'reject vectors accounted for')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: every accept vector on disk is listed, and every listed one exists" {
  run python3 -c "
import json,os
m=json.load(open('$VEC/manifest.json'))
disk=set(os.listdir('$VEC/accept'))
listed=set(m['accept'])
assert disk==listed, ('on disk but unlisted: %s | listed but absent: %s'
                      % (sorted(disk-listed), sorted(listed-disk)))
print(len(disk),'accept vectors accounted for')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: every expected code is in the closed set" {
  run python3 -c "
import json
codes=set('$CODES'.split())
m=json.load(open('$VEC/manifest.json'))
bad={k:v['code'] for k,v in m['reject'].items() if v['code'] not in codes}
assert not bad, bad
print(len(codes),'codes, all in use below')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: no code in the contract is left unexercised" {
  # A code with no vector is a promise with no test behind it. If a future
  # change makes one genuinely unreachable, delete it from the contract —
  # do not leave it standing as an untested branch.
  run python3 -c "
import json
codes=set('$CODES'.split())
m=json.load(open('$VEC/manifest.json'))
used={v['code'] for v in m['reject'].values()}
assert codes<=used, 'no vector for: %s' % sorted(codes-used)
for c in sorted(used):
    print(' %-24s %d vector(s)' % (c, sum(1 for v in m['reject'].values() if v['code']==c)))
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: every accept vector is loadable JSON" {
  # An accept vector that does not parse can never be accepted, so it would
  # silently become a second reject vector and stop carrying the suite.
  run python3 -c "
import json,os
d='$VEC/accept'
for fn in sorted(os.listdir(d)):
    json.load(open(os.path.join(d,fn)))
print(len(os.listdir(d)),'accept vectors parse')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: no reject vector is byte-identical to an accept vector" {
  # The cheapest way to make a stubborn vector pass is to edit it until it is
  # the valid document. This notices the end state of that edit.
  run python3 -c "
import hashlib,os
def digests(sub):
    d={}
    for fn in os.listdir('$VEC/'+sub):
        d[hashlib.sha256(open('$VEC/'+sub+'/'+fn,'rb').read()).hexdigest()]=sub+'/'+fn
    return d
r,a=digests('reject'),digests('accept')
clash=[(r[h],a[h]) for h in set(r)&set(a)]
assert not clash, clash
print('no collisions across %d vectors' % (len(r)+len(a)))
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: every vector records why it exists" {
  # The code says what must happen. Only the prose says what would break if it
  # did not, and that is the half a later reader needs to judge whether the
  # vector is still right.
  run python3 -c "
import json
m=json.load(open('$VEC/manifest.json'))
thin=[k for s in ('reject','accept') for k,v in m[s].items()
      if len(v.get('why','').strip())<40]
assert not thin, thin
print('all vectors carry a rationale')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: the contract documents exactly the codes this suite enforces" {
  # CONTRACT.md §2 is the published table; CODES above is what the suite acts
  # on. Either can be edited alone, and then the repository says one thing and
  # does another.
  run python3 -c "
import re
codes=set('$CODES'.split())
txt=open('$REPO_ROOT/core/orders/CONTRACT.md').read()
table=txt.split('## 2. Reason codes')[1].split('##')[0]
documented=set(re.findall(r'\`(E_[A-Z_]+)\`', table))
assert documented==codes, ('documented not enforced: %s | enforced not documented: %s'
                           % (sorted(documented-codes), sorted(codes-documented)))
print(len(codes),'codes agree between CONTRACT.md and this suite')
"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "order-vectors: the oversize vector really is oversize" {
  # It is the one vector whose property is its byte count, so an edit that
  # shortens it turns it into a differently-named schema test without
  # anything failing.
  run python3 -c "
import os
n=os.path.getsize('$VEC/reject/01-oversize.json')
assert n>65536, n
print(n,'bytes > 65536 limit')
"
  echo "$output"
  [ "$status" -eq 0 ]
}
