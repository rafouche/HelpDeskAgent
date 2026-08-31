<#
.SYNOPSIS
    Runs the Altec Halo Response Agent (Claude Code, headless) for one cycle.
.DESCRIPTION
    Loads config.json, works out whether it's currently business hours, builds the
    task prompt from agent-prompt.md, and invokes `claude -p` with a fixed, scoped
    tool allowlist. The allowlist doesn't change based on config.json - config only
    controls WHICH of those tools the agent is allowed to actually use for what (see
    agent-prompt.md and remediation_whitelist). Intended to run every 5-15 minutes
    via Task Scheduler.
.PARAMETER RootPath
    Folder containing config.json and agent-prompt.md. Defaults to the folder this
    script itself is sitting in, so as long as all three files stay together, you
    never need to pass this - just run `.\Invoke-HaloResponseAgent.ps1` with no
    arguments, whether by hand, from Task Scheduler, or anywhere else.
.PARAMETER DryRun
    Print what would be run without calling claude at all - no prompt, no tool
    calls, nothing live. Just shows the resolved prompt and tool list.
.PARAMETER WhatIf
    Run for real against live Halo/Ninja/M365/etc. data - the agent reads
    everything and reasons about each ticket exactly as it normally would - but
    every tool that changes anything (ticket replies/status/assignment, on-call
    notifications, reboots, script runs, password resets, Hudu writes) is removed
    from its allowlist and swapped for an instruction to describe what it would
    have done instead. Nothing is touched anywhere. This is the one to use to see
    real decisions on real tickets before trusting the schedule; -DryRun only
    checks the prompt/tool list resolve correctly, it never calls Claude.
#>

param(
    [string]$RootPath = $PSScriptRoot,
    [switch]$DryRun,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $RootPath "config.json"
$promptPath = Join-Path $RootPath "agent-prompt.md"
$logDir     = Join-Path $RootPath "logs"
$logFileNameTemplate = "run-{0:yyyy-MM-dd}.log"
if ($WhatIf) {
    $logFileNameTemplate = "whatif-{0:yyyy-MM-dd}.log"
}
$logFile    = Join-Path $logDir ($logFileNameTemplate -f (Get-Date))

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# --- Load config (used for business-hours math; the agent reads the rest itself) ---
$config = Get-Content $configPath -Raw | ConvertFrom-Json

# --- Determine business-hours context ---
$now = Get-Date
$isBusinessDay = $config.business_hours.days -contains $now.DayOfWeek.ToString()
$startTod = [TimeSpan]::Parse($config.business_hours.start)
$endTod   = [TimeSpan]::Parse($config.business_hours.end)
$isBusinessHours = $isBusinessDay -and ($now.TimeOfDay -ge $startTod) -and ($now.TimeOfDay -le $endTod)

# --- Build the prompt from the template ---
$promptTemplate = Get-Content $promptPath -Raw
$prompt = $promptTemplate `
    -replace '\{\{CURRENT_DATETIME\}\}', $now.ToString("dddd, MMMM d, yyyy h:mm tt") `
    -replace '\{\{TIMEZONE\}\}', $config.business_hours.timezone `
    -replace '\{\{IS_BUSINESS_HOURS\}\}', $isBusinessHours `
    -replace '\{\{CONFIG_PATH\}\}', $configPath

#region STATIC TOOL ALLOWLIST - rarely edited
# Everything day-to-day (which team, which remediation, who's on call) lives in
# config.json and needs no changes here. This list only controls WHICH categories
# of tool the agent is technically permitted to call at all - it's the outer fence;
# config.json's remediation_whitelist is what actually decides whether the agent USES
# a given action on a given ticket (see agent-prompt.md).
#
# Add a line here only when you're introducing a brand-new SYSTEM or a brand-new KIND
# of action (e.g. the agent should now also touch UniFi firewall rules). A new
# instance of something already listed here (another NinjaOne script, another M365
# action of a type already present) only needs a config.json entry - nothing here.
#
# TO ADD A NEW SYSTEM (e.g. 3CX): add its tool names as its own labeled block below,
# then add matching investigation guidance to agent-prompt.md's "Investigate" step,
# then (only if it needs remediation actions, not just diagnostics) add entries to
# config.json's remediation_whitelist. See README's "Adding a new system" section
# for the full walkthrough.
# IMPORTANT: Claude Code matches MCP tools as "mcp__<ServerName>__<tool>" - the
# ServerName is whatever exact name you used with `claude mcp add <name> ...` on
# THIS machine (case-sensitive; check yours with `claude mcp list`). A bare
# "ServerName:tool" string (used here previously) never matches anything and
# --permission-mode dontAsk denies it *silently* - if you add a new system and
# tool calls seem to just do nothing, this is the first thing to check.
$allowedTools = @(
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
    # (endpoint "ListMessageTrace" - see agent-prompt.md). Falls back to
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
#endregion STATIC TOOL ALLOWLIST

# --- -WhatIf: strip every tool that changes anything, anywhere ---
# Keep this list in sync with $allowedTools above whenever a new mutating tool is
# added (a new remediation action reuses an existing entry here, so it's rare).
$mutatingTools = @(
    "mcp__Halo__update_ticket",
    "mcp__Microsoft365__outlook_send_mail",
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device",
    "mcp__HUDU__article_create_tool", "mcp__HUDU__article_edit_tool"
)

if ($WhatIf) {
    $allowedTools = $allowedTools | Where-Object { $mutatingTools -notcontains $_ }
    $simulationBannerLines = @(
        "=== SIMULATION MODE (-WhatIf) ===",
        "Nothing you do this run will actually happen - every tool that changes a ticket,",
        "sends a notification, or touches a client system has been removed from your",
        "allowlist on purpose. For each ticket, do the full investigation exactly as",
        "normal, then instead of calling the tool you'd normally use to act, state plainly",
        "what you WOULD have done: the exact reply text, which status/team/agent_id you'd",
        "set, any remediation action and its whitelist justification, any on-call",
        "notification, any Hudu article. Label each one clearly as 'WOULD DO:' so it's",
        "obvious this is a simulation. Do not attempt to call a tool you no longer have -",
        "if investigation alone can't rule out an action, just say so.",
        "==="
    )
    $simulationBanner = $simulationBannerLines -join "`n"
    $prompt = $simulationBanner + "`n`n" + $prompt
}

$allowedToolsArg = ($allowedTools -join ",")

$claudeArgs = @(
    "-p", $prompt,
    "--allowedTools", $allowedToolsArg,
    "--output-format", "json",
    "--permission-mode", "dontAsk"
)

if ($DryRun) {
    Write-Host "=== DRY RUN ==="
    Write-Host "Business hours: $isBusinessHours"
    Write-Host "WhatIf (simulation) mode: $WhatIf"
    Write-Host "Allowed tools: $allowedToolsArg"
    Write-Host "--- Prompt ---"
    Write-Host $prompt
    return
}

if ($WhatIf) {
    Write-Host "=== WHATIF: running for real against live data, but read-only - no ticket, mailbox, device, or Hudu changes will be made ==="
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try {
    $result = & claude @claudeArgs 2>&1
    $modeLabel = "[$timestamp] Business hours: $isBusinessHours"
    if ($WhatIf) {
        $modeLabel = "[$timestamp] WHATIF SIMULATION - Business hours: $isBusinessHours"
    }
    Add-Content -Path $logFile -Value $modeLabel
    Add-Content -Path $logFile -Value $result
    Add-Content -Path $logFile -Value "----"
}
catch {
    Add-Content -Path $logFile -Value "[$timestamp] ERROR: $($_.Exception.Message)"
    throw
}
