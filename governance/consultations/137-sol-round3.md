<!-- provenance
requested_provider: openai
served_provider: openai
reviewer_claim: openai
model: gpt-5.6-sol
consistency_check: active scripts/consult.sh wrapper and jcode log were consistent with OpenAI; this is not proof of independence
session: session_parrot_1785530377311_7f14c1aca77769c9
log: /Users/ss/.jcode/logs/jcode-2026-07-31.log
window_start: 2026-07-31 22:39:36 +0200
-->

# Independent red-team review, PR #137, round 3

## Verdict

**REJECT.** The remediation is substantial, but five of the nine prior conditions remain plainly unsatisfied and three more are only partial. The focused 44 tests and the full 427-test gate are green while I can still:

1. bind a request to an attacker-created, malformed PID file and accept the wrong session;
2. delete the refused body after `cat` failed, because a header-only quarantine is nonempty;
3. return success with the requested output path as a symlink rather than a regular file;
4. add an unproven file during `find` and have the gate omit it;
5. hide markdown below an unreadable or symlinked directory;
6. supply required provenance fields from the body, omit the block closer, or duplicate fields and still pass;
7. register an unproven file with no reason at all.

The oracle wording is improved in the new artifact and library, but the repository still directs operators to use this self-reporting mechanism as the control for a different-provider requirement, and no external method establishes the actual independence claim. The original public 07-31 table also remains uncorrected.

## 1. Question 10: all nine prior conditions

### Condition 1

> "Add a real-environment integration test and make the current review dispatch succeed using the actual log format. Do not copy a truncation constant into fixtures."

**Letter: SATISFIED.** `scripts/test/integration/consult-live.sh` invokes real `jcode`, and the lookup tries the full session id and successively shorter prefixes rather than using one guessed constant. The committed live run is independently visible in the local evidence: session `session_humpback_1785530296553_18547ded9da51e8e` ran at 22:38, produced 16 `prv:OpenAI|mod:gpt` records, and its journal contains the exact response `LIVE_OK`.

**Substance: SATISFIED for the narrow live-format regression.** This review is also running through the real wrapper. The process chain is `bash scripts/consult.sh ...137-sol-round3.md` to `jcode run -p openai -m gpt-5.6-sol`; PID 8658 was recorded in `session_parrot_1785530377311_7f14c1aca77769c9`. At 22:49:19 the actual 20-character tag had 714 records, all OpenAI.

The decision not to spend provider tokens in the default suite is reasonable. The decision to keep the test out of every inventory is not. `scripts/test/MANIFEST` says it records every test file that must be present. Nothing cheap asserts that this integration test still exists or that a result was recorded when attribution code changed. Also, the script never checks that the produced body contains `LIVE_OK`; the actual journal did, but the test would pass a provenance-only artifact. These are new durability weaknesses, not failures of the quoted condition.

### Condition 2

> "Bind evidence to a unique request or turn, not a mutable PID-file prefix. Reject duplicate, stale, malformed, or ambiguous bindings."

**Letter: NOT SATISFIED.** The implementation still binds through a mutable file in `$HOME/.jcode/streaming_pids`, then binds log evidence through a truncated session prefix. It is not a unique request or turn identifier. Its filename check, `session_*_*_*`, does not validate the documented epoch-millisecond or hexadecimal components.

**Substance: NOT SATISFIED. EXECUTED, 2 seconds.** A fake `jcode` created a fresh file named `session_x_y_z` containing its PID, logged an OpenAI decoy, then two seconds later created the real session file and logged DeepSeek. The first poll saw exactly one match and stopped. `consult.sh` exited 0 with:

```text
session: session_x_y_z
served_provider: openai
```

The artifact body explicitly said it came from the later DeepSeek-labelled real session. Both PID files contained the same PID by completion. The duplicate check was defeated by creating the duplicate after the first successful poll. This is wrong-session acceptance, not a denial of service.

A same-user process can write, rename, or `touch` files in the directory. Freshness is only second-resolution `mtime >= START_EPOCH`, has no upper bound, and is not tied to process start metadata or file creation. A file written earlier in the same second is accepted. A future-dated file remains eligible. PID reuse while the original child is alive is prevented by the OS, and an exited un-reaped child normally retains its PID, so reuse during this exact polling loop is less plausible than the direct file race. It does not rescue the binding.

The log side is also non-unique. The 20-character tag contains only a short part of the timestamp after the animal name, and the fallback can go to 16 characters. `mark` is passed to `served_provider` but never used. An older session with the same truncated prefix can be merged into this run.

