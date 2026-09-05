<#
.SYNOPSIS
    Checks this folder's git repo for a new commit on origin/main and pulls
    it if one exists - a self-update check, meant to run on its own schedule
    (see Register-HaloResponseAgentTask.ps1's -EnableAutoUpdate switch),
    separate from the every-10-minute ticket-processing task.
.DESCRIPTION
    Invoke-HaloResponseAgent.ps1 re-reads every .ps1/.md/config.json file
    from disk fresh on each scheduled firing - it's not a long-running
    process with anything cached in memory between cycles. That means a
    plain `git pull` in this folder is enough to make the very next
    ticket-processing cycle pick up whatever just shipped - no restart, no
    reload step, nothing else needed.

    This script only logs when something actually happened (a real update,
    or a real error) - a silent no-op check every cycle would just be log
    noise, the same reasoning Invoke-HaloResponseAgent.ps1 already follows
    for its own logging. On finding a new commit, it also runs
    Invoke-HaloResponseAgent.ps1 -DryRun once as a smoke test (parses/runs
    the just-pulled script without touching Halo or spending any API cost)
    so a broken update is visible in this script's own log immediately,
    rather than silently discovered only when the next real cycle fails.
    This is a smoke test, not a rollback mechanism - if the DryRun fails,
    the new code is still left in place and still runs on the next real
    cycle; the log is what tells a human to go look.

    Git operations never throw in a way that leaves this folder corrupted:
    `git pull` itself refuses to partially apply on a conflict, and this
    script wraps everything in try/catch so a network blip or conflict logs
    an error and exits cleanly rather than crashing.
.PARAMETER RepoPath
    The git repo to check/pull. Defaults to the folder this script lives in
    - as long as you keep the deployed files together, this needs no
    editing either.
#>

param(
    [string]$RepoPath = $PSScriptRoot
)

$logDir = Join-Path $RepoPath "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("update-{0:yyyy-MM-dd}.log" -f (Get-Date))
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

function Write-UpdateLog {
    param([string]$Message)
    Add-Content -Path $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

try {
    $beforeHash = (& git -C $RepoPath rev-parse HEAD 2>&1).Trim()
}
catch {
    Write-UpdateLog "ERROR: could not read current commit - is $RepoPath a git repo, and is git on PATH for this account? $($_.Exception.Message)"
    exit 1
}

try {
    $pullOutput = & git -C $RepoPath pull origin main 2>&1
    $pullExitCode = $LASTEXITCODE
}
catch {
    Write-UpdateLog "ERROR: git pull threw - $($_.Exception.Message)"
    exit 1
}

if ($pullExitCode -ne 0) {
    Write-UpdateLog "ERROR: git pull failed (exit $pullExitCode) - nothing changed, existing files untouched. Output: $($pullOutput | Out-String)"
    exit 1
}

$afterHash = (& git -C $RepoPath rev-parse HEAD 2>&1).Trim()

if ($afterHash -eq $beforeHash) {
    # No update - nothing worth logging, same reasoning as Invoke-HaloResponseAgent.ps1
    # not logging a cycle that found zero candidate tickets any louder than it has to.
    exit 0
}

$shortBefore = $beforeHash.Substring(0, 7)
$shortAfter  = $afterHash.Substring(0, 7)
$commitSummary = & git -C $RepoPath log --oneline "$beforeHash..$afterHash" 2>&1
Write-UpdateLog "Updated $shortBefore -> $shortAfter"
Write-UpdateLog "Commits pulled:`n$($commitSummary | Out-String)"

# Smoke test: does the just-pulled Invoke-HaloResponseAgent.ps1 still run at
# all? -DryRun does no Halo calls and spends no API cost, so this is cheap
# insurance against a broken push reaching the next real 10-minute cycle
# unnoticed.
$mainScript = Join-Path $RepoPath "Invoke-HaloResponseAgent.ps1"
try {
    & $mainScript -DryRun *>&1 | Out-Null
    Write-UpdateLog "Post-update smoke test (-DryRun) passed."
}
catch {
    Write-UpdateLog "WARNING: post-update smoke test (-DryRun) FAILED - $($_.Exception.Message). The new code is still in place and will still run on the next real cycle; check $mainScript by hand before relying on it."
}
