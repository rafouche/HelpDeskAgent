# Altec Halo Response Agent — Setup

## Two-stage pipeline
Each cycle runs two kinds of `claude -p` call, not one:

1. **Classifier** (`classifier-prompt.md`) — one cheap, read-only call (Haiku)
   that finds this cycle's candidate tickets and tags each with a complexity
   tier: `TRIVIAL`, `TRIVIAL_UNCERTAIN`, `MEDIUM`, or `COMPLEX`.
2. **Resolver** (`resolver-prompt.md`) — one call *per classified ticket*, with
   the full MCP tool set, on a model chosen by that ticket's tier (cheap for
   `TRIVIAL`/`TRIVIAL_UNCERTAIN`, capable for `MEDIUM`/`COMPLEX`). This is what
   actually investigates, replies, remediates, or escalates.

`TRIVIAL_UNCERTAIN` tickets still get a (cheap) resolver call, instructed to
skip full investigation and just ask for the one missing piece of information
— see `CLAUDE.md` for why this is a deliberate simplification of "skip the call
entirely."

This replaces an earlier design where one `claude -p` call handled every
ticket itself in a single agentic session — see `CLAUDE.md`'s changelog for
why (a cheap model can triage; only tickets that need it should pay for a
bigger one and a full tool loop).

## Files
| File | Purpose |
|---|---|
| `config.json` | On-call contacts, business hours, Halo IDs, remediation whitelist, per-tier model/effort settings. **Edit this, not the prompts.** |
| `classifier-prompt.md` | Stage 1 instructions: find candidate tickets, tag each with a tier. |
| `resolver-prompt.md` | Stage 2 instructions: investigate/resolve one specific ticket, run fresh per ticket per cycle. |
| `Invoke-HaloResponseAgent.ps1` | Loads config, computes business-hours context, runs the classifier then a resolver call per ticket. |
| `Register-HaloResponseAgentTask.ps1` | One-time setup: registers the Task Scheduler job (and, with `-EnableAutoUpdate`, the auto-update job too). |
| `Install-Prerequisites.ps1` | One-time setup: installs `claude` machine-wide so `SYSTEM` (not just your own account) can find it. |
| `Copy-McpServersToProject.ps1` | One-time setup shortcut: copies already-registered `-s user` MCP servers into this folder's `.mcp.json`. |
| `Update-HaloResponseAgent.ps1` | Fetches a minimal set of files from GitHub over HTTPS (no git); logs only when something actually changed (or failed). |
| `Show-AgentLog.ps1` | Pretty-prints a cycle's log entry (classifier + each ticket's resolver call + a cost summary) instead of raw JSON. |

