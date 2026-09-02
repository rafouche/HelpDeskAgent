<#
.SYNOPSIS
    Runs the Altec Halo Response Agent (Claude Code, headless) for one cycle.
.DESCRIPTION
    Two-stage pipeline per cycle:
      1. CLASSIFIER - one cheap claude -p call (read-only Halo tools, Haiku model)
         finds this cycle's candidate tickets and tags each with a complexity tier.
      2. RESOLVER - one claude -p call PER classified ticket, with the full MCP tool
         set and a model chosen by that ticket's tier, does the actual investigation
         and (outside -WhatIf) the actual reply/remediation/escalation.
    This replaces the earlier design where one claude -p call handled every ticket
    itself in a single agentic session - see CLAUDE.md for why (a cheap model can
    triage; only tickets that need it should pay for a bigger one and a full tool
    loop).
.PARAMETER RootPath
    Folder containing config.json, classifier-prompt.md, and resolver-prompt.md.
    Defaults to the folder this script itself is sitting in, so as long as all
    files stay together, you never need to pass this - just run
    `.\Invoke-HaloResponseAgent.ps1` with no arguments, whether by hand, from Task
    Scheduler, or anywhere else.
.PARAMETER DryRun
    Print what would be run without calling claude at all - no prompt, no tool
    calls, nothing live. Shows the classifier's resolved prompt/tools/model, and
    the resolver's prompt template/tools/tier-to-model mapping (ticket ID and tier
    stay as unresolved placeholders here, since no classifier call happened to
    supply real ones).
