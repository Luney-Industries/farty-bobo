---
name: create-linear-ticket
description: Creates a Linear issue from context in the current conversation or codebase. Use when the user wants to log a bug, feature request, task, or chore in Linear.
---

# Create Linear Ticket

## 1. Gather context

Collect information about the ticket from whatever is available — in order of priority:

- **Arguments passed to the skill** (e.g. `/create-linear-ticket fix the login redirect bug`)
- **Current conversation context** — recent discussion, errors, code snippets
- **Codebase context** — open files, git diff, recent commits, error logs

If none of the above provide enough signal, ask the human to describe the issue or feature in plain text.

## 2. Determine Linear team

If the Linear MCP connector is not configured (i.e., `LINEAR_API_KEY` is not set in `mcp.env`), prompt the human to add it before proceeding.

Use the Linear MCP to list available teams. If the human has previously used a team in this conversation, default to that. Otherwise ask the human to pick a team from the list.

## 3. Determine issue type and labels

Fetch available labels for the team using the Linear MCP. Based on context, suggest the most appropriate label(s) and confirm with the human.

## 4. Draft the ticket

Construct a draft with the following fields — infer as much as possible from context:

- **Title**: one-line summary, clear and actionable
- **Description**: structured using this template. The description MUST open with your identity line (as defined in CLAUDE.md) so reviewers don't mistake an agent-filed ticket for a hand-authored one:
  ```
  _Filed by {your identity} on behalf of @<handle>._

  ## Context
  <what is happening / what needs to be done>

  ## Expected behavior / Goal
  <what should happen>

  ## Acceptance Criteria
  - <criterion 1>
  - <criterion 2>

  ## Notes
  <any relevant links, code references, error messages>
  ```
- **Priority**: infer from context (Urgent/High/Medium/Low/No priority) — default to Medium if unclear
- **Labels**: suggest relevant labels based on context
- **Assignee**: use `"me"` if the human wants to self-assign; leave unset otherwise
- **Project**: ask the human if they want to link this ticket to a project; if yes, use the Linear MCP to list available projects and let them pick
- **Cycle**: default to the active cycle if one exists; otherwise leave unset

## 5. Review with human

Present the full draft clearly. Remind the human that this will post codebase context (code snippets, error messages, etc.) to Linear — confirm they're comfortable with that before proceeding. Do not create the ticket until explicitly approved.

## 6. Create the ticket

Once approved, call `mcp__linear__save_issue` with at minimum `title` and the `teamId` resolved in Step 2 (use the UUID, not the display name). Pass all other drafted fields as additional parameters.

Report back:
- The issue identifier (e.g. `YOU-123`)
- A direct link to the issue (`https://linear.app/{org}/issue/{id}`)
- A one-line summary of what was created
