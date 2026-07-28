#!/bin/sh
set -e

# worker_kill.sh — root-owned, takes no arguments.
#
# Kills every process owned by _jcode_worker using pkill -9 -u.
# Running AS the worker user (via sudo -u _jcode_worker) is sufficient:
# a process may signal processes of its own uid.  No root privilege is
# needed — only a NOPASSWD sudoers entry for the worker identity.
#
# pkill exits 0 when it killed at least one process and 1 when no
# process matched.  Both are success for our purposes.
#
# This script takes NO arguments.  Any argument causes immediate exit.

[ $# -eq 0 ] || exit 1

cd /

exec /usr/bin/pkill -9 -u _jcode_worker
