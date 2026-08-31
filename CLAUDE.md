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
(`Halo:list_teams`, `list_statuses`, `list_priorities`, `Ninja:list_automation_scripts`).
Reason: a tech editing config shouldn't need to hunt down a numeric ID, and config
can't silently drift out of sync with Halo if it never stores IDs in the first place.

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

**Ticket ownership via assignment (planned, not yet built into agent-prompt.md).**
Roger wants a dedicated Halo agent account for this bot. Workflow: agent assigns
itself a ticket when it starts working it; unassigns on escalation (so it's visibly
free for a human); a human can reassign a ticket back to the agent's account for
wrap-up/closure after they've fixed the underlying issue — the agent needs to
recognize that case as "confirm and close," not "re-diagnose from scratch." **This
was designed but not yet implemented in agent-prompt.md — needs the account created
in Halo first, then the workflow logic added.**

**Cross-client fix history + Hudu documentation.** Before diagnosing anything
non-trivial, the agent searches past tickets *org-wide* (`Halo:list_tickets` with a
`search` term and no `client_id`) plus Halo KB and the Hudu `AI-Documented Fixes`
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
- **CIPP MCP migration — done.** Roger switched from the self-built Cloudflare
  Workers CIPP MCP to CIPP-ng's own built-in MCP server (registered as `CIPP_MCP`,
  pointed at the new CIPP-ng deployment). The four identity tool names in
  `Invoke-HaloResponseAgent.ps1` (`get_user`, `healthcheck`, `reset_user_password`,
  `enable_user`) carried over unchanged from the retired worker; only the
  server-name prefix changed from `CIPP:` to `CIPP_MCP:`.
- **Email/bounce diagnostics**: CIPP_MCP has no dedicated message-trace tool, but
  its generic `cipp_api_get` wrapper covers CIPP's native Message Trace via
  `endpoint: "ListMessageTrace"` — wired into `agent-prompt.md`. Falls back to
  finding the NDR in the user's own mailbox (`outlook_email_search`) when that
  doesn't turn up enough. Runs on CIPP's existing GDAP/CSP-delegated permissions,
  no new Exchange app registration needed.
- **3CX troubleshooting**: planned, not built. Per-client 3CX server API access is
  needed (multi-tenant, matching the 3CX Cloudflare Worker target already planned
  in Roger's broader MCP-servers project). Natural design: store each client's 3CX
  connection details in Hudu (Roger already documents client infra there), and have
  the agent look it up by company name at runtime — same "no IDs, look it up by
  name" pattern as everything else, rather than a new config table.
- **Ticket-assignment ownership workflow** (see above) — designed, not implemented.

## Known limitations
- Sequential ticket processing within a run, not parallel (see above).
- `on_call.primary.email`/`text_email` in config.json are still placeholders —
  fill in before relying on emergency escalation.
- The Ninja/CIPP tool names in the static allowlist assume specific MCP connector
  setups; re-verify after any future MCP server swap (see CIPP migration above).
