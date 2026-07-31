<!-- provenance
requested_provider: openai
served_provider: openai
reviewer_claim: openai
model: gpt-5.6-sol
session: session_mouse_1785528404066_0f57a143f3cff2d8
consistency_check: read from the log by hand after scripts/consult.sh refused it
log: /Users/ss/.jcode/logs/jcode-2026-07-31.log
evidence: 526 log lines carry ses:session_mouse_178552, every one prv:OpenAI|mod:gpt, no other provider
-->

> **This review refused itself, and was right to.**
>
> `consult.sh` searched for a 24-character session prefix while the log writes
> 20, so it matched nothing and reported `no-log-activity`. The reviewer found
> that independently and made it the primary reason for rejection — its own
> dispatch, failing in the environment it was written for, while 413 tests
> stayed green.
>
> Attribution was established afterwards by hand and is checkable: 526 log
> lines carry this session, every one `prv:OpenAI|mod:gpt`, no other provider.
> The block above is a **consistency check, not a proof of independence** —
> see condition 3 of this report, which is why the field is no longer called
> `verified_by`.

# Independent red-team review, PR #137, round 2

## Verdict

**REJECT.** The most important result is not hypothetical: the revised control fails on this review, in the real environment it was written for. `consult.sh` takes the first 24 characters of the session id, while every real provider-tagged log record in the available logs carries a 20-character session tag. The exact production filter returns `no-log-activity` for this live session. The fixture tests use longer synthetic tags and therefore all pass.

That alone rejects the change. The rest is worse. I also executed a wrong-session acceptance through duplicate PID files, four gate omissions, a register overmatch, acceptance of a renamed quarantine with an embedded block, destruction of a refused body when quarantine writing fails, and a move path that exits 0 without producing the requested output file. The focused 30 tests and the full 413-test gate remain green with all of these defects present.

## Record reviewed

I read:

- `git log -1`, commit `8ee64a8462056f3f645ee252a588f570f863bb1c`
- all comments shown by `gh pr view 137 --comments`
- issue #135 and its correction comment
- `CLAUDE.md`, `docs/operator-lessons.md`, `governance/adversarial-review.md`, and `governance/reviewers.md`
- `scripts/consult.sh`
- `scripts/lib/consultation-provenance.sh`
- both provenance test files
- `governance/consultations/UNVERIFIED`
- the raw jcode logs for 2026-07-24 through 2026-07-31

The operator's reconstruction of round 1 is fair. I found no material round-1 finding that was inverted or omitted in the PR comment or commit message. The problem is not misrepresentation of my previous report. The problem is that several claimed fixes do not satisfy the reconstructed conditions.

## 1. Prior conditions, ruled on in substance and in letter

The original report was deleted, so these quotations are necessarily the operator's surviving wording. I have split the surviving findings into the conditions they imposed.

### Condition 1: bind attribution to this request, not to a time window

> "Attribution is bound to the session."
>
> "A run that cannot be bound to a session is refused rather than falling back to time."

**Letter: PARTLY SATISFIED.** The implementation no longer uses the time window to select provider records. It tries to find a session through the child PID, and an empty session is refused. There is no time-window fallback.

**Substance: NOT SATISFIED.** It does not reliably bind the output to this request.

First, it does not work in production. `served_provider` computes:

```bash
short="${session:0:24}"
grep -F "ses:$short" "$log"
```

The live session for this review is:

```text
session_mouse_1785528404066_0f57a143f3cff2d8
```

The script searches for:

```text
ses:session_mouse_1785528404
```

The real provider records contain:

```text
ses:session_mouse_178552|prv:OpenAI|mod:gpt
```

That tag is 20 characters, not 24. Across the available logs, 140,665 real provider-tagged records use 20-character session tags. The exact production filter returned `no-log-activity` for this session. The tests manufacture full or 24-character tags, so they test a log format the real tool does not emit.