There are no direct regression tests for duplicate, stale, malformed, or raced PID files. The operator's claim that malformed files are rejected is factually false.

### Condition 3

> "Move the independence oracle outside jcode, or explicitly downgrade this mechanism to a non-authoritative consistency alarm and use an external method for the actual independence claim."

**Letter: NOT SATISFIED.** The field is now `consistency_check`, the success line says `consistent with the log`, and the library correctly leads with "not a proof of independence." Those changes satisfy the downgrade half. No external method is used for the actual independence claim.

**Substance: NOT SATISFIED.** The local wording is much more honest, but the repository is still internally inconsistent:

- `governance/reviewers.md` defines the required property as a different provider, lists Sol's invocation as `jcode run`, then says "Use scripts/consult.sh" and calls the script "the control."
- The same section correctly says a tool with silent failover cannot guarantee provider independence and recommends a direct endpoint only for Kimi. It never supplies an external independence method for Sol.
- `scripts/consult.sh` lines 33-42 still say it extracts the provider that "ACTUALLY served," deletes an unattributable output, and has no unverified path. All three statements overclaim or are stale: the evidence is jcode's own log, refusal now quarantines, and the log cannot establish actuality independently.

The artifact itself is honestly labelled. The overall repository still uses that honest consistency alarm to occupy the procedural slot for an independent provider. That is an incomplete downgrade, not an external oracle.

### Condition 4

> "Make quarantine preservation transactional. Never delete `.stdout` until the quarantine is a verified nonempty regular file. Test the failure path."

**Letter: NOT SATISFIED.** The directory-redirection failure is tested and fixed, but the write operation's status is ignored. The code checks only whether the resulting path is a nonempty regular file. A header alone satisfies that check even if the body copy failed.

**Substance: NOT SATISFIED. EXECUTED, under 1 second.** I made `.stdout` unreadable and triggered a provider mismatch. `cat` printed `Permission denied`; the quarantine contained only its generated header; the script printed `Body kept`, deleted `.stdout`, and exited 1. The finding was gone.

This is not transactional. The function must check the complete write, write to a separate regular temporary file without following links, verify that the body was copied, and only then atomically rename and delete `.stdout`.

### Condition 5

> "Require the requested output to become a nonempty regular file at the exact path. Reject output directories and test write and move failures."

**Letter: NOT SATISFIED.** Output directories are now rejected before dispatch, and a final `-f` plus `-s` check exists. There are still no tests for the `could not write` or `could not move` branches. More importantly, shell `-f` follows symlinks, so it does not establish that the exact path itself is a regular file.

**Substance: NOT SATISFIED. EXECUTED, under 1 second.** I deterministically simulated a post-move replacement with an `mv` shim that placed the artifact in `out.md.real` and left `out.md` as a symlink to it. `consult.sh` exited 0, deleted `.stdout`, and printed success. `ls -l` showed:

```text
out.md -> out.md.real
```

A concurrent writer with access to the output directory can create the same state between `mv` and the final test. The old directory exploit is fixed. The exact-path regular-file guarantee is not.

### Condition 6

> "Replace the top-level shell glob with a defined complete inventory and an explicit symlink and extension policy. Cover hidden files, subdirectories, unusual extensions, and concurrent additions according to that policy."

**Letter: NOT SATISFIED.** The extension and ordinary file-symlink policies are explicit, but there is no concurrency policy, rescan, lock, or stable committed inventory. `find` errors are discarded and its exit status cannot propagate through the process substitution.

**Substance: NOT SATISFIED. EXECUTED.** Results against the exact function:

- Hidden, nested, uppercase `.MD`, and `.markdown` files are included. This part is fixed.
- A directory named `x.md` is inventoried and refused as non-regular. Good.
- A proven filename containing a newline passes; `-print0` and the read loop are NUL-safe. Good.
- A file 300 directories deep passes. Good.
- A matching live or dangling file symlink is refused. Good.
- A symlinked directory containing `hidden.md` is silently skipped while another valid file lets the gate exit 0. This contradicts the broad statement that symlinks are refused rather than skipped.
- An unreadable subtree containing `hidden.md` is silently omitted because `find` diagnostics go to `/dev/null`; another valid file lets the gate exit 0.
- An unreadable regular file listed in `UNVERIFIED` passes even though the gate cannot inspect its contents.
- Concurrent addition still fails open. With 2,001 valid files being checked, I added unproven `late.md` after one second. The gate exited 0 and reported exactly 2,001 checked files while `late.md` existed. It should have seen 2,002.

The new empty-inventory failure is good, but it catches only total enumeration failure. It does not detect partial omission.

### Condition 7

