<#
.SYNOPSIS
    Replays a fixed set of past tickets through the resolver (read-only) and
    scores the results against a rubric - the evaluation harness for the
    cost/speed program, so a prompt, model, or pipeline change can be judged
    on real tickets before it goes live.
.DESCRIPTION
    Reads eval\tickets.json (or -TicketListPath), runs
    Invoke-HaloResponseAgent.ps1 -ReplayTicketIds once per ticket (always a
    -WhatIf simulation - nothing is written to Halo, a device, Hudu, or
    agent-cache.json), then scores each ticket's WOULD-DO output against its
    rubric and writes eval\results\<Label>\summary.json.

    Rubric fields per ticket in tickets.json:
      ticket_id         - the Halo ticket to replay
      tier              - the tier to run it at (what the classifier assigned
                          originally, or what it should have)
      as_of             - optional Halo-time timestamp; actions after it are
                          ignored so the ticket is judged as it stood then
      notes             - free text for humans, not used in scoring
      must_mention      - regex list; every one must match the output (FAIL otherwise)
      must_not_mention  - regex list; none may match the output (FAIL otherwise)
      should_mention    - regex list; a miss is a WARN, not a fail
      reply_must_mention / reply_must_not_mention
                        - same, but checked ONLY against the client-facing
                          reply text: every segment from "Hi <name>," to the
                          mandated "Here to help" sign-off. A rubric that has
                          either and finds no such segment is a FAIL. This is
                          how "the internal note said the right thing but the
                          client got a vague holding reply" is caught (v2.11.4).
      expected_marker   - list; a run that ends [CACHE: HUMAN_OWNED] or
                          [CACHE: BLOCKED] never investigated and is a FAIL
                          unless that marker is listed here
      keep_own_actions  - true to keep this pipeline's own notes dated at or
                          before as_of in play (default: hidden, so the
                          ticket is judged as a fresh first pass). For a
                          draft-revision (FLOW B) scenario - which only
                          works while the draft note still exists in Halo:
                          FLOW B deletes a superseded draft and FLOW A
                          collapses an approved one, so a past ticket's
                          draft state is usually gone (a real attempt on
                          #22067 found no draft and correctly BLOCKED).

    Reading results: the resolver is not deterministic. One ticket flipping
    PASS<->FAIL between two runs with no change in between is noise (seen
    on #22265). Judge a change on the whole list's pass count and cost,
    and re-run any single ticket whose delta you're about to act on.

    Every replayed ticket is a real resolver call at real API cost (roughly
    $0.15-$0.90 each at current settings) - this is why it only ever runs
    when a human invokes it, never on a schedule.

    Compare two runs with -CompareTo: run the same list once as
    -Label baseline (current settings), change something, run it again as
    -Label after, then `Replay-Tickets.ps1 -Label after -CompareTo baseline
    -ScoreOnly` prints per-ticket and total deltas without spending anything.
.PARAMETER RootPath
    The deployment folder (where Invoke-HaloResponseAgent.ps1 and config.json
    live). Defaults to this script's own folder.
.PARAMETER TicketListPath
    The rubric file. Defaults to eval\tickets.json under RootPath.
.PARAMETER TicketIds
    Optional subset of ticket IDs from the list to run (e.g. one ticket while
    iterating on a rubric).
.PARAMETER Label
    Name for this run's results folder (eval\results\<Label>\). Use something
    that says what was being tested: baseline, prefetch-on, playbooks-v1.
.PARAMETER CompareTo
    Another run's label to print deltas against.
.PARAMETER ScoreOnly
    Don't replay anything - just (re)score whatever results already exist
    under eval\results\<Label>\ (free; useful after editing a rubric).
.PARAMETER RequireApproval
    Replay in human-approval mode (the main script's -RequireApproval: drafts
    are held, FLOW A/FLOW B apply). When this switch is NOT given, the
    wrapper reads the registered scheduled task ("Altec Halo Response Agent")
    and mirrors whatever mode production actually runs in, so a replay judges
    the same flow the live pipeline follows. Pass -RequireApproval:$false to
    force the non-approval flow regardless.
#>
param(
    [string]$RootPath = $PSScriptRoot,
    [string]$TicketListPath,
    [int[]]$TicketIds,
    [string]$Label = "baseline",
    [string]$CompareTo,
    [switch]$ScoreOnly,
    [switch]$RequireApproval
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$Label = ($Label -replace '[^A-Za-z0-9_.-]', '_')
if (-not $TicketListPath) { $TicketListPath = Join-Path (Join-Path $RootPath "eval") "tickets.json" }
if (-not (Test-Path $TicketListPath)) { throw "Ticket list not found: $TicketListPath - create it (see eval\tickets.json in the repo for the format)." }

$mainScript = Join-Path $RootPath "Invoke-HaloResponseAgent.ps1"
if (-not (Test-Path $mainScript)) { throw "Invoke-HaloResponseAgent.ps1 not found in $RootPath." }

$resultsRoot = Join-Path (Join-Path $RootPath "eval") "results"
$resultsDir = Join-Path $resultsRoot $Label

# -Encoding UTF8 + -Raw: same reasoning as every other file this project
# reads (Windows PowerShell 5.1 defaults a BOM-less file to the legacy
# codepage and mangles non-ASCII).
$list = Get-Content $TicketListPath -Raw -Encoding UTF8 | ConvertFrom-Json
$rubrics = @($list.tickets)
if ($TicketIds -and $TicketIds.Count -gt 0) {
    $rubrics = @($rubrics | Where-Object { $TicketIds -contains [int]$_.ticket_id })
}
if ($rubrics.Count -eq 0) { throw "No tickets to run - the list is empty or -TicketIds matched nothing." }

function Get-RubricList {
    param($Rubric, [string]$Name)
    $prop = $Rubric.PSObject.Properties[$Name]
    if (-not $prop -or $null -eq $prop.Value) { return @() }
    return @($prop.Value)
}

# The client-facing reply is the only part of the output a client would ever
# see, and the resolver's mandated sign-off makes it findable: every reply
# runs from a "Hi <name>," greeting to "Here to help". Everything else in the
# output (investigation summary, internal note, WOULD-DO list) is excluded
# from the reply_* checks. Returns the joined segments, or "" if none.
function Get-ClientReplyText {
    param([string]$Text)
    if (-not $Text) { return "" }
    $segments = [regex]::Matches($Text, '(?is)\bHi [^,\r\n]{1,60},(.*?)Here to help')
    if ($segments.Count -eq 0) { return "" }
    return (($segments | ForEach-Object { $_.Groups[1].Value }) -join "`n---`n")
}

# --- Approval mode: mirror production unless told otherwise (v2.11.4) ---
# The first baseline ran every ticket without -RequireApproval while the
# scheduled task runs with it, so the replay judged a flow production never
# takes. If the switch wasn't given on the command line, read the registered
# task's arguments; anywhere Get-ScheduledTask doesn't exist (or the task
# isn't registered) the mode stays off and the output says so.
$approvalSource = "command line"
if (-not $PSBoundParameters.ContainsKey('RequireApproval')) {
    $approvalSource = "not detected (no scheduled task found) - running WITHOUT -RequireApproval"
    try {
        if (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) {
            $task = Get-ScheduledTask -TaskName "Altec Halo Response Agent" -ErrorAction Stop
            $taskArgs = ($task.Actions | ForEach-Object { [string]$_.Arguments }) -join " "
            $RequireApproval = [switch]($taskArgs -match '(?i)-RequireApproval')
            $approvalSource = "mirrored from scheduled task 'Altec Halo Response Agent'"
        }
    }
    catch { }
}

if (-not $ScoreOnly) {
    Write-Host "=== REPLAY '$Label' - $($rubrics.Count) ticket(s), read-only simulation, real API cost (roughly `$0.15-`$0.90 per ticket) ==="
    Write-Host "Approval mode: $(if ($RequireApproval) { 'ON (-RequireApproval)' } else { 'OFF' }) - $approvalSource"
    foreach ($r in $rubrics) {
        $tier = if ($r.tier) { [string]$r.tier } else { "MEDIUM" }
        # ConvertFrom-Json turns an ISO-8601 string into a [datetime]; keep
        # the as-of in ISO form for the banner rather than a culture-formatted
        # "09/17/2026 12:30:00" (seen in a stub test), which the resolver has
        # to guess the day/month order of.
        $asOf = ""
        if ($r.as_of) {
            if ($r.as_of -is [datetime]) { $asOf = ([datetime]$r.as_of).ToString("yyyy-MM-ddTHH:mm:ss") }
            else { $asOf = [string]$r.as_of }
        }
        Write-Host ("--- ticket {0} (tier {1}{2}) ---" -f $r.ticket_id, $tier, $(if ($asOf) { ", as of $asOf" } else { "" }))
        # Hashtable splat, deliberately: splatting an ARRAY into a PowerShell
        # script binds its elements positionally, not by name - a real first
        # run did exactly that and bound the deployment folder path to
        # -ReplayTicketIds on every ticket. (Also never name a variable
        # $args - it's PowerShell's own automatic variable.)
        $replayArgs = @{
            RootPath        = $RootPath
            ReplayTicketIds = @([int]$r.ticket_id)
            ReplayTier      = $tier
            ReplayLabel     = $Label
        }
        if ($asOf) { $replayArgs.ReplayAsOf = $asOf }
        if ($RequireApproval) { $replayArgs.RequireApproval = $true }
        if ($r.PSObject.Properties['keep_own_actions'] -and [bool]$r.keep_own_actions) { $replayArgs.ReplayKeepOwnActions = $true }
        try {
            & $mainScript @replayArgs *>&1 | ForEach-Object { Write-Host "    $_" }
        }
        catch {
            Write-Host "    ERROR: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# --- Score ---
if (-not (Test-Path $resultsDir)) { throw "No results folder at $resultsDir - nothing to score." }

$rows = @()
foreach ($r in $rubrics) {
    $path = Join-Path $resultsDir "$($r.ticket_id).json"
    $row = [PSCustomObject]@{
        ticket_id   = [int]$r.ticket_id
        tier        = $r.tier
        status      = "MISSING"
        cost_usd    = 0
        num_turns   = $null
        seconds     = $null
        failed      = @()
        warnings    = @()
        notes       = $r.notes
    }
    if (Test-Path $path) {
        $res = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $text = [string]$res.result
        $row.cost_usd = [double]$res.cost_usd
        $row.num_turns = $res.num_turns
        if ($res.duration_ms) { $row.seconds = [math]::Round(([double]$res.duration_ms) / 1000, 0) }
        if ($res.is_error) {
            $row.status = "ERROR"
            $row.failed = @("run error: $($res.error)")
        }
        else {
            $failed = @()
            $warnings = @()
            # A replay that ended on HUMAN_OWNED or BLOCKED never investigated -
            # it stopped at an ownership/platform check - so it can't have
            # earned a PASS on content, however the regexes happen to match
            # its stop summary. A rubric that genuinely expects that outcome
            # lists it in expected_marker (e.g. ["HUMAN_OWNED"]).
            $marker = [string]$res.cache_marker
            $row | Add-Member -NotePropertyName marker -NotePropertyValue $marker -Force
            $expectedMarkers = @(Get-RubricList -Rubric $r -Name 'expected_marker' | ForEach-Object { ([string]$_).ToUpperInvariant() })
            if (@('HUMAN_OWNED', 'BLOCKED') -contains $marker.ToUpperInvariant() -and $expectedMarkers -notcontains $marker.ToUpperInvariant()) {
                $failed += "ended without investigating: [CACHE: $marker]"
            }
            foreach ($pattern in (Get-RubricList -Rubric $r -Name 'must_mention')) {
                if (-not [regex]::IsMatch($text, [string]$pattern, 'IgnoreCase')) { $failed += "missing: $pattern" }
            }
            foreach ($pattern in (Get-RubricList -Rubric $r -Name 'must_not_mention')) {
                if ([regex]::IsMatch($text, [string]$pattern, 'IgnoreCase')) { $failed += "present: $pattern" }
            }
            foreach ($pattern in (Get-RubricList -Rubric $r -Name 'should_mention')) {
                if (-not [regex]::IsMatch($text, [string]$pattern, 'IgnoreCase')) { $warnings += "missing: $pattern" }
            }
            $replyMust = @(Get-RubricList -Rubric $r -Name 'reply_must_mention')
            $replyMustNot = @(Get-RubricList -Rubric $r -Name 'reply_must_not_mention')
            if ($replyMust.Count -gt 0 -or $replyMustNot.Count -gt 0) {
                $replyText = Get-ClientReplyText -Text $text
                if (-not $replyText) {
                    $failed += "no client-facing reply found (Hi <name>, ... Here to help)"
                }
                else {
                    foreach ($pattern in $replyMust) {
                        if (-not [regex]::IsMatch($replyText, [string]$pattern, 'IgnoreCase')) { $failed += "reply missing: $pattern" }
                    }
                    foreach ($pattern in $replyMustNot) {
                        if ([regex]::IsMatch($replyText, [string]$pattern, 'IgnoreCase')) { $failed += "reply contains: $pattern" }
                    }
                }
            }
            $row.failed = $failed
            $row.warnings = $warnings
            $row.status = if ($failed.Count -gt 0) { "FAIL" } else { "PASS" }
        }
    }
    $rows += $row
}

$passCount = @($rows | Where-Object { $_.status -eq 'PASS' }).Count
$totalCost = [math]::Round(($rows | Measure-Object -Property cost_usd -Sum).Sum, 2)

Write-Host ""
Write-Host "=== RESULTS '$Label' - $passCount / $($rows.Count) pass, total `$$totalCost ==="
Write-Host ("{0,-8} {1,-18} {2,-7} {3,7} {4,6} {5,5}  {6}" -f "ticket", "tier", "status", "cost", "turns", "sec", "checks")
foreach ($row in $rows) {
    $checks = @($row.failed + ($row.warnings | ForEach-Object { "warn $_" })) -join "; "
    Write-Host ("{0,-8} {1,-18} {2,-7} {3,7:N2} {4,6} {5,5}  {6}" -f $row.ticket_id, $row.tier, $row.status, $row.cost_usd, $row.num_turns, $row.seconds, $checks)
}

$summary = [PSCustomObject]@{
    label      = $Label
    scored_at  = (Get-Date).ToString("o")
    require_approval = [bool]$RequireApproval
    approval_source  = $approvalSource
    pass_count = $passCount
    ticket_count = $rows.Count
    total_cost_usd = $totalCost
    tickets    = $rows
}
$summaryPath = Join-Path $resultsDir "summary.json"
$summary | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host "Summary written to $summaryPath"

if ($CompareTo) {
    $otherPath = Join-Path (Join-Path $resultsRoot $CompareTo) "summary.json"
    if (-not (Test-Path $otherPath)) { throw "Nothing to compare to: $otherPath does not exist (run or score '$CompareTo' first)." }
    $other = Get-Content $otherPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $otherRows = @{}
    foreach ($o in @($other.tickets)) { $otherRows[[string]$o.ticket_id] = $o }
    Write-Host ""
    Write-Host "=== '$Label' vs '$CompareTo' ==="
    Write-Host ("{0,-8} {1,-14} {2,10} {3,8}" -f "ticket", "status", "cost diff", "turns")
    foreach ($row in $rows) {
        $o = $otherRows[[string]$row.ticket_id]
        if (-not $o) { Write-Host ("{0,-8} {1,-14} {2,10} {3,8}" -f $row.ticket_id, "$($row.status) (new)", "", ""); continue }
        $costDiff = [math]::Round($row.cost_usd - [double]$o.cost_usd, 2)
        $turnsText = "$($o.num_turns)->$($row.num_turns)"
        Write-Host ("{0,-8} {1,-14} {2,10:+0.00;-0.00;0.00} {3,8}" -f $row.ticket_id, "$($o.status)->$($row.status)", $costDiff, $turnsText)
    }
    $costDelta = [math]::Round($totalCost - [double]$other.total_cost_usd, 2)
    Write-Host ("TOTAL: pass {0}->{1}, cost {2:N2}->{3:N2} ({4:+0.00;-0.00;0.00})" -f $other.pass_count, $passCount, [double]$other.total_cost_usd, $totalCost, $costDelta)
}
