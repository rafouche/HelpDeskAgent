# Altec Halo Response Agent — Project Memory

Read this in full before making changes. It captures not just what the system does
but *why* it's built this way — most of these decisions came from a back-and-forth
with the person who owns this (Roger, Altec Solutions Group), so don't casually
"improve" something below without understanding the reasoning first.

## What this is
A Claude Code headless agent, scheduled via Windows Task Scheduler on a Windows
Server, running 24/7. Every cycle (~15 min) it pulls open Halo tickets, works
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
- `Register-HaloResponseAgentTask.ps1` — one-time Task Scheduler setup for
  the ticket-processing task, and (with `-EnableAutoUpdate`) the auto-update
  task on its own separate schedule in the same run.
- `Install-Prerequisites.ps1` — one-time setup: installs the `claude` CLI
  into a shared `C:\ProgramData\npm` prefix instead of npm's per-user
  Windows default, so `SYSTEM` (and every other account) can find it, not
  just whichever account you run this as. Does not touch `git` - nothing in
  this project needs it (see "Auto-update" below).
- `Copy-McpServersToProject.ps1` — copies already-registered `-s user` MCP
  servers into this folder's `.mcp.json` (`-s project` scope), instead of
  re-typing every `claude mcp add` command by hand. Only for connectors that
  need no further interactive auth.
- `Update-HaloResponseAgent.ps1` — fetches a specific, minimal list of files
  (prompts + every `.ps1` - deliberately never `config.json`, and not
  `README.md`/`CLAUDE.md`) directly from GitHub over plain HTTPS, backing up
  and replacing only the ones that changed; logs only when something
  actually changed (or failed), and runs `Invoke-HaloResponseAgent.ps1
  -DryRun` once as a smoke test after a real update.
- `Show-AgentLog.ps1` — pretty-prints a cycle's log entry (ID resolution
  section, classifier section, one section per resolved ticket, a cost
  summary) instead of raw JSON.
- `README.md` — setup + how-to-extend instructions for a human.

## Design decisions and why