This is the complete set of files this project needs to run - deliberately
everything in this table, nothing more. `README.md` and `CLAUDE.md` (this
file and the one written for Claude Code's own future reference) are
documentation, not part of the deployed program - keep them wherever's
convenient for reading, but there's no need to copy either onto the server
at all, and `Update-HaloResponseAgent.ps1` never fetches them.

## Prerequisites
1. **`Install-Prerequisites.ps1` run once, as Administrator** — installs `claude`
   machine-wide so it's visible to every account on the machine, including
   `SYSTEM` (the account the scheduled tasks below run as), not just
   whichever account you're logged in as. See "Install and authenticate
   Claude Code" below for the full step.
2. **Claude Code authenticated** (via `claude setup-token` for a subscription, or `ANTHROPIC_API_KEY` set as a system environment variable for API billing — API key is the more predictable option for an unattended service).
3. **MCP servers configured** on that machine for: Halo, Microsoft 365, CIPP, Ninja, UniFi, Meraki, Huntress, Hudu — the same connectors you already use, just reachable from wherever Claude Code runs on the server.
4. PowerShell 5.1+ (built into Windows Server).

## Step by step
1. Copy every file in the "Files" table above to
   `C:\AltecAgents\HaloResponseAgent\` (or your preferred path — just keep
   `RootPath` in the scripts consistent), then run `Install-Prerequisites.ps1`
   once as Administrator (see "Install and authenticate Claude Code" below)
   before anything else.
2. **Fill in `config.json`:**
   - `on_call.primary.email` and `text_email` (your email-to-SMS gateway address).
   - Everything else already matches what's live in Halo (team/status names). Review `remediation_whitelist` and add/remove entries as you like.
3. **Dry-run it first:**
   ```powershell
   .\Invoke-HaloResponseAgent.ps1 -DryRun
   ```
   This just prints the classifier's resolved prompt/tools/model and the
   resolver's prompt template/tools/tier-to-model mapping, without calling
   Claude at all — confirm it looks right. (Ticket ID/tier show as unresolved
   placeholders in the resolver template here, since no classifier call ran to
   supply real ones.)
4. **Then simulate a real run** against live data with nothing actually happening:
   ```powershell
   .\Invoke-HaloResponseAgent.ps1 -WhatIf
   ```
   This runs the classifier for real (it's read-only regardless of `-WhatIf`),
   then a real resolver call per classified ticket — full investigation, real
   reasoning about real open tickets — but every tool that would change
   something (replies, ticket status/assignment, on-call notifications,
   reboots, script runs, password resets, Hudu writes) is removed from the
   resolver's allowlist, and it's told to describe what it would have done
   instead (look for "WOULD DO:" in the output). Read through the result
   before trusting any of this against real tickets — either open
   `logs\whatif-<date>.log` directly (one `=== HEADER ===` section per
   classifier/ticket/summary), or use the human-readable viewer:
   ```powershell
   .\Show-AgentLog.ps1
   ```
   With no arguments this shows just the latest entry in whichever log file was
   modified most recently — cost, tokens, turn count, any permission denials
   (tool calls that were silently blocked — the first thing to check if the
   agent seems to do nothing), and the actual report text. Pass `-LogFile` to
   point at a specific file, `-Last N` for the last N entries, or `-All` for
   the whole file.
5. **Once `-WhatIf` looks good, run supervised-live with `-RequireApproval`** before
   trusting it fully unsupervised — see "Human approval mode" below for what this
   does and how to set it up. This is the recommended step before 6, not optional
   busywork: it's the difference between reading transcripts of what the agent
   *would* have said and seeing exactly what it's about to actually send, with a
   chance to catch a bad reply before a client ever sees it.
6. **Run it once fully live** (no `-WhatIf`, no `-RequireApproval`) and check it the
   same way:
   ```powershell
   .\Invoke-HaloResponseAgent.ps1
   .\Show-AgentLog.ps1 -LogFile .\logs\run-<date>.log
   ```
7. **Register the schedule** (as Administrator):
   ```powershell
   .\Register-HaloResponseAgentTask.ps1
   ```
   Default is every 15 minutes, 24/7. Adjust with `-IntervalMinutes`. If you're
   still in the `-RequireApproval` rollout stage, register it with that switch
   instead so every scheduled run starts in human-approval mode from the first
   firing:
   ```powershell
   .\Register-HaloResponseAgentTask.ps1 -RequireApproval
   ```
   `config.json`'s `ai_waiting_approval_status_name`/`ai_approved_status_name`
   must already be set to real Halo statuses before the task runs this way (see
   "Human approval mode" below) — the task will fail every firing otherwise, the
   same as running the switch by hand. Once comfortable with what's coming out
   of that mode, re-run this script *without* `-RequireApproval` to switch the
   existing task back to running fully live — no need to delete and recreate it.
8. **(Optional) Add auto-update on the same task**, so changed files get
   fetched onto this server on their own, instead of someone having to
   re-download them from GitHub by hand — re-run step 7's command with
   `-EnableAutoUpdate` added:
   ```powershell
   .\Register-HaloResponseAgentTask.ps1 -EnableAutoUpdate
   ```
   Default is every 60 minutes - there's no need for this to run as often as
   the ticket-processing task itself; adjust with `-UpdateCheckIntervalMinutes`.
   See "Keeping this up to date automatically" below before relying on it.

## Keeping this up to date automatically

This deployment is a plain folder of files downloaded individually from
GitHub (e.g. clicking Download on each file in a browser) - not a git
clone, no `git`/`git pull` involved anywhere, and nothing in this project
needs `git` installed at all. `Invoke-HaloResponseAgent.ps1` re-reads every
file fresh on each scheduled firing, so replacing a changed file on disk is
enough to make the very next cycle pick it up - no restart or reload step
needed.

`Update-HaloResponseAgent.ps1` automates exactly that, on its own schedule
(via `Register-HaloResponseAgentTask.ps1 -EnableAutoUpdate`, step 8 above):
it downloads a specific, minimal list of files - the three prompts,
`Invoke-HaloResponseAgent.ps1`, `Update-HaloResponseAgent.ps1` itself, and
`Show-AgentLog.ps1` - directly from
`https://raw.githubusercontent.com/rafouche/HelpDeskAgent/main/<file>` over
plain HTTPS (no authentication needed, this is a public repo), compares
each one's hash against the local copy, and replaces only the ones that
changed, backing up whatever was there before to
`backups\<file>.bak-<timestamp>` first - its own subfolder, not loose in
this directory, which is meant to hold only the files this project
actually needs. Only when something actually changed does it log which files
updated to `logs\update-<date>.log`. It also runs
`Invoke-HaloResponseAgent.ps1 -DryRun` once after a real update as a smoke
test (no Halo calls, no API cost) so a broken push is visible in that log
immediately rather than silently discovered when the next real cycle fails.

**`Install-Prerequisites.ps1`, `Register-HaloResponseAgentTask.ps1`, and
`Copy-McpServersToProject.ps1` are deliberately *not* in that list.** They're
one-time setup/registration scripts you run once, by hand, as
Administrator - nothing scheduled ever invokes them again afterward, so an
unattended sync of them would just sit on disk unused. If one of them
changes, re-download it the same way you did the first time; it only
matters the next time you deliberately re-run it. `README.md`/`CLAUDE.md`
are excluded for the same "not part of the running pipeline" reason,
plus they're documentation, not program files.

**`config.json` is never touched by this, on purpose - confirmed the hard
way.** It's explicitly a per-deployment file (this README tells you to fill
in `on_call.primary.email`/`text_email` and review `remediation_whitelist`
by hand), and those edits only ever exist on this server, never in the
repo. An earlier version of this script did sync `config.json`, and the
very first update cycle silently overwrote a live `on_call.primary.email`
with the repo's still-placeholder value - no backup, no warning, discovered
only when on-call escalation broke. Never add `config.json` back to that
file list.
It's a smoke test, not a rollback - if it fails, the new code is still left
in place and still runs next cycle; the log is what tells a human to go
look. A download failure for one file logs an error and leaves that file
untouched - it never partially overwrites anything on disk.

