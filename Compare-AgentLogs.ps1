<#
.SYNOPSIS
    Summarizes Invoke-HaloResponseAgent.ps1's logs over a time window, and
    compares before/after a change - cost and turns per ticket by tier,
    outcome markers, permission denials, errors, the most expensive runs.
.DESCRIPTION
    Read-only and free: it parses logs\run-*.log (and, with -IncludeWhatIf,
    whatif-*.log) and makes no model, Halo or network calls. Use it to judge
    a change to config.json (a model, an effort level, a pipeline flag such as
    client_reply_style) on real production cycles instead of a paid replay:

        # last 7 days, grouped by tier
        .\Compare-AgentLogs.ps1

        # before vs after a change made at 18:00 on Oct 1
        .\Compare-AgentLogs.ps1 -SplitAt "2026-10-01 18:00"

        # grouped by what the TICKET log line records
        .\Compare-AgentLogs.ps1 -By Model
        .\Compare-AgentLogs.ps1 -By Replies -Since "2026-10-01"

    Every figure comes from the log lines the agent already writes: the
    TICKET section's claude -p JSON (total_cost_usd, num_turns, usage,
    permission_denials, the result text and its [CACHE: ...] marker), its
    header (tier, model, prefetch, replies), and each cycle's CYCLE SUMMARY.
    The claude -p JSON carries no per-tool-call detail, so this cannot show
    which tool result was largest; the cache-read and output columns are the
    closest proxy (a run that read far more tokens per turn carried bigger
    tool results).
.PARAMETER Since
    Start of the window. Default: 7 days ago.
.PARAMETER Until
    End of the window. Default: now.
.PARAMETER SplitAt
    Compare runs before this moment with runs at or after it (the time you
    changed config.json). Each side gets its own table and a delta line.
.PARAMETER By
    How to group resolver runs: Tier (default), Model, Replies, Prefetch, Day.
.PARAMETER Top
    How many of the most expensive runs to list. Default 10; 0 hides the list.
.PARAMETER IncludeWhatIf
    Also read whatif-*.log (simulated runs). Off by default so simulations
    never mix into production numbers.
.PARAMETER CsvPath
    Also write one row per resolver run to this CSV, for Excel.
.PARAMETER LogDir
    Folder holding the logs. Default: .\logs next to this script.
#>

param(
    [datetime]$Since = (Get-Date).AddDays(-7),
    [datetime]$Until = (Get-Date),
    [Nullable[datetime]]$SplitAt = $null,
    [ValidateSet('Tier', 'Model', 'Replies', 'Prefetch', 'Day')]
    [string]$By = 'Tier',
    [int]$Top = 10,
    [switch]$IncludeWhatIf,
    [string]$CsvPath,
    [string]$LogDir = (Join-Path $PSScriptRoot "logs")
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not (Test-Path $LogDir)) { Write-Host "Log folder not found: $LogDir"; return }

# Log files are named by day; only open the ones that can overlap the window.
$patterns = @("run-*.log")
if ($IncludeWhatIf) { $patterns += "whatif-*.log" }
$files = @()
foreach ($p in $patterns) {
    foreach ($f in @(Get-ChildItem -Path $LogDir -Filter $p -ErrorAction SilentlyContinue)) {
        if ($f.BaseName -match '(\d{4}-\d{2}-\d{2})$') {
            $day = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd', $null)
            if ($day -ge $Since.Date -and $day -le $Until.Date) { $files += $f }
        }
    }
}
if ($files.Count -eq 0) { Write-Host "No logs in $LogDir between $($Since.ToString('yyyy-MM-dd HH:mm')) and $($Until.ToString('yyyy-MM-dd HH:mm'))."; return }

function Get-Num($v) { if ($null -eq $v -or "$v" -eq '') { return 0.0 } return [double]$v }

function Get-Median([double[]]$values) {
    if (-not $values -or $values.Count -eq 0) { return 0.0 }
    $s = @($values | Sort-Object)
    $n = $s.Count
    if ($n % 2 -eq 1) { return $s[[int][math]::Floor($n / 2)] }
    return ($s[$n / 2 - 1] + $s[$n / 2]) / 2
}