Second, the PID directory is not a unique binding. `session_for_pid` returns the first glob-sorted file whose contents equal the child PID. It does not reject duplicates, validate freshness, validate the filename, compare process start time, or prove that the chosen file was created by the child.

**Executed, 4 seconds:** I ran the exact script with a synthetic `jcode` process that created two session files containing its PID. The lexicographically first session had an OpenAI-tagged log line. The other session represented the real DeepSeek-served request. `consult.sh` selected the decoy and exited 0 with:

```text
served_provider: openai
session: aaa_decoy_openai_session_full
```

The body explicitly came from the DeepSeek-labelled session. This is wrong-provider acceptance, not merely denial of service.

A stale PID file becomes the same attack after PID reuse. If the real pid file never appears, the wrapper waits the full 60 seconds even when the child has already exited, then refuses. If it appears after the fixed polling deadline, the run is refused. If two files name the PID, one silently wins. If two requests share a session, the log is session-scoped rather than request-scoped and their evidence is merged. The unused `mark` parameter does not constrain old records once a prefix matches.

### Condition 2: refusal must preserve the body outside consultation paths

> "A refused body is unattributable, which is not the same as worthless. It goes to `<output>.unattributed`."

**Letter: PARTLY SATISFIED.** On the ordinary tested refusal path, the body is written to `.unattributed`, the `.stdout` file is removed, and no `.md` consultation remains.

**Substance: NOT SATISFIED.** `quarantine_output` never checks whether writing the quarantine succeeded:

```bash
{ ... cat "${OUTPUT}.stdout"; } > "$q"
rm -f "${OUTPUT}.stdout"
echo "Body kept, unattributed: $q"
```

The script runs without `set -e`, so a failed redirection is followed by deletion of the only body and a false success message.

**Executed, under 1 second:** I made `<output>.unattributed` a directory. Redirection failed with `Is a directory`. The script then removed `<output>.stdout`, printed `Body kept`, and no file anywhere in the fixture contained the finding. This is the round-1 destruction defect on a different branch.

Repository search found no reader that directly consumes `.unattributed` files as consultations. That part is sound. A plain rename to `.md` normally fails the gate because it has neither provenance nor a register entry. However, the gate searches for a provenance opener anywhere in the file and does not reject the quarantine header.

**Executed, under 1 second:** a renamed quarantine beginning with `UNATTRIBUTED CONSULTATION OUTPUT - NOT A CONSULTATION`, but containing an embedded `<!-- provenance` block later in its body, passed as proven. A model response, prompt injection, or hand-written body can supply that block before quarantine. Renaming alone then converts the quarantine into accepted evidence.

### Condition 3: every consultation markdown file must be checked regardless of filename

> "Every `.md` is checked now."
>
> "The filename no longer decides whether the gate looks."

**Letter: NOT SATISFIED.** The implementation checks the one-time expansion of `"$dir"/*.md`. That is not every markdown file in the consultation tree.

**Substance: NOT SATISFIED.** I executed each of these fixtures and the gate exited 0 while reporting zero checked files:

- `sub/review.md`, because traversal is not recursive
- `.review.md`, because shell `*` does not match a leading dot without `dotglob`
- `review.MD`, because the extension match is case-sensitive
- a dangling `dangling.md` symlink, because `[[ -e "$f" ]]` is false

A symlink with a live target is followed, so the content being certified need not be stored at the consultation path. A dangling symlink is silently skipped. The policy must decide whether symlinks are forbidden or inspected. The current accidental split is not a policy.

The file set is also a snapshot. **Executed, 29 seconds:** I began a check over 1,200 valid files, then added unproven `late.md` while the loop was running. The check exited 0 with exactly 1,200 checked files. `late.md` existed and was never examined.

There is a second, more direct version of the old filename evasion. A neutral filename is now opened, but provider claims in its body are still ignored. If `137-independent-review.md` contains a DeepSeek provenance block and body text saying `Reviewer: Sol 5.6 (OpenAI)`, the gate sets `claimed=""` from the filename and accepts the file as proven. **Executed, under 1 second.** The gate now looks at the file, but still lets the filename decide whether the claimed reviewer is compared to the served provider.