Trigger the registered update task manually once (Task Scheduler ->
right-click -> Run) and check `logs\update-<today>.log` for an `ERROR` line
before trusting it on its own schedule, the same way you'd confirm any
scheduled task - this mainly just confirms `SYSTEM` has outbound internet
access to GitHub. No log file at all is the expected quiet outcome when
there's nothing new to fetch, since this script only logs when something
actually happened.

This fetches whatever is on `origin/main` unconditionally, with no staging
step or approval gate - worth being explicit about as a real tradeoff, not
just a detail. In this project's actual setup that risk is contained (the
only thing that pushes to `main` is Roger's own reviewed changes), but if
that ever stops being true, this auto-update task should stop running
before anything else does.

## Human approval mode

A middle ground between `-WhatIf` (nothing happens, just narration) and running
fully live (every reply and remediation action goes out immediately): every
client-facing reply and remediation action is held for a human to review and
approve first, in Halo itself, before anything actually reaches a client or
touches a system.

**One-time setup, before you ever pass `-RequireApproval`:**
1. In Halo, create two new custom ticket statuses — call them whatever reads
   clearly to your team, e.g. **"AI Waiting Approval"** and **"AI Approved"**.
2. Put those exact names in `config.json`'s `halo.ai_waiting_approval_status_name`
   and `halo.ai_approved_status_name` (case-insensitive, but otherwise exact —
   same rule as every other name in the `halo` section). Leave both blank if
   you're not using this mode at all.

