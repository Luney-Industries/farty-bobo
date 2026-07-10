---
name: create-linear-project
description: Creates a Linear project under an initiative from a draft list of tickets, clarifies ambiguity with the human, then creates the project and each ticket via /create-linear-ticket. Use when the user wants to stand up a new project in Linear from a plan, doc, or ticket list.
---

# Create Linear Project

## 1. Gather required inputs

This skill needs three things up front. If any are missing from the invocation or conversation context, ask the human directly:

- **Project name**
- **Initiative name** — the initiative this project will be linked under
- **Project lead** — who owns the project

## 2. Gather the ticket draft

Collect the reference to the draft list of tickets that need to be completed. This may come in any form:

- A pasted list or markdown block in the conversation
- A path to a local markdown/text file
- A link to a Figma planning diagram or board
- A link to a Google Doc, Confluence page, Notion page, etc.

Resolve the reference into a concrete list of candidate tickets:

- For local files, read them directly.
- For Figma links, use the Figma MCP tools if available.
- For other links (Docs, Confluence, Notion, etc.), use the relevant MCP/tool if available; otherwise ask the human to paste the content.

Extract for each candidate ticket whatever is present: title, description, priority, sequencing/ordering, and dependencies on other tickets in the list. Do not invent fields that aren't there — leave them blank for now.

## 3. Determine Linear team and initiative

If the Linear MCP connector is not configured (i.e., `LINEAR_API_KEY` is not set in `mcp.env`), prompt the human to add it before proceeding.

- Use `mcp__linear__list_teams` to resolve the team (same rules as `/create-linear-ticket`: default to a team already used in this conversation, otherwise ask). A project can span multiple teams and each ticket needs its own team — for simplicity this skill assumes a single team applies to the project and all its tickets; call this assumption out to the human when confirming the plan in Step 5.
- Use `mcp__linear__list_initiatives` (its `query` param supports name search) to find the initiative matching the name given in Step 1. If there's no exact match, present close matches and confirm with the human, or offer to create a new one with `mcp__linear__save_initiative` — do not create one without explicit confirmation.
- Confirm the **project lead** by name/email against `mcp__linear__list_users` / `mcp__linear__get_user` if ambiguous. `save_project`'s `lead` field accepts a name, email, or `"me"` directly — you only need to disambiguate for the human, not resolve to a UUID.

## 4. Ask clarifying questions

Before creating anything, review the extracted ticket list for ambiguity and gaps. For each ticket (or the list as a whole), look for:

- Vague or missing acceptance criteria
- Unclear scope boundaries between tickets
- Missing or ambiguous priority
- Unclear or contradictory sequencing/dependencies
- Tickets that seem to overlap or should be merged/split

Batch these into a focused set of clarifying questions (use `AskUserQuestion` where the options are well-defined, otherwise ask in plain text). Do not proceed to creation until the ambiguity that would materially affect ticket content or ordering has been resolved. Avoid asking about things that don't matter — the goal is clarity, not exhaustive interrogation.

Update your working ticket list with the answers.

## 5. Review project + ticket plan with human

Present:

- The resolved project name, initiative, and lead
- The finalized list of tickets, each with title, priority, sequencing position, and dependencies

Remind the human that ticket descriptions will post codebase context (code snippets, error messages, links) to Linear — same caveat `/create-linear-ticket` gives per-ticket, called out once here for the whole batch. Also tell them explicitly: because the human already approved this full plan, per-ticket creation in Step 7 will proceed without re-confirming team/priority/project for each ticket — only `/create-linear-ticket`'s own content draft will still be shown per ticket. Confirm this is correct before creating anything in Linear.

## 6. Create the project

Once approved, call `mcp__linear__save_project` with:

- `name`: the project name
- `addTeams`: `[resolved team name or ID]`
- `addInitiatives`: `[resolved initiative name or ID]`
- `lead`: resolved project lead (name, email, or `"me"`)

Prefix the project description (if one is drafted) with your identity line, same as ticket descriptions (Step 7).

Report the created project's identifier and link.

## 7. Create each ticket via /create-linear-ticket

Iterate over the finalized ticket list **in sequencing order** (respecting any dependencies — a ticket should generally be created after the tickets it depends on, so it can reference them). For each ticket, invoke the `create-linear-ticket` skill, passing it explicit values so it doesn't need to re-infer or re-ask for things already settled in Step 5's plan approval:

- The ticket's title and description/acceptance criteria as drafted and clarified
- The priority
- The team resolved in Step 3 (pass explicitly so it isn't re-asked)
- The project created in Step 6, so the ticket is linked to it (pass explicitly so it isn't re-asked whether to link a project)

`/create-linear-ticket` will still show its own content draft for human confirmation per ticket (per Step 5 of that skill) — that step is not skipped, only the team/project selection is short-circuited using the values already approved.

After each ticket is created, if it has dependencies on tickets created earlier in this same run, wire them as real Linear relations via `mcp__linear__save_issue` on the new ticket: pass `blockedBy` with the dependency tickets' identifiers/IDs (or `blocks` if this ticket blocks an earlier one). Do not rely on free-text dependency notes in the description — those don't create queryable relations. If a dependency is on a ticket that hasn't been created yet (shouldn't happen given sequencing order, but if it does), note it and circle back to wire the relation once that ticket exists.

If ticket creation fails partway through the list, stop and report exactly which tickets were created (with links) and which were not, so a re-run doesn't duplicate work.

## 8. Final report

Once all tickets are created, report back:

- The project identifier and link
- The initiative it's linked to
- A list of all created tickets with their identifiers and links, in sequencing order, noting which dependency relations were wired
