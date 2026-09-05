<#
.SYNOPSIS
    Checks GitHub for a newer version of each file this project actually
    needs to run, and downloads any that changed - a self-update check,
    meant to run on its own schedule (see Register-HaloResponseAgentTask.ps1's
    -EnableAutoUpdate switch), separate from the every-15-minute
    ticket-processing task.
.DESCRIPTION
    This deployment is a plain folder of downloaded files, not a git clone -
    files get onto the server by downloading them individually from GitHub
    (e.g. via a browser), not `git clone`/`git pull`. An earlier version of
    this script assumed a git working copy and required git to be installed
    and visible to SYSTEM; that assumption was wrong from the start and has
    been dropped along with the git dependency entirely.

    Instead, this fetches each file in $FilesToSync directly from
    https://raw.githubusercontent.com/<Owner>/<Repo>/<Branch>/<file> (plain
    HTTPS, no git, no authentication needed for a public repo) and compares
    its hash against the local copy, replacing only the files that actually
    changed. $FilesToSync is deliberately a specific, minimal list - not the
    whole repository, and not even every program file, just the ones this
    deployment actually needs kept current without a human involved:
    documentation files (README.md, CLAUDE.md) and repo metadata
    (.gitignore) never land in this folder, and neither do the one-time
    setup scripts (Install-Prerequisites.ps1, Register-HaloResponseAgentTask.ps1,
    Copy-McpServersToProject.ps1) - those run once, by hand, during initial
    setup or when deliberately re-registering the task, never invoked again
    afterward, so there's nothing this script's own unattended cycle would
    ever pick up a change to; if one of them changes, re-download it the
    same way you did the first time. Update this list by hand if a new
    file is added that the running pipeline itself depends on.

    config.json is deliberately NOT in this list and must never be added to
    it. It's explicitly a per-deployment file - README tells every new
    deployment to fill in on_call.primary.email/text_email and review
    remediation_whitelist by hand, and those edits only ever exist on this
    server, never in the repo. A real incident confirmed exactly this risk:
    an earlier version of this script did sync config.json, and the very
    first update cycle silently overwrote a live on_call.primary.email with
    the repo's still-placeholder value, with no backup and no way to tell
    it had happened until on-call escalation broke. If you ever want
    config.json changes to ship automatically, that needs a real design
    (e.g. a separate template file merged with local overrides) - never
    just adding it back to this list.

    Every file this script DOES touch is still backed up before being
    overwritten (to backups\<file>.bak-<timestamp>, in its own subfolder,
    not loose next to the real files) precisely because of that incident -
    even for files that are supposed to be kept in sync, a silent,
    unrecoverable overwrite is worse than a little disk clutter. The
    backups subfolder keeps that clutter out of the main deployment
    directory, which is meant to hold only the files this project actually
    needs (see README) - a real deployment accumulated a pile of loose
    .bak files there after enough real update cycles before this changed.
    Old backups are not cleaned up automatically; delete them by hand (or
    delete the whole backups folder) once you're confident you don't need
    them.

    Invoke-HaloResponseAgent.ps1 re-reads every file fresh on each scheduled
    firing - it's not a long-running process with anything cached in memory
    between cycles - so downloading a changed file here is enough to make
    the very next ticket-processing cycle pick it up, no restart needed.

    This script only logs when something actually happened (a real update,
    or a real error) - a silent no-op check every cycle would just be log
    noise, the same reasoning Invoke-HaloResponseAgent.ps1 already follows
    for its own logging. On finding an update, it also runs
    Invoke-HaloResponseAgent.ps1 -DryRun once as a smoke test (parses/runs
    the just-downloaded script without touching Halo or spending any API
    cost) so a broken update is visible in this script's own log
    immediately, rather than silently discovered only when the next real
    cycle fails. This is a smoke test, not a rollback mechanism - if the
    DryRun fails, the new code is still left in place and still runs on the
    next real cycle; the log is what tells a human to go look.

    A download failure for one file logs an error and leaves that file
    untouched - it never partially overwrites a file (downloads to a .new
    temp path first, only replaces the real file once the download fully
    succeeds), so a network blip can't corrupt anything on disk.
.PARAMETER RepoPath
    The folder this project is deployed to, and where updated files get
    written. Defaults to the folder this script lives in - as long as you
    keep the deployed files together, this needs no editing either.
.PARAMETER RepoOwner
.PARAMETER RepoName
.PARAMETER Branch
    Which GitHub repo/branch to check. Defaults to rafouche/HelpDeskAgent's
    main branch.
#>

param(
    [string]$RepoPath = $PSScriptRoot,
    [string]$RepoOwner = "rafouche",
    [string]$RepoName = "HelpDeskAgent",
    [string]$Branch = "main"
)