> "Parse one provenance block at the start of the file. Reject quarantine sentinels, duplicate or embedded blocks, missing required fields, and metadata contradictions. Do not infer the authoritative reviewer claim only from filename tokens."

**Letter: NOT SATISFIED.** The gate verifies one opener and requires it on line one, but it does not parse a block. It searches the entire file for the first occurrence of each field and never requires a closing `-->`.

**Substance: NOT SATISFIED. EXECUTED, all under 1 second.** Each of these files passed:

1. The opener and `requested_provider` appeared first, the block closed, and body lines later supplied `served_provider`, `reviewer_claim`, and `model`.
2. Required fields appeared after the opener and no closing `-->` appeared anywhere.
3. `served_provider` appeared twice, first `openai` then `deepseek`; `head -1` silently chose OpenAI.
4. The opener used LF while all field lines used CRLF; carriage returns remained in the values, but equal carriage-return-suffixed provider strings passed.
5. The quarantine sentinel appeared after line three and passed, despite the policy header saying it is refused "anywhere in the file."

A full-CRLF opener and a leading-space opener fail closed. Duplicate opener lines fail. A plain renamed quarantine with its sentinel at the start fails. `reviewer_claim` is now authoritative and compared to `served_provider`; that specific filename defect is fixed. The mechanism is nevertheless a whole-file text search, not a record parser.

### Condition 8

> "Match UNVERIFIED paths literally with a validated record grammar."

**Letter: NOT SATISFIED.** `grep -Fqx --` satisfies literal path matching. The function does not validate record grammar or require a reason.

**Substance: NOT SATISFIED. EXECUTED, under 1 second.** A register containing only `a.md` admitted an unproven `a.md` and exited 0. The separate Bats test checks today's repository register, not the grammar of each fixture passed to the function. Round 2 explicitly rejected that separation.

The exact path behavior itself is correct and strict: trailing whitespace, CRLF, and `./a.md` do not match `a.md`. That is preferable to normalization by accident, but the accepted canonical grammar must be documented and enforced together with the reason.

### Condition 9

> "Add an as-of timestamp to the live 07-31 count, or remove it from a per-day total table until the day is complete."

**Letter: NOT SATISFIED.** `governance/consultations/UNVERIFIED` now annotates its copied 1,712 figure as `as of 20:30 UTC`. The original correction comment on issue #135 still presents `07-31 | 0 | 1712` in a per-day table with no as-of timestamp. GitHub reports that comment was never edited.

**Substance: NOT SATISFIED.** The public claim a reader is most likely to encounter remains a false completed-day presentation. At 22:49 local time the day's OpenAI-tagged total was already 3,519 and increasing. Annotating a secondary copy is cosmetic unless the original table is corrected too.

## 2. New-design attack summary

### Session binding

The freshness and multiplicity checks close only the exact static duplicate fixture from round 2. They do not authenticate the file or make the lookup atomic. A malicious or merely concurrent writer can win the first poll with one decoy and add the real file later. The filename parser accepts `session_x_y_z`. The log's fallback prefix is not unique, and the unused `mark` allows older same-prefix evidence to join the result.

The cheapest fix is not a stronger glob. Have `jcode` emit a request-specific session or turn identifier to a dedicated descriptor inherited by the wrapper, or return a structured receipt through a channel not writable as an arbitrary same-user directory entry. At minimum, open and validate one file atomically, compare process start metadata, require strict filename syntax, retain the descriptor until the child is reaped, and reject prefix collisions in the log.

### Inventory

`find -print0` fixes quoting, recursion, case, hidden files, and newlines. It is still a live traversal, not a complete stable inventory. Its errors are hidden. A stable committed gate should prefer a NUL-safe `git ls-files` inventory plus explicit checks for untracked paths if those are in scope. Otherwise it needs a lock or rescan and must fail on any `find` error. Directory symlinks need an explicit refusal path rather than silent non-traversal.

### Record parser

The implementation must first isolate exactly one bounded block from byte zero through one closer, then parse only that slice. Required fields must occur exactly once, unknown duplicates must be rejected or specified, line endings must be normalized or forbidden explicitly, and body text must never satisfy metadata. This is small enough to implement robustly in Python; the current `sed | head` composition has already recreated the class it was meant to remove.

### Register

Fixed-string matching is now exact. Define one canonical relative-path syntax, reject CRLF or normalize it deliberately, and parse the following nonempty reason as part of the same record. Do not rely on a test over the current production file to supply grammar the function itself lacks.

## 3. Question 9: the mechanism against itself

