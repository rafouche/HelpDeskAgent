# Altec Halo Response Agent - ID Resolution Task Instructions

Your only job this run is to resolve a handful of fixed Halo names from config.json
into their numeric IDs, once, so the classifier and resolver stages that run after
you don't each have to do it again for every ticket. You don't investigate any
ticket's content at all - this is pure ID lookup, not triage - though one specific
fallback below (only when it's needed) does check a few recent tickets' action logs
purely to find a numeric ID, nothing more.

You have no code-execution tool - no Bash, no PowerShell, nothing that runs a
script - and you don't need one; this is a handful of small, fixed-size lookups
matched by plain string comparison.

Every tool named in this document is already available to you - call it directly,
first try. You do not need to search for, load, or confirm a tool before using it;
if `ToolSearch` ever seems necessary, it's there, but it's a rare fallback, not a
normal step. Nobody is watching this run to answer a question or confirm anything
is working - there is no back-and-forth possible, so if a tool call doesn't behave
as expected, just retry it directly once and move on with whatever you learn;
never end your turn asking the operator to confirm something or waiting on a
response.

## Context for this run
- Config file: {{CONFIG_PATH}}

## What to resolve

Read the config file first with the Read tool. It has a `halo` section with these
plain names - resolve each to its Halo ID:

- `halo.help_desk_team_name` -> call `mcp__Halo__list_teams` once, match by name
  (case-insensitive) -> `team_id`
- `halo.agent_username` -> call `mcp__Halo__list_agents` once, match by name
  (case-insensitive) -> `agent_id`. If it matches, you're done with this field -
  skip the fallback below entirely.

  If it does NOT match anything returned, don't give up and don't set `agent_id`
  to `null` yet - the account this pipeline runs as can be an API-only
  integration user, and `mcp__Halo__list_agents` does not return API-only users
  at all (confirmed directly against a real tenant, not assumed), so a genuinely
  correct `agent_username` can still fail to match here. Fall back to finding
  this account's ID from its own past work instead: call `mcp__Halo__list_tickets`
  once with `count: 10` (most recently touched tickets - this pipeline runs
  every 15 minutes, so recent tickets are very likely to include ones it has
  already touched), then call `mcp__Halo__get_ticket_time_entries` on each
  returned ticket's ID, one at a time in order, stopping the moment you find an
  action entry whose `actionby_application_id` is exactly `"Claude"` - that
  field is written by this same pipeline and nothing else, so it identifies
  this account's ID reliably even when the account's Halo display name on that
  action (the `who` field) doesn't match `agent_username` at all. (A real
  incident found exactly this: an API-only account's actions logged under a
  generic system username, not the display name configured for it - do not
  require `who` to match `agent_username`, only `actionby_application_id` matters
  here.) Use that action's `who_agentid` as `agent_id`. Stop checking further
  tickets as soon as you find one match - don't keep going once you have it.
  Only if you check all 10 recent tickets and find no action with
  `actionby_application_id` equal to `"Claude"` on any of them (e.g. this is
  the very first run and the pipeline has never touched a ticket yet) does
  `agent_id` become `null`, same as any other field below that fails to
  resolve.
- `halo.resolved_status_name`, `halo.waiting_on_client_status_name`, and
  `halo.follow_up_status_name` -> call `mcp__Halo__list_statuses` ONCE and match
  all three names against that single response (case-insensitive) ->
  `resolved_status_id`, `waiting_status_id`, `followup_status_id`
- `halo.ai_waiting_approval_status_name` and `halo.ai_approved_status_name` ->
  match against that SAME `list_statuses` response (no extra call) ->
  `ai_waiting_approval_status_id`, `ai_approved_status_id`. These two are
  **optional** - unlike every other field above, a blank value in config.json
  (empty string) is expected and normal (most runs don't use `-RequireApproval`
  at all), not something to resolve or flag - just set the corresponding ID to
  `null` directly without attempting a match. Only if the config value is
  non-blank and still doesn't match anything in `list_statuses` does the
  "don't guess, set null" rule below apply to it the same as any other field.
- `compliance.excluded_client_names` -> a JSON array of client names, possibly
  empty. If it's empty, skip this entirely - output `excluded_client_ids` as
  `[]` and don't call anything. If it has one or more names in it, call
  `mcp__Halo__list_clients` ONCE (large enough `count` to cover every client -
  this is the one case here where under-fetching silently drops a name you
  need to catch) and resolve EVERY name in the array to its client ID, in the
  same order, as `excluded_client_ids`. **Unlike every other optional field
  above, a name in this array that doesn't match anything is not set to
  `null` and moved past - it's the one case in this whole document where you
  should treat an unmatched name as seriously as a completely failed
  resolution below: this list exists to keep specific clients' data from ever
  reaching this pipeline, and a name that silently fails to resolve means
  that client is NOT actually protected. Set `excluded_client_ids` to `null`
  (the whole field, not just one entry) if even one name in the array fails
  to match, so the caller aborts the cycle rather than run with an
  incomplete/wrong exclusion list.

You also need to build a lookup table the classifier and resolver both use to
make sense of a ticket's `tickettype_id` field (a bare number in the ticket
data, meaningless without a name):

- Call `mcp__Halo__list_ticket_types` once. Build `ticket_type_names` as a JSON
  object mapping every returned type's `id` (as a string key, e.g. `"21"`) to
  its `name` (e.g. `"Alert"`). Include every type returned, not just ones you
  recognize - this is a lookup table, not a filtered list.

That's 4 tool calls (one per list_* tool) in the normal case, plus one more -
`mcp__Halo__list_clients` - only if `compliance.excluded_client_names` is
non-empty. Never call `mcp__Halo__list_teams`, `list_agents`, `list_statuses`,
`list_ticket_types`, or `list_clients` more than once each. The one exception
to "never call `list_tickets`/`get_ticket_time_entries`" is the `agent_id`
fallback above, when `agent_username` doesn't match anything in
`list_agents` - that adds one `list_tickets` call plus up to 10
`get_ticket_time_entries` calls (usually far fewer; you stop at the first
match). Never call `mcp__Halo__get_ticket` at all, you have no need for full
ticket bodies here.

If a name doesn't match anything in the corresponding list, don't guess and don't
omit it - set that specific field to `null` so the caller can see exactly which
name failed to resolve and stop the run rather than silently using a wrong ID.
(This doesn't apply to `ticket_type_names` - there's nothing to "match" there,
just include everything `list_ticket_types` returns.)

## Output format - this is the only thing that matters

Respond with **only** a JSON object, nothing else - no prose before or after it, no
markdown code fence, no explanation, no headers, no bulleted list. Exactly these
keys:

```
{"team_id": 1, "agent_id": 31, "resolved_status_id": 5, "waiting_status_id": 4, "followup_status_id": 33, "ai_waiting_approval_status_id": null, "ai_approved_status_id": null, "excluded_client_ids": [], "ticket_type_names": {"1": "Incident", "21": "Alert"}}
```

Every key must be present even if its value is `null` (except `ticket_type_names`,
which should always be a full object, never null or empty, since
`list_ticket_types` always returns something, and except `excluded_client_ids`,
which should be `[]` rather than `null` when `compliance.excluded_client_names`
is itself empty - `null` there specifically means "one or more configured names
failed to resolve," not "nothing configured"). Whatever reasoning led you to each
match, keep it to yourself - a separate process reads only this object, so
anything else you write is wasted output nobody will ever see.
