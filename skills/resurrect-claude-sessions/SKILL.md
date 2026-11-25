---
name: resurrect-claude-sessions
description: Find your Linear or Jira tickets that are In Progress or In Review but have no live Claude Code session working on them, and print them as a table of Ticket URL | Session ID | Last active, with a `claude --resume` command for each dead session. Use when the user asks "which tickets have no Claude session?", "what work got orphaned?", "resurrect my dead sessions", "which in-progress tickets lost their session?", or similar. Optional argument: `linear` or `jira` to pick the tracker (default: every tracker that is connected).
model: sonnet
---

# Resurrect Claude Sessions

Find tickets assigned to you that are **In Progress** or **In Review**, but that no live Claude Code session is working on. For each one, find the last local session that worked on it, so the human can resume it.

This skill only reads. It never starts or resumes a session, and never changes a ticket.

Scripts live next to this file: `SCRIPT_DIR="<directory of this SKILL.md>/scripts"`.

| Script | Purpose |
|---|---|
| `find-ticket-sessions.sh [exclude_session_id] < tickets.json` | Scans local transcripts (`~/.claude/projects`) once and ranks sessions per ticket. stdin: `[{ticket, branch}]`. stdout: `{"<TICKET>": [candidates...]}`, every input ticket a key (possibly `[]`). Skips the transcript whose id is `exclude_session_id`. Only scans transcripts touched in the last 30 days; set `RCS_MAX_AGE_DAYS` to change that (`0` scans everything). Exits 1 with empty stdout if the scan fails. |