**Yes, this review was dispatched through `scripts/consult.sh`.** I observed the live wrapper, child command, PID record, `.stdout` growth, full session id, and real provider-tagged log records. The actual 20-character log format matched, so the round-2 24-character production failure is fixed.

The artifact with the provenance record at the top passes `check_consultation_provenance`. That proves only that the record is structurally accepted and internally consistent with jcode's log. It does not prove provider independence, exactly as the new `consistency_check` field now says.

The raw `.stdout` is deliberately outside the markdown inventory. While the child is still running, the wrapper's final atomic move cannot yet have occurred; the process and log evidence establish that it is on the successful provider path, subject to the post-exit write and move steps.

## 4. Question 1c: factual claims

Rechecked results:

- **True:** focused suites pass 44/44.
- **True:** `bash scripts/gate.sh` passes 427 tests and skips the network-dependent reproduce fixpoint.
- **True:** the live integration test was run. Session `humpback` is OpenAI and returned `LIVE_OK`.
- **True:** the two refused reviews cited in the commit had 526 and 529 OpenAI-tagged log lines. The 529-line session is `session_peacock_1785`.
- **True:** the current self-review is running through the claimed wrapper and real OpenAI log format.
- **True:** an empty inventory now fails.
- **True:** `grep -Fqx --` is present and exact.
- **False:** malformed PID files are rejected.
- **False:** session binding rejects a duplicate that arrives after the first successful poll.
- **False:** quarantine preservation is transactional.
- **False:** the exact output path must itself be a regular file.
- **False:** the inventory is complete under concurrent addition or traversal errors.
- **False:** the gate parses exactly one provenance record.
- **False:** the register grammar is validated by the function.
- **False:** the published 07-31 figure now carries an as-of timestamp everywhere it is asserted.
- **Partial:** the oracle is downgraded in the artifact and library, but not completely in repository procedure and not replaced by external evidence for the actual independence claim.

## 5. Tests and commands executed

- `bats scripts/test/consult-provenance.bats scripts/test/consultation-provenance.bats`: 44/44 pass.
- `bash scripts/gate.sh`: pass, 427 tests; network-dependent reproduce skipped.
- Live self-dispatch process, PID-file, session, `.stdout`, and raw-log inspection.
- Historical live integration session and journal inspection: OpenAI plus exact `LIVE_OK`.
- Fresh malformed PID-file race: wrong session accepted, exit 0.
- Quarantine body-copy failure: body deleted, false `Body kept` message.
- Exact-path symlink substitution: exit 0 with output path a symlink.
- Concurrent inventory addition: exit 0, 2,001 checked, late 2,002nd file omitted.
- Unreadable subtree omission: exit 0.
- Symlinked-directory omission: exit 0.
- Directory named `.md`: refused.
- Newline filename: handled correctly.
- 300-level tree: handled correctly.
- Body-supplied metadata: accepted.
- Missing block closer: accepted.
- Duplicate required field: accepted, first value won.
- Hybrid CRLF metadata: accepted.
- Late quarantine sentinel: accepted.
- Bare UNVERIFIED filename with no reason: accepted.
- Trailing-space, CRLF, and leading-`./` register paths: correctly refused as noncanonical exact mismatches.
- Raw GitHub issue #135 comment read through the API: no as-of timestamp and no edit.
- Independent recount of the 526, 529, current-session, and current-day log claims.

## 6. Blocking conditions for another round

1. Replace the attacker-writable first-match PID lookup with an atomic, strictly validated request or turn binding. Reject a decoy that appears before the real descriptor, and test the race with real production control flow.
2. Make quarantine copy success part of the transaction. A failed or partial `cat` must leave `.stdout` intact. Use a separate no-follow temporary regular file and an atomic rename.
3. Require the output path itself, not its symlink target, to be the newly written regular file. Add real write-failure, move-failure, and path-replacement tests.
4. Make inventory failures visible and completeness defined. Fail on `find` errors, refuse directory symlinks according to policy, and lock or rescan so a concurrent addition cannot be omitted.
5. Parse one bounded provenance block. Require one closer and exactly one occurrence of every required field inside the block. Body fields, duplicate fields, and malformed line endings must not pass.
6. Enforce the UNVERIFIED record grammar in the production function, including a canonical path and a nonempty associated reason.
7. Complete the oracle downgrade repository-wide and provide external evidence for any actual independence claim. Update stale `consult.sh` and `governance/reviewers.md` language.
8. Edit the original issue #135 correction table to add the as-of timestamp or remove the incomplete-day row.
9. Keep paid network execution out of the default suite if desired, but inventory the live test and mechanically require a recorded successful run whenever attribution logic changes.

verdict: REJECT