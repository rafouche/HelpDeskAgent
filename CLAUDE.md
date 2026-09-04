# Altec Halo Response Agent — Project Memory

Read this in full before making changes. It captures not just what the system does
but *why* it's built this way — most of these decisions came from a back-and-forth
with the person who owns this (Roger, Altec Solutions Group), so don't casually
"improve" something below without understanding the reasoning first.

## What this is
A Claude Code headless agent, scheduled via Windows Task Scheduler on a Windows
Server, running 24/7. Every cycle (~10 min) it pulls open Halo tickets, works
multiple at once (sequentially within one run — not parallel processes; see
Known limitations), tries to resolve easy ones directly, and escalates the rest.
It's a **replacement for a Cloudflare Workers annotation-only bot** (`ai-triage-worker`
in Roger's other MCP-servers project) — this one actually responds to and closes
tickets, not just annotates them.

Since v2.0.0, each cycle is a **multi-stage pipeline**, not one `claude -p` call
that handles every ticket itself: a cheap classifier call tags each candidate
ticket with a complexity tier, then one resolver call per ticket does the
actual work, on a model chosen by that ticket's tier. Since v2.1.0, a third,
even cheaper stage runs first: an ID resolver that resolves Halo's team/status/
priority/agent names to IDs once per cycle and hands them to both the
classifier and every resolver call, instead of each of those redundantly
re-resolving the same fixed lookups from scratch. See "Two-stage
classifier/resolver pipeline" and "No IDs anywhere in config.json" below for
the full rationale.

## Files
- `config.json` — everything a tech should be able to change without touching a
  script: business hours, on-call contact, Halo team/status/priority **names**
  (never IDs — see "No IDs anywhere in config.json" below), remediation
  whitelist, Hudu fix folder, per-tier model/effort settings.
- `id-resolver-prompt.md` — stage 0: resolve config.json's Halo names to IDs.
  Run once per cycle, read-only, cheap model, before the classifier - skipped
  entirely on a cache hit (see `resolved-ids-cache.json` below).
- `resolved-ids-cache.json` — gitignored, generated at runtime. Caches stage 0's
  last successful result plus the exact `halo.*` names that produced it, so a
  cycle can skip stage 0 entirely when config.json hasn't changed and the cache
  isn't older than `claude.id_cache_max_age_hours`. Safe to delete any time to
  force a fresh resolution next run.
- `classifier-prompt.md` — stage 1: find candidate tickets, tag each with a tier.
  Run once per cycle, read-only, cheap model.
- `resolver-prompt.md` — stage 2: investigate/resolve *one* specific ticket. Run
  fresh once per classified ticket per cycle, full tool set, model chosen by tier.
- `Invoke-HaloResponseAgent.ps1` — computes business-hours context, runs the ID
  resolver call, then the classifier call, then loops the resolver call once
  per classified ticket, logs everything.
- `Register-HaloResponseAgentTask.ps1` — one-time Task Scheduler setup.
- `Show-AgentLog.ps1` — pretty-prints a cycle's log entry (ID resolution
  section, classifier section, one section per resolved ticket, a cost
  summary) instead of raw JSON.
- `README.md` — setup + how-to-extend instructions for a human.

## Design decisions and why

**Two-stage classifier/resolver pipeline (v2.0.0).** Every cycle used to be one
`claude -p` call (Opus, full tool set, adaptive thinking) that pulled every
candidate ticket itself and handled all of them in one long agentic session —
a real 75-ticket/7-candidate cycle at those settings cost $4.13 over 62 turns,
most of it full-tool-loop reasoning applied uniformly regardless of how simple
a given ticket turned out to be. Roger asked for this to split into two calls:
a cheap **classifier** (`classifier-prompt.md`, Haiku, read-only, no MCP tools
beyond Halo lookups) that tags each candidate ticket with a complexity tier
(`TRIVIAL`, `TRIVIAL_UNCERTAIN`, `MEDIUM`, `COMPLEX`), then one **resolver**
call per ticket (`resolver-prompt.md`, full tool set) on a model selected by
that tier via `config.json`'s `claude.resolver_model_*` fields — so only
tickets that actually need a capable model and a full tool loop pay for one.

The literal spec Roger gave was written for raw Anthropic Messages API calls
(a system prompt parameter, `cache_control`/`ttl`, hand-rolled tool execution)
— this system runs on the Claude Code CLI (`claude -p`) instead, which has its
own internal agent loop and MCP integration and doesn't expose that surface.
Adapted to fit: two `claude -p` calls per cycle (not per literal "system
prompt"), model selection via `--model`/`--effort` flags (confirmed against
current Claude Code CLI docs) instead of raw API parameters, no manual
`cache_control` (Claude Code manages its own caching, not exposed to the
invoking script).

