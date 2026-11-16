#!/usr/bin/env bash
# Runs a test command and ends it, with a diagnostic, if it outlives a deadline.
#
#   suite-deadline.sh DEADLINE -- COMMAND...
#
# DEADLINE is a Unix time. The job's own `timeout-minutes` ends a hang too, but
# it ends it with nothing said: a job that runs out of time, or is cancelled by
# hand, skips what is left of it, the step that reports a stalled run included.
# A deadline the step keeps for itself, set below the job's timeout, ends the
# run while the job still has time to say where it stood.
#
# At the deadline this prints the test processes and their samples, then ends
# each worker -- not the runner -- so the runner reports, as it does for any
# worker that dies, which worker it was and the suite and case it last named.
# A runner that still does not finish is then ended itself. Either way the step
# fails: a run that needed ending did not pass.
#
# Windows has no process groups, so there windows-test-processes.ps1 lists the
# runner's process tree and finds and ends its workers instead.
set -uo pipefail

deadline=$1
shift
if [ "${1:-}" = -- ]; then
    shift
fi

here=$(cd "$(dirname "$0")" && pwd)

case "${OSTYPE:-}" in
    msys* | cygwin*) windows=1 ;;
    *) windows= ;;
esac

# The runner's process tree on Windows, ending some of it when asked (see
# windows-test-processes.ps1).
windows_processes() {
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass         -File "$(cygpath -w "$here/windows-test-processes.ps1")" -Root "$runner_winpid" "$@" || true
}

"$@" &
runner=$!
runner_winpid=
if [ -n "$windows" ]; then
    runner_winpid=$(cat "/proc/$runner/winpid" 2>/dev/null || true)
fi

while kill -0 "$runner" 2>/dev/null; do
    if [ "$(date +%s)" -lt "$deadline" ]; then
        sleep 5
        continue
    fi

    echo
    echo "::error::the test run was still going at its deadline; ending its workers so the runner reports where each one stood"
    waited=0
    if [ -n "$windows" ]; then
        windows_processes -End Workers
        while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt 120 ]; do
            sleep 5
            waited=$((waited + 5))
        done
        if kill -0 "$runner" 2>/dev/null; then
            echo "::error::the runner was still going ${waited}s after its deadline; ending it"
            windows_processes -End Tree
        fi
        wait "$runner" 2>/dev/null
        exit 1
    fi
    "$here/report-stalled-run.sh"

    # A worker runs under a shell of its own that leads its process group (see
    # `groupedWorker` in tests/run.lua). Those shells are the only ones whose
    # command names `nupp_reap` at group depth 1; the worker is their child
    # that is not a copy of the shell, and the shell's own parent is not one
    # either -- that rules out the subshell it watches its parent from. Ending
    # the worker lets its shell write the worker's status, which the runner
    # reads back.
    workers=$(ps -A -ww -o pid=,ppid=,command= | awk '
        { pid = $1; parent = $2; $1 = ""; $2 = ""; command[pid] = $0; parentOf[pid] = parent }
        END {
            for (pid in command) {
                up = parentOf[pid]
                if (command[up] ~ /NUPP_TEST_GROUP_DEPTH=1 / && command[up] ~ /nupp_reap/ \
                    && command[parentOf[up]] !~ /nupp_reap/ && command[pid] !~ /nupp_reap/) {
                    print pid
                }
            }
        }')
    if [ -n "$workers" ]; then
        echo "ending workers: $(echo $workers)"
        kill -TERM $workers 2>/dev/null || true
        while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt 120 ]; do
            sleep 5
            waited=$((waited + 5))
        done
    else
        echo "no worker processes found"
    fi
    if kill -0 "$runner" 2>/dev/null; then
        echo "::error::the runner was still going ${waited}s after its deadline; ending it"
        "$here/report-stalled-run.sh"
        kill -TERM "$runner" 2>/dev/null || true
        sleep 10
        kill -KILL "$runner" 2>/dev/null || true
    fi
    wait "$runner" 2>/dev/null
    exit 1
done

wait "$runner"
