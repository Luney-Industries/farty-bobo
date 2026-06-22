---
name: ship-task
description: Merges the PR related to the current task and transitions the related ticket to Done. Supports both Linear and Jira (Atlassian). Confirms all actions with the human before executing.
---

# Ship Task

Merge the open PR for the current branch and close the related ticket (Linear or Jira). **Always confirm the exact actions with the human before executing anything.**

---

## Step 1 — Discover the PR

```sh
gh pr view --json number,title,url,state,isDraft,baseRefName,headRefName,mergeable,statusCheckRollup
```

- If no PR exists: inform the human and stop.
- If the PR is still a **draft**: warn the human. Ask whether to mark it ready before merging or abort.
- If `mergeable` is not `"MERGEABLE"` (conflicts, failed checks, etc.): surface the issue and stop. Do not proceed until it is resolved.
- If CI checks are failing: offer to invoke `/resolve-ci-failures` first, then come back.

---

## Step 2 — Discover the ticket

Look for a ticket reference in this order:

1. **Branch name** — parse the current branch for a ticket ID pattern:
   - Linear: `[A-Z]+-[0-9]+` (e.g. `ENG-123`, `PLT-42`)
   - Jira: same pattern but Jira project keys tend to be all-caps, 2–10 letters
2. **PR title / body** — `gh pr view --json title,body` and scan for the same patterns
3. **Recent commits** — `git log --oneline -20` and scan commit messages
4. **Human** — if no ticket ID is found after the above, ask the human to provide one or confirm there is none

Once a candidate ID is found, determine the tracker:
- If Linear MCP tools are available (`mcp__linear__get_issue` or `mcp__claude_ai_Linear__get_issue`): try fetching the issue by ID. If it resolves → Linear.
- If Atlassian MCP tools are available (`mcp__claude_ai_Atlassian__*`): try fetching the Jira issue. If it resolves → Jira.
- Use whichever tracker successfully returns the issue. If both resolve, ask the human which one to use.
- If neither resolves and no MCP tool is available, fall back to describing the transition the human must do manually.

---

## Step 3 — Confirm with the human

Before doing **anything** irreversible, present a clear confirmation summary:

```
Here's what I'm about to do — confirm or reject each item:

  [1] Merge PR #<number> "<title>"
        Branch:  <headRefName> → <baseRefName>
        URL:     <url>
        Method:  squash merge  (or merge commit if repo default differs)

  [2] Transition ticket <ID> "<ticket title>"
        Tracker:  <Linear | Jira>
        From:     <current status>
        To:       Done  (or equivalent terminal state in your workflow)

Type YES to proceed, NO to abort, or tell me what to change.
```

**Do not proceed until the human types YES (case-insensitive) or an equivalent clear affirmation.**

---

## Step 4 — Merge the PR

Use `gh` to merge. Prefer squash merge unless the repo's branch protection rules require otherwise:

```sh
gh pr merge <number> --squash --delete-branch
```

If `--squash` fails (e.g. repo disables squash), retry with `--merge`, then `--rebase`. Report whichever method succeeds.

If the merge fails for any reason: stop, report the error, and do not attempt the ticket transition.

---

## Step 5 — Transition the ticket

### Linear

Use the Linear MCP to fetch available workflow states for the team, find the terminal "Done" state (or the state whose name matches "Done", "Completed", "Shipped", "Closed" — pick the closest), then update the issue:

```
mcp__linear__save_issue  (or mcp__claude_ai_Linear__save_issue)
  issueId: <id>
  stateId: <done-state-id>
```

### Jira

Use the Atlassian MCP to fetch available transitions for the issue. Discover tool names at runtime (search for `getTransitionsForJiraIssue` or equivalent). Find the transition whose name matches "Done", "Closed", or "Resolved" (exact match first, then case-insensitive substring). Execute it using `transitionJiraIssue` (or equivalent discovered tool).

**Idempotency:** Fetch the current issue status first. If it is already in a terminal state, skip the transition and inform the human.

If neither MCP tool is available or the transition fails, print the manual URL and instruct the human to close the ticket themselves.

---

## Step 6 — Report

Print a brief summary of what was done:

```
✓ PR #<number> merged (<merge-sha>)
✓ Ticket <ID> transitioned → Done
```

If the ticket transition was not possible (no MCP, API error, etc.), call that out clearly so the human can finish manually.
