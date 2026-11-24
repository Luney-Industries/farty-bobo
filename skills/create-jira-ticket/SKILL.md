---
name: create-jira-ticket
description: Creates a Jira ticket from context in the current conversation or codebase. Use when the user wants to log a bug, feature request, task, or spike in Jira.
---

# Create Jira Ticket

## Pre-approved mode (follow-up tickets from `/critique`)

`/critique` Step 10 calls this skill for each follow-up box the human checked in `_critique-consolidated.md`. **The checked box is the human's explicit approval.** In this mode, this section overrides the interactive steps below:

- **Site, project, epic, sprint:** use the parent ticket's. Do not ask.
- **Issue type:** Task, or the closest valid type for the project. Do not ask. Labels: the parent's. Priority defaults to Medium.
- **Summary:** `[{parent-id} {finding-id}] {short title}`, for example `[PROJ-123 MEDIUM-3] Loose status match`. `/critique` uses this tag to find duplicates.
- **Description:** the identity line and template from Step 4, in ADF, filled with the context `/critique` passed in, plus links to the parent ticket and the PR.
- **Link:** link the new ticket to the parent with a "relates to" link.
- If a required field can't be filled from the parent, ask the human for that one field only.
- **Skip Step 5 entirely.** No draft review and no codebase-context confirmation: the human approved filing this context by checking the box.
- Run Step 6 and report back to `/critique`.

Use pre-approved mode **only** when `/critique` invokes the skill for a checked box. Every other invocation, including a human typing `/create-jira-ticket`, follows the full interactive flow below.

## 1. Gather context

Collect information about the ticket from whatever is available — in order of priority:

- **Arguments passed to the skill** (e.g. `/create-jira-ticket fix the login redirect bug`)
- **Current conversation context** — recent discussion, errors, code snippets
- **Codebase context** — open files, git diff, recent commits, error logs

If none of the above provide enough signal, ask the human to describe the issue or feature in plain text.

## 2. Determine Jira workspace and project

Use the Atlassian connector to list accessible Atlassian sites and available Jira projects. If the connector is not configured, prompt the human to set it up before proceeding.

If the human has previously used a project in this conversation, default to that. Otherwise ask the human to pick a project from the list.

## 3. Determine issue type

Use the Atlassian connector to fetch valid issue types for the selected project.

Based on the context, suggest the most appropriate type (Bug, Story, Task, Spike, etc.) and confirm with the human if it's not obvious.

## 4. Draft the ticket

Construct a draft with the following fields — infer as much as possible from context:

- **Summary**: one-line title, clear and actionable
- **Description**: structured using this template. The description MUST open with your identity line (as defined in CLAUDE.md) so reviewers don't mistake an agent-filed ticket for a hand-authored one:
  ```
  _Filed by {your identity} on behalf of @<github-or-jira-handle>._

  ## Context
  <what is happening / what needs to be done>

  ## Expected behavior / Goal
  <what should happen>

  ## Acceptance Criteria
  - <criterion 1>
  - <criterion 2>

  ## Notes
  <any relevant links, code references, error messages. Do not attribute to "Claude Code" — attribute to your identity as defined in CLAUDE.md.>

  ```
- **Issue type**: as determined in step 3
- **Priority**: infer from context (Critical/High/Medium/Low) — default to Medium if unclear
- **Labels**: suggest relevant labels based on context (optional)
- **Sprint**: Default to Next
- **Epic**: ask the human if they want to link this ticket to an epic; if yes, use the Atlassian connector to list available epics in the project and let them pick one
- **Assignee**: leave unset unless the human specifies

Use the Atlassian connector to check which fields are required for the chosen issue type and project.

Format the description as **Atlassian Document Format (ADF)** — not markdown. Use ADF paragraph, bulletList, and heading nodes as appropriate.

## 5. Review with human

Present the full draft clearly. Remind the human that this will post codebase context (code snippets, error messages, etc.) to Jira — confirm they're comfortable with that before proceeding. Do not create the ticket until explicitly approved. (Skipped in pre-approved mode; see the top of this skill.)

## 6. Create the ticket

Once approved, use the Atlassian connector to create the ticket.

Report back:
- The ticket key (e.g. `PROJ-123`)
- A direct link to the ticket
- A one-line summary of what was created
