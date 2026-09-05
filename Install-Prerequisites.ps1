<#
.SYNOPSIS
    One-time setup: installs the claude CLI and makes sure both claude and
    git are visible to every account on this machine, not just whichever
    account you run this as.
.DESCRIPTION
    Run this once, as Administrator, before authenticating Claude Code or
    registering any scheduled task. `Register-HaloResponseAgentTask.ps1`
    registers the ticket-processing (and, optionally, auto-update) tasks to
    run as SYSTEM - a separate Windows account from whichever one you're
    logged in as, with its own profile and its own PATH. Anything installed
    or configured only for your own account is invisible to SYSTEM, so this
    script does the two things that need to be machine-wide instead of
    per-account:

    1. Installs @anthropic-ai/claude-code into a shared npm prefix
       (C:\ProgramData\npm, not npm's per-user default of %AppData%\npm) via
       the machine-wide NPM_CONFIG_PREFIX environment variable, and adds
       that folder to the machine PATH.
    2. Makes sure git's own install folder is on the machine PATH too -
       Git for Windows already installs into a machine-wide folder
       (C:\Program Files\Git\...), so this doesn't reinstall it, it just
       adds that folder to the machine PATH if the installer only added it
       to your own account's.

    Safe to re-run - each step detects whether it's already correct and
    skips redundant work unless told otherwise.

    This only handles WHERE claude and git are installed/visible, not
    Claude Code authentication - still run `claude setup-token` or set
    `ANTHROPIC_API_KEY` afterward, and still register each MCP server with
    `-s project`, per README's setup steps.
.PARAMETER NpmPrefix
    The shared, machine-wide folder to install claude-code into. Defaults
    to C:\ProgramData\npm - change this only if that path is unsuitable for
    some reason on this particular server.
.PARAMETER ReinstallClaude
    Re-run `npm install -g @anthropic-ai/claude-code` even if claude is
    already found under $NpmPrefix. Off by default - if it's already there,
    there's nothing to do.
#>

param(
    [string]$NpmPrefix = "C:\ProgramData\npm",
    [switch]$ReinstallClaude
)

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this from an elevated (Administrator) PowerShell - it writes to C:\ProgramData and the machine-wide PATH/environment."
}

function Add-ToMachinePath {
    param([string]$Directory)
    # [Environment]::SetEnvironmentVariable, not setx - setx silently
    # truncates any value over 1024 characters, and the machine PATH is
    # exactly the kind of long value that can already be close to that
    # limit.
    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ($current -like "*$Directory*") {
        Write-Host "$Directory is already on the machine PATH." -ForegroundColor DarkGray
        return
    }
    [Environment]::SetEnvironmentVariable("Path", "$current;$Directory", "Machine")
    Write-Host "Added $Directory to the machine PATH" -ForegroundColor Green
}

Write-Host "=== 1. claude (via a machine-wide npm prefix) ===" -ForegroundColor Cyan

if (-not (Test-Path $NpmPrefix)) {
    New-Item -ItemType Directory -Path $NpmPrefix | Out-Null
    Write-Host "Created $NpmPrefix" -ForegroundColor Green
}

# NPM_CONFIG_PREFIX machine-wide: npm maps NPM_CONFIG_<KEY> env vars directly
# to its own config keys (documented behavior), and env vars win over the
# per-user %AppData%\npm default baked in by the Node.js Windows installer -
# this is what actually redirects `npm install -g` to a shared folder
# instead of whichever account happens to run it.
setx NPM_CONFIG_PREFIX $NpmPrefix /M | Out-Null
Write-Host "Set machine-wide NPM_CONFIG_PREFIX=$NpmPrefix" -ForegroundColor Green

Add-ToMachinePath -Directory $NpmPrefix

# Mirror both into THIS process's environment too, so the npm install below
# picks up the new prefix immediately - persisting to the registry (above)
# only affects NEW processes, and this script's own process started before
# those changes existed.
$env:NPM_CONFIG_PREFIX = $NpmPrefix
if ($env:Path -notlike "*$NpmPrefix*") { $env:Path = "$env:Path;$NpmPrefix" }