# --- Parse every cycle block into cycle records and resolver-run records ---
$cycles = New-Object System.Collections.ArrayList
$runs = New-Object System.Collections.ArrayList

foreach ($file in ($files | Sort-Object Name)) {
    $isWhatIf = $file.Name -like 'whatif-*'
    $raw = Get-Content -Path $file.FullName -Raw -Encoding UTF8
    foreach ($block in ($raw -split "(?m)^----\s*$")) {
        if (-not $block.Trim()) { continue }
        $lines = @($block -split "`r?`n")
        $headerLine = $lines | Where-Object { $_ -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]' } | Select-Object -First 1
        if (-not $headerLine) { continue }
        [void]($headerLine -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
        $when = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null)
        if ($when -lt $Since -or $when -gt $Until) { continue }

        $cycle = [PSCustomObject]@{
            When = $when; WhatIf = $isWhatIf; Skipped = ''; Errors = 0; Warnings = 0
            Total = 0.0; IdResolution = 0.0; Classifier = 0.0; Resolver = 0.0; Tickets = 0; HasSummary = $false
        }
        foreach ($l in $lines) {
            if ($l -match 'SKIPPED \(gate') { $cycle.Skipped = 'gate' }
            elseif ($l -match 'SKIPPED \(off-hours') { $cycle.Skipped = 'off-hours' }
            if ($l -match '^\[[^\]]+\] ERROR:' -or $l -match '^TICKET \d+ .*\) ERROR:') { $cycle.Errors++ }
            if ($l -match '^\[[^\]]+\] WARNING:') { $cycle.Warnings++ }
        }

        # Section boundaries: "=== TITLE ===" lines.
        $marks = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^===\s*(.+?)\s*===$') { $marks += [PSCustomObject]@{ Title = $matches[1]; Index = $i } }
        }
        for ($m = 0; $m -lt $marks.Count; $m++) {
            $title = $marks[$m].Title
            $end = if ($m -lt $marks.Count - 1) { $marks[$m + 1].Index - 1 } else { $lines.Count - 1 }
            $body = @()
            if ($end -gt $marks[$m].Index) { $body = @($lines[($marks[$m].Index + 1)..$end]) }
            # The section's JSON is the first line that starts with "{"; plain
            # lines the script appends after it (a missing-marker WARNING) are
            # read separately so they can't break the parse.
            $jsonLine = $body | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1
            $data = $null
            if ($jsonLine) { try { $data = $jsonLine | ConvertFrom-Json } catch { $data = $null } }

            if ($title -eq 'CYCLE SUMMARY' -and $data) {
                $cycle.HasSummary = $true
                $cycle.Total = Get-Num $data.total_cost_usd
                $cycle.IdResolution = Get-Num $data.id_resolution_cost_usd
                $cycle.Classifier = Get-Num $data.classifier_cost_usd
                $cycle.Resolver = Get-Num $data.resolver_cost_usd
                $cycle.Tickets = [int](Get-Num $data.tickets_found)
            }
            elseif ($title -match '^TICKET (\d+) \((.*)\)$') {
                $ticketId = $matches[1]
                $attrs = @{}
                foreach ($pair in ($matches[2] -split ',\s*')) {
                    if ($pair -match '^\s*([a-z ]+):\s*(.*)$') { $attrs[$matches[1].Trim()] = $matches[2].Trim() }
                }
                $prefetch = 'off'
                if ($attrs['prefetch'] -and $attrs['prefetch'] -notmatch '^off') { $prefetch = 'on' }
                $replies = if ($attrs['replies']) { $attrs['replies'] } else { 'detailed' }
                $marker = 'none'
                $resultText = ''
                if ($data -and $data.result) {
                    $resultText = [string]$data.result
                    $mk = [regex]::Matches($resultText, '\[CACHE:\s*([A-Z_]+)\]')
                    if ($mk.Count -gt 0) { $marker = $mk[$mk.Count - 1].Groups[1].Value }
                }
                $denied = @()
                if ($data -and $data.permission_denials) { $denied = @($data.permission_denials | ForEach-Object { [string]$_.tool_name }) }
                $usage = if ($data) { $data.usage } else { $null }
                $turns = if ($data) { [int](Get-Num $data.num_turns) } else { 0 }
                $cost = if ($data) { Get-Num $data.total_cost_usd } else { 0.0 }
                [void]$runs.Add([PSCustomObject]@{
                    When       = $when
                    Day        = $when.ToString('yyyy-MM-dd')
                    Ticket     = $ticketId
                    Tier       = $attrs['tier']
                    Model      = $attrs['model']
                    Prefetch   = $prefetch
                    Replies    = $replies
                    Cost       = $cost
                    Turns      = $turns
                    CacheRead  = if ($usage) { Get-Num $usage.cache_read_input_tokens } else { 0.0 }
                    CacheWrite = if ($usage) { Get-Num $usage.cache_creation_input_tokens } else { 0.0 }
                    Output     = if ($usage) { Get-Num $usage.output_tokens } else { 0.0 }
                    Seconds    = if ($data) { [math]::Round((Get-Num $data.duration_ms) / 1000, 0) } else { 0 }
                    Marker     = $marker
                    Denied     = $denied
                    IsError    = [bool]($data -and $data.is_error)
                    Parsed     = [bool]$data
                    ResultChars = $resultText.Length
                    WhatIf     = $isWhatIf
                })
            }
        }
        # A "no marker" warning sits after its TICKET section as a plain line.
        foreach ($l in $lines) {
            if ($l -match '^TICKET (\d+): WARNING - no \[CACHE') {
                $tid = $matches[1]
                $r = $runs | Where-Object { $_.Ticket -eq $tid -and $_.When -eq $when } | Select-Object -Last 1
                if ($r) { $r.Marker = 'none' }
            }
        }
        [void]$cycles.Add($cycle)
    }
}

