<#
.SYNOPSIS
    Runs the Altec Halo Response Agent (Claude Code, headless) for one cycle.
.DESCRIPTION
    Loads config.json, works out whether it's currently business hours, builds the
    task prompt from agent-prompt.md, and invokes `claude -p` with a fixed, scoped
    tool allowlist. The allowlist doesn't change based on config.json — config only
    controls WHICH of those tools the agent is allowed to actually use for what (see
    agent-prompt.md and remediation_whitelist). Intended to run every 5-15 minutes
    via Task Scheduler.
.PARAMETER RootPath
    Folder containing config.json and agent-prompt.md. Defaults to the folder this
    script itself is sitting in, so as long as all three files stay together, you
    never need to pass this — just run `.\Invoke-HaloResponseAgent.ps1` with no
    arguments, whether by hand, from Task Scheduler, or anywhere else.
.PARAMETER DryRun
    Print what would be run without calling claude at all — no prompt, no tool
    calls, nothing live. Just shows the resolved prompt and tool list.
.PARAMETER WhatIf
    Run for real against live Halo/Ninja/M365/etc. data — the agent reads
    everything and reasons about each ticket exactly as it normally would — but
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
$logFileNameTemplate = if ($WhatIf) { "whatif-{0:yyyy-MM-dd}.log" } else { "run-{0:yyyy-MM-dd}.log" }
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

#region STATIC TOOL ALLOWLIST — rarely edited
# Everything day-to-day (which team, which remediation, who's on call) lives in
# config.json and needs no changes here. This list only controls WHICH categories
# of tool the agent is technically permitted to call at all — it's the outer fence;
# config.json's remediation_whitelist is what actually decides whether the agent USES
# a given action on a given ticket (see agent-prompt.md).
#
# Add a line here only when you're introducing a brand-new SYSTEM or a brand-new KIND
# of action (e.g. the agent should now also touch UniFi firewall rules). A new
# instance of something already listed here (another NinjaOne script, another M365
# action of a type already present) only needs a config.json entry — nothing here.
#
# TO ADD A NEW SYSTEM (e.g. 3CX): add its tool names as its own labeled block below,
# then add matching investigation guidance to agent-prompt.md's "Investigate" step,
# then (only if it needs remediation actions, not just diagnostics) add entries to
# config.json's remediation_whitelist. See README's "Adding a new system" section
# for the full walkthrough.
$allowedTools = @(
    "Read",

    # --- Halo: read + reply/update + name-to-ID lookups ---
    "Halo:list_tickets", "Halo:get_ticket", "Halo:get_ticket_time_entries",
    "Halo:list_kb_articles", "Halo:get_kb_article",
    "Halo:update_ticket", "Halo:list_teams", "Halo:list_statuses", "Halo:list_priorities",
    "Halo:list_agents",

    # --- Notifications ---
    "Microsoft 365:outlook_send_mail", "Microsoft 365:outlook_email_search",

    # --- M365 / CIPP identity: read + the two whitelisted remediation actions ---
    # Migrated from the retired custom CIPP Worker to CIPP-ng's built-in MCP server
    # (registered as "CIPP_MCP" — see README). Action names carried over unchanged.
    "CIPP_MCP:get_user", "CIPP_MCP:healthcheck", "CIPP_MCP:reset_user_password", "CIPP_MCP:enable_user",
    # Email delivery diagnostics: CIPP_MCP has no dedicated message-trace tool, but
    # exposes CIPP's native Message Trace through its generic read-endpoint wrapper
    # (endpoint "ListMessageTrace" — see agent-prompt.md). Falls back to
    # outlook_email_search when that doesn't turn up enough.
    "CIPP_MCP:cipp_api_get",

    # --- NinjaOne: read + reboot + run-script + script lookup by name ---
    "Ninja:get_device", "Ninja:get_device_os_info", "Ninja:get_device_software",
    "Ninja:list_device_alerts", "Ninja:get_device_os_patches", "Ninja:list_devices",
    "Ninja:reboot_device", "Ninja:run_script_on_device", "Ninja:list_automation_scripts",

    # --- Network, read-only ---
    "Unifi:list_clients", "Unifi:get_device", "Unifi:list_devices",
    "Meraki:get_network_client", "Meraki:list_org_device_statuses",

    # --- Security context, read-only ---
    "Huntress:list_incident_reports", "Huntress:get_agent",

    # --- Documentation, read-only (also where per-client 3CX connection details
    #     would live once that system is added — see README) ---
    "Hudu:asset_index_tool", "Hudu:asset_show_tool", "Hudu:article_index_tool", "Hudu:article_show_tool",
    # --- Documentation, write. Only ever writes to the "AI-Documented Fixes" folder
    #     from config.json (never edits client-facing docs), so this doesn't need a
    #     remediation_whitelist entry — it never touches a client's live systems. ---
    "Hudu:article_create_tool", "Hudu:article_edit_tool"

    # --- 3CX (not yet built): add its tool names here as their own block once the
    #     multi-tenant 3CX MCP worker exists. Nothing above needs to change.
    # "3CX:get_extension_status", "3CX:list_call_logs", ...
)
#endregion STATIC TOOL ALLOWLIST

# --- -WhatIf: strip every tool that changes anything, anywhere ---
# Keep this list in sync with $allowedTools above whenever a new mutating tool is
# added (a new remediation action reuses an existing entry here, so it's rare).
$mutatingTools = @(
    "Halo:update_ticket",
    "Microsoft 365:outlook_send_mail",
    "CIPP_MCP:reset_user_password", "CIPP_MCP:enable_user",
    "Ninja:reboot_device", "Ninja:run_script_on_device",
    "Hudu:article_create_tool", "Hudu:article_edit_tool"
)

if ($WhatIf) {
    $allowedTools = $allowedTools | Where-Object { $mutatingTools -notcontains $_ }
    $prompt = @"
=== SIMULATION MODE (-WhatIf) ===
Nothing you do this run will actually happen — every tool that changes a ticket,
sends a notification, or touches a client system has been removed from your
allowlist on purpose. For each ticket, do the full investigation exactly as
normal, then instead of calling the tool you'd normally use to act, state plainly
what you WOULD have done: the exact reply text, which status/team/agent_id you'd
set, any remediation action and its whitelist justification, any on-call
notification, any Hudu article. Label each one clearly as "WOULD DO:" so it's
obvious this is a simulation. Do not attempt to call a tool you no longer have —
if investigation alone can't rule out an action, just say so.
===

$prompt
"@
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
    Write-Host "=== WHATIF: running for real against live data, but read-only — no ticket, mailbox, device, or Hudu changes will be made ==="
}

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
try {
    $result = & claude @claudeArgs 2>&1
    $modeLabel = if ($WhatIf) { "[$timestamp] WHATIF SIMULATION — Business hours: $isBusinessHours" } else { "[$timestamp] Business hours: $isBusinessHours" }
    Add-Content -Path $logFile -Value $modeLabel
    Add-Content -Path $logFile -Value $result
    Add-Content -Path $logFile -Value "----"
}
catch {
    Add-Content -Path $logFile -Value "[$timestamp] ERROR: $($_.Exception.Message)"
    throw
}