### Condition 4: an UNVERIFIED entry must admit exactly the file it names, and comments must not be entries

> "Anchored, with comments stripped."

**Letter: SATISFIED only in the narrow wording.** Comment lines are removed and `grep -x` anchors the match.

**Substance: NOT SATISFIED.** The filename is passed to grep as a basic regular expression, not as a fixed string:

```bash
grep -v '^[[:space:]]*#' "$register" | grep -qx "$base"
```

**Executed, under 1 second:** the file was `attack.md`; the register contained `attackXmd`, which does not name that file. The dot in the filename pattern matched `X`, and the gate registered `attack.md` as unproven. A filename containing `.*`, brackets, anchors, or backslashes can match much more. The required operation is `grep -Fqx -- "$base"`, or preferably parsing the register once as literal records.

The comment exploit from round 1 is fixed. The exact-entry property is not.

### Condition 5: the test-only path must not forge accepted evidence

> "Using the test path stamps the artifact SELFTEST, and the gate rejects a SELFTEST block."

**Letter: SATISFIED.** The exact test path sets `SELFTEST=1`; the emitted `verified_by` line contains `SELFTEST`; the gate rejects that marker.

**Substance: SATISFIED within the operator's explicitly narrowed threat model.** An unedited artifact produced by `CONSULT_SKIP_RUN` and `CONSULT_TEST_SESSION` does not pass. I do not repeat the hand-editing objection as an unfixed version of this condition because the operator now explicitly says this is not a dishonest-operator control.

That concession does not rescue the broader gate. A hand-written block, an embedded block in a quarantined body, and a neutral filename with contradictory body attribution still pass. Those are separate failures in what the gate treats as proof.

### Condition 6: write and move failures must not print success or exit 0

> "Write, move and non-empty all checked."

**Letter: NOT SATISFIED.** The script checks the redirection status and the numeric status of `mv`, but it does not establish that the requested output path became a non-empty regular file. There are no regression tests for `could not write`, move failure, an output directory, or quarantine write failure. Searches for `could not write` and `move` in `consult-provenance.bats` returned no tests.

**Substance: NOT SATISFIED.** **Executed, under 1 second:** I made the requested output path an existing directory. `mv output.tmp output` succeeded by moving the tempfile inside the directory. `[ -s "$OUTPUT" ]` also succeeded because the directory had nonzero size. The script removed `.stdout`, printed verified success, and exited 0. The requested output was still a directory; the artifact existed only as `output/output.tmp`.

The final state must be checked with at least `[[ -f "$OUTPUT" && -s "$OUTPUT" ]]`, with output-directory rejection before writing. Quarantine writing must be checked before deleting `.stdout`.

### Condition 7: correct the factual usage figures using the provider-tagged signal

> "The strict session-tag signal inverts two of the entries."

**Letter: MOSTLY SATISFIED.** The old endpoint counts are identified as model-catalog probes, and the replacement table uses `prv:OpenAI|` records. Issue #135 carries the same correction.

**Substance: SATISFIED for completed days, NOT SATISFIED for 07-31 as published.** My independent counts are:

| day | endpoint count | `prv:OpenAI|` count |
|---|---:|---:|
| 07-24 | 13 | 9,738 |
| 07-25 | 0 | 42 |
| 07-26 | 8 | 8,279 |
| 07-27 | 66 | 0 |
| 07-28 | 0 | 0 |
| 07-30 | 0 | 562 |

Those match the correction exactly. The 07-30 split is also correct: 174 records at 12:00 and 388 at 13:00.

The `63 of 66` claim is correct. All 66 July 27 endpoint lines are `/v1/models` probes, and 63 have a nearby HTTP 401 record.

The two #127 windows are also correct:

