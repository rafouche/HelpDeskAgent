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
    Version: 2.13.3 - Roger: "Allie is touching tickets outside of the Help
    Desk queue!" (2026-09-22). She isn't. The Alerts / System Admin tickets
    in question (#22488, #22489, backup alerts) carry actions by who=Allie,
    who_agentid 17, actionby_application_id "Acronis Client Portal": Halo's
    Acronis integration app is bound to the Allie agent account and has
    posted every Acronis ticket that way since at least 2026-08-22 (#21047,
    #21066). No action with application id "Claude" exists on any ticket
    outside Help Desk; the pipeline logs never mention those ids; both
    classifiers filter on team_id. The fix is in Halo (bind the Acronis
    application to its own agent). Here: "Acronis Client Portal" joins the
    default integration app ids (pipeline.integration_application_ids and
    halopsa-mcp's human_touch ignore list), and the deterministic path's
    "ours" test no longer counts an integration app posting through our
    agent id as ours.
    Version: 2.13.2 - the re-processing loop behind Monday's $28 day
    (2026-09-21). Three tickets (#22459, #22460, #22466) were resolved five
    times each: a technician claimed each pending draft (bare Re-Assign +
    Triage, no note), Halo's automation then posted a "Ticket In Progress
    Email" entry, and from then on both classifiers saw "an entry newer than
    our draft" every cycle. The resolver correctly did nothing each time -
    at ~$0.35 a pass, twelve times, with nothing to show for it. Two fixes,
    both paths. (1) What counts as a change: entries by System/Automation
    (who_type 0 - Halo rules, HaloAI triage, automation emails) never do,
    and a bare Triage/Re-Assign with no note text is bookkeeping, not news
    (Invoke-DeterministicClassifier's $isSubstantive; the same sentence in
    classifier-prompt.md's tracked and waiting-approval rules). (2) A
    watermark: when the resolver looks at a ticket and prints [CACHE:
    TRACK], the cycle's start time (UTC) is stored as tracked_evaluated[id]
    in agent-cache.json; the deterministic path drops a tracked or
    waiting-approval ticket whose newest substantive entry is not after that
    time, and the LLM classifier is shown "(evaluated through <time>)" next
    to each tracked id with the same rule. So a human claim is looked at
    once, then ignored until something genuinely new lands. Also: the
    tiering call's "no valid tier" warning now includes the raw response so
    the next one is diagnosable (it hit the three repeat tickets every
    cycle today and silently defaulted them to MEDIUM).
    Version: 2.13.1 - two corrections from Roger the same afternoon.
    (1) The on-call page: the alert-ticket design (v2.13.0) put a second
    ticket in front of the technician with no link to the real one, plus
    Halo's automatic confirmation email on top - "muddies up the workflow".
    Replaced: the page is now ONE hidden emailed action on the original
    ticket itself (outcome 16 with emailto/emailcc overrides to the on-call
    address and the SMS gateway, hiddenfromuser true). Halo does send mail
    for a hidden action - confirmed on the scratch ticket #22417: email_status
    2, dateemailed set, emailto roger@, emailcc the gateway, hidden. So the
    technician gets one email and one text whose subject carries the real
    ticket id, the client sees nothing, no second ticket exists, and the
    note text on the ticket is the audit trail. ON_CALL_MODE "ticket" is the
    Worker default (ON_CALL_EMAIL, ON_CALL_CC_EMAILS); "halo" and "m365"
    remain selectable. #22417 is closed.
    (2) "Drafts not collapsing into Approved Draft again": #22390's reply
    went out at 14:05 but its draft note still read [DRAFT PENDING
    APPROVAL] and its status notes stayed - FLOW A's steps 5/6/6.5/7 were
    four separate tool calls the model could, and did, stop partway
    through. halopsa-mcp's new send_approved_draft does all of it in one
    atomic call (address correction, verbatim send of the draft's own
    text, collapse, [PIPELINE NOTE] cleanup, status/agent/team, verify) and
    can only ever send text already sitting in a human-approved draft.
    FLOW A step 5 is now that one call; steps 6/6.5/7 are gone. The tool is
    APPROVED-tier only and stripped under -WhatIf.
    Version: 2.13.0 - emergencies bypass draft mode, and on-call paging
    finally exists. Roger's decision after ticket #22385: a site-wide 3CX
    outage on a Saturday morning sat as an unsent draft under
    -RequireApproval, and the on-call page never happened because the
    "Microsoft365" MCP server the prompt relied on for it was never
    registered on the server (see the note above its allowlist entries) -
    which means on-call notification had NEVER worked, in any mode. Fixed
    without giving up the structural guarantee: halopsa-mcp's new
    escalate_emergency posts a FIXED, templated acknowledgment (caller
    supplies one summary phrase, max 200 chars, no links), pages on-call
    through m365-mcp's new send_on_call_alert - whose sender and
    recipients are Worker secrets, never arguments - writes an
    '[EMERGENCY ACK SENT]' audit note, sets status/assignment, and refuses
    to run twice on one ticket. It is the one sending tool that survives
    -RequireApproval (still stripped under -WhatIf). The prompt's emergency
    and compromise sections and the approval banner now name it; the old
    "email on-call yourself" instructions are gone. The page itself goes
    through Halo's own mail (an internal alert ticket under Altec Solutions
    Group for the on-call contact, in the Alerts / System Admin team the
    Help Desk pipeline never reads, with the SMS gateway CC'd) - no Graph,
    no new credentials; the m365-mcp path was tried first and dropped
    because that Worker was never configured and CIPP can't send mail
    (no endpoint, no Mail.Send). On-call contacts are halopsa-mcp
    wrangler vars (ON_CALL_USER_ID, ON_CALL_CC_EMAILS, ...), not (only)
    config.json - README says so. Verified live: page_test delivered as
    alert ticket #22417 to roger@altecusa.com + the SMS gateway.
    Version: 2.12.3 - Roger's request from ticket #22385 (Springfield
    Nissan's 3CX down on a Saturday morning, emailed to admin@altecsales.com
    and forwarded into help@ by hand hours later): when a ticket's first
    message is visibly a forward of the client's email from one of our own
    mailboxes, the first client-facing reply adds one warm, explanatory
    paragraph - after the actual answer, never as a correction - saying
    that help@ (or a call) creates a ticket and notifies the whole team
    immediately, while an individual inbox creates no ticket and isn't
    monitored. Once per ticket, never when the client already wrote to
    help@, never when the forward came from the client's own side. The
    intake address and our domains come from config.json's halo block
    (help_desk_email, internal_email_domains) with defaults that match
    this deployment, so no config change is needed. #22385 added to the
    replay list with the reply required to mention help@.
    Version: 2.12.2 - three follow-ups from Roger on #22389/#22390:
    - "assume it's a remote worker if there isn't a contact" (BEC CFO):
      config.json's halo block takes contact_default_sites, { "<client>":
      "<site>" }, rendered into the resolver prompt as
      {{CONTACT_DEFAULT_SITES}}; the multiple-sites rule consults it first,
      then the ticket's own site, then the client's primary.
    - "will all the previous notes get cleaned up?": a note convention.
      Status notes (waiting on a human: needs contact, holding, mismatch)
      start with the line [PIPELINE NOTE]; findings never do. halopsa-mcp's
      delete_ticket_note now also accepts that marker, but only on a note
      whose actionby_application_id is "Claude". FLOW A step 6.5 deletes
      every such note once the approved reply has actually sent. The notes
      already sitting on #22389/#22390 predate the marker and won't be
      auto-removed.
    - "the VPN ticket didn't mention not using VPNs for work": the
      personal-VPN first reply now states the policy and offers a business
      VPN in the same message as the "was this you?" question, instead of
      saving both for a second round.
    Version: 2.12.1 - two live tickets looping the morning after v2.12.0
    shipped (#22389, #22390, both Huntress ITDR escalations Roger approved
    at 22:58). Not v2.12.0's code - the deterministic classifier was in
    shadow mode, its answer unused - but three real defects in the approval
    flow that the same cycle exposed:
    - #22389: the LLM classifier tiered an AI-Approved, unassigned ticket
      COMPLEX from its content in call 1, then skipped it in call 6 as
      'already present'. The resolver ran FLOW B with the stripped tool
      set, could not call update_ticket ('denied by permissions'), left a
      mismatch note, and would have repeated that every cycle. Fixed
      three ways: classifier-prompt.md's call 1 now excludes both approval
      statuses by status_id; the approval banner's calls 5-6 now take
      precedence instead of yielding; and a PowerShell backstop after
      classification (one ticket-fields-only Worker call, history=0)
      forces APPROVED for any ticket currently in ai_approved_status_name,
      logged as TIER OVERRIDE. Fails open.
    - #22390: the approved reply had nowhere to go - the ticket was still
      on the generic 'General User' contact because resolver-prompt.md
      said 'multiple sites, create nothing'. The verified person was never
      the risk; the unreachable client was. That rule now creates the
      contact on the ticket's own site (or the client's primary) and says
      so in the note. FLOW A gained step 4.5: fix an unreachable contact
      for real before sending.
    - Both: every FLOW A stop left the ticket in AI Approved, which call 6
      re-selects unconditionally, so each stop repeated itself every 10
      minutes. Every FLOW A stop now moves the status back to AI Waiting
      Approval and prints [CACHE: UNTRACK].
    - Seen in the same logs: both tickets showed human_touch.found = true
      with no person involved, because Huntress posts its alert through a
      bound Halo agent account (who_type 1, actionby_application_id
      "Huntress"). The resolver reasoned its way past it this time; it
      would not have to every time. halopsa-mcp's human_touch now ignores
      integration accounts (Claude, Huntress; more via its
      HUMAN_TOUCH_IGNORE_APP_IDS var), and the deterministic classifier's
      own human test does the same (pipeline.integration_application_ids,
      default ["Huntress"]).
    Version: 2.12.0 - cost program increment 2: the deterministic classifier,
    behind pipeline.deterministic_classifier (default off) with a
    pipeline.classifier_shadow rollout aid (default off). The LLM classifier
    was 38-43% of every cycle's spend: 10-25 tool-calling turns re-reading
    the same tool schemas and ticket bodies to apply rules that are almost
    entirely mechanical. Now: halopsa-mcp's new GET /helpdesk-triage does
    classifier-prompt.md's calls 1-6 as plain Halo REST calls (every bucket
    trimmed, each ticket with its 6 most recent trimmed actions);
    Invoke-DeterministicClassifier applies the exclusions in PowerShell
    against the same caches the LLM was being handed as text (compliance,
    team, tracked/blocked/human-owned lists, waiting/follow-up status IDs,
    the workflow-status-name skip list - now config-editable as
    pipeline.skip_status_names - a colleague's client-facing reply as the
    latest entry, the tracked-ticket closed/reassigned/unchanged branches
    by dateclosed/agent_id/last substantive entry, and calls 5-6's
    "human touched since our draft" and APPROVED rules); then, only if any
    candidate still needs a tier, ONE no-tool tiering call (Invoke-ClaudeCLI
    -NoMcp: --strict-mcp-config against an empty MCP config, so it carries
    none of the ~90K-token tool-schema prefix) whose rules are read live
    from classifier-prompt.md's own "Classify each candidate" section - one
    text, two consumers. Nothing to tier means no LLM call at all. Any
    failure on this path throws and the cycle falls back to the LLM
    classifier with a WARNING line saying why. Rollout: turn
    classifier_shadow on first - the deterministic path runs alongside the
    LLM every cycle, a CLASSIFIER SHADOW COMPARISON log section shows both
    answers per ticket and the agreement count, and the LLM's answer is
    still the one used; after a day of agreement, turn
    deterministic_classifier on and shadow off. Verified: the route live
    against the real Help Desk queue (8 unassigned, 2 tracked, 6.9s), the
    exclusion logic against that live response with a stubbed tiering
    call, and -DryRun.
    Version: 2.11.6 - baseline3 read (8/10, $4.26): one harness gap, one
    limit that can't be engineered around, one variance note.
    - #22231's resolver described its draft ("a reassuring reply") instead
      of writing it, so the reply-only checks had nothing to read. The
      replay banner now requires the verbatim text of every note, draft,
      and reply it would write - the replay is scored on those words.
    - #22067's draft-revision replay is impossible, and not because of the
      harness: FLOW B deletes the superseded draft (delete_ticket_note)
      and FLOW A collapses the approved one to "[APPROVED DRAFT]", so the
      pending-draft state of any past ticket no longer exists in Halo -
      its action list skips ids 8/10/12 for exactly that reason. The
      resolver, given no draft to revise, correctly stopped with a note
      for a human and BLOCKED. keep_own_actions stays (it is right for a
      ticket whose draft is still live), #22067 goes back to a first-pass
      replay, and the rubric docs say why.
    - #22265 passed cleanly this run (asked Standard vs Pro, 17 turns) and
      failed baseline2 on the same rubric with no change in between. That
      is run-to-run variance; README now says how to read it (a single
      ticket flipping without a change is noise - judge a change on the
      whole list, and re-run the affected tickets before believing a
      one-ticket delta).
    Version: 2.11.5 - baseline2 (approval mode on, clock fixed): 7/10, $4.68.
    Two tickets untouched by any human at their as-of point (#22280 at
    20:34 on 09-16, #22067) still stopped HUMAN_OWNED in 6-9 turns. Cause:
    get_ticket_time_entries' human_touch.found is computed over the whole
    history as it stands today, and resolver-prompt.md rightly says to
    trust that field and not re-derive it - so the replay banner's "ignore
    later actions" lost to the prompt's own rule. Fixed at the tool, not
    with more prose: halopsa-mcp's get_ticket_time_entries and
    get_ticket_history take an optional as_of, drop every action after it,
    and compute human_touch over what's left; the banner now tells the
    resolver to pass it (the as-of timestamp, or the first client
    message's time when none was given) and that a human_touch from a
    call without as_of is today's and does not count. Also new:
    -ReplayKeepOwnActions (rubric field keep_own_actions), which keeps
    this pipeline's own notes dated at or before the as-of point in play
    instead of hiding them - the only way to replay a draft-revision
    (FLOW B) scenario such as #22067's, now judged at 20:42 on 09-11 with
    its pending draft, Roger's contact relink, and Roger's "ask what
    department" note all in place.
    Version: 2.11.4 - the other five baseline results read; two more harness
    defects, one rubric family, one open question.
    - Replay ran without -RequireApproval. Production runs with it, so every
      replay saw the non-approval flow: #22265 "sent" a real client email
      and set Follow Up Needed, which is not what production would do, and
      no FLOW A/FLOW B (draft revision) scenario can be replayed at all.
      Replay-Tickets.ps1 now passes -RequireApproval through, and when the
      switch isn't given it reads the registered scheduled task's own
      arguments ("Altec Halo Response Agent") and mirrors them - the
      replay runs in whatever mode production runs in, and says which.
    - The replay's clock was the wall clock. The baseline ran on a Saturday
      afternoon, so weekday tickets were judged "outside business hours"
      and took the hold-a-draft path (#22067, #22114, #22231, #22280),
      while #22265 reasoned from its own timestamp. With an as-of point,
      {{CURRENT_DATETIME}} and {{IS_BUSINESS_HOURS}} now come from it;
      without one, the banner says to judge from the first client
      message's timestamp. -ReplayAsOf is validated as a timestamp.
    - Regex over the whole output can't tell the client-facing reply from
      the internal note: #22265's internal note said "Standard vs.
      Professional" so should_mention passed, while the reply to the
      client was the vague "looping in our team" holding reply the rubric's
      own notes call the wrong outcome. New rubric fields
      reply_must_mention / reply_must_not_mention score only the
      client-facing reply text - the segment(s) from "Hi <name>," to the
      mandated "Here to help" sign-off - and a rubric that has them fails
      if no such segment exists. Applied across the seeded list.
    - #22067's rubric was checking the emailtolist lesson (v2.10.61) at the
      first client message, before the relink that created the mismatch
      existed - it could only ever pass by accident. as_of moved to
      2026-09-11T20:40, just after Roger relinked the contact.
    - #22114's warranty was never in the custom fields. get_device_custom_fields
      on device 3284 returns only mgmtLevel=Full (checked live 2026-09-19)
      and get_device had no warranty block, so the v2.10.57 fix pointed at
      the wrong surface and the replay's "no warranty record on file" was
      the honest answer. NinjaOne only returns the warranty block with
      expand=warranty on GET /v2/device/{id}; ninjarmm-mcp's get_device
      now sends it and adds warranty_summary (ISO start/end, expired flag,
      days_remaining). Verified live: 3284 ran 2020-07-20 to 2023-07-19.
      Rubric now requires the reply to say so.
    Version: 2.11.3 - first replay baseline read, three fixes from it. Roger
    ran Replay-Tickets.ps1 -Label baseline: 10 tickets, $4.94, 9/10 "pass"
    - but reading the actual results, not the score, the honest number is
    lower, for two harness defects and one allowlist gap:
    - Two tickets (#22296, #22297) ended [CACHE: HUMAN_OWNED] with zero
      investigation and still "passed" their regexes: the replay banner
      told the resolver to ignore actions after the as-of point but said
      nothing about the ticket's CURRENT agent_id/status, and both are held
      by a human today. Banner now says to reconstruct ownership from the
      action log alone and treat current assignment/closure as today's
      state, not the as-of state; Replay-Tickets.ps1 now fails any replay
      that ends HUMAN_OWNED or BLOCKED unless the rubric's new
      expected_marker lists it - a stop summary is not an investigation.
    - #22231 "failed" on must_not_mention "malware|compromise|phishing"
      because the resolver wrote "No malware/compromise indicators" - a
      negated mention my regex can't distinguish. Rubric tightened to
      positive claims only; eval/tickets.json's own comment now warns
      about this when writing must_not patterns.
    - #22300 passed for real - it found the 192.168.188.x range populated
      only by LT SECURITY cameras on VLAN 200 with the servers on VLAN
      1/100, exactly the v2.10.69 standard - but logged 4 permission
      denials on get_vlan/list_switch_ports/get_switch_port confirming it,
      because none of them, nor the list_vlans the v2.10.69 prompt text
      names explicitly, were ever in $resolverTools. Added all five
      read-only Meraki tools (list_vlans, get_vlan, list_switch_ports,
      get_switch_port, get_device); nothing mutating.
    Cost profile from the same run, for the record: Sonnet 5 low, $0.24-
    $1.10 per ticket, 5-45 turns, 23-394 seconds; #22265 (Adobe licensing)
    was the heaviest at 45 turns - the shape increments 3 and 4 target.
    Note for the deployment: eval/tickets.json is seed-once, so the rubric
    fix above does not reach a server that already has the file - delete
    the local copy once (it hasn't been edited there yet) and the updater
    re-seeds it on the next cycle.
    Version: 2.11.2 - the pre-flight gate now sends the Halo Worker's
    bearer token; companion to a security fix in rafouche/MCPs. While
    verifying increment 1's deployed Worker, a bare curl to its public
    workers.dev URL returned real ticket data with no credentials - and a
    credential-less tools/list on /mcp returned all 42 tools, write tools
    included. Every Worker in that repo was the same: the MCP client
    registrations had been sending "Authorization: Bearer <token>" all
    along (README's own `claude mcp add --header` instructions), but no
    Worker ever checked it. Not something this program introduced - a
    pre-existing gap found because the program's first verification step
    was to hit the route from outside. Reported to Roger immediately; no
    write tool was ever called during the check.
    Fix, in rafouche/MCPs (every Worker): an opt-in inbound check - once an
    MCP_AUTH_TOKEN secret is set on a Worker, every route except OPTIONS
    and /health requires that exact bearer token (constant-time compare);
    unset, behavior is unchanged, so the code deploys safely ahead of the
    switch. This script's part: the pre-flight gate's plain-HTTP call to
    /helpdesk-gate (and the /helpdesk-candidates feed increment 2 will
    add) now sends the same Authorization header the Halo entry in
    .mcp.json already carries, via the new Get-HelpDeskGateAuthHeader -
    read from the same file Get-HelpDeskGateBaseUrl already parses, never
    stored a second place. $null when the entry has no header, in which
    case the call goes out bare as before: still fine against a Worker
    whose secret isn't set, and fails open (classifier runs normally)
    against one that is. Unit-tested against a fake .mcp.json (header
    present / absent / file missing) and -DryRun'd before pushing.
    Version: 2.11.1 - Replay-Tickets.ps1 fix; no change in this script.
    Roger's first real run of v2.11.0's Replay-Tickets.ps1 failed on every
    ticket: "Cannot convert value 'C:\AltecAgents\HaloResponseAgent' to type
    System.Int32[]" on -ReplayTicketIds. Root cause: the wrapper splatted an
    ARRAY of "-Name", value pairs into this script (`& $main @args`), and
    array splatting binds elements positionally to a PowerShell script - so
    the string "-RootPath" landed in $RootPath, the folder path landed in
    the next positional parameter (ReplayTicketIds), and nothing was ever
    bound by name. Fixed with a hashtable splat (named binding), and the
    variable is no longer called $args (PowerShell's own automatic
    variable). Second, smaller find from the same test: ConvertFrom-Json
    turns the rubric's ISO as_of string into a [datetime], which then
    reached the replay banner culture-formatted ("09/17/2026 12:30:00");
    now re-formatted to ISO before use.
    Named plainly: v2.11.0 verified this script's replay mode directly
    (-DryRun, and in-process with two IDs) but never executed the wrapper
    itself, which is the piece that broke. Closed that gap the right way
    rather than by re-reading the code: a stub Invoke-HaloResponseAgent.ps1
    with the identical parameter block now stands in for the real one, and
    Replay-Tickets.ps1 is run against it end to end (run, subset, compare,
    score-only, summary.json) before pushing. Also ran the new
    Update-HaloResponseAgent.ps1 for real against an empty folder from raw
    GitHub main: all seven synced files landed, eval/tickets.json seeded
    into its new subfolder, a locally-edited copy was left alone on the
    second run, and the post-update -DryRun smoke test passed - the same
    path production took, confirmed here first this time.
    Version: 2.11.0 - cost/speed program, increment 0 (safety rails) - no
    change to what a scheduled run does. Roger asked for a review of the
    whole design for ways to cut cost and latency without touching
    client-facing behavior, then said "let's start building." A profile of
    his own 2026-09-17 production log showed where the money actually goes:
    a ~90K-token fixed prefix (tool schemas, the approval banner, Claude
    Code's own system prompt, resolver-prompt.md) re-read on every one of
    24-51 turns per call; a raw get_ticket payload of ~66-94K chars for one
    ordinary ticket, re-read on every later turn; and a classifier spending
    up to 51 turns and 245 seconds (38-43% of daily spend) to produce one
    line of JSON - while silently dropping a whole unassigned bucket once
    ("response too large to process") and probing nonexistent ticket IDs.
    The program ships as flag-gated increments (see the "pipeline" block
    this version adds to config.json - every flag defaults off, so nothing
    changes until a human flips one in this deployment's own never-synced
    config.json), each validated on real tickets first. This increment is
    the harness that makes "validated first" possible:
    - -ReplayTicketIds/-ReplayTier/-ReplayAsOf/-ReplayLabel/-ReplayKeepOwnActions: replay mode.
      Runs the resolver against named past tickets at a given tier, always
      as -WhatIf (mutating tools stripped, no cache write-back), skips the
      gate/throttle/classifier, prepends a replay banner telling the
      resolver to judge the ticket as it stood at the as-of time and to
      ignore this pipeline's own later notes/drafts, and writes one JSON
      result per ticket (cost, turns, duration, usage, cache marker, full
      result text) to eval\results\<label>\ via the new Write-ReplayResult.
      Never scheduled - only a human invokes it.
    - Replay-Tickets.ps1 (new): runs the rubric list in eval\tickets.json
      through replay mode one ticket at a time, scores each result's
      WOULD-DO text against must_mention / must_not_mention / should_mention
      regex lists, prints a pass/cost/turns table, writes summary.json, and
      -CompareTo diffs two labeled runs (pass changes, cost and turn deltas)
      so a change is kept or reverted on evidence rather than on the next
      production log.
    - eval\tickets.json (new): seeded with nine real tickets from this
      session's incidents (#22300 VLAN, #22114 warranty, #22067 stale
      emailtolist, #22231, #22265, #22280 Chrome/Edge, #22295, #22296,
      #22297, #22278 LEARN_FIX), each with the lesson it encodes. Synced by
      the updater ONCE and never overwritten - it's the deployment's own to
      grow, same reasoning as config.json.
    - $pipelineFlags: reads config.json's optional "pipeline" block
      (deterministic_classifier, prefetch_ticket, playbooks, client_cards),
      all default false, missing block/key = false; -DryRun prints them.
      Nothing consumes them yet - increments 2-5 will, one at a time.
    - Update-HaloResponseAgent.ps1: syncs Replay-Tickets.ps1; gains a
      seed-once list (eval/tickets.json) and subfolder support (creates the
      parent folder before downloading). Ordering note for future work:
      because the updater fetches its own new copy in the same cycle it
      still runs the OLD file list, a new file only lands one cycle after
      the updater change itself - so any code depending on a new file must
      fail open if it's missing.
    Verified here before pushing, the same way production's own post-update
    gate does: the ParseFile syntax check on all three scripts, then
    -DryRun both normally and in replay mode, in a local PowerShell 7.4.6 -
    necessary but not sufficient, since production is Windows PowerShell
    5.1, so everything new is written to 5.1 syntax (no ternary, no ??).
    Companion change in rafouche/MCPs (halopsa-mcp, additive, awaiting
    Roger's deploy): get_ticket_brief (~1.7K chars for the ticket whose raw
    payload was 66K, plus device_hints parsed from NinjaOne's embedded
    device block), get_ticket_history (trimmed actions + human_touch), and
    GET /helpdesk-candidates (both, per ticket ID, over plain HTTP - the
    feed increments 2 and 3 will consume). Nothing here references any of
    those yet, so the order of deploy vs. update doesn't matter for this
    version.
    Version: 2.10.70 - no code change in this script; config.json only.
    Roger reported he'd already switched his live production config to run
    every tier on Sonnet 5 (classifier_model/resolver_model_trivial changed
    from Haiku 4.5 to Sonnet 5), with effort scaled to each tier's actual
    complexity (low/medium/high) rather than varying by model choice. Synced
    the repo's config.json to match: classifier_model/resolver_model_trivial
    to claude-sonnet-5, resolver_effort_complex raised from "medium" to
    "high" (classifier_effort/resolver_effort_trivial were already "low",
    resolver_effort_medium already "medium"). This also means every tier's
    configured effort value is now actually sent for the first time -
    Haiku 4.5 never accepted --effort at all, so classifier_effort/
    resolver_effort_trivial were previously documented as having no effect;
    refreshed config.json's own comment to drop that now-inaccurate caveat.
    No PS1 code change needed - claude-sonnet-5 was already on
    $effortCapableModels before this. Worth noting given v2.10.39/40/68's
    still-unresolved deferred-tool confusion pattern: that failure was
    concentrated specifically in the cheap Haiku tier per v2.10.40's own
    finding, so moving every tier off Haiku may reduce or eliminate it as a
    side effect - not confirmed yet, worth watching the next few logs.
    Version: 2.10.69 - Roger asked for a full-diagnosis standard after
    reviewing ticket #22300 ("can't access my shared network drive," tiered
    TRIVIAL_UNCERTAIN): the ticket's own auto-generated body already named
    the device's current IP, and cross-referencing that against
    `mcp__Meraki__list_vlans` for this client showed it sitting on a
    segregated "Security" VLAN with no configured uplink - a concrete,
    checkable explanation for the complaint, using a tool already available.
    Instead, the actual reply asked the client for the error message, server
    path, and when it started - diagnostic work the system had the data and
    tools to do itself. Strengthened two places in resolver-prompt.md: the
    TRIVIAL_UNCERTAIN section's "quick, cheap lookup" now explicitly
    includes a VLAN/subnet check for a connectivity complaint (one tool
    call, same cost class as the device/account lookups already there, not
    the full investigate process that tier skips), and the main "Otherwise,
    do this" investigation step gets a general standing rule: exhaust every
    applicable read-only tool before asking the client anything or judging
    difficulty, for any issue type, not only network ones. Both also cover
    what happens once full diagnosis actually points at a network/security
    configuration change (switch port VLAN, firewall rule, anything outside
    the 17-item remediation whitelist): never attempt it and never ask the
    client to arrange it - write the specific finding into a private note
    for a human, detailed enough to act on without re-diagnosing.
    Version: 2.10.68 - no code change in this script; fix lives in
    resolver-prompt.md, and this one is logged with limited confidence, same
    as the two prior attempts at the same underlying issue (v2.10.39/40).
    Roger's own production log (2026-09-17) showed ticket #22297's resolver
    pass reasoning its way out of ever calling a single tool: it saw
    `mcp__Halo__get_ticket` listed as "deferred" rather than immediately
    callable, concluded from that alone that the Halo MCP connection might
    not be set up correctly, considered `ToolSearch` and talked itself out
    of it, and ended the turn - correctly marked `[CACHE: BLOCKED]`, so the
    v2.10.39 backoff held and nothing was silently repeated, but zero actual
    work happened on a real ticket at real cost. Same root conflation as
    v2.10.39/40's PowerShell-denial case (treating one thing's shape in the
    system prompt as evidence about an unrelated thing's availability), just
    triggered by the deferred-tools listing mechanic itself instead of a
    denied PowerShell call this time - resolver-prompt.md already told it
    exactly what to do here and it still didn't. Added a third, specifically-
    named paragraph citing #22297 directly. Not claiming this is fixed -
    the backoff mechanism is what actually bounds the cost; this is a
    pattern to keep watching, not a lever that's worked twice already and
    is now assumed solved on a third try.
    Version: 2.10.67 - no code change in this script; fix lives in
    resolver-prompt.md. Roger's own product-preference policy, not a bug
    report: when a client asks for Google Chrome to be installed, recommend
    Microsoft Edge first with one brief, plain-language reason, but never
    refuse to install Chrome if they still want it. Added a new
    "Recommending a browser (Edge over Chrome)" section, right alongside
    the existing "Recommending a password manager or a business VPN"
    section this pattern already follows (Keeper over Bitwarden/1Password/
    LastPass, NordLayer over a personal VPN app). Ticket #22280 cited as
    the live example Roger pointed at: a client asked for Chrome installed
    with no other context, and the pending reply agreed to schedule the
    install without ever mentioning Edge - a real, current instance of
    exactly the gap this closes, not a fabricated example.
    Version: 2.10.66 - Roger reported a second bug on the same ticket
    (#22265): the superseded draft note was never deleted before the
    revised one was written, even though "delete any prior one(s)" is
    exactly what this script's own FLOW B step 0 instructs. Root cause,
    confirmed live: that ticket's draft note had been written as
    "[INTERNAL NOTE - Relinked] ... --- [DRAFT PENDING APPROVAL] ..." - the
    resolver had also just relinked the ticket's contact and recorded that
    in the same private note ahead of the draft marker, which is reasonable
    on its own, but halopsa-mcp's delete_ticket_note/mark_draft_approved
    both required the marker to be the literal first characters of the note
    (`note.startsWith(...)`) - so the delete was refused, and this script's
    own instructions say not to fight a refusal, just proceed and leave the
    old note in place; that's exactly what a human watching the ticket then
    sees as "it didn't delete the original draft." Fixed in halopsa-mcp: a
    shared `hasDraftMarker()` helper now accepts the marker appearing as its
    own line anywhere in the note, not only as the very first characters,
    used by both tools' safety checks; still an exact, specific match,
    just not fragile against reasonable content recorded ahead of it.
    Updated this script's own FLOW A step 1 / FLOW B step 0 banner text
    (`"starting with the exact line"` -> `"containing the exact line ...
    on its own line"`) to match, and the tool descriptions in halopsa-mcp
    themselves, so nothing describing this behavior still claims the
    stricter, now-inaccurate rule. Roger deploys the Worker separately,
    same as always.
    Version: 2.10.65 - no code change in this script; fix lives in
    resolver-prompt.md's "If a human left a note on your own pending draft"
    section. Roger reported ticket #22265: he wrote a private note on a
    pending draft asking the resolver to add one specific question (which
    Adobe tier the client needed, with a quick comparison) to the existing
    draft. The revised draft instead discarded the original message
    entirely and wrote a new one from scratch that only asked that
    question - technically satisfying the note in isolation, but not what
    Roger wanted (the question added to the draft, not the draft replaced
    by the question) and not what this section's own "using your original
    draft as a starting point" language was meant to convey. Tightened
    that language to say explicitly what "starting point" means: edit, not
    replace - keep the original draft's actual sentences and framing
    intact, change only what the note is actually about - with the #22265
    ticket cited directly as the failure case this now guards against.
    Version: 2.10.64 - no code change in this script; fix lives in
    halopsa-mcp. Roger reported the v2.10.45 client-email-formatting bug
    ("every paragraph break collapsed into one run-on block") back on ticket
    #22231, specifically after a human moved a draft to AI Approved (FLOW A).
    Root cause, confirmed live: HaloPSA's GET /Actions reconstructs the plain
    `note` field from `note_html` (tags stripped, no whitespace substituted)
    whenever `note_html` is present on that action - a Halo AI Triage note on
    the same ticket with no note_html set preserved its \r\n perfectly on the
    same GET call, while this pipeline's own note (note_html set) came back
    with every line break gone entirely, not even a space. FLOW A step 1 reads
    the private "[DRAFT PENDING APPROVAL]" note back with exactly this call
    to resend it "verbatim" (step 2 above) - so the note_html the v2.10.45 fix
    added to update_ticket_draft_only's write was silently corrupting its own
    later read-back, and FLOW A faithfully copied the already-mangled text
    into the real client email, note_html included (nothing left to convert
    into `<br>` by the time it got there). Fixed in halopsa-mcp: removed
    note_html from update_ticket_draft_only's write only - that note is
    always private and never emailed directly, and Halo's own ticket UI
    already renders bare `\n` forgivingly (the original justification in
    v2.10.45's own comment), so note_html served no purpose there. Left
    update_ticket's note_html alone (the real, later, client-facing send
    still needs it, and now reads fresh, uncorrupted draft text at that
    point). Roger deploys the Worker separately, same as always.
    Version: 2.10.63 - no code change; follow-up on v2.10.62's Peplink gap.
    Roger relayed a claim from a different chat session that Peplink IC2
    does support triggering a speed test after all, via an undocumented-
    sounding "Device API Proxy" (`devapi`) passthrough: `POST /rest/o/
    {org_id}/d/{device_id}/devapi/{command}`. Checked directly rather than
    taking it on trust, the same way this project checks everything:
    fetched both the public IC2 API doc page (peplink.com/ic2-api-doc/) and
    what appears to be the canonical live doc (incontrol2.peplink.com/api/
    ic2-api-doc), searched each thoroughly for "devapi"/"Device API Proxy" -
    neither page contains it, at all. Two other things point the same way:
    the claimed URL skips the group segment every other confirmed IC2
    device endpoint requires (`/rest/o/{org}/g/{group}/d/{device}`), and a
    live Peplink community forum thread ("Ability to run and Log Speed
    Tests in Incontrol2 - Feature Requests") shows users asking Peplink for
    exactly this capability, which cuts against it already existing.
    Gave Roger three ways to resolve the discrepancy (get a concrete
    worked example from the other chat, test one live call and report what
    comes back, or drop it) rather than silently deciding for him - he
    chose to drop it, so Peplink stays unimplemented for speed testing,
    same as UniFi, pending real confirmed evidence either way. Recorded
    here so a future session doesn't have to re-investigate the same claim
    from zero.
    Version: 2.10.62 - feature requested by Roger: a new NinjaOne script,
    "Speedtest (JSON)", for troubleshooting "internet/network is slow"
    complaints - writes its result to the device's activity log, and Roger
    wanted it run and its output actually read back in the same pass, plus
    equivalent firewall-level speed testing on Meraki/UniFi/Peplink where
    available.
    Confirmed rather than assumed this needed more than a config.json line:
    every existing remediation_whitelist entry is a one-shot fix (ran or it
    didn't, no result to read), so run_script_on_device (confirmed from its
    own implementation: POST /device/{id}/script/run, fire-and-forget,
    never returns the script's actual output) was never going to be enough
    on its own. Added mcp__Ninja__run_script_and_wait to ninjarmm-mcp -
    queues the same way, then polls GET /device/{id}/activities
    (activityType SCRIPT) every 5s for a new matching entry until it
    appears or maxWaitSeconds (default 60, capped 120) elapses, returning
    the real result (or an honest not-done-yet signal, not an error) -
    doesn't over-parse NinjaOne's own SCRIPT activity schema, which isn't
    independently pinned down here.
    For firewall-level testing, checked live documentation before writing
    anything rather than guessing at three vendors' worth of API shape:
    - Meraki: confirmed against Cisco's own official API docs - a real,
      documented Live Tools endpoint (POST /devices/{serial}/liveTools/
      throughputTest, an async job you poll via its own returned url,
      result.speeds.downstream in Mbps, rate-limited to one request/5s/
      device). Added mcp__Meraki__run_throughput_test to meraki-mcp using
      the identical queue-then-poll shape as the Ninja tool above.
    - UniFi: NOT added. The only speedtest command found (`cmd/devmgr`
      speedtest/speedtest-status) belongs to the legacy classic local-
      controller API - a completely different path shape than
      unifi-mcp's actual Network Integration API proxy
      (/v1/connector/consoles/{hostId}/proxy/network/integration{path}).
      Could not confirm the modern API this Worker actually uses has an
      equivalent action from what's publicly documented. Guessing an
      endpoint against live client firewalls isn't an acceptable way to
      find out.
    - Peplink: NOT added. InControl2's own API documentation shows no
      bandwidth/speed-test trigger endpoint at all under the device
      resource, and a Peplink community forum thread ("Ability to run and
      Log Speed Tests in Incontrol2 - Feature Requests") suggests this may
      genuinely not exist via their API yet, not just be undocumented.
    Added two new remediation_whitelist entries ("Run NinjaOne script:
    Speedtest (JSON)", "Run Meraki throughput test") and a new
    resolver-prompt.md section: when to test at the workstation vs.
    firewall level (or both, to isolate one machine from the connection
    itself), how to read back whichever tool's real result rather than
    assuming a specific field shape, and how to handle a legitimate
    not-done-yet outcome (track the ticket for a later recheck, don't
    treat it as a failure or retry blindly). Both new tools are gated
    exactly like every other action this pipeline takes on a client's live
    system - $mutatingTools (simulated under -WhatIf) and
    $remediationMutatingTools (stripped under -RequireApproval for a
    non-APPROVED ticket) - even though a speed test is transient/non-
    destructive, it does pull real bandwidth on a client's live connection
    for several seconds, the same category every other gated tool exists
    for.
    Version: 2.10.61 - Roger reported a real reply on ticket #22067 went to
    the wrong email address: the contact (Thomas Wilder, Thompson Sales) is
    correctly linked, has no company email address, and uses a personal
    Gmail address on file - but the ticket's own send-to field used a
    different, wrong address instead. Confirmed directly rather than
    guessing at the cause: pulled the ticket (user_id 786, `emailtolist`:
    "twilder@thompsonsales.com") and the actual linked contact record
    (`mcp__Halo__get_contact` 786: `emailaddress`: "thomaswilder84@gmail.com",
    no other email on file) - the contact record was correct the whole time;
    the ticket's own `emailtolist` field was a stale, guessed company-domain
    address left over from before Roger manually relinked the ticket to this
    contact (action history shows the relink, "User Changed," three days
    earlier) that never got refreshed by that relink. HaloPSA apparently
    doesn't keep a ticket's stored send-to address in sync with its linked
    contact automatically - confirmed this is a real, structural HaloPSA gap,
    not something this pipeline's own tool calls caused (halopsa-mcp's
    update_ticket had no `emailto`/`emailtolist` parameter at all before this
    version, so nothing in this pipeline could have set or changed it).
    Added `emailto` to update_ticket/update_ticket_draft_only in halopsa-mcp
    (writes HaloPSA's `emailtolist` field via the same POST-with-id
    convention already used for client_id/site_id/user_id - field name
    confirmed from a live GET response, not yet independently confirmed
    accepted on write). resolver-prompt.md's "Sending a real, client-facing
    reply" section now requires comparing the ticket's `emailtolist` against
    the linked contact's real `get_contact` email before every real send,
    and correcting it (with `verify: true`) when they disagree - the same
    "don't trust a ticket-level field that can silently drift from the real
    linked record" lesson this project already learned once for client_id/
    site_id consistency (ticket #22107), just for the send-to address this
    time. Could not correct ticket #22067 itself directly - Claude Code's
    own auto-mode classifier denies external-system writes from this
    session, same as the ticket #22114 draft-deletion attempt - so this was
    reported to Roger to fix (or approve) himself: set `emailtolist` to
    thomaswilder84@gmail.com on ticket #22067.
    Version: 2.10.60 - Roger sent a full day's production log (2026-09-14)
    after noticing the day was already near $20 by early afternoon and asked
    whether there was a leak. There was: analyzed all 40 cycle summaries in
    the log directly rather than guessing - $17.75 logged by the time the
    file was sent, concentrated in three tickets reprocessed far more than
    anything else that day (#22067 x6/$2.08, #22145 x6/$1.89, #22114 x6/
    $1.40 - roughly 30% of the day's total spend, on tickets that made zero
    forward progress across nearly all of those passes). Two distinct, real
    causes, both fixed:
    (1) #22114/#22067: Roger's own habit of resetting a ticket's status back
    to "New" while working it by hand (which also clears agent_id back to 1
    as a side effect) makes it indistinguishable from a genuinely fresh
    candidate to every classifier-side signal that exists today - status_id,
    status name (classifier-prompt.md deliberately never excludes "New" by
    name, since real fresh work legitimately sits there too), assignment.
    Only the action log (human_touch) tells them apart, and the resolver was
    already discovering that correctly every single time at full MEDIUM/
    COMPLEX Sonnet cost, then emitting [CACHE: UNTRACK] - which, it turns
    out, does nothing for a ticket that was never in the tracked list to
    begin with (these are freshly rediscovered as Unassigned candidates each
    cycle, not through the tracked-ticket recheck path). Added a fourth
    cache marker, [CACHE: HUMAN_OWNED], mirroring [CACHE: BLOCKED]'s own
    established shape (a new human_owned_tickets map in agent-cache.json,
    ticket_id -> when last confirmed, excluded from the classifier's
    Unassigned candidate list for config's new human_owned_retry_hours,
    defaulted considerably longer than blocked_ticket_retry_hours's 4h since
    a human working a ticket by hand isn't in a hurry to get it back -
    ready_for_ai_status_name still overrides this immediately, same as
    everything else). resolver-prompt.md's "Is this ticket actually
    available to you?" checks 1/2 and "When you finish" section now specify
    HUMAN_OWNED for exactly this case, split out from UNTRACK's own listed
    cases.
    (2) #22145: assigned to Erick Gonzales (a real human agent) reviewing
    this pipeline's own still-pending [DRAFT PENDING APPROVAL] note, with no
    note text from him yet - correctly not resolved/replied-to on any of
    these passes, but reaching the resolver at inconsistent, mostly
    expensive tiers (TRIVIAL_UNCERTAIN once, MEDIUM four times, COMPLEX
    once) for what should have been a free "did anything actually change?"
    recheck. Root cause: classifier-prompt.md's call 3 literally says
    "still open, assigned to a real human agent -> UNTRACK, no further
    investigation" with no written exception for a ticket sitting on
    ai_waiting_approval_status_id/ai_approved_status_id - a human claiming a
    pending draft to review isn't the same as taking the ticket over (see
    resolver-prompt.md's own "If a human left a note on your own pending
    draft" section), so the classifier was evidently applying an unwritten,
    inconsistent exception rather than a documented one, explaining both why
    it kept reaching the resolver at all and why its tier varied cycle to
    cycle. These two IDs (ai_waiting_approval_status_id/ai_approved_status_id)
    were never even exposed to the classifier before this version - added
    them (rendering "none" when -RequireApproval isn't configured, same
    pattern as ready_for_ai_status_id) and wrote the exception explicitly:
    a ticket on either status routes to the existing action-log check
    instead of the unconditional UNTRACK, and a bare reassignment/triage
    entry with no free-text note now explicitly counts as "nothing
    substantive" there (matching resolver-prompt.md's own "only a
    reassignment, no note text at all" case) - the existing "nothing
    changed -> exclude entirely, zero cost" outcome that branch already had
    just needed to actually be reached for this case instead of drifting
    into an ad hoc MEDIUM/COMPLEX guess. No change needed to the resolver's
    own already-correct behavior here - both bugs were entirely on the
    classifier side, over-nominating and mis-tiering candidates the
    resolver was, each time, already handling correctly once it saw them.
    Version: 2.10.59 - Roger asked whether FLOW A could delete the draft
    note once it's been approved and sent, to keep ticket history cleaner,
    or alternatively relabel it to something like "Approved draft" instead
    of leaving the whole draft text sitting there. Checked first rather
    than assuming: FLOW A step 6 has deleted the draft note in this exact
    situation since v2.10.49, already per an earlier Roger request - so
    this wasn't a net-new ask, it was reopening that decision. Asked which
    of his own two options he wanted (delete, already live, vs. relabel);
    he chose a third variant: relabel to "[APPROVED DRAFT]" but strip the
    rest of the text entirely, since it already lives in the real sent
    reply and doesn't need to sit twice in the ticket's history. HaloPSA
    has no note-edit endpoint of its own - delete_ticket_note only ever
    calls DELETE /Actions/{id} - so added a new halopsa-mcp tool,
    mark_draft_approved, using the same update-via-POST convention
    update_ticket already relies on for /Tickets (POST /Actions with the
    action's own id edits it in place rather than creating a new one) -
    not yet independently re-verified that this convention also holds for
    /Actions specifically, flagged for Roger to confirm once deployed.
    Same safety scoping as delete_ticket_note (fetches the action first,
    refuses unless it's private, belongs to this ticket, and starts with
    the exact "[DRAFT PENDING APPROVAL]" marker) so it can't touch a
    human's note or a real reply either. Wired into $resolverTools and
    swapped into FLOW A step 6 in place of delete_ticket_note. Left
    mark_draft_approved out of $mutatingTools, matching delete_ticket_note's
    own existing (pre-dating this change) treatment - keeping the two
    "own draft only" tools symmetric rather than introducing a new
    -WhatIf policy for one but not the other without a specific incident
    driving it.
    Version: 2.10.58 - Roger reviewed two full days of production logs
    (2026-09-12/13) while this session was investigating ticket #22114, and
    separately flagged a pattern this session had noticed in passing but not
    fixed: several resolver/classifier calls tried a denied "PowerShell"
    tool call before using the correct MCP tool - "if it's costing money and
    failing, it's a bug and costing money for no purpose. If you saw this,
    you should have fixed it." Fair - flagging a known-costly bug without
    fixing it isn't done here. This exact failure shape already has real
    history: v2.10.39/40 found the same pattern and added prompt wording
    (resolver-prompt.md/classifier-prompt.md's opening paragraphs already
    say explicitly "you have no Bash, no PowerShell") on the reasoning that
    it was "prompt fix with real but limited confidence... not a lever to
    pull further blind" without more evidence. Roger's fresh logs are that
    evidence: the exact same pattern recurred at least 4 times across those
    two days despite the existing prompt wording, sometimes recovering after
    one denial, twice fully spiraling into a no-op turn - proving the
    prompt-only fix was insufficient, not that it needs different wording a
    third time. This file has direct precedent for exactly this situation:
    v2.10.34 found the same denied-but-still-attempted shape for Claude
    Code's built-in Agent/Task (subagent-spawning) tool and fixed it
    structurally with `--disallowedTools "Agent,Task"`, confirmed working
    (subagent_stats.spawned: 0 in every ticket across both of Roger's fresh
    logs). Applied the identical fix to Bash: `--disallowedTools` now also
    includes `Bash,PowerShell` (both names, since permission_denials shows
    it registered as "PowerShell" specifically on this Windows host) -
    removing the tool from what Claude Code even offers the model for the
    call, rather than relying on it being attempted and then denied. No
    equivalent env-var fallback added (unlike CLAUDE_CODE_DISABLE_BUILTIN_AGENTS
    for Agent/Task) since no such documented variable for Bash specifically
    is confirmed to exist - not guessing one into the script.
    Version: 2.10.57 - same ticket, #22114, second correction from Roger the
    same day: v2.10.56's own fix was still wrong. Investigating the original
    complaint, this session proposed a corrected reply for Roger to send
    that shared the device's make/model/serial but told Jill "I don't have
    an exact warranty expiration on file... you can check yourself at
    Lenovo's support site" - Roger: "The warranty is plainly listed in Ninja
    machine record. Never tell a user to look up something that we already
    should have the information on." Checked directly rather than taking
    either side's word for it: mcp__Ninja__get_device's plain hardware/
    system block genuinely has no warranty field (confirmed by re-reading
    its full raw response) - but that's because warranty/purchase-date data
    lives in a device's NinjaOne *custom fields*, a completely different
    API call this Worker never wired up at all, not because Ninja lacks the
    data Roger described. Real gap, not a wrong claim on either side: added
    mcp__Ninja__get_device_custom_fields to ninjarmm-mcp (GET /v2/device/
    {id}/custom-fields, pairing with update_device's existing userData
    parameter which already writes these same fields) and wired it into
    $resolverTools here. Corrected resolver-prompt.md's TRIVIAL_UNCERTAIN
    section again: the v2.10.56 text itself suggested handing the client
    make/model/serial so she or a technician could check the manufacturer's
    site - exactly the "tell the client to go find out what we should
    already know" pattern Roger just named as unacceptable - replaced with
    a direct instruction to check get_device_custom_fields for warranty/
    purchase-date questions specifically and answer from it. Not yet
    re-verified against a live deployment (Roger deploys this Worker's
    changes separately) - did not propose a third reply to ticket #22114
    until that's confirmed, rather than guess again with the same kind of
    unverified confidence that caused this and the prior turn's mistake.
    Version: 2.10.56 - real incident, ticket #22114 (Missouri Sports Hall of
    Fame): Jill Barron asked whether her laptop was still under warranty;
    Roger's report - "you turned right around and asked her if her computer
    was under warranty... you have that information accessible to you
    already in Ninja" - was confirmed exactly right by pulling the ticket's
    own action log (mcp__Halo__get_ticket_time_entries) and the device
    directly (mcp__Ninja__get_device, id 3284): NinjaOne already had the
    laptop's manufacturer/model/serial (Lenovo, 20RY0001US, PF272LST) one
    call away, and the resolver never called it. Root cause: resolver-
    prompt.md's TRIVIAL_UNCERTAIN section told the resolver to skip
    investigation entirely and "reply asking for exactly that" whenever
    something looked missing - treating "missing information" as always
    meaning "the client has to supply it," which isn't true for anything
    already sitting in a system Altec itself controls. Confirmed this
    wasn't a tool-access gap like the others this project has found - the
    tier-to-tools mapping in this file gives TRIVIAL_UNCERTAIN the same
    full allowlist as every other tier, just a cheaper model/lower effort -
    so the fix is entirely in resolver-prompt.md: before asking the client
    anything, do a quick lookup on whatever's already named in the ticket
    (device, account, company) and use what it turns up, only asking for
    what's genuinely still unknown afterward.
    A second, independent bug turned up investigating the first: this run
    had no `-RequireApproval` active (config's ai_waiting_approval_status_name
    is blank, which hard-errors before that switch could even run) and the
    resolver's own tool list confirmed it had the real mcp__Halo__update_ticket,
    not the draft-only one - yet it wrote its clarifying question as a
    private, unemailed note formatted like a `-RequireApproval` draft
    ("[DRAFT PENDING APPROVAL]"/"[INTENDED STATUS]" tags that belong to a
    flow this run wasn't in) and set the ticket to waiting_on_client_status_name
    regardless, as if Jill had actually been asked something she never
    received. Reinforced both "Which update_ticket tool do you actually
    have?" and the TRIVIAL_UNCERTAIN section: having mcp__Halo__update_ticket
    means sending for real is expected, and waiting_on_client_status_name
    should only ever mean the client really was emailed, not that a private
    note merely claims they were. Tried to correct ticket #22114 itself
    directly (delete the stale draft note, send Jill the corrected reply
    with her laptop's real model/serial) but Claude Code's own auto-mode
    classifier denied the external-system write - left the ticket as found
    and reported the specific fix to Roger to send or approve himself
    instead of working around the denial.
    Version: 2.10.55 - two fixes from the same Roger message. First: directly
    confirmed mcp__CIPP__list_message_trace and mcp__CIPP__list_mailboxes
    still exist in the real production cipp-mcp Worker source
    (/home/user/mcps/cipp-mcp/src - rafouche/MCPs is a monorepo, cipp-mcp is
    a sibling of halopsa-mcp in it), not just inferred from this file's own
    v2.10.37/.38 history as v2.10.53's note hedged - Roger clarified CIPP-ng's
    built-in MCP was tried and abandoned (beta, extremely limited) and this
    custom cipp-mcp using documented APIs is the real, current, maintained
    tool. Grepped its source directly: list_mailboxes (schema + handler
    calling ListMailboxes) and list_message_trace (schema + handler calling
    ListMessageTrace) both present exactly as resolver-prompt.md and
    v2.10.53's fix assumed. v2.10.53's hedge is superseded; no code change
    needed here, the allowlist fix already shipped was correct.
    Second, and the larger piece: Roger rejected v2.10.54's Hudu design
    outright - "Do not use a[sic] that sing[sic] Network Stack AI approved
    thing. Only the central KB actual documented fix[es] use the
    AI-Documented Fixes type naming." v2.10.54 invented a single custom KB
    article type ("Network Stack (AI-verified)") for per-client network-stack
    caching, reusing the same article_create_tool/article_edit_tool mechanism
    as the actual fix-documentation feature - conflating two different things
    under one naming convention, exactly the kind of unforced, unverified
    design choice this project's discipline exists to catch (same shape as
    v2.10.51's mistake, this time caught by Roger before any real ticket used
    it rather than after). Replaced with Hudu's real, pre-existing Asset
    Layout system: fetched the live layout list (mcp__Hudu__asset_layout_index_tool,
    27 layouts total) and field schemas (mcp__Hudu__asset_layout_show_tool)
    for Firewalls (id 20), Switches (27), Wireless (6), Network Devices (2),
    ISP/WAN Circuits (21), and LAN (22, confirmed to be per-VLAN/subnet
    documentation, not a vendor-identity fit, so not used here) before writing
    a single line of guidance, rather than guessing at field names.
    resolver-prompt.md's network section now checks/creates a real asset
    under the matching layout (Firewalls/Switches/Wireless, by role) instead
    of a KB article - manufacturer set via mcp__Hudu__asset_create_tool's
    custom_fields to the exact list_items spelling for that layout (confirmed
    live: Firewalls/Switches use "Meraki"/"Ubiquiti", Wireless instead uses
    "Meraki (Cisco)"/"Ubiquiti" - not interchangeable, always re-check via
    asset_layout_show_tool rather than assuming one layout's spelling applies
    to another). Also confirmed live: none of these three layouts' manufacturer
    list includes "Peplink" as an option (only "Other" fits) - documented that
    a Peplink finding needs "Other" plus an explicit note in the model/notes
    field, an open detail from the prior turn that's now resolved. Added
    mcp__HUDU__asset_layout_index_tool/asset_layout_show_tool (read-only) and
    asset_create_tool/asset_edit_tool (write) to $resolverTools; unlike
    article_create_tool/article_edit_tool, the asset write tools ARE in
    $mutatingTools (simulated under -WhatIf) since they write real client-
    facing Hudu records, not an isolated internal-only folder - see the
    allowlist comments at each tool's declaration for the full reasoning.
    The underlying goal from v2.10.54 (cache a finding, never trust it blind,
    since hardware gets swapped) is unchanged - only the storage mechanism
    was wrong, and Roger corrected the mechanism, not the goal.
    Version: 2.10.54 - feature requested by Roger following the v2.10.52
    UniFi/Meraki/Peplink correction: cache a client's actual network stack in
    Hudu once discovered, so a future network ticket doesn't repeat the same
    three-system search - but never trust the cache alone, since the real
    hardware can change (his own example: Peplink APs swapped for UniFi or
    Meraki ones later). Added to resolver-prompt.md's network section: check
    Hudu for a `"Network Stack (AI-verified)"` article under this client's
    Hudu company (found by name via mcp__Hudu__company_index_tool - a
    different ID space than Halo's client_id) before searching all three
    vendor systems blind; if found, use it to go straight to the named
    vendor(s) but still confirm the specific device/role resolves there via
    a real call before acting on or telling a client anything based on it;
    if live reality contradicts the article, update it
    (mcp__Hudu__article_edit_tool) before moving on rather than leaving a
    cache that's now known to be wrong; if no article exists and this
    investigation determines the real stack, write one
    (mcp__Hudu__article_create_tool) - skipped for a ticket that only
    touched one obvious vendor with nothing ambiguous worth recording, since
    this is meant to save a future genuinely multi-system search, not to run
    on every ticket. No allowlist changes needed - company_index_tool/
    article_index_tool/article_create_tool/article_edit_tool were already
    granted for the existing prior-art-search and fix-documentation patterns
    this reuses the same mechanism as.
    Version: 2.10.53 - Roger asked for the same wiring check just done for
    Peplink to be run against Huntress and CIPP too. Huntress came back
    clean: cross-checked every mcp__Huntress__* name resolver-prompt.md
    references by name against $resolverTools and found no mismatches (it
    doesn't reference Huntress tools by specific name at all, unlike CIPP -
    nothing to be inconsistent with). CIPP did not come back clean: found
    mcp__CIPP__list_message_trace and mcp__CIPP__list_mailboxes both
    referenced as load-bearing in resolver-prompt.md's "Email delivery /
    bounce issues" section - the same section documenting ticket #21900 as
    the real incident that justified building list_message_trace as a
    dedicated tool in the first place (see v2.10.37/.38 history above) - but
    neither was ever actually added to $resolverTools. The comment at this
    exact spot still described the OLD generic cipp_api_get passthrough as
    the mechanism, stale since the dedicated tool was built specifically to
    replace that guessed-params approach. Net effect: the documented,
    incident-justified fix has been structurally unable to run since it
    shipped - every real "email not arriving" ticket since then had both
    calls silently denied under --permission-mode dontAsk, reproducing
    #21900's own original failure shape (reporting a plausible cause without
    ever confirming delivery actually failed) invisibly, because a denied
    tool call doesn't announce itself as "the fix didn't apply" any more
    than a wrong-tenant trace result announces itself as wrong. Added both
    tools; kept cipp_api_get as a generic fallback since resolver-prompt.md
    doesn't reference it by name for anything specific. Could not directly
    test against the production "CIPP" MCP server from this session (only a
    newer, differently-named CIPP-ng server is connected here) - relying on
    this file's own v2.10.37/.38 history that list_message_trace was
    actually built and shipped in cipp-mcp, not re-verifying that
    independently; flag to Roger if that's since changed.
    Version: 2.10.52 - same-day correction to v2.10.51, caught by Roger: that
    version's framing (Peplink = a site's WAN/internet uplink layer, UniFi/
    Meraki = the local network layer) was wrong. UniFi, Meraki, and Peplink
    are three independent, competing network hardware ecosystems, not three
    layers of one stack - any of the three can fill any role (firewall,
    switch, access point, router), and a single site can genuinely run more
    than one vendor at once. Confirmed directly, not just taken on Roger's
    word: Thompson Sales exists as a real Meraki organization
    (id 3661426497052213602), a real UniFi site, AND a real Peplink group
    (id 3, under the "ASG Direct Clients" Peplink org) - all three,
    simultaneously, on live data pulled from each system. Rewrote
    resolver-prompt.md's network-investigation guidance: check Hudu
    documentation first for this client's real stack if it exists, otherwise
    search all three systems by client name rather than picking one based on
    what the ticket's symptom "sounds like" - a match in more than one system
    is normal, not a sign of picking wrong. Kept Peplink's own org -> group ->
    device hierarchy note (still accurate, unrelated to the layer-framing
    mistake). Worth naming plainly: v2.10.51 shipped a plausible-sounding but
    unverified assumption about how the three vendors divide responsibility,
    the exact category of mistake this project's own discipline is supposed
    to catch before shipping - it took Roger's domain knowledge, not this
    pipeline's own verification habits, to catch it this time.
    Version: 2.10.51 - real gap, caught by Roger reading the Capabilities
    Brief rather than by a ticket hitting a denial (unlike every other entry
    in this script's Network tool section): Peplink (InControl2) has been a
    registered MCP server on this machine the whole time, but was never
    added to the resolver's tool allowlist and never mentioned in
    resolver-prompt.md at all - confirmed directly (grepped the entire
    codebase for "Peplink", zero matches anywhere before this fix). Added
    the full Peplink toolset (every tool is a GET/LIST, no mutating tool
    exists, same as UniFi) to $resolverTools, and added it to
    resolver-prompt.md's three UniFi/Meraki mentions plus a fourth, more
    specific note on when to actually reach for it: Peplink is InControl2's
    WAN/uplink-failover view for a site's internet connection itself, a
    distinct layer from UniFi/Meraki's local-network view (switches, APs,
    per-client status) - worth calling out explicitly since a call-quality
    or "internet is slow/dropping" complaint is exactly the ticket type that
    needs Peplink's get_device_wan_status, not just Meraki's uplink-loss
    tools, and the two aren't interchangeable. Also noted Peplink's own
    org -> group -> device hierarchy (list_organizations -> list_groups ->
    list_devices, since get_device/get_device_wan_status both require
    org_id and group_id, not just a device_id) - structurally different from
    UniFi/Meraki's flatter site/network model, confirmed directly against
    the tool schemas rather than assumed to match. Prompt/allowlist-only
    change; re-parsed the whole script before shipping (no dynamically-built
    string array touched this time, so no backtick-rendering risk the way
    the FLOW A/B banner edits earlier this session had).
    Version: 2.10.50 - real incident, reported by Roger: ticket #22107. He
    said Allie wrongly claimed Gold Mechanical doesn't exist in NinjaOne,
    when it does and had been matched correctly before. Confirmed live: real
    incident cited directly against ticket #22107 - Gold Mechanical is
    org_id 82 in NinjaOne with 60+ real, actively-checking-in devices,
    including domain controllers and dozens of workstations. Root cause:
    `mcp__Ninja__list_organizations` paginates just like
    `list_devices_detailed` right below it in resolver-prompt.md, but only
    `list_devices_detailed` had pagination instructions - the organization
    lookup was described as a single call. This tenant has ~90 organizations
    and Gold Mechanical sits on page 2 of the default 50-per-page listing,
    so one unpaginated call made it look like it didn't exist at all. Fixed
    by adding the same "page through with `after` until a short/empty page"
    instruction already used for devices to the organization lookup too.
    Second, related but independently confirmed bug on the same ticket:
    Allie's own prior note said she re-linked the ticket from the generic
    "Unknown" client to Gold Mechanical (client_id 129, confirmed correct)
    - but the ticket's `site_id` was left at 1 (the old "Unknown" client's
    site), and the ticket still displayed as client "Unknown"/site "Unknown"
    everywhere in Halo despite client_id being right, because Halo needs
    client_id and site_id to be a consistent pair, not independently
    correct. This is a genuinely new case resolver-prompt.md's existing
    contact-linking section never covered: an automated/system alert
    (Microsoft Security, Huntress, NinjaOne, etc.) has no real human contact
    to attach at all, but the affected client can still be independently
    verified - added a new documented case for exactly this, requiring
    site_id to be set alongside client_id even when user_id stays on the
    generic system contact. Discovered mid-fix that `mcp__Halo__update_ticket`
    /`update_ticket_draft_only` had no `site_id` parameter at all - the
    instruction I was about to write would have been physically impossible
    to follow - so added site_id support to both tools in halopsa-mcp
    (already true for create_contact/get_site, just never wired into ticket
    updates) and to verifyWrite's own confirmation check. Typechecked the
    Worker change clean; ticket #22107 itself still needs a live
    client_id-129/site_id-259 ("Main") fix once Roger deploys this, since
    the currently-deployed Worker doesn't support site_id yet.
    Version: 2.10.49 - Roger asked to extend v2.10.48's draft-cleanup to
    FLOW A's own bookkeeping note too. Previously, once the real approved
    reply was sent (step 5), step 6 added a second private note ("Approved
    and sent - see the reply above. (The draft note above is now
    historical, not pending.)") rather than deleting the original draft,
    since at the time v2.10.48 shipped that felt like a different case
    (Roger hadn't asked about it) from a draft superseding a draft. Now that
    he's asked directly: step 6 deletes the draft note instead
    (delete_ticket_note) - once the real reply is posted, the draft has
    nothing left to document that the sent reply doesn't already show, so
    there's no reason to leave it (or a second note about it) behind. Safe
    for the same reason as the FLOW B/revision-flow case: the tool refuses
    unless the target is still a private note starting with the exact
    `[DRAFT PENDING APPROVAL]` marker, which it still is at this point (only
    what's happened around it changed, not its own text) - if it ever does
    refuse, the instruction is explicit not to fight it or block completing
    the ticket over a cosmetic leftover note. Prompt-only change (this
    script's own FLOW A banner text); no halopsa-mcp change needed since
    delete_ticket_note already existed. Re-verified by extracting and
    rendering the edited PowerShell string array end to end, not just
    re-parsing the file.
    Version: 2.10.48 - feature requested by Roger, correcting a claim from
    this same day: notes CAN be deleted in HaloPSA - Roger deleted #22033's
    duplicate drafts himself, by hand, trying to get it to reprocess. The
    long-standing "no delete-note tool exists" conclusion (v2.7.2, CLAUDE.md)
    only ever verified that mcp__Halo__update_ticket's own schema has no
    edit/delete parameter - true, but never the question of whether
    HaloPSA's underlying REST API has a dedicated delete endpoint. It does:
    `DELETE /Actions/{id}`, confirmed directly against HaloPSA's own API
    reference. That also reframes v2.10.47's own "3 separate drafts" finding
    (recorded there as an apparent resolver hallucination) - it wasn't one;
    a real architectural gap had let 3 genuine draft notes pile up on one
    ticket, and Roger's manual deletions are what brought it back down to 1
    by the time it was checked. See CLAUDE.md for the full correction.
    Added `delete_ticket_note` to halopsa-mcp: deliberately narrow, not a
    general-purpose delete - it fetches the target action first and refuses
    (no delete performed) unless it belongs to the given ticket_id, is
    private (hiddenfromuser: true), and its note starts with the exact
    literal `[DRAFT PENDING APPROVAL]` marker, so it structurally cannot
    remove a human's note or a real client-facing reply even if pointed at
    the wrong action by mistake - same "safe by construction, not by
    instruction" pattern update_ticket_draft_only already uses. Wired into
    two places per Roger's request ("delete any prior drafts if a new draft
    is suggested to keep the ticket flow clean"): FLOW B's own draft-writing
    step (new step 0, before writing the note) and resolver-prompt.md's "If
    a human left a note on your own pending draft" revision flow - both now
    delete any prior `[DRAFT PENDING APPROVAL]` note before writing a new
    one, so a ticket carries at most one at a time instead of accumulating
    superseded copies. Deliberately did NOT change FLOW A step 6 (the
    "Approved and sent" bookkeeping note added once a draft is actually
    sent) - that's a different case (a real reply superseding a draft, not
    a draft superseding a draft) that Roger didn't ask about; flagged as an
    option for later rather than expanded into on my own. Typechecked the
    Worker change clean; Roger deploys it separately. Re-verified the edited
    FLOW A/B PowerShell string arrays by extracting and rendering them end
    to end, not just re-parsing the file - this project's own recurring
    lesson about backtick-escaping bugs in this exact code.
    Version: 2.10.47 - real incident, cost-overrun investigation requested by
    Roger against today's actual run log: ticket #22033 alone was
    reprocessed by the full classifier+resolver pipeline roughly 28 times
    in one day (Sonnet, MEDIUM tier each time) for ~$8.68, nearly all of it
    the resolver re-investigating from scratch only to conclude "nothing
    new happened" - the exact expensive anti-pattern the pre-flight gate
    (v2.10.19/2.10.24) exists to prevent. Root cause: the gate's "has this
    ticket changed since last cycle" fingerprint (both the tracked bucket
    and the unassigned bucket) compared Halo's raw `last_update` field -
    which is "any field on this ticket record changed," and Halo
    recomputes time-based fields (slaholdtime in particular) on its own for
    any on-hold ticket, with zero human or agent activity. Every status a
    ticket sits in while awaiting review (AI Waiting Approval, AI Approved,
    Waiting on client, ...) shows `onhold: true`, so `last_update` on a
    genuinely untouched ticket kept drifting anyway - confirmed live: a
    ticket's `last_update` moved 15 minutes after its actual last action
    with nothing new anywhere in its real action log. That made the gate
    see "changed" on nearly every cycle for any tracked or on-hold
    unassigned ticket, defeating the fingerprint entirely while still
    reporting it as working (the log's "gate: nothing changed" skip did
    fire on some cycles - just not the ones that mattered here). Fixed by
    switching the fingerprint to HaloPSA's separate `lastactiondate` field,
    which only moves when a real Action (note/reply/status change) is
    actually added - confirmed against the same ticket's data, where it
    stayed constant across that entire drifting `last_update` window.
    Changed in two places: halopsa-mcp's `/helpdesk-gate` route now returns
    `last_action_date` (from `lastactiondate`) instead of `last_update` for
    both the tracked and unassigned projections (separate repo,
    rafouche/MCPs), and this script's gate-comparison logic reads that
    field instead. Typechecked the Worker change clean; Roger deploys it
    separately. Also surfaced from the same log review, not yet fixed: one
    resolver pass on ticket #22033 claimed its history held "3 separate
    [DRAFT PENDING APPROVAL] notes," but the ticket's actual, complete
    action log (verified directly) has only ever contained one - since
    Halo notes can't be deleted, a real second or third draft would still
    be there. Flagging this as an apparent resolver miscount/hallucination
    rather than a confirmed, fixable defect - noted here for visibility,
    not chased further without more to go on.
    Version: 2.10.46 - new workflow decision from Roger: never take a ticket
    away from a real human tech who already holds it; status changes can
    still happen. Every place in this pipeline that ends a pass by forcing
    `agent_id: 1` (resolver-prompt.md's "Claim the ticket" default and all
    six "When you finish" cases; FLOW A step 7 and FLOW B step 3 in this
    script's own -RequireApproval banner) now checks the ticket's agent_id
    as found at the start of the pass first: if it's neither `1`
    (Unassigned) nor this pipeline's own account, a real human tech already
    holds it - most likely reached via one of the ownership overrides
    (Ready for AI, a human claiming a pending draft to approve or annotate
    it) that work specifically "regardless of who it's assigned to" - and
    the agent_id write is skipped entirely, in every call that pass makes,
    including the final one. Status, team, category, and note writes are
    unaffected; only the agent_id field changes behavior. Not a bug fix -
    a forward-looking policy change, applied everywhere the old
    unconditional "always unassign" language lived rather than as a single
    rule stated once and left to be recalled correctly downstream (this
    project's own v2.10.42 lesson: a rule stated once elsewhere has
    previously lost to a more specific instruction at the actual point of
    action). Prompt/banner-text only; re-verified both edited PowerShell
    string arrays (FLOW A/B's approval banner) by extracting and rendering
    them end to end, not just re-parsing the file.
    Version: 2.10.45 - real incident, reported by Roger: ticket #22067. Two
    separate bugs found and fixed.

    (1) A human's private note was never read. Timeline confirmed via the
    ticket's real action log: Roger set the ticket straight to
    ai_approved_status_id, then one second later left a private note asking
    for the user's department and the machine's physical location. FLOW A
    (this script's own -RequireApproval banner) only ever looks for the ONE
    [DRAFT PENDING APPROVAL] note and sends its text verbatim once the status
    is AI Approved - it never looks at anything written after that note, so
    Roger's note was never seen and the stale, now-incomplete draft went out
    as-is. Fixed by inserting a new step 1.5 into FLOW A, between finding the
    draft note and executing it: pull the ticket's action log and check
    everything after the draft note for a real human note (who_type: 1) with
    actual free-text instruction, ignoring routine bookkeeping (a bare status
    change, an auto-generated contact/client re-link note). Find one -> stop,
    don't send the stale draft, instead follow resolver-prompt.md's existing
    "If a human left a note on your own pending draft" section (the same
    section 2.10.44 already added for the AI Waiting Approval case) to
    produce a *revised* draft for fresh review. Find nothing but bookkeeping
    -> continue exactly as before. Deliberately reused v2.10.44's existing
    revision-loop instructions rather than writing a new one, since the
    underlying situation is the same: a note is guidance, never itself
    approval for text it was never actually written against.

    Caught and fixed one bug in myself while writing this: single backticks
    used for markdown-style code formatting around identifiers in this new
    step (and, it turned out, in two calls added back in 2.10.44 that had the
    same issue and had gone unnoticed) are not inert in a PowerShell
    double-quoted string - a backtick followed by any character silently
    consumes both and prints the trailing character(s) with no parse error,
    so `` `ai_waiting_approval_status_id` `` rendered as a mangled
    "i_waiting_approval_status_id" with no visible sign anything was wrong
    unless the actual rendered text was read, not just parsed. Confirmed via
    direct pwsh testing, then fixed by doubling every affected backtick
    (`` ` `` -> literal backtick) at all four locations, and re-verified by
    extracting and actually rendering both affected string arrays end to end
    from the live file. Filed here rather than glossed over, consistent with
    this project's standing rule to surface self-caught mistakes.

    (2) The sent reply's formatting was lost. Roger confirmed the draft note
    looked perfect but the actual emailed reply lost all paragraph
    formatting. Root cause confirmed against HaloPSA's own Actions API
    documentation: Actions have a plain-text `note` field and a separate
    `note_html` field used for the outbound email body; halopsa-mcp's
    update_ticket and update_ticket_draft_only only ever set `note`. Halo's
    own ticket-view UI renders plain-text bare newlines forgivingly, but the
    outgoing email is built from `note_html`, where a bare `\n` is not a line
    break without an explicit `<br>` - so every paragraph break vanished the
    moment it left Halo's UI for an actual email. Fixed in halopsa-mcp
    (src/index.ts), not this script: added a `noteToHtml()` helper
    (HTML-escapes the text, then converts newlines to `<br>`) and set
    `note_html: noteToHtml(args.note)` alongside the existing `note` field on
    both write paths. Typechecked clean; Roger deploys the Worker separately.
    Version: 2.10.44 - two features requested by Roger while still validating
    under -RequireApproval.

    (1) Ownership no longer blocks the AI-approval review loop. Ready for AI
    already overrode ownership; two real gaps sat next to it. First:
    ai_approved_status_id was only ever found via the Unassigned bucket
    (agent_id: 1), so a human who claimed a ticket just to approve it would
    make it invisible to the classifier - fixed with a new, explicit,
    status_id-filtered candidate call (paging fully, like the existing
    Ready-for-AI call), unconditional on agent_id. Second, and new: a human
    reviewing a pending draft by leaving a note - "reword this," "wrong
    device, try X" - rather than formally approving it would hit the
    ownership check's "a human is already working this, stay out" rule and
    get silently skipped forever, so the note would just sit there unread.
    Fixed with a second new candidate call (same status-filtered pattern,
    for ai_waiting_approval_status_id) that only includes a ticket if
    something has actually happened since the resolver's own last touch -
    an untouched, still-pending draft is still skipped, exactly as before,
    preserving the original cost protection. resolver-prompt.md gained a
    matching ownership-check exception (0b: your own prior draft note
    overrides the "someone else owns this" checks - proven safe because
    that note could only exist if no human had touched the ticket the
    first time around) and a new "If a human left a note on your own
    pending draft" section: read the human's guidance, incorporate it, and
    write an *updated* draft - never send directly, since a note is
    guidance, not the specific sign-off `ai_approved_status_name`/FLOW A
    requires. Deliberately did not invent a new tier for this - it's tiered
    normally by content, same precedent Ready for AI already set
    ("this status doesn't pre-decide the tier, only candidacy").

    (2) A durable "remember this" mechanism. When a human's note says
    something like "remember this" or "we'll remember that," expecting it
    kept for future tickets (not just this one), the resolver now captures
    it via a new `[CACHE: REMEMBER: <client or general>] <text>` marker -
    independent of, and coexisting with, the required TRACK/UNTRACK/BLOCKED
    line. Persisted in agent-cache.json's new `remembered_notes` list and
    injected into every resolver call as `{{REMEMBERED_NOTES}}` -
    deliberately NOT injected into classifier-prompt.md, since the
    classifier only tiers/finds candidates and would pay the token cost on
    every single call without ever using it. Chose this in-context-memory
    approach over a Hudu article specifically because the ask was "least
    cost and speed for future lookups": zero marginal tool calls, instant,
    versus a Hudu article costing a real lookup call each time it might be
    relevant. The real tradeoff, named directly rather than glossed over:
    unlike blocked_tickets' time-based aging, remembered notes never expire
    on their own - they're meant to be permanent institutional knowledge -
    so config's new `max_remembered_notes` (default 50) is the only thing
    bounding growth, oldest entries dropped first once exceeded, since an
    ever-growing list would otherwise inflate every future resolver call's
    cost forever. Explicitly instructed never to capture a password or
    credential verbatim into this plain-text, always-injected list.
    Verified the extraction regex, the cap logic, and a full JSON round-
    trip through ConvertTo-Json/ConvertFrom-Json (exactly how it persists
    to and loads from agent-cache.json) locally before shipping either
    piece.
    Version: 2.10.43 - identity rollout requested by Roger: resolver-prompt.md
    now speaks as "Allie," Altec's Virtual Service Coordinator, instead of an
    unnamed automated agent. Scope deliberately narrowed from Roger's original
    request after review - three behavior changes (permanent draft-only with
    no fully-live mode, always-human-review for password/access/identity
    requests, a referenced-but-undefined identity-verification procedure)
    were explicitly dropped at Roger's direction, so this ships tone/identity
    only, nothing that changes what Allie can do or when she needs sign-off.
    Added: the Allie name/title/naming rationale and never-claim-human rule
    near the top; a richer tone section (warm/calm/professional/empathetic/
    concise, first-name address); explicit frustrated-client guidance
    (acknowledge first, a concrete never-do list) alongside the tone section;
    a "Signing off" section requiring a standard signature on every client-
    facing reply, with an AI-disclosure line that varies by which
    update_ticket tool this run actually has (the same structural
    approval-mode check "Which update_ticket tool do you actually have?"
    already uses, not a new guess); an honest "if asked whether you're a
    person" handoff script; and a new "Accuracy and transparency" section -
    genuinely new, not previously written down anywhere - listing what must
    never be invented (troubleshooting results, ticket history, device info,
    technician availability, appointments, completion times, actions never
    actually taken) and keeping internal/security/confidential detail out of
    client-facing text. Caught and fixed one self-contradiction while
    drafting this: an early draft kept the old "don't mention you're an AI
    unless asked" line from this document's existing tone guidance, which
    directly conflicts with a signature that discloses AI-powered status on
    every single reply - removed the old line, since the signature's
    disclosure is now the standard, unconditional behavior and "if asked"
    covers only the separate case of a client raising it in conversation.
    Also fixed the one existing client-facing example sentence that used
    "escalating" (Roger's instruction: never use that word in anything a
    client sees, even though the document's own internal section headers and
    process language keep it - that's never client-visible, so left alone).
    Config.json's agent_username and the Halo-side agent rename are already
    handled directly by Roger; not touched here, and not synced by
    Update-HaloResponseAgent.ps1 regardless (see its own per-deployment
    file handling). Prompt-only change, no PS1 code touched - no new
    template variables, no changes to the approval-mode mechanics themselves.
    Version: 2.10.42 - real incident, reported by Roger from a live
    -RequireApproval run: tickets #21954 and #21952, in the same run, both
    landed a draft note correctly (private, unsent - update_ticket_draft_only
    worked exactly as designed, nothing went out) but with the wrong
    status_id on the real call: waiting_on_client_status_name instead of
    ai_waiting_approval_status_id. FLOW B's own instructions (the
    -RequireApproval banner built in this script) already said the right
    value unambiguously ("status_id: $($ids.ai_waiting_approval_status_id)"),
    but resolver-prompt.md's ordinary EASY-case section - written for the
    fully-live default, where "set status to waiting_on_client_status_name"
    is correct because a real reply was actually sent - also feeds the
    model's own reasoning about what status this ticket "should" be in. Both
    tickets conflated the two: correctly wrote
    "[INTENDED STATUS] waiting_on_client_status_name" in the draft note body
    (that part's right - it records what FLOW A should set later, once
    approved), then also applied that same value to the real status_id on
    THIS call, where FLOW B's fixed value should have applied instead. Not a
    missing instruction, a conflict-resolution failure between two correct-
    in-their-own-context instructions - the same failure shape as this
    project's other "an explicit rule existed and still wasn't prioritized
    correctly" incidents. Consequence is worse than a cosmetic status
    mismatch: waiting_on_client_status_name is exactly the status this same
    run's own classifier banner treats as ordinary, unremarkable ticket
    state (not the dedicated ai_waiting_approval_status_id state the
    classifier's banner explicitly protects from reprocessing) - so the
    pending, unreviewed draft would have looked like a normal
    already-handled ticket indefinitely, never flagged as needing a human's
    sign-off. Fixed by expanding FLOW B step 2 in place, at the exact point
    the real call is made, to explicitly name and preempt this conflation
    (citing this concrete incident) rather than trusting the model to keep
    the two status concepts separate on its own after deciding one first.
    Version: 2.10.41 - real incident, reported by Roger: the script stopped
    running entirely ("haven't seen any activity in a while"), and a manual
    run surfaced the actual error - "Cannot find an overload for 'TryParse'
    and the argument count: '2'" at the blocked_tickets loading line. Root
    cause: `$blockedAt = $null` followed by `[datetime]::TryParse($prop.Value,
    [ref]$blockedAt)` - PowerShell's method-overload binder can't resolve a
    `[ref]` argument against an untyped/`$null` variable, so this call has
    likely never actually worked, on any version of this script, since this
    loading code was first written (v2.10.30). It stayed silent purely
    because it only executes when `$agentCache.blocked_tickets` actually has
    an entry to iterate - and v2.10.39, shipped hours earlier, was very
    likely what produced this pipeline's first-ever real blocked_tickets
    entry (ticket #21950's "no marker" outcome). So a fix from earlier the
    same day is almost certainly what exposed a bug that had been dormant
    since v2.10.30 - the two are directly connected, not a coincidence.
    Confirmed both the failure and the fix locally before touching
    production code: reproduced the exact error with the isolated TryParse
    call, then fixed it by pre-typing the ref target (`[datetime]$blockedAt
    = 0` instead of `$blockedAt = $null`) and re-ran the *entire* loading
    block end to end against a realistic two-entry cache (one within the
    retry window, one past it) to confirm it now parses and prunes
    correctly, not just that it no longer throws. Checked the rest of the
    file for the same pattern - one other `[ref]` call exists
    (`[long]::TryParse` for a ticket ID) and was already written correctly
    (`$parsedId = 0L` pre-types it), so this was the only instance.
    Process note for next time: this script's existing
    `[System.Management.Automation.Language.Parser]::ParseFile` check after
    every edit (mandatory in this project since early on) verifies syntax
    only - it cannot and did not catch this, because a method-overload
    resolution failure is a runtime error, not a parse error. It shipped
    clean through that check for however long this code has existed. Worth
    remembering that "parses cleanly" and "actually runs" are different
    guarantees whenever a change touches a genuinely new code path (like a
    cache that had never before held a real entry) rather than one already
    exercised by prior runs.
    Version: 2.10.40 - v2.10.39's own BLOCKED-backoff fix confirmed working
    live, same day: ticket #21950 hit the identical deferred-tool confusion
    as #21934, but this time correctly triggered "treating as BLOCKED
    (backing off for blocked_ticket_retry_hours)" instead of being left
    unprotected - the structural fix held. The underlying confusion itself
    recurred anyway (this is now 2 of 4 Haiku-tier/TRIVIAL resolver calls in
    one log that reached for a PowerShell probe first, and both of those 2
    fully spiraled into a no-op turn; the 2 that recovered did so after a
    single denial; both Sonnet-tier/COMPLEX calls in the same log show zero
    of this pattern) - a real, still-open reliability tax concentrated in
    the cheap tier specifically, contained by v2.10.39's backoff but not
    eliminated by it. Traced the new spiral's exact shape: a denied
    PowerShell probe (checking the date, a "just verifying setup" no-op) was
    followed by the model treating that denial as if it cast doubt on
    whether its Halo MCP tools were connected at all - two unrelated
    systems, conflated. Added a second, narrower resolver-prompt.md
    paragraph naming this specific chain (PowerShell denial -> doubt about
    MCP tools) directly, alongside the existing ToolSearch-confusion
    paragraph from v2.10.39. No code change this time - this is squarely in
    "prompt fix with real but limited confidence" territory per v2.10.39's
    own reasoning, so the backoff mechanism, not the prompt wording, is what
    actually bounds the cost. Nothing else to fix here without more evidence
    - this is a pattern worth continuing to watch, not a lever to pull
    further blind.
    Version: 2.10.39 - real incident, from Roger's own log review of the
    first live runs after v2.10.36-38 shipped: ticket #21934's resolver hit
    a deferred MCP tool (this machine has enough MCP servers/tools
    registered that Claude Code defers some tool schemas until ToolSearch
    loads them - already known, `ToolSearch` was already granted to
    $resolverTools for exactly this), but instead of just calling
    `ToolSearch` per resolver-prompt.md's own existing instruction, it spun
    into confusion, tried a denied PowerShell probe for "Halo" commands,
    then ended its entire turn asking "can you confirm I have permission to
    invoke the MCP Halo tools?" - a question nobody was there to answer,
    in a fully headless run, despite resolver-prompt.md already saying
    explicitly not to do exactly this. $0.13 spent, zero ticket progress,
    no note or reply posted to the ticket, and - the real gap - no
    `[CACHE: TRACK|UNTRACK|BLOCKED]` marker either, so the existing "no
    marker" handling just logged a warning and left the ticket completely
    unprotected: identical to a fresh candidate next cycle, free to
    reproduce the identical confusion at the identical cost indefinitely.
    Two fixes: (1) resolver-prompt.md's existing ToolSearch guidance
    strengthened with the specific failure pattern observed (deferred !=
    permissions problem, never a reason to stop and ask) - a prompt fix
    alone given no real confidence, since the model already had and
    ignored a clear "never end your turn asking" instruction here; so (2)
    the actual fix: a resolver run ending with no marker at all is now
    treated the same as BLOCKED (added to blocked_tickets, backs off for
    blocked_ticket_retry_hours) instead of left unprotected - same
    reasoning blocked_tickets already exists for, just extended to cover
    "the resolver never got far enough to emit anything" alongside "the
    resolver explicitly gave up." Costs nothing if this was a one-off
    fluke (ticket just gets a normal cycle after the backoff window); stops
    it from being a repeatable, silent cost leak if it isn't.
    Version: 2.10.38 - follow-up to v2.10.37, same day: Roger asked to have
    cipp-mcp itself fixed for the ListMessageTrace param-naming gap that let
    v2.10.37's ticket #21900 investigation skip the trace. Fixing it exposed
    something worse. Verified live: cipp-mcp's `cipp_api_get` generic
    passthrough was never the actual bug - it forwards whatever params it's
    given correctly - the resolver's *guesses* at param names
    (`Recipient`/`recipientAddress`, missing the required `days` window) were
    wrong. Found the real param names (`tenantFilter`, `days`, `sender`,
    `recipient` - all lowercase) from CIPP's own community PowerShell module
    source (BNWEIN/CIPPAPIModule) and added a dedicated
    `mcp__CIPP__list_message_trace` tool to cipp-mcp so a resolver never has
    to guess this again - same "mechanical tool over remembered judgment"
    pattern as `human_touch`/`update_ticket_draft_only` this session.
    But testing the corrected call against ticket #21900's own tenant
    (bcfo.org) still didn't return bcfo.org's mail - it silently returned
    Altec's own partner-tenant traffic instead (`@altecusa.com` addresses),
    byte-identical whether `tenantFilter` was the domain name or the tenant's
    GUID `customerId`. A second client tenant (springfieldbrewingco.com)
    instead threw a 500 wrapping a 404 from the underlying Exchange call.
    Confirmed this is a real gap in this CIPP deployment's message-trace
    integration for delegated/managed tenants (likely a GDAP/Exchange-Online-
    remoting session/permission issue, not something visible from Graph-API-
    backed endpoints like ListUsers/ListMailboxes, which correctly honor
    `tenantFilter` for the same tenants) - not something fixable from either
    MCP repo's own code. Flagged to Roger to investigate on the CIPP/GDAP
    side rather than silently shipped as "fixed." Given the tool can return a
    fully-formed, successful-looking result for the wrong tenant, v2.10.37's
    "trust the trace" framing was itself dangerous without a check - amended
    resolver-prompt.md's message-trace guidance to require confirming the
    returned rows' addresses actually belong to the requested tenant before
    treating a trace result as evidence of anything, and to fall through to
    the NDR-search check (or say delivery couldn't be confirmed) rather than
    trusting an error or a wrong-tenant result either way.
    Version: 2.10.37 - real incident, found by Roger reviewing the same
    -RequireApproval validation cycle as v2.10.36: ticket #21900, a client
    report that mail wasn't arriving at `accounting@bcfo.org`. The resolver
    found `accountEnabled: false` on that account via `mcp__CIPP__get_user`
    and reported it as the likely cause in its draft note, recommending a
    human review before re-enabling - without ever running the
    ListMessageTrace check resolver-prompt.md already documents for email
    delivery issues. `accounting@bcfo.org` is a shared mailbox
    (`recipientTypeDetails: SharedMailbox`) - shared mailboxes have no
    interactive sign-in by design, so a disabled account there is normal,
    not a fault. Roger's own message trace the next day showed mail had in
    fact been delivered successfully (one message quarantined, unrelated).
    Two compounding gaps, both in resolver-prompt.md's prompt text only (no
    code change needed - the tool calls already existed): (1) the
    message-trace step was written as one option among several rather than
    a required check before reporting a cause, so it was skippable in
    practice; (2) nothing anywhere told the resolver a disabled account is
    expected/benign on a shared mailbox specifically, so a true-but-benign
    fact (`accountEnabled: false`) was reported as if it were diagnostic.
    Fixed both in resolver-prompt.md's "Email delivery / bounce issues
    specifically" section: the trace is now framed as required before
    reporting any suspected cause as a finding ("a hypothesis, not a
    diagnosis" until confirmed), and a new rule requires checking
    `recipientTypeDetails` before flagging any disabled/locked account as a
    possible cause of anything, since shared/room/equipment mailboxes being
    disabled is expected and only a disabled real UserMailbox is actually
    informative. This is a diagnostic-accuracy gap, not a safety/cost one
    like v2.10.30-2.10.36 - the ticket correctly went to Waiting Approval
    and nothing was sent without review - but a wrong root cause reaching a
    human reviewer as a confident recommendation defeats the point of
    review just as surely as a cost or safety miss would.
    Version: 2.10.36 - real incident, found by Roger reviewing a live
    -RequireApproval validation cycle: ticket #21478, actively worked by
    real humans (Roger, Erick Gonzales - calls, replies, status changes)
    for days, sat in `waiting_on_client_status_name` and reached a real
    Sonnet resolver call ($0.25) purely to re-discover "a human already
    owns this" via human_touch - something a status-name check should have
    caught for free, the same way "Dispatch Needed" already does.
    classifier-prompt.md's Unassigned-bucket pre-filter never included
    `waiting_on_client_status_name`/`follow_up_status_name` - the two
    statuses THIS PIPELINE ITSELF uses for hand-back and escalation -
    despite `waiting_on_client_status_name` being named, from the very
    start of this project's ownership-check work, as a status real techs
    use routinely too. Root cause: any ticket reaching the Unassigned
    bucket while in one of these two statuses is, by construction, never
    this pipeline's own doing - a genuine bot-created `waiting_on_client_status_name`
    ticket is already excluded by the tracked-list check (the pipeline
    always emits [CACHE: TRACK] when setting it), and an escalated ticket
    always emits [CACHE: UNTRACK] immediately, so it looks "fresh" to this
    bucket the very next cycle unless caught by status. Fixed as a plain
    numeric check, not a judgment call: $ids.waiting_status_id/
    $ids.followup_status_id (already resolved for resolver-prompt.md) are
    now also injected into classifier-prompt.md as
    {{WAITING_STATUS_ID}}/{{FOLLOWUP_STATUS_ID}}, and the Unassigned bucket
    drops a ticket_id match against either one outright, ahead of (and
    independent from) the existing status-name judgment-call list. Chose a
    mechanical ID comparison over adding these two names to the existing
    judgment-call list deliberately - this project's whole track record
    this session is judgment calls not being applied consistently every
    time (the approval bypass, the missed ownership check), and this one
    has a clean, always-correct mechanical rule available, so it doesn't
    need to be a judgment call at all.
    Version: 2.10.35 - correction, same day as v2.10.33: NordLayer and the
    per-client NinjaOne VPN configuration scripts are two completely
    unrelated products solving two unrelated problems, not a hierarchy -
    v2.10.33 wrongly described NordLayer as covering business VPN needs
    "beyond what a NinjaOne script covers," implying overlap. Corrected
    per Roger: NordLayer is exclusively the sanctioned replacement for a
    personal/consumer VPN application (NordVPN, ExpressVPN, etc. - privacy/
    proxy-style apps someone installed themselves) - it has nothing to do
    with a client connecting to their own company's internal network,
    which is a different need entirely, solved by the Windows built-in VPN
    client via that client's own NinjaOne script ("Company VPN access
    requested"). Also fixed the "personal/consumer VPN flagged" section's
    own internal-resource-access branch, which had inherited the same
    conflation (recommending NordLayer for someone who needed internal
    network access, not a consumer-VPN replacement) - it now points to the
    "Company VPN access requested" flow instead, naming no product from
    the wrong category.
    Version: 2.10.34 - cost investigation requested by Roger ("is there
    anything else to help reduce costs"): a TRIVIAL-tier ticket (#21880,
    Haiku, the cheapest tier) cost $0.64 in a real log - three to eight
    times a typical TRIVIAL ticket's $0.08-0.23 - and its own
    subagent_stats showed 7 spawned/completed subagents, in the same run
    where separate PowerShell tool-call attempts were correctly denied.
    --allowedTools is an inclusion list built only from named MCP tools;
    none of $resolverTools/$classifierTools/etc. include Claude Code's
    built-in subagent-launching tool, but that tool isn't confirmed to be
    gated by the same allowlist a named MCP tool or Bash/PowerShell is -
    matching the observed denied-vs-spawned split in the same run.
    Invoke-ClaudeCLI now explicitly adds `--disallowedTools "Agent,Task"`
    (covering both the tool's current and former name) and sets
    CLAUDE_CODE_DISABLE_BUILTIN_AGENTS=1 for the duration of the native
    call (Claude Code's documented headless-mode fallback, restored
    afterward) - belt-and-suspenders, since this pipeline's per-tier tool
    sets are already curated to be sufficient; no tier should ever need to
    delegate its own investigation to a second, separately-billed Claude
    invocation. Unverified against a live run at time of writing - worth
    confirming via -WhatIf or a real cycle that subagent_stats.spawned
    stays 0 going forward.
    Version: 2.10.33 - policy fix requested by Roger: a real ticket
    (#21730) showed the resolver recommending Bitwarden/1Password for a
    password manager - reasonable-sounding generic advice, and the wrong
    answer, since Altec is a Keeper reseller/partner. resolver-prompt.md
    gained a "Recommending a password manager or a business VPN" section:
    always Keeper by name for a password manager, always NordLayer by name
    for a legitimate business/commercial VPN need (distinct from the
    per-client NinjaOne VPN configuration scripts, which remain the answer
    when a client already has one set up) - explicitly exempted from the
    "no vendor/tool names" client-facing-tone rule, since recommending a
    product the client would actually use is the point, not an internal-
    tooling leak like naming Huntress or NinjaOne would be.
    Version: 2.10.32 - follow-up to v2.10.30 (BLOCKED) and the ownership
    check, after Roger pushed back on the BLOCKED diagnosis and asked why
    the ownership check itself wasn't more reliable, rather than accepting
    a workaround. Live investigation of the exact ticket behind v2.10.30
    (real Halo timestamps, not the log's own summarized text) found the
    original "Halo permanently swallows the write" theory was wrong: the
    note that ticket's resolver believed never landed actually did land,
    a few minutes after its own immediate verification check had already
    given up. The real mechanism is Halo's own eventual consistency, not a
    permanent block. Separately, the exact same live investigation found a
    genuine ownership-check miss on a different ticket: a human's status
    change was already five minutes old in Halo's own action log by the
    time a resolver pass ran, and that pass still concluded "untriaged, no
    human touch found" - the very next pass, five minutes later, correctly
    caught the same evidence. Same rule, same data, inconsistent outcome -
    a reliability gap, not a design gap.
    Fixed both at the layer where the underlying fact is genuinely
    mechanical rather than judgment, per Roger's own steer ("if the MCP
    can offload some of that, fine, as long as it doesn't affect other
    functions of the MCP"). Confirmed halopsa-mcp's /status route (the
    only thing anything outside this pipeline depends on - the NOC
    wallboard in the separate Dashboard repo) shares no code with either
    change: (1) mcp__Halo__update_ticket_draft_only now always verifies
    its own write with built-in retries against real wall-clock delay
    (something this resolver has no tool to do itself) before returning,
    and mcp__Halo__update_ticket gained an opt-in verify parameter (default
    false - existing callers of that tool, including any outside this
    pipeline, see byte-for-byte the same response/timing unless they
    explicitly ask for the new behavior); (2) mcp__Halo__get_ticket_time_entries
    now returns a computed human_touch field ({found, actions}) alongside
    its unchanged raw actions list - the exact same mechanical rule
    resolver-prompt.md's ownership check already used (who_type: 1, not
    this pipeline's own identity), just computed once, reliably, instead
    of re-derived by the model scanning a list that can run past a dozen
    entries. Both changes are purely additive to existing tool responses
    or gated behind a new opt-in parameter - no existing behavior for any
    other caller changed. resolver-prompt.md's "Halo's own ticket-triage"
    section (renamed "A write can report success and not be immediately
    readable back") and its ownership check were both rewritten to use
    these directly instead of doing their own manual re-fetch-and-scan.
    Version: 2.10.31 - real incident, reported by Roger from a live day's
    log: several tickets under -RequireApproval got a real, emailed
    client-facing reply sent directly, bypassing the approval hold
    entirely (confirmed: tickets #21871, #21880, #21887, #21888, all on
    TRIVIAL/TRIVIAL_UNCERTAIN tier, the cheapest model/shortest-effort
    combination). Root cause: mcp__Halo__update_ticket was never actually
    removed from a non-APPROVED ticket's tool allowlist under
    -RequireApproval (it couldn't be - FLOW B's own draft/status/unassign
    bookkeeping needed some update_ticket-shaped tool), so whether a reply
    stayed private depended entirely on the resolver choosing to follow
    the approval banner's redirect over other, more concrete "reply now"
    instructions written throughout the rest of resolver-prompt.md
    (the TRIVIAL_UNCERTAIN section, the EASY/NOT EASY sections, etc.) -
    which it didn't always do, especially on the cheaper tier. Fixed
    structurally, not just with more prompt text: halopsa-mcp gained a new
    tool, update_ticket_draft_only - identical to update_ticket in every
    other respect, but a note it writes is always private and unemailed,
    regardless of what's passed, and it throws a loud error rather than
    silently downgrading if the caller explicitly tries to override that.
    $resolverToolsApprovalStripped now removes mcp__Halo__update_ticket
    entirely for a non-APPROVED ticket and gives it update_ticket_draft_only
    instead, so sending a real reply is no longer possible regardless of
    what the model does - a tool-allowlist-level guarantee, the same
    category of fix already used for remediation actions, extended to
    cover this gap too. resolver-prompt.md also gained a new "Which
    update_ticket tool do you actually have?" section near the top (an
    ever-present, not conditionally-injected, reinforcement - the model is
    told to check which tool is actually available rather than trust a
    rule read many tokens earlier) plus a reinforcement inline at "Sending
    a real, client-facing reply," the single place every other section's
    "reply to the client" instruction ultimately routes through.
    Version: 2.10.30 - real incident, same log as v2.10.31: a ticket stuck
    in Halo's own untriaged-ticket write-swallow bug (see "Halo's own
    ticket-triage" in resolver-prompt.md) got fully reprocessed by the
    resolver every single cycle - confirmed live: one ticket cost over a
    dollar across three consecutive cycles in about ten minutes, each one
    correctly concluding "a human needs to fix something in Halo, I can't
    act on this" and stopping, with no sign it would ever stop reprocessing
    on its own. [CACHE: TRACK] didn't help: the underlying problem is that
    literally nothing lands on the ticket, not even the tracking note
    itself, so a future cycle's tracked-ticket recheck found no evidence
    anything had been tried and treated it as a brand-new candidate again
    every time. Added a third real marker, [CACHE: BLOCKED] (resolver-
    prompt.md's "When you finish" section), for this specific class of
    problem - a structural/platform dead end only a human fixing something
    in Halo can resolve, where immediate retry reproduces the identical
    failure at the identical cost. A new blocked_tickets map in
    agent-cache.json (ticket_id -> when it was last found blocked) excludes
    those IDs from the classifier's Unassigned candidate list
    (classifier-prompt.md's call 1) until claude.blocked_ticket_retry_hours
    (default 4) has passed, at which point the entry simply ages out and
    the ticket becomes a normal candidate again automatically - no special
    recheck logic needed for that half, aging out IS the retry.
    Version: 2.10.29 - follow-up, same day as v2.10.28: verified live that
    the device-lookup fix's hostname-pattern-matching approach was itself
    weak - on the actual Gold Mechanical case, no device hostname contained
    the contact's name at all, and even her stated Windows UserID
    ("jcodie") didn't exactly match what NinjaOne had on record for her
    device (logged in as "JCody"). Rewrote resolver-prompt.md's device
    lookup to search NinjaOne's `lastLoggedInUser` field (the reliable
    signal) instead of hostname pattern-matching: mcp__Ninja__list_devices_detailed
    returns `lastLoggedInUser` directly in its bulk response (confirmed
    live - no per-device get_device call needed), but its own org_id filter
    doesn't actually filter server-side (same bug class already known for
    list_devices), so the instructions now page through with the `after`
    cursor and filter client-side by organizationId, matching the login
    field loosely against the contact's name/email/stated UserID rather
    than requiring an exact string match against any one of them. Also
    added explicit multi-match handling, requested by Roger: prefer the
    most recently active device, weigh device type against ticket context
    (e.g. "working from home" implies a laptop), and if still ambiguous,
    ask the client to confirm which specific device rather than picking
    silently.
    Version: 2.10.28 - real incident: a VPN-access ticket (Gold Mechanical,
    #21866) got a draft reply asking the client what device they'd be
    using, without the resolver ever calling a NinjaOne tool first - the
    action log showed no device lookup at all. resolver-prompt.md's
    "investigate" step only ever said "NinjaOne for device health/patches/
    software" in general terms, with no instruction to actually try
    mapping the ticket's contact to a NinjaOne device before falling back
    to asking. Added an explicit "Before asking the client which device/
    workstation they're on, try to find out yourself" instruction
    (list_organizations to map the Halo client to its NinjaOne org -
    confirmed live that list_org_contacts is frequently empty, so match by
    client name instead - then list_org_devices/get_device to look for a
    hostname or last-logged-in-user match), plus a "Company VPN access
    requested" section covering the whole flow for that specific case:
    identify the device, check whether the VPN client is already
    installed, run the matching per-client "Add <Company Abbreviation> VPN
    Configuration" NinjaOne script if not (new config.json remediation
    whitelist entry, requested by Roger - the script name varies per
    client, so resolver-prompt.md's remediation-whitelist matching rules
    were extended to cover a placeholder-style entry name, not just exact
    literal names), then actually walk the client through connecting via
    Windows' built-in VPN client rather than a vague "we're setting it up,
    details to follow." Config note from Roger: no OpenVPN references -
    Altec is moving away from it.
    Version: 2.10.27 - real incident: Roger reported a ticket that had gone
    quiet (waiting on a client reply) got a fresh reply and was skipped
    entirely - not tiered, not touched. Verified directly against the live
    Halo tenant that its /Tickets response for the unassigned-bucket query
    (agent_id: 1, team_id: Help Desk) is ordered by ticket ID/creation date
    descending, not by last-updated - so the page_no:1/page_size:15 pull
    both classifier-prompt.md's own candidate list and halopsa-mcp's
    /helpdesk-gate fingerprint (v2.10.24) relied on could miss a ticket
    with an older ID that just got fresh activity, if enough newer tickets
    existed to bump it past page 1. Fixed on both sides: halopsa-mcp's
    buildHelpDeskGate now pages through the whole unassigned bucket (new
    fetchAllTickets helper, page_size 20, capped at 5 pages/100 tickets -
    the cap is a runaway-cost guard against an unusually large queue, not
    a real limitation, since this all happens as plain Worker-side HTTP
    calls with zero LLM cost either way) instead of trusting page 1 alone,
    same pattern the stuck-claimed/Ready-for-AI buckets already used;
    classifier-prompt.md's own "Unassigned" candidate call (call 1) does
    the same full paged sweep now rather than a single page. The gate
    response also carries a new unassigned_truncated flag (only true if a
    queue somehow exceeds the 100-ticket cap) which the PS1 script logs as
    a NOTE line if it ever fires, so a future gap like this shows up in the
    log instead of silently recurring.
    Version: 2.10.26 - design change, requested by Roger: a tracked ticket
    a real tech resolves before this pipeline gets back to it used to be a
    dead end - classifier-prompt.md's tracked-ticket check just emitted
    UNTRACK the moment it saw the ticket closed or reassigned, and whatever
    fix the human actually applied was never captured anywhere this
    pipeline could learn from later. Added a new real tier, LEARN_FIX:
    classifier-prompt.md now distinguishes "closed" (by status name, via
    the same status_id_names lookup added in v2.10.22) from "still open but
    reassigned" - only the former routes to LEARN_FIX instead of bare
    UNTRACK. resolver-prompt.md's new "If the assigned tier is LEARN_FIX"
    section is a read-only pass, skipping every claim/reply/status section
    entirely: read the closing tech's own notes, and if they documented a
    real fix, write it to Hudu via the existing "Documenting a fix that
    worked" process - using the TECH'S account, explicitly superseding
    anything this pipeline itself guessed on that same ticket in an earlier
    cycle, never blending the two. Gets a fixed, minimal tool allowlist
    (get_ticket/get_ticket_time_entries plus Hudu read/write only - no
    mcp__Halo__update_ticket at all, so -RequireApproval/-WhatIf's
    mutating-tool filtering doesn't need to consider this tier) and the
    cheap trivial-tier model, since it's a read-and-summarize task, not a
    fresh investigation.
    Version: 2.10.25 - design change, requested by Roger: this account is
    API-only and invisible in Halo's own agent-picker UI, so the resolver's
    temporary self-claim while working a ticket ("Claim the ticket")
    signals nothing to a human colleague - it's just an extra write with no
    real benefit today, though it would if this account is ever upgraded to
    a real licensed Halo user later. Added halo.agent_can_self_assign
    (config.json) - a plain boolean, not a Halo name, so it needs no Stage
    0 resolution. false ("do not assign me" mode, this account's actual
    current state) skips the mid-processing self-claim entirely in both
    resolver-prompt.md's "Claim the ticket" section and the -RequireApproval
    FLOW A banner's own claim step; true preserves the original always-
    self-claim behavior. Either setting still ends every path with the
    same unconditional "return to a neutral agent_id" step - this only
    ever affects the interim claim, never the final handoff. Missing/absent
    defaults to true, so an older config.json sees no behavior change.
    Version: 2.10.24 - real incident, same day as v2.10.20-23: the classifier
    ran (and paid real cost) every single cycle despite Roger reporting
    "no updates, no status changes, nothing" - the pre-flight gate's
    unassigned_count was a bare count, not a change check, so a queue that
    always has a few non-actionable tickets sitting at agent_id: 1 (AI
    Waiting Approval, Dispatch Needed - Halo clears assignment as a side
    effect of these statuses, see resolver-prompt.md) reported count > 0
    and forced a classifier run every 15 minutes, forever, even when none
    of those specific tickets had changed at all since the last check. This
    was the actual, structural version of the cost complaint the status
    pre-filter (v2.10.22) only partially addressed - that fix stopped the
    RESOLVER from being called on a known non-candidate, but did nothing to
    stop the CLASSIFIER itself from running every cycle regardless.
    Extended halopsa-mcp's /helpdesk-gate to return the unassigned bucket's
    actual tickets (id/last_update/status_id), not just a count - same
    page_size (15) classifier-prompt.md's own unassigned scan already uses,
    so this fingerprint covers the same window. Invoke-HaloResponseAgent.ps1
    now fingerprints this bucket exactly the way it already did for tracked
    tickets: only counts it as changed if a ticket ID wasn't in
    unassigned_last_seen (agent-cache.json) last cycle, or an already-seen
    one's last_update moved - a ticket merely leaving the bucket isn't
    itself a signal, so that alone doesn't trigger a run, only prunes it
    from the cache. A cycle where the same static set of tickets is still
    sitting there, unchanged, now correctly logs "SKIPPED (gate: nothing
    changed)" at the cost of one cheap HTTP call, same as it always should
    have.
    Version: 2.10.23 - real incident, same day as v2.10.22: that exact fix
    ran for a full cycle at real cost with status_id_names entirely missing
    (a logged warning said so directly), because the ID cache's
    invalidation logic only ever compared config.json's own halo.*/
    compliance.* text - a code deploy that changes what
    id-resolver-prompt.md resolves, with no config.json name behind the new
    field, left old cached IDs looking "still valid" and silently missing
    it for up to id_cache_max_age_hours. Not the first time this exact
    class of surprise hit this session (the Ready for AI status rename hit
    the same underlying gap, just masked because a config-side name
    happened to also change alongside it that time). Added
    $idSchemaVersion, a plain literal bumped by hand any time
    id-resolver-prompt.md's OUTPUT schema changes - a field added, removed,
    or resolved differently - even when no config.json name is involved at
    all; it's now part of the same cache-identity object config.json's
    names already are, so a schema-changing deploy invalidates old caches
    exactly like a name edit always has, with no separate "remember to
    clear the cache after this specific kind of change" step for a human
    to forget. This one deploy bumps it from unset to "2," which
    self-heals this exact incident the moment the file is on disk - no
    manual cache-clear needed for this fix specifically, unlike the two
    before it.
    Version: 2.10.22 - real incident, same day as v2.10.21: ticket 20910 sat
    in "Dispatch Needed" and cost a full classifier+resolver cycle
    (~$0.42) every time it was rescanned, each one correctly concluding a
    human agent already owned it via v2.10.21's own bright-line rule -
    reaching the same true answer the expensive way, every 15 minutes,
    because nothing recognized the status itself. Added status_id_names
    (every Halo status id -> name) to id-resolver-prompt.md's output,
    built from the exact same list_statuses call already made for the
    other status fields - zero extra API cost, same pattern as the
    existing ticket_type_names lookup. classifier-prompt.md's "Unassigned"
    bucket now drops a candidate before it's even a candidate if its
    status name clearly signals an already-active non-Help-Desk-AI
    workflow (Dispatch Needed, Scheduled, Waiting on vendor, Quote*,
    Scoped for review, Awaiting Deployment, With CAB, On Hold, Awaiting
    Approval/Approved), using data list_tickets already returns - no new
    tool call, no resolver call at all for these going forward. This is a
    judgment call on the status name, deliberately not a hardcoded list,
    and deliberately not the safety backstop - v2.10.21's human-touch rule
    still runs on everything that gets through, so a status this filter
    misjudges still can't result in acting on a human-owned ticket, only
    in one avoidable resolver call, same as before this fix. Never applied
    to a ticket carrying the Ready for AI status (v2.10.21), which exists
    specifically to override signals like this one, or to the
    "Stuck-claimed" bucket, whose own rule is "never silently drop
    regardless of status."
    Version: 2.10.21 - real incident: the resolver claimed and drafted work
    on tickets a human colleague was actively coordinating (Dispatch Needed,
    Waiting on client), requiring the status reverted and notes deleted by
    hand. The prior "is this really unassigned" check (v2.10.15) judged
    whether a human's activity looked "recent" or "stale" before treating
    agent_id: 1 as free - that judgment call is exactly what let this
    through, since a status change or note from weeks ago is not evidence a
    ticket is free, it's evidence a human still owns it. Hardened into a
    bright-line rule in resolver-prompt.md: any real human agent action in
    the history, ever, means the ticket isn't available - no "how recent"
    judgment left. Added the one deliberate override this needs: a new
    config.json field, halo.ready_for_ai_status_name (optional/nullable,
    same pattern as ai_waiting_approval_status_name/ai_approved_status_name),
    resolved the same way, that a human sets on any ticket to force this
    pipeline to take it over regardless of current assignment or history.
    classifier-prompt.md gained a 4th candidate-finding bucket for it
    (list_tickets filtered by team_id + the new status_id, added as an
    optional filter on halopsa-mcp's list_tickets alongside the existing
    team_id/agent_id ones), included unconditionally. This status is
    orthogonal to -RequireApproval by design - it only overrides candidacy,
    never the FLOW A/FLOW B approval-gating logic, so a Ready-for-AI ticket
    under -RequireApproval still drafts and holds for human sign-off like
    any other. See CLAUDE.md for the full design writeup, including a
    deliberately deferred cheap status-based pre-filter at the classifier
    stage that would catch obviously-never-ours statuses (Scheduled,
    Waiting on vendor, etc.) before spending a resolver call at all.
    Version: 2.10.20 - real incident: ticket 20910 (and separately, a genuine
    Entra Connect sync-error alert, ticket 21798) sat untouched across many
    consecutive cycles despite the classifier correctly finding them as
    candidates every time (team_id filter from v2.10.17 confirmed working via
    the classifier's own logged tool-call params). The resolver call for both
    kept "failing" with $0 cost and zero action taken, logging: "ERROR:
    Warning: Unknown --effort value 'mediumx' - ignoring it and using the
    default effort." That text is the claude CLI's own stderr, and per its
    own wording the CLI recovered from it and continued normally - the bad
    value came from a live-config.json typo in resolver_effort_complex (not
    this repo's config.json, which is unaffected). The real bug is in this
    script, not the config: Invoke-ClaudeCLI's `2>&1` merge, combined with
    this script's global $ErrorActionPreference = "Stop" and PowerShell
    7.3+'s $PSNativeCommandUseErrorActionPreference defaulting to $true,
    promotes ANY stderr line from the claude process into a terminating
    exception the instant it's written - even one the CLI itself explicitly
    logged as non-fatal and moved past. That exception fired before
    $rawOutput was ever assigned, so Invoke-ClaudeCLI never returned, the
    ticket was never actually worked, and the outer catch block logged the
    CLI's own recovered-from warning as if the whole call had failed. This
    would have happened for any stderr chatter from claude, not just this
    specific typo. Fixed by scoping $PSNativeCommandUseErrorActionPreference
    = $false around just the native `claude` invocation in Invoke-ClaudeCLI,
    restoring the pre-7.3 behavior where native stderr is still captured
    (still visible in the log via the 2>&1 merge) but no longer treated as a
    terminating error on its own.
    Version: 2.10.19 - real incident, unrelated to v2.10.18's changes: a
    classifier call hit a transient MCP connection issue and genuinely
    could not invoke any Halo tool that cycle - its own raw result said so
    directly ("I don't have direct invocation capability for these MCP
    tools in my current session's tool set") - but instead of reporting
    that cleanly, it fabricated a placeholder result alongside the prose:
    {"ticket_id": 0, "tier": "LOADING"}. This script accepted that as a
    real candidate (it's syntactically valid JSON) and spent a full
    resolver call - $0.16 - "discovering" that ticket 0 doesn't exist in
    Halo (404). Halo ticket IDs are always positive integers, so added a
    validation pass right after classifier parsing: any ticket whose
    ticket_id doesn't parse as a positive integer is discarded with a
    logged warning before it ever reaches the resolver, falling through to
    the normal "no candidates" path if that empties the list. classifier-
    prompt.md also gained an explicit instruction for this failure mode:
    if Halo tools genuinely aren't callable this run, the correct output is
    plain [] - the same as a normal quiet cycle - never a fabricated
    ticket_id or explanatory prose.
    Version: 2.10.18 - v2.10.17's team_id filter was not enough by itself:
    another ~$20 accrued overnight even after that deploy, because every
    single 15-minute cycle - including the vast majority that find nothing
    - still ran the full classifier LLM call. Two structural changes, plus a
    third, unrelated cleanup Roger asked for while looking at this:
    1. Off-hours throttle: outside business hours, skip a scheduled firing
    entirely (no ID resolution, no gate, no classifier - just a log line)
    unless config.json's business_hours.off_hours_check_interval_minutes
    (default 60) has passed since the last real check. Business hours are
    roughly a third of a day's scheduled cycles, so most of the waste was
    happening outside them; a genuine emergency is still caught within this
    interval since the resolver's emergency handling doesn't depend on
    cadence, just on a cycle running at all.
    2. Pre-flight gate: added a new GET /helpdesk-gate route to halopsa-mcp
    (separate repo, rafouche/MCPs) that answers "is there plausibly anything
    to find" using only cheap, count-only or single-ticket Halo calls - no
    Claude CLI, no LLM, called directly over plain HTTP via Invoke-RestMethod
    (its base URL found from .mcp.json's own "Halo" entry, not a second
    hardcoded place). If the gate reports zero new unassigned tickets, zero
    stuck-claimed tickets, and no tracked ticket's last_update has changed
    since it was last seen, the classifier call is skipped entirely for that
    cycle. Fails open on any problem (missing Worker URL, network error,
    malformed response) - always runs the classifier normally rather than
    risk silently skipping a cycle that needed it. Neither this nor the
    throttle above ever applies under -WhatIf/-DryRun.
    3. Consolidated resolved-ids-cache.json and tracked-tickets.json into one
    agent-cache.json (also now holding tracked_last_seen for the gate and
    last_real_cycle_at for the throttle) - one local cache file instead of
    several scattered ones, migrating existing content from the old two
    files on first run rather than discarding it, then removing them.
    Version: 2.10.17 - real incident: two overnight log files showed ~$20+
    in cost concentrated in cycles finding zero tickets - "tickets_found":0
    cycles costing $0.10-$2.49 each, dozens of times a day. Root cause,
    visible directly in the logs: the classifier's Unassigned/Stuck-claimed
    list_tickets calls had no team_id filter, so every cycle fetched every
    team's tickets account-wide (82 full ticket bodies in one cycle, almost
    all irrelevant) just to manually discard everything outside Help Desk -
    real cost every 15 minutes regardless of findings, plus repeated denied
    PowerShell tool attempts and subagent spawns trying to cope with the
    oversized results. Fixed at the source: halopsa-mcp's list_tickets
    gained a team_id parameter (HaloPSA's own /Tickets filter), and
    classifier-prompt.md's Unassigned/Stuck-claimed calls now pass
    team_id: {{TEAM_ID}} alongside agent_id - the existing "keep only Help
    Desk team_id" check stays as a backstop, not the primary filter. This
    is the biggest cost lever available: it fires on every cycle, not just
    ones with findings, which config.json's effort/model settings can't
    touch at all since this bloat happens during candidate search, before
    any tier or model is chosen.
    Version: 2.10.16 - v2.10.15's include_inactive fix was itself
    incomplete, two more real corrections found by testing live rather
    than trusting the fix worked: (1) include_inactive was sending
    includeinactive, the /Client convention this codebase copied - but
    /Agent's real param is includedisabled (confirmed against HaloPSA's
    live swagger spec); includeinactive isn't real on /Agent at all, so it
    was silently ignored the whole time, no error, no effect. (2) Even
    fixed, Cynthia Hicks still wouldn't have appeared: she's
    isdisabled: false, just isapiagent: true (no interactive login) -
    API-only and disabled are independent categories on /Agent, confirmed
    live (this tenant has 3 API-only agents - halointegrator, Huntress,
    Cynthia Hicks - none disabled, plus separate disabled-but-not-API-only
    agents). Fixed in halopsa-mcp: list_agents' include_inactive now sends
    includedisabled, and a new include_api_agents sends includeapiagents.
    id-resolver-prompt.md's retry now passes both together in one call.
    Verified live: list_agents({include_inactive:true,
    include_api_agents:true}) returns Cynthia Hicks (agent_id: 31).
    Version: 2.10.15 - supersedes v2.10.14's agent-identity fix with the
    actual root cause, plus a second, separate bug found while chasing it
    down. v2.10.14's ticket-history-scanning fallback (list_tickets +
    get_ticket_time_entries, matching actionby_application_id: "Claude")
    was itself built on a wrong assumption - every action it would have
    found showed who_agentid: 17 / who: "halointegrator", a different
    generic integration identity, never this pipeline's own account. It
    would have "worked" only in the sense of not crashing, silently caching
    the wrong ID forever.
    Root cause #1: mcp__Halo__list_agents excludes inactive/disabled agents
    by default (confirmed via HaloPSA's own documented
    IncludeActive/IncludeInactive flags on GET /Agent) - the same behavior
    list_clients already has for inactive clients. An account whose Halo
    licence was removed is disabled, not deleted, so it's excluded from a
    plain list_agents call for that ordinary reason, not because API-only
    accounts are structurally unreturnable. Fixed in halopsa-mcp (separate
    repo, rafouche/MCPs): added include_inactive to list_agents, mirroring
    list_clients' existing param exactly. id-resolver-prompt.md now retries
    list_agents with include_inactive: true when the plain call doesn't
    match halo.agent_username, before giving up - restoring the original
    design in full: a plain name in config.json, resolved and cached
    automatically, no config field of any kind for this case. The
    ticket-history-scanning fallback and its list_tickets/
    get_ticket_time_entries tool grants are removed from
    id-resolver-prompt.md/$idResolverTools entirely.
    Root cause #2, separate and more consequential: every note/reply this
    pipeline has ever written was attributed to the wrong identity in
    Halo's own ticket history. HaloPSA attributes every API-created action
    to whichever agent the OAuth client_credentials application is bound to
    in Halo's own admin config ("Login Type: Agent"), unless the /Actions
    payload explicitly overrides it with who_agentid - which
    halopsa-mcp's update_ticket never sent. Fixed in halopsa-mcp:
    update_ticket gained a new note_agent_id parameter (deliberately not a
    reuse of agent_id, which is ticket assignment and is routinely 1/
    Unassigned in the exact same call that logs a ticket's final note - see
    resolver-prompt.md's "Claim the ticket" section) that sets who_agentid
    on the /Actions POST when a note is included. resolver-prompt.md gained
    a new blanket section, "Every note must say who wrote it," requiring
    note_agent_id: {{AGENT_ID}} on every update_ticket call that includes a
    note. This is a Cloudflare Worker deploy, not something this repo's own
    files can fix alone - notes/replies written before that deploy keep
    showing the old generic identity in Halo's permanent history; only new
    ones after deploy are corrected.
    Version: 2.10.14 - two real incidents, both from the same overnight run.

    First: the tracked-tickets cache (v2.10.9) silently failed to write on
    every cycle where $trackedTicketIds ended up empty (the common case -
    nothing currently waiting on a client) - "WARNING: could not write
    tracked-tickets cache ... Cannot find path '...tracked-tickets.json.tmp'
    because it does not exist." Root cause, reproduced directly: piping an
    empty array into Select-Object -Unique produces zero pipeline objects,
    so the downstream ConvertTo-Json | Set-Content never actually runs and
    the .tmp file is never created - Move-Item then fails because its
    source doesn't exist. Fixed by calling ConvertTo-Json -InputObject
    explicitly instead of piping, which always passes exactly one array
    (even an empty one) through, reliably emitting "[]".

    Second, superseding v2.10.13 entirely: v2.10.13's halo.agent_id config
    field (a human-entered numeric override for an API-only agent account
    that mcp__Halo__list_agents can never return) was correctly pushed back
    on - it broke this project's own standing design principle that every
    halo.* field is a plain name the pipeline resolves and caches itself,
    never a raw ID a human has to look up and paste in. It also turned out
    config.json's halo.agent_username was never actually wrong - this
    repo's own tracked config.json has said "Artie Fischel" since the
    commit that first added it (confirmed via git log), but config.json was
    deliberately dropped from auto-sync back in v2.10.1 specifically so a
    live server's hand-edited copy is never overwritten by this repo's
    template - the two were simply never the same file, and the live
    account name has been correct all along. What actually changed was the
    account's Halo-side license status, from licensed to API-only, which is
    what broke name-based resolution for the first time.
    id-resolver-prompt.md's agent_id resolution now tries
    mcp__Halo__list_agents first as always, but when agent_username doesn't
    match anything there, it falls back to finding the account's ID from
    its own past ticket actions: mcp__Halo__list_tickets (count 10, most
    recently touched) then mcp__Halo__get_ticket_time_entries on each,
    stopping at the first action entry tagged actionby_application_id:
    "Claude" - written by this same pipeline and nothing else - and reading
    its who_agentid. That same investigation found the API-only account's
    action-log entries show a generic display name ("halointegrator"), not
    agent_username's configured value at all, so the fallback deliberately
    does not require the log's "who" field to match - only
    actionby_application_id is trusted. halo.agent_id was removed from
    config.json and from $currentHaloIdentity (the ID-resolution cache's
    invalidation key) along with this revert. This fallback only works once
    the pipeline has touched at least one ticket under this account, and
    costs up to 10 extra tool calls on the (id_cache_max_age_hours-gated,
    so infrequent) cycles it actually runs - usually far fewer, since this
    pipeline touches tickets every 15 minutes - a deliberate tradeoff of
    some cost for never requiring a human to know a raw Halo ID.
    Version: 2.10.12 - real incident: v2.10.9's new warning line, "TICKET
    $ticketId: WARNING - ...", crashed the script outright on every run
    ("Variable reference is not valid. ':' was not followed by a valid
    variable name character") - PowerShell parses "$name:" inside a
    double-quoted string as an attempted scope/drive reference (the same
    syntax as $env:PATH or $script:var), not as the variable followed by a
    literal colon, whenever nothing that looks like a valid scope name
    follows. Fixed by wrapping it as "${ticketId}:", which disambiguates the
    variable name from the colon.
    This should have been caught before it ever reached a real run - the
    verification this project has relied on (BOM/ASCII byte checks,
    paren/brace/bracket balance counts) cannot catch this class of error at
    all, since brackets stayed balanced and encoding was never the issue.
    From this version on, every .ps1 change gets checked with a real
    PowerShell parser (`[System.Management.Automation.Language.Parser]::ParseFile`)
    before shipping - confirmed available even without a Windows/pwsh
    install on hand by downloading the official PowerShell-for-Linux
    release tarball. This is now the actual verification step; the
    byte-level checks remain useful for the BOM/encoding class of bug they
    were built for, but were never a substitute for real parsing and should
    not be treated as one going forward.
    Version: 2.10.11 - real incident, serious: a ticket sitting unassigned on
    a different Halo team entirely (Alerts / System Admin, not Help Desk)
    was picked up by a cycle, investigated, and escalated - and the
    escalation path's own routine "set the team back to
    help_desk_team_name" bookkeeping then moved that foreign ticket ONTO
    the Help Desk team as a side effect, when it had never belonged there.
    Root cause: the classifier's own "keep only Help Desk team_id" filter is
    a prompt instruction, not something enforced anywhere in code or by the
    resolver - a ticket that slipped past that judgment call had nothing
    else standing between it and a real Halo write. Unlike a wrong-agent
    ticket (which the resolver's "Claim the ticket" section already
    verifies independently) there was no equivalent check for team_id at
    all.
    resolver-prompt.md gained a new section, "Verify this is actually a
    Help Desk ticket," run right after the compliance-exclusion check and
    before claiming - it compares the ticket's own team_id against
    {{TEAM_ID}} (already resolved and injected, just never checked against)
    and stops immediately, untouched, on any mismatch. This is defense in
    depth at the same trust level as the compliance check: the classifier's
    own filter (also hardened with stronger, more explicit wording and the
    real incident as a concrete example) is still the first line, but the
    resolver no longer blindly trusts it. The escalation sections' "set
    team back to help_desk_team_name" bookkeeping is now explicitly
    documented as restating an already-confirmed team, never a mechanism
    for moving a ticket onto Help Desk - the bug was always in that
    bookkeeping running on a ticket that should never have reached it, not
    in the bookkeeping itself.
    Version: 2.10.10 - feature request, with a real gap caught along the way:
    Roger asked whether "effort" could be set per model tier (low for the
    cheap classifier model, medium for Sonnet, maybe high for Opus someday)
    instead of one global value applying to every call. Checking that
    surfaced a real, pre-existing problem: config.json's single "effort"
    value was already being passed to every classifier and
    ID-resolution call, both of which always run on classifier_model
    (claude-haiku-4-5 by default) - and Claude Haiku 4.5 does not support
    the effort parameter at all; sending it is rejected. This had been true
    since "effort" was first added, independent of anything requested here.
    Added optional per-call config overrides - classifier_effort (also
    covers the ID-resolution call, same model), resolver_effort_trivial,
    resolver_effort_medium, resolver_effort_complex - each falling back to
    the original plain "effort" value when absent, so a config with none of
    these new keys behaves byte-for-byte like before. No resolver_effort_
    approved: the APPROVED tier already reuses resolver_model_trivial's
    model, so it reuses resolver_effort_trivial too.
    Fixed the underlying gap properly rather than just adding the feature on
    top of it: $effortCapableModels is an explicit allowlist of models
    confirmed to accept --effort (current Sonnet/Opus tiers only, not
    Haiku), and Invoke-ClaudeCLI itself now checks the model being called
    against that list before ever adding --effort to the arguments -
    enforced once, centrally, for the ID-resolution, classifier, and every
    resolver call, rather than trusting each call site to remember. A
    configured effort value for a Haiku-backed tier is simply never sent,
    not an error - -DryRun's preview shows exactly what would and wouldn't
    be sent, including a note when a configured value is being silently
    skipped for this reason, so this is visible rather than a silent no-op
    discovered only by reading source.
    Version: 2.10.9 - cost regression fix, Roger's own suggestion: v2.10.5's
    "check every unassigned ticket's time entries every cycle" design (built
    to replace agent_id-based cross-cycle tracking once the resolver started
    always unassigning itself) was a real, unnecessary cost increase - a
    real overnight run burned noticeably more than expected. Roger's fix:
    cache which ticket IDs are still worth watching in a local file instead
    of re-deriving that set from a full time-entries scan every cycle.
    tracked-tickets.json (gitignored, next to resolved-ids-cache.json) now
    holds that list. Loaded once per cycle, passed to the classifier as
    {{TRACKED_TICKET_IDS}}, and only THAT small set (not the whole
    Unassigned page) gets a get_ticket/get_ticket_time_entries check -
    genuinely new Unassigned tickets go back to needing zero extra calls,
    exactly like the pre-v2.10.5 design.
    The classifier can now emit a pseudo-tier, "UNTRACK", for a tracked
    ticket that's no longer open or has been claimed by a human - it never
    reaches the resolver, PowerShell just drops that ID from the cache.
    mcp__Halo__get_ticket added to $classifierTools for this (it didn't
    need single-ticket lookups before). The resolver, in turn, must end
    every response with either [CACHE: TRACK] or [CACHE: UNTRACK]
    (resolver-prompt.md's new "When you finish" requirement) - PowerShell
    regexes this out of $resolverResult.Parsed.result and updates the cache
    accordingly; FLOW A's own step 8 was given the same requirement
    explicitly, since FLOW A skips the rest of the document (including "When
    you finish") on purpose. The cache is written once per cycle in a
    `finally` block so every exit path (normal completion, the early
    "no candidates" return, even a thrown error) persists it, and never
    under -WhatIf, matching how every other real-effect write in this
    script is skipped there.
    A missing/corrupt cache file is treated as an empty list, not an error -
    this is a cost optimization, not a correctness mechanism, so losing it
    just means one pricier cycle re-discovering what's still open, never a
    broken one.
    Version: 2.10.8 - policy fix, no incident but a real design flaw:
    resolver-prompt.md's personal/consumer-VPN section told the resolver to
    unconditionally tell "them" to disconnect the VPN, without ever
    confirming the named account owner was actually the one who connected
    it. A Huntress VPN alert only proves an account was used with a
    consumer VPN - not that the account's owner is the one who did it - so
    lecturing the named contact about VPN policy doesn't address the real
    question, and misses the case that actually matters: someone else
    signed in as them.
    The section now confirms identity first: ask the named contact plainly
    whether the sign-in was them, before saying anything about VPN policy
    at all. If they confirm it was them, THEN explain why to stop using a
    personal VPN and offer proper remote access if they need one (unchanged
    from before, just moved after confirmation instead of assumed). If they
    deny it or can't confirm, treat it as a real compromise indicator
    regardless of business hours or tier - notify on-call immediately (same
    mechanism as the emergency section, but not gated on being after hours,
    since a live compromise doesn't wait for a shift change), send a brief
    client acknowledgment, and flag a private note for a human to review
    and decide on password reset/session revocation. Deliberately does NOT
    auto-reset the password or revoke sessions itself - that's a human
    judgment call given what's at stake, not something to automate on a
    "they said no" signal alone.
    Version: 2.10.7 - real incident: a real deployment accumulated a pile of
    loose <file>.bak-<timestamp> files in the main deployment directory,
    one per file per real update cycle that changed something - expected
    given how many real fixes shipped across a single day this session,
    but it defeated the whole point of this being a minimal-files
    deployment (only the files the project actually needs, nothing else -
    see README). Update-HaloResponseAgent.ps1 and
    Copy-McpServersToProject.ps1 (the only two places that ever create a
    .bak file) now write backups into their own backups\ subfolder instead
    of loose next to the real file - same backup behavior, same retention
    (still not auto-cleaned; delete by hand), just out of the way. backups/
    added to .gitignore alongside logs/.
    Version: 2.10.6 - real incident: ticket #21702's approved reply landed
    successfully via mcp__Halo__update_ticket with note_is_private: false,
    but Halo recorded it as a "Private Note"-type action and the client
    never received it - confirmed directly by pulling the ticket's own
    action log, not assumed. note_is_private only flags a note
    internal-only; it isn't what makes Halo actually email the ticket's
    contact. Per config-owner's own domain knowledge running Halo day to
    day, a private note never emails the client by definition, so this was
    a real, silent non-delivery, not a display/labeling quirk.
    Every place in this codebase that sends a real, client-facing reply now
    pairs note_is_private: false with a new send_email: true parameter:
    resolver-prompt.md gained a "Sending a real, client-facing reply"
    section establishing this as the general rule, and FLOW A step 5 (the
    approval-mode send-for-real step) was updated to match. Anything meant
    to stay private (FLOW B's draft note, internal findings notes) is
    unaffected - send_email stays unset/false there.
    UPDATE, same day: the send_email dependency is no longer just an
    assumption - confirmed directly against this tenant's real Outcome list
    (mcp__Halo__list_outcomes) and fixed at the source. update_ticket was
    hardcoding outcome_id: 7 ("Private Note") for every note it created,
    and that outcome has hidesendemail: true in HaloPSA - it can never
    email the client regardless of hiddenfromuser. Outcome 16 ("Email
    User") has hidesendemail: false and sendemail: 1 - it's the one that
    actually emails the ticket's contact. halopsa-mcp's update_ticket now
    accepts send_email: true to use outcome 16 instead of 7, confirmed by
    reading and fixing the real halopsa-mcp source (rafouche/MCPs, commit
    37143c8) directly, not guessed. That fix is committed but not yet
    pushed/deployed to Cloudflare - Roger is handling that push and the
    live deploy from his own session on that repo. Until it's deployed,
    send_email: true is a no-op against the live tool (the parameter isn't
    in the schema Halo's MCP server actually serves yet) - re-confirm
    against the deployed tool schema once he's pushed it, the same way
    every other Halo-tool-schema fact in this project gets confirmed
    directly rather than assumed.
    Version: 2.10.5 - real incident: ticket #21702, run again after v2.10.4,
    worked correctly but ended up assigned to the bot's own agent - and
    since Halo's API-user account doesn't show up in a normal
    licensed-user list, the ticket became effectively invisible in the
    Help Desk ticket list. Root cause: FLOW A step 7 (the approval-mode
    send-for-real step) set agent_id per a "[INTENDED ASSIGNMENT] keep"
    marker for Resolved/Waiting-on-client outcomes, deliberately leaving
    the ticket assigned to the bot so a later cycle's "already mine" check
    could track it for a possible client reply - the same design this
    whole pipeline used for every Resolved/Waiting-on-client ticket, not
    just approval-mode ones, since v1.
    That tracking design is now inverted: the bot always unassigns itself
    (`agent_id: 1`) at the end of every path in resolver-prompt.md
    (Resolved, Waiting on client, Follow Up Needed, before-hours draft,
    emergency), and FLOW A step 7 always unassigns too - the
    "[INTENDED ASSIGNMENT] keep|unassign" marker is removed from the
    draft-note protocol entirely, since there's no longer a "keep" case.
    Cross-cycle tracking of "did the client reply yet" no longer depends on
    staying assigned - it's done by status instead. The classifier's
    existing "Unassigned" call (`agent_id: 1`, page 1) now doubles as the
    re-check pool: a fresh "Distinguish a fresh ticket from a re-check"
    step calls `get_ticket_time_entries` on every candidate in it (bounded
    to that same 15-ticket page) and skips any where the bot's own last
    note is still the most recent entry with no new client-facing activity
    since. The old "Already mine" call (`agent_id: {{AGENT_ID}}`, fully
    paged) is repurposed as a stuck-claimed recovery check - it should
    normally come back empty now, and a hit means a prior cycle's final
    unassign write never landed (a crash, or Halo's own triage-swallow
    bug), which resolver-prompt.md's "Claim the ticket" section now
    handles explicitly as a recovery case rather than assuming it's a
    normal multi-reply continuation.
    Version: 2.10.4 - real incident: ticket #21702, a -RequireApproval-mode
    run against a Huntress escalation for the same verified Mark Pon
    scenario v2.10.2 was built for, still couldn't create/relink the
    contact - it correctly did all the M365 verification work, then hit
    "create_contact is not permitted in this run" and flagged it for a
    human instead, because v2.10.2 had put mcp__Halo__create_contact in
    $remediationMutatingTools, gating it behind approval for non-APPROVED
    tickets same as a password reset or reboot. That was the wrong
    category: fixing which contact a ticket is linked to is fixing the
    ticket's OWN DATA, not a remediation action taken on the client's
    actual problem - the same reasoning that already exempts
    update_ticket's own bookkeeping and the on-call notification from
    -RequireApproval's gating. mcp__Halo__create_contact is removed from
    $remediationMutatingTools (it stays in $mutatingTools, so -WhatIf still
    blocks it - simulation mode must still touch nothing real). The FLOW B
    approval-banner text no longer lists create_contact among the deferred
    remediation actions, and now has an explicit exception (matching the
    existing EMERGENCY-acknowledgment one) telling the model to create/
    relink a verified contact for real, immediately, regardless of
    approval tier.
    Version: 2.10.3 - two minor tuning changes, no incident behind either.
    Default ticket-processing interval raised from 10 to 15 minutes
    (Register-HaloResponseAgentTask.ps1's -IntervalMinutes default), and the
    auto-update check interval raised from 30 to 60 minutes
    (-UpdateCheckIntervalMinutes default) - a new commit only ships a
    handful of times a day at most, so checking hourly is plenty.
    Also narrowed Update-HaloResponseAgent.ps1's $filesToSync: it was
    syncing Install-Prerequisites.ps1, Register-HaloResponseAgentTask.ps1,
    and Copy-McpServersToProject.ps1 alongside the actual running-pipeline
    files, but none of those three are ever invoked by anything scheduled -
    they're one-time setup/registration scripts run once, by hand, as
    Administrator. Syncing them bought nothing (a change to one only
    matters the next time someone deliberately re-runs it, at which point
    re-downloading it the normal way is no extra step) while still costing
    a download/hash-check/potential backup every update cycle. Removed;
    $filesToSync is now just the three prompts, Invoke-HaloResponseAgent.ps1,
    Update-HaloResponseAgent.ps1 itself, and Show-AgentLog.ps1.
    Version: 2.10.2 - real incident: a Huntress ITDR escalation for
    mpon@battlefieldfire.gov came back from the resolver as "NEEDS CONTACT
    VERIFIED" instead of getting fixed automatically, even though the
    resolver had already done every bit of verification work needed - it
    confirmed via M365 that the account was real, active, enabled, and
    non-admin, and confirmed no matching Halo contact existed under the
    right client. It could not act because create_contact was deliberately
    withheld from $resolverTools entirely, on the assumption that any
    automatic contact creation meant fabricating an identity from unverified
    ticket text - contradicting an earlier, explicit request to create the
    user automatically when the ticket body already contains enough
    information to do so safely. The real gap was that "unverified ticket
    text" and "independently confirmed via a live M365/CIPP lookup" were
    being treated as the same risk tier when they aren't.
    resolver-prompt.md's "unknown or wrong contact" section now has three
    tiers instead of two: existing-contact re-linking (unchanged), a new
    verified-identity create-and-link tier (client already known, identity
    confirmed via a real system lookup - not just ticket text, and site
    unambiguous), and the original flag-for-a-human tier for everything
    else. mcp__Halo__create_contact and mcp__Halo__list_sites (needed since
    create_contact requires a site_id) are added to $resolverTools;
    create_contact is added to $mutatingTools (stripped under -WhatIf, same
    as update_ticket) and $remediationMutatingTools (gated behind
    -RequireApproval for non-APPROVED tickets, same tier as a password reset
    or reboot - FLOW B drafts the intended contact creation into the private
    note instead of creating it for real).
    Version: 2.10.1 - real incident: v2.10.0's Update-HaloResponseAgent.ps1
    included config.json in its synced file list, and the very first real
    update cycle silently overwrote a live on_call.primary.email with the
    repo's still-placeholder value ("REPLACE_ME@altecusa.com") - no backup,
    no warning, discovered only when on-call escalation broke. config.json
    is explicitly a per-deployment file (README has every deployment fill
    in on_call/remediation_whitelist by hand) whose real values only ever
    exist on that one server, never in the repo - syncing it is never safe
    regardless of what the repo's own copy contains, and it's removed from
    $filesToSync for good. Every file the script does still sync now gets
    backed up (to <file>.bak-<timestamp>) before being overwritten, so even
    a file that's supposed to stay in sync can't become unrecoverable the
    way config.json just did.
    Version: 2.10.0 - dropped git entirely. v2.9.9's fix was still built on
    a wrong root assumption, stated directly: this deployment has never
    been a git clone - files get onto the server by downloading them
    individually (via a browser), not `git clone`/`git pull`, as stated
    from the very start of this project. Every git-based fix since v2.9.6
    (Register-UpdateCheckTask.ps1, Add-GitToMachinePath.ps1, then
    Install-Prerequisites.ps1's git section, v2.9.9's winget install) was
    solving a problem that didn't need to exist.
    Update-HaloResponseAgent.ps1 now fetches a specific, minimal list of
    files (config.json, the three prompts, and every .ps1 - not
    README.md/CLAUDE.md, which are documentation, not part of the deployed
    program) directly from
    https://raw.githubusercontent.com/rafouche/HelpDeskAgent/main/<file>
    over plain HTTPS, comparing each one's hash against the local copy and
    replacing only what changed - no git, no authentication needed for a
    public repo. Install-Prerequisites.ps1's entire git section is removed;
    nothing in this project needs git installed at all anymore.
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
    [switch]$RequireApproval,
    [int[]]$ReplayTicketIds,
    [string]$ReplayTier = "MEDIUM",
    [string]$ReplayAsOf,
    [string]$ReplayLabel = "replay",
    [switch]$ReplayKeepOwnActions
)

$ErrorActionPreference = "Stop"

# --- Replay (evaluation) mode ---
# -ReplayTicketIds runs the resolver against specific, already-known tickets
# with the tier given by -ReplayTier, skipping the gate/throttle/classifier
# entirely, and writes one JSON result per ticket to eval\results\<label>\
# for Replay-Tickets.ps1 to score. It is always a -WhatIf simulation - every
# mutating tool is stripped and nothing is written back to Halo or to
# agent-cache.json - so the same past tickets can be replayed repeatedly to
# compare prompt/model/pipeline changes on cost and outcome before any of
# them go live. A replay is never scheduled; it only runs when a human
# invokes it (directly, or via Replay-Tickets.ps1).
$isReplay = ($null -ne $ReplayTicketIds -and @($ReplayTicketIds).Count -gt 0)
if ($isReplay) {
    $WhatIf = [switch]$true
    $ReplayTier = $ReplayTier.ToUpperInvariant()
    $validReplayTiers = @('TRIVIAL', 'TRIVIAL_UNCERTAIN', 'MEDIUM', 'COMPLEX', 'APPROVED', 'LEARN_FIX')
    if ($validReplayTiers -notcontains $ReplayTier) {
        throw "-ReplayTier '$ReplayTier' is not a real tier. Use one of: $($validReplayTiers -join ', ')."
    }
    $ReplayLabel = ($ReplayLabel -replace '[^A-Za-z0-9_.-]', '_')
    if (-not $ReplayLabel) { $ReplayLabel = "replay" }
    # v2.11.4: the as-of point also drives the run context's clock (below), so
    # it has to be a real timestamp, not just text the resolver is told about.
    $replayAsOfDate = $null
    if ($ReplayAsOf) {
        try { $replayAsOfDate = [datetime]::Parse($ReplayAsOf, [System.Globalization.CultureInfo]::InvariantCulture) }
        catch { throw "-ReplayAsOf '$ReplayAsOf' is not a timestamp. Use ISO form, e.g. 2026-09-17T12:30:00 (Halo time)." }
    }
}

# Windows PowerShell 5.1 captures external-process output using the console's
# legacy OEM/ANSI codepage by default, not UTF-8 - claude's own output is UTF-8
# (em dashes, curly quotes, emoji in its replies), so without this the captured
# text and the log file it's written to end up permanently mangled (e.g. an em
# dash becomes "GCo"). Setting both encodings to UTF-8 before invoking claude
# fixes this for the whole session.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$configPath           = Join-Path $RootPath "config.json"
$agentCachePath       = Join-Path $RootPath "agent-cache.json"
$legacyIdCachePath    = Join-Path $RootPath "resolved-ids-cache.json"
$legacyTrackedPath    = Join-Path $RootPath "tracked-tickets.json"
$idResolverPromptPath = Join-Path $RootPath "id-resolver-prompt.md"
$classifierPromptPath = Join-Path $RootPath "classifier-prompt.md"
$resolverPromptPath   = Join-Path $RootPath "resolver-prompt.md"
$logDir               = Join-Path $RootPath "logs"

$logFileNameTemplate = "run-{0:yyyy-MM-dd}.log"
if ($WhatIf) {
    $logFileNameTemplate = "whatif-{0:yyyy-MM-dd}.log"
}
if ($isReplay) {
    $logFileNameTemplate = "replay-{0:yyyy-MM-dd}.log"
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

# --- Load the unified local cache: resolved Halo IDs, the tracked-ticket
#     list (ticket IDs the resolver is already waiting on a client reply
#     for), per-ticket "last seen" state (the pre-flight gate below uses
#     this to notice when a tracked ticket actually changed), and the
#     timestamp of the last cycle that ran a real check (the off-hours
#     throttle below uses this). v2.10.18 consolidated what used to be two
#     separate files (resolved-ids-cache.json, tracked-tickets.json) into
#     this one, migrating their content on first run rather than discarding
#     it - Roger asked for one cache file instead of several scattered ones.
#     A missing or corrupt file just means starting fresh on every part of
#     it - every one of these is a cost optimization, never a correctness
#     requirement, so losing all of it costs at most one pricier cycle,
#     never a broken one. -WhatIf still reads it for an accurate simulation;
#     only the write-back later is skipped so nothing real persists.
$agentCache = $null
if (Test-Path $agentCachePath) {
    try {
        $agentCache = Get-Content $agentCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $earlyTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "[$earlyTimestamp] WARNING: could not read $agentCachePath ($($_.Exception.Message)) - starting this cycle with a fresh cache." -Encoding UTF8
        $agentCache = $null
    }
}
elseif ((Test-Path $legacyIdCachePath) -or (Test-Path $legacyTrackedPath)) {
    $migratedIds = $null
    if (Test-Path $legacyIdCachePath) {
        try { $migratedIds = Get-Content $legacyIdCachePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $migratedIds = $null }
    }
    $migratedTracked = @()
    if (Test-Path $legacyTrackedPath) {
        try { $migratedTracked = @(Get-Content $legacyTrackedPath -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { [int]$_ }) } catch { $migratedTracked = @() }
    }
    $agentCache = [PSCustomObject]@{
        resolved_ids         = $migratedIds
        tracked_tickets      = $migratedTracked
        tracked_last_seen    = [PSCustomObject]@{}
        unassigned_last_seen = [PSCustomObject]@{}
        blocked_tickets      = [PSCustomObject]@{}
        human_owned_tickets  = [PSCustomObject]@{}
        remembered_notes     = @()
        last_real_cycle_at   = $null
    }
    foreach ($legacyPath in @($legacyIdCachePath, $legacyTrackedPath, "$legacyIdCachePath.tmp", "$legacyTrackedPath.tmp")) {
        if (Test-Path $legacyPath) { Remove-Item -Path $legacyPath -Force -ErrorAction SilentlyContinue }
    }
    $earlyTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$earlyTimestamp] Migrated resolved-ids-cache.json/tracked-tickets.json into agent-cache.json and removed the old files." -Encoding UTF8
}
if (-not $agentCache) {
    $agentCache = [PSCustomObject]@{
        resolved_ids         = $null
        tracked_tickets      = @()
        tracked_last_seen    = [PSCustomObject]@{}
        unassigned_last_seen = [PSCustomObject]@{}
        blocked_tickets      = [PSCustomObject]@{}
        human_owned_tickets  = [PSCustomObject]@{}
        remembered_notes     = @()
        last_real_cycle_at   = $null
    }
}

$trackedTicketIds = @()
if ($agentCache.tracked_tickets) { $trackedTicketIds = @($agentCache.tracked_tickets | ForEach-Object { [int]$_ }) }

# PSCustomObject -> Hashtable so per-ticket lookups/updates below (the
# pre-flight gate) are plain key access instead of PSObject.Properties
# gymnastics every time.
$trackedLastSeen = @{}
if ($agentCache.tracked_last_seen) {
    foreach ($prop in $agentCache.tracked_last_seen.PSObject.Properties) { $trackedLastSeen[$prop.Name] = $prop.Value }
}

# v2.13.2: per-ticket "evaluated through" watermark (UTC ISO text) - written
# whenever the resolver looks at a ticket and keeps tracking it. Entries at
# or before this time have been looked at; only newer ones are a change.
$trackedEvaluated = @{}
if ($agentCache.PSObject.Properties['tracked_evaluated'] -and $agentCache.tracked_evaluated) {
    foreach ($prop in $agentCache.tracked_evaluated.PSObject.Properties) { $trackedEvaluated[$prop.Name] = [string]$prop.Value }
}

# Same pattern, for the unassigned-bucket fingerprint the gate check uses
# below - absent entirely on a cache file from before this existed, which
# just means "nothing seen yet," not an error.
$unassignedLastSeen = @{}
if ($agentCache.unassigned_last_seen) {
    foreach ($prop in $agentCache.unassigned_last_seen.PSObject.Properties) { $unassignedLastSeen[$prop.Name] = $prop.Value }
}

# Real incident (v2.10.30): a ticket stuck in one of Halo's own structural
# dead ends - a genuine agent-permissions gap, or a write that's still not
# confirmable even after halopsa-mcp's own built-in verify retries (see
# resolver-prompt.md's "A write can report success and not be immediately
# readable back" section) - got fully reprocessed by the resolver every
# single cycle, each time correctly re-discovering "I can't act on this, a
# human needs to fix something in Halo first" and stopping, at real cost
# (confirmed live: one ticket cost over a dollar across three consecutive
# cycles in about ten minutes, with no sign it would ever stop on its
# own). [CACHE: TRACK] doesn't help here because the underlying
# problem is that NO write ever lands - not even the tracking note itself -
# so a future cycle's tracked-ticket recheck sees no evidence anything was
# ever tried and treats it as a brand-new candidate again, forever.
# [CACHE: BLOCKED] (see resolver-prompt.md's "When you finish" section) is
# the fix: a resolver that hits one of these dead ends says so with that
# marker instead, and this ticket ID goes in blocked_tickets (ticket_id ->
# when it was last found blocked) instead of tracked_tickets. Blocked
# tickets are excluded from the classifier's Unassigned candidate list
# (see {{BLOCKED_TICKET_IDS}} below) until claude.blocked_ticket_retry_hours
# has passed, at which point the entry simply ages out here and the ticket
# becomes a completely normal candidate again next cycle - on the
# (hopeful) assumption a human fixed whatever was actually broken in Halo
# by then. No new classifier logic needed for the retry itself: aging out
# is just "stop excluding it," not a special recheck path.
$blockedTicketRetryHours = 4
if ($config.claude.blocked_ticket_retry_hours) { $blockedTicketRetryHours = [double]$config.claude.blocked_ticket_retry_hours }
$blockedTickets = @{}
if ($agentCache.blocked_tickets) {
    foreach ($prop in $agentCache.blocked_tickets.PSObject.Properties) {
        [datetime]$blockedAt = 0
        if ([datetime]::TryParse($prop.Value, [ref]$blockedAt)) {
            if (((Get-Date) - $blockedAt).TotalHours -lt $blockedTicketRetryHours) {
                $blockedTickets[$prop.Name] = $prop.Value
            }
        }
    }
}

# v2.10.60: same cost shape as blocked_tickets above, different cause. Real
# incident, confirmed directly from a full day's production log Roger sent
# after noticing the day was already near $20 by early afternoon: tickets
# #22114 and #22067 were each reprocessed 6 times in one day, at MEDIUM/
# COMPLEX (Sonnet) tier every time, and every single pass reached the exact
# same conclusion - a real human agent (Roger) had already acted on the
# ticket, so the resolver correctly claimed and did nothing. The classifier's
# own "New"/"In Progress"/"Updated" statuses are deliberately never excluded
# by name (see classifier-prompt.md - real Help Desk work legitimately sits
# in all three), and Roger's own habit of manually resetting a ticket's
# status back to "New" while working it by hand - which also clears
# agent_id back to 1 as a side effect, already documented elsewhere in this
# file - means neither the status-id check nor the status-name judgment call
# can ever catch this case; only the actual action log (human_touch) can.
# The resolver was already discovering that correctly every time (emitting
# [CACHE: UNTRACK], per resolver-prompt.md's own documented case for "someone
# else's ticket") - the gap was that UNTRACK only ever prunes tracked_tickets,
# which these tickets were never in to begin with (they're freshly
# rediscovered as Unassigned candidates each cycle, not through the tracked-
# ticket recheck path at all), so nothing about that conclusion carried
# forward to the next cycle's classifier call. Same fix shape as
# blocked_tickets: a human-confirmed-elsewhere ticket now gets its own
# [CACHE: HUMAN_OWNED] marker (resolver-prompt.md's "Is this ticket actually
# available to you?" checks 1/2, "When you finish" section) and goes in
# human_owned_tickets (ticket_id -> when last confirmed) instead of silently
# costing a full resolver call to re-derive the same answer every 15-30
# minutes. Given a human working a ticket by hand is in no hurry to hand it
# back to this pipeline, and ready_for_ai_status_name already exists as the
# correct, immediate way to signal "actually, take this one" regardless of
# this cache, defaulted the retry window considerably longer than
# blocked_ticket_retry_hours's 4h (that one exists to recover from a
# transient platform bug ASAP; this one exists to stop re-asking a question
# whose answer isn't expected to change soon).
$humanOwnedRetryHours = 24
if ($config.claude.human_owned_retry_hours) { $humanOwnedRetryHours = [double]$config.claude.human_owned_retry_hours }
$humanOwnedTickets = @{}
if ($agentCache.human_owned_tickets) {
    foreach ($prop in $agentCache.human_owned_tickets.PSObject.Properties) {
        [datetime]$humanOwnedAt = 0
        if ([datetime]::TryParse($prop.Value, [ref]$humanOwnedAt)) {
            if (((Get-Date) - $humanOwnedAt).TotalHours -lt $humanOwnedRetryHours) {
                $humanOwnedTickets[$prop.Name] = $prop.Value
            }
        }
    }
}

# Requested feature: when a human explicitly asks Allie to remember something
# ("remember this," "we'll remember that") for future tickets, resolver-prompt.md's
# "Remembering something for future tickets" section captures it via a
# `[CACHE: REMEMBER] <text>` line. This is durable institutional knowledge, not a
# transient per-ticket cache entry like tracked/blocked_tickets above - it's never
# pruned by age, only capped by count (max_remembered_notes, oldest dropped first)
# so it doesn't grow the resolver prompt's size (and therefore every future call's
# cost) without bound. Injected into resolver-prompt.md only, not
# classifier-prompt.md - the classifier's only job is finding/tiering candidates,
# never drafting replies, so this context would cost tokens on every single
# candidate-finding call without ever actually being used for anything.
$maxRememberedNotes = 50
if ($config.claude.max_remembered_notes) { $maxRememberedNotes = [int]$config.claude.max_remembered_notes }
$rememberedNotes = @()
if ($agentCache.remembered_notes) {
    $rememberedNotes = @($agentCache.remembered_notes | Select-Object -Last $maxRememberedNotes)
}

# Carried through untouched unless Stage 0 below actually re-resolves fresh
# IDs - initialized here (not just inside the try block) so an early
# failure before Stage 0 finishes still persists the cache's existing value
# instead of the finally block silently wiping it back to null.
$resolvedIdsForCache = $agentCache.resolved_ids

# --- Determine business-hours context ---
$now = Get-Date
# v2.11.4: in a replay with an as-of point, the resolver's "current date/time"
# and business-hours flag come from that point, not from the wall clock - the
# first baseline ran on a Saturday afternoon, so four of ten tickets that
# arrived on weekdays were judged "outside business hours" and took the
# hold-a-draft path, while one reasoned from the ticket's own timestamp
# instead. Neither is the behavior being scored. $now itself stays the real
# clock (log timestamps, the off-hours throttle - which never applies under
# -WhatIf anyway).
$contextNow = $now
if ($isReplay -and $replayAsOfDate) { $contextNow = $replayAsOfDate }
$isBusinessDay = $config.business_hours.days -contains $contextNow.DayOfWeek.ToString()
$startTod = [TimeSpan]::Parse($config.business_hours.start)
$endTod   = [TimeSpan]::Parse($config.business_hours.end)
$isBusinessHours = $isBusinessDay -and ($contextNow.TimeOfDay -ge $startTod) -and ($contextNow.TimeOfDay -le $endTod)
$nowText = $contextNow.ToString("dddd, MMMM d, yyyy h:mm tt")
# v2.13.2: Halo action datetimes are UTC without a suffix; this is the
# "evaluated through" watermark written for every ticket the resolver looks
# at this cycle (see tracked_evaluated above).
$cycleStartUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss")

# --- Off-hours throttle: outside business hours, skip most cycles entirely
#     rather than paying for a real check every 15 minutes overnight/on
#     weekends when the vast majority find nothing. Real incident: two
#     overnight log files showed cost concentrated in cycles that found
#     zero tickets, dozens of times a night - business hours only account
#     for roughly a third of a day's scheduled cycles, so most of that
#     waste was happening outside them. A genuine emergency is still caught
#     within this interval (the resolver's own emergency handling doesn't
#     depend on cadence, just on a cycle running at all) - a bounded delay
#     outside business hours, not a design regression. Never throttles
#     -WhatIf/-DryRun - a human asked for those on purpose and should always
#     see the real thing, not a skip.
$offHoursIntervalMinutes = 60
if ($config.business_hours.off_hours_check_interval_minutes) { $offHoursIntervalMinutes = $config.business_hours.off_hours_check_interval_minutes }
if (-not $isBusinessHours -and -not $WhatIf -and -not $DryRun -and $agentCache.last_real_cycle_at) {
    $minutesSinceLastRealCycle = ((Get-Date) - [datetime]$agentCache.last_real_cycle_at).TotalMinutes
    if ($minutesSinceLastRealCycle -lt $offHoursIntervalMinutes) {
        $throttleTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Add-Content -Path $logFile -Value "[$throttleTimestamp] SKIPPED (off-hours throttle) - last real check $([math]::Round($minutesSinceLastRealCycle,1))m ago, threshold ${offHoursIntervalMinutes}m." -Encoding UTF8
        return
    }
}

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
# mcp__Halo__get_ticket added for the tracked-tickets check (v2.10.9,
# classifier-prompt.md's "Find candidate tickets" call 3) - the classifier
# needs it to cheaply check each tracked ticket's current status/open-state
# before deciding whether to keep watching it or emit UNTRACK for it.
$classifierTools = @(
    "Read", "ToolSearch",
    "mcp__Halo__list_tickets", "mcp__Halo__get_ticket_time_entries", "mcp__Halo__get_ticket"
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
    # delete_ticket_note: structurally narrow (see its own tool description) -
    # can only remove a private note that starts with the literal
    # "[DRAFT PENDING APPROVAL]" marker on the exact ticket given, never a
    # human's note or a real client-facing reply. Added per Roger's request
    # to delete a superseded draft when a revised one replaces it, instead of
    # leaving the old one behind - see resolver-prompt.md's "If a human left
    # a note on your own pending draft" section and this script's own FLOW B.
    "mcp__Halo__delete_ticket_note",
    # mark_draft_approved (v2.10.59): same safety scoping as
    # delete_ticket_note right above, but edits the sent draft note down to
    # a short "[APPROVED DRAFT]" marker in place instead of deleting it -
    # Roger wanted a visible trace that a draft existed and was approved,
    # without the full reply text sitting twice in the ticket's history
    # (it's already in the real sent reply). Used by FLOW A step 6 below in
    # place of delete_ticket_note now.
    "mcp__Halo__mark_draft_approved",
    # get_client/list_clients/get_contact/list_contacts: a real run showed the
    # resolver denied on get_client while investigating which company a ticket
    # belonged to - never added despite being the same kind of read-only
    # name-to-ID lookup already granted for teams/statuses/agents.
    "mcp__Halo__get_client", "mcp__Halo__list_clients", "mcp__Halo__get_contact", "mcp__Halo__list_contacts",
    # list_sites/create_contact: a real ticket (a Huntress alert for a real,
    # M365-verified user with zero matching Halo contacts) showed the
    # resolver correctly doing all the verification work, then having no way
    # to act on it - create_contact was deliberately withheld at first (see
    # resolver-prompt.md's "unknown or wrong" section) on the assumption
    # that creating a contact always meant fabricating an identity from
    # unverified ticket text, but an M365-confirmed real/active/enabled
    # account is independent verification, not a guess. list_sites is
    # needed alongside it since create_contact requires a site_id, not just
    # a client_id.
    "mcp__Halo__list_sites", "mcp__Halo__create_contact",
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
    # escalate_emergency (v2.13.0): the one-call emergency path - a FIXED,
    # templated acknowledgment to the client plus an on-call page whose
    # recipients are Worker settings, not arguments. Deliberately NOT stripped
    # under -RequireApproval (see $resolverToolsApprovalStripped): Roger's
    # decision, 2026-09-20, after ticket #22385 (a site-wide phone outage on a
    # Saturday sat as an unsent draft because approval mode had removed every
    # tool that could send). Still stripped under -WhatIf like every write.
    "mcp__Halo__escalate_emergency",
    # send_approved_draft (v2.13.1): FLOW A's send + collapse + cleanup +
    # status in one atomic call. It can only send text already sitting in a
    # human-approved draft note, and refuses unless the ticket is in the
    # approved status - so it is APPROVED-tier only (stripped for every other
    # tier under -RequireApproval, see $resolverToolsApprovalStripped) and
    # stripped under -WhatIf like every write.
    "mcp__Halo__send_approved_draft",

    # --- M365 / CIPP identity: read + the two whitelisted remediation actions ---
    # Server registered here as "CIPP" (cipp-mcp.young-math-a33a.workers.dev) -
    # this is the custom CIPP Worker, using CIPP's own documented APIs, and it's
    # the real, permanent, intentionally-chosen tool (CORRECTED v2.10.55 - Roger
    # confirmed CIPP-ng's built-in MCP was tried and abandoned; there is no
    # cutover in progress or planned). See README's "CIPP MCP" section.
    "mcp__CIPP__get_user", "mcp__CIPP__healthcheck", "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    # Real incident, found the same day as v2.10.52's UniFi/Meraki/Peplink
    # correction, this time from directly cross-checking every mcp__CIPP__*
    # name resolver-prompt.md actually instructs calling against this array,
    # not from a live ticket hitting a denial: mcp__CIPP__list_message_trace
    # and mcp__CIPP__list_mailboxes are both referenced as load-bearing in
    # resolver-prompt.md's "Email delivery / bounce issues" section - the
    # SAME section that documents ticket #21900 as the real incident that
    # justified building list_message_trace as a dedicated tool in the first
    # place (v2.10.37/.38 .NOTES history) - but neither tool was ever added
    # here. The comment this replaced still described the OLD generic
    # cipp_api_get passthrough as the mechanism, stale ever since the
    # dedicated tool was built to replace exactly that guessed-params
    # approach. Net effect: the documented, incident-justified fix has been
    # unable to actually run - every real "email not arriving" ticket since
    # then had both calls silently denied under --permission-mode dontAsk,
    # the same failure shape #21900 was supposed to have already fixed.
    # cipp_api_get kept as a generic fallback for anything without its own
    # dedicated tool - not otherwise referenced by name in resolver-prompt.md.
    "mcp__CIPP__list_message_trace", "mcp__CIPP__list_mailboxes", "mcp__CIPP__cipp_api_get",
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
    # get_device_custom_fields (v2.10.57): real incident, ticket #22114 - a
    # client asked whether her laptop was under warranty, and get_device's
    # plain hardware/system block has no warranty/purchase-date field at
    # all. NinjaOne tracks that kind of asset data in a device's custom
    # fields instead (the same fields update_device's userData parameter
    # already writes to) - added the matching read tool so warranty-type
    # questions can actually be answered from what Altec already has,
    # instead of asking the client or telling them to check the
    # manufacturer's site themselves.
    "mcp__Ninja__get_device", "mcp__Ninja__get_device_custom_fields", "mcp__Ninja__get_device_os_info", "mcp__Ninja__get_device_software",
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
    # run_script_and_wait (v2.10.62): same remediation-whitelist gating as
    # run_script_on_device - it queues and runs the exact same way, just
    # also polls for a result. Needed for the new "Speedtest (JSON)"
    # NinjaOne script (troubleshooting a client's "internet is slow"
    # complaint) - run_script_on_device alone can't be used for this, since
    # it never returns the script's actual output (fire-and-forget), and
    # there'd be nothing to tell the client without reading the result back
    # in the same pass, per Roger's own request ("run the script and wait
    # for the output"). See resolver-prompt.md's network-speed-testing
    # section for when to use this over the plain fire-and-forget tool.
    "mcp__Ninja__run_script_and_wait",

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
    # v2.11.3 - the VLAN/subnet diagnosis resolver-prompt.md has required since
    # v2.10.69 (compare the ticket's own reported IP against the client's VLAN
    # layout) names mcp__Meraki__list_vlans explicitly - and it was never in
    # this list. Found by the first replay baseline: ticket #22300 reached the
    # right answer anyway via list_network_clients, but logged 4 permission
    # denials on get_vlan/list_switch_ports/get_switch_port trying to confirm
    # it. Same failure shape as the CIPP list_message_trace gap (v2.10.52
    # history above): a tool the prompt is written around, silently denied.
    # All read-only; none belong in $mutatingTools.
    "mcp__Meraki__list_vlans", "mcp__Meraki__get_vlan",
    "mcp__Meraki__list_switch_ports", "mcp__Meraki__get_switch_port",
    "mcp__Meraki__get_device",
    # run_throughput_test (v2.10.62): the first Meraki tool that actively DOES
    # something rather than just reading - runs a live WAN throughput test on
    # an MX appliance (Meraki's own Live Tools API), for firewall-level
    # network-slowness troubleshooting alongside the new NinjaOne workstation
    # speed test. Gated the same way as every other action this pipeline can
    # take on a client's live system (remediation whitelist + $mutatingTools/
    # $remediationMutatingTools below), even though it's transient/read-only
    # in effect (no lasting config change) - it does consume real bandwidth on
    # the client's live connection for ~10s, the same category of "touches a
    # client's live system" every other gated tool is gated for, not a passive
    # GET. UniFi/Peplink don't have an equivalent tool yet - Roger asked for
    # them to be wired up too, but neither vendor's current API could be
    # confirmed to actually support triggering a speed test (UniFi: the only
    # command found is the legacy classic-controller API, not the modern
    # Network Integration API this Worker actually proxies through; Peplink:
    # InControl2's docs show no such endpoint at all, and it looks like a
    # still-outstanding feature request on Peplink's own community forum) -
    # not wired up rather than guessed at.
    "mcp__Meraki__run_throughput_test",

    # Real incident: Peplink (InControl2) was registered as an MCP server on this
    # machine the whole time but never added to any tool allowlist here, and
    # resolver-prompt.md never mentioned it either - a real gap found by Roger
    # reading the Capabilities Brief and noticing it wasn't listed alongside
    # UniFi/Meraki, not by a ticket actually hitting a denial (unlike every
    # other entry in this Network section). Every Peplink tool is a GET/LIST -
    # no mutating tool exists at all, same as UniFi - so the full set is
    # included. Peplink's own hierarchy is org -> group -> device (unlike
    # UniFi/Meraki's flatter site/network model), so get_device/
    # get_device_wan_status need org_id and group_id resolved first via
    # list_organizations -> list_groups, not just a device_id alone.
    # CORRECTED same day (v2.10.52): UniFi/Meraki/Peplink are three
    # independent, competing vendor ecosystems, not three layers of one stack
    # (an original v2.10.51 framing was wrong - see resolver-prompt.md's own
    # network section and CLAUDE.md for the real-data correction, confirmed
    # via Thompson Sales existing as a real org/site/group in all three
    # simultaneously).
    "mcp__Peplink__list_organizations", "mcp__Peplink__list_groups", "mcp__Peplink__list_devices",
    "mcp__Peplink__get_device", "mcp__Peplink__get_device_wan_status", "mcp__Peplink__healthcheck",

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
    # asset_layout_index_tool/asset_layout_show_tool (v2.10.55): read-only, resolve
    # a real Asset Layout's current numeric ID by name (Firewalls/Switches/Wireless)
    # and its field schema (the exact `manufacturer` list_items spelling, which
    # differs slightly per layout) - see resolver-prompt.md's network-stack-caching
    # section for why this replaced the v2.10.54 custom-KB-article design.
    "mcp__HUDU__asset_layout_index_tool", "mcp__HUDU__asset_layout_show_tool",
    # --- Documentation, write. article_create_tool/article_edit_tool only ever
    #     write to the "AI-Documented Fixes" folder from config.json (never edit
    #     client-facing docs), so they don't need a remediation_whitelist entry -
    #     they never touch a client's live systems. Deliberately absent from
    #     $mutatingTools below, unlike every other tool in this file that changes
    #     something: a -WhatIf run keeps these two live so testing runs build real,
    #     reusable KB content instead of just describing what they would have
    #     written - see resolver-prompt.md's "Documenting a fix that worked"
    #     section for how a simulation-sourced article gets labeled so it's never
    #     mistaken for a confirmed fix.
    #     asset_create_tool/asset_edit_tool (v2.10.55) are different: they write
    #     to a client's REAL Firewalls/Switches/Wireless asset records, the same
    #     documentation the whole team relies on - not an isolated internal-only
    #     folder - so unlike the article tools above, these two ARE in
    #     $mutatingTools below and get simulated under -WhatIf like everything
    #     else that touches real client-facing state. ---
    "mcp__HUDU__article_create_tool", "mcp__HUDU__article_edit_tool",
    "mcp__HUDU__asset_create_tool", "mcp__HUDU__asset_edit_tool"
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
    "mcp__Halo__update_ticket", "mcp__Halo__update_ticket_draft_only", "mcp__Halo__create_contact",
    "mcp__Halo__escalate_emergency", "mcp__Halo__send_approved_draft",
    "mcp__Microsoft365__outlook_send_mail",
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device",
    # v2.10.62: same reasoning as run_script_on_device/reboot_device above -
    # both actively touch a client's live system (runs code on a device /
    # pulls real bandwidth on a live WAN link for ~10s), so both get
    # simulated under -WhatIf like everything else in this list.
    "mcp__Ninja__run_script_and_wait", "mcp__Meraki__run_throughput_test",
    # v2.10.55: writes to a client's real Hudu asset records (Firewalls/Switches/
    # Wireless), not the isolated "AI-Documented Fixes" folder - see the note where
    # $resolverTools declares these two for why they're treated differently from
    # article_create_tool/article_edit_tool, which stay live under -WhatIf.
    "mcp__HUDU__asset_create_tool", "mcp__HUDU__asset_edit_tool"
)

# Subset of $mutatingTools that -RequireApproval strips from a non-APPROVED-tier
# ticket (see the per-ticket tool selection below). mcp__Microsoft365__outlook_send_mail
# is deliberately absent - the on-call notification it sends is an internal
# alert to Altec's own team, not client correspondence, so it's never gated.
# What CAN be enforced at the allowlist level - and is - is that a
# non-APPROVED-tier ticket physically cannot call a remediation action,
# regardless of what the prompt says.
# mcp__Halo__create_contact is deliberately NOT in this list, even though it's
# in $mutatingTools above (so -WhatIf still blocks it) - a real -RequireApproval
# run (ticket #21702, a Huntress escalation for a verified Mark Pon) showed the
# resolver correctly do all the verification work, then refuse to create/relink
# the contact because the tool had been stripped, flagging it for a human
# instead. That's the wrong outcome: creating/relinking a contact once identity
# is independently verified (resolver-prompt.md's "unknown or wrong contact"
# section) is fixing the TICKET'S OWN DATA - who it's linked to - not a
# remediation action taken on the client's actual problem. It's the same
# category as update_ticket's own bookkeeping and the on-call notification
# below: real work that should happen immediately regardless of approval tier,
# with only the client-facing reply/remediation itself held back for sign-off.
$remediationMutatingTools = @(
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device",
    # v2.10.62: both new speed-test diagnostics are remediation-whitelist
    # entries (config.json), so both get stripped from a non-APPROVED
    # ticket's allowlist the same way run_script_on_device already is -
    # see the $resolverTools/$mutatingTools comments for why, even for a
    # transient/non-destructive action like this.
    "mcp__Ninja__run_script_and_wait", "mcp__Meraki__run_throughput_test"
)

# Base allowlist plus one pre-filtered variant for -RequireApproval, computed
# once here - the per-ticket loop below picks which one a given ticket actually
# gets, since -RequireApproval's filtering depends on that ticket's own tier
# (APPROVED vs. everything else), not a single cycle-wide switch. -WhatIf's own
# filtering (by $mutatingTools, a superset of $remediationMutatingTools) is
# applied inline in that same loop instead of precomputed here, since it always
# applies uniformly regardless of tier - no per-ticket variant needed for it.
#
# REAL INCIDENT (v2.10.31): $resolverToolsApprovalStripped used to just remove
# $remediationMutatingTools and leave mcp__Halo__update_ticket in place,
# because the old halopsa-mcp had no tool that could write a note without
# being able to also send it publicly - so whether a non-APPROVED ticket's
# reply actually stayed private depended entirely on the resolver choosing to
# follow resolver-prompt.md's approval-banner instructions over other,
# more concrete "reply now" instructions written elsewhere in the same
# document. It didn't always: several real tickets got a genuine, emailed
# client-facing reply despite -RequireApproval being active, most often on
# TRIVIAL/TRIVIAL_UNCERTAIN tickets (the cheapest model, the shortest-effort
# tier). halopsa-mcp now has mcp__Halo__update_ticket_draft_only - same
# shape, but a note can only ever land private and unemailed, structurally,
# regardless of what's passed (see its tool description) - so a non-APPROVED
# ticket gets THAT in place of mcp__Halo__update_ticket entirely: even a
# resolver that tries to send a real reply anyway physically cannot, it can
# only get a rejected tool call and (per resolver-prompt.md's reinforcement
# near FLOW B) notice its real update_ticket tool isn't available and use
# the draft-only one instead.
$resolverToolsFull = $resolverTools
$resolverToolsApprovalStripped = @($resolverToolsFull | Where-Object { ($remediationMutatingTools -notcontains $_) -and ($_ -ne "mcp__Halo__update_ticket") -and ($_ -ne "mcp__Halo__send_approved_draft") }) + @("mcp__Halo__update_ticket_draft_only")

# LEARN_FIX (see resolver-prompt.md's "If the assigned tier is LEARN_FIX"
# section) never claims, assigns, replies to, or mutates the ticket at all -
# it's a read-the-notes-and-maybe-write-a-Hudu-article pass on a ticket
# that's already closed. A fixed, minimal allowlist rather than reusing
# $resolverToolsFull/stripped variants: smaller tool-schema overhead every
# call, and no mcp__Halo__update_ticket present at all means there's
# nothing here for -RequireApproval/-WhatIf's mutating-tool filtering to
# even need to consider for this tier.
$resolverToolsLearnFix = @(
    "mcp__Halo__get_ticket", "mcp__Halo__get_ticket_time_entries",
    "mcp__HUDU__article_folder_index_tool", "mcp__HUDU__article_index_tool", "mcp__HUDU__article_show_tool",
    "mcp__HUDU__article_create_tool", "mcp__HUDU__article_edit_tool"
)
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

# Replay-mode banner (see -ReplayTicketIds above). Sits above the simulation
# banner, since a replay is a simulation with one extra rule: the ticket is
# to be judged as a fresh first pass, exactly as it stood when the pipeline
# first saw it, not as it stands today after this pipeline's own later notes
# and drafts landed on it.
$replayAsOfText = if ($ReplayAsOf) { $ReplayAsOf } else { "(not given - use the ticket's first client message as the reference point)" }
$replayBannerLines = @(
    "=== EVALUATION REPLAY ($ReplayLabel) ===",
    "This run is a replay of a past ticket, used to score this pipeline's own",
    "behavior - it is a simulation (see the simulation banner below), and nothing",
    "you do here reaches Halo, a device, or a client.",
    $(if ($ReplayKeepOwnActions) {
        "Judge the ticket as it stood at: $replayAsOfText"
    } else {
        "Judge the ticket as a fresh, first-pass candidate as it stood at: $replayAsOfText"
    }),
    "- Ignore every action dated after that point.",
    $(if ($replayAsOfDate) {
        "- When you call mcp__Halo__get_ticket_time_entries or mcp__Halo__get_ticket_history," + "`n" +
        "  pass as_of: `"$($replayAsOfDate.ToString('yyyy-MM-ddTHH:mm:ss'))`" - the response then contains only" + "`n" +
        "  the actions up to that point and its human_touch is computed over them," + "`n" +
        "  which makes it the authoritative ownership answer for this replay. A" + "`n" +
        "  human_touch from any call made WITHOUT as_of (or from get_ticket_brief /" + "`n" +
        "  the candidate feed) is computed over today's full history and must not" + "`n" +
        "  drive the ownership check here. (Real replay: two untouched-at-the-time" + "`n" +
        "  tickets stopped HUMAN_OWNED on today's human_touch.found.)"
    } else {
        "- When you call mcp__Halo__get_ticket_time_entries or mcp__Halo__get_ticket_history," + "`n" +
        "  pass as_of set to the first client message's datetime (read it from the" + "`n" +
        "  ticket's dateoccurred or the first action) - the response then contains only" + "`n" +
        "  the actions up to that point and its human_touch is computed over them," + "`n" +
        "  which makes it the authoritative ownership answer for this replay. A" + "`n" +
        "  human_touch from any call made WITHOUT as_of (or from get_ticket_brief /" + "`n" +
        "  the candidate feed) is computed over today's full history and must not" + "`n" +
        "  drive the ownership check here."
    }),
    $(if ($ReplayKeepOwnActions) {
        "- This pipeline's own earlier actions (who is its own agent account or" + "`n" +
        "  actionby_application_id is `"Claude`", including a `"[DRAFT PENDING APPROVAL]`"" + "`n" +
        "  note) dated at or before the as-of point ARE part of the state being" + "`n" +
        "  judged - a pending draft of yours plus a later human note is the draft-" + "`n" +
        "  revision case, handle it exactly as the approval-mode flow says. Only" + "`n" +
        "  those dated after the as-of point are ignored."
    } else {
        "- Ignore every action authored by this pipeline itself, whenever it was" + "`n" +
        "  written: notes/replies where who is this pipeline's own agent account or" + "`n" +
        "  actionby_application_id is `"Claude`", and any note containing" + "`n" +
        "  `"[DRAFT PENDING APPROVAL]`" or `"[APPROVED DRAFT]`". They do not exist for" + "`n" +
        "  the purposes of this replay - do not treat them as prior art, as a pending" + "`n" +
        "  draft to revise, or as evidence the ticket was already handled."
    }),
    "- A real human agent's actions before the as-of point still count exactly as",
    "  they normally would (the ownership check applies as usual).",
    "- The ticket's CURRENT agent_id, status, and closed/resolved flags describe",
    "  today, not the as-of point - do not apply the ownership check to them.",
    "  Reconstruct ownership from the action log alone: if no real human action",
    "  is dated at or before the as-of point, treat the ticket as unassigned and",
    "  in its original status at that time, however it is assigned or closed now.",
    "  (Real replay: two tickets a human picked up days later were skipped as",
    "  HUMAN_OWNED without any investigation, which is exactly wrong here.)",
    $(if ($replayAsOfDate) {
        "- The run context's current date/time and business-hours flag are already set" + "`n" +
        "  to the as-of point - use them as given, not today's real clock."
    } else {
        "- Judge business hours from the first client message's own timestamp (the" + "`n" +
        "  config's business_hours days/start/end), not from the run context's clock," + "`n" +
        "  which is today's."
    }),
    "Then investigate and decide exactly as the rest of this document says, and",
    "describe what you WOULD do per the simulation banner. Be specific about every",
    "fact you established and every tool you used to establish it - the replay is",
    "scored on whether the right facts were found, not just on the final wording.",
    "- Write out, verbatim and in full, the text of every note, draft, and reply",
    "  you would write or send - greeting, body, and sign-off exactly as the",
    "  client or technician would read it. The replay is scored on those words.",
    "  A description of a reply ('a reassuring note telling her it's safe')",
    "  scores as no reply at all. (Real replay: a correct diagnosis of #22231",
    "  failed for exactly this.)",
    "==="
)
$replayBanner = $replayBannerLines -join "`n"

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
    # LEARN_FIX: a tracked ticket got closed by a real human, not this
    # pipeline - read what they actually did and document it in Hudu if
    # it's worth remembering. A read-and-summarize task, not a fresh
    # investigation, so it gets the cheap model like TRIVIAL/APPROVED do
    # regardless of how complex the original ticket was.
    "LEARN_FIX"         = $config.claude.resolver_model_trivial
}

# --- Effort selection per tier - optional per-tier overrides, each falling back
#     to config.claude.effort (the original single global setting) if blank or
#     absent. A config with none of these new keys behaves exactly as before -
#     every tier just gets $config.claude.effort, same as every call did prior
#     to this. classifier_effort covers both the classifier and Stage 0's ID
#     resolution call, since both always run on classifier_model.
function Get-EffortForConfig {
    param([string]$PerTierValue)
    if ($PerTierValue) { return $PerTierValue }
    return $config.claude.effort
}

# -DryRun display helper: shows what will actually be sent, not just what's
# configured - a configured effort value the model doesn't support (see
# $effortCapableModels below) is silently never sent by Invoke-ClaudeCLI, so
# this makes that visible in the preview instead of only discoverable by
# comparing config.json against the model-support list by hand.
function Format-EffortDisplay {
    param([string]$Effort, [string]$Model)
    if (-not $Effort) { return "(account default)" }
    if ($effortCapableModels -contains $Model) { return $Effort }
    return "$Effort (NOT sent - $Model doesn't support --effort)"
}

# Finds halopsa-mcp's own base URL from .mcp.json (the same file that already
# holds this MCP server's real registration - see README's "Register each
# MCP server" section) rather than hardcoding it a second place that could
# drift out of sync. Used only by the pre-flight gate below, which calls the
# Worker's /helpdesk-gate route directly over plain HTTP (no Claude CLI, no
# LLM call) - returns $null on any problem (missing .mcp.json, no "Halo"
# entry, malformed URL) so the caller can fail open and just run the
# classifier normally instead of guessing.
function Get-HelpDeskGateBaseUrl {
    param([string]$RootPath)
    $mcpJsonPath = Join-Path $RootPath ".mcp.json"
    if (-not (Test-Path $mcpJsonPath)) { return $null }
    try {
        $mcpConfig = Get-Content $mcpJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $mcpConfig.mcpServers) { return $null }
        $haloEntry = $null
        foreach ($prop in $mcpConfig.mcpServers.PSObject.Properties) {
            if ($prop.Name -eq "Halo") { $haloEntry = $prop.Value; break }
        }
        if (-not $haloEntry -or -not $haloEntry.url) { return $null }
        $uri = [Uri]$haloEntry.url
        return $uri.GetLeftPart([UriPartial]::Authority)
    }
    catch {
        return $null
    }
}

# The Authorization header the Halo MCP registration in .mcp.json already
# sends on every MCP call (`claude mcp add ... --header "Authorization:
# Bearer <token>"` - see README). The Worker's plain-HTTP routes this script
# calls directly (/helpdesk-gate, /helpdesk-candidates) enforce that same
# bearer token once the Worker's MCP_AUTH_TOKEN secret is set, so send it
# here too. $null when .mcp.json has no such header - the call then goes
# out without one, which still works against a Worker whose secret isn't
# set yet, and fails open (classifier runs normally) against one that is.
function Get-HelpDeskGateAuthHeader {
    param([string]$RootPath)
    $mcpJsonPath = Join-Path $RootPath ".mcp.json"
    if (-not (Test-Path $mcpJsonPath)) { return $null }
    try {
        $mcpConfig = Get-Content $mcpJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $mcpConfig.mcpServers) { return $null }
        foreach ($prop in $mcpConfig.mcpServers.PSObject.Properties) {
            if ($prop.Name -ne "Halo") { continue }
            $headers = $prop.Value.headers
            if (-not $headers) { return $null }
            foreach ($h in $headers.PSObject.Properties) {
                if ($h.Name -eq "Authorization" -and $h.Value) { return [string]$h.Value }
            }
        }
        return $null
    }
    catch {
        return $null
    }
}
$classifierEffort = Get-EffortForConfig -PerTierValue $config.claude.classifier_effort
$effortForTier = @{
    "TRIVIAL"           = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "TRIVIAL_UNCERTAIN" = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "MEDIUM"            = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_medium
    "COMPLEX"           = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_complex
    "APPROVED"          = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "LEARN_FIX"         = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
}

# --- Pipeline feature flags (config.json "pipeline" block, all default OFF) ---
# Each flag gates one under-the-hood change from the cost/speed program so it
# can ship in the code (which production auto-downloads within minutes) while
# staying inert until a human turns it on in this deployment's own config.json
# - which is never synced from the repo, so flipping one on or off here is
# the whole rollout/rollback, with no git timing to worry about. A missing
# "pipeline" block, or a missing key, always means OFF.
$pipelineFlags = @{
    deterministic_classifier = $false   # increment 2: PowerShell + Worker gather candidates; one no-tool tiering call
    classifier_shadow        = $false   # increment 2 rollout aid: run the deterministic path alongside the LLM classifier and log the diff, use the LLM's answer
    prefetch_ticket          = $false   # increment 3: ticket brief/history/contact/device injected into the resolver prompt
    playbooks                = $false   # increment 4: lean core prompt + per-topic playbooks selected per ticket
    client_cards             = $false   # increment 5: per-client context cards (network stack, VLANs, servers) injected per ticket
}
if ($config.PSObject.Properties.Name -contains 'pipeline' -and $config.pipeline) {
    foreach ($flagName in @($pipelineFlags.Keys)) {
        $flagValue = $config.pipeline.PSObject.Properties[$flagName]
        if ($flagValue -and $flagValue.Value -eq $true) { $pipelineFlags[$flagName] = $true }
    }
}

# Models confirmed to accept an effort parameter at all - Claude Haiku 4.5
# (classifier_model/resolver_model_trivial's default) does NOT support it and
# errors if sent one; only current Sonnet/Opus-tier models do. This list is
# deliberately an allowlist, not a denylist: an unrecognized/future model
# never gets --effort until it's confirmed and added here, rather than risking
# the same error a denylist could miss. Invoke-ClaudeCLI enforces this - every
# call site above just passes whatever effort it wants and the model it's
# using; it's Invoke-ClaudeCLI's job to decide whether that combination is
# actually safe to send.
$effortCapableModels = @(
    "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
    "claude-sonnet-5", "claude-sonnet-4-6"
)

# --- Deterministic classifier (cost program, increment 2; v2.12.0) ---
# What the LLM classifier does in 10-25 tool-calling turns at ~40% of every
# cycle's spend, done as: one plain HTTP GET to halopsa-mcp's
# /helpdesk-triage (calls 1-6 of classifier-prompt.md as Halo REST calls),
# the mechanical exclusions applied here in PowerShell against the same
# caches the LLM was being handed as text, and - only if any candidate
# survives - ONE no-tool tiering call whose entire input is the tiering
# rules (read live from classifier-prompt.md, so the two stay one text) plus
# a trimmed brief per candidate. Nothing to tier means no LLM call at all.
# Any failure throws; the caller falls back to the LLM classifier for that
# cycle and logs why. Never touches Halo - read-only by construction.
$deterministicSkipStatusNamesDefault = @(
    "Dispatch Needed", "Scheduled", "Waiting on vendor", "Quote*", "Scoped for review",
    "Awaiting Deployment", "With CAB", "On Hold", "Awaiting Approval", "Approved"
)
$deterministicClosedStatusNames = @("Resolved", "Closed", "Completed", "Closed Order", "Closed Item")

function Test-DeterministicSkipStatus {
    param([string]$StatusName, [string[]]$SkipNames)
    if (-not $StatusName) { return $false }
    foreach ($pattern in $SkipNames) {
        if (-not $pattern) { continue }
        if ($pattern.EndsWith('*')) {
            if ($StatusName.StartsWith($pattern.TrimEnd('*'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        elseif ([string]::Equals($StatusName, $pattern, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Invoke-DeterministicClassifier {
    param(
        [string]$RootPath,
        $Ids,
        [string[]]$TrackedTicketIds,
        [hashtable]$BlockedTickets,
        [hashtable]$HumanOwnedTickets,
        [bool]$ApprovalMode,
        [string[]]$SkipStatusNames,
        [string]$ClassifierPromptPath,
        [string]$Model,
        [string]$Effort,
        [string]$NowText,
        [string]$Timezone,
        [string]$PipelineAppId = "Claude",
        # Integrations that post through a bound Halo agent account look human
        # (who_type 1) but aren't: Huntress's alert intake, seen live on
        # #22389/#22390. Same list halopsa-mcp's human_touch now ignores.
        [string[]]$IntegrationAppIds = @("Huntress", "Acronis Client Portal"),
    [hashtable]$EvaluatedAt = @{}
    )
    $report = @()
    $baseUrl = Get-HelpDeskGateBaseUrl -RootPath $RootPath
    if (-not $baseUrl) { throw "no Halo Worker URL in .mcp.json (Get-HelpDeskGateBaseUrl returned nothing)" }
    $headers = @{}
    $auth = Get-HelpDeskGateAuthHeader -RootPath $RootPath
    if ($auth) { $headers['Authorization'] = $auth }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # --- IDs and name maps, as plain lookups ---
    $teamId = [int]$Ids.team_id
    $agentId = [int]$Ids.agent_id
    $waitingStatusId = [string]$Ids.waiting_status_id
    $followupStatusId = [string]$Ids.followup_status_id
    $readyStatusId = ""
    if ($Ids.ready_for_ai_status_id -and ([string]$Ids.ready_for_ai_status_id) -match '^\d+$') { $readyStatusId = [string]$Ids.ready_for_ai_status_id }
    $waitingApprovalStatusId = ""
    $approvedStatusId = ""
    if ($ApprovalMode) {
        if ($Ids.ai_waiting_approval_status_id -and ([string]$Ids.ai_waiting_approval_status_id) -match '^\d+$') { $waitingApprovalStatusId = [string]$Ids.ai_waiting_approval_status_id }
        if ($Ids.ai_approved_status_id -and ([string]$Ids.ai_approved_status_id) -match '^\d+$') { $approvedStatusId = [string]$Ids.ai_approved_status_id }
    }
    $excludedClientIds = @()
    if ($Ids.excluded_client_ids) { $excludedClientIds = @($Ids.excluded_client_ids | ForEach-Object { [string]$_ }) }
    $statusNames = @{}
    if ($Ids.status_id_names) { foreach ($prop in $Ids.status_id_names.PSObject.Properties) { $statusNames[[string]$prop.Name] = [string]$prop.Value } }
    $ticketTypeNames = @{}
    if ($Ids.ticket_type_names) { foreach ($prop in $Ids.ticket_type_names.PSObject.Properties) { $ticketTypeNames[[string]$prop.Name] = [string]$prop.Value } }
    $trackedSet = @{}
    foreach ($t in @($TrackedTicketIds)) { if ($t) { $trackedSet[[string]$t] = $true } }
    if ($null -eq $BlockedTickets) { $BlockedTickets = @{} }
    if ($null -eq $HumanOwnedTickets) { $HumanOwnedTickets = @{} }

    # --- 1 HTTP call: every bucket, trimmed, with recent actions ---
    $query = "team_id=$teamId&agent_id=$agentId&history=6&max_details_chars=1500&max_note_chars=600"
    if ($trackedSet.Count -gt 0) { $query += "&tracked_ids=$(@($trackedSet.Keys) -join ',')" }
    if ($readyStatusId) { $query += "&ready_status_id=$readyStatusId" }
    if ($waitingApprovalStatusId) { $query += "&waiting_approval_status_id=$waitingApprovalStatusId" }
    if ($approvedStatusId) { $query += "&approved_status_id=$approvedStatusId" }
    $triageStart = Get-Date
    $triage = Invoke-RestMethod -Uri "$baseUrl/helpdesk-triage?$query" -Method Get -TimeoutSec 90 -Headers $headers
    if ($triage.error) { throw "helpdesk-triage returned an error: $($triage.error)" }
    $bucketCount = { param($b) if ($b) { [string]$b.record_count } else { "n/a" } }
    $report += "triage fetched in $([math]::Round(((Get-Date) - $triageStart).TotalSeconds, 1))s: unassigned=$(& $bucketCount $triage.unassigned) stuck_claimed=$(& $bucketCount $triage.stuck_claimed) ready_for_ai=$(& $bucketCount $triage.ready_for_ai) waiting_approval=$(& $bucketCount $triage.waiting_approval) approved=$(& $bucketCount $triage.approved) tracked=$(@($triage.tracked.requested).Count)"
    if ($triage.unassigned -and $triage.unassigned.truncated) { $report += "NOTE: unassigned bucket truncated at the Worker's page cap (record_count=$($triage.unassigned.record_count))" }

    # --- helpers over trimmed actions (newest first) ---
    $bookkeepingOutcomes = @('Re-Assign', 'Change Status', 'SLA Hold', 'SLA Release', 'Change Priority', 'Rule Applied', 'Emailed Confirmation', 'AI Triage', 'User Changed', 'Triage', 'Ticket In Progress Email')
    # v2.13.3: an integration app posting through our own agent account
    # (Halo's Acronis integration is bound to Allie, agent 17) is neither
    # ours nor human - the who_agentid match must exclude those apps.
    $isOurs = { param($a) ($a.actionby_application_id -eq $PipelineAppId) -or (([string]$a.who_agentid -eq [string]$agentId) -and ($IntegrationAppIds -notcontains [string]$a.actionby_application_id)) }
    $isHuman = { param($a) ([int]$a.who_type -eq 1) -and -not (& $isOurs $a) -and ($IntegrationAppIds -notcontains [string]$a.actionby_application_id) }
    $isSubstantive = {
        param($a)
        # v2.13.2: System/Automation entries (Halo rules, HaloAI triage,
        # automation emails) are never news - real incident: a "Ticket In
        # Progress Email" entry re-queued three tickets every cycle for a day.
        if ($null -ne $a.who_type -and [int]$a.who_type -eq 0) { return $false }
        if ($bookkeepingOutcomes -notcontains [string]$a.outcome) { return $true }
        $n = [string]$a.note
        if (-not $n) { return $false }
        if ($n -match '^(Status changed|Priority changed|From: .*; To: |Matched |AI Suggestions)') { return $false }
        return $true
    }
    $statusNameOf = { param($t) $key = [string]$t.status_id; if ($statusNames.ContainsKey($key)) { $statusNames[$key] } else { "" } }
    # v2.13.2: Halo action datetimes are UTC wall-clock. Windows PowerShell
    # 5.1 hands them over as ISO strings; PowerShell 7 (the test harness)
    # converts them to DateTime objects. Normalize both to UTC before
    # comparing against the "evaluated through" watermark (UTC ISO text).
    $asUtc = {
        param($v)
        if ($null -eq $v -or [string]$v -eq "") { return $null }
        if ($v -is [DateTime]) {
            if ($v.Kind -eq [DateTimeKind]::Local) { return $v.ToUniversalTime() }
            return [DateTime]::SpecifyKind($v, [DateTimeKind]::Utc)
        }
        try { return [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)) } catch { return $null }
    }
    $alreadyEvaluated = {
        param([string]$id, $entry)
        if (-not $EvaluatedAt.ContainsKey($id)) { return $false }
        $mark = & $asUtc $EvaluatedAt[$id]; $when = & $asUtc $entry.datetime
        if ($null -eq $mark -or $null -eq $when) { return $false }
        return ($when -le $mark)
    }

    $candidates = New-Object System.Collections.ArrayList
    $seen = @{}
    $dropped = New-Object System.Collections.ArrayList
    $add = {
        param([int]$id, $tier, [string]$source)
        if ($seen.ContainsKey([string]$id)) { return }
        $seen[[string]$id] = $true
        [void]$candidates.Add([PSCustomObject]@{ ticket_id = $id; tier = $tier; source = $source })
    }
    $drop = { param([int]$id, [string]$reason) [void]$dropped.Add("$id`: $reason") }

    # --- Call 1: unassigned ---
    foreach ($entry in @($triage.unassigned.tickets)) {
        $t = $entry.ticket; $id = [int]$t.id; $key = [string]$id
        $statusName = & $statusNameOf $t
        if ($excludedClientIds -contains [string]$t.client_id) { & $drop $id "compliance exclusion (client_id $($t.client_id))"; continue }
        if ([int]$t.team_id -ne $teamId) { & $drop $id "team_id $($t.team_id) is not Help Desk ($teamId)"; continue }
        if ($trackedSet.ContainsKey($key)) { continue }   # call 3 owns it
        if ($BlockedTickets.ContainsKey($key)) { & $drop $id "blocked list"; continue }
        if ($HumanOwnedTickets.ContainsKey($key)) { & $drop $id "human-owned list"; continue }
        if ($readyStatusId -and [string]$t.status_id -eq $readyStatusId) { continue }   # call 4 owns it, unconditionally
        if ([string]$t.status_id -eq $waitingStatusId) { & $drop $id "status $($t.status_id) '$statusName' = waiting_on_client and not tracked - not this pipeline's"; continue }
        if ([string]$t.status_id -eq $followupStatusId) { & $drop $id "status $($t.status_id) '$statusName' = follow_up (escalated)"; continue }
        if ($Ids.ai_waiting_approval_status_id -and [string]$t.status_id -eq [string]$Ids.ai_waiting_approval_status_id) {
            if ($waitingApprovalStatusId) { continue }   # call 5 decides
            & $drop $id "status '$statusName' = ai_waiting_approval, approval mode off this run"; continue
        }
        if ($Ids.ai_approved_status_id -and [string]$t.status_id -eq [string]$Ids.ai_approved_status_id) {
            if ($approvedStatusId) { continue }   # call 6 decides
            & $drop $id "status '$statusName' = ai_approved, approval mode off this run"; continue
        }
        if (Test-DeterministicSkipStatus -StatusName $statusName -SkipNames $SkipStatusNames) { & $drop $id "status '$statusName' names an active workflow this pipeline can't act on"; continue }
        $latest = $null
        if (@($entry.recent_actions).Count -gt 0) { $latest = @($entry.recent_actions)[0] }
        if ($latest -and (& $isHuman $latest) -and ($latest.hiddenfromuser -eq $false)) { & $drop $id "latest action is a colleague's client-facing entry ($($latest.who), $($latest.datetime))"; continue }
        & $add $id $null "unassigned"
    }

    # --- Call 2: stuck-claimed - always a look, never a silent drop ---
    foreach ($entry in @($triage.stuck_claimed.tickets)) {
        $t = $entry.ticket; $id = [int]$t.id
        if ($excludedClientIds -contains [string]$t.client_id) { & $drop $id "compliance exclusion (client_id $($t.client_id))"; continue }
        & $add $id $null "stuck_claimed"
    }

    # --- Call 3: tracked ---
    foreach ($m in @($triage.tracked.missing)) { & $add ([int]$m.id) "UNTRACK" "tracked (not found: $($m.error))" }
    foreach ($entry in @($triage.tracked.tickets)) {
        $t = $entry.ticket; $id = [int]$t.id
        $statusName = & $statusNameOf $t
        if ($excludedClientIds -contains [string]$t.client_id) { & $add $id "UNTRACK" "tracked (compliance exclusion)"; continue }
        $closed = ($null -ne $t.dateclosed) -or ($t.hasbeenclosed -eq $true) -or ($deterministicClosedStatusNames -contains $statusName)
        if ($closed) { & $add $id "LEARN_FIX" "tracked (closed: '$statusName' $($t.dateclosed))"; continue }
        $onApprovalStatus = ($Ids.ai_waiting_approval_status_id -and [string]$t.status_id -eq [string]$Ids.ai_waiting_approval_status_id) -or ($Ids.ai_approved_status_id -and [string]$t.status_id -eq [string]$Ids.ai_approved_status_id)
        if ([int]$t.agent_id -ne 1 -and [int]$t.agent_id -ne $agentId -and -not $onApprovalStatus) { & $add $id "UNTRACK" "tracked (now assigned to agent $($t.agent_id) $($t.agent_name))"; continue }
        $lastSubstantive = $null
        foreach ($a in @($entry.recent_actions)) { if (& $isSubstantive $a) { $lastSubstantive = $a; break } }
        if ($lastSubstantive -and (& $isOurs $lastSubstantive)) { & $drop $id "tracked, unchanged (latest substantive entry is ours, $($lastSubstantive.datetime))"; continue }
        if (-not $lastSubstantive) { & $drop $id "tracked, unchanged (no substantive entry in the recent window)"; continue }
        if (& $alreadyEvaluated ([string]$id) $lastSubstantive) { & $drop $id "tracked, unchanged since last evaluated ($($EvaluatedAt[[string]$id])Z; newest entry $($lastSubstantive.who) $($lastSubstantive.datetime))"; continue }
        & $add $id $null "tracked (new entry by $($lastSubstantive.who), $($lastSubstantive.datetime))"
    }

    # --- Call 4: Ready for AI - unconditional ---
    if ($triage.ready_for_ai) {
        foreach ($entry in @($triage.ready_for_ai.tickets)) {
            $t = $entry.ticket; $id = [int]$t.id
            if ($excludedClientIds -contains [string]$t.client_id) { & $drop $id "compliance exclusion (client_id $($t.client_id))"; continue }
            & $add $id $null "ready_for_ai"
        }
    }

    # --- Calls 5-6: approval mode ---
    if ($triage.waiting_approval) {
        foreach ($entry in @($triage.waiting_approval.tickets)) {
            $t = $entry.ticket; $id = [int]$t.id
            if ($excludedClientIds -contains [string]$t.client_id) { & $drop $id "compliance exclusion (client_id $($t.client_id))"; continue }
            $humanSinceOurs = $null
            foreach ($a in @($entry.recent_actions)) {
                if (& $isOurs $a) { break }
                if ((& $isHuman $a) -and (& $isSubstantive $a)) { $humanSinceOurs = $a; break }
            }
            if ($humanSinceOurs -and (& $alreadyEvaluated ([string]$id) $humanSinceOurs)) { & $drop $id "waiting_approval, human entry already evaluated ($($humanSinceOurs.who) $($humanSinceOurs.datetime) <= $($EvaluatedAt[[string]$id])Z)"; continue }
            if ($humanSinceOurs) { & $add $id $null "waiting_approval (human $($humanSinceOurs.who) $($humanSinceOurs.outcome) at $($humanSinceOurs.datetime))" }
            else { & $drop $id "waiting_approval, untouched since our draft" }
        }
    }
    if ($triage.approved) {
        foreach ($entry in @($triage.approved.tickets)) {
            $t = $entry.ticket; $id = [int]$t.id
            if ($excludedClientIds -contains [string]$t.client_id) { & $drop $id "compliance exclusion (client_id $($t.client_id))"; continue }
            & $add $id "APPROVED" "approved"
        }
    }

    $report += "dropped ($($dropped.Count)):"
    foreach ($d in $dropped) { $report += "  $d" }
    $report += "candidates ($($candidates.Count)):"
    foreach ($c in $candidates) { $report += "  $($c.ticket_id) $(if ($c.tier) { $c.tier } else { '(to tier)' }) - $($c.source)" }

    # --- One tiering call, only if something needs a tier ---
    $toTier = @($candidates | Where-Object { $null -eq $_.tier })
    $cost = 0
    if ($toTier.Count -gt 0) {
        $briefs = @()
        $idList = @($toTier | ForEach-Object { $_.ticket_id })
        for ($i = 0; $i -lt $idList.Count; $i += 40) {
            $chunk = @($idList[$i..([Math]::Min($i + 39, $idList.Count - 1))])
            $cand = Invoke-RestMethod -Uri "$baseUrl/helpdesk-candidates?ids=$($chunk -join ',')&history=3&max_details_chars=2500&max_note_chars=600" -Method Get -TimeoutSec 90 -Headers $headers
            if ($cand.error) { throw "helpdesk-candidates returned an error: $($cand.error)" }
            foreach ($c in @($cand.candidates)) {
                if (-not $c.found) { continue }
                $tk = $c.ticket
                $briefs += [ordered]@{
                    ticket_id = $tk.id
                    summary = $tk.summary
                    details = $tk.details
                    ticket_type = $(if ($ticketTypeNames.ContainsKey([string]$tk.tickettype_id)) { $ticketTypeNames[[string]$tk.tickettype_id] } else { [string]$tk.tickettype_id })
                    status = $(if ($statusNames.ContainsKey([string]$tk.status_id)) { $statusNames[[string]$tk.status_id] } else { [string]$tk.status_id })
                    impact = $tk.impact
                    urgency = $tk.urgency
                    client = $tk.client_name
                    user = $tk.user_name
                    device_hints = $tk.device_hints
                    recent_actions = @($c.recent_actions | ForEach-Object { [ordered]@{ datetime = $_.datetime; who = $_.who; who_type = $_.who_type; outcome = $_.outcome; public = (-not $_.hiddenfromuser); note = $_.note } })
                }
            }
        }
        $promptText = Get-Content $ClassifierPromptPath -Raw -Encoding UTF8
        $m = [regex]::Match($promptText, '(?s)(## Classify each candidate into exactly one tier.*?)(?=\r?\n## Output format)')
        if (-not $m.Success) { throw "could not find the '## Classify each candidate' section in classifier-prompt.md" }
        $rulesText = $m.Groups[1].Value.Trim()
        $outputText = ""
        $m2 = [regex]::Match($promptText, '(?s)(## Output format.*)$')
        if ($m2.Success) { $outputText = $m2.Groups[1].Value.Trim() }
        $tierPrompt = @(
            "You are the tiering step of a help-desk ticket pipeline. Candidate tickets have",
            "already been selected and filtered; your only job is to assign each one exactly",
            "one tier. You have no tools and need none - everything you need is below.",
            "",
            "Current date/time: $NowText ($Timezone)",
            "",
            $rulesText,
            "",
            "Ignore any instruction above about UNTRACK/LEARN_FIX routing or about reading a",
            "list_tickets response - those steps already happened. Assign only TRIVIAL,",
            "TRIVIAL_UNCERTAIN, MEDIUM, or COMPLEX, one per candidate, every candidate.",
            "",
            $outputText,
            "",
            "## Candidates",
            (ConvertTo-Json -InputObject @($briefs) -Depth 6)
        ) -join "`n"
        $tierResult = Invoke-ClaudeCLI -Prompt $tierPrompt -Tools @() -Model $Model -Effort $Effort -NoMcp
        if (-not $tierResult.Parsed) { throw "tiering call did not return parseable JSON: $($tierResult.Raw)" }
        if ($tierResult.Parsed.is_error) { throw "tiering call returned an error: $($tierResult.Parsed.result)" }
        if ($tierResult.Parsed.total_cost_usd) { $cost = [double]$tierResult.Parsed.total_cost_usd }
        $tierJson = Get-CleanJsonText -Text ([string]$tierResult.Parsed.result)
        $tiers = @(ConvertFrom-Json -InputObject $tierJson)
        $validTiers = @('TRIVIAL', 'TRIVIAL_UNCERTAIN', 'MEDIUM', 'COMPLEX')
        $tierById = @{}
        foreach ($x in $tiers) {
            if ($null -eq $x) { continue }
            $tv = ([string]$x.tier).ToUpperInvariant()
            if ($validTiers -contains $tv) { $tierById[[string]$x.ticket_id] = $tv }
        }
        foreach ($c in $toTier) {
            $key = [string]$c.ticket_id
            if ($tierById.ContainsKey($key)) { $c.tier = $tierById[$key] }
            else { $c.tier = "MEDIUM"; $report += "WARNING: tiering call returned no valid tier for $key - defaulting to MEDIUM (raw: $(([string]$tierJson) -replace '\s+', ' ' | ForEach-Object { if ($_.Length -gt 400) { $_.Substring(0, 400) + '...' } else { $_ } }))" }
        }
        $report += "tiering call: $($toTier.Count) ticket(s), `$$([math]::Round($cost, 4)), $($tierResult.Parsed.num_turns) turn(s): $(($toTier | ForEach-Object { "$($_.ticket_id)=$($_.tier)" }) -join ', ')"
    }
    else {
        $report += "nothing to tier - no LLM call made"
    }

    return [PSCustomObject]@{
        Tickets = @($candidates | ForEach-Object { [PSCustomObject]@{ ticket_id = $_.ticket_id; tier = $_.tier } })
        Cost    = $cost
        Report  = ($report -join "`n")
    }
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
        [string]$Effort,
        # v2.12.0: a call that needs no tools at all (the deterministic
        # classifier's one tiering call) must not pay to load every MCP
        # server's tool schema into its context - that schema block is most
        # of the ~90K-token fixed prefix every other call carries. With
        # -NoMcp the CLI is pointed at an empty MCP config and told to use
        # only that (--strict-mcp-config), so .mcp.json is never read.
        [switch]$NoMcp
    )
    $toolsArg = ($Tools -join ",")
    # Real incident: a TRIVIAL-tier ticket (#21880, Haiku, cheapest tier)
    # cost $0.64 - three to eight times a typical TRIVIAL ticket's $0.08-0.23
    # - and its own subagent_stats showed 7 spawned/completed subagents,
    # while separate PowerShell tool-call attempts in the same run were
    # correctly denied (present in permission_denials). --allowedTools is an
    # inclusion list built only from named MCP tools ($resolverTools/
    # $classifierTools/$resolverToolsLearnFix/etc. above) - none of them
    # spawn subagents - but Claude Code's built-in subagent-launching tool
    # (Task/Agent) isn't confirmed to be gated by that same allowlist the
    # way a named MCP tool or Bash/PowerShell is, matching this observed
    # behavior (denied vs. spawned in the same run). This pipeline's MCP
    # tool sets are already curated to be sufficient for every tier - it
    # should never need to delegate its own investigation to a subagent,
    # and every subagent spawned is a second, separate Claude invocation
    # with its own full cost. Belt-and-suspenders: explicitly disallow the
    # tool by both its current and former name, and disable the
    # environment-level fallback Claude Code documents for headless runs
    # (see the try/finally below) in case --disallowedTools alone isn't
    # sufficient either.
    # An empty tool list (the deterministic classifier's tiering call, v2.12.0)
    # omits --allowedTools entirely rather than passing an empty value; under
    # --permission-mode dontAsk nothing is allowed anyway.
    $claudeArgs = @("-p")
    if ($toolsArg) { $claudeArgs += @("--allowedTools", $toolsArg) }
    $claudeArgs += @(
        # Bash/PowerShell (v2.10.58): same belt-and-suspenders reasoning as
        # Agent/Task above - Claude Code registers its built-in Bash tool
        # (renamed "PowerShell" in permission_denials on this Windows host)
        # regardless of --allowedTools, so the model can see it and attempt
        # it even though it was never granted; --permission-mode dontAsk then
        # auto-denies the call, but only after a wasted turn. Real incidents,
        # confirmed directly from two full days of Roger's own production
        # logs (2026-09-12/13): at least 4 separate resolver/classifier calls
        # tried a PowerShell probe first - sometimes recovering after one
        # denial, twice fully spiraling into a no-op turn per the v2.10.39/40
        # history above - despite resolver-prompt.md/classifier-prompt.md
        # already stating explicitly, since before those versions, "you have
        # no Bash, no PowerShell" in their very first paragraphs. Two rounds
        # of stronger prompt wording (v2.10.39, v2.10.40) did not stop it, so
        # per this same file's own v2.10.34 precedent for Agent/Task, this is
        # now enforced structurally instead of re-worded again: explicitly
        # disallowing the tool by both names removes it from what Claude Code
        # even registers for the call, the same fix that took subagent_stats
        # to a confirmed 0 for Agent/Task in every ticket across both of
        # those same two days' logs.
        "--disallowedTools", "Agent,Task,Bash,PowerShell",
        "--output-format", "json",
        "--permission-mode", "dontAsk"
    )
    if ($Model)  { $claudeArgs += @("--model", $Model) }
    # --effort is only sent when the model being called is confirmed to accept
    # it - Claude Haiku 4.5 (the classifier's and TRIVIAL/APPROVED tiers'
    # default model) does NOT support it and errors if sent one. A real config
    # applied a single global effort value to every call regardless of model
    # before this check existed, silently sending --effort to every
    # classifier and TRIVIAL/APPROVED resolver call. $effortCapableModels
    # (defined above, near $modelForTier) is the allowlist this checks
    # against.
    if ($Effort -and $effortCapableModels -contains $Model) {
        $claudeArgs += @("--effort", $Effort)
    }
    if ($NoMcp) {
        $tempDir = [System.IO.Path]::GetTempPath()
        $emptyMcpPath = Join-Path $tempDir "halo-response-agent-no-mcp.json"
        if (-not (Test-Path $emptyMcpPath)) {
            Set-Content -Path $emptyMcpPath -Value '{"mcpServers":{}}' -Encoding ASCII
        }
        $claudeArgs += @("--strict-mcp-config", "--mcp-config", $emptyMcpPath)
    }

    # The prompt goes in over stdin, not as a "-p <text>" argument. Both prompt
    # files are full of literal embedded double quotes (example client replies,
    # quoted phrases like a "how do I..." question) - a real run showed the
    # classifier receiving its own instructions truncated at exactly one of
    # these, which is PowerShell mangling an embedded quote while re-quoting
    # the argument list for the external claude process, not a file/encoding
    # problem (already ruled out: BOM, hash, and length all verified intact
    # on disk). Stdin has no argument-parsing step, so this is no longer a
    # hazard no matter how many quotes a prompt contains.
    #
    # $PSNativeCommandUseErrorActionPreference must be off around this specific
    # call. With the script's global $ErrorActionPreference = "Stop" (above),
    # PowerShell 7.3+'s default of $true promotes every stderr LINE from a
    # native command into a terminating exception once merged via 2>&1 - even
    # a soft, self-recovering CLI warning the claude process itself logged and
    # continued past (real incident: "Unknown --effort value 'mediumx' -
    # ignoring it and using the default effort", from a bad live config.json
    # value - the CLI printed that, then finished normally, but this line
    # threw before $rawOutput was ever assigned, so Invoke-ClaudeCLI never
    # returned, the ticket was never actually worked, and the catch block at
    # the call site logged the warning text as if the whole call had failed -
    # $0 cost, zero action taken, every single cycle, for as long as that
    # tier's effort value stayed invalid). Scoped to just this call so it
    # doesn't mask real preference-driven behavior anywhere else in the
    # script.
    $prevNativeErrorPref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    $prevDisableBuiltinAgents = $env:CLAUDE_CODE_DISABLE_BUILTIN_AGENTS
    $env:CLAUDE_CODE_DISABLE_BUILTIN_AGENTS = "1"
    try {
        $rawOutput = $Prompt | & claude @claudeArgs 2>&1
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $prevNativeErrorPref
        $env:CLAUDE_CODE_DISABLE_BUILTIN_AGENTS = $prevDisableBuiltinAgents
    }
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

# One JSON file per replayed ticket, under eval\results\<label>\ - the raw
# material Replay-Tickets.ps1 scores and compares. Written on both the
# success and the error path so a replay that crashed on one ticket still
# leaves a record of it rather than a silent gap in the results folder.
function Write-ReplayResult {
    param(
        [string]$RootPath,
        [string]$Label,
        $TicketId,
        [string]$Tier,
        [string]$Model,
        [string]$Effort,
        [string]$AsOf,
        $Result,
        [string]$CacheMarker,
        [string]$ErrorMessage
    )
    $resultsDir = Join-Path (Join-Path (Join-Path $RootPath "eval") "results") $Label
    if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null }
    $parsed = $null
    if ($Result) { $parsed = $Result.Parsed }
    $record = [PSCustomObject]@{
        ticket_id    = $TicketId
        tier         = $Tier
        model        = $Model
        effort       = $Effort
        as_of        = $AsOf
        label        = $Label
        ran_at       = (Get-Date).ToString("o")
        cost_usd     = $(if ($parsed -and $parsed.total_cost_usd) { $parsed.total_cost_usd } else { 0 })
        num_turns    = $(if ($parsed -and $parsed.num_turns) { $parsed.num_turns } else { $null })
        duration_ms  = $(if ($parsed -and $parsed.duration_ms) { $parsed.duration_ms } else { $null })
        usage        = $(if ($parsed) { $parsed.usage } else { $null })
        cache_marker = $CacheMarker
        is_error     = $(if ($ErrorMessage) { $true } elseif ($parsed) { [bool]$parsed.is_error } else { $true })
        error        = $ErrorMessage
        result       = $(if ($parsed) { $parsed.result } elseif ($Result) { $Result.Raw } else { $null })
    }
    $outPath = Join-Path $resultsDir "$TicketId.json"
    $record | ConvertTo-Json -Depth 6 | Set-Content -Path $outPath -Encoding UTF8
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
    $dryRunOffHoursMinutes = 60
    if ($config.business_hours.off_hours_check_interval_minutes) { $dryRunOffHoursMinutes = $config.business_hours.off_hours_check_interval_minutes }
    Write-Host "Off-hours throttle: skip real checks more often than every $dryRunOffHoursMinutes minute(s) outside business hours (never applies under -WhatIf/-DryRun)"
    $dryRunGateUrl = Get-HelpDeskGateBaseUrl -RootPath $RootPath
    Write-Host "Pre-flight gate: $(if ($dryRunGateUrl) { "$dryRunGateUrl/helpdesk-gate (found via .mcp.json)" } else { 'NOT CONFIGURED - .mcp.json missing or has no "Halo" entry, so every real cycle always runs the classifier (fails open, same as a live gate-check failure would)' })"
    Write-Host "WhatIf (simulation) mode: $WhatIf"
    Write-Host "RequireApproval (human sign-off) mode: $RequireApproval"
    Write-Host "Replay (evaluation) mode: $(if ($isReplay) { "ON - tickets $($ReplayTicketIds -join ','), tier $ReplayTier, label '$ReplayLabel', as-of $replayAsOfText$(if ($ReplayKeepOwnActions) { ', own prior actions kept' })" } else { 'off' })"
    Write-Host "Pipeline flags (config.json 'pipeline' block, all default off): $(($pipelineFlags.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')"
    Write-Host "Ready-for-AI hand-back status: $(if ($config.halo.ready_for_ai_status_name) { "'$($config.halo.ready_for_ai_status_name)' (resolved to an ID at Stage 0, not shown here)" } else { 'NOT CONFIGURED - halo.ready_for_ai_status_name is blank, so this feature is off' })"
    if ($RequireApproval) {
        Write-Host "  NOTE: the approval banner (FLOW A/FLOW B, per-ticket tool selection)" -ForegroundColor Yellow
        Write-Host "  is built from Stage 0's resolved IDs and isn't shown below - it doesn't" -ForegroundColor Yellow
        Write-Host "  exist yet at -DryRun's no-Halo-calls preview stage. Run -WhatIf" -ForegroundColor Yellow
        Write-Host "  -RequireApproval together to see it for real without touching Halo." -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "--- ID Resolution (runs once per cycle, before the classifier - skipped entirely on a cache hit) ---"
    Write-Host "Model: $($config.claude.classifier_model)"
    Write-Host "Effort: $(Format-EffortDisplay -Effort $classifierEffort -Model $config.claude.classifier_model)"
    Write-Host "Allowed tools: $($idResolverTools -join ',')"
    Write-Host "Cache file: $agentCachePath"
    Write-Host "Cache max age (hours): $(if ($config.claude.id_cache_max_age_hours) { $config.claude.id_cache_max_age_hours } else { '24 (default)' })"
    Write-Host "--- ID resolver prompt ---"
    Write-Host $idResolverPrompt
    Write-Host ""
    Write-Host "--- Classifier ---"
    Write-Host "Model: $($config.claude.classifier_model)"
    Write-Host "Effort: $(Format-EffortDisplay -Effort $classifierEffort -Model $config.claude.classifier_model)"
    Write-Host "Allowed tools: $($classifierTools -join ',')"
    Write-Host "--- Classifier prompt (TEAM_ID/AGENT_ID shown as placeholders - only resolved on an actual run) ---"
    Write-Host $classifierPrompt
    Write-Host ""
    Write-Host "--- Resolver (per classified ticket) ---"
    Write-Host "Model by tier: TRIVIAL/TRIVIAL_UNCERTAIN=$($modelForTier['TRIVIAL']), MEDIUM=$($modelForTier['MEDIUM']), COMPLEX=$($modelForTier['COMPLEX']), APPROVED=$($modelForTier['APPROVED']), LEARN_FIX=$($modelForTier['LEARN_FIX'])"
    Write-Host "Effort by tier: TRIVIAL/TRIVIAL_UNCERTAIN=$(Format-EffortDisplay -Effort $effortForTier['TRIVIAL'] -Model $modelForTier['TRIVIAL']), MEDIUM=$(Format-EffortDisplay -Effort $effortForTier['MEDIUM'] -Model $modelForTier['MEDIUM']), COMPLEX=$(Format-EffortDisplay -Effort $effortForTier['COMPLEX'] -Model $modelForTier['COMPLEX']), APPROVED=$(Format-EffortDisplay -Effort $effortForTier['APPROVED'] -Model $modelForTier['APPROVED']), LEARN_FIX=$(Format-EffortDisplay -Effort $effortForTier['LEARN_FIX'] -Model $modelForTier['LEARN_FIX'])"
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
    #
    # $idSchemaVersion closes a real, repeated gap in that design: it only
    # ever compared config.json's OWN text, so a code deploy that changes
    # what id-resolver-prompt.md itself resolves - a new field added to its
    # output, with no config.json name behind it - left old cached IDs
    # looking "still valid" and silently missing the new field for up to
    # id_cache_max_age_hours. Real incident: status_id_names (v2.10.22)
    # shipped, but a config.json-unrelated field has nothing in it to
    # invalidate the cache, so the classifier ran for a full cycle at real
    # cost with status_id_names entirely missing, silently falling back to
    # judging each status by hand instead of the free lookup table - not
    # the first time this exact class of surprise hit (the Ready for AI
    # status rename hit the same gap, just with a config-side field that
    # happened to also change, masking the real cause). Bump this any time
    # id-resolver-prompt.md's OUTPUT schema changes - a field added,
    # removed, or resolved differently - even when no config.json name is
    # involved at all. This one deploy carries it from unset to "2" so this
    # exact incident also self-heals the moment this file is on disk,
    # without anyone needing to remember to clear the cache by hand.
    $idSchemaVersion = "2"

    $currentHaloIdentity = [PSCustomObject]@{
        id_schema_version                = $idSchemaVersion
        help_desk_team_name              = $config.halo.help_desk_team_name
        agent_username                   = $config.halo.agent_username
        resolved_status_name             = $config.halo.resolved_status_name
        waiting_on_client_status_name    = $config.halo.waiting_on_client_status_name
        follow_up_status_name            = $config.halo.follow_up_status_name
        ai_waiting_approval_status_name  = $config.halo.ai_waiting_approval_status_name
        ai_approved_status_name          = $config.halo.ai_approved_status_name
        ready_for_ai_status_name         = $config.halo.ready_for_ai_status_name
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

    if ($agentCache.resolved_ids) {
        try {
            $cached = $agentCache.resolved_ids
            $cachedInputJson = $cached.input | ConvertTo-Json -Compress
            $cachedAgeHours = ((Get-Date) - [datetime]$cached.resolved_at).TotalHours
            if ($cachedInputJson -eq $currentHaloIdentityJson -and $cachedAgeHours -le $idCacheMaxAgeHours) {
                $ids = $cached.ids
                $cachedResolvedAt = $cached.resolved_at
                $usedCachedIds = $true
            }
        }
        catch {
            # Any problem reading the cached value (corrupted, hand-edited
            # into something unexpected) - just treat it as a cache miss and
            # resolve fresh below. Caching is purely an optimization; it
            # must never become a new way for this script to fail.
        }
    }

    if (-not $usedCachedIds) {
        # If any name fails to match, abort the whole cycle rather than let a
        # null/wrong ID silently ride along into every ticket's resolver call
        # this cycle - or, just as bad, get written to the cache and silently
        # reused by every cycle after this one.
        $idResolverResult = Invoke-ClaudeCLI -Prompt $idResolverPrompt -Tools $idResolverTools `
            -Model $config.claude.classifier_model -Effort $classifierEffort
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
            throw "Cached ID resolution data failed validation: $($missingIdFields -join ', ') - delete $agentCachePath to force a fresh resolution, or check config.json's halo section against Halo."
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

    # status_id_names - same pattern as ticket_type_names above, same reason
    # (a readability/judgment aid, not an API-call value - missing here is a
    # warning, not an aborted cycle). Lets the classifier recognize a status
    # like "Dispatch Needed"/"Scheduled"/"Waiting on vendor" by name and skip
    # it as an obviously-already-active-elsewhere workflow before ever
    # spending a resolver call finding the same thing the hard way (real
    # incident: v2.10.21).
    $statusIdNamesText = "(unavailable - status lookup returned nothing usable this cycle)"
    $statusIdCount = 0
    if ($ids.status_id_names) {
        $statusIdProps = @($ids.status_id_names.PSObject.Properties)
        $statusIdCount = $statusIdProps.Count
        if ($statusIdCount -gt 0) {
            $statusIdNamesText = ($statusIdProps | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
        }
    }
    if ($statusIdCount -eq 0) {
        Add-Content -Path $logFile -Value "[$timestamp] WARNING: status_id_names is missing/empty this cycle - classifier will see raw status_id numbers without names, and can't apply the non-Help-Desk-AI-workflow status pre-filter." -Encoding UTF8
    }
    $statusIdNamesText = $statusIdNamesText.Replace('$', '$$')

    # excluded_client_ids was already validated non-null above - [] (nothing
    # configured, the common case) renders as a plain "none" so the classifier/
    # resolver aren't left comparing against literal empty-array text.
    $excludedClientIdsText = "none"
    if ($ids.excluded_client_ids -and @($ids.excluded_client_ids).Count -gt 0) {
        $excludedClientIdsText = (@($ids.excluded_client_ids) -join ", ")
    }

    # Same "none" rendering as excluded_client_ids above, same reason - an
    # empty tracked-tickets cache (the common case right after this feature
    # ships, or once every waiting ticket has been answered) should read as
    # plain text, not literal empty-array syntax.
    $trackedTicketIdsText = "none"
    if ($trackedTicketIds -and @($trackedTicketIds).Count -gt 0) {
        # v2.13.2: each id carries its "evaluated through" watermark so the
        # classifier can tell an entry it already looked at from a new one.
        $trackedTicketIdsText = (@($trackedTicketIds | ForEach-Object { $k = [string]$_; if ($trackedEvaluated.ContainsKey($k)) { "$k (evaluated through $($trackedEvaluated[$k])Z)" } else { "$k" } }) -join ", ")
    }

    # Same "none" rendering, same reason - see the blocked_tickets loading/
    # pruning comment above for what this list means and why it exists.
    $blockedTicketIdsText = "none"
    if ($blockedTickets.Count -gt 0) {
        $blockedTicketIdsText = (@($blockedTickets.Keys) -join ", ")
    }

    # Same "none" rendering, same reason - see the human_owned_tickets
    # loading/pruning comment above for what this list means and why it
    # exists (v2.10.60).
    $humanOwnedTicketIdsText = "none"
    if ($humanOwnedTickets.Count -gt 0) {
        $humanOwnedTicketIdsText = (@($humanOwnedTickets.Keys) -join ", ")
    }

    # Same "none" rendering as ready_for_ai_status_id below - these are only
    # ever set when -RequireApproval's two config names are both configured
    # (see config's halo._comment), so a run that doesn't use approval mode
    # renders literal "none" here rather than a blank/0 the classifier could
    # misread as a real status_id. Needed here (v2.10.60) so the classifier's
    # call 3 can recognize a ticket sitting in one of these two statuses and
    # not unconditionally UNTRACK it just because a human reassigned it to
    # review the pending draft - see "Find candidate tickets" below.
    $aiWaitingApprovalStatusIdText = "none"
    if ($null -ne $ids.ai_waiting_approval_status_id) { $aiWaitingApprovalStatusIdText = $ids.ai_waiting_approval_status_id }
    $aiApprovedStatusIdText = "none"
    if ($null -ne $ids.ai_approved_status_id) { $aiApprovedStatusIdText = $ids.ai_approved_status_id }

    # Same "none" rendering, same reason - see the remembered_notes loading
    # comment above. Rendered as a plain bullet list (not JSON) since this is
    # meant to be read and weighed by the resolver, not parsed.
    # halo.contact_default_sites (v2.12.2): { "<client name>": "<site name>" } -
    # the site to create a new contact under for that client when nothing in
    # the ticket points to one. Rendered as text for the resolver prompt.
    $contactDefaultSitesText = "none"
    if ($config.halo.PSObject.Properties['contact_default_sites'] -and $config.halo.contact_default_sites) {
        $contactDefaultSiteLines = @($config.halo.contact_default_sites.PSObject.Properties | ForEach-Object { "$($_.Name) -> $($_.Value)" })
        if ($contactDefaultSiteLines.Count -gt 0) { $contactDefaultSitesText = ($contactDefaultSiteLines -join "; ") }
    }
    $contactDefaultSitesText = $contactDefaultSitesText.Replace('$', '$$')

    # halo.help_desk_email / halo.internal_email_domains (v2.12.3): how the
    # resolver recognizes a client email that reached the desk by being
    # forwarded from one of our own mailboxes. Defaults keep an older
    # config.json working unchanged.
    $helpDeskEmail = "help@altecusa.com"
    if ($config.halo.PSObject.Properties['help_desk_email'] -and $config.halo.help_desk_email) { $helpDeskEmail = [string]$config.halo.help_desk_email }
    $internalEmailDomains = @("altecusa.com", "altecsales.com")
    if ($config.halo.PSObject.Properties['internal_email_domains'] -and $config.halo.internal_email_domains) { $internalEmailDomains = @($config.halo.internal_email_domains | ForEach-Object { [string]$_ }) }
    $helpDeskEmailText = $helpDeskEmail.Replace('$', '$$')
    $internalEmailDomainsText = ($internalEmailDomains -join ", ").Replace('$', '$$')

    $rememberedNotesText = "none"
    if (@($rememberedNotes).Count -gt 0) {
        $rememberedNotesLines = @($rememberedNotes | ForEach-Object {
            "- [$($_.client)] $($_.text) (from ticket #$($_.source_ticket_id), $($_.remembered_at))"
        })
        $rememberedNotesText = "`n" + ($rememberedNotesLines -join "`n")
    }

    if ($usedCachedIds) {
        # Log a lightweight confirmation, not the full claude-call section (there
        # was no claude call this cycle) - shaped like a no-cost claude response so
        # Show-AgentLog.ps1 renders it the same way as every other section instead
        # of hitting its "couldn't parse" fallback.
        $cacheNoteContent = [PSCustomObject]@{
            result = "Using cached IDs from $cachedResolvedAt (age $([math]::Round($cachedAgeHours,1))h, cache max age ${idCacheMaxAgeHours}h): team_id=$($ids.team_id), agent_id=$($ids.agent_id), resolved_status_id=$($ids.resolved_status_id), waiting_status_id=$($ids.waiting_status_id), followup_status_id=$($ids.followup_status_id), ai_waiting_approval_status_id=$($ids.ai_waiting_approval_status_id), ai_approved_status_id=$($ids.ai_approved_status_id), ready_for_ai_status_id=$($ids.ready_for_ai_status_id), excluded_client_ids=[$excludedClientIdsText], ticket_type_names_count=$ticketTypeCount"
        } | ConvertTo-Json -Compress
        Write-LogSection -LogFile $logFile -Header "ID RESOLUTION" -Content $cacheNoteContent
        # $resolvedIdsForCache already holds this same cached value (set
        # before Stage 0 began) - nothing to update.
    }
    else {
        # Record the freshly-validated IDs, keyed on the exact config.json
        # names that produced them so any future edit to those names
        # invalidates this automatically - $resolvedIdsForCache is what the
        # finally block at the end of this script actually writes to
        # agent-cache.json, alongside the tracked-ticket state, as one
        # combined write for the whole cycle instead of a separate file
        # write here.
        $resolvedIdsForCache = [PSCustomObject]@{
            resolved_at = (Get-Date).ToString("o")
            input       = $currentHaloIdentity
            ids         = $ids
        }
    }

    # Inject the resolved IDs into both the classifier and resolver prompts - from
    # here on, neither needs to look any of these up itself.
    # ready_for_ai_status_id is optional (null when the config name is blank
    # or unset) - render it as the literal text "none" rather than the
    # PowerShell $null->"" empty-string substitution, so classifier-prompt.md/
    # resolver-prompt.md's {{READY_FOR_AI_STATUS_ID}} placeholder always reads
    # as an explicit, human-legible value instead of silently vanishing into
    # blank text that could be misread as "status 0" or a stray space.
    $readyForAiStatusIdText = "none"
    if ($null -ne $ids.ready_for_ai_status_id) { $readyForAiStatusIdText = $ids.ready_for_ai_status_id }

    # agent_can_self_assign (v2.10.25): a plain boolean, not a Halo name to
    # resolve, so it comes straight from config.json - no Stage 0 lookup
    # needed. Missing/absent (an older config.json, or a value that isn't
    # literally JSON false) defaults to $true - the pre-v2.10.25 behavior
    # (always self-assign while working a ticket) - so a deployment that
    # hasn't added this field yet sees no behavior change at all.
    $agentCanSelfAssign = $true
    if ($null -ne $config.halo.agent_can_self_assign) { $agentCanSelfAssign = [bool]$config.halo.agent_can_self_assign }
    $agentCanSelfAssignText = if ($agentCanSelfAssign) { "true" } else { "false" }

    $classifierPrompt = $classifierPrompt `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{STATUS_ID_NAMES\}\}', $statusIdNamesText `
        -replace '\{\{EXCLUDED_CLIENT_IDS\}\}', $excludedClientIdsText `
        -replace '\{\{TRACKED_TICKET_IDS\}\}', $trackedTicketIdsText `
        -replace '\{\{BLOCKED_TICKET_IDS\}\}', $blockedTicketIdsText `
        -replace '\{\{HUMAN_OWNED_TICKET_IDS\}\}', $humanOwnedTicketIdsText `
        -replace '\{\{WAITING_STATUS_ID\}\}', $ids.waiting_status_id `
        -replace '\{\{FOLLOWUP_STATUS_ID\}\}', $ids.followup_status_id `
        -replace '\{\{READY_FOR_AI_STATUS_ID\}\}', $readyForAiStatusIdText `
        -replace '\{\{AI_WAITING_APPROVAL_STATUS_ID\}\}', $aiWaitingApprovalStatusIdText `
        -replace '\{\{AI_APPROVED_STATUS_ID\}\}', $aiApprovedStatusIdText
    $resolverPromptTemplate = $resolverPromptTemplate `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{EXCLUDED_CLIENT_IDS\}\}', $excludedClientIdsText `
        -replace '\{\{REMEMBERED_NOTES\}\}', $rememberedNotesText `
        -replace '\{\{CONTACT_DEFAULT_SITES\}\}', $contactDefaultSitesText `
        -replace '\{\{HELP_DESK_EMAIL\}\}', $helpDeskEmailText `
        -replace '\{\{INTERNAL_EMAIL_DOMAINS\}\}', $internalEmailDomainsText `
        -replace '\{\{RESOLVED_STATUS_ID\}\}', $ids.resolved_status_id `
        -replace '\{\{WAITING_STATUS_ID\}\}', $ids.waiting_status_id `
        -replace '\{\{FOLLOWUP_STATUS_ID\}\}', $ids.followup_status_id `
        -replace '\{\{READY_FOR_AI_STATUS_ID\}\}', $readyForAiStatusIdText `
        -replace '\{\{AGENT_CAN_SELF_ASSIGN\}\}', $agentCanSelfAssignText

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
            "banner for what that means downstream. It adds two extra, ownership-",
            "independent candidate-finding calls, on top of calls 1-4 above:",
            "",
            "5. **AI Waiting Approval, but only if a human has touched it since:**",
            "   `{ team_id: $($ids.team_id), status_id: $($ids.ai_waiting_approval_status_id),",
            "   open_only: true, pageinate: true, page_no: 1, page_size: 15 }`, paging",
            "   through every page (same reasoning as call 4 - a human deliberately left",
            "   feedback on one of these expecting it to be seen). For each ticket found,",
            "   call ``mcp__Halo__get_ticket_time_entries`` and check whether anything has",
            "   happened since your own most recent action on it - a new note from a real",
            "   human (``who_type: 1``, not this pipeline's own identity), or a change in",
            "   who it's assigned to. Entries by System, Automation or HaloAI (``who_type: 0`` -",
            "   'Rule Applied', 'AI Triage', 'Ticket In Progress Email') never count, a bare",
            "   Re-Assign/Triage with no note text counts only the first time you see it, and",
            "   nothing dated at or before the ticket's 'evaluated through' time in the",
            "   tracked list above counts at all - it was already looked at (real incident,",
            "   2026-09-21: an automation email after a technician's claim re-queued three",
            "   drafts every cycle for a day). **If nothing has happened yet** (your own",
            "   `[DRAFT PENDING APPROVAL]` note is still the most recent substantive",
            "   entry): skip it, same as always - re-processing an untouched, still-",
            "   pending draft wastes cost and risks clobbering it. **If something HAS",
            "   happened** - a human left a note, or reassigned it to themselves to",
            "   review it, or both: include it as a candidate, regardless of who it's",
            "   currently assigned to. Do not apply the 'skip anything with a recent",
            "   reply from a different Altec agent' rule to this bucket - a human",
            "   reviewing or annotating a draft this pipeline itself wrote is not the",
            "   same as a colleague independently working an unrelated ticket, even if",
            "   they claimed it to leave the note. Tier it normally based on its actual",
            "   content, exactly like a first-pass candidate - this call finds *whether*",
            "   to look again, not how complex it is. The resolver's own instructions",
            "   (see resolver-prompt.md's `"If a human left a note on your own pending",
            "   draft`") handle what happens next - producing a revised draft, not a",
            "   fresh send, even if the note reads like approval.",
            "6. **AI Approved, regardless of ownership:**",
            "   `{ team_id: $($ids.team_id), status_id: $($ids.ai_approved_status_id),",
            "   open_only: true, pageinate: true, page_no: 1, page_size: 15 }`, paging",
            "   through every page. **Every ticket found here is an unconditional",
            "   candidate, regardless of who it's currently assigned to** - a human",
            "   approved this exact draft and it's ready to actually send; don't skip it",
            "   for being assigned to a real agent (they may have claimed it just to",
            "   approve it) and don't apply the 'recent reply from a different agent'",
            "   rule here either. Tag it with tier `"APPROVED`" specifically, not your",
            "   usual TRIVIAL/MEDIUM/COMPLEX judgment - this ticket's tier was already",
            "   decided last cycle; your only job for it now is flagging it so the",
            "   resolver runs its approval-completion flow instead of tiering it fresh.",
            "",
            "Calls 5-6 take precedence over calls 1-4 for any ticket whose status_id is",
            "$($ids.ai_waiting_approval_status_id) or $($ids.ai_approved_status_id): call 1's own rules already exclude those",
            "two statuses from its bucket, so such a ticket should only ever appear here -",
            "and if one somehow shows up in both, the call 5/6 answer (APPROVED for call",
            "6) is the one to output, never a content tier. Real incident, ticket #22389",
            "(2026-09-20): tiered COMPLEX by call 1 from its content, then skipped here as",
            "'already present' - the resolver ran the wrong flow with the wrong tools every",
            "cycle. Every other candidate-selection/tiering rule in this document still",
            "applies as normal to every other ticket.",
            "==="
        )
        $classifierPrompt = ($classifierApprovalBannerLines -join "`n") + "`n`n" + $classifierPrompt

        # FLOW A step 3's content depends on agent_can_self_assign (v2.10.25,
        # see config.json) - computed as a single string (embedded `n, not
        # separate array elements) so it can drop into the array literal
        # below as one item without needing to restructure the whole
        # $approvalBannerLines array around a conditional splice.
        $flowAStep3Lines = if ($agentCanSelfAssign) {
            "3. Assign yourself to the ticket (mcp__Halo__update_ticket with verify: true,`n" +
            "   your resolved agent_id) - its own call, before anything else below. Check`n" +
            "   the response's verified.confirmed before proceeding - the fact you found a`n" +
            "   draft note at all means a PRIOR write landed, but that doesn't guarantee`n" +
            "   THIS one will."
        }
        else {
            "3. Skip assigning yourself to the ticket - config's agent_can_self_assign is`n" +
            "   false (this account operates in `"do not assign me`" mode - see`n" +
            "   resolver-prompt.md's `"Claim the ticket`" section), so there is nothing to`n" +
            "   do for this step. Proceed directly to step 4."
        }
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
            "   and find the ONE private note containing the exact line",
            "   `"[DRAFT PENDING APPROVAL]`" (on its own line - it doesn't have to be the",
            "   very first thing in the note; a relink or other bookkeeping recorded",
            "   ahead of it in the same note still counts). If you find zero or more",
            "   than one, stop - add an internal note (first line: [PIPELINE NOTE], see",
            "   resolver-prompt.md's 'Marking your own waiting-on-a-human notes') flagging",
            "   the mismatch, move the",
            "   ticket's status back to ai_waiting_approval_status_name in that same",
            "   update_ticket call (verify: true), print [CACHE: UNTRACK], and do nothing",
            "   else; don't guess which draft is the real one. The status move is not",
            "   optional: a ticket left in ai_approved_status_name is re-selected by",
            "   the classifier's call 6 unconditionally every cycle, so a stop that",
            "   leaves the status alone repeats itself - note, cost, and all - every 10",
            "   minutes until a human notices (real incident, tickets #22389/#22390,",
            "   2026-09-20). Back on AI Waiting Approval, the ticket waits quietly until",
            "   a human fixes the problem and re-approves. The same rule applies to",
            "   every other stop in this flow (step 4's 'can't tell what it meant',",
            "   step 5's 'nowhere to send it').",
            "1.5. **Before trusting this status, check what's actually after that draft",
            "   note.** A human can move a ticket to AI Approved and leave an",
            "   instructional note at essentially the same moment - the status change",
            "   alone does not mean the exact draft text is still what they want sent.",
            "   Real incident: ticket #22067 - a human triaged the ticket to AI Approved",
            "   and, one second later, left a private note reading `"Ask what department",
            "   the user is in and where is the machine physically located.`" FLOW A found",
            "   the AI-Approved status, sent the original stale draft verbatim, and the",
            "   note asking for missing information was never read or acted on at all.",
            "   Look at everything after the draft note for any note with real text from",
            "   a human (``who_type: 1``, not this pipeline's own identity) - ignore routine",
            "   bookkeeping with no free-text instruction (a bare status change, a",
            "   contact/client re-link with only its auto-generated `"From: ... To: ...`"",
            "   note). **If you find one:** stop here - do not proceed to step 2. Instead,",
            "   follow resolver-prompt.md's `"If a human left a note on your own pending",
            "   draft`" section exactly as if this ticket were still AI Waiting Approval:",
            "   read the note, incorporate it, and write a *revised* draft back to",
            "   ``ai_waiting_approval_status_id`` for a fresh review - do not send the",
            "   original text, and do not treat the AI-Approved status as still valid for",
            "   text that was never actually reviewed. **If nothing but routine bookkeeping",
            "   follows the draft:** continue to step 2 below, business as usual.",
            "2. Read its structure: the text after that first line is the exact",
            "   client-facing reply a human approved, verbatim - don't edit, improve, or",
            "   shorten it. A line `"[INTENDED STATUS] <name>`" names the status to set",
            "   afterward. A line `"[INTENDED REMEDIATION] none`" or `"...  <description>`"",
            "   names the exact whitelisted remediation action, if any, queued for this",
            "   ticket, with enough detail (target device/account) to actually perform it",
            "   now. There is no assignment line to read - step 7 below decides agent_id",
            "   from the ticket's own current state, not from anything in this note.",
            $flowAStep3Lines,
            "4. If [INTENDED REMEDIATION] isn't `"none`": perform EXACTLY that action now,",
            "   matching the remediation whitelist the same way you always would. Can't",
            "   tell exactly what it meant (which device, which account)? Stop and flag it",
            "   in an internal note rather than guessing or substituting a different",
            "   target. Real time has passed and you're no longer confident this specific",
            "   action is still safe to run as recorded? Say so in an internal note and",
            "   stop rather than run stale intent blindly.",
            "4.5. Make sure the reply can actually reach the client before sending it:",
            "   if the ticket's contact is a generic/system one or its emailtolist is",
            "   empty, apply resolver-prompt.md's 'unknown or wrong contact' section NOW,",
            "   for real (create/relink the verified contact - this flow has the tools),",
            "   re-fetch the ticket, and only then continue. If that section genuinely",
            "   can't produce a deliverable address, stop the way step 1 does: internal",
            "   note (first line: [PIPELINE NOTE]) saying exactly what's missing, status back to",
            "   ai_waiting_approval_status_name, [CACHE: UNTRACK]. Real incident, ticket",
            "   #22390: an approved reply to a verified M365 user was held every cycle",
            "   because her Halo contact had never been created - the contact was the",
            "   fix, and this flow could have made it.",
            "5. ONE call does the rest: mcp__Halo__send_approved_draft with ticket_id,",
            "   draft_action_id (the note from step 1), status_id = [INTENDED STATUS]'s id,",
            "   team_id = help_desk_team_name's id, require_status_id =",
            "   ai_approved_status_id, and agent_id decided by Roger's rule: never take a",
            "   ticket away from a real human tech who holds it - if the ticket's current",
            "   agent_id is neither 1 nor this pipeline's own agent_id, OMIT agent_id;",
            "   otherwise pass agent_id: 1 (Halo's API-user account doesn't show in the",
            "   licensed-user list, so a ticket left on it is invisible to humans). Before",
            "   the call, compare get_contact's emailaddress for the linked user_id with",
            "   the ticket's emailtolist; if they differ, pass emailto with the contact's",
            "   real address (v2.10.61). The tool then, atomically: corrects the address,",
            "   posts the draft's text VERBATIM as the real emailed reply (it can only",
            "   send text already sitting in the approved draft, never text you supply),",
            "   collapses the draft to [APPROVED DRAFT], deletes every [PIPELINE NOTE]",
            "   you wrote, sets status/team/agent, and verifies. Real incident, ticket",
            "   #22390 (2026-09-20): with these as separate steps the reply went out but",
            "   the draft was never collapsed - a step a model can skip is a step that",
            "   will eventually be skipped. Read the response: verified.confirmed must be",
            "   true before you report `"sent`"; if the tool refuses (0 or 2+ draft notes,",
            "   wrong status, empty draft), stop the way step 1 does - [PIPELINE NOTE],",
            "   status back to ai_waiting_approval_status_name, [CACHE: UNTRACK].",
            "6. Print your one-line summary, then as the very last line of your response",
            "   print exactly `"[CACHE: TRACK]`" if [INTENDED STATUS] was",
            "   waiting_on_client_status_name, or `"[CACHE: UNTRACK]`" for any other",
            "   status - same rule as resolver-prompt.md's own `"When you finish`"",
            "   section, which this step is standing in for. Then stop - nothing else",
            "   in this document applies to an APPROVED-tier ticket (Hudu documentation,",
            "   if warranted, already happened when the draft was written).",
            "",
            "FLOW B - every other tier: work the rest of this document completely",
            "normally (investigate, judge difficulty, decide on a reply and/or a",
            "remediation action) with one change at the very end. Wherever this document",
            "would have you send a real, public, client-facing reply OR take a",
            "remediation action (password reset/unlock/reboot/script run), do this",
            "instead, in one update_ticket_draft_only call (not update_ticket - that tool",
            "is not in your allowlist for this ticket; see the top of resolver-prompt.md's",
            "`"Which update_ticket tool do you actually have?`" section if you're unsure why):",
            "0. Before writing a new draft, delete any prior one(s) still on this ticket -",
            "   scan the action history you already pulled for every private note",
            "   containing the exact line `"[DRAFT PENDING APPROVAL]`" on its own line",
            "   (not necessarily as the very first thing in the note) and call",
            "   mcp__Halo__delete_ticket_note (ticket_id, action_id) on each one, before",
            "   step 1 below. Per Roger's request: a ticket should only ever carry one",
            "   pending draft at a time, not an accumulating pile of superseded ones -",
            "   real incident, ticket #22033 ended up with 3 separate",
            "   `"[DRAFT PENDING APPROVAL]`" notes left behind across several revision",
            "   rounds (nothing ever removed the old one when a new draft replaced it),",
            "   which tripped FLOW A's own `"exactly one draft note or stop`" safety check",
            "   and needed a human to clean up by hand. The tool refuses (no delete",
            "   happens) unless the note is private and starts with that exact marker, so",
            "   it cannot remove a human's note or a real reply even if pointed at the",
            "   wrong action by mistake - if it refuses, don't fight it or guess at a",
            "   workaround, just proceed to step 1 and leave the old note as-is.",
            "1. note: a single private note, in this exact structure - `"[DRAFT PENDING",
            "   APPROVAL]`" on its own line, then the full client-facing reply text you",
            "   would have sent, verbatim, exactly as you'd have sent it live; then a line",
            "   `"[INTENDED STATUS] <name>`" (whichever this document's own rules would",
            "   have set - resolved_status_name/waiting_on_client_status_name/",
            "   follow_up_status_name); then a line",
            "   `"[INTENDED REMEDIATION] none`" or `"...  <exact whitelisted action +",
            "   target>`" (e.g. `"Reset M365 password for jsmith@client.com`" or `"Run",
            "   NinjaOne script 'Reset Printing' on device WKS-1234`") - specific enough",
            "   that FLOW A can execute this exact action later without re-diagnosing.",
            "   No assignment line is needed - FLOW A decides agent_id from the ticket's",
            "   own current state when it executes this later (see its own step 7), not",
            "   from anything recorded here.",
            "2. status_id: $($ids.ai_waiting_approval_status_id) (ai_waiting_approval_status_name) -",
            "   ALWAYS this exact value on THIS call, never",
            "   resolved_status_name/waiting_on_client_status_name/follow_up_status_name,",
            "   even though you likely just decided one of those belongs in the",
            "   `"[INTENDED STATUS]`" line above. Those are two different things: the",
            "   [INTENDED STATUS] line is a record of what status should be set LATER,",
            "   by FLOW A, once a human approves and this actually sends - it never",
            "   controls what status_id you pass to THIS call. Real incident: two",
            "   tickets in one run set this call's real status_id to",
            "   waiting_on_client_status_name instead - matching what they'd correctly",
            "   written as [INTENDED STATUS], but wrong for the actual call, because the",
            "   client hadn't actually been asked anything yet (the reply was still an",
            "   unsent private draft) - `"Waiting on client`" was simply false. Worse,",
            "   that status is exactly what this run's own classifier banner (above)",
            "   treats as ordinary, unremarkable ticket state, not something needing",
            "   review - so the pending draft would have gone unnoticed indefinitely",
            "   instead of surfacing for approval.",
            "3. agent_id: 1 - unless the ticket already belongs to a real human tech",
            "   (agent_id is neither 1 nor this pipeline's own agent_id) when you",
            "   fetched it, most likely because you reached it through Ready for AI,",
            "   which works specifically `"regardless of who it's assigned to`" - in that",
            "   case, leave agent_id out of this call, per Roger's workflow decision to",
            "   never take a ticket away from a tech who already holds it. Otherwise,",
            "   agent_id: 1 (visibly free/pending, not stuck showing as yours while it",
            "   waits).",
            "update_ticket_draft_only always writes the note above as private and",
            "unemailed regardless of any other argument, so there is no note_is_private",
            "or send_email field to set here - it isn't capable of sending a real reply",
            "no matter what you pass it. It also always verifies its own write before",
            "returning - check the response's verified.confirmed rather than assuming",
            "success. An untriaged ticket can still leave the note/agent_id part of this",
            "exact call unconfirmed while the status_id part lands fine, which would leave",
            "the ticket looking like it's waiting for approval with nothing to actually",
            "approve - see resolver-prompt.md's `"A write can report success and not be",
            "immediately readable back`" section for what to do if verified.confirmed is",
            "false. Do not actually take the remediation action this cycle - only the",
            "private draft note above.",
            "",
            "ONE EXCEPTION: a genuine EMERGENCY (the emergency section's outage test, or",
            "the confirmed-compromise path) is acknowledged and paged for real,",
            "immediately, with ONE call: mcp__Halo__escalate_emergency. That tool is the",
            "only sending tool you hold in this mode, and it can only send a fixed,",
            "templated acknowledgment ('we can see <your one-line summary>... notifying",
            "our on-call engineer right now') and page the configured on-call contacts -",
            "you supply the summary phrase, never the message or the recipients. Roger's",
            "decision (2026-09-20, ticket #22385: a site-wide phone outage on a Saturday",
            "morning sat as an unsent draft because this mode had removed every tool",
            "that could send). Only the detailed follow-up reply, once you've actually",
            "investigated, goes through the draft/approve flow above. Never write the",
            "acknowledgment as a draft and never ask a human to page on-call by hand -",
            "the tool does both, and if its on-call page fails it says so in its",
            "response, which is when you flag that for a human in a NEEDS URGENT note.",
            "",
            "Any private note you leave that is only a status of this pipeline's own",
            "progress - waiting on a human to verify a contact, pick a site, fix a",
            "mismatch - starts with the line [PIPELINE NOTE] (see resolver-prompt.md's",
            "'Marking your own waiting-on-a-human notes'), so FLOW A can clear it once",
            "the ticket proceeds. Findings never carry it.",
            "",
            "ANOTHER EXCEPTION: fixing which contact/company a ticket is linked to",
            "(resolver-prompt.md's `"unknown or wrong contact`" section, including",
            "create_contact when identity is independently verified) is not the",
            "client-facing reply or remediation this flow defers - it's fixing the",
            "ticket's own data, the same category as the update_ticket bookkeeping this",
            "flow itself relies on. Do this for real, immediately, exactly as that",
            "section describes, whatever tier this ticket is - do not draft it into the",
            "note above or wait for approval to create/relink a contact.",
            "",
            "Everything else in this document (investigation, judgment, Hudu",
            "documentation) still happens normally under FLOW B - only the outgoing",
            "reply/remediation is held back.",
            "==="
        )
        $approvalBanner = $approvalBannerLines -join "`n"
    }

    # --- Cheap pre-flight gate: before paying for the classifier LLM call,
    #     ask halopsa-mcp's own /helpdesk-gate route (a plain HTTP GET, no
    #     Claude/LLM involved at all) whether there's plausibly anything for
    #     it to find. Real incident: the vast majority of cycles found
    #     nothing, yet every one still ran the full classifier at real cost.
    #     Fails open on any problem (missing Worker URL, network error,
    #     malformed response) - always run the classifier normally rather
    #     than risk silently skipping a cycle that needed it. Never runs
    #     under -WhatIf/-DryRun, same reasoning as the throttle above.
    $shouldRunClassifier = $true
    if (-not $WhatIf -and -not $DryRun) {
        try {
            $gateBaseUrl = Get-HelpDeskGateBaseUrl -RootPath $RootPath
            if ($gateBaseUrl) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $gateUri = "$gateBaseUrl/helpdesk-gate?team_id=$($ids.team_id)&agent_id=$($ids.agent_id)"
                if ($trackedTicketIds.Count -gt 0) { $gateUri += "&tracked_ids=$($trackedTicketIds -join ',')" }
                $gateHeaders = @{}
                $gateAuth = Get-HelpDeskGateAuthHeader -RootPath $RootPath
                if ($gateAuth) { $gateHeaders['Authorization'] = $gateAuth }
                $gate = Invoke-RestMethod -Uri $gateUri -Method Get -TimeoutSec 20 -Headers $gateHeaders
                $anyTrackedChanged = $false
                foreach ($t in @($gate.tracked)) {
                    $key = [string]$t.id
                    if (-not $t.found) { $anyTrackedChanged = $true; continue }
                    $previousSeen = $trackedLastSeen[$key]
                    if (-not $previousSeen -or $previousSeen -ne $t.last_action_date) { $anyTrackedChanged = $true }
                    $trackedLastSeen[$key] = $t.last_action_date
                }
                # Real incident: unassigned_count alone can never go quiet on
                # a queue that always has a few non-actionable tickets
                # sitting at agent_id: 1 (AI Waiting Approval, Dispatch
                # Needed - see resolver-prompt.md) - the classifier ran and
                # paid real cost every 15 minutes reaching the identical
                # "nothing to do" conclusion about the exact same tickets,
                # because a bare count > 0 can't distinguish "still the same
                # three tickets" from "something genuinely new." Fingerprint
                # this bucket the same way tracked tickets already are: only
                # count it as changed if a ticket ID here wasn't seen last
                # cycle (genuinely new), or an already-seen one's
                # last_action_date moved (something happened to it). A
                # ticket simply leaving this bucket (claimed for real,
                # resolved) isn't itself a signal - there's nothing left for
                # the classifier to do about it - so that alone doesn't
                # trigger a run, only prunes it from $unassignedLastSeen
                # below.
                #
                # Real incident: this fingerprint used to compare Halo's raw
                # `last_update` field, which moves on its own for any
                # on-hold ticket (Halo recomputes slaholdtime continuously,
                # with zero real activity) - confirmed live via ticket #22033
                # sitting untouched in AI Waiting Approval for hours while
                # `last_update` still drifted, which made this gate see
                # "changed" on nearly every cycle and reprocess it through
                # the full classifier+resolver about 28 times in one day at
                # real Sonnet cost, chasing a change that never happened.
                # `last_action_date` (halopsa-mcp's `lastactiondate`) only
                # moves when a real Action - a note, reply, or status change
                # - is actually added, so it's immune to that drift.
                $anyUnassignedChanged = $false
                $seenUnassignedIds = @{}
                foreach ($u in @($gate.unassigned)) {
                    $key = [string]$u.id
                    $seenUnassignedIds[$key] = $true
                    $previousSeen = $unassignedLastSeen[$key]
                    if (-not $previousSeen -or $previousSeen -ne $u.last_action_date) { $anyUnassignedChanged = $true }
                    $unassignedLastSeen[$key] = $u.last_action_date
                }
                foreach ($key in @($unassignedLastSeen.Keys)) {
                    if (-not $seenUnassignedIds.ContainsKey($key)) { $unassignedLastSeen.Remove($key) }
                }
                $shouldRunClassifier = $anyUnassignedChanged -or ($gate.stuck_claimed_count -gt 0) -or $anyTrackedChanged
                if ($gate.unassigned_truncated) {
                    $gateTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $logFile -Value "[$gateTimestamp] NOTE: unassigned gate fingerprint truncated - the Help Desk unassigned bucket has more tickets than the Worker's page cap covered this cycle (unassigned_count=$($gate.unassigned_count)); a change on a ticket past the cap could be missed until it's covered by a future cycle." -Encoding UTF8
                }
                if (-not $shouldRunClassifier) {
                    $gateTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Add-Content -Path $logFile -Value "[$gateTimestamp] SKIPPED (gate: nothing changed) - unassigned unchanged ($($seenUnassignedIds.Count) known, none new), stuck_claimed=0, $($trackedTicketIds.Count) tracked ticket(s) unchanged." -Encoding UTF8
                    Write-LogSection -LogFile $logFile -Header "CYCLE SUMMARY" -Content (([PSCustomObject]@{ tickets_found = 0; id_resolution_cost_usd = $idResolutionCost; classifier_cost_usd = 0; resolver_cost_usd = 0; total_cost_usd = $idResolutionCost; tickets = @() }) | ConvertTo-Json -Compress)
                    Add-Content -Path $logFile -Value "----" -Encoding UTF8
                    Write-Host "Cycle complete: 0 ticket(s) (gate skipped classifier), total cost `$$idResolutionCost"
                }
            }
        }
        catch {
            $gateTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Add-Content -Path $logFile -Value "[$gateTimestamp] WARNING: pre-flight gate check failed ($($_.Exception.Message)) - running the classifier normally instead of guessing." -Encoding UTF8
            $shouldRunClassifier = $true
        }
    }

    if (-not $shouldRunClassifier) {
        return
    }

    if (-not $isReplay) {
    # --- Stage 1: classify ---
    # v2.12.0: with pipeline.deterministic_classifier on, the candidate list
    # comes from Invoke-DeterministicClassifier (one HTTP call + at most one
    # no-tool tiering call); any failure there falls back to the LLM
    # classifier for this cycle. With pipeline.classifier_shadow on (and the
    # flag off) the deterministic path still runs and its answer is logged
    # next to the LLM's for comparison, but the LLM's answer is what's used.
    $classifierSource = "llm"
    $deterministic = $null
    if ($pipelineFlags.deterministic_classifier -or $pipelineFlags.classifier_shadow) {
        $skipStatusNames = $deterministicSkipStatusNamesDefault
        if ($config.PSObject.Properties.Name -contains 'pipeline' -and $config.pipeline -and $config.pipeline.PSObject.Properties['skip_status_names'] -and $config.pipeline.skip_status_names) {
            $skipStatusNames = @($config.pipeline.skip_status_names | ForEach-Object { [string]$_ })
        }
        try {
            $deterministic = Invoke-DeterministicClassifier -RootPath $RootPath -Ids $ids -TrackedTicketIds $trackedTicketIds `
                -BlockedTickets $blockedTickets -HumanOwnedTickets $humanOwnedTickets -ApprovalMode ([bool]$RequireApproval) `
                -SkipStatusNames $skipStatusNames -ClassifierPromptPath $classifierPromptPath `
                -Model $config.claude.classifier_model -Effort $classifierEffort -NowText $nowText -Timezone $config.business_hours.timezone -EvaluatedAt $trackedEvaluated `
                -IntegrationAppIds $(if ($config.PSObject.Properties.Name -contains 'pipeline' -and $config.pipeline -and $config.pipeline.PSObject.Properties['integration_application_ids'] -and $config.pipeline.integration_application_ids) { @($config.pipeline.integration_application_ids | ForEach-Object { [string]$_ }) } else { @("Huntress", "Acronis Client Portal") })
            Write-LogSection -LogFile $logFile -Header "DETERMINISTIC CLASSIFIER$(if (-not $pipelineFlags.deterministic_classifier) { ' (SHADOW)' })" -Content $deterministic.Report
        }
        catch {
            $deterministic = $null
            $detTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Add-Content -Path $logFile -Value "[$detTimestamp] WARNING: deterministic classifier failed ($($_.Exception.Message)) - $(if ($pipelineFlags.deterministic_classifier) { 'falling back to the LLM classifier for this cycle' } else { 'shadow comparison skipped' })." -Encoding UTF8
        }
    }
    if ($pipelineFlags.deterministic_classifier -and $deterministic) {
        $classifierSource = "deterministic"
        $tickets = @($deterministic.Tickets)
        $classifierCost = $deterministic.Cost
        Write-Host "Classifier: deterministic path, $($tickets.Count) ticket(s), `$$([math]::Round($classifierCost, 4))"
    }
    if ($classifierSource -eq "llm") {
    $classifierResult = Invoke-ClaudeCLI -Prompt $classifierPrompt -Tools $classifierTools `
        -Model $config.claude.classifier_model -Effort $classifierEffort
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
    $classifierCost = 0
    if ($classifierResult.Parsed.total_cost_usd) { $classifierCost = $classifierResult.Parsed.total_cost_usd }

    if ($deterministic -and $pipelineFlags.classifier_shadow) {
        # Side-by-side: same ticket set and same tiers means the switch is
        # safe; any difference is listed with the deterministic path's own
        # reasoning already in the section above.
        $llmMap = @{}
        foreach ($t in @($tickets)) { if ($t -and $t.ticket_id) { $llmMap[[string]$t.ticket_id] = [string]$t.tier } }
        $detMap = @{}
        foreach ($t in @($deterministic.Tickets)) { $detMap[[string]$t.ticket_id] = [string]$t.tier }
        $allIds = @(@($llmMap.Keys) + @($detMap.Keys) | Sort-Object -Unique)
        $sameCount = 0
        $shadowLines = @()
        foreach ($k in $allIds) {
            $l = if ($llmMap.ContainsKey($k)) { $llmMap[$k] } else { "-" }
            $d = if ($detMap.ContainsKey($k)) { $detMap[$k] } else { "-" }
            if ($l -eq $d) { $sameCount++ }
            $shadowLines += ("{0,-8} llm={1,-18} deterministic={2,-18}{3}" -f $k, $l, $d, $(if ($l -ne $d) { "  <-- differs" } else { "" }))
        }
        $shadowLines += "agreement: $sameCount / $($allIds.Count) ticket(s); llm classifier `$$([math]::Round([double]$classifierCost, 4)) vs deterministic `$$([math]::Round([double]$deterministic.Cost, 4))"
        Write-LogSection -LogFile $logFile -Header "CLASSIFIER SHADOW COMPARISON" -Content ($shadowLines -join "`n")
    }
    }

    # UNTRACK is a pseudo-tier, not a real one - the classifier uses it to
    # tell us a previously-tracked ticket (see the tracked-tickets cache
    # loaded above) is no longer open, or has moved off waiting_on_client
    # with nothing new to act on, so it can come out of the cache. It never
    # goes to the resolver - there's nothing to resolve, just bookkeeping,
    # and spending a real claude -p call on a no-op would defeat the whole
    # point of this cache existing.
    $untrackedIds = @($tickets | Where-Object { $_.tier -eq 'UNTRACK' } | ForEach-Object { $_.ticket_id })
    if ($untrackedIds.Count -gt 0) {
        $trackedTicketIds = @($trackedTicketIds | Where-Object { $untrackedIds -notcontains $_ })
        Write-Host "Untracking $($untrackedIds.Count) ticket(s) no longer worth watching: $($untrackedIds -join ', ')"
    }
    $tickets = @($tickets | Where-Object { $_.tier -ne 'UNTRACK' })

    # A ticket_id must be a real, positive Halo ticket ID - never 0,
    # negative, null, or non-numeric. Real incident: a classifier call that
    # couldn't actually invoke its Halo tools this cycle (a transient MCP
    # connection issue, not a prompt problem - its own raw result said so
    # directly: "I don't have direct invocation capability for these MCP
    # tools in my current session's tool set") fabricated a placeholder
    # result instead of reporting the failure - {"ticket_id": 0, "tier":
    # "LOADING"} - which this script accepted as real data and spent a full
    # resolver call "discovering" ticket 0 doesn't exist ($0.16 for
    # nothing). Halo ticket IDs are always positive integers, so reject
    # anything else here, before it ever reaches the resolver, rather than
    # paying to find out it was never real.
    $validTickets = @()
    foreach ($t in $tickets) {
        $parsedId = 0L
        if ([long]::TryParse([string]$t.ticket_id, [ref]$parsedId) -and $parsedId -gt 0) {
            $validTickets += $t
        }
        else {
            Write-Host "WARNING: classifier returned an invalid ticket_id ($($t.ticket_id), tier '$($t.tier)') - discarding without spending a resolver call. This usually means the classifier couldn't actually reach its Halo tools this cycle (check the CLASSIFIER section's raw result in the log for why), not a real candidate."
        }
    }
    $tickets = $validTickets

    # v2.12.1 backstop (ticket #22389): under -RequireApproval, a ticket whose
    # CURRENT status is ai_approved_status_name is APPROVED tier, full stop -
    # the classifier's call 6 says so, but the LLM classifier tiered one from
    # its content (COMPLEX) via call 1 instead, and the resolver then ran the
    # wrong flow with the wrong tools every cycle. One cheap HTTP call to the
    # Worker (ticket fields only, no actions) makes that impossible whatever
    # the classifier says. Fails open: any problem here leaves the tiers as
    # classified and logs why.
    if ($RequireApproval -and $ids.ai_approved_status_id -and @($tickets).Count -gt 0) {
        try {
            $backstopBase = Get-HelpDeskGateBaseUrl -RootPath $RootPath
            if ($backstopBase) {
                $backstopHeaders = @{}
                $backstopAuth = Get-HelpDeskGateAuthHeader -RootPath $RootPath
                if ($backstopAuth) { $backstopHeaders['Authorization'] = $backstopAuth }
                $backstopIds = @($tickets | Where-Object { $_.tier -ne 'APPROVED' -and $_.tier -ne 'UNTRACK' } | ForEach-Object { [string]$_.ticket_id })
                for ($bi = 0; $bi -lt $backstopIds.Count; $bi += 40) {
                    $backstopChunk = @($backstopIds[$bi..([Math]::Min($bi + 39, $backstopIds.Count - 1))])
                    $backstop = Invoke-RestMethod -Uri "$backstopBase/helpdesk-candidates?ids=$($backstopChunk -join ',')&history=0&max_details_chars=1" -Method Get -TimeoutSec 30 -Headers $backstopHeaders
                    foreach ($bc in @($backstop.candidates)) {
                        if (-not $bc.found) { continue }
                        if ([string]$bc.ticket.status_id -ne [string]$ids.ai_approved_status_id) { continue }
                        foreach ($t in $tickets) {
                            if ([string]$t.ticket_id -eq [string]$bc.ticket.id -and $t.tier -ne 'APPROVED') {
                                $backstopTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                                Add-Content -Path $logFile -Value "[$backstopTimestamp] TIER OVERRIDE: ticket $($t.ticket_id) is in ai_approved_status_name (status_id $($bc.ticket.status_id)) but the classifier tiered it $($t.tier) - running it as APPROVED so the approved draft actually sends." -Encoding UTF8
                                $t.tier = 'APPROVED'
                            }
                        }
                    }
                }
            }
        }
        catch {
            $backstopTimestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Add-Content -Path $logFile -Value "[$backstopTimestamp] WARNING: approved-tier backstop check failed ($($_.Exception.Message)) - tiers left as classified." -Encoding UTF8
        }
    }
    # $idResolutionCost was already set in Stage 0 above (0 on a cache hit, the
    # real cost on a fresh resolution) - not recomputed here; $classifierCost
    # was set by whichever classifier path ran above.
    }
    else {
        # Replay mode: the ticket list and tier come from the command line, no
        # classifier call at all - see -ReplayTicketIds at the top of this file.
        $classifierCost = 0
        $tickets = @($ReplayTicketIds | ForEach-Object { [PSCustomObject]@{ ticket_id = $_; tier = $ReplayTier } })
        Write-LogSection -LogFile $logFile -Header "REPLAY ($ReplayLabel)" -Content (([PSCustomObject]@{ ticket_ids = @($ReplayTicketIds); tier = $ReplayTier; as_of = $ReplayAsOf; label = $ReplayLabel }) | ConvertTo-Json -Compress)
    }

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
        $effort = $effortForTier[$tier]
        if (-not $model) {
            Write-Host "Unrecognized tier '$tier' for ticket $ticketId - falling back to the COMPLEX model."
            $model = $config.claude.resolver_model_complex
            $effort = $effortForTier['COMPLEX']
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
        if ($isReplay) {
            $resolverPrompt = $replayBanner + "`n`n" + $resolverPrompt
        }

        # Which tool list a ticket gets depends on ITS OWN tier, not just the
        # cycle-wide switches - an APPROVED ticket needs the full mutating set to
        # actually execute what was approved, while every other ticket under
        # -RequireApproval gets the remediation-mutating tools physically removed
        # (see $resolverToolsApprovalStripped above). -WhatIf's full strip always
        # applies on top, regardless of tier, since nothing should touch anything
        # real in a simulation run. LEARN_FIX is its own fixed minimal allowlist
        # (see $resolverToolsLearnFix above) - it has no mutating Halo tools to
        # strip either way, so -RequireApproval/-WhatIf don't apply to it at all.
        if ($tier -eq 'LEARN_FIX') {
            $ticketTools = $resolverToolsLearnFix
        }
        else {
            $ticketTools = $resolverToolsFull
            if ($RequireApproval -and $tier -ne 'APPROVED') {
                $ticketTools = $resolverToolsApprovalStripped
            }
            if ($WhatIf) {
                $ticketTools = $ticketTools | Where-Object { $mutatingTools -notcontains $_ }
            }
        }

        try {
            $resolverResult = Invoke-ClaudeCLI -Prompt $resolverPrompt -Tools $ticketTools `
                -Model $model -Effort $effort
            Write-LogSection -LogFile $logFile -Header "TICKET $ticketId (tier: $tier, model: $model)" -Content $resolverResult.Raw

            $ticketCost = 0
            if ($resolverResult.Parsed -and $resolverResult.Parsed.total_cost_usd) {
                $ticketCost = $resolverResult.Parsed.total_cost_usd
            }
            $resolverCost += $ticketCost

            # resolver-prompt.md's "When you finish" section requires every
            # path to end with exactly one of these three markers, so the
            # cache doesn't depend on Halo's own agent_id anymore (see the
            # tracked-tickets cache loaded above). A real run under -WhatIf
            # never writes this cache back (see the finally block below), so
            # a missing marker there is expected, not a warning-worthy gap.
            # `[CACHE: REMEMBER: <client>] <text>` is independent of, and can
            # coexist with, the single required TRACK/UNTRACK/BLOCKED line
            # below - see resolver-prompt.md's "Remembering something for
            # future tickets". Zero or more per ticket; each becomes one new
            # entry, newest last, then capped to max_remembered_notes (oldest
            # dropped first) so this list can't grow the resolver prompt's
            # size - and therefore every future call's cost - without bound.
            if ($resolverResult.Parsed -and $resolverResult.Parsed.result) {
                $rememberMatches = [regex]::Matches($resolverResult.Parsed.result, '\[CACHE:\s*REMEMBER:\s*([^\]]+)\]\s*(.+)')
                foreach ($m in $rememberMatches) {
                    $rememberedNotes = @($rememberedNotes) + [PSCustomObject]@{
                        client           = $m.Groups[1].Value.Trim()
                        text             = $m.Groups[2].Value.Trim()
                        source_ticket_id = $ticketId
                        remembered_at    = (Get-Date).ToString("o")
                    }
                }
                if (@($rememberedNotes).Count -gt $maxRememberedNotes) {
                    $rememberedNotes = @($rememberedNotes | Select-Object -Last $maxRememberedNotes)
                }
            }

            $cacheMarker = $null
            if ($resolverResult.Parsed -and $resolverResult.Parsed.result -match '\[CACHE:\s*(TRACK|UNTRACK|BLOCKED|HUMAN_OWNED)\s*\]') {
                $cacheMarker = $Matches[1].ToUpperInvariant()
            }
            # v2.13.2: TRACK also stamps the watermark - everything on this
            # ticket dated up to the start of this cycle has now been looked at.
            if ($cacheMarker -eq 'TRACK') { $trackedEvaluated[[string]$ticketId] = $cycleStartUtc } else { [void]$trackedEvaluated.Remove([string]$ticketId) }
            switch ($cacheMarker) {
                'TRACK'   { if ($trackedTicketIds -notcontains $ticketId) { $trackedTicketIds += $ticketId } }
                'UNTRACK' { $trackedTicketIds = @($trackedTicketIds | Where-Object { $_ -ne $ticketId }) }
                'BLOCKED' {
                    # A structural/platform dead end, not "waiting on
                    # someone" - see blocked_tickets loading comment above.
                    # Not tracked via the normal mechanism (there's nothing
                    # for a tracked-ticket recheck to find - the whole point
                    # is that writes aren't landing), and not left in
                    # tracked_tickets either if it got there first.
                    $trackedTicketIds = @($trackedTicketIds | Where-Object { $_ -ne $ticketId })
                    $blockedTickets[[string]$ticketId] = (Get-Date).ToString("o")
                }
                'HUMAN_OWNED' {
                    # v2.10.60 - see human_owned_tickets loading comment
                    # above. A real human agent already confirmed to own this
                    # ticket, not this pipeline's own tracked/pending-draft
                    # ticket - same "not tracked either" reasoning as BLOCKED
                    # above, different cache/cooldown (human_owned_tickets /
                    # human_owned_retry_hours, not blocked_tickets /
                    # blocked_ticket_retry_hours), since the underlying
                    # reason for exclusion is completely different (a human
                    # genuinely working it by hand, not a platform failure).
                    $trackedTicketIds = @($trackedTicketIds | Where-Object { $_ -ne $ticketId })
                    $humanOwnedTickets[[string]$ticketId] = (Get-Date).ToString("o")
                }
                default {
                    if (-not $WhatIf) {
                        # Real incident (v2.10.39): a resolver run can end without ever
                        # reaching "When you finish" at all - e.g. it got confused about
                        # a deferred MCP tool's availability, asked a question nobody was
                        # there to answer, and stopped - so there's no marker to parse
                        # because the model never got that far, not because it forgot the
                        # syntax. Treated the same as BLOCKED, not left alone: whatever
                        # went wrong, retrying this exact ticket next cycle (15-30 min
                        # later) just reproduces the identical failure at the identical
                        # cost, the same reasoning blocked_tickets already exists for.
                        # Backing off for blocked_ticket_retry_hours costs nothing if the
                        # failure was a one-off fluke - it just gets a normal cycle next
                        # time it comes up - but stops a repeatable failure from silently
                        # burning money every cycle with zero ticket progress and zero
                        # Halo-side visibility (no note, no reply - only this ticket's own
                        # marker discipline would normally record anything at all).
                        $trackedTicketIds = @($trackedTicketIds | Where-Object { $_ -ne $ticketId })
                        $blockedTickets[[string]$ticketId] = (Get-Date).ToString("o")
                        Add-Content -Path $logFile -Value "TICKET ${ticketId}: WARNING - no [CACHE: TRACK|UNTRACK|BLOCKED|HUMAN_OWNED] marker found in resolver output; treating as BLOCKED (backing off for blocked_ticket_retry_hours) rather than leaving it unprotected for next cycle." -Encoding UTF8
                    }
                }
            }

            $ticketOutcomes += [PSCustomObject]@{
                ticket_id = $ticketId
                tier      = $tier
                model     = $model
                cost_usd  = $ticketCost
            }
            if ($isReplay) {
                Write-ReplayResult -RootPath $RootPath -Label $ReplayLabel -TicketId $ticketId -Tier $tier -Model $model -Effort $effort -AsOf $ReplayAsOf -Result $resolverResult -CacheMarker $cacheMarker
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
            if ($isReplay) {
                Write-ReplayResult -RootPath $RootPath -Label $ReplayLabel -TicketId $ticketId -Tier $tier -Model $model -Effort $effort -AsOf $ReplayAsOf -Result $null -CacheMarker $null -ErrorMessage $_.Exception.Message
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
finally {
    # Persist the unified local cache - resolved Halo IDs, the tracked-
    # ticket list, per-ticket "last seen" state (the pre-flight gate above),
    # and this cycle's timestamp (the off-hours throttle above) - covers
    # every exit path (normal completion, an early "nothing changed" return,
    # and even the catch block's throw) with one write, instead of a
    # separate write for each concern at each individual exit point. Never
    # under -WhatIf: a simulation run must leave nothing real behind, and
    # every part of this cache directly changes a future real cycle's
    # behavior the same way any other persisted state would.
    if (-not $WhatIf) {
        try {
            $prunedTrackedLastSeen = @{}
            $prunedTrackedEvaluated = @{}
            foreach ($id in $trackedTicketIds) {
                $key = [string]$id
                if ($trackedLastSeen.ContainsKey($key)) { $prunedTrackedLastSeen[$key] = $trackedLastSeen[$key] }
                if ($trackedEvaluated.ContainsKey($key)) { $prunedTrackedEvaluated[$key] = $trackedEvaluated[$key] }
            }
            $updatedCache = [PSCustomObject]@{
                resolved_ids         = $resolvedIdsForCache
                tracked_tickets      = @($trackedTicketIds | Select-Object -Unique)
                tracked_last_seen    = $prunedTrackedLastSeen
                tracked_evaluated    = $prunedTrackedEvaluated
                unassigned_last_seen = $unassignedLastSeen
                blocked_tickets      = $blockedTickets
                human_owned_tickets  = $humanOwnedTickets
                remembered_notes     = @($rememberedNotes)
                last_real_cycle_at   = (Get-Date).ToString("o")
            }
            $tempCachePath = "$agentCachePath.tmp"
            # -InputObject, not piped: piping an empty array into a pipeline
            # stage produces zero pipeline objects, so a downstream
            # ConvertTo-Json/Set-Content can silently never run at all - a
            # real incident on the old tracked-tickets-only file hit exactly
            # this with an empty tracked list, the common case. -InputObject
            # on the whole combined object here avoids that class of bug
            # regardless of which nested array happens to be empty this cycle.
            ConvertTo-Json -InputObject $updatedCache -Depth 6 | Set-Content -Path $tempCachePath -Encoding UTF8
            Move-Item -Path $tempCachePath -Destination $agentCachePath -Force
        }
        catch {
            # Failing to WRITE this cache should never fail the cycle - worst
            # case, the next cycle just falls back to treating it as empty/stale.
            Add-Content -Path $logFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] WARNING: could not write agent-cache.json to $agentCachePath - $($_.Exception.Message)" -Encoding UTF8
        }
    }
}
