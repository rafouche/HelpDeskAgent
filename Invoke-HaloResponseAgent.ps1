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
.PARAMETER RequireApproval
    Run for real, but hold every client-facing reply and remediation action for
    a human to approve first, rather than sending/running it immediately - the
    "human guardrails" rollout stage between -WhatIf and unsupervised live
    running. Needs config.json's halo.ai_waiting_approval_status_name and
    halo.ai_approved_status_name set to two custom statuses you create in Halo
    first (see README's "Human approval mode" section) - the switch hard-errors
    before calling claude at all if either is blank or doesn't resolve.
    A first-pass ticket gets investigated exactly as normal, but instead of
    actually replying/acting, the resolver writes what it would have done into
    a private note, sets the ticket to ai_waiting_approval_status_name, and
    unassigns itself. A human reviews that note in Halo and flips the status to
    ai_approved_status_name to approve it (or just leaves it/reassigns it
    manually to reject). The next cycle picks up any ai_approved_status_name
    ticket, reassigns itself, actually sends the approved reply, runs any
    approved remediation action, and applies the originally-intended final
    status - see the approval banner built at runtime (not a static part of
    classifier-prompt.md/resolver-prompt.md) for the exact mechanics. The one
    exception: the brief emergency on-call acknowledgment still sends
    immediately, same as always, since on-call is already being paged at that
    same moment - only the detailed follow-up reply and any remediation action
    wait for approval. Remediation-mutating tools (password reset, reboot,
    script run) are physically removed from a non-approved ticket's allowlist,
    not just discouraged in the prompt; the "is this a private draft or a real
    reply" distinction on `update_ticket` itself can't be enforced that way
    (both are the same tool, just different arguments), so that part relies on
    the prompt being followed, the same trust level as the rest of this
    system's safety rules (ticket-ownership checks, whitelist compliance).
    Combine with -WhatIf to safely dry-run the whole approval choreography
    against live data with nothing actually written anywhere.
.NOTES
    Version: 2.9.9 - fixed a real gap in Install-Prerequisites.ps1's git
    handling, found via a real run: it assumed git was already installed
    somewhere on the box and only fixed machine PATH visibility, the same
    assumption already corrected for npm/claude in v2.9.4 but missed here.
    A real run showed git genuinely wasn't installed at all for that
    account, not just missing from the machine PATH. Now installs git via
    winget first if Get-Command finds nothing, refreshes this process's own
    PATH from the registry afterward (winget's install doesn't update an
    already-running process), then proceeds with the existing machine-PATH
    fix. Given this, it's worth directly verifying whether any earlier
    `git pull` instruction actually landed on a given server rather than
    assuming it did, if git's real install status there was never confirmed
    first.
    Version: 2.9.8 - consolidated setup scripts: Install-ClaudeCodeMachineWide.ps1
    and Add-GitToMachinePath.ps1 (v2.9.4/v2.9.7) merged into one
    Install-Prerequisites.ps1, and Register-UpdateCheckTask.ps1 (v2.9.6)
    folded into Register-HaloResponseAgentTask.ps1 as its -EnableAutoUpdate
    switch. These should have been one script each from the start rather
    than accumulating across three separate fixes - flagged directly and
    corrected. CLAUDE.md's "Known limitations" no longer documents
    machine-wide credential/tool/PATH setup as a discovered limitation
    either - it's now stated up front as a design decision ("Everything the
    scheduled tasks depend on is configured machine-wide"), since
    Install-Prerequisites.ps1 and the corrected README steps mean there's
    nothing left to "discover" - just the right way to set this up.
    Version: 2.9.7 - fixed the exact risk v2.9.6 flagged but hadn't hit yet:
    confirmed via a script run through NinjaRMM (executes as SYSTEM by
    default, same as Task Scheduler) that git itself has the same
    account-scoping gap already hit for claude, MCP registration, and
    Claude Code's credentials - "'git' is not recognized..." despite
    `git pull` working fine run interactively as an admin. Added
    Add-GitToMachinePath.ps1: unlike the claude/npm fix, no reinstall
    needed - Git for Windows' installer already puts git.exe in a
    machine-wide folder (C:\Program Files\Git\...), the missing piece is
    that only the installing account's own PATH (HKCU) got updated, not the
    machine-wide one (HKLM). Finds git's real location from whichever
    account it already works for and adds that folder to the machine PATH
    via [Environment]::SetEnvironmentVariable (not setx, which silently
    truncates PATH-length values).
    Version: 2.9.6 - added Update-HaloResponseAgent.ps1 +
    Register-UpdateCheckTask.ps1: an auto-update check, on its own schedule
    (default 30 min), separate from this script's every-10-minute ticket
    cycle. This script re-reads every .ps1/.md/config.json file fresh on
    each firing, so a plain `git pull` in this folder is enough to make the
    very next cycle pick up whatever just shipped - no restart/reload
    needed. The update script only logs when something actually changed or
    failed, and runs this script with -DryRun once after a real update as a
    smoke test (no Halo calls, no API cost) so a broken push is visible
    immediately rather than discovered only when the next real cycle fails -
    a smoke test, not a rollback, the new code stays either way. Kept as its
    own script/task rather than folded in here, so a git/network problem can
    never abort an actual ticket-processing cycle.
    This is the fourth tool in this project (claude, MCP registration,
    Claude Code's credentials, now git) where "works interactively as an
    admin" has turned out not to reliably imply "works for SYSTEM" -
    README/CLAUDE.md both flag confirming this by hand before trusting it
    unattended, rather than assuming git is different just because it
    already works fine run by hand.
    Version: 2.9.5 - policy request from a real -RequireApproval-mode ticket:
    a personal/consumer VPN flagged (most often via Huntress, but the policy
    itself is general - it applies regardless of which system surfaces it).
    Two additions to resolver-prompt.md, no PS1/tool-list changes needed
    (list_contacts/update_ticket/get_contact were already granted). First,
    extended the v2.9.3 confidence-gated re-linking's HIGH CONFIDENCE tier to
    also accept a matched email address (not just a phone number) - a
    security-alert-generated ticket names a person by email (an M365
    account), not a callback number, so it needed the same "is this actually
    linked to the real person" check as a voicemail one, just matched a
    different way. Second, added a "personal/consumer VPN use flagged"
    block: always tell them to disconnect it and stop using it for company
    resources - no exceptions, this is a hard policy, not a judgment call
    (an earlier draft made this conditional on the ticket suggesting a
    legitimate reason first - corrected on direct instruction: that's a
    separate question, asked in addition to the disconnect instruction, not
    instead of it). If they were using it because they couldn't otherwise
    reach something (geo-blocked, traveling), ask if the ticket doesn't
    already make that clear, and separately flag it privately for IT to set
    up real remote access.
    Version: 2.9.4 - fixed a real first-scheduled-run failure: "'claude' is
    not recognized as the name of a cmdlet, function, script file, or
    operable program." A third instance of the same SYSTEM-account-scoping
    shape already documented for credentials and MCP registration -
    `npm install -g @anthropic-ai/claude-code` installs into the interactive
    user's own per-account npm prefix (%AppData%\npm\claude.cmd - npm's own
    documented Windows default, not assumed), on that user's PATH but not
    SYSTEM's. Every prior -WhatIf/-RequireApproval test ran interactively as
    an admin, so this never surfaced until the real scheduled firing.
    First attempt fixed this at runtime, in this script - resolving claude's
    path at startup and threading it through Invoke-ClaudeCLI's three call
    sites as an explicit -ClaudeExe parameter. Reverted the same day: fixing
    the install itself, once, is better than every future run re-discovering
    where npm happened to put it. Real fix is
    Install-ClaudeCodeMachineWide.ps1 (new script) - points npm's global
    prefix at C:\ProgramData\npm (genuinely shared by every account, unlike
    %AppData%) via the machine-wide NPM_CONFIG_PREFIX environment variable
    (documented npm behavior, confirmed against npm's own docs), adds that
    folder to the machine PATH, and reinstalls claude-code so it lands there
    for every account at once. See README's "Install and authenticate Claude
    Code" section and CLAUDE.md's "Known limitations" for the full account-
    scoping picture (this is the third instance of it, not a new category).
    Version: 2.9.3 - added confidence-gated ticket re-linking, prompted by a
    real example: a voicemail comes in against a generic/shared account, but
    the transcript names the real caller (a spoken name + callback number,
    no email) - e.g. "Dawn Davis, Director of Stone County Health Department,
    417-907-9136." Required a matching halopsa-mcp fix (rafouche/MCPs,
    commit a0264be, not yet deployed as of this writing): update_ticket now
    accepts client_id/user_id to re-link a ticket (confirmed against the
    live HaloPSA swagger's Faults schema - the same POST /Tickets body
    already used for create/update), and list_contacts now accepts
    search_phonenumbers (confirmed against /Users' own documented param) to
    match a caller's number against existing contacts.
    Deliberately did NOT wire this up as "reassign whenever the tools allow
    it" - resolver-prompt.md's "If the ticket's contact/company is unknown
    or wrong" section now splits on confidence: a phone number matching
    exactly one existing Halo contact is treated as a real, already-vetted
    identity and acted on automatically (re-link, verify the write landed
    per the pre-triage-swallow section above, log a private note explaining
    why); a name/company mentioned in text with no phone match - or a phone
    search with zero or multiple hits - falls back to the same flagged-note
    pattern as before (now split into NEEDS CONTACT CREATED / NEEDS CONTACT
    VERIFIED depending on whether a possible match exists). mcp__Halo__
    create_contact exists in halopsa-mcp and could create a new contact
    outright, but is deliberately NOT in $resolverTools - fabricating a new
    identity from unverified voicemail/email text stays a human-supervised
    step, never something this pipeline does on its own. $resolverTools
    itself needed no changes - list_contacts/get_contact/update_ticket were
    already granted, just not previously usable for this purpose.
    Version: 2.9.2 - fixed the deeper cause behind ticket #21568 staying
    missed even after v2.9.1's classifier-logic fix: it never reached the
    classifier at all. mcp__Halo__list_tickets had no agent/team filter of
    its own - only count/open_only/client_id/search - so the classifier's
    "call it once with open_only: true" instruction silently returned just
    the ~20 most-recently-active open tickets account-wide, out of a real
    213 open (confirmed live). A ticket that goes quiet - exactly what
    happened after #21568 was privately noted and reassigned - ages out of
    that window with no error or signal that it happened. Raising count
    doesn't work either: each row carries full ticket body text, and count:
    30 alone already exceeded Claude Code's own response-size limit in a
    live test, let alone 213.
    Real fix required changing the underlying tool, not just this repo:
    added agent_id and pageinate/page_no/page_size to halopsa-mcp's
    list_tickets (rafouche/MCPs, commits b9a0c4e/3f7d8ab), confirmed against
    HaloPSA's own live REST API v2 swagger spec, then verified live post-
    deploy (agent_id: 1 correctly returned only unassigned tickets;
    page_size: 10 pagination returned exactly one page plus an accurate
    record_count). classifier-prompt.md's "Find candidate tickets" now
    makes two agent_id-filtered calls instead of one unfiltered one:
    agent_id: 1 (Halo's real "Unassigned" agent) capped at page 1/15 - an
    old unassigned ticket is a slower-moving gap, not worth a full sweep
    every 10 minutes - and agent_id: {{AGENT_ID}} (this bot's own tickets)
    paged through in FULL regardless of record_count, since that set should
    always be small and must never silently truncate - that's exactly the
    #21568 failure shape. Did not add HaloPSA's `team` filter - its swagger
    types it as a bare string despite being "array of int," meaning the
    wire encoding isn't documented and wasn't safe to guess; client-side
    team_id filtering on the (now much smaller) combined results stays as
    it was.
    Version: 2.9.1 - fixed a real missed-ticket bug found via a live report
    (ticket #21568): a human agent did the work, documented it in a PRIVATE
    note (`hiddenfromuser: true`), reassigned the ticket to the bot, and set
    it to "waiting on client" expecting a client-facing follow-up - but no
    client-facing reply had ever gone out, and the classifier dropped the
    ticket anyway. Root cause, confirmed against ticket #21568's real
    mcp__Halo__get_ticket/get_ticket_time_entries/list_statuses responses
    (not assumed): classifier-prompt.md's "drop already-claimed tickets with
    nothing new to act on" check used mcp__Halo__get_ticket, whose schema has
    no field distinguishing a client-facing reply from an internal-only note
    - only the action log's `hiddenfromuser` flag can - so the check had no
    way to tell "we already told the client" from "someone just talked to
    themselves." Fixed by swapping that check onto
    mcp__Halo__get_ticket_time_entries (now in $classifierTools;
    mcp__Halo__get_ticket removed from that list since nothing in
    classifier-prompt.md calls it anymore) and adding a third "include as
    candidate" case: the most recent substantive action-log entry is a
    private note describing real work - written by the bot in an earlier
    cycle OR by a human colleague handing the ticket off - with no public,
    client-facing reply sent since. Also added a small clarifying addition
    to resolver-prompt.md's NEW/ONGOING/EMERGENCY CANDIDATE classification so
    a ticket in exactly this state is treated as NEW (client still owed a
    first reply) rather than mistaken for ONGOING, while still using the
    private note as prior art instead of re-diagnosing from zero.
    Version: 2.9.0 - added a compliance-driven client exclusion list
    (config.json's new `compliance.excluded_client_names`), prompted by a
    direct question about PCI/HIPAA/GLBA/SOX exposure from routing ticket
    data through a third-party AI API. Resolved the same way as team/status/
    agent names (one mcp__Halo__list_clients call in Stage 0, only if the
    list is non-empty), but treated as a hard-fail-if-unresolved field
    unconditionally (not gated behind any switch) - unlike every other
    optional field in this pipeline, a name here that fails to resolve
    aborts the whole cycle, since silently under-protecting a client is the
    one failure mode this feature exists to prevent.
    Checked directly before building this: mcp__Halo__list_tickets only
    supports an INCLUDE filter for a single client_id, no exclude/negative
    filter and no bulk multi-client filter - so this control cannot stop the
    classifier's account-wide list_tickets scan from seeing an excluded
    client's ticket subject/summary line as an unavoidable side effect of how
    it builds a candidate list every cycle (documented plainly in
    config.json's own compliance._comment, not glossed over). What it DOES
    reliably stop, checked as the very first thing in both
    classifier-prompt.md (drop from candidacy immediately, no exceptions)
    and resolver-prompt.md (a new check ahead of "Claim the ticket" that
    overrides every other exception in the document, including the emergency
    on-call-acknowledgment carve-out under -RequireApproval): the deep
    investigation, every downstream Ninja/Huntress/CIPP/Meraki/UniFi tool
    call, and any reply/action. This is prompt-level enforcement (same trust
    tier as this system's other safety rules), not a physical tool-removal
    like -WhatIf's - there's no tool-allowlist mechanism that can filter by
    ticket content, only by tool name.
    Version: 2.8.1 - two findings from real -WhatIf/-RequireApproval runs.
    First: on a ticket Halo hasn't triaged yet (a distinct Halo workflow step,
    not just a status value), mcp__Halo__update_ticket can silently accept a
    note/agent_id/team_id change and report success while it never actually
    lands - only status_id reliably takes effect pre-triage. No tool here can
    trigger Halo's triage directly, so resolver-prompt.md now has a dedicated
    section requiring a re-fetch-and-confirm after every note/assignment
    write, one retry via a status-only update (unverified whether this
    actually triages the ticket, but cheap to try), and a stop-and-flag if it
    still doesn't land - this is a detection/mitigation fix, not a root-cause
    fix, since nothing available can confirm or drive Halo's real triage
    mechanism from here. The -RequireApproval FLOW A/FLOW B banner text now
    points at this same section too, since their whole mechanism depends on a
    note actually landing. Second: confirmed directly (no create-contact tool
    and no user/contact parameter on update_ticket exist in this toolset) that
    there's currently no way to create a new Halo contact or relink a ticket
    to one - a real scenario when a new employee at an existing client emails
    in before their contact record exists. resolver-prompt.md now has the
    agent flag this with a "NEEDS CONTACT CREATED - " internal note carrying
    the company/name/email it found in the ticket body, rather than attempt
    something no available tool can actually do. See CLAUDE.md's "Known gaps"
    section for what halopsa-mcp would need to add to close this for real.
    Version: 2.8.0 - added -RequireApproval, a human-sign-off mode for the
    transition from -WhatIf testing to unsupervised live running (see the
    .PARAMETER RequireApproval block above for the full mechanics). Two new
    optional config.json fields (halo.ai_waiting_approval_status_name/
    ai_approved_status_name, blank unless you're using the switch) resolved
    from the SAME list_statuses call Stage 0 already makes for the other three
    statuses - no extra tool call. A new "APPROVED" tier (cheap model, since
    it's a mechanical replay, not fresh diagnosis) drives a per-ticket tool
    selection that didn't exist before this version: which tool list a ticket
    gets now depends on that ticket's OWN tier, not just a single cycle-wide
    switch, since an APPROVED ticket needs the full mutating toolset to
    execute what was approved while every other ticket under -RequireApproval
    gets remediation-mutating tools physically removed. classifier-prompt.md
    and resolver-prompt.md themselves are unchanged - the whole feature is an
    "approval banner" built at runtime from Stage 0's resolved IDs and
    prepended to each prompt only when the switch is active, same pattern as
    the existing -WhatIf simulation banner, so a run without the switch is
    byte-for-byte the same prompt as before this version. Confirmed directly
    (not assumed) that mcp__Halo__update_ticket has no way to edit or delete
    an existing note - only add a new one - so "delete the private draft note"
    from the original ask is implemented as "add a note marking the draft
    historical" instead; see CLAUDE.md for why a literal delete isn't
    possible here.
    Version: 2.7.3 - the first -WhatIf run after the halopsa-mcp fix landed
    caught a real edge case: ticket 21577 showed agent_id: 1 (the unassigned
    sentinel) but its action history (now readable thanks to that fix) showed
    a human colleague actively coordinating an on-site visit and a vendor
    part - Halo appears to clear the assignment as a side effect of a
    "Waiting on vendor" status change, not because the ticket is actually
    free. The resolver caught this correctly on its own judgment, but
    resolver-prompt.md never told it to check for this, so it was relying on
    the model happening to look - the same class of gap as the original
    agent_id: 0 vs 1 sentinel ambiguity. resolver-prompt.md's "Claim the
    ticket" section now explicitly says to pull action history before
    claiming an agent_id: 1 ticket and treat recent human activity on it the
    same as an explicit different-agent assignment.
    Version: 2.7.2 - no code or prompt change, CLAUDE.md correction only. A
    separate session fixed halopsa-mcp itself: 5 of its tools (including
    get_ticket_time_entries/list_time_entries) were silently 404ing because
    they called resource paths that don't exist in HaloPSA's live API -
    confirmed against the real OpenAPI spec and verified live. Once pointed
    at the right path, get_ticket_time_entries turns out to be HaloPSA's
    ticket conversation/notes endpoint, not a time-tracking-only endpoint -
    proving the "no tool exists for ticket notes" conclusion in v2.7.1's
    CLAUDE.md entry wrong. Nothing here needed to change: get_ticket_time_entries
    was already in $resolverTools, and resolver-prompt.md's step 1 already
    told the resolver to read "notes/time entries" - both were already
    correct, only the tool underneath them was broken, and that's fixed
    upstream now. See CLAUDE.md's corrected entry for the full trace and the
    methodology lesson (a tool's description isn't the same as a live call).
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
    [switch]$WhatIf,
    [switch]$RequireApproval
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
    "mcp__Halo__list_agents", "mcp__Halo__list_ticket_types",
    # list_clients: only actually called when config.json's
    # compliance.excluded_client_names is non-empty (id-resolver-prompt.md's own
    # instruction, not enforced here) - granted unconditionally since it's cheap
    # to have available and the alternative (conditionally building this array)
    # isn't worth the complexity for one more tool name.
    "mcp__Halo__list_clients"
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
# NOTE: get_ticket is deliberately NOT here either (removed after ticket #21568
# revealed the classifier needs get_ticket_time_entries instead - see .NOTES
# version history). get_ticket's schema has no field distinguishing a
# client-facing reply from an internal-only note, so it can't actually answer
# "has anything new happened since we last touched this ticket" - only the
# action log's hiddenfromuser flag can. classifier-prompt.md's own text still
# tells the model not to reach for get_ticket, so there'd be nothing for it to
# call even if it were left in.
# NOTE: list_tickets itself required a fix in the underlying halopsa-mcp
# server (rafouche/MCPs), not just here, before ticket #21568 could actually
# be found: it had no agent/team filter at all, so it silently returned only
# the most recent ~20 open tickets account-wide (each row carries full body
# text, so even a larger count exceeds Claude Code's own response-size limit
# well before reaching the true end of the backlog - confirmed live, count:30
# already failed). halopsa-mcp now accepts agent_id (single agent, forwarded
# straight to HaloPSA's own /Tickets filter) and pageinate/page_no/page_size
# (HaloPSA's real pagination) - see classifier-prompt.md's "Find candidate
# tickets" section for how the classifier uses these instead of one
# unfiltered pull. This tool array doesn't change for that fix (list_tickets
# was already here) - only the prompt's instructions for how to call it did.
$classifierTools = @(
    "Read", "ToolSearch",
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket_time_entries"
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

# Subset of $mutatingTools that -RequireApproval strips from a non-APPROVED-tier
# ticket (see the per-ticket tool selection below). Deliberately narrower than
# $mutatingTools: mcp__Halo__update_ticket itself CANNOT be stripped here, because
# -RequireApproval's own "draft note + AI Waiting Approval status + unassign"
# bookkeeping (see the approval banner below) is itself a real update_ticket call
# that must succeed - only the CONTENT of that call (private draft vs. a real
# public reply) tells the two apart, which isn't something a tool allowlist can
# enforce. mcp__Microsoft365__outlook_send_mail is also deliberately absent - the
# on-call notification it sends is an internal alert to Altec's own team, not
# client correspondence, so it's never gated. What CAN be enforced at the
# allowlist level - and is - is that a non-APPROVED-tier ticket physically cannot
# call a remediation action, regardless of what the prompt says.
$remediationMutatingTools = @(
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device"
)

# Base allowlist plus one pre-filtered variant for -RequireApproval, computed
# once here - the per-ticket loop below picks which one a given ticket actually
# gets, since -RequireApproval's filtering depends on that ticket's own tier
# (APPROVED vs. everything else), not a single cycle-wide switch. -WhatIf's own
# filtering (by $mutatingTools, a superset of $remediationMutatingTools) is
# applied inline in that same loop instead of precomputed here, since it always
# applies uniformly regardless of tier - no per-ticket variant needed for it.
$resolverToolsFull = $resolverTools
$resolverToolsApprovalStripped = $resolverToolsFull | Where-Object { $remediationMutatingTools -notcontains $_ }
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
    # APPROVED (-RequireApproval only): a human already approved a previously
    # drafted reply/remediation - this pass replays it rather than re-diagnosing,
    # so it gets the cheap model like TRIVIAL does, regardless of how complex the
    # original ticket was.
    "APPROVED"          = $config.claude.resolver_model_trivial
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
    Write-Host "RequireApproval (human sign-off) mode: $RequireApproval"
    if ($RequireApproval) {
        Write-Host "  NOTE: the approval banner (FLOW A/FLOW B, per-ticket tool selection)" -ForegroundColor Yellow
        Write-Host "  is built from Stage 0's resolved IDs and isn't shown below - it doesn't" -ForegroundColor Yellow
        Write-Host "  exist yet at -DryRun's no-Halo-calls preview stage. Run -WhatIf" -ForegroundColor Yellow
        Write-Host "  -RequireApproval together to see it for real without touching Halo." -ForegroundColor Yellow
    }
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
    Write-Host "Model by tier: TRIVIAL/TRIVIAL_UNCERTAIN=$($modelForTier['TRIVIAL']), MEDIUM=$($modelForTier['MEDIUM']), COMPLEX=$($modelForTier['COMPLEX']), APPROVED=$($modelForTier['APPROVED'])"
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
        help_desk_team_name              = $config.halo.help_desk_team_name
        agent_username                   = $config.halo.agent_username
        resolved_status_name             = $config.halo.resolved_status_name
        waiting_on_client_status_name    = $config.halo.waiting_on_client_status_name
        follow_up_status_name            = $config.halo.follow_up_status_name
        ai_waiting_approval_status_name  = $config.halo.ai_waiting_approval_status_name
        ai_approved_status_name          = $config.halo.ai_approved_status_name
        excluded_client_names            = $config.compliance.excluded_client_names
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

    # ai_waiting_approval_status_id/ai_approved_status_id are optional everywhere
    # above (a blank config value resolves to null on purpose, not a failure) -
    # but -RequireApproval can't function at all without both, so it gets its own
    # hard check here rather than joining the always-required list above.
    if ($RequireApproval) {
        $missingApprovalFields = @()
        foreach ($field in @("ai_waiting_approval_status_id", "ai_approved_status_id")) {
            if ($null -eq $ids.$field) { $missingApprovalFields += $field }
        }
        if ($missingApprovalFields.Count -gt 0) {
            throw "-RequireApproval needs both halo.ai_waiting_approval_status_name and halo.ai_approved_status_name set in config.json to real Halo status names, but $($missingApprovalFields -join ', ') did not resolve - create both as custom statuses in Halo first (see README's 'Human approval mode' section), then set their exact names in config.json."
        }
    }

    # excluded_client_ids is [] when compliance.excluded_client_names is empty
    # (the normal case) and null specifically when one or more configured names
    # failed to resolve - this is a compliance boundary, unconditional on any
    # switch, so a resolution failure aborts every run, not just -RequireApproval
    # ones. Never let this cycle proceed on a guess about which clients are
    # actually protected.
    if ($null -eq $ids.excluded_client_ids) {
        throw "compliance.excluded_client_names has one or more names that didn't match a real Halo client - check config.json's compliance section against Halo's actual client list (mcp__Halo__list_clients), or the cycle would run without knowing for certain which clients are protected."
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

    # excluded_client_ids was already validated non-null above - [] (nothing
    # configured, the common case) renders as a plain "none" so the classifier/
    # resolver aren't left comparing against literal empty-array text.
    $excludedClientIdsText = "none"
    if ($ids.excluded_client_ids -and @($ids.excluded_client_ids).Count -gt 0) {
        $excludedClientIdsText = (@($ids.excluded_client_ids) -join ", ")
    }

    if ($usedCachedIds) {
        # Log a lightweight confirmation, not the full claude-call section (there
        # was no claude call this cycle) - shaped like a no-cost claude response so
        # Show-AgentLog.ps1 renders it the same way as every other section instead
        # of hitting its "couldn't parse" fallback.
        $cacheNoteContent = [PSCustomObject]@{
            result = "Using cached IDs from $cachedResolvedAt (age $([math]::Round($cachedAgeHours,1))h, cache max age ${idCacheMaxAgeHours}h): team_id=$($ids.team_id), agent_id=$($ids.agent_id), resolved_status_id=$($ids.resolved_status_id), waiting_status_id=$($ids.waiting_status_id), followup_status_id=$($ids.followup_status_id), ai_waiting_approval_status_id=$($ids.ai_waiting_approval_status_id), ai_approved_status_id=$($ids.ai_approved_status_id), excluded_client_ids=[$excludedClientIdsText], ticket_type_names_count=$ticketTypeCount"
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
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{EXCLUDED_CLIENT_IDS\}\}', $excludedClientIdsText
    $resolverPromptTemplate = $resolverPromptTemplate `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{EXCLUDED_CLIENT_IDS\}\}', $excludedClientIdsText `
        -replace '\{\{RESOLVED_STATUS_ID\}\}', $ids.resolved_status_id `
        -replace '\{\{WAITING_STATUS_ID\}\}', $ids.waiting_status_id `
        -replace '\{\{FOLLOWUP_STATUS_ID\}\}', $ids.followup_status_id

    # --- Approval-mode banners (-RequireApproval only) - built here, not up with
    #     $simulationBanner, because they need $ids.ai_waiting_approval_status_id/
    #     ai_approved_status_id, which only exist after Stage 0 resolves (or loads
    #     from cache) above. See CLAUDE.md's "Human approval mode" section for the
    #     full design rationale. ---
    if ($RequireApproval) {
        $classifierApprovalBannerLines = @(
            "=== APPROVAL MODE (-RequireApproval) ===",
            "This run requires human sign-off before any client-facing reply or",
            "remediation action happens for real - see the resolver's own approval-mode",
            "banner for what that means downstream. It changes two things about how you",
            "build today's candidate list:",
            "",
            "1. SKIP ENTIRELY any ticket whose status_id is $($ids.ai_waiting_approval_status_id)",
            "   (config's ai_waiting_approval_status_name) - it already has a drafted",
            "   reply/action sitting in a private note, waiting on a human to review. Do",
            "   not include it as a candidate; re-processing it wastes cost and risks",
            "   clobbering the pending draft.",
            "2. DO include any ticket whose status_id is $($ids.ai_approved_status_id)",
            "   (config's ai_approved_status_name) as a candidate, even though it's still",
            "   unassigned (agent_id: 1) - a human approved its draft and it's ready to",
            "   actually send. Tag it with tier `"APPROVED`" specifically, not your usual",
            "   TRIVIAL/MEDIUM/COMPLEX judgment - this ticket's tier was already decided",
            "   last cycle; your only job for it now is flagging it so the resolver runs",
            "   its approval-completion flow instead of tiering it fresh.",
            "",
            "Every other candidate-selection/tiering rule in this document still applies",
            "as normal to every other ticket.",
            "==="
        )
        $classifierPrompt = ($classifierApprovalBannerLines -join "`n") + "`n`n" + $classifierPrompt

        $approvalBannerLines = @(
            "=== APPROVAL MODE (-RequireApproval) ===",
            "This run requires a human to sign off before any client-facing reply or",
            "remediation action happens for real. Two flows - which one applies depends",
            "on the tier given above.",
            "",
            "FLOW A - tier is APPROVED (a human already approved this ticket's draft):",
            "skip everything else in this document, including re-diagnosing - do only",
            "this:",
            "1. Get this ticket's notes/actions (mcp__Halo__get_ticket_time_entries -",
            "   despite the name, this is HaloPSA's ticket conversation/notes endpoint)",
            "   and find the ONE private note starting with the exact line",
            "   `"[DRAFT PENDING APPROVAL]`". If you find zero or more than one, stop -",
            "   add an internal note flagging the mismatch and do nothing else; don't",
            "   guess which draft is the real one.",
            "2. Read its structure: the text after that first line is the exact",
            "   client-facing reply a human approved, verbatim - don't edit, improve, or",
            "   shorten it. A line `"[INTENDED STATUS] <name>`" names the status to set",
            "   afterward. A line `"[INTENDED ASSIGNMENT] keep`" or `"...unassign`" says",
            "   whether to stay assigned to yourself or hand back to the Help Desk queue",
            "   unassigned. A line `"[INTENDED REMEDIATION] none`" or `"...  <description>`"",
            "   names the exact whitelisted remediation action, if any, queued for this",
            "   ticket, with enough detail (target device/account) to actually perform it",
            "   now.",
            "3. Assign yourself to the ticket (mcp__Halo__update_ticket, your resolved",
            "   agent_id) - its own call, before anything else below. Verify it landed",
            "   per resolver-prompt.md's untriaged-ticket section before proceeding - the",
            "   fact you found a draft note at all means a PRIOR write landed, but that",
            "   doesn't guarantee THIS one will.",
            "4. If [INTENDED REMEDIATION] isn't `"none`": perform EXACTLY that action now,",
            "   matching the remediation whitelist the same way you always would. Can't",
            "   tell exactly what it meant (which device, which account)? Stop and flag it",
            "   in an internal note rather than guessing or substituting a different",
            "   target. Real time has passed and you're no longer confident this specific",
            "   action is still safe to run as recorded? Say so in an internal note and",
            "   stop rather than run stale intent blindly.",
            "5. Post the approved text from step 2 as a real, public, client-facing reply",
            "   (mcp__Halo__update_ticket, note_is_private: false) - its own call,",
            "   unchanged from what was drafted.",
            "6. There is no tool that can delete or edit an existing Halo note -",
            "   update_ticket can only add a new one. So instead of literally deleting the",
            "   draft, add one more private note in the same final call as step 7:",
            "   `"Approved and sent - see the reply above. (The draft note above is now`"",
            "   `"historical, not pending.)`" - this keeps the record unambiguous for anyone",
            "   reading the ticket later, without a delete that isn't actually possible.",
            "7. In that same call: set status to [INTENDED STATUS] and agent_id/team_id",
            "   per [INTENDED ASSIGNMENT] (unassign -> agent_id: 1, team back to",
            "   help_desk_team_name - same as any other escalation; keep -> leave assigned",
            "   to yourself). Verify steps 5-7 all actually landed per",
            "   resolver-prompt.md's untriaged-ticket section before your summary below -",
            "   don't report `"sent`" if the reply never actually posted.",
            "8. Print your one-line summary and stop - nothing else in this document",
            "   applies to an APPROVED-tier ticket (Hudu documentation, if warranted,",
            "   already happened when the draft was written).",
            "",
            "FLOW B - every other tier: work the rest of this document completely",
            "normally (investigate, judge difficulty, decide on a reply and/or a",
            "remediation action) with one change at the very end. Wherever this document",
            "would have you send a real, public, client-facing reply OR take a",
            "remediation action (password reset/unlock/reboot/script run), do this",
            "instead, in one update_ticket call:",
            "1. note: a single private note, in this exact structure - `"[DRAFT PENDING",
            "   APPROVAL]`" on its own line, then the full client-facing reply text you",
            "   would have sent, verbatim, exactly as you'd have sent it live; then a line",
            "   `"[INTENDED STATUS] <name>`" (whichever this document's own rules would",
            "   have set - resolved_status_name/waiting_on_client_status_name/",
            "   follow_up_status_name); then a line `"[INTENDED ASSIGNMENT] keep`" or",
            "   `"...unassign`" (keep if you'd have stayed assigned to yourself -",
            "   Resolved/Waiting on client -, unassign if you'd have handed it back to the",
            "   queue - Follow Up Needed/escalation); then a line",
            "   `"[INTENDED REMEDIATION] none`" or `"...  <exact whitelisted action +",
            "   target>`" (e.g. `"Reset M365 password for jsmith@client.com`" or `"Run",
            "   NinjaOne script 'Reset Printing' on device WKS-1234`") - specific enough",
            "   that FLOW A can execute this exact action later without re-diagnosing.",
            "2. note_is_private: true.",
            "3. status_id: $($ids.ai_waiting_approval_status_id) (ai_waiting_approval_status_name).",
            "4. agent_id: 1 (unassign yourself - visibly free/pending, not stuck showing",
            "   as yours while it waits).",
            "Verify this call actually landed per resolver-prompt.md's untriaged-ticket",
            "section - an untriaged ticket can silently drop the note/agent_id part of",
            "this exact call while still applying the status_id part, which would leave",
            "the ticket looking like it's waiting for approval with nothing to actually",
            "approve. Do not actually take the remediation action, and do not post any",
            "real client-facing reply this cycle - only the private draft note above.",
            "",
            "ONE EXCEPTION: the brief EMERGENCY acknowledgment (`"We've identified this as",
            "a priority issue and are notifying our on-call engineer now`") still sends",
            "for real, immediately, exactly as the emergency section describes - on-call",
            "is already being paged at the same moment, so this one message isn't held",
            "back. Only the detailed follow-up reply (once you've actually investigated)",
            "goes through the draft/approve flow above. The on-call notification itself",
            "(email/text) is never gated either - it's an internal alert to your own team,",
            "not client correspondence.",
            "",
            "Everything else in this document (investigation, judgment, Hudu",
            "documentation) still happens normally under FLOW B - only the outgoing",
            "reply/remediation is held back.",
            "==="
        )
        $approvalBanner = $approvalBannerLines -join "`n"
    }

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
        if ($RequireApproval) {
            $resolverPrompt = $approvalBanner + "`n`n" + $resolverPrompt
        }
        if ($WhatIf) {
            $resolverPrompt = $simulationBanner + "`n`n" + $resolverPrompt
        }

        # Which tool list a ticket gets depends on ITS OWN tier, not just the
        # cycle-wide switches - an APPROVED ticket needs the full mutating set to
        # actually execute what was approved, while every other ticket under
        # -RequireApproval gets the remediation-mutating tools physically removed
        # (see $resolverToolsApprovalStripped above). -WhatIf's full strip always
        # applies on top, regardless of tier, since nothing should touch anything
        # real in a simulation run.
        $ticketTools = $resolverToolsFull
        if ($RequireApproval -and $tier -ne 'APPROVED') {
            $ticketTools = $resolverToolsApprovalStripped
        }
        if ($WhatIf) {
            $ticketTools = $ticketTools | Where-Object { $mutatingTools -notcontains $_ }
        }

        try {
            $resolverResult = Invoke-ClaudeCLI -Prompt $resolverPrompt -Tools $ticketTools `
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
