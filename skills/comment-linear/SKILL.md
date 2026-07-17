---
name: comment-linear
description: Post or update a comment on a Linear ticket using the Linear MCP server. Accepts a ticket ID (e.g. ENG-123), a Linear ticket URL, or a direct link to an existing comment. Works for both human-authored comments and agent-generated summaries.
---

# Comment on Linear Skill

## Steps

### 1. Resolve the Target

Accept the target from one of the following:
- **Ticket ID** — e.g. `ENG-123`
- **Ticket URL** — e.g. `https://linear.app/yourorg/issue/ENG-123`
- **Comment link** — e.g. `https://linear.app/yourorg/issue/ENG-123#comment-456` — extract the issue ID and comment ID from the URL

If no target is provided, ask the human for one before proceeding.

If the Linear MCP connector is not configured, prompt the human to set it up and stop.

### 2. Resolve the Issue

Use `mcp__linear__get_issue` with the issue identifier (e.g. `ENG-123`) to fetch issue details and confirm it exists before proceeding.

If the issue is not found, surface the error and stop.

### 3. Determine the Action

Ask (or infer from context) whether to:
- **Add a new comment** — post fresh content to the issue
- **Update an existing comment** — edit a specific comment by ID (required when a comment link was provided, or when the caller explicitly wants to update)

If the action is ambiguous, ask the human to clarify.

### 4. Compose the Comment

Accept the comment body from one of:
- **Inline text provided by the caller** (human message or agent output passed to this skill)
- **A file path** — read the file content and use it as the comment body
- **Interactive input** — if no content was provided, ask the human to type or paste the comment

**Identity footer:** Always append the following footer to every comment posted by this skill, separated from the body by a blank line:

```
---
_Posted by {agent identity} on behalf of the human_
```

If the comment is an update to an existing comment with this footer already present, replace the existing footer rather than appending a second one.

Format the comment in Markdown. Keep it concise — do not pad with filler.

### 5. Preview and Confirm

Show the human the final comment body and the target issue ID before posting. Ask:
> "Post this comment to `{issue-id}`? (yes / edit / cancel)"

Do not post without explicit confirmation. If the human selects "edit", accept revised content and re-show the preview.

### 6. Post the Comment

Use the Linear MCP connector:
- For **new comments**: use `mcp__linear__save_comment` with the issue ID and comment body.
- For **updating an existing comment**: use `mcp__linear__save_comment` with the comment ID to edit it.

On success, confirm to the caller: "Comment posted to `{issue-id}`."
On failure, surface the full error and ask the human how to proceed — do not retry silently.
