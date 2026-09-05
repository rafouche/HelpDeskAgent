<#
.SYNOPSIS
    Adds git's install directory to the machine-wide PATH so SYSTEM (and
    any other account) can find it - not just the account git happens to
    already work for interactively.
.DESCRIPTION
    Confirmed via a real test: a script run through NinjaRMM (which executes
    as SYSTEM by default - the same account Register-UpdateCheckTask.ps1
    registers its scheduled task under) failed with "'git' is not
    recognized as the name of a cmdlet, function, script file, or operable
    program", even though `git pull` works fine run interactively as an
    admin. This is the fourth tool in this project (claude, MCP
    registration, Claude Code's credentials, now git) with this exact
    account-scoping shape - see CLAUDE.md's "Known limitations".

    Unlike claude/npm (which needed a full reinstall into a shared prefix,
    since npm's own documented default on Windows is a genuinely per-user
    folder), git's installer already puts git.exe itself in a machine-wide
    location (C:\Program Files\Git\... by default) - the missing piece is
    almost always that only the installing user's own PATH (HKCU) got
    updated during setup, not the machine-wide one (HKLM). This script
    doesn't guess that location - it finds git's real path via the
    currently logged-in account's own PATH (where it already works) and
    adds that same folder to the machine PATH. No reinstall needed.

    Run this once, as Administrator, on the same account git already works
    for interactively (i.e. `git --version` already succeeds in this
    session).
#>

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    throw "git isn't found on PATH even for this account. Run this from the account git already works for interactively (git --version/git pull succeeds there), or install Git for Windows first if it isn't installed anywhere on this machine."
}

$gitDir = Split-Path -Path $gitCmd.Source -Parent
Write-Host "Found git at $($gitCmd.Source)" -ForegroundColor Green

function Add-ToMachinePath {
    param([string]$Directory)
    # [Environment]::SetEnvironmentVariable, not setx - setx silently
    # truncates any value over 1024 characters, and the machine PATH is
    # exactly the kind of long value that can already be close to that
    # limit (same reasoning as Install-ClaudeCodeMachineWide.ps1).
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($current -like "*$Directory*") {
        Write-Host "$Directory is already on the machine PATH." -ForegroundColor DarkGray
        return
    }
    [Environment]::SetEnvironmentVariable("Path", "$current;$Directory", "Machine")
    Write-Host "Added $Directory to the machine PATH" -ForegroundColor Green
}

Add-ToMachinePath -Directory $gitDir

# Git for Windows' full installer normally puts both a `cmd` directory
# (git.exe, git-gui.exe) and a sibling `bin` directory on PATH. Whichever one
# `Get-Command` found above, also add the other if it exists - cheap
# insurance in case something ever needs a tool only shipped in the one not
# already covered.
$parent = Split-Path -Path $gitDir -Parent
foreach ($siblingName in @("cmd", "bin")) {
    $sibling = Join-Path $parent $siblingName
    if ((Test-Path $sibling) -and ($sibling -ne $gitDir)) {
        Add-ToMachinePath -Directory $sibling
    }
}

Write-Host "`nEnvironment variables only take effect in a NEW process - open a fresh" -ForegroundColor Yellow
Write-Host "PowerShell window (or wait for the next scheduled/Ninja run) and confirm:" -ForegroundColor Yellow
Write-Host "`n    git --version`n" -ForegroundColor Cyan
Write-Host "Then re-run the same NinjaRMM script (or trigger the registered Task" -ForegroundColor Yellow
Write-Host "Scheduler task by hand) to confirm SYSTEM specifically can now see it too -" -ForegroundColor Yellow
Write-Host "this script running successfully as your own account doesn't prove that on" -ForegroundColor Yellow
Write-Host "its own." -ForegroundColor Yellow