# Deliberately minimal - only the files the unattended pipeline itself
# depends on. Update by hand if a new required file is added; do NOT change
# this to "everything in the repo" - README.md/CLAUDE.md/.gitignore are
# documentation/repo metadata, not part of the deployed program, and should
# never land here.
#
# Also deliberately excluded: Install-Prerequisites.ps1,
# Register-HaloResponseAgentTask.ps1, Copy-McpServersToProject.ps1. These
# are one-time setup/registration scripts - run once, by hand, as
# Administrator, never invoked again by anything scheduled - so an
# unattended sync of them would just sit on disk unused; a change to one of
# these only matters the next time a human deliberately re-runs it, and at
# that point re-downloading it the normal way (same as the first time) is
# no extra step.
#
# config.json is deliberately NOT here and must never be added - see the
# long comment in the header above. It's a per-deployment file (on-call
# contacts, remediation whitelist) that only ever exists correctly on this
# server, never in the repo - a real incident confirmed that syncing it
# silently overwrites live settings with the repo's placeholder values.
$filesToSync = @(
    "id-resolver-prompt.md",
    "classifier-prompt.md",
    "resolver-prompt.md",
    "Invoke-HaloResponseAgent.ps1",
    "Update-HaloResponseAgent.ps1",
    "Show-AgentLog.ps1"
)

$logDir = Join-Path $RepoPath "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("update-{0:yyyy-MM-dd}.log" -f (Get-Date))
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Backups of replaced files live here, not loose in $RepoPath - see the
# comment where this is used below for why.
$backupDir = Join-Path $RepoPath "backups"

function Write-UpdateLog {
    param([string]$Message)
    Add-Content -Path $logFile -Value "[$timestamp] $Message" -Encoding UTF8
}

$changedFiles = @()
$downloadErrors = @()

foreach ($file in $filesToSync) {
    $url = "https://raw.githubusercontent.com/$RepoOwner/$RepoName/$Branch/$file"
    $localPath = Join-Path $RepoPath $file
    $tempPath = "$localPath.new"

    try {
        Invoke-WebRequest -Uri $url -OutFile $tempPath -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $downloadErrors += "$file - $($_.Exception.Message)"
        if (Test-Path $tempPath) { Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue }
        continue
    }

    $isNew = -not (Test-Path $localPath)
    $isDifferent = $true
    if (-not $isNew) {
        $oldHash = (Get-FileHash -Path $localPath -Algorithm SHA256).Hash
        $newHash = (Get-FileHash -Path $tempPath -Algorithm SHA256).Hash
        $isDifferent = $oldHash -ne $newHash
    }

    if ($isDifferent) {
        if (-not $isNew) {
            # Back up whatever was there before overwriting it. Cheap
            # insurance - the config.json incident that prompted this exists
            # precisely because a prior version of this script overwrote a
            # live file with no way to get the old content back. Backups go
            # in their own subfolder, not next to the real files - a real
            # deployment accumulated a pile of <file>.bak-<timestamp> files
            # cluttering the main directory after enough real update cycles,
            # and the whole point of this being a minimal-files deployment
            # (see README) is defeated if backups pile up alongside it.
            if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
            $backupPath = Join-Path $backupDir "$file.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item -Path $localPath -Destination $backupPath -Force
        }
        Move-Item -Path $tempPath -Destination $localPath -Force
        $changedFiles += $file
    }
    else {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
    }
}

if ($downloadErrors.Count -gt 0) {
    Write-UpdateLog "ERROR downloading $($downloadErrors.Count) file(s):`n$($downloadErrors -join "`n")"
}

if ($changedFiles.Count -eq 0) {
    # No update - nothing worth logging beyond any errors already logged
    # above, same reasoning as Invoke-HaloResponseAgent.ps1 not logging a
    # cycle that found zero candidate tickets any louder than it has to.
    if ($downloadErrors.Count -gt 0) { exit 1 }
    exit 0
}

Write-UpdateLog "Updated file(s): $($changedFiles -join ', ')"

# Smoke test: does the just-downloaded Invoke-HaloResponseAgent.ps1 still run
# at all? -DryRun does no Halo calls and spends no API cost, so this is
# cheap insurance against a broken push reaching the next real 15-minute
# cycle unnoticed.
$mainScript = Join-Path $RepoPath "Invoke-HaloResponseAgent.ps1"
try {
    & $mainScript -DryRun *>&1 | Out-Null
    Write-UpdateLog "Post-update smoke test (-DryRun) passed."
}
catch {
    Write-UpdateLog "WARNING: post-update smoke test (-DryRun) FAILED - $($_.Exception.Message). The new code is still in place and will still run on the next real cycle; check $mainScript by hand before relying on it."
}
