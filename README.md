# Altec Halo Response Agent — Setup

## Files
| File | Purpose |
|---|---|
| `config.json` | On-call contacts, business hours, Halo IDs, remediation whitelist. **Edit this, not the prompt.** |
| `agent-prompt.md` | The agent's task instructions, run fresh each cycle. |
| `Invoke-HaloResponseAgent.ps1` | Loads config, computes business-hours context, calls `claude -p`. |
| `Register-HaloResponseAgentTask.ps1` | One-time setup: registers the Task Scheduler job. |
| `Show-AgentLog.ps1` | Pretty-prints a log entry (cost, tokens, permission denials, the actual report) instead of raw JSON. |

## Prerequisites
1. **Claude Code installed and authenticated** on the Windows Server (via `claude setup-token` for a subscription, or `ANTHROPIC_API_KEY` set as a system environment variable for API billing — API key is the more predictable option for an unattended service).
2. **MCP servers configured** on that machine/account for: Halo, Microsoft 365, CIPP, Ninja, UniFi, Meraki, Huntress, Hudu — the same connectors you already use, just reachable from wherever Claude Code runs on the server.
3. PowerShell 5.1+ (built into Windows Server).

## Step by step
1. Copy all four files to `C:\AltecAgents\HaloResponseAgent\` (or your preferred path — just keep `RootPath` in the scripts consistent).
2. **Fill in `config.json`:**
   - `on_call.primary.email` and `text_email` (your email-to-SMS gateway address).
   - Everything else already matches what's live in Halo (team/status names). Review `remediation_whitelist` and add/remove entries as you like.
3. **Dry-run it first:**
   ```powershell
   .\Invoke-HaloResponseAgent.ps1 -DryRun
   ```
   This just prints the resolved prompt and tool list without calling Claude at all — confirm it looks right.
4. **Then simulate a real run** against live data with nothing actually happening:
   ```powershell
   .\Invoke-HaloResponseAgent.ps1 -WhatIf
   ```
   This calls Claude for real against your live Halo/Ninja/M365/etc. data — full
   investigation, real reasoning about real open tickets — but every tool that
   would change something (replies, ticket status/assignment, on-call
   notifications, reboots, script runs, password resets, Hudu writes) is removed
   from its allowlist for the run, and it's told to describe what it would have
   done instead (look for "WOULD DO:" in the output). Read through the result
   before trusting any of this against real tickets — either open
   `logs\whatif-<date>.log` directly (a single huge JSON line per run), or use
   the human-readable viewer:
   ```powershell
   .\Show-AgentLog.ps1
   ```
   With no arguments this shows just the latest entry in whichever log file was
   modified most recently — cost, tokens, turn count, any permission denials
   (tool calls that were silently blocked — the first thing to check if the
   agent seems to do nothing), and the actual report text. Pass `-LogFile` to
   point at a specific file, `-Last N` for the last N entries, or `-All` for
   the whole file.
5. **Run it once for real** and check it the same way:
   ```powershell
   .\Invoke-HaloResponseAgent.ps1
   .\Show-AgentLog.ps1 -LogFile .\logs\run-<date>.log
   ```
6. **Register the schedule** (as Administrator):
   ```powershell
   .\Register-HaloResponseAgentTask.ps1
   ```
   Default is every 10 minutes, 24/7. Adjust with `-IntervalMinutes`.

## Editing config.json — no IDs, ever
Everything in `config.json` is a plain name, exactly as it appears in Halo or
NinjaOne. The agent looks up the real technical ID itself every run — nobody has to
hunt one down or keep it in sync.

**To add a new remediation action** (say, a new approved NinjaOne script), add an
entry to `remediation_whitelist`:
```json
{
  "name": "Run NinjaOne script: <exact script name in NinjaOne>",
  "requires": "<plain-English condition that must be true before the agent uses it>"
}
```
That's it — the agent finds the script by name and the tool it needs
(`mcp__Ninja__run_script_on_device`) is already allowed. You only touch
`Invoke-HaloResponseAgent.ps1`'s tool list if you're adding a brand-new *kind* of
action (e.g. something in a system that isn't touched at all today), not a new
instance of an existing kind.

**To change which Halo team/status/priority the agent uses**, edit the matching line
under `halo` in `config.json` (e.g. `follow_up_status_name`) to the name as it appears
in Halo. No ID lookup needed — the agent resolves it itself.

**To change who the agent works as in Halo**, edit `halo.agent_username` to the exact
name of the Halo user account (rename the existing temporary account, or create a new
one and update this to match — either way, nothing else needs to change). The agent
claims unassigned Help Desk tickets under this name and picks back up anything already
assigned to it; on escalation it unassigns itself and hands the ticket back to the
Help Desk team, unassigned, for a human to pick up.

## Adding a new system (e.g. 3CX later)
The whole point of the split between `config.json` (day-to-day) and the static
allowlist (rare) is that adding a new *system* — a new connector like a future 3CX
MCP — never touches config.json's structure, and adding a new *action* within a
system already wired in never touches the script. Three steps, in order:

1. **Tool names → `Invoke-HaloResponseAgent.ps1`.** Add the new system's tool names
   as their own labeled block in the `#region STATIC TOOL ALLOWLIST` section (there's
   already an empty placeholder block for 3CX). This is a one-time step per system,
   not per action.