**Then run with the switch:**
```powershell
.\Invoke-HaloResponseAgent.ps1 -RequireApproval
```
(If either status name above is blank or doesn't match a real Halo status, this
fails immediately with a clear error — it won't silently run unsupervised.)

**What happens on a first-pass ticket:** the agent investigates exactly as
normal, but instead of sending the reply or running a remediation action for
real, it writes what it would have done into a **private** note, sets the
ticket to your `ai_waiting_approval_status_name` status, and unassigns itself.
Open the ticket in Halo, read that private note — it's the exact client-facing
text and the exact remediation action (if any) the agent wants to take.

**To approve it:** just change the ticket's status to `ai_approved_status_name`
in Halo — that's the whole approval action, nothing else to click. On the next
scheduled run, the agent picks it back up, reassigns itself, actually runs the
approved remediation action (if any), actually sends the approved reply, and
sets the ticket to whatever its originally-planned final status was
(Resolved/Waiting on client/Follow Up Needed). **To reject it:** don't change
the status — it's your call whether to edit the note yourself and reassign the
ticket to a person, leave it for the agent to reconsider on a later run, or
anything else; the agent will just leave an untouched `ai_waiting_approval_status_name`
ticket alone rather than re-drafting or re-costing on it every cycle.

**One exception:** the brief emergency on-call acknowledgment
("we've identified this as a priority issue and are notifying our on-call
engineer") still sends immediately, same as fully-live mode — on-call is
already being paged at that same moment, so holding back a one-line
acknowledgment doesn't add safety, only delay. Everything else about that
ticket (the actual diagnosis, the detailed follow-up reply) still goes through
the approval flow above.

**What this does and doesn't guarantee:** remediation actions (password reset,
reboot, running a whitelisted script) are physically blocked on a not-yet-approved
ticket — the tool itself is removed from that call's allowlist, not just
discouraged in the prompt, so a mistake there fails loudly rather than quietly
running. Whether a given `update_ticket` call is the safe private draft or a
real client-facing reply isn't something a tool allowlist can tell apart (it's
the same tool either way, just different arguments), so that part relies on the
agent following the instructions correctly — the same trust level as the rest
of this system's safety rules (ticket-ownership checks, remediation-whitelist
compliance), which has held up across many real `-WhatIf` runs so far.

You can also combine both switches (`-WhatIf -RequireApproval`) to see the whole
draft/approve choreography play out against live ticket data with nothing
actually written to Halo at all — useful for validating this mode itself before
trusting it with real client tickets.

Once you're comfortable with what's coming out of this mode, stop passing
`-RequireApproval` (re-run `.\Register-HaloResponseAgentTask.ps1` without it if
the schedule was registered with the switch) and the agent goes back to running
exactly as it did before this mode existed — no config changes needed, since a
run without the switch never looks at either new status
name at all.

## Excluding clients for compliance reasons

If any of your clients carry data this pipeline shouldn't be routing to a
third-party AI API — a dealership, a medical/dental practice, a CPA firm,
anything rolling up to a public parent company, or anything else your own
legal/compliance review flags — list their exact Halo client names in
`config.json`'s `compliance.excluded_client_names`:

```json
"compliance": {
  "excluded_client_names": ["Example Dealership Group", "Example Medical Group"]
}
```

Every name must match a real Halo client exactly (case-insensitive, same rule
as everything else in this file) or the whole cycle refuses to run — this
fails closed on purpose, since a typo here silently leaving a client
unprotected is worse than the cycle not running at all.

**Read `compliance._comment` in `config.json` (and CLAUDE.md's matching
section) before relying on this for an actual compliance determination** —
it stops the deep investigation and every downstream Ninja/Huntress/CIPP/
Meraki/UniFi tool call for an excluded client's tickets, but Halo's own API
has no way to exclude a client from the classifier's account-wide ticket
scan, so that first-pass subject/summary read is not something this control
eliminates. That's a meaningfully smaller exposure than the full pipeline,
not a zero one — get this reviewed by whoever handles compliance for that
client before treating it as sufficient on its own.

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
claims an unassigned Help Desk ticket under this name only for as long as it's
actively working it, and always unassigns itself again once it's done — whether
it resolved the ticket, is waiting on the client, or is handing it back to a
human — so it never sits showing as owned by an account that doesn't even
appear in Halo's normal licensed-user list. A ticket still assigned to this
account on a later run means something went wrong last time (a crash, or Halo's
own triage-swallow quirk eating part of a write) and needs a look, not that it's
still being worked normally.

## Adding a new system (e.g. 3CX later)
The whole point of the split between `config.json` (day-to-day) and the static
allowlist (rare) is that adding a new *system* — a new connector like a future 3CX
MCP — never touches config.json's structure, and adding a new *action* within a
system already wired in never touches the script. Three steps, in order:

