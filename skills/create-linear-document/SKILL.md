---
name: create-linear-document
description: Creates a Linear document (the Documents feature, distinct from issues/projects) from context in the current conversation, a plan, or a file. Use when the user wants to write up a doc, spec, RFC, or notes page in Linear and attach it to a team, project, initiative, cycle, or issue.
---

# Create Linear Document

## 1. Gather content

Collect the document's content from whatever is available — in order of priority:

- **Arguments passed to the skill** (e.g. `/create-linear-document write up the migration plan`)
- **Current conversation context** — a plan, design discussion, or synthesis of recent work
- **A file or existing artifact** the human points to

If none of the above provide enough signal, ask the human what the document should cover.

## 2. Determine the parent

A Linear document requires exactly one parent: a **team**, **project**, **initiative**, **cycle**, or **issue**. Ask the human which one this document belongs to, unless it's obvious from context (e.g. they were just discussing a specific project).

Use the Linear MCP to resolve the parent to its ID — never pass a human-readable name straight into `save_document`:
- Team → `mcp__linear__list_teams`, use the resolved team ID
- Project → `mcp__linear__list_projects`, use the resolved project ID
- Initiative → `mcp__linear__list_initiatives`, use the resolved initiative ID
- Cycle → ask for the team too, then use `mcp__linear__list_cycles` (scoped to that team) to resolve the specific cycle; cycle names/numbers alone are ambiguous across teams
- Issue → call `mcp__linear__get_issue` with the identifier they gave you (e.g. `LIN-123`) to confirm it exists and obtain its ID; do not assume the human-readable identifier is accepted by `save_document` without confirming via `get_issue` first

Pass exactly one parent field to `save_document` — never more than one. If context makes more than one parent plausible (e.g. the human mentions both an issue and its project), ask which one the document should attach to; do not guess or pass both.

If the Linear MCP connector is not configured (i.e., `LINEAR_API_KEY` is not set in `mcp.env`), prompt the human to add it before proceeding.

## 3. Draft the document

Construct a draft with:

- **Title**: clear, one line
- **Content**: Markdown. The content MUST open with your identity line (as defined in CLAUDE.md) so readers don't mistake an agent-authored doc for a hand-written one:
  ```
  _Drafted by {your identity} on behalf of @<handle>._

  <the actual document content, structured with headings as appropriate>
  ```
- **Icon** (optional): only set if the human asks for one — pass an icon name or emoji code (e.g. `Rocket` or `:eagle:`), not a raw Unicode emoji
- **Color** (optional): leave unset unless the human asks for one

## 4. Review with human

Present the full draft — title, parent, and content — clearly. Remind the human that this will post the drafted content to Linear where it may be visible to the whole team. Do not create the document until explicitly approved.

## 5. Create the document

Once approved, call `mcp__linear__save_document` with `title`, `content`, and exactly one parent field (`team`, `project`, `initiative`, `cycle`, or `issue`) resolved in Step 2.

Report back:
- The document title
- Whatever id/slug/link the `save_document` response actually contains — report only what the tool returned; do not construct or guess a URL if it isn't present in the response
- A one-line summary of what was created

## 6. Updating an existing document

If the human wants to edit a document instead of creating one, resolve it via `mcp__linear__get_document` or `mcp__linear__list_documents`, then call `mcp__linear__save_document` with its `id` set. `title` is only required when creating — when updating, you may pass just `id` and the fields you're changing (e.g. `content`) and omit `title` and the parent entirely. Passing a parent on update reparents the document — only do this if the human explicitly asks to move it.
