---
name: pr-action-board
description: Find your open PRs that are either approved or have new unresolved/unresponded comments, compile them into a triage board with human-annotatable MERGE/ADDRESS/REPLY/SKIP actions, then dispatch dedicated agents to execute each decision. Use when the user asks "what PRs do I need to deal with?", "triage my open PRs", "which PRs need my attention?", or similar.
disable-model-invocation: false
---

# PR Action Board Skill

Surface every PR that needs your attention in one annotated triage file:

- **Your own open PRs** — approved and waiting to merge, or sitting on unanswered reviewer comments.
- **Others' PRs where you need to respond** — someone replied to your comment, tagged you directly, tagged one of your teams, or the PR description mentions you or a team you belong to.

The full workflow is a single human approval gate: the skill builds the file with pre-filled actions and pre-drafted proposals, you review and edit, say "done", and all agents fire simultaneously.

---

## Helper Scripts

All deterministic state checks in this skill are performed by helper scripts co-located with the skill. Before Phase 2, locate the script directory:

```sh
SCRIPT_DIR=$(find ~ -maxdepth 7 \
  -path "*/farty-bobo/skills/pr-action-board/scripts" \
  -type d 2>/dev/null | head -1)

if [[ -z "$SCRIPT_DIR" ]]; then
  echo "ERROR: farty-bobo scripts not found. Clone the farty-bobo repo first." >&2
  exit 1
fi
```

Cache `$SCRIPT_DIR` for use throughout all phases.

Scripts available (all executable, all take stdin/stdout, all output JSON):

| Script | Purpose |
|--------|---------|
| `get-teams.sh <org>` | Returns `[{slug, name, mention}]` for the user's teams in one org |
| `find-mention-prs.sh <login> <org_or_empty> <teams_json>` | Open PRs (not mine) where I or my teams are mentioned and I haven't responded |
| `find-thread-reply-prs.sh <login> <org_or_empty>` | Open PRs (not mine) where I commented and got unresponded replies |
| `check-pr-threads.sh <login> <owner> <repo> <pr_number>` | Per-PR check: unresolved review threads + issue comment chains with unresponded replies |

---

## Phase 1 — Preflight

1. Run `gh auth status`. If unauthenticated, stop and tell the human to run `gh auth login`.
2. Resolve the GitHub login once and cache it:
   ```sh
   gh api user --jq .login
   ```
   Do NOT assume a login from git config, memory, or any other source.
3. **Prompt the human to choose the org scope.** Fetch the list of orgs:
   ```sh
   gh api user/orgs --jq '.[].login'
   ```
   Present the list and ask the human to pick one, or "all" to scan across all orgs:

   ```
   Which org should I scan?

     1) embarkvet
     2) acme-corp
     3) all orgs (no restriction)

   Enter a number or org name:
   ```

   Do NOT proceed until the human responds. Cache their choice as `{scope}`:
   - Specific org → `{scope}` = `--owner {org}` for `gh search prs` calls; org name alone for scripts.
   - "all" → `{scope}` = `` (no flag); pass empty string to scripts.

---

## Phase 2 — Scan for Actionable PRs

Run phases 2a, 2b, and 2c **in parallel**. Collect and deduplicate by URL.

### 2a. My Approved PRs

```sh
gh search prs \
  --author="@me" \
  --state=open \
  --review=approved \
  --json number,title,url,repository,createdAt,updatedAt,isDraft,labels \
  --limit 100 \
  {scope}
```

Exclude drafts (`isDraft: true`) unless the human explicitly asked to include them.

### 2b. My PRs with New Unresponded Comments

```sh
gh search prs \
  --author="@me" \
  --state=open \
  --json number,title,url,repository,createdAt,updatedAt,isDraft \
  --limit 100 \
  {scope}
```

For each PR, run in parallel (batch up to 10 at a time):

