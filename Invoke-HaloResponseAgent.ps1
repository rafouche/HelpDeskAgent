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
$isBusinessDay = $config.business_hours.days -contains $now.DayOfWeek.ToString()
$startTod = [TimeSpan]::Parse($config.business_hours.start)
$endTod   = [TimeSpan]::Parse($config.business_hours.end)
$isBusinessHours = $isBusinessDay -and ($now.TimeOfDay -ge $startTod) -and ($now.TimeOfDay -le $endTod)
$nowText = $now.ToString("dddd, MMMM d, yyyy h:mm tt")

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
    "mcp__Halo__update_ticket", "mcp__Halo__update_ticket_draft_only", "mcp__Halo__create_contact",
    "mcp__Microsoft365__outlook_send_mail",
    "mcp__CIPP__reset_user_password", "mcp__CIPP__enable_user",
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device"
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
    "mcp__Ninja__reboot_device", "mcp__Ninja__run_script_on_device"
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
$resolverToolsApprovalStripped = @($resolverToolsFull | Where-Object { ($remediationMutatingTools -notcontains $_) -and ($_ -ne "mcp__Halo__update_ticket") }) + @("mcp__Halo__update_ticket_draft_only")

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
$classifierEffort = Get-EffortForConfig -PerTierValue $config.claude.classifier_effort
$effortForTier = @{
    "TRIVIAL"           = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "TRIVIAL_UNCERTAIN" = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "MEDIUM"            = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_medium
    "COMPLEX"           = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_complex
    "APPROVED"          = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
    "LEARN_FIX"         = Get-EffortForConfig -PerTierValue $config.claude.resolver_effort_trivial
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
    $claudeArgs = @(
        "-p",
        "--allowedTools", $toolsArg,
        "--disallowedTools", "Agent,Task",
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
        $trackedTicketIdsText = (@($trackedTicketIds) -join ", ")
    }

    # Same "none" rendering, same reason - see the blocked_tickets loading/
    # pruning comment above for what this list means and why it exists.
    $blockedTicketIdsText = "none"
    if ($blockedTickets.Count -gt 0) {
        $blockedTicketIdsText = (@($blockedTickets.Keys) -join ", ")
    }

    # Same "none" rendering, same reason - see the remembered_notes loading
    # comment above. Rendered as a plain bullet list (not JSON) since this is
    # meant to be read and weighed by the resolver, not parsed.
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
        -replace '\{\{WAITING_STATUS_ID\}\}', $ids.waiting_status_id `
        -replace '\{\{FOLLOWUP_STATUS_ID\}\}', $ids.followup_status_id `
        -replace '\{\{READY_FOR_AI_STATUS_ID\}\}', $readyForAiStatusIdText
    $resolverPromptTemplate = $resolverPromptTemplate `
        -replace '\{\{TEAM_ID\}\}', $ids.team_id `
        -replace '\{\{AGENT_ID\}\}', $ids.agent_id `
        -replace '\{\{TICKET_TYPE_NAMES\}\}', $ticketTypeNamesText `
        -replace '\{\{EXCLUDED_CLIENT_IDS\}\}', $excludedClientIdsText `
        -replace '\{\{REMEMBERED_NOTES\}\}', $rememberedNotesText `
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
            "   who it's assigned to. **If nothing has happened yet** (your own",
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
            "Skip any ticket ID in calls 5-6 that's already present in calls 1-4's",
            "results, so it isn't listed twice. Every other candidate-selection/tiering",
            "rule in this document still applies as normal to every other ticket.",
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
            "   and find the ONE private note starting with the exact line",
            "   `"[DRAFT PENDING APPROVAL]`". If you find zero or more than one, stop -",
            "   add an internal note flagging the mismatch and do nothing else; don't",
            "   guess which draft is the real one.",
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
            "5. Post the approved text from step 2 as a real, public, client-facing reply",
            "   (mcp__Halo__update_ticket, note_is_private: false AND send_email: true AND",
            "   verify: true - note_is_private alone does not email the client, see",
            "   resolver-prompt.md's `"Sending a real, client-facing reply`" section) - its",
            "   own call, unchanged from what was drafted.",
            "6. There is no tool that can delete or edit an existing Halo note -",
            "   update_ticket can only add a new one. So instead of literally deleting the",
            "   draft, add one more private note in the same final call as step 7:",
            "   `"Approved and sent - see the reply above. (The draft note above is now`"",
            "   `"historical, not pending.)`" - this keeps the record unambiguous for anyone",
            "   reading the ticket later, without a delete that isn't actually possible.",
            "7. Check the ticket's current agent_id (from step 1's data, or a fresh",
            "   mcp__Halo__get_ticket if you don't already have it) before this call.",
            "   Workflow decision from Roger: never take a ticket away from a real human",
            "   tech who already holds it. If agent_id is neither 1 (Halo's real",
            "   `"Unassigned`" placeholder) nor this pipeline's own agent_id, a human tech",
            "   already holds it - most likely because they claimed it just to approve",
            "   this draft - so leave agent_id out of this call entirely; don't change it.",
            "   Otherwise (agent_id is already 1, or somehow this pipeline's own account),",
            "   include agent_id: 1 same as always - Halo's API-user account doesn't show",
            "   up in a normal licensed-user list, so a ticket left assigned to it is",
            "   invisible in the Help Desk ticket list a human looks at. Either way, in",
            "   that same call: set status to [INTENDED STATUS], team_id back to",
            "   help_desk_team_name, and verify: true. Check the response's",
            "   verified.confirmed before your summary below - don't report `"sent`" if",
            "   the reply never actually posted.",
            "8. Print your one-line summary, then as the very last line of your response",
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
            "ONE EXCEPTION: the brief EMERGENCY acknowledgment (`"We've identified this as",
            "a priority issue and are notifying our on-call engineer now`") still sends",
            "for real, immediately, exactly as the emergency section describes - on-call",
            "is already being paged at the same moment, so this one message isn't held",
            "back. Only the detailed follow-up reply (once you've actually investigated)",
            "goes through the draft/approve flow above. The on-call notification itself",
            "(email/text) is never gated either - it's an internal alert to your own team,",
            "not client correspondence.",
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
                $gate = Invoke-RestMethod -Uri $gateUri -Method Get -TimeoutSec 20
                $anyTrackedChanged = $false
                foreach ($t in @($gate.tracked)) {
                    $key = [string]$t.id
                    if (-not $t.found) { $anyTrackedChanged = $true; continue }
                    $previousSeen = $trackedLastSeen[$key]
                    if (-not $previousSeen -or $previousSeen -ne $t.last_update) { $anyTrackedChanged = $true }
                    $trackedLastSeen[$key] = $t.last_update
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
                # cycle (genuinely new), or an already-seen one's last_update
                # moved (something happened to it). A ticket simply leaving
                # this bucket (claimed for real, resolved) isn't itself a
                # signal - there's nothing left for the classifier to do
                # about it - so that alone doesn't trigger a run, only prunes
                # it from $unassignedLastSeen below.
                $anyUnassignedChanged = $false
                $seenUnassignedIds = @{}
                foreach ($u in @($gate.unassigned)) {
                    $key = [string]$u.id
                    $seenUnassignedIds[$key] = $true
                    $previousSeen = $unassignedLastSeen[$key]
                    if (-not $previousSeen -or $previousSeen -ne $u.last_update) { $anyUnassignedChanged = $true }
                    $unassignedLastSeen[$key] = $u.last_update
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

    # --- Stage 1: classify ---
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
            if ($resolverResult.Parsed -and $resolverResult.Parsed.result -match '\[CACHE:\s*(TRACK|UNTRACK|BLOCKED)\s*\]') {
                $cacheMarker = $Matches[1].ToUpperInvariant()
            }
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
                        Add-Content -Path $logFile -Value "TICKET ${ticketId}: WARNING - no [CACHE: TRACK|UNTRACK|BLOCKED] marker found in resolver output; treating as BLOCKED (backing off for blocked_ticket_retry_hours) rather than leaving it unprotected for next cycle." -Encoding UTF8
                    }
                }
            }

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
            foreach ($id in $trackedTicketIds) {
                $key = [string]$id
                if ($trackedLastSeen.ContainsKey($key)) { $prunedTrackedLastSeen[$key] = $trackedLastSeen[$key] }
            }
            $updatedCache = [PSCustomObject]@{
                resolved_ids         = $resolvedIdsForCache
                tracked_tickets      = @($trackedTicketIds | Select-Object -Unique)
                tracked_last_seen    = $prunedTrackedLastSeen
                unassigned_last_seen = $unassignedLastSeen
                blocked_tickets      = $blockedTickets
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
