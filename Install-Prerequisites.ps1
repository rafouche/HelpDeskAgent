<#
.SYNOPSIS
    One-time setup: installs the claude CLI into a shared npm prefix so
    every account on this machine, not just whichever one you run this as,
    can find it.
.DESCRIPTION
    Run this once, as Administrator, before authenticating Claude Code or
    registering any scheduled task. `Register-HaloResponseAgentTask.ps1`
    registers the ticket-processing (and, optionally, auto-update) tasks to
    run as SYSTEM - a separate Windows account from whichever one you're
    logged in as, with its own profile and its own PATH. A plain
    `npm install -g @anthropic-ai/claude-code` run as yourself only lands in
    your own account's per-user npm prefix (%AppData%\npm - npm's own
    documented Windows default), which SYSTEM never sees.

    This installs @anthropic-ai/claude-code into a shared npm prefix
    instead (C:\ProgramData\npm) via the machine-wide NPM_CONFIG_PREFIX
    environment variable, and adds that folder to the machine PATH.

    Safe to re-run - detects whether it's already correct and skips
    redundant work unless told otherwise.

    This only handles WHERE claude is installed, not Claude Code
    authentication - still run `claude setup-token` or set
    `ANTHROPIC_API_KEY` afterward, and still register each MCP server with
    `-s project`, per README's setup steps.

    Auto-update (Register-HaloResponseAgentTask.ps1's -EnableAutoUpdate)
    does not need git - it fetches individual files over plain HTTPS (see
    Update-HaloResponseAgent.ps1), matching how this project is actually
    deployed (files downloaded individually, not cloned with git). Nothing
    in this project needs git installed at all.
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

Write-Host "=== claude (via a machine-wide npm prefix) ===" -ForegroundColor Cyan

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

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Open a NEW PowerShell window (this one won't see the machine-wide" -ForegroundColor Yellow
Write-Host "     PATH/NPM_CONFIG_PREFIX changes just made)." -ForegroundColor Yellow
Write-Host "  2. Authenticate - this only handled WHERE claude is installed, not" -ForegroundColor Yellow
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