```sh
# PR-level conversation comments
gh api repos/{owner}/{repo}/issues/{number}/comments \
  --jq '[.[] | {login: .user.login, created_at: .created_at, body: .body}] | sort_by(.created_at)'

# Formal review states
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --jq '[.[] | {login: .user.login, state: .state, submitted_at: .submitted_at, body: .body}] | sort_by(.submitted_at)'

# Inline review threads WITH resolution status (GraphQL)
gh api graphql -f query='
  query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            isOutdated
            comments(first: 20) {
              nodes {
                author { login }
                createdAt
                body
                path
                line
              }
            }
          }
        }
      }
    }
  }
' -f owner="{owner}" -f repo="{repo}" -F number={number}
```

**Identity anchor:** Use the cached `{gh_login}` from Phase 1 as the authoritative identity. A comment or review is "from the human" if and only if `author.login` / `user.login` equals `{gh_login}`.

**Inline thread filtering:**
- Exclude `isResolved: true` and `isOutdated: true` threads.
- Only count and surface threads where `isResolved: false` AND `isOutdated: false`.

**Keep a PR in the unresponded list if ANY of:**
- A reviewer left a conversation comment AFTER the human's last comment and the human has not replied since.
- A reviewer's formal review state is `CHANGES_REQUESTED` with no subsequent human acknowledgment.
- An unresolved, non-outdated inline thread where the last reply's `author.login` is NOT `{gh_login}`.

**Skip if:**
- The human's most recent activity on the PR is newer than all unresolved reviewer activity.
- The only reviewer activity is a simple `APPROVED` with no comments.

**For each ADDRESS PR — generate proposals inline** (no agent spawn needed; use the comment data already fetched):

For each unresolved comment or inline thread, synthesize a brief proposed action:
- Code change requests → `Proposed: [one-sentence description of the change to make]`
- Discussion questions → `Proposed reply: [draft response based on the comment context and what you know about the PR]`
- `CHANGES_REQUESTED` review with body → treat as a code change request