2. **Investigation guidance → `agent-prompt.md`.** Add a short paragraph to the
   "Investigate" step telling the agent what this system is for and when to check it
   — same pattern as the email-diagnostics paragraph already there.
3. **Remediation actions (if any) → `config.json`.** Same as any other remediation —
   a plain-English `name` + `requires` entry, no IDs.

**For 3CX specifically**, since it's per-client (each client has its own 3CX server),
the natural place for "which 3CX server/API belongs to which client" is Hudu — you
likely already document client infrastructure there, and the agent already has
read access to it (`mcp__HUDU__asset_index_tool`/`asset_show_tool`). That keeps the same
"no IDs in config" pattern: the agent looks up the client's 3CX connection details
from Hudu by company name, same as it looks up Halo team/status IDs by name today.

## CIPP MCP swap — not actually cut over yet
The plan is to move from the self-built CIPP Worker to CIPP-ng's built-in MCP
server, but as of the last check (`claude mcp list` on the production server),
the registered `CIPP` connector still points at the original custom Worker
(`cipp-mcp.young-math-a33a.workers.dev`), not CIPP-ng (`cipp.altecusa.com`) — the
production machine hasn't been switched over. That's fine for now: the script
uses whatever's registered as `CIPP` and the old worker is still connected and
working, so there's no rush.

