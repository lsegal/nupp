#!/usr/bin/env bash
# What a test run left running, and where each test process is blocked.
#
# A run that stops making progress says nothing about where it stood: every
# macOS leg from a7deafd88 on sat at "shell suites joining" for an hour with one
# Nupp worker that had finished its suites and never exited. This lists the
# test processes and, where `sample` exists (macOS), samples each one, which
# names the call it is blocked in. Called by the suite step's deadline and by
# the step that reports a failed or cancelled run. Never fails: it reports on a
# failure, it is not one.
set -uo pipefail

ps -A -ww -o pid,ppid,pgid,stat,etime,command \
    | grep -E 'nupp-test|tests/run|luajit|bin/nupp' | grep -v grep || true
if command -v sample >/dev/null 2>&1; then
    for pid in $(pgrep -f 'nupp-test|tests/run' || true); do
        echo "=== sample $pid"
        sample "$pid" 2 -file /dev/stdout 2>/dev/null | head -60 || true
    done
fi
exit 0