These proposals populate the `#### Proposed Changes` section in Phase 3. Also identify any open questions the human needs to answer (things the reviewer asked that you can't resolve from context alone) — these go into `#### Questions`.

### 2c. Others' PRs — Where I Need to Respond

Run 2c-i first (TEAMS_JSON is needed by 2c-ii). Once 2c-i completes, run 2c-ii and 2c-iii **in parallel** — 2c-iii has no dependency on TEAMS_JSON.

#### 2c-i. Team membership (prerequisite for 2c-ii only)

```sh
TEAMS_JSON=$("$SCRIPT_DIR/get-teams.sh" "{org}")
# If scope is "all orgs", call get-teams.sh for each org individually and merge results.
# If get-teams.sh errors or returns [], proceed with TEAMS_JSON="[]".
```

#### 2c-ii. Mention PRs (run after TEAMS_JSON is available)

```sh
MENTION_PRS=$("$SCRIPT_DIR/find-mention-prs.sh" \
  "{gh_login}" "{org_or_empty}" "$TEAMS_JSON")
```

#### 2c-iii. Thread reply PRs (run in parallel with 2c-ii)

```sh
THREAD_REPLY_PRS=$("$SCRIPT_DIR/find-thread-reply-prs.sh" \
  "{gh_login}" "{org_or_empty}")
```

#### 2c-iv. Merge, deduplicate, and draft replies

Combine `MENTION_PRS` and `THREAD_REPLY_PRS`. Deduplicate by URL. If a PR appears with multiple reasons, set `reason` to `"multiple"` and list all reasons in a `reasons` array.

Cap at 30 PRs from Phase 2c (most recently updated first). Warn and list dropped PR numbers if more are found.

**For each REPLY PR — draft replies inline** (use the thread/mention context already fetched):

For each unresponded thread or mention, write a draft reply appropriate to the context:
- Thread replies: address the specific question or comment the reviewer left
- Direct mentions: respond to what the person asked or flagged
- Keep drafts brief, professional, and substantive

These drafts populate the `#### Draft Replies` section in Phase 3.

### 2d. Enrich All PRs

For every unique PR from 2a, 2b, and 2c (up to 50 total — if more, keep the 50 most recently updated, warn and list dropped numbers):

```sh
gh pr view {number} --repo {owner}/{repo} \
  --json mergeable,mergeStateStatus,statusCheckRollup,reviews,reviewRequests,headRefName,baseRefName
```

Derive per PR:
- **Approvers**: unique logins from `reviews` where `state == "APPROVED"`, latest review per reviewer.
- **Pending reviewers**: entries in `reviewRequests` who haven't responded.
- **CI status**: `passing` | `failing` | `pending` | `none`.
- **Merge readiness**: `ready` | `conflicts` | `blocked` | `unknown`.
- **Unresponded comment count** (2a/2b PRs only): unresolved, non-outdated threads + unacknowledged conversation comments.
- **PR type**: `my-pr` (2a/2b) | `others-pr` (2c).
- **Reason for inclusion**: `approved` | `unresponded-comments` | `both` | `thread-reply` | `mention` | `direct-mention` | `team-mention` | `multiple`.
- **CHANGES_REQUESTED override**: If any reviewer's latest review state is `CHANGES_REQUESTED`, default action is `ADDRESS` regardless of approvals.

---

## Phase 3 — Build the Triage Board File

Write to:
```
/tmp/pr-action-board-{YYYYMMDD-HHMMSS}.md
```

### File format

The file is the **single human approval gate** for the entire run. It includes pre-filled actions and pre-drafted proposals for every PR. The human reviews all of it once, edits whatever they want, and says "done" — after which all agents fire in parallel.

```markdown
# PR Action Board — {YYYY-MM-DD HH:MM:SS}

Scoped to: {org name, or "all orgs"}
GitHub login: @{login}

> Review all Action blocks and proposed items below, then tell me "done" to execute everything.
>
> Top-level actions:   MERGE | ADDRESS | REPLY | SKIP
> Per-item decisions:  APPROVE | SKIP | EDIT: <your direction or replacement text>
> Questions:           Fill in ANSWER: <your response>

---

## My Open PRs

| PR | Title | Repo | Reason | Approvers | CI | Merge Ready | Unresponded | Action |
|----|-------|------|--------|-----------|----|-----------  |-------------|--------|
| [#123](url) | Fix login redirect | embarkvet/foo | approved | @alice, @bob | passing | ready | 0 | MERGE |
| [#118](url) | Add PostHog tracking | embarkvet/bar | unresponded-comments | — | failing | blocked | 3 | ADDRESS |

**Total:** N  **Approved + ready:** M  **Need attention:** K

---

## Others' PRs — Action Needed From Me

| PR | Author | Repo | Reason | Context | Action |
|----|--------|------|--------|---------|--------|
| [#77](url) | @alice | embarkvet/bar | thread-reply | Reply to my comment on `src/auth.ts:14` | REPLY |
| [#55](url) | @bob | embarkvet/baz | direct-mention | @kinanf tagged in comment by @carol | REPLY |

**Total:** N

---

## PR Details & Actions

<!-- ═══════════════════════════════════════════════════════════════════════ -->

### [My PR] [#123] Fix login redirect — embarkvet/foo

**URL:** https://github.com/embarkvet/foo/pull/123
**Branch:** `fix/login-redirect` → `main`
**Reason:** approved
**Approvers:** @alice, @bob
**Pending reviewers:** none
**CI:** passing
**Merge ready:** ready
**Unresponded comments:** 0

#### Reviewer Activity

*(none — approved cleanly)*

### Action

```
MERGE
```

<!-- MERGE | ADDRESS | SKIP -->

<!-- ═══════════════════════════════════════════════════════════════════════ -->

### [My PR] [#118] Add PostHog tracking — embarkvet/bar

**URL:** https://github.com/embarkvet/bar/pull/118
**Branch:** `feature/posthog` → `main`
**Reason:** unresponded-comments
**Approvers:** none
**Pending reviewers:** @carol
**CI:** failing
**Merge ready:** blocked
**Unresponded comments:** 3

#### Proposed Changes

<!-- For each item: APPROVE to accept as-is, SKIP to ignore, or EDIT: <direction> to override. -->

**[C1]** @carol · CHANGES_REQUESTED
> "This will fire an event on every render — should be memoized. Also the API key is hardcoded, that needs to be an env var."

Proposed: Memoize the analytics call with `useMemo` at `src/tracking.ts:28`.

```
APPROVE
```

**[C2]** @dave · inline · `src/tracking.ts:42`
> "Why not use the existing `useAnalytics` hook here instead?"

Proposed reply: "The `useAnalytics` hook doesn't support batched events yet — this is a deliberate short-term workaround."

```
APPROVE
```

**[C3]** @carol · PR comment · 12h ago
> "Any update on the memoization fix?"

Proposed reply: "Working on it — will push the fix shortly."

```
APPROVE
```

#### Questions

<!-- Fill in each ANSWER field. Leave blank to skip. -->

**[Q1]** Carol mentioned a hardcoded API key in `src/tracking.ts:15`. Address it in this PR or defer?

```
ANSWER: 
```

### Action

```
ADDRESS
```

<!-- MERGE | ADDRESS | SKIP -->

<!-- ═══════════════════════════════════════════════════════════════════════ -->

### [Others' PR] [#77] Refactor auth service — embarkvet/bar

**URL:** https://github.com/embarkvet/bar/pull/77
**Author:** @alice
**Reason:** thread-reply
**Updated:** 3h ago

#### Draft Replies

<!-- For each draft: APPROVE to post as-is, SKIP to not post, or EDIT: <replacement text> to override. -->

**[R1]** Review thread · @alice · `src/auth.ts:14` · 3h ago
> "Do you think we should extract this into a shared helper? Would love your take since you built the original."

Draft: "Yeah, extracting makes sense here. The original auth pattern lives in `src/auth/base.ts` — a shared helper there would stay consistent with how we've structured things. Happy to do a follow-up PR for it if that works for you."

```
APPROVE
```

### Action

```
REPLY
```

<!-- REPLY | SKIP -->

<!-- ═══════════════════════════════════════════════════════════════════════ -->

### [Others' PR] [#55] Add rate limiting — embarkvet/baz

**URL:** https://github.com/embarkvet/baz/pull/55
**Author:** @bob
**Reason:** direct-mention
**Mentioned at:** 2026-05-07 14:32 UTC
**Updated:** 1d ago

#### Draft Replies

**[R1]** PR comment · @carol · 1d ago
> "@kinanf — can you review the token bucket implementation here? You wrote the original spec."

Draft: "Taking a look — the token bucket logic looks right to me at a glance. One thing worth checking: the refill rate calculation on line 42 assumes wall-clock seconds but the original spec used monotonic time to handle clock skew. Worth verifying that still holds."

```
APPROVE
```

### Action

```
REPLY
```

<!-- ═══════════════════════════════════════════════════════════════════════ -->
```

### Notes on pre-filled values

**Summary table:** include an `Action` column in both tables pre-populated with the suggested action — makes it easy to scan and change one without opening the details section.

**Default actions:**
- My PR — approved + merge-ready + CI passing + 0 unresponded: `MERGE`
- My PR — unresponded comments OR CI failing OR merge blocked: `ADDRESS`
- My PR — draft: `SKIP` (note it is a draft)
- Others' PR — any: `REPLY`
- Everything else: `TBD`

**Proposed items:**
- Code change requests: always default to `APPROVE`
- Discussion replies (questions, follow-ups): default to `APPROVE`
- `CHANGES_REQUESTED` reviews: always generate at least one `[C]` item

**EDIT semantics:**
- `EDIT: <direction>` on a code-change item → the ADDRESS agent treats your direction as the implementation instruction instead of the original proposal.
- `EDIT: <replacement text>` on a reply item → the REPLY agent posts your replacement text verbatim (after prepending the Farty Bobo disclosure).

After writing the file, tell the human:

```
Triage board written to: /tmp/pr-action-board-{timestamp}.md

Open the file and review:
  — Top-level Action (MERGE/ADDRESS/REPLY/SKIP) for each PR
  — Proposed Changes [C1, C2…]: APPROVE, SKIP, or EDIT: <direction>
  — Draft Replies [R1, R2…]: APPROVE, SKIP, or EDIT: <your text>
  — Questions [Q1, Q2…]: fill in ANSWER: <response>

Save and tell me "done" — everything will execute in parallel.
```

**Do NOT proceed until the human explicitly says they are done reviewing.**

---

## Phase 4 — Parse Annotations

Re-read the triage file. For each PR, extract:

### 4a. Top-level action

Find the **first non-comment, non-blank line** inside the `### Action` code block:
- `/^MERGE$/i` → Phase 5a
- `/^ADDRESS$/i` → Phase 5b
- `/^REPLY$/i` → Phase 5c
- `/^SKIP$/i` → log as skipped
- `/^TBD$/i` → surface to the human before dispatching (see below)
- Malformed → treat as `TBD`

### 4b. Per-item decisions (ADDRESS PRs)

For each `**[C\d+]**` block in `#### Proposed Changes`, extract the code block immediately following it:
- `APPROVE` → include this item in the approved changes list with the original proposed action
- `SKIP` → exclude from the approved changes list
- `EDIT: <text>` → include with `direction` set to the text after `EDIT:`

For each `**[Q\d+]**` block in `#### Questions`, extract the ANSWER field:
- Non-empty `ANSWER: <text>` → include in the question-answers map
- Empty or missing → omit (agent will note the unanswered question but proceed)

### 4c. Per-item decisions (REPLY PRs)

For each `**[R\d+]**` block in `#### Draft Replies`, extract the code block immediately following it:
- `APPROVE` → use the draft text verbatim
- `SKIP` → do not post this reply
- `EDIT: <text>` → use the text after `EDIT:` as the reply body

### 4d. Build execution payloads

For each PR, build a self-contained payload that will be passed to the executing agent:

```json
// ADDRESS PR example
{
  "pr": 118,
  "repo": "embarkvet/bar",
  "headRefName": "feature/posthog",
  "approved_changes": [
    { "id": "C1", "type": "code_change", "direction": "Memoize the analytics call with useMemo at src/tracking.ts:28" },
    { "id": "C2", "type": "discussion_reply", "reply_text": "The useAnalytics hook doesn't support batched events yet — this is a deliberate short-term workaround." },
    { "id": "C3", "type": "discussion_reply", "reply_text": "Working on it — will push the fix shortly." }
  ],
  "question_answers": [
    { "id": "Q1", "answer": "Defer to a separate ticket" }
  ]
}

// REPLY PR example
{
  "pr": 77,
  "repo": "embarkvet/bar",
  "approved_replies": [
    {
      "id": "R1",
      "target_type": "review_thread",
      "first_comment_rest_id": 12345678,
      "reply_text": "Yeah, extracting makes sense here..."
    }
  ]
}
```

### 4e. TBD handling

Dispatch all PRs with clear MERGE/ADDRESS/REPLY/SKIP actions immediately (Phase 5). For TBD PRs, surface them to the human now, wait for their decision, then add those agents to the parallel batch. Do not hold up the rest of the queue.

Tally: `{M} MERGE, {A} ADDRESS, {R} REPLY, {S} SKIP, {T} TBD`

---

## Phase 5 — Execute All Actions in Parallel

**Run ALL agents — MERGE, ADDRESS, and REPLY — in a single parallel batch.** Send all agent tool calls in one message. Each agent is self-contained and does not require human interaction; all approvals were captured in the triage file.

Name each agent after a unique American outlaw from the 1800s–1900s (e.g. Butch Cassidy, Jesse James, Belle Starr, Black Bart, Dutch Schultz, Pretty Boy Floyd, Billy the Kid, Bonnie Parker, Sam Bass, Pearl Hart, John Wesley Hardin, Cole Younger, Doc Holliday, Calamity Jane, Tom Horn, Kid Curry, Sundance Kid, Cherokee Bill, Cattle Annie, Emmett Dalton). Names must be unique across all agents in this session. If the list is exhausted, continue with other historical American outlaws.

### 5a. MERGE agents

Each merge agent receives:
1. PR URL, number, and repo `{owner}/{repo}`.
2. Merge strategy — ask the human once before dispatching if not already specified: `--squash` (default), `--merge`, or `--rebase`.
3. Instructions to:

   a. **Pre-merge check:** Run `gh pr view {number} --repo {owner}/{repo} --json mergeable,mergeStateStatus,statusCheckRollup,baseRefName` and verify:
      - `mergeable` is `"MERGEABLE"` and `mergeStateStatus` is `"CLEAN"`. If `mergeable` is `null`, wait 10 seconds and re-poll up to 3 times.
      - CI is passing.
      - Cache `baseRefName` for post-merge monitoring.
      - If either check fails after retries, do NOT merge — report the blocker back.

   b. **Merge:**
      ```sh
      gh pr merge {number} --repo {owner}/{repo} --{strategy} --delete-branch
      ```
      If `branchProtectionRules` returns empty or errors, attempt direct merge. If blocked by required status checks, retry with `--auto`.

   c. **Post-merge CI watch:** Monitor `{baseRefName}` for up to 10 minutes, polling every 60 seconds:
      ```sh
      gh run list --branch {baseRefName} --repo {owner}/{repo} --limit 3 \
        --json databaseId,status,conclusion,name,createdAt
      ```
      If any run fails, invoke `/resolve-ci-failures` on `{baseRefName}`. If not terminal after 10 minutes, return `ci_outcome: timed_out` — do NOT invoke `/resolve-ci-failures` for timed-out runs.

   d. **Jira ticket transition (only after CI is green):**
      1. Extract ticket key from PR title then `headRefName` using `[A-Z]+-\d+`. If none found, record `jira_transition: skipped_no_ticket`.
      2. Fetch transitions via `getTransitionsForJiraIssue`.
      3. Select target: "Done" → "Merged" → "Released" → "Closed" (first case-insensitive match).
      4. Idempotency check via `getJiraIssue` — skip if already in or past target state.
      5. Apply via `transitionJiraIssue`. On error, record `jira_transition: failed` and do not block.
      6. Skip entirely if CI is not green; record `jira_transition: skipped_ci_not_green`.

   e. Return:
      ```json
      {
        "pr": 123, "repo": "owner/repo",
        "status": "merged | blocked | error",
        "merge_sha": "abc123",
        "ci_outcome": "passing | failing | timed_out | skipped",
        "jira_ticket": "BBH-1915 | null",
        "jira_transition": "done | skipped_no_ticket | skipped_no_matching_state | skipped_already_done | skipped_ci_not_green | failed",
        "notes": "..."
      }
      ```

### 5b. ADDRESS agents

Each ADDRESS agent receives the **execution payload** from Phase 4d (approved_changes list, question_answers) plus:
- PR URL, number, repo `{owner}/{repo}`, `headRefName`
- The full original unresponded comment text for context

The agent must NOT re-do the analysis or ask the human any questions. All decisions are already in the payload.

Instructions:
1. Locate the local clone (via `find ~ -name ".git" -maxdepth 5 ...`), check out `{headRefName}` (`git checkout {headRefName} && git pull`). If no local clone is found, return `status: no_local_clone`.
2. For each item in `approved_changes`:
   - `type: "code_change"` → implement the change described in `direction`. Use the original comment for context.
   - `type: "discussion_reply"` → post the `reply_text` to the appropriate comment thread on GitHub. Prepend the Farty Bobo disclosure.
3. For any unanswered `[Q]` items (not in `question_answers`): note them in the return payload as `unanswered_questions` — do not block execution.
4. After all changes are made: run `/build` to verify compilation and tests pass.
5. Run `/critique` to commit, push, and open/update the PR.
6. Return:
   ```json
   {
     "pr": 118, "repo": "owner/repo",
     "status": "addressed | partial | error",
     "changes_applied": ["C1", "C2"],
     "changes_skipped": [],
     "replies_posted": ["C2", "C3"],
     "unanswered_questions": ["Q1"],
     "notes": "..."
   }
   ```

### 5c. REPLY agents

Each REPLY agent receives the **execution payload** from Phase 4d (approved_replies list) plus:
- PR URL, number, repo `{owner}/{repo}`, PR author

The agent must NOT re-draft or ask for approval. All reply text is already in the payload.

Instructions:
1. For each item in `approved_replies`:
   - Prepend `_Posted by Farty Bobo on behalf of @{gh_login}._\n\n` to the reply text.
   - `target_type: "review_thread"` → post via:
     ```sh
     gh api -X POST repos/{owner}/{repo}/pulls/{number}/comments/{first_comment_rest_id}/replies \
       -f body="..."
     ```
     where `first_comment_rest_id` is the REST integer comment ID (not the GraphQL node ID) from the payload.
   - `target_type: "pr_comment"` → post via:
     ```sh
     gh api -X POST repos/{owner}/{repo}/issues/{number}/comments \
       -f body="..."
     ```
2. Return:
   ```json
   {
     "pr": 77, "repo": "owner/repo",
     "status": "replied | partial | error",
     "replies_posted": ["R1"],
     "replies_skipped": [],
     "notes": "..."
   }
   ```

---

## Phase 6 — Update Triage File and Report

Phase 6 runs after ALL agents have returned. The parent skill writes the triage file; sub-agents do not.

1. Re-read the triage file.
2. Append `#### Outcome` under each PR's `### Action` block:
   ```markdown
   #### Outcome

   **Status:** merged | addressed | replied | skipped | blocked
   **Completed:** {timestamp}
   **Details:** {one-sentence summary}
   **CI post-merge:** passing | failing | timed_out | n/a
   **Jira:** {ticket} → Done | skipped ({reason}) | n/a
   ```
3. Update both summary tables to add an `Outcome` column.
4. Report to the human:
   ```
   PR Action Board — complete.

   ✓  MERGE   [#123] embarkvet/foo — merged. CI passing. BBH-1915 → Done.
   ✓  ADDRESS [#118] embarkvet/bar — 3 changes applied, 2 replies posted, critique passed.
   ✓  REPLY   [#77]  embarkvet/bar — 1 thread reply posted.
   ✓  REPLY   [#55]  embarkvet/baz — 1 mention reply posted.
   —  SKIP    [#101] embarkvet/qux — skipped per your instruction.
   ✗  MERGE   [#109] embarkvet/qux — blocked: merge conflicts. Needs manual rebase.

   Updated triage file: /tmp/pr-action-board-{timestamp}.md
   ```

   Surface any failures or blockers with suggested next steps.

---

## Guardrails

- **Single approval gate.** No action is taken until the human has reviewed the triage file and said "done". The pre-merge check in Phase 5a is a second safety gate for MERGE.
- **No interactive loops in Phase 5.** Agents execute with the payloads they receive. If something is ambiguous, agents note it in their return payload — they do not pause to ask questions. Unanswered questions and unexpected blockers are surfaced in Phase 6.
- **All agents run in parallel.** MERGE, ADDRESS, and REPLY agents are all dispatched in a single message after the human says "done". There is no sequential phase.
- **No external posts without disclosure.** Every comment or reply posted to GitHub must open with `_Posted by Farty Bobo on behalf of @{gh_login}._`
- **No summary comments to GitHub PRs.** Only inline code review comments and targeted replies. Summaries stay in the triage file.
- **Do not post the triage file externally.** The `/tmp` file is local only.
- **One round per invocation.** New PRs or comments after Phase 2 are not included.
- **Outlaw names must be unique per session.** Never reuse a name, even after the previous agent has completed.
