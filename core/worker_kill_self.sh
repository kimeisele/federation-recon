#!/bin/sh

# worker_kill_self.sh -- root-owned, no arguments.
# Invoked AS the slot uid via "sudo -n -u <slot> .../worker_kill_self.sh".
# Derives its target from "id -u" so no uid string crosses the sudo boundary.
#
# Protocol (not a heuristic):
#   1. Loop: pkill -STOP -u <self>, then check the list of live PIDs.
#      Repeat until a pass reports zero processes that were not already
#      stopped at the start of the pass.
#   2. Then pkill -9 -u <self>.
#
# During STOP nothing dies, so the uid's population is monotonically
# non-decreasing and bounded by RLIMIT_NPROC; forks start failing at the
# cap; the next full pass stops the world, and stopped processes cannot fork.
#
# pkill exits 1 when nothing matched -- success here.  Any other nonzero
# exit or any stderr means failure.

[ $# -eq 0 ] || exit 1

cd / || exit 1

MY_UID="$(id -u)"

# Check that MY_UID is a plausible slot uid (611..618).
# If id -u returns something unexpected, refuse silently to avoid killing
# the wrong processes.
case "$MY_UID" in
  61[1-8]) ;;
  *)
    echo "worker_kill_self.sh: unexpected uid $MY_UID (expected 611-618)" >&2
    exit 1
    ;;
esac

MAX_ITER=20

# Phase 1 -- STOP loop.
#
# The exit condition used to compare PID counts ("didn't grow = stopped"),
# but that is a heuristic inference, not an observation.  A vanishing process
# can cancel growth from a new fork, making the count equal while an
# unstopped process remains.  Do not reintroduce that optimisation.

iter=0
unknown_seen=false
while [ "$iter" -lt "$MAX_ITER" ]; do
    iter=$((iter + 1))

    # Snapshot the current PID list for this uid.
    PID_LIST="$(pgrep -u "$MY_UID" 2>/dev/null)" || {
        rc=$?
        # pgrep exit 1 means "no processes matched" -- nothing to stop.
        if [ "$rc" -eq 1 ]; then
            PID_LIST=""
        else
            echo "worker_kill_self.sh: pgrep failed with exit $rc" >&2
            exit 1
        fi
    }

    # Count how many PIDs are in the list.
    set -- $PID_LIST
    count="$#"
    # If the list is empty, there are zero by definition.
    [ -z "$PID_LIST" ] && count=0

    if [ "$count" -eq 0 ]; then
        # Nothing to stop -- exit phase 1 successfully.
        break
    fi

    # STOP every process owned by this uid.
    pkill -STOP -u "$MY_UID" 2>/dev/null || {
        rc=$?
        # pkill exit 1 means nothing matched this pass -- that is fine
        # (racing with completion) and counts as success.
        [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
            echo "worker_kill_self.sh: pkill -STOP failed with exit $rc" >&2
            exit 1
        }
    }

    # Re-enumerate after STOP.
    NEW_LIST="$(pgrep -u "$MY_UID" 2>/dev/null)" || {
        rc=$?
        if [ "$rc" -eq 1 ]; then
            NEW_LIST=""
        else
            echo "worker_kill_self.sh: pgrep after STOP failed with exit $rc" >&2
            exit 1
        fi
    }

    set -- $NEW_LIST
    new_count="$#"
    [ -z "$NEW_LIST" ] && new_count=0

    if [ "$new_count" -eq 0 ]; then
        break
    fi

    # Check every PID's state directly via ps.  "T" means stopped.
    # A PID whose state cannot be read is unknown -- not treated as
    # stopped, and reported if the iteration bound is hit.
    all_stopped=true
    for pid in $NEW_LIST; do
        state="$(ps -o stat= -p "$pid" 2>/dev/null)" || {
            unknown_seen=true
            all_stopped=false
            continue
        }
        case "$state" in
            T*) ;;
            *)
                all_stopped=false
                ;;
        esac
    done

    if $all_stopped; then
        break
    fi
done

if [ "$iter" -ge "$MAX_ITER" ]; then
    if $unknown_seen; then
        echo "worker_kill_self.sh: STOP loop hit max iterations ($MAX_ITER) with processes in unknown state" >&2
    else
        echo "worker_kill_self.sh: STOP loop hit max iterations ($MAX_ITER)" >&2
    fi
    # Continue to KILL anyway -- better to attempt than leave survivors.
fi

# Phase 2 -- KILL -9.
pkill -9 -u "$MY_UID" 2>/dev/null || {
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
        echo "worker_kill_self.sh: pkill -9 failed with exit $rc" >&2
        exit 1
    }
}

exit 0