**Everything the scheduled tasks depend on is configured machine-wide, not
per-account.** Both scheduled tasks run as `SYSTEM`
(`Register-HaloResponseAgentTask.ps1`'s `New-ScheduledTaskPrincipal -UserId
"SYSTEM"`) — a separate Windows account from whichever one this gets set up
as, with its own profile, `PATH`, and environment variables. Concretely:
- `Install-Prerequisites.ps1` installs `claude` into a shared npm prefix
  (`C:\ProgramData\npm`, not npm's per-user default of `%AppData%\npm`).
- `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` are set with `setx ... /M`
  (machine-wide `HKLM`, not per-user `HKCU`).
- MCP servers are registered with `-s project` (a plain `.mcp.json` file in
  this folder, not tied to any account), and
  `Register-HaloResponseAgentTask.ps1` sets the scheduled task's
  `-WorkingDirectory` explicitly so that file actually gets discovered
  (project-scoped MCP config is resolved from the current directory, not
  from the script's own path).

None of this shows up in interactive testing done as an admin - a `-WhatIf`
run by hand uses that account's own credentials/MCP config/`PATH`
regardless of what the scheduled task would see. Confirm the real thing by
triggering the registered task manually once (Task Scheduler ->
right-click -> Run) rather than trusting an interactive `-WhatIf` run alone.
See README's "Install and authenticate Claude Code" and "Register each MCP
server" sections for the actual setup steps.

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
  `[INTENDED STATUS] <name>` and `[INTENDED REMEDIATION] none|<description>`
  lines - the only channel connecting the two resolver calls (first-pass and
  approval-pass) is this note's text, since they're separate `claude -p`
  sessions with no shared memory. The approval-pass resolver is told to stop
  and flag rather than guess if it finds zero or more than one such note, or
  can't tell exactly what a recorded remediation action meant.
  **UPDATE (v2.10.5) - there used to be an `[INTENDED ASSIGNMENT]
  keep|unassign` line here too; it's gone.** See the entry below - the
  approval-pass now always unassigns, so there's nothing left for that line
  to record.
- **`classifier-prompt.md`/`resolver-prompt.md` themselves are unchanged.**
  The whole feature is an "approval banner" built at runtime in
  `Invoke-HaloResponseAgent.ps1` from Stage 0's resolved IDs and prepended to
  each prompt only when `-RequireApproval` is passed - same pattern as the
  existing `-WhatIf` simulation banner. A run without the switch sends the
  exact same prompt bytes as before this version existed.
  **UPDATE (v2.10.5) - no longer true.** Both documents now have their own
  always-unassign end-state instructions that apply regardless of
  `-RequireApproval`; see the entry below.

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

**Personal/consumer VPN use is a hard "disconnect it, no exceptions" policy,
not a judgment call (v2.9.5).** Prompted by a real ticket worked in
`-RequireApproval` mode (most often surfaced via Huntress, but the policy
itself isn't tied to that one system - the same rule applies no matter what
surfaces it). First draft made this conditional (skip the disconnect
instruction if the ticket suggested a legitimate reason like geo-blocking) -
corrected on direct instruction: always tell them to disconnect it, full
stop. Geo-blocking/travel is a separate, additional question the resolver
asks (or reads off the ticket if already clear) so it can flag IT to set up
real remote access - that's in addition to the disconnect instruction, never
a substitute for it. This also surfaced that a ticket naming someone by
security-alert (most often Huntress, e.g. a flagged M365 sign-in) needs the
same "is this actually linked to the real person" check as a
voicemail-generated one (see "Known limitations" below for the original
ticket-re-linking entry), just matched by email instead of phone number -
the confidence-gated re-linking logic now accepts either.
**UPDATE (v2.10.8) - the disconnect instruction now waits for identity
confirmation first; see the entry below.** This entry's "always tell them
to disconnect it" was still correct advice, but it fired at the wrong
point - before ever confirming the named account owner was the one who
actually connected the VPN. A real compromise (someone else signing in as
that person) would have gotten the same "please disconnect your VPN"
reply, missing the actual security question entirely.

**Auto-update fetches specific files over plain HTTPS - no git (v2.10.0,
correcting v2.9.6-2.9.9).** This deployment is downloaded files, not a git
clone - files land on the server by downloading them individually (e.g. via
a browser), not `git clone`/`git pull`, true from the very start of this
project. Every earlier version of this feature (`Register-UpdateCheckTask.ps1`,
`Add-GitToMachinePath.ps1`, `Install-Prerequisites.ps1`'s git section) wrongly
assumed a git working copy and needed git installed and visible to `SYSTEM`
- confirmed broken in exactly that way on the real production machine, more
than once, before the root assumption itself was corrected rather than
patched again.
`Update-HaloResponseAgent.ps1` now fetches a specific, minimal file list
directly from
`https://raw.githubusercontent.com/rafouche/HelpDeskAgent/main/<file>`,
compares each one's hash against the local copy, and replaces only what
changed, backing up the previous version first - no git, no authentication
needed for a public repo. Logs only when something actually changed or
failed (same cost-conscious-logging reasoning as this pipeline's own logs),
and runs `Invoke-HaloResponseAgent.ps1 -DryRun` once as a smoke test after a
real update so a broken push is visible immediately rather than discovered
only when the next real cycle fails - a smoke test, not a rollback: the new
code stays in place either way.
**`config.json` is deliberately excluded from that list (v2.10.1, found via
a real incident) - never add it back.** An earlier version of this list did
include it, and the very first real update cycle silently overwrote a live
`on_call.primary.email` with the repo's still-placeholder value - no
backup existed yet either, so it wasn't even recoverable. `config.json` is
explicitly a per-deployment file (README has every new deployment fill in
`on_call`/`remediation_whitelist` by hand); those edits only ever exist on
that one server, never in the repo, so syncing it is never safe regardless
of what the repo's own copy currently contains. Every file this script does
sync now gets backed up before being overwritten for exactly this reason -
even a file that's supposed to stay in sync shouldn't be unrecoverable if
something ever goes wrong with a specific update.
Still its own script and its own scheduled task
(`Register-HaloResponseAgentTask.ps1 -EnableAutoUpdate`), not folded into
`Invoke-HaloResponseAgent.ps1` itself - keeps "run the pipeline" and "check
for updates" as two separately-failing concerns, so a network problem can
never abort an actual ticket-processing cycle. Also worth being explicit
about as a real tradeoff, not just a detail: this fetches whatever is on
`origin/main` unconditionally, no staging or approval step - acceptable
here because the only thing that pushes to `main` is Roger's own reviewed
changes, not a tradeoff to carry over unexamined if that ever changes.

**`create_contact` is granted when identity is independently verified, not
just claimed in ticket text (v2.10.2, real incident).** A Huntress ITDR
escalation for `mpon@battlefieldfire.gov` came back "NEEDS CONTACT VERIFIED"
instead of getting fixed, even though the resolver had already confirmed via
M365 that the account was real, active, enabled, and non-admin, and that no
matching Halo contact existed under the right client - it had done all the
verification work and then had no tool to act on it. `create_contact` had
been withheld from `$resolverTools` entirely (see the superseded "Known
gaps" entry above) on the assumption that any automatic contact creation
meant fabricating an identity from unverified text - but that blanket rule
contradicted an earlier, explicit request to create the user automatically
when the ticket already contains enough information to do so safely, and it
conflated two different risk levels: text typed into a ticket claiming an
identity, versus that same identity independently confirmed against a live
M365/CIPP account lookup.
`resolver-prompt.md`'s "unknown or wrong contact" section now has three
tiers: existing-contact re-linking (unchanged from v2.9.5), a new tier that
creates and links a contact automatically when the client is already known,
the identity is confirmed via a real system lookup (not just ticket text),
and the site is unambiguous, and the original flag-for-a-human tier for
everything else (ambiguous site, no independent verification available,
text-only claims). `mcp__Halo__create_contact` and `mcp__Halo__list_sites`
(`create_contact` requires a `site_id`, not just a `client_id`) are now in
`$resolverTools`; `create_contact` is in `$mutatingTools` (stripped under
`-WhatIf`).
**UPDATE (v2.10.4) - `create_contact` is no longer gated behind
`-RequireApproval` either; see the entry below.** It was originally also put
in `$remediationMutatingTools`, gated the same as a password reset or
reboot - a real approval-mode run (ticket #21702) showed that was the wrong
call: it made the resolver correctly verify identity and then refuse to
fix the ticket's own contact link, flagging it for a human instead of just
doing it.

**Default intervals raised, and the auto-update file list narrowed further
(v2.10.3, tuning only - no incident).** Ticket-processing raised from 10 to
15 minutes (`-IntervalMinutes`), and the update-check task from 30 to 60
minutes (`-UpdateCheckIntervalMinutes`), both in
`Register-HaloResponseAgentTask.ps1` - a new commit only ships a handful of
times a day at most, so checking hourly for one is plenty, and 15 minutes
between ticket-processing cycles is still fast relative to how often a
ticket actually needs a response.
Also removed `Install-Prerequisites.ps1`, `Register-HaloResponseAgentTask.ps1`,
and `Copy-McpServersToProject.ps1` from `Update-HaloResponseAgent.ps1`'s
`$filesToSync` (previously described above as "every `.ps1` file," which was
accurate at the time but is no longer). Those three are one-time
setup/registration scripts run once, by hand, as Administrator - nothing
scheduled ever invokes them again afterward, so syncing them bought nothing
(a change only matters the next time someone deliberately re-runs one, at
which point re-downloading it the normal way is no extra step) while still
costing a download/hash-check/potential backup every update cycle for no
reason. `$filesToSync` is now just the three prompts,
`Invoke-HaloResponseAgent.ps1`, `Update-HaloResponseAgent.ps1` itself, and
`Show-AgentLog.ps1`.

**`create_contact` no longer waits for `-RequireApproval` sign-off (v2.10.4,
real incident, corrects v2.10.2).** Ticket #21702 - a Huntress escalation
for the same kind of verified-but-unlinked user v2.10.2 was built to fix -
ran in `-RequireApproval` mode and still came back "NEEDS CONTACT VERIFIED
... create_contact is not permitted in this run." The resolver had done
everything right (confirmed Mark Pon via M365/CIPP, matched the ticket's
claim, identified the right client/site) and then couldn't act, because
v2.10.2 had put `create_contact` in `$remediationMutatingTools` - the same
gate as a password reset or reboot - so it got stripped from every
non-APPROVED ticket's tools under approval mode.
That gate was the wrong category for this action. `-RequireApproval` exists
to hold back what the pipeline says or does *to the client's actual
problem* - a reply, a password reset, a reboot - until a human signs off.
Fixing which contact a ticket is linked to isn't that; it's correcting the
ticket's own bookkeeping, the same class of action as the `update_ticket`
calls `-RequireApproval` itself depends on to draft its note and change
status, and the on-call notification email/text, both of which were already
exempted from gating for exactly this reason. `create_contact` is removed
from `$remediationMutatingTools` (so it's available to every ticket
regardless of approval tier) but stays in `$mutatingTools`, so `-WhatIf`
still blocks it - a dry run must still write nothing real to Halo. The
FLOW B approval-banner text gained an explicit exception for this, mirroring
the existing EMERGENCY-acknowledgment one: create/relink a verified contact
for real, immediately, whatever tier the ticket is - only the client-facing
reply and any remediation action still go through the draft-and-wait flow.

**The bot always unassigns itself when it's done with a ticket - cross-cycle
tracking no longer depends on staying assigned (v2.10.5, real incident,
inverts a design decision that dated back to v1).** Ticket #21702, run again
after v2.10.4's create_contact fix, worked correctly end to end - but ended
up assigned to the bot's own agent, and since Halo's API-user account
doesn't appear in a normal licensed-user list, the ticket became effectively
invisible in the Help Desk ticket list Roger actually looks at. Root cause:
FLOW A step 7 (the approval-mode send-for-real step) left Resolved/Waiting-
on-client tickets assigned to the bot on purpose, via an
`[INTENDED ASSIGNMENT] keep` marker written by FLOW B's draft - and that
same "stay assigned to track it" design wasn't approval-mode-specific at
all: every non-approval-mode Resolved/Waiting-on-client ticket had been
doing the exact same thing since before `-RequireApproval` existed, via
resolver-prompt.md's own end-state instructions. It just took an
approval-mode run to surface it, because that's the run Roger happened to
be watching closely enough to notice a ticket disappear.
Roger's own framing, and the one now implemented: only stay assigned to
yourself for as long as you're actively working the ticket and sending
responses; once a pass is done, always unassign, no exceptions, regardless
of outcome or which status the ticket landed on. That breaks the original
tracking mechanism (agent_id as the signal for "the bot already handled
this and is waiting on the client") - Roger flagged this tension himself
("not sure how you will cache or track the tickets you've worked on at that
point") rather than assuming it away.
The replacement tracking mechanism reuses a pattern already proven
elsewhere in this same file: `-RequireApproval`'s own `ai_approved_status_name`
tickets were already being found via status, sitting unassigned
(`agent_id: 1`), inside the classifier's ordinary "Unassigned" query - no
separate agent-based bucket needed for those. Generalizing that: the
classifier's "Unassigned" call (`agent_id: 1`, page 1/15) now doubles as the
re-check pool for every outcome, not just approval-mode ones. A new
"Distinguish a fresh ticket from a re-check" step calls
`get_ticket_time_entries` on every candidate in that page (bounded to 15
tickets/cycle, the same cost the old "already mine" bucket used to pay for
its own smaller set) and skips any where the bot's own last note is still
the most recent entry with nothing new from the client since. The old
"Already mine" call (`agent_id: {{AGENT_ID}}`, fully paged) isn't removed -
it's repurposed as a stuck-claimed recovery check. It should come back
empty under normal operation now; a hit means a prior cycle's final
unassign write never landed (crashed, threw, or Halo's own triage-swallow
bug ate it), and resolver-prompt.md's "Claim the ticket" section now treats
that explicitly as a recovery case - verify what was actually completed
before finishing the job and unassigning properly - rather than assuming
it's a normal multi-reply conversation still in progress, which is what it
would have meant under the old design.

**A real client-facing reply now requires `send_email: true`, not just
`note_is_private: false` (v2.10.6, real incident).** Ticket #21702's
approved reply landed successfully via `update_ticket` with
`note_is_private: false`, but Halo recorded it as a "Private Note"-type
action and the client never got it - confirmed by pulling the ticket's own
action log directly rather than assuming. Per Roger's own domain knowledge
running Halo day to day: a private note never emails the client, by
definition, so from his side this was indistinguishable from "the bot
never sent it" regardless of what the `note_is_private` flag said.
Root cause confirmed directly, not assumed: `mcp__Halo__list_outcomes`
against the live tenant showed `update_ticket` was hardcoding
`outcome_id: 7` ("Private Note") for every note, and that outcome has
`hidesendemail: true` in HaloPSA - it can never trigger an email regardless
of `hiddenfromuser`. Outcome `16` ("Email User") has `hidesendemail: false`
and `sendemail: 1` - it's the one that actually emails the ticket's
contact. Read and fixed directly in `halopsa-mcp`'s own source
(`rafouche/MCPs`, commit `37143c8`): `update_ticket` now accepts
`send_email: true` to use outcome 16 instead of 7 (and forces
`hiddenfromuser` false when it's set, since emailing a note the client
can't see in the portal isn't coherent). That commit is made but not yet
pushed/deployed to Cloudflare - Roger is handling the push and live deploy
himself from his own session on that repo. See the "Known gaps and future
work" entry above for the deploy-status caveat: `send_email: true` is a
no-op against the live tool until that deploy lands. Every place in this
codebase that sends a real reply (resolver-prompt.md's new "Sending a
real, client-facing reply" section, FLOW A step 5) now pairs
`note_is_private: false` with `send_email: true`; every place that stays
private (FLOW B's draft note, internal findings notes) explicitly leaves
`send_email` unset.

**Backups now live in their own `backups\` subfolder, not loose in the
deployment directory (v2.10.7, real incident).** Roger reported "a ton of
.bak files" showing up on the production server - expected, given how many
real fixes shipped to `Invoke-HaloResponseAgent.ps1`/the prompts across a
single day this session, each one triggering `Update-HaloResponseAgent.ps1`
to back up the previous version before replacing it - but it defeated the
whole point of this deployment being a minimal, clean folder holding only
the files the project actually needs (see README's "Keeping this up to
date automatically"). `Update-HaloResponseAgent.ps1` and
`Copy-McpServersToProject.ps1` (the only two places that ever write a
`.bak` file) now create `backups\<file>.bak-<timestamp>` instead of
`<file>.bak-<timestamp>` next to the real file - same backup behavior and
retention (still not auto-cleaned up automatically; delete by hand, or
delete the whole `backups\` folder), just relocated. `backups/` added to
`.gitignore` alongside `logs/`.

**Consumer-VPN alerts now confirm identity before saying anything about
VPN policy (v2.10.8, corrects v2.9.5's design flaw).** Roger's feedback,
verbatim: the resolver should ask if the sign-in was the account owner
themselves first; if yes, explain the policy and offer proper remote
access if needed; if no, that's a possible breach and needs to be treated
as one. The v2.9.5 policy jumped straight to "tell them to disconnect it,"
which assumed the named contact was the one who connected the VPN -
exactly the thing a security alert on an account can't tell you by itself.
Lecturing the account owner about VPN policy doesn't address a real
compromise, and worse, if someone else really is signing in as them, that
person likely never even sees the reply (it goes to the real owner's
inbox).
The section now has two branches instead of one: **confirmed by the
account owner** gets the v2.9.5 policy essentially unchanged (explain why,
tell them to stop, offer real remote access if they have a legitimate
need) - just moved to fire only after confirmation instead of assumed.
**Denied, or the owner can't confirm it** is treated as a real compromise
indicator regardless of business hours or the ticket's tier - immediate
on-call notification (the same mechanism the emergency section already
uses, but not gated on being after hours, since a live compromise doesn't
wait for a shift change), a brief calm client acknowledgment, and a
`"NEEDS URGENT SECURITY REVIEW - "` internal note for a human to act on.
Deliberately does not auto-reset the password or revoke sessions itself -
that's a real, potentially disruptive action best left to a human's
judgment given what's at stake, not something to trigger off a single
"they said no" signal, even though `mcp__CIPP__reset_user_password` is
already whitelisted and could technically do it.

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
- **Private-note handoff got dropped as "nothing new" (fixed, found via a live
  report - ticket #21568).** A human agent did real work on a ticket, wrote it
  up in a PRIVATE note (`hiddenfromuser: true`), reassigned the ticket to the
  bot, and set it to "waiting on client" expecting a client-facing follow-up.
  Nothing followed up - the client never heard anything. Confirmed against
  ticket #21568's real `get_ticket`/`get_ticket_time_entries`/`list_statuses`
  responses (not assumed): classifier-prompt.md's "drop already-claimed
  tickets with nothing new to act on" check used `mcp__Halo__get_ticket` to
  decide whether anything had changed since our last touch - but `get_ticket`'s
  schema has no field distinguishing a client-facing reply from an
  internal-only note, so a private note and a real client-facing reply looked
  identical to that check, and the ticket got silently dropped as "already
  handled." Fixed by switching that check to
  `mcp__Halo__get_ticket_time_entries` (the action log, which does carry
  `hiddenfromuser`) and adding a third "include as candidate" case: most
  recent substantive entry is a private note describing real work - whether
  from the bot in an earlier cycle or from a human colleague handing off -
  with no public reply sent since. `mcp__Halo__get_ticket` was removed from
  `$classifierTools` since nothing in classifier-prompt.md calls it anymore.
  resolver-prompt.md's NEW/ONGOING/EMERGENCY CANDIDATE classification also got
  a small clarifying addition so this exact state is treated as NEW (client
  still owed a first reply, private note used as prior art rather than
  re-diagnosed from scratch) instead of being mistaken for ONGOING.
- **list_tickets silently only ever saw ~20 of the account's real 213 open
  tickets (fixed, same ticket #21568 - the above fix alone wasn't enough).**
  Even after the fix directly above, #21568 stayed invisible: it never
  reached the classifier at all, because `mcp__Halo__list_tickets` had no
  agent/team filter - only `count`/`open_only`/`client_id`/`search` - so
  "call it once with `open_only: true`" silently returned just the ~20
  most-recently-active open tickets account-wide out of a real 213
  (confirmed live). A ticket that goes quiet ages out of that window with
  no error. Raising `count` doesn't fix it either - each row carries full
  ticket body text, and `count: 30` alone already exceeded Claude Code's own
  response-size limit in a live test.
  This required a fix in the underlying tool, not just this repo: added
  `agent_id` and `pageinate`/`page_no`/`page_size` to `halopsa-mcp`'s
  `list_tickets` (`rafouche/MCPs`, commits `b9a0c4e`/`3f7d8ab`), confirmed
  against HaloPSA's own live REST API v2 swagger spec, then verified live
  post-deploy: `agent_id: 1` correctly returned only unassigned tickets,
  and `page_size: 10` pagination returned exactly one page plus an accurate
  `record_count`. classifier-prompt.md's "Find candidate tickets" now makes
  two agent_id-filtered calls instead of one unfiltered one: `agent_id: 1`
  (Halo's real "Unassigned" agent) capped at page 1/15 (an old unassigned
  ticket is a slower-moving gap, not worth a full sweep every 15 minutes),
  and `agent_id` = this bot's own ID, paged through in full regardless of
  `record_count` - that set should always be small, and must never
  silently truncate, since that's exactly the #21568 failure shape.
  Deliberately did not add HaloPSA's `team` filter - its swagger types it
  as a bare string despite being documented as "array of int," meaning the
  wire encoding isn't documented and wasn't safe to guess at; client-side
  `team_id` filtering on the (now much smaller) combined results stays as
  it was. A real gap remains: an unassigned Help Desk ticket could in
  theory still age past the unassigned call's page-1/15 window if enough
  *other teams'* unassigned tickets arrive first - lower-priority than the
  fixed case, not yet mitigated.

## Known gaps and future work

Found by directly querying the live Halo instance (`list_ticket_types`,
`list_priorities`, `get_ticket`, `update_ticket`'s real schema) rather than
assuming from config.json alone:

- **`note_is_private: false` alone does not email the client - a real
  incident on ticket #21702 confirmed this the hard way, and the root cause
  was tracked down and fixed at the source (v2.10.6).** The resolver posted
  a real, approved reply with `note_is_private: false` and the call landed
  successfully, but Halo recorded it as a "Private Note"-type action and
  the client never received anything. Root cause, confirmed directly
  against the live tenant (`mcp__Halo__list_outcomes`), not assumed:
  `halopsa-mcp`'s `update_ticket` hardcoded `outcome_id: 7` ("Private
  Note") for every note it created, and that outcome has
  `hidesendemail: true` in HaloPSA - it can never trigger an email
  regardless of `hiddenfromuser`. Outcome `16` ("Email User") has
  `hidesendemail: false` and `sendemail: 1` - it's the one that actually
  emails the ticket's contact.
  Fixed directly in `halopsa-mcp`'s own source (`rafouche/MCPs`, commit
  `37143c8`, type-checked clean): `update_ticket` now accepts a
  `send_email: true` parameter that selects outcome 16 instead of 7 (and
  forces `hiddenfromuser` false when set - emailing a note the client can't
  see in the portal isn't coherent). Existing callers that don't pass
  `send_email` keep the exact prior behavior, so this is additive, not a
  breaking change. **That commit exists but is not yet pushed or deployed
  to Cloudflare** - Roger is handling the push and live deploy himself from
  his own session on that repo ("I'll push the MCP in the other chat
  controlling the MCPs"), so `send_email: true` is a no-op against the live
  tool until he does. This pipeline pairs `note_is_private: false` with
  `send_email: true` on every real client-facing reply (see
  resolver-prompt.md's "Sending a real, client-facing reply" section and
  Invoke-HaloResponseAgent.ps1's FLOW A step 5) - confirm against the live
  tool schema once the deploy lands, the same way every other Halo-tool
  fact in this project gets confirmed directly.
- **`compliance.excluded_client_names` (v2.9.0) cannot stop the classifier's
  unassigned/mine `list_tickets` calls from seeing an excluded client's ticket
  subject/summary line every cycle** - confirmed directly against HaloPSA's
  live REST API v2 swagger spec: `/Tickets` supports only an INCLUDE filter
  for a single `client_id`, no exclude filter, no bulk/multi-client filter
  (as of the same investigation that added `agent_id`/pagination to
  `halopsa-mcp` - see "Known limitations" above - so this has now actually
  been checked against the real spec, not just the MCP tool's exposed
  surface). Closing this the rest of the way needs one of: (a) the Halo MCP
  server adding an exclude-filter or "list tickets NOT in these clients"
  capability (HaloPSA's API itself has no such filter either, so this would
  need client-side filtering inside halopsa-mcp before it ever returns a
  response - out of this repo's control, same as the priority/urgency/
  contact-creation gaps above); or (b) a non-AI pre-filter sitting in front
  of the classifier entirely - e.g. PowerShell itself calling Halo's REST API
  directly (bypassing the MCP server) to fetch and filter the ticket list
  before any of it reaches a `claude -p` call - a materially bigger
  architecture change than anything else in this file, since PS1 currently
  has no independent Halo API client at all. Worth real design discussion
  before attempting, not a quick patch.

- **An unassigned Help Desk ticket could still age past the classifier's
  unassigned-call window (page 1/15 of `agent_id: 1`, any team) if enough
  *other teams'* unassigned tickets arrive first** - a real but lower-
  priority residual gap from the `list_tickets` fix above (see "Known
  limitations"), not yet mitigated. HaloPSA's `team` filter would close this
  properly (filter to Help Desk server-side before the page-size limit ever
  applies), but its swagger types it as a bare string despite being
  documented as "array of int" - the wire encoding (JSON-array text vs.
  something else) isn't documented and needs a live test against a real
  tenant before wiring it in. Until then, a periodic wider sweep (paging
  through all of `agent_id: 1` account-wide, filtering to Help Desk
  client-side, on some slower cadence than every 15-minute cycle) is the
  fallback if this turns out to matter in practice.

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
- **Ticket re-linking is now possible, but deliberately confidence-gated, not
  fully automated (v2.9.3 - supersedes the v2.8.1 entry that used to be
  here).** The v2.8.1 gap ("no tool to create a Halo contact/user, or to
  relink a ticket to a different one") is now half-closed at the tool level:
  `halopsa-mcp` (`rafouche/MCPs`, commit `a0264be`) added `client_id`/`user_id`
  to `update_ticket` and `search_phonenumbers` to `list_contacts`, and
  `mcp__Halo__create_contact` turned out to already exist (the original
  "confirmed directly against the real tool list" check was correct at the
  time - `create_contact` was added to `halopsa-mcp` sometime after). Real
  scenario that prompted this: a voicemail comes in against a generic/shared
  account, but the transcript names the real caller with a spoken name and
  callback number, no email (e.g. "Dawn Davis, Director of Stone County
  Health Department, 417-907-9136").
  Having the tools didn't mean using them unconditionally was safe -
  reassigning a ticket to the wrong real client is worse than leaving it
  unlinked. `resolver-prompt.md`'s "If the ticket's contact/company is
  unknown or wrong" section now splits on confidence: a callback phone
  number matching **exactly one** existing Halo contact
  (`list_contacts` + `search_phonenumbers: true`) is treated as a real,
  already-vetted identity and re-linked automatically (write verified per
  the pre-triage-swallow section, private note logged explaining why); zero
  or multiple phone matches, or only a name/company in text with no phone to
  check, falls back to the same flagged-note pattern as before.
  **UPDATE (v2.10.2) - `create_contact` is no longer withheld outright; see
  the entry below.** The blanket "never in `$resolverTools`" stance taken
  here turned out to be too broad - it couldn't distinguish "fabricating an
  identity from unverified ticket text" (still correctly refused) from
  "creating a Halo record for someone already confirmed real via a live
  M365/CIPP lookup" (safe to do automatically, and something the project had
  explicitly asked for earlier).
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
