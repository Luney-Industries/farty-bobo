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

Use the Linear MCP to resolve the parent:
- Team → `mcp__linear__list_teams`
- Project → `mcp__linear__list_projects`
- Initiative → `mcp__linear__list_initiatives`
- Issue → the identifier they gave you (e.g. `LIN-123`), or `mcp__linear__get_issue` to confirm it exists
- Cycle → ask for the team too, since cycle names/numbers are disambiguated by team

If the Linear MCP connector is not configured, prompt the human to add it before proceeding.

## 3. Draft the document

Construct a draft with:

- **Title**: clear, one line
- **Content**: Markdown. The content MUST open with your identity line (as defined in CLAUDE.md) so readers don't mistake an agent-authored doc for a hand-written one:
  ```
  _Drafted by {your identity} on behalf of @<handle>._

  <the actual document content, structured with headings as appropriate>
  ```
- **Icon** (optional): suggest an emoji or icon name if it fits the doc's purpose
- **Color** (optional): leave unset unless the human asks for one

## 4. Review with human

Present the full draft — title, parent, and content — clearly. Remind the human that this will post the drafted content to Linear where it may be visible to the whole team. Do not create the document until explicitly approved.

## 5. Create the document

Once approved, call `mcp__linear__save_document` with `title`, `content`, and exactly one parent field (`team`, `project`, `initiative`, `cycle`, or `issue`) resolved in Step 2.

Report back:
- The document title
- A direct link to the document (Linear returns a URL/slug in the response — surface it)
- A one-line summary of what was created

## 6. Updating an existing document

If the human wants to edit a document instead of creating one, resolve it via `mcp__linear__get_document` or `mcp__linear__list_documents`, then call `mcp__linear__save_document` with its `id` set. Passing a parent on update reparents the document — only do this if the human explicitly asks to move it.
