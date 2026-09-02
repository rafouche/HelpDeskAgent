<#
.SYNOPSIS
    Pretty-prints Invoke-HaloResponseAgent.ps1's log entries in human-readable form,
    instead of the raw JSON blobs it writes to logs\run-<date>.log / whatif-<date>.log.
.DESCRIPTION
    Each cycle appends one entry: a "[timestamp] ..." mode line, then one or more
    "=== HEADER ===" sections (CLASSIFIER, one TICKET <id> per resolved ticket, and
    a final CYCLE SUMMARY), then a "----" separator. This splits a log file back
    into those entries and, per section, prints: cost, tokens, turn count, any
    permission denials (tool calls that were silently blocked - the first thing to
    check if something seems to do nothing), and the actual text Claude wrote.

    Also understands the older, pre-classifier/resolver-pipeline log format (a
    single JSON blob per cycle, no "=== HEADER ===" sections) so historical logs
    still display.
.PARAMETER LogFile
    Path to a specific log file. Defaults to the most recently modified file in
    .\logs (whichever of run-*.log / whatif-*.log is newest).
.PARAMETER Last
    Show only the last N cycle entries in the file. Defaults to 1 (just the
    latest cycle). Pass a large number (or use -All) to see everything in the file.
.PARAMETER All
    Show every cycle entry in the file, ignoring -Last.
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

function Write-ClaudeResultSection {
    param(
        [string]$Title,
        [string]$JsonText
    )
    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Yellow

    $data = $null
    try {
        $data = $JsonText | ConvertFrom-Json
    }
    catch {
        Write-Host "(could not parse this section's JSON - printing raw)" -ForegroundColor Red
        Write-Host $JsonText
        return
    }

    if ($null -ne $data.total_cost_usd) {
        $cost = "`${0:N4}" -f $data.total_cost_usd
        $modelNames = "(unknown)"
        if ($data.modelUsage) {
            $modelNames = ($data.modelUsage.PSObject.Properties.Name) -join ', '
        }
        Write-Host "Cost: $cost   Turns: $($data.num_turns)   Duration: $([math]::Round($data.duration_ms/1000,1))s   Model: $modelNames" -ForegroundColor DarkGray
    }

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
        Write-Host "(no 'result' text in this section - is_error: $($data.is_error), terminal_reason: $($data.terminal_reason))" -ForegroundColor Yellow
    }
}

function Write-CycleSummarySection {
    param([string]$JsonText)
    Write-Host ""
    Write-Host "--- CYCLE SUMMARY ---" -ForegroundColor Green

    $data = $null
    try {
        $data = $JsonText | ConvertFrom-Json
    }
    catch {
        Write-Host $JsonText
        return
    }

    Write-Host ("Tickets found: {0}   Classifier cost: `${1:N4}   Resolver cost: `${2:N4}   Total: `${3:N4}" -f `
        $data.tickets_found, $data.classifier_cost_usd, $data.resolver_cost_usd, $data.total_cost_usd) -ForegroundColor Green

    if ($data.tickets -and $data.tickets.Count -gt 0) {
        foreach ($t in $data.tickets) {
            $costText = "`${0:N4}" -f $t.cost_usd
            $line = "  Ticket $($t.ticket_id): tier=$($t.tier) model=$($t.model) cost=$costText"
            if ($t.error) {
                Write-Host "$line ERROR: $($t.error)" -ForegroundColor Red
            }
            else {
                Write-Host $line
            }
        }
    }
}

$rawText = Get-Content -Path $LogFile -Raw -Encoding UTF8
$blocks = $rawText -split "(?m)^----\s*$" | Where-Object { $_.Trim() }

if (-not $All) {
    $blocks = $blocks | Select-Object -Last $Last
}

foreach ($block in $blocks) {
    $lines = @($block -split "`r?`n")

    # The first "[timestamp] ..." line is this cycle's mode header. Any LATER
    # line matching the same pattern is a mid-cycle "[timestamp] ERROR: ..."
    # written directly by the script (not through a "=== HEADER ===" section) -
    # without treating it as its own boundary, its text would get glued onto
    # whichever section happened to precede it, breaking that section's JSON.
    $timestampLineIndices = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[\d{4}-\d{2}-\d{2}') { $timestampLineIndices += $i }
    }

    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkGray
    $headerText = "(no header line found)"
    if ($timestampLineIndices.Count -gt 0) { $headerText = $lines[$timestampLineIndices[0]] }
    Write-Host $headerText -ForegroundColor Cyan

    # Find every "=== SOMETHING ===" section marker and its line index, plus
    # every mid-cycle timestamp/error line (as a synthetic "ERROR" section),
    # combined and sorted so each acts as a boundary for the ones around it.
    $sectionMarkers = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^===\s*(.+?)\s*===$') {
            $sectionMarkers += [PSCustomObject]@{ Title = $matches[1]; Index = $i; IsRaw = $false }
        }
    }
    foreach ($idx in $timestampLineIndices) {
        if ($idx -eq $timestampLineIndices[0]) { continue }  # that one is the header, not a section
        $sectionMarkers += [PSCustomObject]@{ Title = "ERROR"; Index = $idx; IsRaw = $true }
    }
    $sectionMarkers = $sectionMarkers | Sort-Object Index

    if ($sectionMarkers.Count -eq 0) {
        # Older log format: one raw JSON line per cycle, no section markers.
        $jsonLine = $lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
        if ($jsonLine) {
            Write-ClaudeResultSection -Title "RESULT (legacy single-call log format)" -JsonText $jsonLine
        }
        else {
            Write-Host "(no JSON result found in this entry - likely a PowerShell-level ERROR line, not a claude response)"
            foreach ($l in $lines) {
                if ($l.Trim() -and $l -ne $headerText) { Write-Host $l }
            }
        }
        continue
    }

    for ($m = 0; $m -lt $sectionMarkers.Count; $m++) {
        $marker = $sectionMarkers[$m]

        if ($marker.IsRaw) {
            # A mid-cycle "[timestamp] ERROR: ..." line - the notice IS the line
            # itself, not a header followed by separate content.
            Write-Host ""
            Write-Host "--- ERROR ---" -ForegroundColor Red
            Write-Host $lines[$marker.Index] -ForegroundColor Red
            continue
        }

        $title = $marker.Title
        $startIdx = $marker.Index + 1
        $endIdx = $lines.Count - 1
        if ($m -lt $sectionMarkers.Count - 1) {
            $endIdx = $sectionMarkers[$m + 1].Index - 1
        }

        $sectionLines = @()
        if ($endIdx -ge $startIdx) {
            $sectionLines = $lines[$startIdx..$endIdx]
        }
        $sectionText = ($sectionLines -join "`n").Trim()

        if ($title -eq "CYCLE SUMMARY") {
            Write-CycleSummarySection -JsonText $sectionText
        }
        else {
            Write-ClaudeResultSection -Title $title -JsonText $sectionText
        }
    }
}

Write-Host ""
Write-Host ("=" * 78) -ForegroundColor DarkGray