One deliberate simplification: the spec said a `TRIVIAL_UNCERTAIN` ticket
should "skip this call entirely — just post a reply asking for the missing
info and stop," implying a third, distinct code path. Since *something* still
has to post that reply, and PowerShell has no direct Halo access outside of a
`claude -p` call, `TRIVIAL_UNCERTAIN` instead gets the ordinary resolver call
at the cheapest tier's model, with `resolver-prompt.md` instructed to skip
investigation and just ask for the specific missing piece — same cost profile
as "skip it," one fewer code path to maintain.

**Cost/token logging per cycle.** `Invoke-HaloResponseAgent.ps1` writes a
`CYCLE SUMMARY` JSON block after every cycle: `classifier_cost_usd`,
`resolver_cost_usd`, `total_cost_usd`, and a per-ticket `{ticket_id, tier,
model, cost_usd}` array — so a config change to `claude.effort` or a
`resolver_model_*` field can be verified against real numbers (via
`Show-AgentLog.ps1`) rather than assumed to have helped.

**No IDs anywhere in config.json.** Every Halo/Ninja/etc. reference in config is a
plain name exactly as it appears in the actual tool (e.g. `"Help Desk"`, not team
ID `1`). Reason: a tech editing config shouldn't need to hunt down a numeric ID,
and config can't silently drift out of sync with Halo if it never stores IDs in
the first place. Since v2.1.0, a dedicated ID resolver stage (see below) resolves
Halo's team/status/priority/agent names to IDs once per cycle and hands the
numbers to the classifier and every resolver call - `mcp__Ninja__list_automation_scripts`
is the one lookup still done per-ticket by the resolver itself, since which
script (if any) applies depends on the specific ticket, not a fixed value for
the whole run. Since v2.2.0, that resolution is itself cached to
`resolved-ids-cache.json` (gitignored - it's runtime state for one specific
Halo instance, not source), keyed on the exact `halo.*` name values that
produced it, so editing any of those names invalidates the cache automatically;
`claude.id_cache_max_age_hours` forces a fresh resolution periodically anyway,
in case Halo itself changes without config.json changing.

**Static tool allowlist vs. config.json — different change frequency.** The
PowerShell script's `$resolverTools`/`$classifierTools` lists are the outer
fence (what each stage is technically capable of calling); `config.json`'s
`remediation_whitelist` is what the resolver is actually *permitted* to use
its tools for on a given ticket. Adding a new instance of an existing action
type (another NinjaOne script, another M365 action) only needs a config.json
entry. Adding a brand-new system (e.g. 3CX) needs a new labeled block in
`$resolverTools` — there's already an empty placeholder block for 3CX. The
classifier's tool list almost never changes; it only ever needs enough Halo
read access to find and skim candidate tickets.

**Escalation = status change only.** By explicit instruction: escalating a ticket
changes Halo status to `follow_up_status_name` ("Follow Up Needed" — there is no
"Escalated" status in this Halo instance and none should be created) and nothing
else. No team reassignment. The client is never told or shown the word "escalated" —
client-facing language is along the lines of "I'm looping in our team," never more
specific than that.

**Ticket ownership via assignment — implemented.** A dedicated Halo agent account
(name configurable via `config.json`'s `halo.agent_username`; currently a temporary
account, "Artie Fischel") is who the agent claims tickets as. It works tickets that
are either unassigned or already assigned to that name, self-assigning any unassigned
one it picks up (`mcp__Halo__list_agents` resolves the name to an `agent_id`, same
no-IDs-in-config pattern as everything else). On escalation (`follow_up_status_name`),
it unassigns itself and resets the team to `help_desk_team_name` in the same
`update_ticket` call, so the ticket is visibly free for a human on the queue rather
than sitting under the bot's name. **Not yet built:** a human reassigning a ticket
back to the agent's account for wrap-up/closure after fixing the underlying issue —
the agent would need to recognize that case as "confirm and close," not
"re-diagnose from scratch."

