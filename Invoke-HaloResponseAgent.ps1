<#
.SYNOPSIS
    Runs the Altec Halo Response Agent (Claude Code, headless) for one cycle.
.DESCRIPTION
    Three-stage pipeline per cycle:
      0. ID RESOLUTION - one cheap claude -p call (read-only Halo name-to-ID
         lookup tools, Haiku model) resolves config.json's plain Halo names
         (team/agent/status/priority) into IDs once for this cycle. Aborts the
         whole cycle if any name fails to match, rather than let a bad ID
         silently reach a ticket. See id-resolver-prompt.md.
      1. CLASSIFIER - one cheap claude -p call (read-only Halo tools, Haiku model)
         finds this cycle's candidate tickets and tags each with a complexity tier.
      2. RESOLVER - one claude -p call PER classified ticket, with the full MCP tool
         set and a model chosen by that ticket's tier, does the actual investigation
         and (outside -WhatIf) the actual reply/remediation/escalation.
    Stage 0's resolved IDs are injected directly into both the classifier and every
    resolver call's prompt, so neither stage repeats the same fixed lookups itself -
    see the "ID pre-resolution" note in Version 2.1.0 below.
    This replaces the earlier design where one claude -p call handled every ticket
    itself in a single agentic session - see CLAUDE.md for why (a cheap model can
    triage; only tickets that need it should pay for a bigger one and a full tool
    loop).
.PARAMETER RootPath
    Folder containing config.json, id-resolver-prompt.md, classifier-prompt.md,
    and resolver-prompt.md. Defaults to the folder this script itself is sitting
    in, so as long as all files stay together, you never need to pass this - just
    run `.\Invoke-HaloResponseAgent.ps1` with no arguments, whether by hand, from
    Task Scheduler, or anywhere else.
.PARAMETER DryRun
    Print what would be run without calling claude at all - no prompt, no tool
    calls, nothing live. Shows all three stages' resolved prompt/tools/model
    (ID-resolution placeholders like {{TEAM_ID}}, and per-ticket {{TICKET_ID}}/
    {{TIER}}, all stay as unresolved placeholders here, since no ID-resolution or
    classifier call happened to supply real ones).
.PARAMETER WhatIf
    Run for real against live Halo/Ninja/M365/etc. data - ID resolution and the
    classifier run exactly as they always would (both are read-only regardless),
    but every resolver call has every tool that changes anything (ticket
    replies/status/assignment, on-call notifications, reboots, script runs,
    password resets, Hudu writes) removed from its allowlist and swapped for an
    instruction to describe what it would have done instead. Nothing is touched
    anywhere. This is the one to use to see real decisions on real tickets before
    trusting the schedule; -DryRun only checks the prompt/tool list resolve
    correctly, it never calls Claude.
