#!/usr/bin/env bats
# pr-opener-canary.bats — the boundary on the first outward-facing act.
#
# Opening a pull request is the only thing in this pipeline that other people
# see. The owner's limits (2026-08-02) are: this repository only, draft only,
# never a merge, never onto main. A limit nobody tried to cross is a claim.
#
# These cases try to cross each one. None of them reaches the network: every
# refusal happens before `gh pr create` is called, which is itself the
# property under test — a guard that fires after the request has gone out is
# not a guard.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    OPENER="$REPO/operator/builders/gh-pr-opener.sh"
    RUN="$BATS_TEST_TMPDIR/run"
    mkdir -p "$RUN"

    # A `gh` on PATH that records what it was asked and answers plausibly, so
    # a refusal that did not happen shows up as a recorded invocation.
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_CALLS"
case "$1 $2" in
  "repo view") echo "${FAKE_SLUG:-kimeisele/federation-recon}" ;;
  "pr create") echo "${FAKE_PR_URL:-https://github.com/kimeisele/federation-recon/pull/1}" ;;
  "pr view")   echo "${FAKE_IS_DRAFT:-true}" ;;
  *) echo "unexpected gh invocation: $*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$BIN/gh"
    export GH_CALLS="$BATS_TEST_TMPDIR/gh-calls.txt"
    : > "$GH_CALLS"
    export PATH="$BIN:$PATH"
}

_result() {
    printf '{"verdict": "%s", "issue": 1, "work_order_id": "wo-1-1"}\n' \
        "${1:-accepted}" > "$RUN/result.json"
}

# Run the opener from a scratch git repository on a named branch, so the
# branch checks have something real to read.
_in_branch_repo() {
    local branch="$1"; shift
    local dir="$BATS_TEST_TMPDIR/repo"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        git -C "$dir" init -q .
        git -C "$dir" config user.email t@t
        git -C "$dir" config user.name t
        printf 'x\n' > "$dir/f"
        git -C "$dir" add -A
        git -C "$dir" commit -q -m one
    fi
    git -C "$dir" checkout -q -B "$branch"
    ( cd "$dir" && "$@" )
}

@test "pr-opener canary: a repository that is not this one is refused" {
    _result accepted
    FAKE_SLUG="someone-else/other-repo" \
        run _in_branch_repo feature bash "$OPENER" "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSED"* ]]
    [[ "$output" == *"someone-else/other-repo"* ]]

    # And it never got as far as creating anything.
    run grep -c "pr create" "$GH_CALLS"
    [ "$output" = "0" ]
}

@test "pr-opener canary: a pull request from main is refused" {
    _result accepted
    run _in_branch_repo main bash "$OPENER" "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a proposal"* ]]
    run grep -c "pr create" "$GH_CALLS"
    [ "$output" = "0" ]
}

@test "pr-opener canary: a detached HEAD is refused" {
    _result accepted
    local dir="$BATS_TEST_TMPDIR/detached"
    mkdir -p "$dir"
    git -C "$dir" init -q .
    git -C "$dir" config user.email t@t
    git -C "$dir" config user.name t
    printf 'x\n' > "$dir/f"
    git -C "$dir" add -A && git -C "$dir" commit -q -m one
    git -C "$dir" checkout -q --detach

    run bash -c "cd '$dir' && bash '$OPENER' '$RUN'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"detached HEAD"* ]]
}

@test "pr-opener canary: a rejected run opens nothing" {
    _result rejected
    run _in_branch_repo feature bash "$OPENER" "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not accepted"* ]]
    run grep -c "pr create" "$GH_CALLS"
    [ "$output" = "0" ]
}

@test "pr-opener canary: a non-draft result is refused after the fact" {
    # --draft is passed unconditionally; this is the case where it was
    # accepted and ignored. A flag that was requested is not a limit — the
    # created object is read back and checked.
    _result accepted
    FAKE_IS_DRAFT=false run _in_branch_repo feature bash "$OPENER" "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a draft"* ]]
}

@test "pr-opener canary: a URL outside this repository is refused" {
    _result accepted
    FAKE_PR_URL="https://github.com/someone-else/other/pull/1" \
        run _in_branch_repo feature bash "$OPENER" "$RUN"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a pull request URL"* ]]
}

@test "pr-opener canary: the opener contains no merge path" {
    # Checked as a property of the file rather than asserted in a comment.
    # `gh pr merge` is the only way this script could merge anything, and it
    # is not in it.
    run grep -c "pr merge" "$OPENER"
    [ "$output" = "0" ]
    run grep -c -- "--admin" "$OPENER"
    [ "$output" = "0" ]
}

@test "pr-opener canary: --draft is passed on every create path" {
    # There is exactly one `gh pr create` in the file and it carries --draft.
    # If a second creation path is ever added without it, this fails.
    #
    # The count is one only because the failure message was reworded not to
    # repeat the literal — an error string mentioning the command was enough
    # to make the count two, and a test that counts strings has to be honest
    # about counting strings.
    CREATES="$(grep -c 'gh pr create' "$OPENER")"
    DRAFTS="$(grep -c -- '--draft' "$OPENER")"
    [ "$CREATES" = "1" ]
    [ "$DRAFTS" -ge 1 ]
}

@test "pr-opener canary: within the limits, it opens a draft and prints the URL" {
    # The positive case, so the canaries above cannot be satisfied by a script
    # that refuses everything.
    _result accepted
    run _in_branch_repo feature bash "$OPENER" "$RUN"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"https://github.com/kimeisele/federation-recon/pull/1"* ]]

    run grep -c -- "--draft" "$GH_CALLS"
    [ "$output" = "1" ]
    run grep -c -- "--base main" "$GH_CALLS"
    [ "$output" = "1" ]
}