- 08:07 through 08:40: 803 provider-tagged records, all `prv:OpenRouter|mod:deepseek`, zero OpenAI
- 10:01 through 10:15: 450 provider-tagged records, all `prv:OpenRouter|mod:deepseek`, zero OpenAI

The remaining problem is that 07-31 was still in progress. The 1,712nd OpenAI-tagged record occurred at 21:45:49 local time, immediately before the issue correction at 21:46. By the correction commit at 22:05:28, the count was already 1,764. During this review it passed 2,199 and continued growing. The table labels 1,712 as the day's "actual" without an as-of timestamp. It was a valid snapshot, not a per-day total. The correction is therefore historically accurate only if annotated `as of 21:45:49 +02:00`.

### Condition 8: do not use the audited tool's own assertion as independent proof

> "This reads the audited tool's own log. Evidence from outside jcode would be a different design."

**Letter: NOT SATISFIED.** The design was not replaced. The limitation was documented.

**Substance: NOT SATISFIED.** This is still the category error from round 1. A tool that can silently substitute a provider can also mislabel the provider, session, PID file, or log. The control asks the accused component to produce the evidence that acquits it. Stating that limit is honest, but honesty about a failed trust boundary does not make the boundary adequate for a claim of independent provider verification.

The script is useful as a consistency alarm. It can catch the observed bug when jcode's output and jcode's log disagree. It cannot establish provider independence. Documentation should call it defense in depth, not proof.

## 2. New-design attack results

### 2.1 Session binding

The live 24-versus-20 mismatch is the highest-priority finding. It means the mechanism fails safe but does not function. Question 2 of the review template asks whether it fires in its intended environment. It does not.

The duplicate-PID exploit shows it can also fail open under a spoofed or stale PID directory. Fixing 24 to 20 is insufficient because a truncated prefix is not a unique request identity. At minimum, the wrapper must reject zero or multiple PID-file matches, validate file freshness against process start, use an exact full session id from a structured record, and bind to a unique turn/request id rather than a session shared across work.

A real integration test must invoke real jcode and read the actual emitted tag. Fixtures that repeat a guessed truncation constant are precisely the "test duplicates what it guards" failure described in `docs/operator-lessons.md`.

### 2.2 Quarantine

No repository reader currently treats `.unattributed` as a consultation. Good.

The preservation guarantee is still false on write failure. The quarantine marker is not enforced by the gate after rename. The gate must reject the quarantine sentinel anywhere appropriate, require exactly one provenance block at the start of the file, and parse that block structurally. The quarantine writer must only remove `.stdout` after a checked, durable write and successful move into place.

### 2.3 Gate coverage

The current shell glob is not an inventory. Use an explicit inventory source. For committed evidence, `git ls-files -z -- governance/consultations` gives a stable, NUL-safe set and makes symlink policy inspectable. If the policy covers untracked working-tree files too, enumerate recursively with `find ... -print0`, reject symlinks or define their handling, and rescan or lock as needed. Define the accepted extension policy rather than silently treating `.MD`, `.markdown`, hidden files, and nested paths as outside scope.

Most importantly, stop deriving the claimed reviewer solely from filename tokens. Require one machine-readable reviewer/provider claim inside the single provenance record and compare requested, served, model, and reviewer identity there. A body may mention other models, so free-text parsing is not a sound substitute. The metadata has to carry the authoritative claim.

### 2.4 Register

Anchoring is not literal matching. Use fixed-string matching and validate the register grammar in the gate itself, not only in a Bats test over today's repository. A register record should be parsed as an exact path plus a nonempty reason.

### 2.5 Run the mechanism against itself

**Yes, this review was dispatched through `scripts/consult.sh`.** The live process chain is:

```text
bash scripts/consult.sh .../137-sol-round2.md .../review137r2.txt
  jcode run -p openai -m gpt-5.6-sol ...
```

PID 30157 is recorded in:

```text
~/.jcode/streaming_pids/session_mouse_1785528404066_0f57a143f3cff2d8
```