**Human approval mode (`-RequireApproval`, v2.8.0) — the rollout stage between
`-WhatIf` and unsupervised live.** Roger's own framing: run live, but hold every
client-facing reply and remediation action in a private note first, flip a
status to mark it waiting, and only actually send/run it once a human flips the
status to approved on a later cycle. Design decisions worth recording:
- **Two new Halo statuses, not a new mechanism.** `ai_waiting_approval_status_name`/
  `ai_approved_status_name` in `config.json`'s `halo` section, resolved the same
  way as every other status name (same `list_statuses` call, no extra tool
  call) - blank unless you're using the switch, and a hard PS1-level error if
  the switch is passed while either is blank or unresolved. The "approve"
  action is just a human changing a ticket's status in Halo directly - no new
  UI, no new tool, nothing to build there.
- **Scope of the gate, decided with Roger rather than assumed:** remediation
  actions (password reset, reboot, script run) wait for approval too, not just
  the reply text - "Both wait" was the explicit choice over "correspondence
  only." The one exception is the brief emergency on-call acknowledgment,
  which still sends immediately since on-call is already being paged at that
  same moment - "Send immediately" was the explicit choice there, over holding
  literally every message including that one.
- **Per-ticket tool selection, not per-cycle.** Before this version, a
  cycle's resolver tool list was one fixed thing for every ticket (full, or
  -WhatIf-stripped). This version introduces the first *per-ticket* tool
  selection: a ticket classified `APPROVED` gets the full mutating toolset (it
  needs to actually execute what was approved); every other ticket under
  `-RequireApproval` gets remediation-mutating tools (CIPP reset/enable, Ninja
  reboot/run-script) physically removed - real defense in depth, not just a
  prompt instruction, so a reasoning mistake fails loudly (permission denial)
  rather than quietly executing.
- **Why `update_ticket` itself can't be stripped for a non-approved ticket:**
  the draft-mode bookkeeping (writing the private note, setting
  `ai_waiting_approval_status_name`, unassigning) is ITSELF a real,
  legitimate `update_ticket` call that must succeed - the same tool a real
  client-facing reply would also use. Allowlists work at tool-name
  granularity, not call-content granularity, so there's no way to permit "a
  private note" but block "a public reply" via the allowlist alone; that
  distinction is enforced by the prompt (the approval banner), at the same
  trust level as every other judgment call this system already makes
  unsupervised (ticket-ownership checks, remediation-whitelist compliance).
  Worth knowing plainly, not glossing over: this one piece is not physically
  guaranteed the way the remediation-tool stripping is.
- **No delete-note tool exists - confirmed directly, not assumed.**
  `mcp__Halo__update_ticket`'s real schema (agent_id/note/note_is_private/
  status_id/team_id/ticket_id) can only ADD a note, never edit or delete one -
  same fact already established when the priority/impact/urgency gap was
  investigated. Roger's original ask ("delete the private note") therefore
  becomes "add a new note marking the old draft historical, right after
  sending the real reply" - the record stays unambiguous for a human reading
  the ticket later, without a delete that isn't actually possible.
- **The two-phase note protocol is plain-text, not a structured API.** A
  first-pass draft note is a private note starting with the literal line
  `[DRAFT PENDING APPROVAL]`, followed by the exact reply text, then
  `[INTENDED STATUS] <name>`, `[INTENDED ASSIGNMENT] keep|unassign`, and
  `[INTENDED REMEDIATION] none|<description>` lines - the only channel
  connecting the two resolver calls (first-pass and approval-pass) is this
  note's text, since they're separate `claude -p` sessions with no shared
  memory. The approval-pass resolver is told to stop and flag rather than
  guess if it finds zero or more than one such note, or can't tell exactly
  what a recorded remediation action meant.
- **`classifier-prompt.md`/`resolver-prompt.md` themselves are unchanged.**
  The whole feature is an "approval banner" built at runtime in
  `Invoke-HaloResponseAgent.ps1` from Stage 0's resolved IDs and prepended to
  each prompt only when `-RequireApproval` is passed - same pattern as the
  existing `-WhatIf` simulation banner. A run without the switch sends the
  exact same prompt bytes as before this version existed.

**Cross-client fix history + Hudu documentation.** Before diagnosing anything
non-trivial, the agent searches past tickets *org-wide* (`mcp__Halo__list_tickets`
with a `search` term and no `client_id`) plus Halo KB and the Hudu `AI-Documented Fixes`
folder (single shared folder, not per-client) for a similar already-solved issue.
No hard cap on how many different fixes it tries across ticket cycles before
escalating — judgment-based — but client frustration always overrides and forces
escalation regardless of remaining ideas. A fix that works and wasn't already
documented gets written up in that Hudu folder as a concise internal SOP. This is
the one place the agent writes outside Halo, and it's deliberately *not* gated by
the remediation whitelist — it only ever writes internal documentation, never
touches a client's live systems.

