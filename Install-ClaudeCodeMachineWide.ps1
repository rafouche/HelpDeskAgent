<#
.SYNOPSIS
    Installs the claude CLI into a machine-wide npm prefix so every Windows
    account (including SYSTEM) can find it - not just whichever account
    happens to run the install.
.DESCRIPTION
    npm's own documented default global-install prefix on Windows is
    %AppData%\npm - a per-user folder, by design (confirmed against npm's
    official docs, not assumed). That's on YOUR PATH when you install and
    test interactively as an admin, but SYSTEM (the account
    Register-HaloResponseAgentTask.ps1 registers the scheduled task under)
    has its own separate profile and PATH, and never sees it - a real
    scheduled run failed with "'claude' is not recognized..." for exactly
    this reason, even though `claude --version` worked fine interactively the
    whole time.

    This script points npm's prefix at C:\ProgramData\npm instead - a folder
    genuinely shared by every account on the machine (that's what ProgramData
    is for), unlike %AppData% which is per-user - via the machine-wide
    NPM_CONFIG_PREFIX environment variable (documented npm behavior: env vars
    prefixed NPM_CONFIG_ map directly to npm config keys, and take precedence
    over the per-user default), adds that folder to the machine PATH, then
    installs @anthropic-ai/claude-code so it lands there. All of this happens
    in one run - it also sets the same values in its own current process
    before invoking npm, so the reinstall step doesn't need a fresh shell to
    pick up the new prefix (only OTHER processes - a new PowerShell window,
    SYSTEM's scheduled task - need that, which is why the instructions below
    say to open a new window before testing).

    Run this once, as Administrator, instead of a plain
    `npm install -g @anthropic-ai/claude-code`. Safe to re-run - it detects
    an already-correct machine-wide install and skips reinstalling unless
    -Reinstall is passed.

    This only handles WHERE claude gets installed, not authentication -
    still run `claude setup-token` or set `ANTHROPIC_API_KEY` afterward, per
    README's "Install and authenticate Claude Code" section.
.PARAMETER NpmPrefix
    The shared, machine-wide folder to install into. Defaults to
    C:\ProgramData\npm - change this only if that path is unsuitable for some
    reason on this particular server.
.PARAMETER Reinstall
    Re-run `npm install -g @anthropic-ai/claude-code` even if claude is
    already found under $NpmPrefix. Off by default - if it's already there,
    there's nothing to do.
#>

param(
    [string]$NpmPrefix = "C:\ProgramData\npm",
    [switch]$Reinstall
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this from an elevated (Administrator) PowerShell - it writes to C:\ProgramData and the machine-wide PATH/environment."
}

if (-not (Test-Path $NpmPrefix)) {
    New-Item -ItemType Directory -Path $NpmPrefix | Out-Null
    Write-Host "Created $NpmPrefix" -ForegroundColor Green
}

# NPM_CONFIG_PREFIX machine-wide: npm maps NPM_CONFIG_<KEY> env vars directly
# to its own config keys (documented behavior), and env vars win over the
# per-user %AppData%\npm default baked in by the Node.js Windows installer -
# this is what actually redirects `npm install -g` to a shared folder instead
# of silently landing whichever account happens to run it. A short single
# value like this is safe with plain setx (unlike PATH below, this can't hit
# setx's 1024-character truncation bug).
setx NPM_CONFIG_PREFIX $NpmPrefix /M | Out-Null
Write-Host "Set machine-wide NPM_CONFIG_PREFIX=$NpmPrefix" -ForegroundColor Green

# Add $NpmPrefix to the machine PATH - NOT via setx, which silently truncates
# any value over 1024 characters (a real, documented gotcha), and the machine
# PATH is exactly the kind of long value that can already be close to that
# limit. [Environment]::SetEnvironmentVariable has no such limit.
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
if ($machinePath -notlike "*$NpmPrefix*") {
    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$NpmPrefix", "Machine")
    Write-Host "Added $NpmPrefix to the machine PATH" -ForegroundColor Green
}
else {
    Write-Host "$NpmPrefix already on the machine PATH" -ForegroundColor DarkGray
}

# Mirror both into THIS process's environment too, so the npm install below
# picks up the new prefix immediately - persisting to the registry (above)
# only affects NEW processes, and this script's own process started before
# those changes existed.
$env:NPM_CONFIG_PREFIX = $NpmPrefix
if ($env:Path -notlike "*$NpmPrefix*") { $env:Path = "$env:Path;$NpmPrefix" }

$existingClaude = Get-Command claude -ErrorAction SilentlyContinue
$alreadyCorrect = $existingClaude -and ($existingClaude.Source -like "$NpmPrefix*")

if ($alreadyCorrect -and -not $Reinstall) {
    Write-Host "`nclaude already resolves to $($existingClaude.Source) - already under $NpmPrefix, nothing to reinstall." -ForegroundColor Green
    Write-Host "Pass -Reinstall to force a fresh install anyway." -ForegroundColor DarkGray
}
else {
    Write-Host "`nInstalling @anthropic-ai/claude-code into $NpmPrefix ..." -ForegroundColor Cyan
    npm install -g @anthropic-ai/claude-code

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd -and ($claudeCmd.Source -like "$NpmPrefix*")) {
        Write-Host "`nSuccess - claude now resolves to $($claudeCmd.Source)" -ForegroundColor Green
    }
    else {
        Write-Warning "claude did not resolve under $NpmPrefix as expected (found: $($claudeCmd.Source)). Check the npm install output above for errors before continuing."
    }
}

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Open a NEW PowerShell window (this one won't see the machine-wide" -ForegroundColor Yellow
Write-Host "     PATH/NPM_CONFIG_PREFIX changes just made - same reasoning as the /M note" -ForegroundColor Yellow
Write-Host "     in README's 'Install and authenticate Claude Code' section)." -ForegroundColor Yellow
Write-Host "  2. Authenticate - this only handled WHERE claude installs, not credentials:" -ForegroundColor Yellow
Write-Host "       claude setup-token                      # subscription login" -ForegroundColor Cyan
Write-Host "       # or" -ForegroundColor Yellow
Write-Host "       setx ANTHROPIC_API_KEY `"sk-ant-...`" /M   # API billing" -ForegroundColor Cyan
Write-Host "  3. Confirm SYSTEM sees it too by triggering the registered scheduled task" -ForegroundColor Yellow
Write-Host "     once by hand (Task Scheduler -> right-click -> Run) rather than trusting" -ForegroundColor Yellow
Write-Host "     an interactive -WhatIf run alone." -ForegroundColor Yellow
