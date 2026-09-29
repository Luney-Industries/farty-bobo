---
name: triage-mentions
description: Scan Slack, Confluence, Jira, and GitHub for comments and messages that directly mention or tag the human. Present findings for selection, draft responses in a triage file, let the human APPROVE/DISMISS/RETRY each one, then dispatch approved responses using the appropriate skills.
---

# Triage Mentions Skill

Surface every place someone has pinged you — Slack, Jira, Confluence, GitHub — and help you respond without losing your mind.

---

## Phase 1 — Preflight

Before doing anything else, verify the following MCP connectors are reachable:

- **Slack**: `slack_search_public_and_private` (or `slack_search_public` as fallback) AND `slack_send_message` (required for dispatch — if absent, warn the human upfront that Slack replies won't be possible)
- **Atlassian (Jira + Confluence)**: `getAccessibleAtlassianResources`
- **GitHub**: `gh` CLI authenticated (`gh auth status`) AND `gh api` access — required for PR/issue comment scanning. If unavailable, warn and skip the GitHub scan.

If all connectors are unavailable, stop and tell the human: "No connectors are configured. Fix at least one and try again."

If only some connectors are missing, warn the human which sources will be skipped, then proceed with the available ones.

Resolve the human's identity once and cache for the session:

- **Atlassian account ID and display name** — call `atlassianUserInfo` with the human's email (`kfaham@embarkvet.com`). Extract and cache:
  - `accountId` — used in JQL and CQL queries
  - `displayName` — used as the display name in CQL text searches

  If `atlassianUserInfo` does not return a `displayName`, fall back to `lookupJiraAccountId` using the email. If display name is still null after both attempts, stop and ask the human to provide it manually — do not proceed with CQL queries that depend on it.

- **Slack member ID and handle** — use `slack_search_users` to resolve the Slack member ID for the human's name or email. Cache both the raw member ID (e.g. `U012AB3CD`) and the `@handle`. If resolution fails, warn and skip the Slack scan.

- **GitHub login** — run `gh api user --jq .login` to get the canonical GitHub username. Cache it for all GitHub queries. If `gh` is not authenticated, skip the GitHub scan and warn the human.

- **Human's email** — `kfaham@embarkvet.com` — use as lookup seed.

---

## Phase 2 — Scan Sources

Run scans across all three sources. Each scan should look back **7 days** by default (override if the human specifies a different window via skill args, e.g. `/triage-mentions 14d`).

Compute the lookback cutoff date as an absolute ISO 8601 timestamp at scan start (e.g. `2024-01-08T14:00:00Z`). Use this value in all queries — do not rely on relative date helpers whose syntax varies across API versions.

**Rate limiting note:** Jira and Confluence share the same Atlassian OAuth token. Run their scans sequentially (Jira first, then Confluence) to avoid concurrent 429s. If a 429 is received, back off 10 seconds and retry once before surfacing the error.

### 2a. Slack Scan

Search for messages where the human is directly mentioned using their cached Slack member ID:

```
query: "@{slack_member_id}"
```

Use `slack_search_public_and_private` for full coverage. Fall back to `slack_search_public` if private search is unavailable.

For each result:
- Fetch the thread context with `slack_read_thread` to get the full question/comment and all replies.
- Cache per result: `channel_id` (not just channel name), `thread_ts` (the raw float timestamp, e.g. `1714000000.123456`), author, message text, date.
- **Skip rule:** If the human's member ID appears in any reply posted *after* the mention, skip this thread — they have already responded. Only include threads where the human has not yet replied at all, or where a new mention of their member ID appears after their last reply.

Limit to 50 results. If the raw search returns more, note the overflow count in the triage list header (e.g. `Showing 50 of 83 — re-invoke with a shorter window to see the rest`).

### 2b. Jira Scan

Run these two JQL queries sequentially:

**Query 1 — direct mentions:**
```jql
(comment ~ "accountId:{account_id}" OR description ~ "accountId:{account_id}") AND updatedDate >= "{cutoff_iso}" ORDER BY updated DESC
```

**Query 2 — issues owned by the human with new activity:**
```jql
(assignee = "{account_id}" OR reporter = "{account_id}") AND updatedDate >= "{cutoff_iso}" ORDER BY updated DESC
```

Note: use the cached `{account_id}`, not `currentUser()` — `currentUser()` resolves to the MCP app's OAuth identity, not the human.

For each result, fetch the issue via `getJiraIssue` to get the full comment list. Filter to comments that either:
- Contain the human's account ID in a mention, OR
- Were added after the human's most recent comment on that issue (i.e. someone replied after them)

Skip any issue where the human's most recent comment is newer than all other comments — they have already responded.

Capture: issue key, summary, comment ID, author, comment text (truncated to 300 chars), date, direct link.

Limit to 30 issues total.

### 2c. Confluence Scan

Confluence does not store `@mentions` as plain text — they are ADF user-mention nodes. Full-text search on display name is lossy (misses most real mentions, may include false positives). Use this two-pronged approach and accept that results may be incomplete:

**Query 1 — comments referencing the human's account ID or display name:**
```cql
type = "comment" AND (text ~ "{account_id}" OR text ~ "{display_name}") AND lastModified >= "{cutoff_iso}" ORDER BY lastModified DESC
```

**Query 2 — pages the human contributes to with recent comment activity:**
```cql
type = "page" AND space.type = "global" AND contributor = "{account_id}" AND lastModified >= "{cutoff_iso}" ORDER BY lastModified DESC
```

For each result, fetch the page comments via `getConfluencePageFooterComments` and `getConfluencePageInlineComments`. Filter to comments that:
- Contain the human's display name or account ID in the text, AND
- Were added after the human's most recent comment on that page (or have no reply from the human at all)

**Limitation note:** ADF-encoded `@mentions` may not appear in full-text search results. When presenting Confluence results in Phase 3, prepend a one-line warning: `⚠ Confluence scan may miss some @mention notifications due to API limitations.`

Capture: page title, page URL, comment ID, author, comment text (truncated to 300 chars), date.

Limit to 30 results.

### 2d. GitHub Scan

Search for GitHub notifications where the human is mentioned. Run these `gh` commands sequentially:

**Query 1 — PR and issue review requests / mentions:**
```sh
gh api "notifications?all=false&participating=true&per_page=50" \
  --paginate --jq '.[] | select(.updated_at >= "{cutoff_iso}")'
```

This returns notifications the human is subscribed to and participating in. Filter to those with `reason` of `mention`, `review_requested`, or `comment`.

**Query 2 — PRs where the human is reviewed and new comments have arrived since their last review:**
```sh
gh search prs \
  --involves=@me \
  --state=open \
  --updated=">={cutoff_date}" \
  --json number,title,url,repository,updatedAt \
  --limit 30
```

For each PR returned by Query 2, fetch comments since the human's last activity:
```sh
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  --jq '.[] | select(.created_at >= "{cutoff_iso}" and .user.login != "{gh_login}")'
gh api repos/{owner}/{repo}/issues/{number}/comments \
  --jq '.[] | select(.created_at >= "{cutoff_iso}" and .user.login != "{gh_login}")'
```

**Query 3 — Issues where the human is mentioned or assigned with new comments:**
```sh
gh search issues \
  --involves=@me \
  --state=open \
  --updated=">={cutoff_date}" \
  --json number,title,url,repository,updatedAt \
  --limit 30
```

For each item, capture: repo (`owner/name`), PR/issue number, title, comment author, comment text (truncated to 300 chars), URL to the specific comment, date.

**Skip rule:** Skip any PR/issue where the human's most recent comment is newer than all other comments since the cutoff — they have already responded.

Limit to 50 total GitHub items. Use `gh api` for pagination where needed.

---

## Phase 3 — Deduplicate and Triage List

Merge all results into a single list. Remove duplicates (same URL/ID). Apply this priority sort:

1. Direct `@mention` of the human (highest priority)
2. Reply to a thread/comment the human started
3. New comment on an issue/page the human owns or is assigned to
4. New comment on an issue/page the human has previously commented on (lower confidence — present as a separate section labeled "Also active")

Present the list to the human grouped by source for readability:

```
Found {N} items requiring your attention ({date range}):
{If overflow: Showing {50} of {total} — re-invoke with a shorter window to see the rest.}
{If Confluence: ⚠ Confluence scan may miss some @mention notifications due to API limitations.}

── SLACK ──────────────────────────────────────────
[1] #channel-name — @author — "snippet of message..." (2h ago)
    https://...

── JIRA ───────────────────────────────────────────
[2] PROJ-123 — "Issue title" — @author commented: "snippet..." (1d ago)
    https://...

── CONFLUENCE ─────────────────────────────────────
[3] "Page title" — @author commented: "snippet..." (3d ago)
    https://...

── GITHUB ─────────────────────────────────────────
[4] owner/repo #123 — "PR title" — @author commented: "snippet..." (45m ago)
    https://...

── ALSO ACTIVE (lower confidence) ─────────────────
[4] JIRA  PROJ-456 — new comment, you commented here before (2d ago)
    https://...

Enter item numbers to address (e.g. "1 3 5"), "all", or "none":
```

Wait for the human's selection before proceeding. If the human says "none", stop cleanly. If they say "all", select every item.

---

## Phase 4 — Draft Responses

For each selected item, draft a response. Use all available context:
- Read the full thread/comment chain
- Follow at most **2 linked documents** per item (Jira links, Confluence links, etc.) — note in the draft if context was truncated due to this cap
- Infer what the author is asking or needs
- Compose a direct, helpful reply written from the human's voice — first person, direct, actionable

**Tone by platform:**
- **Slack**: Respectful and direct. No swearing. Punchy. In character per the `post-on-slack` skill tone guidance.
- **Jira**: Professional and concise. Address the specific question or action item. No filler.
- **Confluence**: Clear and collegial. Suitable for a shared page read by multiple people.
- **GitHub**: Technical and to the point. PR/issue comments are read by the whole team. Address the specific code or design question. Include references to files or line numbers when relevant. No filler, no pleasantries.

Write all drafts to a temporary file at:

```
$TEMP_ROOT/triage-mentions/triage-mentions-{YYYYMMDD-HHMMSS}.md
```

`$TEMP_ROOT` is the human's configured temp root (`FARTY_BOBO_TEMP_DIR`, defaulting to `/tmp`). Resolve it with exactly these commands (see the Temp Directory section of `/critique`):

```sh
# >>> temp-root (canonical: skills/critique/SKILL.md; tests/test-temp-root.sh enforces sync)
TEMP_ROOT="${FARTY_BOBO_TEMP_DIR:-/tmp}"
TEMP_ROOT="${TEMP_ROOT%/}"
case "$TEMP_ROOT" in
  /?*) ;;
  *) echo "WARNING: FARTY_BOBO_TEMP_DIR must be an absolute path (got '$FARTY_BOBO_TEMP_DIR'); falling back to /tmp" >&2
     TEMP_ROOT=/tmp ;;
esac
# <<< temp-root
(umask 077; mkdir -p "$TEMP_ROOT/triage-mentions")
```

If the temp-root block prints its `WARNING`, surface it to the human. Resolve once, then use the literal absolute file path in every later Write/Edit/Bash call and in every spawned-agent prompt.

(Include seconds to avoid collisions if the skill is re-invoked within the same minute.)

Use this exact structure for each item in the file:

```markdown
---

## Item {N} — {SOURCE}: {brief title}

**Source:** {SLACK | JIRA | CONFLUENCE}
**From:** @{author}
**Where:** {channel name / issue key / page title}
**Link:** {direct URL}
**Date:** {date}
<!-- Internal: channel_id={channel_id} thread_ts={thread_ts} (Slack only) -->
<!-- Internal: gh_repo={owner/repo} gh_number={number} gh_comment_id={id} (GitHub only) -->

### Context

> {full quoted message or comment, verbatim, max 500 chars — truncate with "…" if longer}

### Draft Response

{Reply content here — first person, direct. Do NOT open with "Posted by Farty Bobo" — dispatch handles attribution.}

### Decision

APPROVE

<!-- Replace APPROVE with one of: APPROVE | DISMISS | RETRY: <your notes> -->
<!-- Parser looks for the first line in this section that matches APPROVE, DISMISS, or RETRY: -->
```

Note: the Decision section defaults to `APPROVE` so the human only has to change items they want to dismiss or retry — not approve every single one.

After writing the file, tell the human:

```
Drafts written to: {TEMP_ROOT}/triage-mentions/triage-mentions-{timestamp}.md

Open the file, review each draft, and set the Decision for each item:
  APPROVE  — post as-is (default)
  DISMISS  — skip this item
  RETRY: <your notes>  — revise and re-present before posting

Save the file, then tell me "done" to dispatch.
```

Do NOT proceed until the human explicitly says they're done annotating.

---

## Phase 5 — Parse Decisions

Re-read the triage file. For each item's `### Decision` section, find the **first non-comment line** that matches one of:

- `/^APPROVE$/i` → dispatch as-is (Phase 6)
- `/^DISMISS$/i` → skip; log "dismissed" in session summary
- `/^RETRY:/i` → extract the notes after the colon; revise the draft using those notes

If no match is found (unannotated, blank, or unrecognized text), ask the human to clarify that specific item before proceeding with others.

**RETRY handling:**
- Show the revised draft inline in the conversation.
- Ask: "Post this revised response? (yes / edit / skip)"
- On "yes" → dispatch. On "edit" → accept new content and re-confirm. On "skip" → dismiss.
- Cap at **2 revision rounds** per item. If the human still isn't satisfied after 2 rounds, mark it dismissed with a note and move on — do not loop indefinitely.

After RETRY items are resolved, update the corresponding block in the triage file: replace the Draft Response with the final accepted version and change the Decision line to `APPROVED (revised)`.

Tally: `{A} approved, {D} dismissed, {R} retried`

---

## Phase 6 — Dispatch Approved Responses

**Secret scan first:** Before dispatching any item, scan both the `### Context` block AND the `### Draft Response` block for secrets — API keys, tokens, passwords, internal hostnames, `.env` values, connection strings. If found in either block, surface the finding to the human and pause that item's dispatch — do not redact silently.

For each APPROVE item, route to the correct skill:

| Source | Dispatch method |
|--------|----------------|
| SLACK | Use `slack_send_message` with `channel_id` and `thread_ts` from the cached metadata (HTML comment in the file). Open the message with the identity disclosure line: `_{your identity} on behalf of @{human_slack_handle}:_` then the draft body. |
| JIRA | Invoke `/comment-jira` with the ticket ID and draft body. The skill handles ADF formatting and identity footer. |
| CONFLUENCE | Invoke `/comment-confluence` with the page URL and draft body. The skill handles ADF formatting, identity footer, and space visibility check. |
| GITHUB | Use `gh api repos/{owner}/{repo}/issues/{number}/comments -f body="{body}"` to post a PR or issue comment. Open the body with the identity disclosure line: `_Posted by {your identity} on behalf of @{gh_login}._` then the draft body. For PR review comments on specific lines, use `gh api repos/{owner}/{repo}/pulls/{number}/comments` with appropriate `path`, `line`, and `commit_id` fields. |

After dispatch, report outcomes:

```
Dispatch complete:
  ✓ [1] SLACK #channel — replied in thread
  ✓ [3] JIRA PROJ-456 — comment posted
  ✗ [2] CONFLUENCE "Page title" — FAILED: {error message}
  — [4] DISMISSED
  ~ [5] RETRY → APPROVED (revised) — posted
```

For any failures, surface the full error and ask the human how to proceed.

---

## Guardrails

- **Never post without human approval.** Every item goes through APPROVE before dispatch. No exceptions.
- **Skip already-answered items.** If the human has already replied to a thread or comment after the mention (detected in Phase 2), do not include it in the triage list.
- **Do not post the triage file to external systems.** The triage file under `$TEMP_ROOT/triage-mentions/` is local. Never upload it to Slack, Jira, Confluence, Pastebin, or anywhere else.
- **Respect the 7-day default.** Do not silently extend the window. If the human wants more history, they must say so.
- **One round per invocation.** New mentions that arrive after Phase 2 are not included. Re-invoke the skill to pick them up.
- **RETRY cap.** No item gets more than 2 revision rounds. If it's still not right, dismiss it — the human can always invoke `/comment-jira`, `/comment-confluence`, or `/post-on-slack` manually.