**Remediation whitelist is deliberately narrow and config-driven.** Everything
outside Halo defaults to read-only. An action is only allowed if it's explicitly
listed in `config.json`'s `remediation_whitelist` (plain name + plain-English
`requires` condition) — start narrow, expand deliberately, never let the agent
freelance a remediation just because it seems obviously safe.

**Business hours are the service-plan boundary, not just an operating window.**
8am–5pm Central, Mon–Fri are the hours actual ticket responses are included in the
client's service plan. Outside that window: no live client-facing reply for
non-emergencies (the agent still investigates quietly and leaves a ready-to-send
internal note for the morning), and a genuine system-down emergency triggers an
immediate on-call notification (email + SMS via an existing email-to-SMS gateway,
contact info in config) plus one brief client acknowledgment — never a technical
explanation.

**Branding: this is "Altec," never a named vendor tool.** The agent never mentions
Huntress, NinjaOne, UniFi, Meraki, CIPP, or any other underlying tool to a client —
matches Roger's standing preference that Altec is the service provider client-facing,
regardless of which vendor tool actually did the work.

**Compliance client exclusion (v2.9.0) — a real boundary, with a real, disclosed
limit.** `config.json`'s `compliance.excluded_client_names` came directly out of
a PCI/HIPAA/GLBA/SOX conversation with Roger: some of Altec's clients (a
dealership, a medical practice, a CPA firm, anything rolling up to a public
parent company) may carry data types this pipeline shouldn't be routing to a
third-party AI API at all, at least not without a lot more contractual/legal
groundwork than exists today. Resolved the same way as team/status/agent names —
one `mcp__Halo__list_clients` call in Stage 0 — but unlike every other optional
field in this pipeline, an unresolved name here aborts the WHOLE cycle
unconditionally (not gated behind `-RequireApproval` or any switch): silently
under-protecting a client is exactly the failure mode this feature exists to
prevent, so it fails closed rather than proceeding on a guess.

**The honest limit, checked before building rather than assumed:**
`mcp__Halo__list_tickets` only supports an INCLUDE filter for a single
`client_id` — there's no exclude filter and no bulk multi-client filter. That
means the classifier's account-wide ticket scan (its whole design already
depends on reading every open ticket to build a candidate list — see "Two-stage
classifier/resolver pipeline" above) still sees an excluded client's ticket
subject/summary line every cycle, as an unavoidable side effect of how it
works today. What this control DOES reliably stop — checked as literally the
first thing in both `classifier-prompt.md` (drop from candidacy immediately,
before any other filter) and `resolver-prompt.md` (a check ahead of even
"Claim the ticket," overriding every other exception in the document,
including the emergency on-call-acknowledgment carve-out under
`-RequireApproval`) — is the deep investigation: full ticket body/notes, and
every downstream Ninja/Huntress/CIPP/Meraki/UniFi tool call, plus any reply or
action. That's a meaningfully smaller exposure than the full pipeline, but not
zero, and `config.json`'s own `compliance._comment` says so plainly rather than
implying a stronger guarantee than what's actually true. This is prompt-level
enforcement (same trust tier as this system's other safety rules — ticket-
ownership checks, remediation-whitelist compliance), not a physical
tool-removal like `-WhatIf`'s: there's no tool-allowlist mechanism that can
filter by *ticket content*, only by tool name, so nothing at the code level
can stop the classifier from reading a ticket's subject line short of Halo's
own API gaining an exclude filter, or a non-AI pre-filter layer sitting in
front of the classifier - see "Known gaps" for what would actually close this
the rest of the way.

## Multi-ticket handling
One classifier call finds every candidate ticket for the cycle; PowerShell then
loops the resolver call once per ticket, one `claude -p` process at a time, not
concurrent — same sequential-not-parallel behavior as the original single-call
design, just as N+1 separate processes instead of one process handling N
tickets internally. Fine at current volume. If ticket volume ever grows enough
that one cycle doesn't finish within the scheduling interval or the task's
execution time limit, that's a real architecture change (genuine parallelism —
multiple resolver processes in flight at once, not just sequential), not a
config tweak. Not worth building preemptively.