# --- Output helpers ---
function Write-Title([string]$text) { Write-Host ""; Write-Host $text -ForegroundColor Cyan; Write-Host ("-" * $text.Length) -ForegroundColor DarkGray }

function Get-GroupKey($run, [string]$by) {
    switch ($by) {
        'Tier' { return [string]$run.Tier }
        'Model' { return [string]$run.Model }
        'Replies' { return [string]$run.Replies }
        'Prefetch' { return [string]$run.Prefetch }
        'Day' { return [string]$run.Day }
    }
}

function Get-RunStats($set) {
    $set = @($set)
    $n = $set.Count
    if ($n -eq 0) { return $null }
    $cost = ($set | Measure-Object Cost -Sum).Sum
    $turns = ($set | Measure-Object Turns -Sum).Sum
    return [PSCustomObject]@{
        Runs       = $n
        TotalCost  = $cost
        AvgCost    = $cost / $n
        MedCost    = Get-Median ([double[]]@($set | ForEach-Object { $_.Cost }))
        AvgTurns   = $turns / $n
        CostPerTurn = if ($turns -gt 0) { $cost / $turns } else { 0 }
        AvgReadK   = (($set | Measure-Object CacheRead -Sum).Sum / $n) / 1000
        AvgWriteK  = (($set | Measure-Object CacheWrite -Sum).Sum / $n) / 1000
        AvgOutK    = (($set | Measure-Object Output -Sum).Sum / $n) / 1000
        Over20     = @($set | Where-Object { $_.Turns -gt 20 }).Count
    }
}

function Write-RunTable($set, [string]$by) {
    $set = @($set)
    if ($set.Count -eq 0) { Write-Host "  (no resolver runs)"; return }
    $fmt = "  {0,-18} {1,5} {2,9} {3,8} {4,8} {5,6} {6,7} {7,8} {8,8} {9,7} {10,5}"
    Write-Host ($fmt -f $by, 'runs', 'total $', 'avg $', 'median $', 'turns', '$/turn', 'readK', 'writeK', 'outK', '>20t') -ForegroundColor DarkGray
    $rows = $set | Group-Object { Get-GroupKey $_ $by } | Sort-Object Name
    foreach ($g in $rows) {
        $s = Get-RunStats $g.Group
        Write-Host ($fmt -f $g.Name, $s.Runs, ('{0:N2}' -f $s.TotalCost), ('{0:N3}' -f $s.AvgCost), ('{0:N3}' -f $s.MedCost), ('{0:N1}' -f $s.AvgTurns), ('{0:N4}' -f $s.CostPerTurn), ('{0:N0}' -f $s.AvgReadK), ('{0:N1}' -f $s.AvgWriteK), ('{0:N1}' -f $s.AvgOutK), $s.Over20)
    }
    $t = Get-RunStats $set
    Write-Host ($fmt -f 'ALL', $t.Runs, ('{0:N2}' -f $t.TotalCost), ('{0:N3}' -f $t.AvgCost), ('{0:N3}' -f $t.MedCost), ('{0:N1}' -f $t.AvgTurns), ('{0:N4}' -f $t.CostPerTurn), ('{0:N0}' -f $t.AvgReadK), ('{0:N1}' -f $t.AvgWriteK), ('{0:N1}' -f $t.AvgOutK), $t.Over20) -ForegroundColor White
}

