---
name: ship-task
description: Merges the PR related to the current task and transitions the related ticket to Done. Supports both Linear and Jira (Atlassian). Confirms all actions with the human before executing.
---

# Ship Task

Merge the open PR for the current branch and close the related ticket (Linear or Jira). **Always confirm the exact actions with the human before executing anything.**

---

## Step 1 — Discover the PR

```sh
gh pr view --json number,title,url,state,isDraft,baseRefName,headRefName,mergeable,mergeStateStatus,statusCheckRollup
```

Handle each case:

- **`state` is `MERGED`**: PR was already merged. Skip to Step 5 (ticket transition only).
- **`state` is `CLOSED`** (unmerged): inform the human and stop — do not transition the ticket.
- **`isDraft` is true**: warn the human. Ask whether to mark it ready (`gh pr ready <number>`) before merging or abort.
- **`mergeable` is `UNKNOWN`**: GitHub is still computing merge conflict status. Wait 5 seconds and retry up to 3 times. If still `UNKNOWN` after retries, inform the human and stop.
- **`mergeable` is `CONFLICTING`**: surface the merge conflict and stop. Do not proceed until resolved.
- **`mergeStateStatus`**: check for blocking states before asking the human to confirm anything:
  - `BLOCKED` — branch protection rules unsatisfied (required reviews, required checks). Surface which checks are blocking and stop.
  - `BEHIND` — branch is behind base. Inform the human; offer to rebase/merge base in if desired.
  - `DRAFT` — redundant with `isDraft` check above; handle the same way.
  - `CLEAN` or `HAS_HOOKS` — proceed.
- **`statusCheckRollup`**: scan for any check with `conclusion` of `FAILURE` or `TIMED_OUT`. If found, list the failing checks by name and offer to invoke `/resolve-ci-failures` before proceeding.

---

## Step 2 — Discover the ticket

Look for a ticket reference in this order:

1. **Branch name** — parse the current branch for a ticket ID pattern `[A-Z]+-[0-9]+` (e.g. `ENG-123`, `PLT-42`)
2. **PR title / body** — `gh pr view --json title,body` and scan for the same pattern
3. **Recent commits** — `git log --oneline -20` and scan commit messages
4. **Human** — if no ticket ID is found, ask the human to provide one. If they confirm there is none, set `TICKET_ID=none` and skip Steps 5b onward.

Once a candidate ID is found, determine the tracker:
- If Linear MCP tools are available (`mcp__linear__get_issue` or `mcp__claude_ai_Linear__get_issue`): try fetching the issue by ID. If it resolves → **tracker = Linear**.
- If Atlassian MCP tools are available (`mcp__claude_ai_Atlassian__*`): try fetching the Jira issue. If it resolves → **tracker = Jira**.
- If both resolve, ask the human which tracker to use.
- If neither resolves and no MCP tool is available, set `TICKET_ID=none` — you will instruct the human to close manually at the end.

Record the resolved `TRACKER` (Linear | Jira | none) and `TICKET_ID` — carry these values into all subsequent steps.

---

## Step 3 — Confirm with the human

Before doing **anything** irreversible, present a clear confirmation summary. Use the values gathered in Steps 1–2:

```
Here's what I'm about to do — confirm or reject each item:

  [1] Merge PR #<number> "<title>"
        Branch:    <headRefName> → <baseRefName>
        URL:       <url>
        Method:    squash merge  (preferred; will re-confirm if repo requires a different method)
        After merge: delete branch <headRefName>

  [2] Transition ticket <TICKET_ID> "<ticket title>"   ← omit this block if TICKET_ID=none
        Tracker:   <Linear | Jira>
        From:      <current status>
        To:        Done  (or equivalent terminal state in your workflow)

Type YES to proceed, NO to abort, or tell me what to change.
```

**Do not proceed until the human types YES (exact word, case-insensitive). Treat any other response as a change request or abort.**

---

## Step 4 — Merge the PR

Use `gh` to merge with squash as the default:

```sh
gh pr merge <number> --squash --delete-branch
```

If `--squash` is rejected by the repo (squash merges disabled), **stop and re-confirm with the human** before retrying with `--merge`. Do not silently fall through to a different merge strategy — the human approved squash specifically.

Capture the merge commit SHA from the output (look for the SHA line in `gh pr merge` stdout or run `gh pr view <number> --json mergeCommit --jq '.mergeCommit.oid'` after the merge).

If the merge fails for any reason: stop, report the full error, and do not attempt the ticket transition.

---

## Step 5 — Transition the ticket

Skip this step entirely if `TICKET_ID=none`.

### Linear

Fetch the issue using `mcp__linear__get_issue` (or `mcp__claude_ai_Linear__get_issue`) to get the `teamId`. Then fetch available workflow states for that team and find the terminal state whose name matches "Done", "Completed", "Shipped", or "Closed" (exact match first, then case-insensitive substring).

**Idempotency:** If the issue is already in a terminal state, skip the transition and inform the human.

```
mcp__linear__save_issue  (or mcp__claude_ai_Linear__save_issue)
  issueId: <id>
  stateId: <done-state-id>
```

### Jira

Use the Atlassian MCP to fetch available transitions. Discover tool names at runtime (search for `getTransitionsForJiraIssue` or equivalent). Find the transition whose name matches "Done", "Closed", or "Resolved" (exact match first, then case-insensitive substring). If ambiguous, surface all candidates to the human to choose.

**Idempotency:** Fetch the current issue status first. If it is already in a terminal state, skip the transition and inform the human.

Execute using `transitionJiraIssue` (or equivalent discovered tool).

### Fallback

If neither MCP tool is available or the transition fails, print the direct ticket URL and instruct the human to close it manually.

---

## Step 6 — Report

Print a brief summary:

```
✓ PR #<number> merged  (SHA: <merge-sha>)
✓ Branch <headRefName> deleted
✓ Ticket <TICKET_ID> transitioned → Done
```

Omit the ticket line if `TICKET_ID=none`. If the ticket transition was not possible, call that out clearly so the human can finish manually.