Candidate fields you use: `session_id`, `agent_name`, `cwd`, `cwd_exists`, `confidence` (`strong` = the session ran on the ticket's branch or is named after the ticket; `weak` = it only mentions the ticket), `last_active` (epoch seconds). The full field list is in the script header.

**Ticket key match.** Wherever this skill says a name "contains the ticket key", it means: the key appears case-insensitively, not preceded by a letter, digit or `_`, and not followed by a digit. `YOU-12` matches `YOU-12/fix-login` and `kfaham/you-12-fix`, but not `YOU-123/...` or `XYOU-12`. This is the same rule the scanner uses.

---

## Phase 1 — Pick the tracker(s)

Read the argument:

- `linear` → Linear only. `jira` → Jira only.
- No argument → every tracker whose tools are available. Query them all and merge the results.

Tool discovery (load deferred tools with `ToolSearch` first):

- **Linear:** `mcp__linear__list_issues` and `mcp__claude_ai_Linear__list_issues`. If both exist, query both: they can be signed in to different workspaces. Merge the results and drop duplicates by `id`.
- **Jira:** the Atlassian MCP tools (`mcp__claude_ai_Atlassian__*`). Call `getAccessibleAtlassianResources`. If only `authenticate` is exposed, or that call fails, Jira isn't connected. With no argument, skip it and say so in the output. With the `jira` argument, tell the human to authenticate the Atlassian connector and stop.

If no tracker is connected, say so and stop.

## Phase 2 — Fetch the tickets

Only tickets **assigned to the human**.

**Linear:** call `list_issues` with `assignee: "me"`, `state: "started"`, `limit: 250`, and `fields: ["id","url","status","gitBranchName"]`. Keep calling with `cursor` while `hasNextPage` is true. `id` is the ticket key (e.g. `YOU-123`).

**Jira:** use the sites from `getAccessibleAtlassianResources`. Each result has an `id` (the `cloudId`) and a `url` (the site URL). Call `atlassianUserInfo` once to get the human's `accountId`. Then, for **each** site:

1. Call `searchJiraIssuesUsingJql` with `cloudId: <id>`, `fields: ["status"]`, `maxResults: 100`, and this JQL:

```jql
assignee = "<accountId>" AND statusCategory = "In Progress" ORDER BY updated DESC
```

2. Keep calling with `nextPageToken` until the response has none.
3. For each issue, take the `key`, the status name (`fields.status.name`), and the URL `<site url>/browse/<KEY>`. Jira gives no branch name, so use `""`.

**Status filter:** the "started" / "In Progress" category can include more than In Progress and In Review (for example "QA" or "Blocked"). Keep a ticket only if its status name contains `progress` or `review` (case-insensitive). Count the tickets you dropped, grouped by status name, for the footnotes in Phase 5.

If no tickets remain, say so and stop.

## Phase 3 — List live sessions

Load the tool with `ToolSearch` `select:ListAgents` if it is deferred. Then call `ListAgents`, following `cursor` until the listing ends.

Rows print as `name [ref]`. For every peer row, store the **name without the trailing ` [ref]`**. This bare name is what you compare in Phase 4. The header line names this session, and this session is never in the list.

Only if loading or calling `ListAgents` fails, treat the live list as empty and say so in the output, because then every ticket will look dead.

## Phase 4 — Scan transcripts and decide who is dead

Build the stdin array, one entry per ticket: `{"ticket": "<KEY>", "branch": "<gitBranchName or empty>"}`.

Check `$CLAUDE_CODE_SESSION_ID` first. If it is empty, warn in the output: "Couldn't find this session's id, so this session's own transcript may show up as a candidate."

Run the scanner once with a heredoc, so no temp file is needed. Pass the session id explicitly as the first argument. The scan can take a minute on a big transcript folder, so give the Bash call a 5-minute timeout:

```bash
"$SCRIPT_DIR/find-ticket-sessions.sh" "$CLAUDE_CODE_SESSION_ID" <<'EOF'
[{"ticket":"YOU-9638","branch":"kfaham/you-9638-add-the-submission-tracking-view"}, ...]
EOF
```

**If the scanner exits non-zero, or stdout is empty, stop.** The results are unknown. Report the exit status and the stderr text, and print no table. A partial table would call live work dead.

Keep any `NOTE: dropped N mention-only triage candidates` line from stderr for the footnotes.

Next, mark each live row as **attributed** if its name contains any input ticket key, or equals the `agent_name` of any candidate of any ticket. Every other live row is **unattributed**: a live session you can't tie to a transcript (often an auto-named row like `youthinc-1d`).

Then put each ticket into exactly one state, checking in this order:

1. **Alive** if either is true:
   - A live row's name contains the ticket key.
   - Any of its candidates has an `agent_name` equal to a live row's name (exact match).
2. **Can't tell** if its top candidate has `agent_name: null` **and** at least one live row is unattributed. That unnamed session may be one of the unattributed live rows, and there is no way to check. If the top candidate's `last_active` is under 10 minutes ago, say so in the reason too, because it makes "still open" more likely.
3. **Dead:** everything else.

Recent activity alone never makes a ticket alive. An idle live session doesn't touch its transcript.

For each dead or can't-tell ticket, the session to show is its **first** candidate (the scanner already sorts strong first, then by score, then by recency). It can be missing. A ticket with no candidates is always dead.

## Phase 5 — Print the results

Print only the dead tickets in the table, newest `Last active` first, tickets with no session last:

```
| Ticket URL | Session ID | Last active |
|---|---|---|
| https://linear.app/acme/issue/YOU-9164/add-mod-types | 196c05f8-7a3b-4c2d-9e1f-a0b1c2d3e4f5 (weak) | 2026-11-24 09:41 (1d ago) |
| https://linear.app/acme/issue/YOU-9375/update-stale-mascots | f6516cc0-1c2d-4e5f-8a9b-0c1d2e3f4a5b | 2026-11-12 14:03 (13d ago) |
| https://acme.atlassian.net/browse/OPS-42 | — | never |
```

- **Ticket URL:** the full URL from the tracker.
- **Session ID:** the full `session_id`, never shortened. Add ` (weak)` when `confidence` is `weak`: that session only mentioned the ticket and may not be the one that worked on it. Use `—` when there is no candidate.
- **Last active:** `last_active` as local time `YYYY-MM-DD HH:MM`, then the age in parentheses (`5m ago`, `3h ago`, `13d ago`). Use `never` when there is no candidate.

Under the table, print a resume command for each dead ticket that has a session:

```
YOU-9375  cd '/Users/me/dev/app/.worktrees/you-9375' && claude --resume 'f6516cc0-1c2d-4e5f-8a9b-0c1d2e3f4a5b'
```

Shell-quote both values. If `cwd_exists` is `false`, print `claude --resume '<id>'` alone and add: "its directory `<cwd>` no longer exists. Recreate the worktree, or run this from the repo root." Below the commands, print once: "Check that each session isn't already open in another terminal before you resume it." Never run these commands yourself.

If any ticket is **can't tell**, print a separate `Can't tell` section after the commands, in the same table format, with **no resume command**. Under each row, give a one-line reason, e.g.:

```
YOU-9500  its last session (a1b2c3d4-…) has no name, and 2 live sessions (youthinc-1d, app-3f) couldn't be tied to a ticket. It may be one of them. Check those before resuming.
```

Name the unattributed live rows in the reason. In this reason line, a shortened session id is fine. The table row still shows the full id.

Then add footnotes, each only when it applies:

- `N tickets in other started statuses were skipped: QA (2), Blocked (1).`
- `Jira isn't connected, so only Linear was checked.` (or the other way round)
- `ListAgents failed, so no live sessions could be seen. Every ticket is listed as dead.`
- `Couldn't find this session's id, so this session's own transcript may show up as a candidate.`
- `The scanner dropped N mention-only candidates that looked like triage or report sessions.` (from the stderr `NOTE:` line)
- `N tickets count as alive only because a live session's name contains the ticket key. That can be a review or triage session named after the PR branch, not one doing the work.` (count the tickets that matched alive rule 1 but not rule 2)
- `No session found for N tickets in the last <D> days of transcripts. Set RCS_MAX_AGE_DAYS=0 and run again to scan everything.` Use the real value of `RCS_MAX_AGE_DAYS` for `<D>` (30 if unset). Skip this footnote when it is `0`.

If no ticket is dead or can't tell, skip the tables and say: `All N In Progress / In Review tickets have a live Claude session. Nothing to resurrect.`

---

## Rules

- **Read-only.** Never resume or start a session, never message one, never change a ticket.
- **Only the human's tickets.** Always filter by assignee = the human.
- **Never claim a session is the owner without evidence.** Mark weak matches `(weak)`. Never make up a session ID.
- **A ticket is alive only on a name match.** That means the ticket key in a live row's name, or an `agent_name` equal to a live row's name. Never match on `custom_title`. Never treat recent activity as alive. When you can't tell, say so. Don't guess dead.
- **No table on a failed scan.** If the scanner fails, report the error and stop.
