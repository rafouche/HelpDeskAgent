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

## Files
- `config.json` — everything a tech should be able to change without touching a
  script: business hours, on-call contact, Halo team/status/priority **names**
  (never IDs — see "No IDs, ever" below), remediation whitelist, Hudu fix folder.
- `agent-prompt.md` — the actual task logic run fresh each cycle.
- `Invoke-HaloResponseAgent.ps1` — computes business-hours context, builds the
  prompt, calls `claude -p` with a scoped tool allowlist, logs output.
- `Register-HaloResponseAgentTask.ps1` — one-time Task Scheduler setup.
- `README.md` — setup + how-to-extend instructions for a human.

## Design decisions and why

**No IDs anywhere in config.json.** Every Halo/Ninja/etc. reference in config is a
plain name exactly as it appears in the actual tool (e.g. `"Help Desk"`, not team
ID `1`). The agent resolves the real ID itself at runtime via lookup tools
(`mcp__Halo__list_teams`, `list_statuses`, `list_priorities`,
`mcp__Ninja__list_automation_scripts`). Reason: a tech editing config shouldn't need
to hunt down a numeric ID, and config can't silently drift out of sync with Halo if
it never stores IDs in the first place.

**Static tool allowlist vs. config.json — different change frequency.** The
PowerShell script's `--allowedTools` list is the outer fence (what the agent is
technically capable of calling); `config.json`'s `remediation_whitelist` is what it's
actually *permitted* to use those tools for on a given ticket. Adding a new instance
of an existing action type (another NinjaOne script, another M365 action) only needs
a config.json entry. Adding a brand-new system (e.g. 3CX) needs a new labeled block
in the script's allowlist — there's already an empty placeholder block for 3CX.

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

## Multi-ticket handling
One `claude -p` run works through *all* open Help Desk tickets, one after another —
sequential within a single process, not concurrent. Fine at current volume. If
ticket volume ever grows enough that one run doesn't finish within the scheduling
interval or the task's execution time limit, that's a real architecture change
(genuine parallelism — multiple processes split by team/range), not a config tweak.
Not worth building preemptively.

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
  entries in `Invoke-HaloResponseAgent.ps1` and `agent-prompt.md` to the new
  server name.
- **Email/bounce diagnostics**: the CIPP server (old worker, see above) has no
  dedicated message-trace tool, but its generic `cipp_api_get` wrapper covers
  CIPP's native Message Trace via `endpoint: "ListMessageTrace"` — wired into
  `agent-prompt.md`. Falls back to finding the NDR in the user's own mailbox
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
- Sequential ticket processing within a run, not parallel (see above).
- `on_call.primary.email` in config.json is still a placeholder — fill in before
  relying on emergency escalation. `text_email` may be legitimately left blank (no
  SMS on-call set up yet) — the agent skips the text and still sends email in that
  case, this is expected.
- **Tool-name syntax bug that silently broke every MCP call from day one (fixed):**
  the static allowlist and `agent-prompt.md` used a `Server:tool_name` naming
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
