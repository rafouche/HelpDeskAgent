<#
.SYNOPSIS
    Copies your already-registered -s user MCP servers into a project-scoped
    .mcp.json file, so SYSTEM (or any other account) can see them too.
.DESCRIPTION
    `claude mcp add ... -s user` (the default scope) only registers a server
    under the account you're logged in as, in that account's own
    ~/.claude.json - the scheduled task runs as SYSTEM, a different account
    with its own empty profile, which sees none of that (see README's
    "Register each MCP server" section). The fix is -s project, which writes
    a plain .mcp.json file into this folder instead - not tied to any one
    account.

    Re-typing every `claude mcp add` command with its URL and Bearer token by
    hand is tedious and error-prone with more than a couple of servers. Since
    ~/.claude.json's top-level `mcpServers` object and .mcp.json's own
    `mcpServers` object are the exact same JSON shape (confirmed against
    Claude Code's own docs, not assumed), this script just copies that object
    across instead of re-entering anything.

    Only handles servers that need no further interactive auth (static
    Bearer-token/API-key connectors) - anything showing "Needs authentication"
    in `claude mcp list` still needs the one-time interactive login described
    in README's "Registering MCP servers" section, on whichever account will
    actually run the task.
.PARAMETER ProjectPath
    Folder to write .mcp.json into. Defaults to the folder this script lives
    in - normally leave this alone, since that's also where
    Invoke-HaloResponseAgent.ps1 and the scheduled task's working directory
    both expect it.
.PARAMETER RemoveUserScoped
    After writing .mcp.json, also remove each copied server from -s user
    scope (`claude mcp remove <name> -s user`) so you're not left with the
    same server registered twice. Off by default - leaving the -s user copies
    in place is harmless, just redundant.
.PARAMETER Force
    Skip the confirmation prompt before writing.
#>

param(
    [string]$ProjectPath = $PSScriptRoot,
    [switch]$RemoveUserScoped,
    [switch]$Force
)

$claudeJsonPath = Join-Path $env:USERPROFILE ".claude.json"
if (-not (Test-Path $claudeJsonPath)) {
    Write-Error "Could not find $claudeJsonPath - no user-scoped Claude Code config found under this account ($env:USERNAME). Register at least one server with -s user first, or run this as the account you tested under."
    exit 1
}

$claudeConfig = Get-Content -Path $claudeJsonPath -Raw | ConvertFrom-Json

if (-not $claudeConfig.mcpServers -or ($claudeConfig.mcpServers.PSObject.Properties.Count -eq 0)) {
    Write-Error "No top-level 'mcpServers' entries found in $claudeJsonPath - nothing registered with -s user under this account ($env:USERNAME)."
    exit 1
}

$serverNames = @($claudeConfig.mcpServers.PSObject.Properties.Name)
Write-Host "Found $($serverNames.Count) user-scoped MCP server(s) under ${env:USERNAME}:" -ForegroundColor Cyan
foreach ($name in $serverNames) {
    $url = $claudeConfig.mcpServers.$name.url
    Write-Host "  - $name  ($url)"
}

if (-not $Force) {
    $answer = Read-Host "`nWrite these $($serverNames.Count) server(s) to $ProjectPath\.mcp.json ? (y/n)"
    if ($answer -notin @("y", "Y", "yes", "Yes")) {
        Write-Host "Aborted - nothing written." -ForegroundColor Yellow
        exit 0
    }
}

$mcpJsonPath = Join-Path $ProjectPath ".mcp.json"
if (Test-Path $mcpJsonPath) {
    $backupPath = "$mcpJsonPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "`nExisting .mcp.json found - backing it up to $backupPath before overwriting." -ForegroundColor Yellow
    Copy-Item -Path $mcpJsonPath -Destination $backupPath
}

# -Depth 10 matters: each server's "headers" object (Authorization: Bearer
# ...) is nested two levels deep, past ConvertTo-Json's default depth of 2,
# which would otherwise silently flatten it to the string "System.Object[]".
[ordered]@{ mcpServers = $claudeConfig.mcpServers } |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $mcpJsonPath -Encoding UTF8

Write-Host "`nWrote $($serverNames.Count) server(s) to $mcpJsonPath" -ForegroundColor Green

if ($RemoveUserScoped) {
    Write-Host "`nRemoving each from -s user scope so they're not registered twice..." -ForegroundColor Cyan
    foreach ($name in $serverNames) {
        claude mcp remove $name -s user
    }
}

Write-Host "`nVerify with (run from $ProjectPath so it picks up the project-scoped file too):" -ForegroundColor Cyan
Write-Host "  cd `"$ProjectPath`"; claude mcp list"
Write-Host "`nThen confirm the real fix worked by triggering the registered scheduled task" -ForegroundColor Cyan
Write-Host "once by hand (Task Scheduler -> right-click -> Run) - a -WhatIf run by hand" -ForegroundColor Cyan
Write-Host "still uses your own account either way and won't catch a SYSTEM-scoping gap." -ForegroundColor Cyan