function Write-CycleSummary($cycleSet, $runSet) {
    $cycleSet = @($cycleSet); $runSet = @($runSet)
    $real = @($cycleSet | Where-Object { -not $_.Skipped })
    $ordered = @($cycleSet | Sort-Object When)
    $days = [math]::Max(1.0, ($ordered[-1].When - $ordered[0].When).TotalDays)
    $total = ($cycleSet | Measure-Object Total -Sum).Sum
    Write-Host ("  Cycles: {0} ({1} skipped by the gate, {2} by the off-hours throttle, {3} ran)   Errors: {4}   Warnings: {5}" -f `
        $cycleSet.Count, @($cycleSet | Where-Object { $_.Skipped -eq 'gate' }).Count, @($cycleSet | Where-Object { $_.Skipped -eq 'off-hours' }).Count, $real.Count, `
        ($cycleSet | Measure-Object Errors -Sum).Sum, ($cycleSet | Measure-Object Warnings -Sum).Sum)
    Write-Host ("  Spend: {0:N2} total = ID resolution {1:N2} + classifier {2:N2} + resolver {3:N2}   (~{4:N2} per day over {5:N1} days)" -f `
        $total, ($cycleSet | Measure-Object IdResolution -Sum).Sum, ($cycleSet | Measure-Object Classifier -Sum).Sum, ($cycleSet | Measure-Object Resolver -Sum).Sum, ($total / $days), $days)
    $markers = $runSet | Group-Object Marker | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }
    if ($markers) { Write-Host "  Outcomes ([CACHE: ...] marker): $($markers -join ', ')" }
    $errs = @($runSet | Where-Object { $_.IsError -or -not $_.Parsed }).Count
    if ($errs) { Write-Host "  Resolver runs with an error or unreadable output: $errs" -ForegroundColor Yellow }
    $den = @($runSet | ForEach-Object { $_.Denied } | Where-Object { $_ })
    if ($den.Count -gt 0) {
        Write-Host "  Permission denials: $($den.Count) - $((($den | Group-Object | Sort-Object Count -Descending | Select-Object -First 8) | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', ')" -ForegroundColor Yellow
    }
    else { Write-Host "  Permission denials: none" }
}

$windowText = "$($Since.ToString('yyyy-MM-dd HH:mm')) to $($Until.ToString('yyyy-MM-dd HH:mm'))"
Write-Host ""
Write-Host "Compare-AgentLogs - $windowText - $($files.Count) log file(s)$(if ($IncludeWhatIf) { ' (including WhatIf)' })" -ForegroundColor Green
Write-Host "Resolver costs are what claude -p reported (total_cost_usd). readK/writeK/outK are average cache-read, cache-write and output tokens per run, in thousands; >20t counts runs over 20 turns." -ForegroundColor DarkGray

if ($SplitAt) {
    $split = [datetime]$SplitAt
    $sides = @(
        @{ Name = "BEFORE $($split.ToString('yyyy-MM-dd HH:mm'))"; Cycles = @($cycles | Where-Object { $_.When -lt $split }); Runs = @($runs | Where-Object { $_.When -lt $split }) },
        @{ Name = "AFTER  $($split.ToString('yyyy-MM-dd HH:mm'))"; Cycles = @($cycles | Where-Object { $_.When -ge $split }); Runs = @($runs | Where-Object { $_.When -ge $split }) }
    )
    foreach ($side in $sides) {
        Write-Title $side.Name
        if ($side.Cycles.Count -eq 0) { Write-Host "  (no cycles)"; continue }
        Write-CycleSummary $side.Cycles $side.Runs
        Write-Host ""
        Write-RunTable $side.Runs $By
    }
    $a = Get-RunStats $sides[0].Runs; $b = Get-RunStats $sides[1].Runs
    if ($a -and $b) {
        Write-Title "CHANGE (after vs before, per resolver run)"
        $pct = { param($x, $y) if ($x -eq 0) { 'n/a' } else { '{0:+0;-0;0}%' -f ((($y - $x) / $x) * 100) } }
        Write-Host ("  avg cost {0:N3} -> {1:N3} ({2})   median {3:N3} -> {4:N3} ({5})" -f $a.AvgCost, $b.AvgCost, (& $pct $a.AvgCost $b.AvgCost), $a.MedCost, $b.MedCost, (& $pct $a.MedCost $b.MedCost))
        Write-Host ("  turns {0:N1} -> {1:N1} ({2})   cost/turn {3:N4} -> {4:N4} ({5})" -f $a.AvgTurns, $b.AvgTurns, (& $pct $a.AvgTurns $b.AvgTurns), $a.CostPerTurn, $b.CostPerTurn, (& $pct $a.CostPerTurn $b.CostPerTurn))
        Write-Host ("  output {0:N1}K -> {1:N1}K ({2})   cache write {3:N1}K -> {4:N1}K ({5})" -f $a.AvgOutK, $b.AvgOutK, (& $pct $a.AvgOutK $b.AvgOutK), $a.AvgWriteK, $b.AvgWriteK, (& $pct $a.AvgWriteK $b.AvgWriteK))
        if ($a.Runs -lt 10 -or $b.Runs -lt 10) { Write-Host "  Fewer than 10 runs on a side - treat these as noise, not a result." -ForegroundColor Yellow }
    }
}
else {
    Write-Title "SUMMARY"
    Write-CycleSummary $cycles $runs
    Write-Title "RESOLVER RUNS BY $($By.ToUpper())"
    Write-RunTable $runs $By
}

# Tickets the resolver ran more than once in the window: re-evaluations,
# revisions after a human note, and the approved send all show up here.
$repeats = @($runs | Group-Object Ticket | Where-Object { $_.Count -gt 1 } | Sort-Object { ($_.Group | Measure-Object Cost -Sum).Sum } -Descending)
if ($repeats.Count -gt 0) {
    Write-Title "TICKETS RUN MORE THAN ONCE ($($repeats.Count))"
    foreach ($g in ($repeats | Select-Object -First 10)) {
        $path = ($g.Group | Sort-Object When | ForEach-Object { "$($_.Tier)/$($_.Marker)" }) -join ' > '
        Write-Host ("  #{0}  {1} runs  {2:N2} total   {3}" -f $g.Name, $g.Count, ($g.Group | Measure-Object Cost -Sum).Sum, $path)
    }
}

if ($Top -gt 0 -and $runs.Count -gt 0) {
    Write-Title "MOST EXPENSIVE RUNS"
    foreach ($r in ($runs | Sort-Object Cost -Descending | Select-Object -First $Top)) {
        Write-Host ("  {0}  #{1,-6} {2,-17} {3,-18} {4,7:N3}  {5,3} turns  read {6,5:N0}K  out {7,4:N1}K  {8}" -f $r.When.ToString('MM-dd HH:mm'), $r.Ticket, $r.Tier, $r.Model, $r.Cost, $r.Turns, ($r.CacheRead / 1000), ($r.Output / 1000), $r.Marker)
    }
}

if ($CsvPath) {
    $runs | Select-Object When, Ticket, Tier, Model, Prefetch, Replies, Cost, Turns, CacheRead, CacheWrite, Output, Seconds, Marker, @{ n = 'Denied'; e = { $_.Denied -join ';' } }, IsError, WhatIf |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Wrote $($runs.Count) run(s) to $CsvPath" -ForegroundColor Green
}
Write-Host ""