.NOTES
    Version: 2.7.1 - the first full 6-ticket cycle after the account's spend
    limit was raised (separate from credit balance - see CLAUDE.md if this
    trips again) validated the v2.7.0 Hudu-during-WhatIf change working as
    intended: ticket 21608 wrote a new "[Candidate - untested]" article,
    ticket 21607 immediately found and correctly reused it later the same
    cycle instead of duplicating it. Added mcp__Meraki__list_network_clients
    (denied while investigating a call-quality ticket's network, same class
    of gap as the round before). Investigated, rather than assumed, a
    denial on mcp__Halo__list_time_entries: confirmed via its real schema
    that it (and get_ticket_time_entries) return only billable labor time,
    not a ticket's notes/actions/message history, and get_ticket has no
    parameter to request that either - so this is a genuine Halo MCP server
    capability gap, not an allowlist fix, and adding list_time_entries
    wouldn't have helped despite looking like every other tool-gap fix this
    session. Documented in CLAUDE.md rather than "fixed" by adding a tool
    that doesn't solve it. Also documented in CLAUDE.md: repeated -WhatIf
    runs against the same live backlog never actually claim a ticket, so the
    same tickets get re-investigated at full cost every run - not
    representative of production cost, where a claimed/resolved ticket
    actually drops out of future cycles.
    Version: 2.7.0 - two cost-related changes prompted by real -WhatIf spend
    ($20+ in testing). First: mcp__HUDU__article_create_tool/article_edit_tool
    are no longer stripped during -WhatIf - confirmed via `claude -p`'s own JSON
    output that they only ever write to the isolated "AI-Documented Fixes" Hudu
    folder, never a client-facing doc, so there's no real-world risk in leaving
    them live; testing runs now build real, reusable KB content instead of just
    describing what they'd have written. resolver-prompt.md's "Documenting a fix
    that worked" section now tells the model to label a simulation-sourced
    article as unverified/untested, since nothing was actually confirmed fixed
    this run - never write one as if it were a confirmed production fix. Second:
    Show-AgentLog.ps1 now prints each stage's cache_read/cache_creation/fresh
    input token counts (straight from claude -p's own usage block, verified
    directly by running `claude -p --output-format json` and inspecting the
    real JSON rather than assuming the field names) - this makes it possible to
    actually see whether prompt caching (the ~90-entry tool list and fixed
    instructions repeated on every classifier/resolver call) is paying off,
    instead of guessing from total cost alone.
    Version: 2.6.1 - the v2.6.0 -WhatIf re-test confirmed the unassigned-sentinel
    fix worked (all 4 candidates correctly claimed as unassigned this run) and
    surfaced 5 more tool gaps on the same two ticket types that had them before:
    mcp__CIPP__list_alerts/list_mailbox_permissions (BEC/mailbox-compromise
    checks on the Huntress escalation ticket) and mcp__Meraki__get_org_vpn_statuses/
    list_network_devices/get_device_uplink_info (WAN quality check on a
    call-quality complaint). Added to $resolverTools, same pattern as every
    prior tool-gap fix. Unrelated to this repo: the same run's last two tickets
    (21577, 21571) got zero investigation because the Anthropic account had hit
    its API usage limit mid-cycle ("regain access on 2026-10-01") - visible in
    the log as an inline API error, not a code bug, but worth knowing since
    real cycles will silently under-serve the queue the same way until that
    limit is raised or resets.
    Version: 2.6.0 - fixed a real run where the resolver wrongly skipped 3
    tickets the classifier had explicitly found unassigned, reasoning
    "agent_id: 1, which is neither unassigned (0) nor my assigned agent_id" -
    a live mcp__Halo__list_agents call confirmed agent_id 1 is Halo's own
    "Unassigned" placeholder record (name "Unassigned", is_agent: false), not
    a colleague; every prior run this session had correctly treated it as
    unassigned, but neither prompt ever said so explicitly, leaving it for the
    model to guess. classifier-prompt.md and resolver-prompt.md now both state
    the sentinel value directly, and the two escalation "unassign yourself"
    steps in resolver-prompt.md (which used agent_id: 0, never verified
    against live data) now use agent_id: 1 to match. Also closed 6 tool gaps
    a real Huntress security-escalation ticket hit: added
    mcp__Huntress__get_escalation/list_identities/list_organizations and
    mcp__CIPP__list_tenants/list_mfa_users/list_conditional_access to
    $resolverTools (all read-only, same pattern as every prior tool-gap fix).
    Version: 2.5.0 - removed config.json's halo.urgent_priority_names entirely
    instead of leaving it in place unused. It was never independently verified
    against live Halo data when first written (present in this repo's very
    first commit) - v2.3.0's investigation confirmed its values are real
    entries in Halo's priority catalog (list_priorities), but the user
    separately confirmed the actual per-ticket-type urgency scale they see in
    Halo's UI (Low/Normal/Escalated/Critical under "Incident") doesn't match
    those names at all - it's a different field (urgency, not priority), and
    no available tool exposes that specific scale to verify or resolve it
    against. Since nothing can act on a priority or urgency value either way
    (no parameter for either on mcp__Halo__update_ticket), keeping an unverified
    field around to "document intent" was worse than not having it - a config
    value nobody can act on and nobody had checked was itself the omission.
    Lesson for future config/prompt work: verify any Halo-name-shaped config
    value directly against the live instance before trusting it, and prefer
    deleting a confirmed-unused field over leaving it with an explanatory
    comment - a comment doesn't stop it from being read as authoritative.
    Version: 2.4.0 - ticket-type/impact-aware classification. list_tickets and
    get_ticket already return tickettype_id, impact, and urgency inline - no
    new tool calls needed, just better use of data already being fetched. The
    ID resolver (Stage 0) now also calls list_ticket_types once and builds a
    ticket_type_names id->name lookup table (same pattern as team/status/
    agent), injected into both the classifier and resolver prompts as
    {{TICKET_TYPE_NAMES}}. classifier-prompt.md and resolver-prompt.md both
    now treat impact:1 ("Company Wide") as a second, independent signal toward
    COMPLEX/EMERGENCY CANDIDATE alongside the existing wording-based judgment,
    and both give guidance on machine-generated ticket types (Alert, Huntress -
    judge by what's reported, not by the fact that a monitoring system filed
    it) and HR/admin-coordination types (New Starter/Leaver/Administrator
    Rights/Hardware Collection Request - often need human coordination even
    when the ask reads simply). A missing/empty ticket_type_names is a warning,
    not an aborted cycle, since it's a readability aid (translating a bare
    tickettype_id into a name) rather than a value used in any actual API call.
    Version: 2.3.0 - stopped resolving urgent_priority_names to IDs at all.
    Direct inspection of a real Halo instance found two things: (1) Halo scopes
    priorities per SLA policy, so the same severity tier can have a different
    name under each SLA - "Urgent"/"Critical"/"Critial" turned out to be one
    tier (priorityid 1) under three different SLAs, not three distinct levels,
    which is why they'd resolved to the same id (a real, correct result that
    2.2.0's duplicate-id check would have wrongly flagged as an error on every
    future cycle - that check is removed along with the resolution it was
    guarding). (2) mcp__Halo__update_ticket has no priority parameter at all,
    so nothing could ever have consumed these IDs regardless - resolver-
    prompt.md's "set an urgent priority" instruction was never actually
    achievable and has been replaced with an internal-note-only fallback (see
    its Emergency escalation section) until a tool exists that can act on it.
    Version: 2.2.0 - the ID resolution stage (added in 2.1.0) is now cached to
    disk (resolved-ids-cache.json) instead of running a fresh claude -p call
    every single cycle. The cache is keyed on the exact halo.* names in
    config.json right now, so any edit to a team/agent/status/priority name
    invalidates it automatically - no manual "clear the cache" step - plus a
    time-based expiry (claude.id_cache_max_age_hours, default 24) as a backstop
    for the rarer case where Halo itself changes (a team renamed, an agent
    account recreated) without config.json's text changing. A cache read
    failure of any kind (missing file, corrupted JSON, hand-edited into
    something unexpected) is treated as a cache miss and falls through to a
    fresh resolution - caching is purely an optimization, never a new way for
    this script to fail. Cached or fresh, the resolved IDs go through the same
    validation before being trusted or written back to the cache.
    Version: 2.1.0 - added an ID pre-resolution stage (id-resolver-prompt.md) that
    runs once per cycle before the classifier: team_id, agent_id, and all three
    status_ids/urgent priority_ids are resolved once and injected into both the
    classifier and every resolver call's prompt, instead of each of those calls
    redundantly re-resolving the same fixed Halo names from scratch. A real run
    showed every resolver call independently repeating 4 identical name-to-ID
    lookups regardless of which ticket it was working - real, if moderate, waste
    once you're paying for one resolver call per ticket per cycle. list_teams/
    list_statuses/list_priorities/list_agents were removed from both the
    classifier's and resolver's own tool allowlists entirely (not just discouraged
    in the prompt) so the savings are guaranteed rather than hoped-for. If any
    config.json name fails to resolve against real Halo data, the whole cycle
    aborts with a clear error naming exactly which field failed, rather than let
    a null/wrong ID silently reach every ticket's resolver call this cycle.
    Version: 2.0.1 - prompts are now piped to claude over stdin instead of
    passed as a "-p <text>" argument, since embedded double quotes in the
    prompt files (quoted example phrases) were being truncated/mangled by
    PowerShell's native-command argument re-quoting - this, not file
    encoding, was the cause of the classifier reporting its own instructions
    as "cut off."
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
$idCachePath          = Join-Path $RootPath "resolved-ids-cache.json"
$idResolverPromptPath = Join-Path $RootPath "id-resolver-prompt.md"
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
# -Encoding UTF8 is load-bearing: Windows PowerShell 5.1's Get-Content defaults
# to the system's legacy codepage for a file with no BOM, silently corrupting
# any non-ASCII character (em dashes, curly quotes) in config.json/the prompt
# templates - this is the same root cause as the earlier .ps1 parsing bug, just
# hitting a data file read at runtime instead of a script being parsed.
$config = Get-Content $configPath -Raw -Encoding UTF8 | ConvertFrom-Json

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