## In-flight / not-yet-built
- **CIPP MCP migration — NOT actually cut over yet, despite an earlier note here
  claiming otherwise.** `claude mcp list` on the production server still shows
  `CIPP` pointed at `cipp-mcp.young-math-a33a.workers.dev` — the original,
  supposedly-retired custom Cloudflare Worker, not CIPP-ng's built-in MCP
  (`cipp.altecusa.com`). Roger chose to keep using the old worker for now rather
  than block on registering the new one. When CIPP-ng is registered on that
  machine and you're ready to cut over: register it under a clear name (e.g.
  `claude mcp add CIPPNG https://cipp.altecusa.com/... ...`), re-verify its tool
  names match (`get_user`, `healthcheck`, `reset_user_password`, `enable_user`,
  `cipp_api_get` — these carried over unchanged from the old worker as far as
  could be verified from a separate Claude session hitting the CIPP-ng instance
  directly, but re-check against production), then update the `mcp__CIPP__...`
  entries in `Invoke-HaloResponseAgent.ps1` and `resolver-prompt.md` to the new
  server name.
- **Email/bounce diagnostics**: the CIPP server (old worker, see above) has no
  dedicated message-trace tool, but its generic `cipp_api_get` wrapper covers
  CIPP's native Message Trace via `endpoint: "ListMessageTrace"` — wired into
  `resolver-prompt.md`. Falls back to finding the NDR in the user's own mailbox
  (`outlook_email_search`) when that doesn't turn up enough — though see the
  Microsoft365 gap below, that fallback doesn't work either until it's registered.
