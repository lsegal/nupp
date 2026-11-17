# What a Windows test run is running, and a way to end its workers.
#
#   windows-test-processes.ps1 -Root PID [-End Workers|Tree] [-Links FILE]
#
# The deadline in suite-deadline.sh finds a worker through the process group
# its shell leads (see `groupedWorker` in tests/run.lua). Windows has no such
# groups, so its worker is the plain `... --json ...` runner command its shell
# started. This lists every process under the runner ROOT (a Windows process
# id) with its command line, then optionally ends some of them:
#
#   Workers  each outermost worker, then everything under it. The worker goes
#            first, so it cannot see a child die and go on to its next suite.
#   Tree     every process under ROOT, and ROOT itself.
#
# A process is ended with exit status 143, the status a shell gives a command
# ended by SIGTERM. The worker's shell writes that status where the runner
# reads it back, so the runner reports "killed by signal 15" and the suite the
# worker last named, as it does on the other platforms. Never fails: it reports
# on a failure, it is not one.
param(
    [Parameter(Mandatory = $true)][int]$Root,
    [ValidateSet('', 'Workers', 'Tree')][string]$End = '',
    [string]$Links = ''
)

$ErrorActionPreference = 'Continue'

# A process's parent is the one Windows records while that one is still
# running. Git Bash runs a command by forking a copy of itself that then starts
# the command and exits, so the parent Windows records for a shell's command is
# usually gone: a `sleep` a test left running would not be found under its
# worker at all. LINKS is a file of "PID PARENT" Windows process ids from Git
# Bash's own process table, which keeps the shell as the parent; it stands in
# for a parent that has exited. It is not preferred outright, because a shell
# that runs a Windows program in place of itself stays behind as the parent
# Windows records, and its own entry there names the shell's parent instead.
$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$byId = @{}
$parentOf = @{}
foreach ($process in $all) {
    $byId[[int]$process.ProcessId] = $process
    $parentOf[[int]$process.ProcessId] = [int]$process.ParentProcessId
}
if ($Links -and (Test-Path $Links)) {
    foreach ($line in Get-Content $Links) {
        $pair = $line.Trim() -split '\s+'
        if ($pair.Count -ne 2) { continue }
        $process = $byId[[int]$pair[0]]
        if (-not $process) { continue }
        $recorded = $byId[$parentOf[[int]$pair[0]]]
        # Windows reuses process ids, so a recorded parent younger than its
        # child is some later process that took the id of one that exited.
        if (-not $recorded -or $recorded.CreationDate -gt $process.CreationDate) {
            $parentOf[[int]$pair[0]] = [int]$pair[1]
        }
    }
}
$children = @{}
foreach ($id in $parentOf.Keys) {
    $parent = $parentOf[$id]
    if (-not $children.ContainsKey($parent)) {
        $children[$parent] = New-Object System.Collections.ArrayList
    }
    [void]$children[$parent].Add($byId[$id])
}

# Breadth first, so a worker is always met before anything it started. Windows
# reuses process ids, so a child created before its supposed parent is not one.
$depthOf = @{}
function Get-Descendants([int]$id) {
    $found = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($id)
    $seen = @{ $id = $true }
    $depthOf[$id] = 0
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $children.ContainsKey($current)) { continue }
        foreach ($child in $children[$current]) {
            $childId = [int]$child.ProcessId
            if ($seen.ContainsKey($childId)) { continue }
            $owner = $byId[$current]
            if ($owner -and $child.CreationDate -lt $owner.CreationDate) { continue }
            $seen[$childId] = $true
            $depthOf[$childId] = $depthOf[$current] + 1
            [void]$found.Add($child)
            $queue.Enqueue($childId)
        }
    }
    return , $found
}

function Format-Process($process, [string]$indent) {
    $age = ''
    if ($process.CreationDate) {
        $age = '{0:hh\:mm\:ss}' -f ((Get-Date) - $process.CreationDate)
    }
    $line = $process.CommandLine
    if (-not $line) { $line = $process.Name }
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) + '...' }
    '{0}{1,7} {2,7} {3,9} {4,8:N0}K  {5}' -f $indent, $process.ProcessId, $parentOf[[int]$process.ProcessId], $age,
        ($process.WorkingSetSize / 1KB), $line
}

$rootProcess = $byId[$Root]
if (-not $rootProcess) {
    "process $Root is not running"
    exit 0
}

$tree = Get-Descendants $Root
'    PID    PPID       AGE  WORKING  COMMAND'
Format-Process $rootProcess ''
foreach ($process in $tree) {
    Format-Process $process ('  ' * $depthOf[[int]$process.ProcessId])
}

if (-not $End) { exit 0 }

Add-Type -ErrorAction SilentlyContinue -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NuppTestEnd {
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);
    public static int Terminate(int id, int code) {
        IntPtr process = OpenProcess(0x0001, false, id);
        if (process == IntPtr.Zero) return 0;
        try { return TerminateProcess(process, (uint)code) ? 1 : 0; } finally { CloseHandle(process); }
    }
}
'@

function End-Process($process) {
    $id = [int]$process.ProcessId
    $ended = [NuppTestEnd]::Terminate($id, 143)
    if ($ended -eq 1) {
        "ended $id $($process.Name)"
    } elseif (Get-Process -Id $id -ErrorAction SilentlyContinue) {
        "could not end $id $($process.Name)"
    } else {
        "$id $($process.Name) had already exited"
    }
}

if ($End -eq 'Tree') {
    End-Process $rootProcess
    foreach ($process in $tree) { End-Process $process }
    exit 0
}

# Workers: `--json` runner commands with no such command above them under ROOT.
# A worker's own suites may run the runner again, and those runs are its
# business; only the outermost ones are the runner's workers.
$isWorker = { param($process) $process.CommandLine -match '\s--json(\s|$)' }
$workers = @()
foreach ($process in $tree) {
    if (-not (& $isWorker $process)) { continue }
    $nested = $false
    $up = $parentOf[[int]$process.ProcessId]
    while ($up -ne $Root -and $byId.ContainsKey($up)) {
        if (& $isWorker $byId[$up]) { $nested = $true; break }
        $up = $parentOf[$up]
    }
    if (-not $nested) { $workers += $process }
}

if ($workers.Count -eq 0) {
    'no worker processes found'
    exit 0
}
'ending workers: ' + (($workers | ForEach-Object { $_.ProcessId }) -join ' ')
foreach ($worker in $workers) {
    End-Process $worker
    foreach ($process in (Get-Descendants ([int]$worker.ProcessId))) { End-Process $process }
}
exit 0