$existingClaude = Get-Command claude -ErrorAction SilentlyContinue
$claudeAlreadyCorrect = $existingClaude -and ($existingClaude.Source -like "$NpmPrefix*")

if ($claudeAlreadyCorrect -and -not $ReinstallClaude) {
    Write-Host "claude already resolves to $($existingClaude.Source) - already under $NpmPrefix, nothing to reinstall." -ForegroundColor Green
    Write-Host "Pass -ReinstallClaude to force a fresh install anyway." -ForegroundColor DarkGray
}
else {
    Write-Host "Installing @anthropic-ai/claude-code into $NpmPrefix ..." -ForegroundColor Cyan
    npm install -g @anthropic-ai/claude-code

    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($claudeCmd -and ($claudeCmd.Source -like "$NpmPrefix*")) {
        Write-Host "Success - claude now resolves to $($claudeCmd.Source)" -ForegroundColor Green
    }
    else {
        Write-Warning "claude did not resolve under $NpmPrefix as expected (found: $($claudeCmd.Source)). Check the npm install output above for errors before continuing."
    }
}

Write-Host "`n=== 2. git (machine-wide PATH visibility) ===" -ForegroundColor Cyan

$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
    Write-Warning "git isn't installed (or isn't on PATH) for this account either. Install Git for Windows first (https://git-scm.com/download/win, or `winget install --id Git.Git -e`), then re-run this script."
}
else {
    # Git for Windows already installs git.exe into a machine-wide folder
    # (C:\Program Files\Git\... by default) - no reinstall needed here,
    # unlike claude/npm above. The only thing usually missing is that the
    # installer only added it to the installing account's own PATH (HKCU),
    # not the machine-wide one (HKLM).
    $gitDir = Split-Path -Path $gitCmd.Source -Parent
    Write-Host "Found git at $($gitCmd.Source)" -ForegroundColor Green
    Add-ToMachinePath -Directory $gitDir

    # Git for Windows' full installer normally puts both a `cmd` directory
    # (git.exe, git-gui.exe) and a sibling `bin` directory on PATH. Whichever
    # one was found above, also add the other if it exists - cheap insurance
    # in case something ever needs a tool only shipped in the one not
    # already covered.
    $parent = Split-Path -Path $gitDir -Parent
    foreach ($siblingName in @("cmd", "bin")) {
        $sibling = Join-Path $parent $siblingName
        if ((Test-Path $sibling) -and ($sibling -ne $gitDir)) {
            Add-ToMachinePath -Directory $sibling
        }
    }
}

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Open a NEW PowerShell window (this one won't see the machine-wide" -ForegroundColor Yellow
Write-Host "     PATH/NPM_CONFIG_PREFIX changes just made)." -ForegroundColor Yellow
Write-Host "  2. Authenticate - this only handled WHERE claude/git are installed, not" -ForegroundColor Yellow
Write-Host "     credentials:" -ForegroundColor Yellow
Write-Host "       claude setup-token                      # subscription login" -ForegroundColor Cyan
Write-Host "       # or" -ForegroundColor Yellow
Write-Host "       setx ANTHROPIC_API_KEY `"sk-ant-...`" /M   # API billing" -ForegroundColor Cyan
Write-Host "  3. Register each MCP server with -s project (README's 'Register each MCP" -ForegroundColor Yellow
Write-Host "     server' section)." -ForegroundColor Yellow
Write-Host "  4. Register the scheduled task(s) with Register-HaloResponseAgentTask.ps1." -ForegroundColor Yellow
Write-Host "  5. Confirm SYSTEM sees everything by triggering the registered task(s) once" -ForegroundColor Yellow
Write-Host "     by hand (Task Scheduler -> right-click -> Run) rather than trusting an" -ForegroundColor Yellow
Write-Host "     interactive -WhatIf run alone." -ForegroundColor Yellow
