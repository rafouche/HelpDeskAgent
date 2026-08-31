<#
.SYNOPSIS
    Pretty-prints Invoke-HaloResponseAgent.ps1's log entries in human-readable form,
    instead of the raw JSON blob it writes to logs\run-<date>.log / whatif-<date>.log.
.DESCRIPTION
    Each run appends one entry: a "[timestamp] ..." mode line, one big JSON object
    (claude's --output-format json response), and a "----" separator. This splits
    a log file back into those entries and prints, per entry: the timestamp/mode,
    cost, token usage, turn count, any permission denials (tool calls that were
    silently blocked - the first thing to check if something seems to do nothing),
    and the actual report text Claude wrote, exactly as it read out in the console
    but without needing to eyeball a giant single-line JSON string for it.
.PARAMETER LogFile
    Path to a specific log file. Defaults to the most recently modified file in
    .\logs (whichever of run-*.log / whatif-*.log is newest).
.PARAMETER Last
    Show only the last N entries in the file. Defaults to 1 (just the latest run).
    Pass a large number (or use -All) to see everything in the file.
.PARAMETER All
    Show every entry in the file, ignoring -Last.
#>

param(
    [string]$LogFile,
    [int]$Last = 1,
    [switch]$All
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not $LogFile) {
    $logDir = Join-Path $PSScriptRoot "logs"
    $candidate = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) {
        Write-Host "No log files found in $logDir - run Invoke-HaloResponseAgent.ps1 (with -WhatIf or for real) first."
        return
    }
    $LogFile = $candidate.FullName
}

if (-not (Test-Path $LogFile)) {
    Write-Host "Log file not found: $LogFile"
    return
}

$rawText = Get-Content -Path $LogFile -Raw -Encoding UTF8
$blocks = $rawText -split "(?m)^----\s*$" | Where-Object { $_.Trim() }

if (-not $All) {
    $blocks = $blocks | Select-Object -Last $Last
}

foreach ($block in $blocks) {
    $lines = $block -split "`r?`n" | Where-Object { $_.Trim() }
    $headerLine = $lines | Where-Object { $_ -match '^\[\d{4}-\d{2}-\d{2}' } | Select-Object -First 1
    $jsonLine   = $lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    $headerText = "(no header line found)"
    if ($headerLine) { $headerText = $headerLine }
    Write-Host $headerText -ForegroundColor Cyan

    if (-not $jsonLine) {
        Write-Host "(no JSON result found in this entry - likely a PowerShell-level ERROR line above, not a claude response)"
        continue
    }

    try {
        $data = $jsonLine | ConvertFrom-Json
    }
    catch {
        Write-Host "Could not parse this entry's JSON - printing raw:" -ForegroundColor Yellow
        Write-Host $jsonLine
        continue
    }

    $cost = "{0:C4}" -f $data.total_cost_usd
    $modelNames = "(unknown)"
    if ($data.modelUsage) {
        $modelNames = ($data.modelUsage.PSObject.Properties.Name) -join ', '
    }
    Write-Host "Cost: $cost   Turns: $($data.num_turns)   Duration: $([math]::Round($data.duration_ms/1000,1))s   Model: $modelNames" -ForegroundColor DarkGray

    if ($data.permission_denials -and $data.permission_denials.Count -gt 0) {
        Write-Host ""
        Write-Host "PERMISSION DENIALS (tool calls silently blocked - check the allowlist if these look wrong):" -ForegroundColor Red
        foreach ($denial in $data.permission_denials) {
            Write-Host "  - $($denial.tool_name)" -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($data.result) {
        Write-Host $data.result
    }
    else {
        Write-Host "(no 'result' text in this entry - is_error: $($data.is_error), terminal_reason: $($data.terminal_reason))" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
