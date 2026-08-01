<!-- provenance
requested_provider: moonshot
served_provider: moonshot
reviewer_claim: moonshot
model: kimi-k3
consistency_check: direct API call, model field read from the response body
log: not applicable — no tool with failover in the path
-->

# Red-team round 2 — PR #131

**Verdict: REJECT.** All four round-1 conditions verified as met; one NEW blocking
condition of the same shape the PR exists to kill.

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 9932, completion 9701 |
| Mode | **diff mode — nothing executed by the reviewer**, answers labelled NOT EXECUTED |

---

## Round-1 conditions — verification

**(1) "guard the exclusion against empty/short rids and match rids token-wise, with a test for the empty-rid case."** Letter: moot — the rid comparator was deleted, not patched, which is the stronger fix. Exclusion is now slot membership read from the claim directory; argv cannot assert it. Substance: met. Test 4 executes exactly my degenerate input (`""`, partial, near-miss claims) and the stray is still found. **Satisfied.**

**(2) "make the clean line state its scope or anchor detection on non-argv attributes."** Both disjuncts done. Detection is anchored on the kernel uid; the line is now "no process is running under an unclaimed slot uid," which is precisely the set inspected. Not cosmetic — the line is now true of the check that prints it. **Satisfied in letter and substance.**

**(3) "emit a machine-actionable signal when strays are found."** Exit 1, twice: pre-flight *before* the canary suite, and post-reconcile; both fail-closed on strays and on `status != "ok"`. Tests 12–13 execute `launcher.main` and assert rc and that no canary ran before refusal. **Satisfied.**

**(4) "file the owner-decision artifact for the reaping sudoers rule."** Filed as #134 per the operator; the diff names it three times and the refusal routes the operator there. Letter: satisfied within the diff; the issue's existence/content is outside it — NOT VERIFIED. If #134 does not exist, this condition is unmet and the basis of this verdict changes. That is on the operator.

## Fresh attacks

**1. The user column.** The uid itself is unforgeable as claimed — a slot process cannot setuid, and slot reuse is handled by checking pre-claim: a prior survivor is unclaimed at pre-flight and caught. The window closes correctly across launches. **But** the code compares the user *name string*. ps(1) explicitly reserves printing a decimal uid when the name exceeds the field width, and width/truncation behavior for 10-character names like `_jcode_w01` under `ps -eo user=` is ps-version dependent. If the target host ever prints `_jcode_+` or a number, `user in _SLOT_MAP` is never true, root may print as `0`, zero strays, status `"ok"` — silent fail-open reproducing #129's shape, with all 14 tests green, because every test injects fixtures and none reads real ps. NOT EXECUTED — unverifiable in this mode, and unexercised by their suite.

**2. `_slot_of_sudo_parent`.** The adversary cannot mint root processes, and first-match ordering means run()'s real `-u <slot>` precedes any trailing attacker-controlled tokens — spoofing needs prefix control the worker never has. Sound. Reverse: `sudo cat $WRAPPER` is root, contains the wrapper path, lacks `-u slot` → "unattributed" stray → refusal. Ordinary operator debugging now wedges the pool. Non-blocking: tighten to argv[0] being sudo.

**3. Refuse-on-any-stray.** Fail-closed is right for root strays. But the code conflates "cannot reap" with "will not reap": a slot-uid stray is killable *today* via kill_slot, which acts as the slot user — no sudoers change, no #134. One double-forked `sleep` from a builder and every subsequent launch refuses until a human acts; that is the adversary's cheapest persistent lever. Attribution (pid/slot/command printed) makes it acceptable, so I recommend rather than block: reap the slot-owned subset at pre-flight now.

**4. New problems from fixes.** (a) The ps-name dependence in attack 1. (b) Newline-in-argv evasion is dead by construction — attribution rides on the leading pid/user fields; credit. (c) The mutation gap they self-reported (13 green with the re-read reverted) is exactly the class of finding this process exists for; test 14's instrumented listdir is sound *if* reconcile's top-of-function claim collection also listdirs `_SLOTS_DIR` — that body is outside the diff, NOT VERIFIED.

## New blocking condition

Match numerically on `-o uid=` (width- and resolution-immune; `_SLOT_MAP` already holds the uids), or demonstrate on the target host that this exact ps invocation prints full slot names and `root`. All four round-1 conditions are met; the round-2 attack surfaces one new blocker of the same shape this PR exists to kill.

verdict: REJECT
