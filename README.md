# Altec Halo Response Agent — Setup

## Files
| File | Purpose |
|---|---|
| `config.json` | On-call contacts, business hours, Halo IDs, remediation whitelist. **Edit this, not the prompt.** |
| `agent-prompt.md` | The agent's task instructions, run fresh each cycle. |
| `Invoke-HaloResponseAgent.ps1` | Loads config, computes business-hours context, calls `claude -p`. |
| `Register-HaloResponseAgentTask.ps1` | One-time setup: registers the Task Scheduler job. |

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
   This prints the exact prompt and tool list without calling Claude — confirm it looks right.
4. **Run it once for real** and check `logs\run-<date>.log`:
   ```powershell
   .\Invoke-HaloResponseAgent.ps1
   ```
5. **Register the schedule** (as Administrator):
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
(`Ninja:run_script_on_device`) is already allowed. You only touch
`Invoke-HaloResponseAgent.ps1`'s tool list if you're adding a brand-new *kind* of
action (e.g. something in a system that isn't touched at all today), not a new
instance of an existing kind.

**To change which Halo team/status/priority the agent uses**, edit the matching line
under `halo` in `config.json` (e.g. `follow_up_status_name`) to the name as it appears
in Halo. No ID lookup needed — the agent resolves it itself.

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
read access to it (`Hudu:asset_index_tool`/`asset_show_tool`). That keeps the same
"no IDs in config" pattern: the agent looks up the client's 3CX connection details
from Hudu by company name, same as it looks up Halo team/status IDs by name today.

## CIPP MCP swap — complete
Moved from the self-built CIPP Worker to CIPP-ng's built-in MCP server, registered
as `CIPP_MCP` (see "Registering MCP servers" below). Its `get_user`, `healthcheck`,
`reset_user_password`, and `enable_user` tools carried over from the retired
worker with the same names, so only the `CIPP:` → `CIPP_MCP:` prefix changed in
`Invoke-HaloResponseAgent.ps1`. Message Trace didn't need a custom wrapper after
all — the built-in MCP's generic `cipp_api_get` tool covers it via
`endpoint: "ListMessageTrace"`, now wired into `agent-prompt.md`.

If CIPP-ng ever renames or restructures these tools, re-check them the same way:
run `.\Invoke-HaloResponseAgent.ps1 -DryRun` after connecting the new MCP, or just
ask Claude interactively (`claude` with the CIPP_MCP server configured) to list
its available tools, and update the four `CIPP_MCP:` lines accordingly — nothing
else in this file or in config.json needs to change either way.

## Registering MCP servers (command line / PowerShell)
Run once per Windows account that will execute the scheduled task (see the note
in "Prerequisites" about SYSTEM vs. a dedicated service account — register under
whichever account actually runs the task, since `-s user` scope is per-account):

```powershell
# Claude Code CLI itself, if not already installed:
npm install -g @anthropic-ai/claude-code

# Authenticate (pick one):
claude setup-token                      # subscription login
setx ANTHROPIC_API_KEY "sk-ant-..."      # or API billing — more predictable for an unattended service

# Register CIPP-ng's built-in MCP server (URL/token from CIPP-ng's own
# Settings > API Client / Integrations page — generate a dedicated API client
# scoped for MCP use, don't reuse a human user's session token):
claude mcp add --transport http CIPP_MCP https://cipp.altecusa.com/api/MCPServer `
    --header "Authorization: Bearer <token-from-CIPP-ng>" -s user

# Repeat for the other connectors this agent uses, with each one's own
# endpoint/token (Halo, Microsoft 365, Ninja, UniFi, Meraki, Huntress, Hudu):
claude mcp add --transport http <Name> <https-url> --header "Authorization: Bearer <token>" -s user

# Verify:
claude mcp list
```

Then confirm the tool names match what's in `Invoke-HaloResponseAgent.ps1` —
`.\Invoke-HaloResponseAgent.ps1 -DryRun` prints the allowlist without calling
Claude — before registering the scheduled task.

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