# ID resolver: runs once per cycle, before the classifier, to resolve config.json's
# plain Halo names (team/agent/status) into IDs, plus build a ticket-type
# id-to-name lookup table (list_ticket_types - a small, fixed catalog, same
# reasoning as team/agent/status) - all deterministic lookups that never change
# between tickets in the same cycle, so paying for them once here instead of
# redundantly in the classifier and every single resolver call is pure savings.
# list_priorities deliberately NOT here - config.json has no priority/urgency
# field to resolve at all (see its halo._comment for why), and there's no
# tool that could act on a resolved priority/urgency ID regardless.
$idResolverTools = @(
    "Read", "ToolSearch",
    "mcp__Halo__list_teams", "mcp__Halo__list_statuses",
    "mcp__Halo__list_agents", "mcp__Halo__list_ticket_types"
)

# Classifier: read-only, just enough to find and skim candidate tickets. Never
# touched by -WhatIf, since it can't mutate anything to begin with.
# ToolSearch: with this many MCP servers/tools registered on the machine, a real
# run showed a resolver call (see $resolverTools below) getting stuck trying to
# use ToolSearch to load a tool's schema before calling it, then giving up when
# it couldn't - included here too so that path, if it comes up, actually works
# instead of dead-ending.
# NOTE: list_teams/list_statuses/list_priorities/list_agents are deliberately NOT
# here - the ID resolver stage above already resolved and validated team_id/
# agent_id for this run (see {{TEAM_ID}}/{{AGENT_ID}} in classifier-prompt.md), so
# there's nothing left for the classifier to look up; leaving these tools out
# entirely (rather than just telling the prompt not to bother) guarantees the
# savings instead of just hoping the model complies.
$classifierTools = @(
    "Read", "ToolSearch",
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket"
)