1. **Tool names → `Invoke-HaloResponseAgent.ps1`.** Add the new system's tool names
   as their own labeled block in the `#region STATIC TOOL ALLOWLISTS` section's
   `$resolverTools` array (there's already an empty placeholder block for 3CX;
   the classifier's `$classifierTools` almost never needs new entries, since
   triage only needs Halo). This is a one-time step per system, not per action.
2. **Investigation guidance → `resolver-prompt.md`.** Add a short paragraph to
   the "Investigate" step telling the agent what this system is for and when
   to check it — same pattern as the email-diagnostics paragraph already there.
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
`resolver-prompt.md` to the new server name. Nothing in `config.json` needs to
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

The scheduled tasks in this setup run as the `SYSTEM` account
(`New-ScheduledTaskPrincipal -UserId "SYSTEM"` in `Register-HaloResponseAgentTask.ps1`)
— a separate Windows account from whichever one you're logged in as, with its
own profile, its own `PATH`, and its own environment variables. Anything
installed or configured only for your own account (a plain
`npm install -g`, `claude setup-token`, `setx` without `/M`) is invisible to
`SYSTEM`. So install and authenticate machine-wide from the start, not
per-account:

```powershell
.\Install-Prerequisites.ps1
```
Run once, as Administrator. It installs `claude` into a shared npm prefix
(`C:\ProgramData\npm`, not npm's per-user default of `%AppData%\npm`) via the
machine-wide `NPM_CONFIG_PREFIX` environment variable, and adds that folder
to the machine `PATH`. If npm nags about its own update (`npm error code EBADENGINE ... Not
compatible with your version of node/npm`) during this, ignore it — that's
npm's optional self-update rejecting itself because it wants a newer Node
than the LTS above ships; it doesn't affect the `claude-code` install, which
already succeeded.

Then, from a **new** PowerShell window (the one you just ran
`Install-Prerequisites.ps1` in won't see the machine-wide `PATH`/env changes
it just made):
```powershell
Get-Command claude   # Source should be under C:\ProgramData\npm, not your own AppData
claude --version

claude setup-token                      # subscription login
# or
setx ANTHROPIC_API_KEY "sk-ant-..." /M   # API billing — more predictable for an unattended service
```

**The `/M` above is not optional.** Claude Code's credential storage is
scoped per-user (`%USERPROFILE%\.claude\.credentials.json`, restricted to
your own account by default; verified against Claude Code's own docs, not
assumed), and `setx` *without* `/M` only sets a **per-user** environment
variable (`HKCU`), which `SYSTEM` would never see. `/M` writes it to the
machine-wide `HKLM` environment instead, which every account on the box —
`SYSTEM` included — inherits. Requires an elevated (Administrator) shell,
same as everything else in this setup. Reboot the server once after setting
it (or at least confirm with a fresh `-WhatIf` run once the task is
registered) so Task Scheduler's own process picks up the change rather than
a stale cached environment.

If you use `claude setup-token` (a one-year subscription token, not a file - it prints to the
terminal and does *not* save anywhere on its own) instead of an API key, the same rule applies to
wherever you put it: `setx CLAUDE_CODE_OAUTH_TOKEN "<token>" /M`, machine-wide, for the same reason.
The API key is still the better default here specifically because it doesn't expire on a fixed
one-year clock the way a subscription token does - one less thing to remember to rotate on an
unattended service.

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
registers non-interactively. **Run these from inside this folder**
(`C:\AltecAgents\HaloResponseAgent\`, or wherever you copied the files) —
`-s project` writes the registration to a `.mcp.json` file in the *current*
directory, which needs to be this one:

```powershell
cd C:\AltecAgents\HaloResponseAgent\   # -s project below writes .mcp.json here - must run from this folder

# Example: a Worker-hosted connector with a static Bearer token
claude mcp add --transport http Halo https://<your-halo-worker>/mcp `
    --header "Authorization: Bearer <token>" -s project

# Repeat per connector, each with its own endpoint/token. Avoid spaces in the
# name (e.g. use "Microsoft365", not "Microsoft 365") so the mcp__ prefix stays
# unambiguous:
claude mcp add --transport http <Name> <https-url> --header "Authorization: Bearer <token>" -s project

claude mcp list   # verify — note the exact names and connection status
```

**`-s project`, not `-s user` — this is not a style preference.** `claude mcp add`
defaults to (and many examples elsewhere use) `-s user`, which registers the
server only for the Windows account you're currently logged in as, in that
account's own `~/.claude.json`. `Register-HaloResponseAgentTask.ps1` runs the
scheduled task as `SYSTEM` (verified against Claude Code's own docs, not
assumed) — a completely separate Windows account with its own profile, which
would see *no* MCP servers registered under `-s user`, the same way it
wouldn't see a `claude setup-token`/`/login` credential stored under your
account either (see the API key note above). `-s project` writes to
`.mcp.json` in this folder instead — a plain file on disk, not tied to any one
account, readable by whichever account actually runs `Invoke-HaloResponseAgent.ps1`.
`Register-HaloResponseAgentTask.ps1` also sets the scheduled task's working
directory to this folder for exactly this reason - without both pieces, the
task would silently see zero MCP tools and do nothing but call `Read`, the
exact same failure shape as the naming bug two paragraphs up, just a different
root cause. `.mcp.json` holds the same real Bearer tokens/credentials you just
typed above in plain text — it's already in `.gitignore`, same reasoning as
`config.json`'s real secrets never going into git.

Since you've likely already been testing interactively as yourself with
`-s user` registrations from earlier in this setup, re-run the two `claude mcp add`
commands above with `-s project` before you ever rely on the scheduled task -
a `-WhatIf` run you triggered by hand will look identical either way, since
that's still your own account; only the actual scheduled firing (as `SYSTEM`)
exposes the difference. If `claude mcp add` complains about a name already
registered, remove the old `-s user` entry first (`claude mcp remove <name> -s user`)
rather than leaving both in place.

**Shortcut if you have more than a couple of connectors already registered
with `-s user`:** `Copy-McpServersToProject.ps1` copies your existing
`-s user` registrations (URLs, headers, tokens included) straight into a
`.mcp.json` in this folder, instead of re-typing every `claude mcp add`
command by hand. Only handles connectors that don't need further interactive
auth (see "Needs authentication" below) - run it from this folder:
```powershell
.\Copy-McpServersToProject.ps1
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
The classifier/resolver split (see "Two-stage pipeline" above) is itself the
main cost lever: a single-call design that ran every ticket through one big
agentic session cost **$4.13** for a 75-ticket / 7-candidate cycle at the
account defaults (`claude-opus-5`, effort `high`, adaptive thinking, 62 turns)
— most of that spend was full-tool-loop reasoning applied uniformly, including
to tickets that turned out to need nothing more than "ask for the missing
info." The two-stage design instead pays for a full tool loop only on tickets
the (cheap) classifier actually flagged as needing one.

`config.json`'s `claude` block controls the remaining levers:

```json
"claude": {
  "effort": "low",
  "classifier_model": "claude-haiku-4-5",
  "resolver_model_trivial": "claude-haiku-4-5",
  "resolver_model_medium": "claude-sonnet-5",
  "resolver_model_complex": "claude-sonnet-5"
}
```

- **`classifier_model`** — always cheap; the classifier never uses write tools
  and doesn't need frontier-tier reasoning to sort tickets into four buckets.
- **`resolver_model_trivial`/`_medium`/`_complex`** — the model the resolver
  uses for a ticket, chosen by the tier the classifier assigned it (`TRIVIAL`
  and `TRIVIAL_UNCERTAIN` both use `resolver_model_trivial`, since the latter
  just asks for missing info and stops rather than investigating). Sonnet is
  roughly 60% cheaper per token than Opus ($2/$10 per million tokens vs.
  $5/$25); Opus remains an option here for `_complex` if you want extra
  headroom on genuinely hard tickets specifically, without paying for it on
  every ticket.
- **`effort`** — one of `low`, `medium`, `high` (default), `xhigh`, `max`. The
  fallback default for the classifier and every resolver call. Lower effort
  means less thinking, fewer/more-consolidated tool calls, and less token
  spend, at some cost to thoroughness.
- **`classifier_effort`/`resolver_effort_trivial`/`_medium`/`_complex`**
  (optional, all omitted by default) — per-call overrides if you want finer
  control than one global `effort` value, e.g. `low` for the cheap
  Haiku-backed tiers and `medium` for Sonnet-backed ones as they get more
  capable. Each falls back to plain `effort` above when absent, so adding
  none of these behaves exactly like today. There's no separate
  `resolver_effort_approved` — the `APPROVED` tier (`-RequireApproval` only)
  reuses `resolver_model_trivial`'s model, so it reuses
  `resolver_effort_trivial` too.
  **Not every model accepts `--effort` at all** — Claude Haiku 4.5
  (`classifier_model`/`resolver_model_trivial`'s default) does NOT support it
  and the CLI rejects it if sent, so this script only ever sends `--effort`
  when the model actually being called that cycle is on its own
  confirmed-supported list (current Sonnet/Opus tiers) — setting
  `classifier_effort` or `resolver_effort_trivial` has no effect unless you
  also change the matching model to one that supports it. `-DryRun` shows
  exactly what would and wouldn't be sent, including a note when a configured
  effort value is being silently skipped for this reason.

**Compare a few `-WhatIf` runs' WOULD DO quality against a known-good baseline
before trusting a cheaper setting live** — judgment calls on escalation,
frustration detection, and root-cause investigation are exactly where a
cheaper model or lower effort is more likely to slip, and that risk now sits
specifically on `MEDIUM`/`COMPLEX` tickets (the ones the classifier itself
flagged as needing real judgment) rather than uniformly across every ticket.

Two more levers, both structural rather than config-driven:

- **ID pre-resolution (v2.1.0), now cached (v2.2.0).** Team/status/priority/
  agent name-to-ID lookups are deterministic and don't change between tickets
  in the same cycle, but the classifier and every single resolver call used to
  redundantly re-resolve them from scratch. A new stage (`id-resolver-prompt.md`)
  resolves them once per cycle, before the classifier, and injects the IDs
  directly into every downstream prompt - `list_teams`/`list_statuses`/
  `list_priorities`/`list_agents` were removed from the classifier's and
  resolver's tool allowlists entirely so the savings are guaranteed, not just
  hoped-for. As of v2.2.0 this resolution itself is cached to
  `resolved-ids-cache.json`, so most cycles skip even that one call: the cache
  is keyed on the exact `halo.*` names in `config.json` right now, so editing
  any of them (renaming the team, switching `agent_username`, etc.) invalidates
  it automatically, and `claude.id_cache_max_age_hours` (default 24) forces a
  fresh resolution periodically anyway, as a backstop for the rarer case where
  Halo itself changes (a team renamed, an agent account recreated) without
  `config.json`'s text changing at all. If any name fails to resolve (cached or
  fresh), the whole cycle aborts with a clear error rather than silently using
  a wrong ID on every ticket - a cache read problem of any kind (missing,
  corrupted) is always treated as a harmless cache miss, never a failure.
- **Skipping unchanged tickets.** A ticket already waiting on a client reply
  would get a full re-investigation and a full-price resolver call every
  cycle if nothing changed. `tracked-tickets.json` (gitignored, next to
  `resolved-ids-cache.json`) is a small local cache of ticket IDs still
  worth watching - the resolver adds one whenever it ends a ticket still
  expecting a reply, and the classifier checks only that small list each
  cycle (not the whole open-ticket backlog) for a new client reply, dropping
  a ticket from the cache once it's resolved or a human has taken it over.
  This only shows its effect on real (non-`-WhatIf`) runs, since `-WhatIf`
  never writes to this cache - a `-WhatIf` test will keep re-showing the
  same backlog every time regardless of this fix, because nothing ever
  really got marked handled.

`Show-AgentLog.ps1`'s CYCLE SUMMARY section shows ID resolution cost,
classifier cost, resolver cost, and a per-ticket cost/tier/model breakdown
every run, so you can verify a change actually reduced spend rather than just
assuming it did.

Other things worth knowing, not (yet) wired into the script:
- `--fallback-model sonnet,haiku` makes a call retry on a cheaper model if the
  primary is overloaded/unavailable — a reliability net, not a cost lever (it
  doesn't trigger on rate limits), and not currently exposed via config.json.
- Don't use `--bare` here even though it reduces per-call overhead elsewhere —
  it also skips MCP entirely, which is this agent's whole job.
- Running less often (raise `-IntervalMinutes` when registering the scheduled
  task) cuts total daily cost proportionally, at the cost of slower response
  to new tickets — a scheduling tradeoff, not a per-call one.

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
- Before running this against any client with regulated data (PCI/HIPAA/GLBA/SOX or similar), read "Excluding clients for compliance reasons" above — and read it as what it actually guarantees, not what it sounds like it guarantees.
