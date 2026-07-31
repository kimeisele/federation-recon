# Red-team — PR #131, stray process detection

**Reviewer:** Kimi K3 (Moonshot), direct API. **Verdict: REJECT**, four blocking conditions.

## Provider independence, as evidence rather than as a claim

| | |
|---|---|
| Endpoint | `https://api.moonshot.ai/v1/chat/completions` |
| `model` field in the response | `kimi-k3` |
| Tokens | prompt 5258, completion 7433 (reasoning 6139) |
| Temperature | 1 (the only value `kimi-k3` accepts) |
| Session context | none — single call, no history |

## Why Kimi and not the default reviewer

`governance/reviewers.md` makes Sol the default and reserves Kimi for judgments and
**security review / adversarial code analysis**. A change on the sandbox boundary is the
second category, so Kimi is the right reviewer here rather than a fallback.

It was also the only one available. Two attempts to run Sol in checkout mode against this
branch hung, measured:

    attempt 1: 47 minutes elapsed, 1.77s CPU, no output, no files written
    attempt 2: 10 minutes elapsed, 0.04s CPU, no filesystem activity at all

Quota was 7% of the 7-day window, so it was not throttling. This is the second distinct
instance of jcode hanging silently that this repository has recorded.

## Mode, stated because it changes what the answers are worth

**DIFF MODE — no checkout, nothing executed by the reviewer.** The review template calls
this the weaker mode and warns it "will win by default unless this is stated". The
reviewer was instructed to label questions 1, 3 and 8 NOT EXECUTED and did so.

The operator executed the reviewer's three most concrete findings afterwards.
**All three reproduce:**

    empty run id in the claimed set   -> 0 strays, status='ok'
    claimed id "w01" (3 chars)        -> 0 strays   [substring of _jcode_w01]
    double-fork with relative argv    -> 0 strays

---

## The review

## 1. Hiding from / impersonating the check — NOT EXECUTED

Hiding is trivial. The filter is `_SANDBOX_BASE in command`, which only sees *self-advertising* processes. Any descendant a run spawned with relative-path exec (`cd $BASE && ./bin/x`), a rewritten `argv[0]`, or a double-fork daemon has no base path in argv and is invisible. Who controls argv here? The sandboxed builder — i.e. the adversary. An embedded newline in an argument splits the ps line: the pid-bearing fragment may lack the base string, and the continuation parses as garbage and is skipped (`len(parts) < 4`). Evasion via argv alone. I would have run: a process with a >4KB argv and one with `\n` in argv[2], under `ps` piped (not tty), to check truncation and line-splitting on macOS — a truncated line missing the base string hides even the wrapper. False positives are symmetric: the operator's own `tail -f $BASE/log`, an editor, an `lsof` mentioning the path all get reported as strays "not accounted for by any claimed slot." That is noise training the operator to dismiss the report.

## 2. Live-run exclusion

Substring matching against attacker-influenceable data. A stray carrying any claimed run id anywhere in argv is excluded; the builder can read `runs/`, learn live ids, and mint them into its daemon's argv. Benign collisions are plausible if rids are short (the fixture's `W-AbGC` is 6 chars). Degenerate case: an empty rid makes `"" in command` true for **every** line — zero strays, status `"ok"`, check voided. A corrupt claim file is exactly the input reconcile exists to tolerate. One-line guard missing: skip empty/short rids; match rids as argv tokens, not substrings.

## 3. Clean without reading the table — NOT EXECUTED

Directly: no. The call is unconditional, exceptions and non-zero exit → `"unknown"`, and the launcher's `.get(..., "not checked")` fails in the right direction. Effectively: yes, twice. (a) The empty-rid exclusion above — the table was read, the result voided, the clean line printed. (b) `claimed_run_ids` is snapshotted *before* reconcile releases claims, so a slot released this pass still masks its root-owned stray this pass — one cycle of blindness on exactly the #129 shape, courtesy of `_release_slot`'s `pgrep -u` being unable to see the process the new check exists to find. I would have driven `reconcile()` with a monkeypatched `subprocess.run` and a corrupt claim fixture; not possible here.

## 4. Degrading existing claims

No new raise path; no exit-code change; worst case is a 10s stall on a hung ps. It cannot fake a canary pass. What it does is *dilute* one: the new clean line prints beside canary output and reads as a process-level guarantee it is not (see 6). Also note `reconcile()` takes no `ps_output`, so the wiring test greps source instead of executing reconcile with a fixture — the integration path is untested.

## 5. The owner-only argument

It conflates enablement with construction. The launcher already wields sudo (`sudo -n -u slot kill_self.sh`); a reaper behind a capability probe, shipped dark and lit by one sudoers line, is the same species of mechanism. "I cannot grant the permission" is not "the PR cannot contain the code" — and given the prior round where this operator's scoping premise was factually false, treat it as habit. Worse, the operator's own premise — a reaper must not kill what it cannot reliably identify — indicts this PR: the detector identifies by substring over adversary-influenced argv. The honest sequencing is *narrow identification, then reap*. This ships the broad version of the first and none of the second.

## 6. The failure mode that looks like success

`reconcile(): no processes outlived their run` — printed by a check that matched argv substrings, excluded anything carrying a claimed id, and never looked at descendants. The seven-hour sudo would now be caught; its children and anything quieter would not, and the line reads exactly like #129's line did. The fix reproduces the original epistemic defect one level down: a true statement about a subset rendered as a statement about the whole, by a PR whose stated purpose is ending exactly that.

## 7. Missing

Empty/short-rid guard and token-exact rid matching. Scope-honest reporting ("no processes with $BASE in argv…") or identification anchored on unforgeable attributes (uid root/slot, PPID 1, argv[0] is the wrapper, start-time vs run start). False-positive triage. A machine-checkable signal — non-zero exit or a state file — so the report has a consumer other than a human skimming stderr. An owner-facing decision artifact for the sudoers rule; a stderr comment is not a request. An end-to-end reconcile test with injected ps.

## 8. Right thing, or merely correct — NOT EXECUTED

Half of it. Detection-first is correct sequencing; detection-only is this repository's chronic disease — the observatory that never observes, the red-team gate nothing triggers, and now a report with no consumer, no exit code, no scheduler, whose false positives train dismissal. Better than the blind line it replaces; not the control the incident called for.

Blocking conditions: (1) guard the exclusion against empty/short rids and match rids token-wise, with a test for the empty-rid case; (2) make the clean line state its scope or anchor detection on non-argv attributes; (3) emit a machine-actionable signal when strays are found; (4) file the owner-decision artifact for the reaping sudoers rule.

verdict: REJECT