# Resolver: the full tool set - everything a ticket might need to be diagnosed
# or (within the remediation whitelist) fixed. Add a line here only when
# introducing a brand-new SYSTEM or a brand-new KIND of action (e.g. the agent
# should now also touch UniFi firewall rules). A new instance of something
# already listed here (another NinjaOne script, another M365 action of a type
# already present) only needs a config.json entry - nothing here. See README's
# "Adding a new system" section for the full walkthrough.
$resolverTools = @(
    "Read", "ToolSearch",

    # --- Halo: read + reply/update ---
    # list_teams/list_statuses/list_agents are deliberately NOT here, same
    # reasoning as $classifierTools above - the ID resolver stage already
    # resolved and validated team_id/agent_id/all three status_ids for this run
    # (see resolver-prompt.md's Context section), so every ticket's resolver
    # call would otherwise redundantly redo the same fixed lookups from
    # scratch. list_priorities was never added here either: get_ticket's own
    # response already embeds the ticket's current priority object directly,
    # and there's no tool that can change a ticket's priority anyway (see
    # resolver-prompt.md's emergency-escalation section).
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket", "mcp__Halo__get_ticket_time_entries",
    "mcp__Halo__list_kb_articles", "mcp__Halo__get_kb_article",
    "mcp__Halo__update_ticket",
    # get_client/list_clients/get_contact/list_contacts: a real run showed the
    # resolver denied on get_client while investigating which company a ticket
    # belonged to - never added despite being the same kind of read-only
    # name-to-ID lookup already granted for teams/statuses/agents.
    "mcp__Halo__get_client", "mcp__Halo__list_clients", "mcp__Halo__get_contact", "mcp__Halo__list_contacts",
    # list_assets: multiple real runs hit "no printer/copier asset tracked in
    # NinjaOne" (printers/copiers usually aren't RMM-managed) and wanted to
    # check Halo's own asset registry instead - denied because it was never
    # added, not because -WhatIf removed it.
    "mcp__Halo__list_assets",

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
    # list_tenants/list_mfa_users/list_conditional_access: a real run investigating
    # a security-flagged ticket wanted to confirm which tenant it was checking and
    # whether MFA/conditional access was actually enforced for the affected user -
    # denied because none of these three read-only lookups had been added yet.
    "mcp__CIPP__list_tenants", "mcp__CIPP__list_mfa_users", "mcp__CIPP__list_conditional_access",
    # list_alerts/list_mailbox_permissions: the very next run on that same
    # Huntress-escalation ticket type hit two more denials while checking for a
    # BEC-style mailbox compromise (Defender/CIPP alerts, unexpected mailbox
    # delegate access) - second straight round of CIPP gaps on this ticket type.
    "mcp__CIPP__list_alerts", "mcp__CIPP__list_mailbox_permissions",

    # --- NinjaOne: read + reboot + run-script + script lookup by name ---
    # Three straight real runs each turned up a different missing read-only
    # NinjaOne tool the resolver legitimately wanted (list_org_devices to
    # identify a device by client instead of guessing from hostname patterns,
    # get_device_windows_services to check the print spooler, then
    # get_device_disks/get_device_processors/list_device_antivirus_status/
    # list_alerts). Rather than keep patching one at a time, every read-only
    # NinjaOne diagnostic tool is included now - only device/org mutation
    # (approve/reject_device, update_device, create/update_organization,
    # set/end_device_maintenance, acknowledge/resolve_alert, approve/
    # reject_os_patch, Ninja's own create/update_ticket) is left out, since
    # none of that is something this agent should ever do.
    "mcp__Ninja__get_device", "mcp__Ninja__get_device_os_info", "mcp__Ninja__get_device_software",
    "mcp__Ninja__get_device_software_patches", "mcp__Ninja__get_device_disks", "mcp__Ninja__get_device_processors",
    "mcp__Ninja__get_device_maintenance", "mcp__Ninja__list_devices_detailed",
    "mcp__Ninja__list_device_alerts", "mcp__Ninja__list_alerts", "mcp__Ninja__list_device_antivirus_status",
    "mcp__Ninja__get_device_os_patches", "mcp__Ninja__query_os_patches", "mcp__Ninja__query_software_patches",
    "mcp__Ninja__query_software_inventory", "mcp__Ninja__query_antivirus_threats", "mcp__Ninja__query_backup_jobs",
    "mcp__Ninja__list_devices",
    "mcp__Ninja__list_organizations", "mcp__Ninja__list_org_devices",
    "mcp__Ninja__get_device_volumes", "mcp__Ninja__get_device_network_interfaces",
    "mcp__Ninja__get_device_windows_services",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device", "mcp__Ninja__list_automation_scripts",

    # --- Network, read-only --- (every UniFi tool is a GET/LIST - no
    # mutating UniFi tool exists at all, so the full set is included)
    "mcp__Unifi__list_clients", "mcp__Unifi__get_device", "mcp__Unifi__list_devices", "mcp__Unifi__list_sites",
    "mcp__Unifi__get_host", "mcp__Unifi__list_hosts", "mcp__Unifi__get_isp_metrics",
    "mcp__Unifi__list_network_devices", "mcp__Unifi__list_network_sites",
    # list_organizations/list_networks: a real run showed the resolver denied on
    # list_organizations while investigating a client's network, mirroring the
    # same Ninja gap fixed earlier - discovering an org without then listing its
    # networks wouldn't be very useful, so both are added together.
    "mcp__Meraki__get_network_client", "mcp__Meraki__list_org_device_statuses",
    "mcp__Meraki__list_organizations", "mcp__Meraki__list_networks",
    # get_org_vpn_statuses/list_network_devices/get_device_uplink_info: a real
    # run investigating a call-quality complaint wanted to check WAN uplink
    # loss/latency and the office's device list - denied because none of these
    # three had been added yet, same class of gap as the round above.
    "mcp__Meraki__get_org_vpn_statuses", "mcp__Meraki__list_network_devices", "mcp__Meraki__get_device_uplink_info",
    # list_network_clients: same call-quality-complaint ticket type, a follow-up
    # run wanted the connected-client list for a network (distinct from
    # get_network_client, which needs one client's ID/MAC already known) - denied
    # because it hadn't been added yet.
    "mcp__Meraki__list_network_clients",

    # --- Security context, read-only ---
    # get_escalation/list_identities/list_organizations: a real run working a
    # Huntress security escalation ticket wanted to pull the escalation's own
    # detail (not just the incident report list) and check the affected
    # identity/org context - denied because none of these three had been
    # added yet, same class of gap as the earlier Ninja/UniFi/Meraki rounds.
    "mcp__Huntress__list_incident_reports", "mcp__Huntress__get_agent",
    "mcp__Huntress__get_escalation", "mcp__Huntress__list_identities", "mcp__Huntress__list_organizations",

    # --- Documentation, read-only (also where per-client 3CX connection details
    #     would live once that system is added - see README) ---
    # NOTE: registered here as "HUDU" (all caps).
    "mcp__HUDU__company_index_tool",
    "mcp__HUDU__asset_index_tool", "mcp__HUDU__asset_show_tool", "mcp__HUDU__article_index_tool", "mcp__HUDU__article_show_tool",
    # article_folder_index_tool: lets the agent list a folder's contents directly
    # (config's hudu_fix_folder_name) instead of relying only on keyword search,
    # which can miss an existing fix article that doesn't share search terms.
    "mcp__HUDU__article_folder_index_tool",
    # --- Documentation, write. Only ever writes to the "AI-Documented Fixes" folder
    #     from config.json (never edits client-facing docs), so this doesn't need a
    #     remediation_whitelist entry - it never touches a client's live systems.
    #     Deliberately absent from $mutatingTools below, unlike every other tool in
    #     this file that changes something: a -WhatIf run keeps these two live so
    #     testing runs build real, reusable KB content instead of just describing
    #     what they would have written - see resolver-prompt.md's "Documenting a
    #     fix that worked" section for how a simulation-sourced article gets
    #     labeled so it's never mistaken for a confirmed fix. ---
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
# mcp__HUDU__article_create_tool/article_edit_tool are deliberately NOT here -
# see the note where $resolverTools declares them: they only ever write to the
# isolated "AI-Documented Fixes" folder, never a client's live systems, so they
# stay live even during -WhatIf runs rather than being simulated like everything
# else below. resolver-prompt.md's "Documenting a fix that worked" section tells
# the model how to label a simulation-sourced article so it's never mistaken for
# a confirmed fix.
$mutatingTools = @(
    "mcp__Halo__update_ticket",
    "mcp__Microsoft365__outlook_send_mail",
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device"
)

if ($WhatIf) {
    $resolverTools = $resolverTools | Where-Object { $mutatingTools -notcontains $_ }
}
#endregion STATIC TOOL ALLOWLISTS

$simulationBannerLines = @(
    "=== SIMULATION MODE (-WhatIf) ===",
    "Nothing you do this run will actually happen - ONLY the tools that change a",
    "ticket, send a notification, or touch a client system have been removed from",
    "your allowlist on purpose. Every read-only/investigative tool (Halo lookups,",
    "NinjaOne, UniFi, Meraki, Huntress, Hudu reads, KB search, etc.) is still fully",
    "present and works exactly as it always does - use it normally, the same as any",
    "other run. If you're ever unsure whether a specific tool is available, just",
    "call it: a tool you don't have returns a permission denial, not a broken",
    "session, so there's no need to ask or guess first. Do the full investigation",
    "exactly as normal, then instead of calling the tool you'd normally use to act,",
    "state plainly what you WOULD have done: the exact reply text, which",
    "status/team/agent_id you'd set, any remediation action and its whitelist",
    "justification, any on-call notification. Label each one clearly as 'WOULD DO:'",
    "so it's obvious this is a simulation. Do not attempt to call a tool you no",
    "longer have - if investigation alone can't rule out an action, just say so.",
    "ONE EXCEPTION: mcp__HUDU__article_create_tool and article_edit_tool are still",
    "live and really write, same as any other run - see resolver-prompt.md's",
    "'Documenting a fix that worked' section for how to label a simulation-sourced",
    "article so it's never mistaken for a confirmed fix.",
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

    # The classifier is told to respond with ONLY a JSON array, but a real run
    # showed it ignoring that and writing a full markdown analysis (headers,
    # a table, bullet points) with the actual array in a fenced code block at
    # the end. Rather than trust "JSON only" to always hold, find the JSON
    # wherever it actually is: prefer a fenced ```json/``` block anywhere in
    # the text (not just one starting at position 0), then fall back to the
    # outermost [ ... ] span if no fence is present at all.
    $fenceMatch = [regex]::Match(
        $trimmed,
        '```(?:json)?\s*\r?\n(.*?)\r?\n```',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if ($fenceMatch.Success) {
        return $fenceMatch.Groups[1].Value.Trim()
    }

    # Fallback for an unfenced response: find the outermost span, whichever
    # bracket type actually opens first - [ for the classifier's array, { for
    # the ID resolver's object. This has to check WHICH one starts first rather
    # than always trying [ ] before { } - if the ID resolver's object ever gains
    # a nested array-valued field again, a naive "look for [ ] first" would grab
    # just that inner array instead of the enclosing object (this bit an earlier
    # version that briefly had an array field here).
    $firstBracket = $trimmed.IndexOf('[')
    $firstBrace = $trimmed.IndexOf('{')

    if ($firstBrace -ge 0 -and ($firstBracket -lt 0 -or $firstBrace -lt $firstBracket)) {
        $lastBrace = $trimmed.LastIndexOf('}')
        if ($lastBrace -gt $firstBrace) {
            return $trimmed.Substring($firstBrace, $lastBrace - $firstBrace + 1)
        }
    }
    elseif ($firstBracket -ge 0) {
        $lastBracket = $trimmed.LastIndexOf(']')
        if ($lastBracket -gt $firstBracket) {
            return $trimmed.Substring($firstBracket, $lastBracket - $firstBracket + 1)
        }
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
        "-p",
        "--allowedTools", $toolsArg,
        "--output-format", "json",
        "--permission-mode", "dontAsk"
    )
    if ($Model)  { $claudeArgs += @("--model", $Model) }
    if ($Effort) { $claudeArgs += @("--effort", $Effort) }

    # The prompt goes in over stdin, not as a "-p <text>" argument. Both prompt
    # files are full of literal embedded double quotes (example client replies,
    # quoted phrases like a "how do I..." question) - a real run showed the
    # classifier receiving its own instructions truncated at exactly one of
    # these, which is PowerShell mangling an embedded quote while re-quoting
    # the argument list for the external claude process, not a file/encoding
    # problem (already ruled out: BOM, hash, and length all verified intact
    # on disk). Stdin has no argument-parsing step, so this is no longer a
    # hazard no matter how many quotes a prompt contains.
    $rawOutput = $Prompt | & claude @claudeArgs 2>&1
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

# --- Build the ID resolver prompt --- (-Encoding UTF8: see note on $config above)
$idResolverPromptTemplate = Get-Content $idResolverPromptPath -Raw -Encoding UTF8
$idResolverPrompt = $idResolverPromptTemplate -replace '\{\{CONFIG_PATH\}\}', $configPath

# --- Build the classifier prompt (TEAM_ID/AGENT_ID substituted after ID resolution runs) ---
$classifierPromptTemplate = Get-Content $classifierPromptPath -Raw -Encoding UTF8
$classifierPrompt = $classifierPromptTemplate `
    -replace '\{\{CURRENT_DATETIME\}\}', $nowText `
    -replace '\{\{TIMEZONE\}\}', $config.business_hours.timezone `
    -replace '\{\{CONFIG_PATH\}\}', $configPath

# --- Build the resolver prompt TEMPLATE (ticket ID/tier and the resolved Halo IDs
#     substituted later - ticket ID/tier per ticket, resolved IDs once after ID
#     resolution runs) ---
$resolverPromptTemplate = Get-Content $resolverPromptPath -Raw -Encoding UTF8
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
    Write-Host "--- ID Resolution (runs once per cycle, before the classifier - skipped entirely on a cache hit) ---"
    Write-Host "Model: $($config.claude.classifier_model)"
    Write-Host "Effort: $(if ($config.claude.effort) { $config.claude.effort } else { '(account default)' })"
    Write-Host "Allowed tools: $($idResolverTools -join ',')"
    Write-Host "Cache file: $idCachePath"
    Write-Host "Cache max age (hours): $(if ($config.claude.id_cache_max_age_hours) { $config.claude.id_cache_max_age_hours } else { '24 (default)' })"
    Write-Host "--- ID resolver prompt ---"
    Write-Host $idResolverPrompt
    Write-Host ""
    Write-Host "--- Classifier ---"
    Write-Host "Model: $($config.claude.classifier_model)"
    Write-Host "Effort: $(if ($config.claude.effort) { $config.claude.effort } else { '(account default)' })"
    Write-Host "Allowed tools: $($classifierTools -join ',')"
    Write-Host "--- Classifier prompt (TEAM_ID/AGENT_ID shown as placeholders - only resolved on an actual run) ---"
    Write-Host $classifierPrompt
    Write-Host ""
    Write-Host "--- Resolver (per classified ticket) ---"
    Write-Host "Model by tier: TRIVIAL/TRIVIAL_UNCERTAIN=$($modelForTier['TRIVIAL']), MEDIUM=$($modelForTier['MEDIUM']), COMPLEX=$($modelForTier['COMPLEX'])"
    Write-Host "Effort: $(if ($config.claude.effort) { $config.claude.effort } else { '(account default)' })"
    Write-Host "Allowed tools: $($resolverTools -join ',')"
    Write-Host "--- Resolver prompt template (ticket ID/tier and resolved Halo IDs shown as placeholders - only resolved on an actual run) ---"
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
    # --- Stage 0: resolve Halo team/agent/status/priority IDs once for this cycle,
    #     using a cache when possible ---
    # These are fixed, deterministic lookups (a name-to-ID match, not ticket-specific
    # judgment) that essentially never change - so beyond resolving them once per
    # cycle instead of redundantly in the classifier and every resolver call, cache
    # the result to disk and skip even that one call on every cycle where nothing's
    # changed. The cache is keyed on the exact halo.* names in config.json right now
    # - ANY edit to a team/agent/status/priority name invalidates it automatically,
    # no separate "clear the cache" step needed - plus a time-based expiry
    # (claude.id_cache_max_age_hours) as a backstop for the rarer case where Halo
    # itself changes (a team gets renamed, an agent account gets recreated) without
    # config.json's text changing at all.
    $currentHaloIdentity = [PSCustomObject]@{
        help_desk_team_name           = $config.halo.help_desk_team_name
        agent_username                = $config.halo.agent_username
        resolved_status_name          = $config.halo.resolved_status_name
        waiting_on_client_status_name = $config.halo.waiting_on_client_status_name
        follow_up_status_name         = $config.halo.follow_up_status_name
    }
    $currentHaloIdentityJson = $currentHaloIdentity | ConvertTo-Json -Compress

    $idCacheMaxAgeHours = 24
    if ($config.claude.id_cache_max_age_hours) { $idCacheMaxAgeHours = $config.claude.id_cache_max_age_hours }

    $ids = $null
    $idResolutionCost = 0
    $usedCachedIds = $false
    $cachedResolvedAt = $null
    $cachedAgeHours = $null

    if (Test-Path $idCachePath) {
        try {
            $cached = Get-Content $idCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cachedInputJson = $cached.input | ConvertTo-Json -Compress
            $cachedAgeHours = ((Get-Date) - [datetime]$cached.resolved_at).TotalHours
            if ($cachedInputJson -eq $currentHaloIdentityJson -and $cachedAgeHours -le $idCacheMaxAgeHours) {
                $ids = $cached.ids
                $cachedResolvedAt = $cached.resolved_at
                $usedCachedIds = $true
            }
        }
        catch {
            # Any problem reading/parsing the cache (missing, corrupted, hand-
            # edited into something unexpected) - just treat it as a cache miss
            # and resolve fresh below. Caching is purely an optimization; it
            # must never become a new way for this script to fail.
        }
    }

    if (-not $usedCachedIds) {
        # If any name fails to match, abort the whole cycle rather than let a
        # null/wrong ID silently ride along into every ticket's resolver call
        # this cycle - or, just as bad, get written to the cache and silently
        # reused by every cycle after this one.
        $idResolverResult = Invoke-ClaudeCLI -Prompt $idResolverPrompt -Tools $idResolverTools `
            -Model $config.claude.classifier_model -Effort $config.claude.effort
        Write-LogSection -LogFile $logFile -Header "ID RESOLUTION" -Content $idResolverResult.Raw

        if (-not $idResolverResult.Parsed) {
            throw "ID resolution call did not return parseable JSON - see the ID RESOLUTION section just written to the log."
        }
        if ($idResolverResult.Parsed.is_error) {
            throw "ID resolution call returned an error: $($idResolverResult.Parsed.result)"
        }
        if ($idResolverResult.Parsed.total_cost_usd) { $idResolutionCost = $idResolverResult.Parsed.total_cost_usd }

        $idJsonText = Get-CleanJsonText -Text $idResolverResult.Parsed.result
        try {
            # Direct -InputObject call, not piped - see the identical note on
            # $tickets below for why piping ConvertFrom-Json through another
            # stage is unsafe.
            $ids = ConvertFrom-Json -InputObject $idJsonText
        }
        catch {
            throw "Could not parse the ID resolution JSON. Raw text: $idJsonText"
        }
    }

    # --- Validate the resolved IDs (from cache or freshly resolved) before
    #     trusting them or writing them to the cache ---
    $missingIdFields = @()
    foreach ($field in @("team_id", "agent_id", "resolved_status_id", "waiting_status_id", "followup_status_id")) {
        if ($null -eq $ids.$field) { $missingIdFields += $field }
    }

    if ($missingIdFields.Count -gt 0) {
        if ($usedCachedIds) {
            throw "Cached ID resolution data failed validation: $($missingIdFields -join ', ') - delete $idCachePath to force a fresh resolution, or check config.json's halo section against Halo."
        }
        throw "ID resolution failed to match: $($missingIdFields -join ', ') - check these names in config.json's halo section against what actually exists in Halo (team/status/priority/agent names are case-insensitive but must otherwise match exactly)."
    }

    # ticket_type_names is a readability aid (translates a ticket's bare
    # tickettype_id into a name for the classifier/resolver's own judgment),
    # not a value used in any actual API call - a problem here gets a warning,
    # not an aborted cycle. Worst case, the classifier/resolver just see the
    # raw numeric tickettype_id without a friendly name this cycle.
    $ticketTypeNamesText = "(unavailable - ticket type lookup returned nothing usable this cycle)"
    $ticketTypeCount = 0
    if ($ids.ticket_type_names) {
        $ticketTypeProps = @($ids.ticket_type_names.PSObject.Properties)
        $ticketTypeCount = $ticketTypeProps.Count
        if ($ticketTypeCount -gt 0) {
            $ticketTypeNamesText = ($ticketTypeProps | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
        }
    }
    if ($ticketTypeCount -eq 0) {
        Add-Content -Path $logFile -Value "[$timestamp] WARNING: ticket_type_names is missing/empty this cycle - classifier/resolver will see raw tickettype_id numbers without names." -Encoding UTF8
    }
    # Escape any literal '$' in the type names before using this as a -replace
    # replacement value below - PowerShell's -replace treats an un-escaped '$'
    # in the replacement string as a regex backreference (e.g. "$1"); '$$' is
    # how you insert one literal '$'. None of the real type names on this
    # instance contain one, but ticket types are free-text business data, not
    # something this script controls, so this is cheap insurance.
    $ticketTypeNamesText = $ticketTypeNamesText.Replace('$', '$$')

    if ($usedCachedIds) {
        # Log a lightweight confirmation, not the full claude-call section (there
        # was no claude call this cycle) - shaped like a no-cost claude response so
        # Show-AgentLog.ps1 renders it the same way as every other section instead
        # of hitting its "couldn't parse" fallback.
        $cacheNoteContent = [PSCustomObject]@{
            result = "Using cached IDs from $cachedResolvedAt (age $([math]::Round($cachedAgeHours,1))h, cache max age ${idCacheMaxAgeHours}h): team_id=$($ids.team_id), agent_id=$($ids.agent_id), resolved_status_id=$($ids.resolved_status_id), waiting_status_id=$($ids.waiting_status_id), followup_status_id=$($ids.followup_status_id), ticket_type_names_count=$ticketTypeCount"
        } | ConvertTo-Json -Compress
        Write-LogSection -LogFile $logFile -Header "ID RESOLUTION" -Content $cacheNoteContent
    }
    else {
        # Save a fresh cache now that these IDs are validated - keyed on the exact
        # config.json names that produced them, so any future edit to those names
        # invalidates this automatically.
        $freshCache = [PSCustomObject]@{
            resolved_at = (Get-Date).ToString("o")
            input       = $currentHaloIdentity
            ids         = $ids
        }
        try {
            $tempCachePath = "$idCachePath.tmp"
            $freshCache | ConvertTo-Json -Depth 5 | Set-Content -Path $tempCachePath -Encoding UTF8
            Move-Item -Path $tempCachePath -Destination $idCachePath -Force
        }
        catch {
            # Failing to WRITE the cache should never fail the cycle - worst
            # case, the next cycle just resolves fresh again, same as today.
            Add-Content -Path $logFile -Value "[$timestamp] WARNING: could not write ID resolution cache to $idCachePath - $($_.Exception.Message)" -Encoding UTF8
        }
    }

    # Inject the resolved IDs into both the classifier and resolver prompts - from
    # here on, neither needs to look any of these up itself.
    $classifierPrompt = $classifierPrompt `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText
    $resolverPromptTemplate = $resolverPromptTemplate `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{RESOLVED_STATUS_ID\}\}', $ids.resolved_status_id `
        -replace '\{\{WAITING_STATUS_ID\}\}', $ids.waiting_status_id `
        -replace '\{\{FOLLOWUP_STATUS_ID\}\}', $ids.followup_status_id

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
        # ConvertFrom-Json is called directly (via -InputObject), NOT through a
        # pipe, and only THEN wrapped in @(...). A real run with 4 classified
        # tickets showed $tickets ending up as a single element containing all
        # 4 ticket objects nested inside it (every property access on it - like
        # $ticket.ticket_id - returned all 4 values space-joined, which is
        # PowerShell's member-enumeration behavior on a collection, not a
        # single ticket). Piping ConvertFrom-Json's array result through
        # another pipeline stage can hand that whole array to @(...) as ONE
        # item instead of enumerating it, double-nesting the result; calling it
        # directly and wrapping the resulting variable is unambiguous - @() on
        # an already-array variable is a same-array no-op, and only promotes a
        # true scalar (the single-candidate case, which ConvertFrom-Json
        # collapses to a bare object rather than a 1-item array) into a
        # 1-item array.
        $parsedTickets = ConvertFrom-Json -InputObject $ticketsJsonText
        $tickets = @($parsedTickets)
    }
    catch {
        throw "Could not parse the classifier's ticket/tier list as JSON. Raw classifier result text: $ticketsJsonText"
    }

    # $idResolutionCost was already set in Stage 0 above (0 on a cache hit, the
    # real cost on a fresh resolution) - not recomputed here.
    $classifierCost = 0
    if ($classifierResult.Parsed.total_cost_usd) { $classifierCost = $classifierResult.Parsed.total_cost_usd }

    # ConvertFrom-Json on the classifier's "[]" (no candidate tickets) can come
    # back as $null rather than an empty array depending on PowerShell version -
    # @($null) then has Count 1, not 0, so check for that specifically too.
    $ticketsIsEmpty = (-not $tickets) -or ($tickets.Count -eq 0) -or ($tickets.Count -eq 1 -and $null -eq $tickets[0])
    if ($ticketsIsEmpty) {
        $emptySummary = [PSCustomObject]@{
            tickets_found         = 0
            id_resolution_cost_usd = $idResolutionCost
            classifier_cost_usd   = $classifierCost
            resolver_cost_usd     = 0
            total_cost_usd        = $idResolutionCost + $classifierCost
            tickets               = @()
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
        tickets_found          = $tickets.Count
        id_resolution_cost_usd = $idResolutionCost
        classifier_cost_usd    = $classifierCost
        resolver_cost_usd      = $resolverCost
        total_cost_usd         = $idResolutionCost + $classifierCost + $resolverCost
        tickets                = $ticketOutcomes
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