.PARAMETER WhatIf
    Run for real against live Halo/Ninja/M365/etc. data - the classifier runs
    exactly as it always would (it's read-only regardless), but every resolver
    call has every tool that changes anything (ticket replies/status/assignment,
    on-call notifications, reboots, script runs, password resets, Hudu writes)
    removed from its allowlist and swapped for an instruction to describe what it
    would have done instead. Nothing is touched anywhere. This is the one to use
    to see real decisions on real tickets before trusting the schedule; -DryRun
    only checks the prompt/tool list resolve correctly, it never calls Claude.
.NOTES
    Version: 2.0.0 - two-stage classifier/resolver pipeline. Previous versions
    (implicit v1.x) ran one claude -p call per cycle that handled every ticket
    itself in a single session.
#>

param(
    [string]$RootPath = $PSScriptRoot,
    [switch]$DryRun,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 captures external-process output using the console's
# legacy OEM/ANSI codepage by default, not UTF-8 - claude's own output is UTF-8
# (em dashes, curly quotes, emoji in its replies), so without this the captured
# text and the log file it's written to end up permanently mangled (e.g. an em
# dash becomes "GCo"). Setting both encodings to UTF-8 before invoking claude
# fixes this for the whole session.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$configPath           = Join-Path $RootPath "config.json"
$classifierPromptPath = Join-Path $RootPath "classifier-prompt.md"
$resolverPromptPath   = Join-Path $RootPath "resolver-prompt.md"
$logDir               = Join-Path $RootPath "logs"

$logFileNameTemplate = "run-{0:yyyy-MM-dd}.log"
if ($WhatIf) {
    $logFileNameTemplate = "whatif-{0:yyyy-MM-dd}.log"
}
$logFile = Join-Path $logDir ($logFileNameTemplate -f (Get-Date))

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# --- Load config (used for business-hours math and cost/model settings; the
#     agent itself reads the rest of config.json directly via the Read tool) ---
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# --- Determine business-hours context ---
$now = Get-Date
$isBusinessDay = $config.business_hours.days -contains $now.DayOfWeek.ToString()
$startTod = [TimeSpan]::Parse($config.business_hours.start)
$endTod   = [TimeSpan]::Parse($config.business_hours.end)
$isBusinessHours = $isBusinessDay -and ($now.TimeOfDay -ge $startTod) -and ($now.TimeOfDay -le $endTod)
$nowText = $now.ToString("dddd, MMMM d, yyyy h:mm tt")

#region STATIC TOOL ALLOWLISTS - rarely edited
# IMPORTANT: Claude Code matches MCP tools as "mcp__<ServerName>__<tool>" - the
# ServerName is whatever exact name you used with `claude mcp add <name> ...` on
# THIS machine (case-sensitive; check yours with `claude mcp list`). A bare
# "ServerName:tool" string never matches anything and --permission-mode dontAsk
# denies it *silently* - if you add a new system and tool calls seem to just do
# nothing, this is the first thing to check.

# Classifier: read-only, just enough to find and skim candidate tickets. Never
# touched by -WhatIf, since it can't mutate anything to begin with.
$classifierTools = @(
    "Read",
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket",
    "mcp__Halo__list_teams", "mcp__Halo__list_statuses", "mcp__Halo__list_priorities",
    "mcp__Halo__list_agents"
)

# Resolver: the full tool set - everything a ticket might need to be diagnosed
# or (within the remediation whitelist) fixed. Add a line here only when
# introducing a brand-new SYSTEM or a brand-new KIND of action (e.g. the agent
# should now also touch UniFi firewall rules). A new instance of something
# already listed here (another NinjaOne script, another M365 action of a type
# already present) only needs a config.json entry - nothing here. See README's
# "Adding a new system" section for the full walkthrough.
$resolverTools = @(
    "Read",

    # --- Halo: read + reply/update + name-to-ID lookups ---
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket", "mcp__Halo__get_ticket_time_entries",
    "mcp__Halo__list_kb_articles", "mcp__Halo__get_kb_article",
    "mcp__Halo__update_ticket", "mcp__Halo__list_teams", "mcp__Halo__list_statuses", "mcp__Halo__list_priorities",
    "mcp__Halo__list_agents",

    # --- Notifications ---
    # NOTE: no "Microsoft365" server is registered on this machine yet (absent
    # from `claude mcp list`) - register it first (README's "Registering MCP
    # servers" section; use a name with no spaces, e.g. `claude mcp add
    # Microsoft365 ...`, so it matches this prefix exactly). Until then these two
    # entries are harmless no-ops, and on-call email plus the NDR bounce fallback
    # do not work.
    "mcp__Microsoft365__outlook_send_mail", "mcp__Microsoft365__outlook_email_search",

    # --- M365 / CIPP identity: read + the two whitelisted remediation actions ---
    # Server registered here as "CIPP" (cipp-mcp.young-math-a33a.workers.dev) -
    # this is still the ORIGINAL custom CIPP Worker; the migration to CIPP-ng's
    # built-in MCP (cipp.altecusa.com) hasn't been cut over on this machine yet.
    # Once you register the CIPP-ng server and are ready to switch, update the
    # server name here (and re-verify these tool names against it) - see
    # README's "CIPP MCP swap" section.
    "mcp__CIPP__get_user", "mcp__CIPP__healthcheck", "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    # Email delivery diagnostics via CIPP's generic read-endpoint wrapper
    # (endpoint "ListMessageTrace" - see resolver-prompt.md). Falls back to
    # outlook_email_search when that doesn't turn up enough.
    "mcp__CIPP__cipp_api_get",

    # --- NinjaOne: read + reboot + run-script + script lookup by name ---
    "mcp__Ninja__get_device", "mcp__Ninja__get_device_os_info", "mcp__Ninja__get_device_software",
    "mcp__Ninja__list_device_alerts", "mcp__Ninja__get_device_os_patches", "mcp__Ninja__list_devices",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device", "mcp__Ninja__list_automation_scripts",

    # --- Network, read-only ---
    "mcp__Unifi__list_clients", "mcp__Unifi__get_device", "mcp__Unifi__list_devices",
    "mcp__Meraki__get_network_client", "mcp__Meraki__list_org_device_statuses",

    # --- Security context, read-only ---
    "mcp__Huntress__list_incident_reports", "mcp__Huntress__get_agent",

    # --- Documentation, read-only (also where per-client 3CX connection details
    #     would live once that system is added - see README) ---
    # NOTE: registered here as "HUDU" (all caps).
    "mcp__HUDU__asset_index_tool", "mcp__HUDU__asset_show_tool", "mcp__HUDU__article_index_tool", "mcp__HUDU__article_show_tool",
    # article_folder_index_tool: lets the agent list a folder's contents directly
    # (config's hudu_fix_folder_name) instead of relying only on keyword search,
    # which can miss an existing fix article that doesn't share search terms.
    "mcp__HUDU__article_folder_index_tool",
    # --- Documentation, write. Only ever writes to the "AI-Documented Fixes" folder
    #     from config.json (never edits client-facing docs), so this doesn't need a
    #     remediation_whitelist entry - it never touches a client's live systems. ---
    "mcp__HUDU__article_create_tool", "mcp__HUDU__article_edit_tool"
)
# --- 3CX (not yet built): add its tool names as their own block inside the array
#     above once the multi-tenant 3CX MCP worker exists, e.g.
#     "3CX:get_extension_status", "3CX:list_call_logs" - nothing else above needs
#     to change. (Kept as a comment here, not inside the array literal, since
#     Windows PowerShell 5.1's parser breaks on a comment-only tail immediately
#     before an array's closing ')' - always follow any comment inside @( ... )
#     with at least one more real element before the close.)

# Keep this list in sync with $resolverTools above whenever a new mutating tool
# is added (a new remediation action reuses an existing entry here, so it's rare).
$mutatingTools = @(
    "mcp__Halo__update_ticket",
    "mcp__Microsoft365__outlook_send_mail",
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device",
    "mcp__HUDU__article_create_tool", "mcp__HUDU__article_edit_tool"
)

if ($WhatIf) {
    $resolverTools = $resolverTools | Where-Object { $mutatingTools -notcontains $_ }
}
#endregion STATIC TOOL ALLOWLISTS

$simulationBannerLines = @(
    "=== SIMULATION MODE (-WhatIf) ===",
    "Nothing you do this run will actually happen - every tool that changes a ticket,",
    "sends a notification, or touches a client system has been removed from your",
    "allowlist on purpose. Do the full investigation exactly as normal, then instead",
    "of calling the tool you'd normally use to act, state plainly what you WOULD have",
    "done: the exact reply text, which status/team/agent_id you'd set, any",
    "remediation action and its whitelist justification, any on-call notification,",
    "any Hudu article. Label each one clearly as 'WOULD DO:' so it's obvious this is",
    "a simulation. Do not attempt to call a tool you no longer have - if",
    "investigation alone can't rule out an action, just say so.",
    "==="
)
$simulationBanner = $simulationBannerLines -join "`n"

# --- Model selection per tier (config-driven, see config.json's "claude" block) ---
$modelForTier = @{
    "TRIVIAL"           = $config.claude.resolver_model_trivial
    "TRIVIAL_UNCERTAIN" = $config.claude.resolver_model_trivial
    "MEDIUM"            = $config.claude.resolver_model_medium
    "COMPLEX"           = $config.claude.resolver_model_complex
}

function Get-CleanJsonText {
    param([string]$Text)
    $trimmed = $Text.Trim()
    if ($trimmed.StartsWith('```')) {
        # drop the opening fence line (``` or ```json) and a trailing ``` line if
        # present. Guarded with Count checks before every range slice - PowerShell's
        # ".." operator returns a DESCENDING sequence (not empty) when start > end,
        # which would misbehave here on a single-line fenced response.
        $lines = @($trimmed -split "`r?`n")
        if ($lines.Count -gt 1) {
            $lines = $lines[1..($lines.Count - 1)]
        }
        else {
            $lines = @()
        }
        if ($lines.Count -gt 0 -and $lines[-1].Trim() -eq '```') {
            if ($lines.Count -gt 1) {
                $lines = $lines[0..($lines.Count - 2)]
            }
            else {
                $lines = @()
            }
        }
        $trimmed = ($lines -join "`n").Trim()
    }
    return $trimmed
}

function Invoke-ClaudeCLI {
    param(
        [string]$Prompt,
        [string[]]$Tools,
        [string]$Model,
        [string]$Effort
    )
    $toolsArg = ($Tools -join ",")
    $claudeArgs = @(
        "-p", $Prompt,
        "--allowedTools", $toolsArg,
        "--output-format", "json",
        "--permission-mode", "dontAsk"
    )
    if ($Model)  { $claudeArgs += @("--model", $Model) }
    if ($Effort) { $claudeArgs += @("--effort", $Effort) }

    $rawOutput = & claude @claudeArgs 2>&1
    $rawText = $rawOutput | Out-String

    $parsed = $null
    try {
        $parsed = $rawText | ConvertFrom-Json
    }
    catch {
        # leave $parsed as $null - caller decides how to handle an unparsed response
    }

    return [PSCustomObject]@{
        Raw    = $rawText
        Parsed = $parsed
    }
}

function Write-LogSection {
    param(
        [string]$LogFile,
        [string]$Header,
        [string]$Content
    )
    Add-Content -Path $LogFile -Value "=== $Header ===" -Encoding UTF8
    Add-Content -Path $LogFile -Value $Content -Encoding UTF8
}

# --- Build the classifier prompt ---
$classifierPromptTemplate = Get-Content $classifierPromptPath -Raw
$classifierPrompt = $classifierPromptTemplate `
    -replace '\{\{CURRENT_DATETIME\}\}', $nowText `
    -replace '\{\{TIMEZONE\}\}', $config.business_hours.timezone `
    -replace '\{\{CONFIG_PATH\}\}', $configPath

# --- Build the resolver prompt TEMPLATE (ticket ID / tier substituted per ticket later) ---
$resolverPromptTemplate = Get-Content $resolverPromptPath -Raw
$resolverPromptTemplate = $resolverPromptTemplate `
    -replace '\{\{CURRENT_DATETIME\}\}', $nowText `
    -replace '\{\{TIMEZONE\}\}', $config.business_hours.timezone `
    -replace '\{\{IS_BUSINESS_HOURS\}\}', $isBusinessHours `
    -replace '\{\{CONFIG_PATH\}\}', $configPath

if ($DryRun) {
    Write-Host "=== DRY RUN ==="
    Write-Host "Business hours: $isBusinessHours"
    Write-Host "WhatIf (simulation) mode: $WhatIf"
    Write-Host ""
    Write-Host "--- Classifier ---"
    Write-Host "Model: $($config.claude.classifier_model)"
    Write-Host "Effort: $(if ($config.claude.effort) { $config.claude.effort } else { '(account default)' })"
    Write-Host "Allowed tools: $($classifierTools -join ',')"
    Write-Host "--- Classifier prompt ---"
    Write-Host $classifierPrompt
    Write-Host ""
    Write-Host "--- Resolver (per classified ticket) ---"
    Write-Host "Model by tier: TRIVIAL/TRIVIAL_UNCERTAIN=$($modelForTier['TRIVIAL']), MEDIUM=$($modelForTier['MEDIUM']), COMPLEX=$($modelForTier['COMPLEX'])"
    Write-Host "Effort: $(if ($config.claude.effort) { $config.claude.effort } else { '(account default)' })"
    Write-Host "Allowed tools: $($resolverTools -join ',')"
    Write-Host "--- Resolver prompt template (ticket ID/tier shown as placeholders) ---"
    Write-Host $resolverPromptTemplate
    return
}

if ($WhatIf) {
    Write-Host "=== WHATIF: running for real against live data, but read-only - no ticket, mailbox, device, or Hudu changes will be made ==="
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$modeLabel = "[$timestamp] Business hours: $isBusinessHours"
if ($WhatIf) {
    $modeLabel = "[$timestamp] WHATIF SIMULATION - Business hours: $isBusinessHours"
}
Add-Content -Path $logFile -Value $modeLabel -Encoding UTF8

try {
    # --- Stage 1: classify ---
    $classifierResult = Invoke-ClaudeCLI -Prompt $classifierPrompt -Tools $classifierTools `
        -Model $config.claude.classifier_model -Effort $config.claude.effort
    Write-LogSection -LogFile $logFile -Header "CLASSIFIER" -Content $classifierResult.Raw

    if (-not $classifierResult.Parsed) {
        throw "Classifier call did not return parseable JSON - see the CLASSIFIER section just written to the log."
    }
    if ($classifierResult.Parsed.is_error) {
        throw "Classifier call returned an error: $($classifierResult.Parsed.result)"
    }

    $ticketsJsonText = Get-CleanJsonText -Text $classifierResult.Parsed.result
    $tickets = $null
    try {
        # Wrapped in @(...): ConvertFrom-Json unwraps a single-element JSON array
        # into a bare object rather than a 1-item array, which would break every
        # .Count check below on a cycle with exactly one candidate ticket.
        $tickets = @($ticketsJsonText | ConvertFrom-Json)
    }
    catch {
        throw "Could not parse the classifier's ticket/tier list as JSON. Raw classifier result text: $ticketsJsonText"
    }

    $classifierCost = 0
    if ($classifierResult.Parsed.total_cost_usd) { $classifierCost = $classifierResult.Parsed.total_cost_usd }

    # ConvertFrom-Json on the classifier's "[]" (no candidate tickets) can come
    # back as $null rather than an empty array depending on PowerShell version -
    # @($null) then has Count 1, not 0, so check for that specifically too.
    $ticketsIsEmpty = (-not $tickets) -or ($tickets.Count -eq 0) -or ($tickets.Count -eq 1 -and $null -eq $tickets[0])
    if ($ticketsIsEmpty) {
        $emptySummary = [PSCustomObject]@{
            tickets_found       = 0
            classifier_cost_usd = $classifierCost
            resolver_cost_usd   = 0
            total_cost_usd      = $classifierCost
            tickets             = @()
        }
        Write-LogSection -LogFile $logFile -Header "CYCLE SUMMARY" -Content ($emptySummary | ConvertTo-Json -Compress)
        Add-Content -Path $logFile -Value "----" -Encoding UTF8
        Write-Host "No candidate tickets this cycle."
        return
    }

    # --- Stage 2: resolve each classified ticket, one claude -p call each ---
    $resolverCost = 0
    $ticketOutcomes = @()

    foreach ($ticket in $tickets) {
        $ticketId = $ticket.ticket_id
        $tier = $ticket.tier

        $model = $modelForTier[$tier]
        if (-not $model) {
            Write-Host "Unrecognized tier '$tier' for ticket $ticketId - falling back to the COMPLEX model."
            $model = $config.claude.resolver_model_complex
        }

        $resolverPrompt = $resolverPromptTemplate `
            -replace '\{\{TICKET_ID\}\}', $ticketId `
            -replace '\{\{TIER\}\}', $tier
        if ($WhatIf) {
            $resolverPrompt = $simulationBanner + "`n`n" + $resolverPrompt
        }

        try {
            $resolverResult = Invoke-ClaudeCLI -Prompt $resolverPrompt -Tools $resolverTools `
                -Model $model -Effort $config.claude.effort
            Write-LogSection -LogFile $logFile -Header "TICKET $ticketId (tier: $tier, model: $model)" -Content $resolverResult.Raw

            $ticketCost = 0
            if ($resolverResult.Parsed -and $resolverResult.Parsed.total_cost_usd) {
                $ticketCost = $resolverResult.Parsed.total_cost_usd
            }
            $resolverCost += $ticketCost
            $ticketOutcomes += [PSCustomObject]@{
                ticket_id = $ticketId
                tier      = $tier
                model     = $model
                cost_usd  = $ticketCost
            }
        }
        catch {
            Add-Content -Path $logFile -Value "TICKET $ticketId (tier: $tier, model: $model) ERROR: $($_.Exception.Message)" -Encoding UTF8
            $ticketOutcomes += [PSCustomObject]@{
                ticket_id = $ticketId
                tier      = $tier
                model     = $model
                cost_usd  = 0
                error     = $_.Exception.Message
            }
        }
    }

    $summary = [PSCustomObject]@{
        tickets_found       = $tickets.Count
        classifier_cost_usd = $classifierCost
        resolver_cost_usd   = $resolverCost
        total_cost_usd      = $classifierCost + $resolverCost
        tickets             = $ticketOutcomes
    }
    Write-LogSection -LogFile $logFile -Header "CYCLE SUMMARY" -Content ($summary | ConvertTo-Json -Depth 5 -Compress)
    Add-Content -Path $logFile -Value "----" -Encoding UTF8

    Write-Host "Cycle complete: $($tickets.Count) ticket(s), total cost `$$($summary.total_cost_usd)"
}
catch {
    Add-Content -Path $logFile -Value "[$timestamp] ERROR: $($_.Exception.Message)" -Encoding UTF8
    Add-Content -Path $logFile -Value "----" -Encoding UTF8
    throw
}