- **3CX troubleshooting**: planned, not built. Per-client 3CX server API access is
  needed (multi-tenant, matching the 3CX Cloudflare Worker target already planned
  in Roger's broader MCP-servers project). Natural design: store each client's 3CX
  connection details in Hudu (Roger already documents client infra there), and have
  the agent look it up by company name at runtime — same "no IDs, look it up by
  name" pattern as everything else, rather than a new config table.
- **Ticket-assignment ownership workflow** (see above) — designed, not implemented.

## MCP server setup status on the production machine (as of the last `claude mcp list`)
- **Connected and working:** `Halo`, `Meraki`, `CIPP` (old worker — see above),
  `Ninja`, `Unifi`.
- **Registered but "Needs authentication":** `Huntress`, `HUDU` (note the ALL-CAPS
  name — that's the exact registered name, and the `mcp__HUDU__...` prefix must
  match it exactly, case-sensitive). These are OAuth-based remote MCP servers; the
  one-time login can't complete unattended. Run, from a machine with a browser
  (or via `ssh -t` into the server so the redirect URL can be pasted back):
  `claude mcp login Huntress --no-browser` and `claude mcp login HUDU --no-browser`.
  Credentials are stored per-machine (Windows Credential Manager) and can't be
  copied from another machine — this has to run on the production server itself.
- **Not registered at all:** `Microsoft365` (or however you name it — just avoid
  spaces, since Claude Code's `mcp__<server>__<tool>` prefix needs an exact,
  unambiguous match). Until it's added via `claude mcp add`, on-call email
  notifications and the NDR bounce-diagnosis fallback are both silent no-ops.

## Known limitations
- **Console/log encoding (fixed).** Windows PowerShell 5.1 captured `claude`'s
  UTF-8 output (em dashes, curly quotes, emoji) using the console's legacy OEM
  codepage by default, permanently mangling it in the log file (e.g. an em dash
  became "GÇö"). `Invoke-HaloResponseAgent.ps1` now sets
  `[Console]::OutputEncoding`/`$OutputEncoding` to UTF-8 before invoking `claude`
  and writes the log with `-Encoding UTF8`. Logs from before this fix have
  already-corrupted text that can't be recovered by re-reading them differently.
- **Per-cycle cost.** A real 75-ticket/7-candidate cycle cost $4.13 under the
  original single-call design (`claude-opus-5`, effort `high`, adaptive
  thinking, 62 turns) — see "Two-stage classifier/resolver pipeline" above for
  why that became two calls instead. Under the current two-stage pipeline (v2.6+,
  tiered models, effort `low`, ID-resolution caching), a real 6-candidate
  `-WhatIf` cycle cost $2.53 (classifier $0.16, resolver $2.38 across 2
  TRIVIAL/MEDIUM/COMPLEX tickets each). `config.json`'s `claude.effort` and
  `claude.resolver_model_*`/`classifier_model` are the remaining levers — see
  README's "Reducing per-run cost". Not wired in: `--fallback-model`
  (reliability, not cost — doesn't trigger on rate limits) and lowering the
  Task Scheduler run frequency (cuts total daily cost, trades off response
  latency).
  **Repeated `-WhatIf` testing against the same live backlog is not
  representative of production cost and inflates the testing bill**: because
  simulation mode never actually claims/resolves a ticket in real Halo, the
  same unassigned tickets stay candidates and get fully re-investigated from
  scratch on every single test run - the classifier-prompt.md logic that
  skips an already-claimed ticket with nothing new to act on never gets a
  chance to kick in during testing, since nothing is ever really claimed. In
  production this doesn't happen the same way (a resolved/claimed ticket
  drops out of future candidate lists for real) - so don't extrapolate a
  cost-per-day from `-WhatIf` runs against a static backlog without
  accounting for this.
- Sequential ticket processing within a cycle, not parallel (see above).
- `on_call.primary.email` in config.json is still a placeholder — fill in before
  relying on emergency escalation. `text_email` may be legitimately left blank (no
  SMS on-call set up yet) — the agent skips the text and still sends email in that
  case, this is expected.
- **Tool-name syntax bug that silently broke every MCP call from day one (fixed):**
  the static allowlist and `agent-prompt.md` (the single-call design's prompt,
  later split into `classifier-prompt.md`/`resolver-prompt.md` — see "Two-stage
  classifier/resolver pipeline" above) used a `Server:tool_name` naming
  convention that Claude Code never actually recognizes — it matches MCP tools as
  `mcp__<ServerName>__<tool>`, where `ServerName` is whatever exact name (case-
  sensitive) was used with `claude mcp add` on that machine. With
  `--permission-mode dontAsk`, an unmatched tool name is denied *silently*, so
  every scheduled run before this fix only ever had the built-in `Read` tool
  working — it never touched Halo, Ninja, or anything else, and never logged an
  error saying so. Confirmed and fixed by running `-WhatIf` directly against the
  production server and reading its own diagnosis of the permission denials in the
  log. If you add a new system's tools to the allowlist later, use the
  `mcp__<ServerName>__<tool>` form from the start and confirm the server name via
  `claude mcp list` on the actual machine — don't assume it matches the vendor's
  display name.
- **Credential/MCP-registration account scoping — same silent-failure shape as
  the naming bug above, different root cause (fixed, found before it shipped).**
  Raised as a direct question ("will the SYSTEM-run scheduled task still have
  API access") and verified against Claude Code's own docs rather than
  assumed, since this project has already been burned once by an assumption in
  this exact area. Two separate things, both scoped per-Windows-account by
  default:
  1. **Credentials.** `claude setup-token`/`/login` write to
     `%USERPROFILE%\.claude\.credentials.json`, restricted to whichever
     account is logged in when you run them. `Register-HaloResponseAgentTask.ps1`
     runs the task as `SYSTEM` — a different account with its own empty
     profile, which would see none of that. Fix: `ANTHROPIC_API_KEY` (or
     `CLAUDE_CODE_OAUTH_TOKEN` if using a subscription token) set with
     `setx ... /M` - the `/M` is not optional, plain `setx` only sets a
     per-user variable that `SYSTEM` never sees either.
  2. **MCP server registration.** `claude mcp add ... -s user` (what this
     README used to say) registers a server only for the account you're
     logged in as, in that account's own `~/.claude.json` - same account-
     scoping problem, one layer down. Fix: `-s project`, which writes
     `.mcp.json` into this folder instead - a plain file, not tied to any
     account. That alone isn't sufficient either: Task Scheduler gives a
     process no working directory by default (lands in
     `%SystemRoot%\System32`), and project-scoped MCP config is discovered
     from the current directory, not from the script's own location -
     `Register-HaloResponseAgentTask.ps1` now sets the scheduled task's
     `-WorkingDirectory` explicitly for exactly this reason. Miss either half
     and the result is identical to the original naming bug: the task runs,
     reports no error, and silently has zero working tools. `.mcp.json` holds
     real credentials in plain text and is now in `.gitignore`.
  Neither of these would show up in any interactive testing done as an admin
  user (`-WhatIf` runs by hand use that account's own credentials/MCP config
  regardless of what the scheduled task would see) - only an actual scheduled
  firing, running as `SYSTEM`, exposes the gap. Confirm both are correct by
  triggering the registered task manually once (Task Scheduler ->
  right-click -> Run) rather than trusting an interactive `-WhatIf` run alone.

## Known gaps and future work

Found by directly querying the live Halo instance (`list_ticket_types`,
`list_priorities`, `get_ticket`, `update_ticket`'s real schema) rather than
assuming from config.json alone:

- **`compliance.excluded_client_names` (v2.9.0) cannot stop the classifier's
  account-wide `list_tickets` scan from seeing an excluded client's ticket
  subject/summary line every cycle** - confirmed directly:
  `mcp__Halo__list_tickets` supports only an INCLUDE filter for a single
  `client_id`, no exclude filter, no bulk/multi-client filter. Closing this
  the rest of the way needs one of: (a) the Halo MCP server adding an exclude-
  filter or "list tickets NOT in these clients" capability to `list_tickets`
  (out of this repo's control, same as the priority/urgency/contact-creation
  gaps above); or (b) a non-AI pre-filter sitting in front of the classifier
  entirely - e.g. PowerShell itself calling Halo's REST API directly (bypassing
  the MCP server) to fetch and filter the ticket list before any of it reaches
  a `claude -p` call - a materially bigger architecture change than anything
  else in this file, since PS1 currently has no independent Halo API client at
  all. Worth real design discussion before attempting, not a quick patch.

- **Ticket type and impact are now used for classification (v2.4.0).**
  `list_tickets`/`get_ticket` already return `tickettype_id`, `impact`, and
  `urgency` inline - no new tool calls needed. The ID resolver (Stage 0) calls
  `mcp__Halo__list_ticket_types` once and builds an id->name lookup table
  (`{{TICKET_TYPE_NAMES}}`, same pattern as team/status/agent), and both
  `classifier-prompt.md` and `resolver-prompt.md` now treat `impact: 1`
  ("Company Wide") as a second, independent signal toward COMPLEX/EMERGENCY
  CANDIDATE, plus give judgment guidance on machine-generated types (Alert,
  Huntress) and HR/admin-coordination types (New Starter/Leaver/Administrator
  Rights/Hardware Collection Request). This is prompt-level judgment guidance,
  not a hard rule engine - there's no per-type routing table, and impact/type
  don't gate candidacy, only inform the tier the classifier/resolver already
  judge from wording. A finer-grained design (e.g. a per-type default
  investigation path) is still open if the current guidance doesn't prove
  sufficient in practice.
- **Halo has (at least) two separate severity scales - priority and urgency -
  and they are NOT the same list.** `list_priorities` returns rows keyed by
  both a GUID (`id`) and a small integer (`priorityid`, 1-4: top tier/High/
  Medium/Low), each also carrying an `slaid` (this instance has 3 SLA
  policies) - confirmed "Urgent" (slaid 2), "Critical" (slaid 1), and "Critial"
  (slaid 3, a typo that's genuinely in Halo, not a config mistake) are all
  `priorityid: 1`, the same tier under three different SLAs. Separately, the
  user confirmed the actual urgency scale visible in Halo's UI for the
  "Incident" ticket type is Low/Normal/Escalated/Critical - a different field
  (`urgency`, not `priority`/`priority_id`) with names that don't match
  `list_priorities` at all. `list_ticket_types` doesn't expose a per-type
  urgency matrix either, and no `list_urgencies`-style tool exists - **there is
  currently no way to independently verify or resolve urgency values through
  any available tool.** `config.json`'s `halo.urgent_priority_names` (present
  since this repo's first commit, matched against `list_priorities` in v2.3.0
  but never actually verified against the real urgency scale it was likely
  meant to represent) was removed entirely in v2.5.0 rather than left in place
  unverified - see v2.5.0 above for the reasoning. If a priority- or urgency-
  setting capability is ever added, resolve `priorityid` (not the GUID `id`)
  for priority; urgency's real value list still needs to be found (Halo admin
  UI export, a different endpoint, or asking the user to supply it directly)
  before it can be resolved by name at all.
- **There is currently no tool that can set a ticket's priority, impact,
  urgency, or ticket type at all.** `mcp__Halo__update_ticket`'s real parameter
  schema is only `agent_id`, `note`, `note_is_private`, `status_id`, `team_id`,
  `ticket_id` - confirmed directly, not assumed. This is why the emergency-
  escalation section of `resolver-prompt.md` can only flag the need for an
  urgent priority in an internal note rather than actually set one - the
  impact/type awareness added in v2.4.0 informs the tier/urgency judgment, it
  doesn't let the resolver act on impact/priority/type directly. Closing this
  gap needs either the Halo MCP server exposing a priority/impact/urgency/type
  parameter on `update_ticket` (out of this repo's control - that server is a
  separate project) or a different tool entirely.
- **Halo already computes its own AI suggestions on every ticket** -
  `ai_suggested_priority`, `ai_suggested_urgency`, `ai_suggested_impact`, and
  `ai_suggested_type` are real fields returned by `get_ticket`, still unused by
  this pipeline even after v2.4.0. Worth considering as an additional signal
  for the classifier (or a sanity check against its own judgment) - deferred
  since it's a distinct design question from "does impact/type inform tier at
  all," which v2.4.0 already answers.
- **No tool exists to create a Halo contact/user, or to relink a ticket to a
  different one** (found v2.8.1) - confirmed directly by checking the real
  tool list, not assumed: no `create_contact`/`create_user`-style tool exists
  anywhere in this toolset, and `mcp__Halo__update_ticket`'s real schema
  (`agent_id`/`note`/`note_is_private`/`status_id`/`team_id`/`ticket_id`) has
  no user/contact parameter at all. Real scenario this blocks: a new employee
  at an existing client company emails in before their contact record exists
  in Halo, so the ticket has no contact properly linked even though the
  company name, the person's name, and their email are all sitting in the
  ticket body. `resolver-prompt.md` now has the agent flag this with a
  `"NEEDS CONTACT CREATED - "` internal note carrying those three pieces of
  info, so a human can create the contact and relink the ticket in under a
  minute, rather than attempt something no available tool can do. Closing
  this for real needs the Halo MCP server (`halopsa-mcp`, a separate project -
  see the CIPP/Huntress tool-gap entries elsewhere in this file for how
  responsive that project's maintainer has been) to add a contact-creation
  tool and either a user/contact parameter on `update_ticket` or a dedicated
  "relink ticket to contact" tool.
- **Halo has its own ticket-triage workflow step that can silently swallow a
  note/assignment write** (found v2.8.1, via real `-WhatIf`/`-RequireApproval`
  testing) - distinct from this pipeline's own classifier/tier terminology,
  and distinct from a ticket's status field. On an untriaged ticket,
  `update_ticket` accepts a `note`/`agent_id`/`team_id` change and reports
  success, but the change never actually lands - only `status_id` reliably
  takes effect. No tool here can trigger Halo's triage directly, and no field
  on a ticket exposes whether it's been triaged, so this can't be detected in
  advance, only after the fact by re-fetching and comparing.
  `resolver-prompt.md` now requires exactly that (re-fetch and confirm after
  every note/assignment write, one retry via a status-only update, then
  stop-and-flag for human triage if it still doesn't land) - a
  detection/mitigation fix, not a root-cause one, since nothing available can
  drive or confirm Halo's real triage mechanism from here. Worth watching
  whether the "retry with a status-only update" step actually helps in
  practice or is just a wasted call - it's an untested hypothesis built on
  the one thing that IS confirmed (status changes take effect pre-triage),
  not a confirmed fix in its own right.
- **CORRECTED - "no tool for ticket notes" was wrong; the bullet that used to
  be here is superseded.** It said `get_ticket_time_entries`/`list_time_entries`
  were "the wrong data entirely (billable labor time, not message content) -
  confirmed via their own schemas/descriptions." That was a real mistake, not
  just an outdated finding: it was inferred from the tools' name/description
  text, not from an actual query - I have no way to call the live Halo MCP
  server from where that conclusion was written, only `ToolSearch` schema
  lookups. A separate session later pulled `halopsa-mcp` itself, cross-checked
  every endpoint against HaloPSA's live OpenAPI spec, and found
  `get_ticket_time_entries`/`list_time_entries` were pointed at `/Action`
  (404 on every call - matches what ticket 21571's run actually observed)
  instead of the real path `/Actions`, HaloPSA's ticket conversation/notes
  endpoint (`conversationonly`/`excludeprivate`/`includehtmlnote`/
  `includehtmlemail` params). Fixed at the source and verified live against
  that same ticket 21571: 7 real actions came back, including a private note
  with full text, author, and timestamp. Four other tools had the same class
  of bug (`list_contacts`/`get_contact` -> `/Users` not `/Customer`;
  `list_opportunities`/`get_opportunity` -> `/Opportunities` not `/Opportunity`;
  `list_contracts`/`get_contract` -> `/ClientContract` not `/Contract`;
  `list_software_licences` -> `/SoftwareLicence` not `/SoftwareLicences`) -
  none of those were ever added to this repo's allowlist, so no action needed
  on them here beyond noting they're fixed. **Lesson layered on top of the
  v2.5.0/v2.6.0 ones**: "confirmed via its own schema" is not the same claim
  as "confirmed by calling it" - say which one actually happened, because a
  tool's name/description can be simply wrong about what it does, not just
  silent about it. `get_ticket_time_entries` was already in `$resolverTools`
  before and after this correction (see `Invoke-HaloResponseAgent.ps1`) - it
  needed no allowlist change, only a fixed server behind it. `resolver-prompt.md`
  step 1 ("Read full history... notes/time entries") already told the
  resolver to use it - the instruction was right all along; only the tool
  underneath it was broken.