When you're ready to cut over: register the CIPP-ng MCP server under a clear,
distinct name (e.g. `CIPPNG` — see "Registering MCP servers" below), confirm its
tool names (`get_user`, `healthcheck`, `reset_user_password`, `enable_user`,
`cipp_api_get` all carried over unchanged when checked against a CIPP-ng instance
directly, but re-verify against your own — run `.\Invoke-HaloResponseAgent.ps1
-DryRun` or ask `claude` interactively to list that server's tools), then update
every `mcp__CIPP__...` entry in `Invoke-HaloResponseAgent.ps1` and
`agent-prompt.md` to the new server name. Nothing in `config.json` needs to
change either way — remember Claude Code matches MCP tools as
`mcp__<ServerName>__<tool>` (see "Registering MCP servers" below for why this
matters), so the rename has to happen in both the allowlist and the prompt, not
just one.

## Registering MCP servers (command line / PowerShell)
Run once per Windows account that will execute the scheduled task (see the note
in "Prerequisites" about SYSTEM vs. a dedicated service account — register under
whichever account actually runs the task, since `-s user` scope is per-account).

### 0. Node.js — required, not bundled
Windows Server has no Node.js/npm out of the box, and `claude-code` is an npm
package, so `npm install -g @anthropic-ai/claude-code` fails with
`npm : The term 'npm' is not recognized...` until Node is installed. Fastest
path on a server with no package manager already set up:

```powershell
Invoke-WebRequest -Uri "https://nodejs.org/dist/v22.14.0/node-v22.14.0-x64.msi" -OutFile "$env:TEMP\node.msi"
Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\node.msi`" /qn /norestart" -Wait
# Close and reopen PowerShell (or refresh PATH in the current session) so node/npm are picked up:
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
node -v
npm -v
```
(`winget install OpenJS.NodeJS.LTS` or `choco install nodejs-lts -y` work too, if either is already set up on the box.)

### 1. Install and authenticate Claude Code
```powershell
npm install -g @anthropic-ai/claude-code
```
If npm nags about its own update (`npm error code EBADENGINE ... Not compatible
with your version of node/npm`) right after, ignore it — that's npm's optional
self-update rejecting itself because it wants a newer Node than the LTS above
ships; it doesn't affect the `claude-code` install, which already succeeded.

```powershell
claude --version   # confirm it's on PATH

claude setup-token                      # subscription login
# or
setx ANTHROPIC_API_KEY "sk-ant-..."      # API billing — more predictable for an unattended service; restart the shell after setx
```

### 2. Register each MCP server

**The naming matters, exactly.** Claude Code matches MCP tools as
`mcp__<ServerName>__<tool>`, where `ServerName` is whatever name you give it in
`claude mcp add <name> ...` — case-sensitive. `--permission-mode dontAsk` (used
by `Invoke-HaloResponseAgent.ps1`) denies an unmatched tool name *silently*, with
no error anywhere — this is exactly the bug that made every scheduled run do
nothing but call `Read` for months without anyone noticing (see `CLAUDE.md`
"Known limitations"). After registering, always confirm with `claude mcp list`
and match the exact names it shows against the `mcp__<ServerName>__<tool>`
entries in `Invoke-HaloResponseAgent.ps1` — don't assume a connector's display
name or the vendor's name for it.

Get each connector's endpoint URL and credential from wherever you recorded the
custom Cloudflare Worker URLs/tokens when you built Halo/Ninja/UniFi/Meraki/
Huntress/Hudu/CIPP, or from CIPP-ng's own Settings for the new CIPP-ng MCP.
Most of your own Workers use a plain static API key/Bearer token, which
registers non-interactively:

```powershell
# Example: a Worker-hosted connector with a static Bearer token
claude mcp add --transport http Halo https://<your-halo-worker>/mcp `
    --header "Authorization: Bearer <token>" -s user

# Repeat per connector, each with its own endpoint/token. Avoid spaces in the
# name (e.g. use "Microsoft365", not "Microsoft 365") so the mcp__ prefix stays
# unambiguous:
claude mcp add --transport http <Name> <https-url> --header "Authorization: Bearer <token>" -s user

claude mcp list   # verify — note the exact names and connection status
```

**If a connector shows "Needs authentication"** in `claude mcp list` (this is
normal for OAuth-based servers like Hudu/Huntress — token auth connectors just
show "Connected" once added), it needs a one-time interactive login that can't
complete unattended on a headless server:

```powershell
claude mcp login <Name> --no-browser
```

This prints an authorization URL — open it in a browser on any machine, sign in,
and paste the resulting redirect URL back into the prompt. If the server itself
has no browser, run this over `ssh -t user@server` so the terminal stays
interactive for pasting the URL back. **These credentials are stored per-machine
(Windows Credential Manager) and cannot be copied from one machine to
another** — the login has to be run against the actual production server, not
somewhere else and transplanted.

Then confirm the tool names match what's in `Invoke-HaloResponseAgent.ps1` —
`.\Invoke-HaloResponseAgent.ps1 -DryRun` prints the allowlist without calling
Claude — before registering the scheduled task, and run `.\Invoke-HaloResponseAgent.ps1
-WhatIf` at least once to confirm Halo/CIPP/etc. tool calls actually succeed:
`.\Show-AgentLog.ps1` after the run shows any permission denials clearly, not
just whether the script completed without a PowerShell error (a run can finish
"successfully" while every single tool call inside it was silently denied — see
`CLAUDE.md`'s note on the tool-name syntax bug for exactly this happening here).

## Reducing per-run cost
Each `-WhatIf` or real run calls the API for real — a 75-ticket / 7-candidate
run at the account defaults (`claude-opus-5`, effort `high`, adaptive thinking)
cost **$4.13** and took 62 turns. `config.json`'s `claude` block controls the
two cheapest levers, both blank by default (no change from what you have today):

```json
"claude": {
  "model": "",
  "effort": ""
}
```

- **`model`** — e.g. `"claude-sonnet-5"` (Sonnet is roughly 60% cheaper per
  token than Opus: $2/$10 per million tokens vs. $5/$25). Ticket triage —
  reading tickets, calling lookup tools, drafting replies — doesn't obviously
  need frontier-tier reasoning the way a hard coding problem might, but
  **compare a Sonnet `-WhatIf` run's WOULD DO quality against a known-good
  Opus run before switching the live schedule** — judgment calls on escalation,
  frustration detection, and root-cause investigation are exactly where a
  cheaper model is more likely to slip.
- **`effort`** — one of `low`, `medium`, `high` (default), `xhigh`, `max`.
  Lower effort means less thinking, fewer/more-consolidated tool calls, and
  less token spend, at some cost to thoroughness. `medium` is a reasonable
  first thing to try before touching the model.

Other things worth knowing, not (yet) wired into the script:
- `--fallback-model sonnet,haiku` makes a run retry on a cheaper model if the
  primary is overloaded/unavailable — a reliability net, not a cost lever (it
  doesn't trigger on rate limits), and not currently exposed via config.json.
- Don't use `--bare` here even though it reduces per-run overhead elsewhere —
  it also skips MCP entirely, which is this agent's whole job.
- Running less often (raise `-IntervalMinutes` when registering the scheduled
  task) cuts total daily cost proportionally, at the cost of slower response
  to new tickets — a scheduling tradeoff, not a per-run one.

## Cross-client fix history
Before diagnosing a non-obvious issue from scratch, the agent searches past tickets
across *every* client (not just the one it's currently working) plus Halo's KB and
the Hudu "AI-Documented Fixes" folder, looking for a similar issue that's already
been solved. If a fix doesn't pan out, it tries other genuinely different fixes
across ticket cycles — there's no fixed attempt cap, it uses judgment, but client
frustration always overrides and triggers escalation regardless.

When a fix works and isn't already documented, it writes a short internal SOP-style
article into Hudu under the folder named in `config.json`'s `hudu_fix_folder_name`
(default: "AI-Documented Fixes") — create that folder once in Hudu if it doesn't
exist yet. This is the one place the agent writes outside of Halo, and it's
deliberately not gated by the remediation whitelist: it only ever writes internal
documentation, never touches a client's live systems.

## Safety notes
- Start with the remediation whitelist as narrow as you're comfortable with — you can always add to `config.json` later without touching anything else.
- `-MultipleInstances IgnoreNew` in the scheduled task keeps two runs from overlapping if one takes longer than the interval.
- Watch the logs for the first week or two, especially escalation and after-hours behavior, before trusting it fully.
- Nothing in this setup lets the agent act outside the `remediation_whitelist` — everything else it does with M365/Ninja/UniFi/Meraki/Huntress/Hudu is read-only by tool scoping in `Invoke-HaloResponseAgent.ps1`.