The full session metadata and provider-tagged records identify OpenAI/gpt-5.6-sol. However, the mechanism's own 24-character grep cannot see the real 20-character tag. Therefore `consult.sh` will classify this review as `no-log-activity`, refuse it, and quarantine its captured stdout. It will not produce a provenance-bearing `.md` artifact through its claimed path.

Before this report was added, `bash scripts/gate.sh` passed 413 tests because `.stdout` is outside the glob. The focused provenance suites passed 30 tests. Those green results coexist with the live self-failure and every executed evasion above.

A manually written provenance block would make the gate pass, because the gate does not authenticate `verified_by` or verify the cited log. That would not mean the mechanism passed against itself. It would demonstrate the acknowledged hand-writing bypass.

### 2.6 Factual claims

The completed-day replacement counts, the 63/66 catalog-probe claim, the 07-30 hourly split, and both #127 dispatch-window counts are true. The 07-31 figure needs an as-of timestamp and must not be presented as a completed per-day count.

### 2.7 Is this the right thing?

Not as the primary proof of independence.

The right architecture puts the oracle outside the component whose provider-selection behavior is being audited. Options include a direct provider endpoint whose response model and endpoint are recorded, a separate broker or wrapper that owns transport selection and emits an independently protected receipt, or OS/network observation captured by a process outside jcode. The exact mechanism depends on OAuth transport constraints, but the trust boundary does not: jcode cannot be both the subject and sole witness.

Keep the log check as defense in depth. It is cheap and it catches inconsistent failover. Do not let it mint the repository's assertion that an independent provider answered.

## 3. Tests and commands executed

- `bats scripts/test/consult-provenance.bats scripts/test/consultation-provenance.bats`: 30/30 pass
- `bash scripts/gate.sh`: pass, 413 tests, full reproduce skipped by the gate as network-dependent
- independent raw-log recount for every available day
- exact live-session production grep: `no-log-activity`
- duplicate PID-file wrong-session acceptance: accepted, exit 0
- nested markdown omission: gate exit 0
- hidden markdown omission: gate exit 0
- uppercase extension omission: gate exit 0
- dangling markdown symlink omission: gate exit 0
- file-created-during-run omission: gate exit 0, 1,200 old files checked, late file skipped
- regex register overmatch: gate exit 0
- neutral filename with contradictory Sol body claim: gate exit 0 as proven
- renamed quarantine with embedded provenance: gate exit 0 as proven
- failed quarantine write: body deleted, false `Body kept` message
- output path as directory: consult exit 0, no requested output file

## 4. Blocking conditions for another round

1. Add a real-environment integration test and make the current review dispatch succeed using the actual log format. Do not copy a truncation constant into fixtures.
2. Bind evidence to a unique request or turn, not a mutable PID-file prefix. Reject duplicate, stale, malformed, or ambiguous bindings.
3. Move the independence oracle outside jcode, or explicitly downgrade this mechanism to a non-authoritative consistency alarm and use an external method for the actual independence claim.
4. Make quarantine preservation transactional. Never delete `.stdout` until the quarantine is a verified nonempty regular file. Test the failure path.
5. Require the requested output to become a nonempty regular file at the exact path. Reject output directories and test write and move failures.
6. Replace the top-level shell glob with a defined complete inventory and an explicit symlink and extension policy. Cover hidden files, subdirectories, unusual extensions, and concurrent additions according to that policy.
7. Parse one provenance block at the start of the file. Reject quarantine sentinels, duplicate or embedded blocks, missing required fields, and metadata contradictions. Do not infer the authoritative reviewer claim only from filename tokens.
8. Match UNVERIFIED paths literally with a validated record grammar.
9. Add an as-of timestamp to the live 07-31 count, or remove it from a per-day total table until the day is complete.

This is not an approval with cleanup suggestions. The mechanism fails its own live dispatch, and several of the exact round-1 failure classes remain executable behind green tests.

verdict: REJECT