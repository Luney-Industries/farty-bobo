---
name: critique
description: Used to run githooks, perform code & plan reviews with expert critics, and commit/push verified changes
disable-model-invocation: false
---


# Code and Plan Review Skill

## Temp Directory

Planning and review artifacts written by `/plan-task`, `/build`, and `/review-multiple-prs` live outside the repo under:

```
TEMP_DIR=/tmp/<repo-name>/<branch-name>
```

Resolve `<repo-name>` and `<branch-name>` using:
- `<repo-name>` = `basename $(git rev-parse --show-toplevel)`
- `<branch-name>` = `git branch --show-current`

**Worktree note:** if running inside a git worktree, `git rev-parse --show-toplevel` returns the worktree path, not the main repo root. Use `git rev-parse --git-common-dir | xargs dirname` to get the true repo root when resolving `<repo-name>`.

**macOS note:** `/tmp` → `/private/tmp` and is cleared on reboot. Decisions scratch files do not persist across reboots; if a session spans a reboot, the human will need to re-state decisions manually.

---

1. Either detect the repos affected from the context OR ask the human to select the repos that should be used to review the code changes or the staged implementation plan (md file):

- current directory
- a list of repos in the file system

2. enable and run githooks in the repos impacted by the code changes and fix errors (linting, type checks, tests) before committing. Most repos have dedicated commands to achieve these goals either in package.json or pyproject.toml.

3. Once you are ready to commit the changes, prompt the human to select their preferred review options:

- one generalist critic (good for simple tasks)
- a team of critics who have expertise in the technology stacks being used and best security practices. The critics must create a markdown file to list their revisions sorted by severity (high first).
- Modularity review: Run `/modularity:review` to analyze coupling across modules using the Balanced Coupling model. Best for changes that introduce or restructure component boundaries, touch multiple modules, or modify public APIs/contracts.
- Codex review: Ask the human to run `/codex:review`
- Manual review by the human.

4. Prompt the human to select the next step from the following options:

- Ignore code review revisions and proceed to next step.
- Implement revisions. Use the original agent(s) to implement changes.

5. **Branch safety check.** Run `git branch --show-current` and compare against the repo's default branch (typically `main` or `master`).
   - If on the default branch: warn the human — "You are on `{branch}` (the default branch). Committing directly here is not recommended. Should I create a new branch first, or do you explicitly approve committing to `{branch}`?"
   - Do not proceed to Step 6 until the human has either approved committing to the default branch explicitly or confirmed a new branch to use.
   - If the human chooses a new branch: create it from the current HEAD (`git checkout -b {branch-name}`), then continue.

6. Prepare, summarize the changes in the changed files. Always prefix commits with [{ticket-id}]: {summary of change}. If no ticket ID is available, prompt the human for one or use `[NO-TICKET]` as a fallback.
   - Temporary review and planning files (`review-draft-*.md`, `plans/*.plan.md`, `plans/decisions-*.md`, `plans/stubs/**`) are written to `/tmp/<repo-name>/<branch-name>/` — outside the repo — and must never appear in `git status`. If any such file is found inside the repo, do not stage it and delete it immediately.
   Permanent project docs (`README.md`, `SKILL.md`, `AGENTS.md`, etc.) should still be committed when changed.
7. Commit and push. If the push fails due to pre-push hook errors, prompt the human for approval before using `git push --no-verify`. If `--no-verify` was used, record this in the Decision Log (Step 9) as a warning line.

7a. **Open a draft pull request.** After a successful push, open a **draft** PR using `gh pr create --draft` (or equivalent).

   **PR body:** Read `.github/PULL_REQUEST_TEMPLATE.md` from the repo root and use it as the base for the PR body — fill in the Summary and Test plan sections with content relevant to the change. If the file does not exist, use a bare `## Summary` / `## Test plan` structure. Never append Anthropic or Claude Code branding lines (e.g. `🤖 Generated with Claude Code`) to the PR body.

   After the PR is created, request a review from **Copilot** using `gh pr edit {number} --add-reviewer "Copilot"`. Capture the PR URL. If the PR creation fails, skip Steps 7 and 8 and warn the human.

7b. **Bot review loop (draft PRs only).**

   This step only applies when the PR was opened as a **draft**. If the PR is not a draft, skip to Step 8. **If `/critique` was invoked recursively from within this loop (e.g., by `/address-pr-comments` or `/resolve-ci-failures`), skip Step 7b entirely** — the bot loop is already running in the parent invocation.

   After the draft PR is open, wait for automated reviewers (bots, linters, CI) to post their feedback:

   1. **Estimate the wait time** based on PR size and recent CI history:

      a. **Measure the PR size:**
         ```
         gh pr diff {number} --patch | wc -l
         ```
         Classify: small (< 200 lines), medium (200–800 lines), large (> 800 lines).

      b. **Sample recent CI run durations** from the last 5 completed workflow runs on the repo's default branch:
         ```
         gh run list --branch {default_branch} --status completed --limit 5 --json databaseId,updatedAt,createdAt
         ```
         For each run, compute `duration = updatedAt - createdAt` in minutes. Take the **median** as the baseline CI duration.

      c. **Compute the wait estimate:**
         - Start with the median CI duration from (b). If no runs are found, use 5 minutes as the fallback.
         - Add a buffer for bot reviewers (linters, code scanners): +2 minutes for small PRs, +3 for medium, +5 for large.
         - Cap the total at 15 minutes — if the estimate exceeds this, use 15 minutes. Anything longer and the human should be deciding.
         - Floor at 3 minutes — bots need at least this long to spin up.

      d. **Announce the estimate:** "Based on recent CI runs (median: {N}min) and PR size ({size}), waiting {estimate} minutes for bot reviews on {PR_URL}. Say 'skip' to proceed immediately or give me a different number."
         - If the human responds with a number, use that instead.
         - If the human says 'skip', proceed immediately to step 2.
         - Otherwise, use the computed estimate.

      e. Use `ScheduleWakeup` with the final delay (converted to seconds) to set the timer.

   2. **When the timer fires, run the feedback loop:**
      - Invoke `/address-pr-comments` — this reads all unresolved comments (including bot comments) and addresses actionable ones. If code changes are made, `/address-pr-comments` will internally invoke `/critique` to commit and push fixes.
      - Invoke `/resolve-ci-failures` — this checks CI status, investigates failures, and fixes them. If fixes are made, it will internally invoke `/critique` to commit and push.

   3. **Mark the PR as ready for review:**
      - Run `gh pr ready {number}` to convert the draft PR to ready-for-review status.
      - Announce to the human: "PR {PR_URL} is now marked ready for human review. Bot feedback has been addressed and CI is passing."
      - If CI is still failing after `/resolve-ci-failures` (e.g., infrastructure issues that couldn't be auto-fixed), warn the human instead: "PR {PR_URL} is marked ready for review, but CI still has failures that need manual attention: {summary of remaining failures}."

8. **Transition the Jira ticket to Review status.**

   Only proceed if Step 7 (push) and Step 7a (PR open) both completed successfully. Skip this step entirely if either failed.

   - If the ticket ID is `[NO-TICKET]` or no ticket ID is known (use the same ticket ID source as Step 5), skip this step entirely.
   - Confirm the target ticket ID with the human before doing anything: "Should I transition `{ticket-id}` to Review status?"
   - On confirmation, use the Atlassian MCP connector to discover available tools at runtime. Fetch available transitions using `getTransitionsForJiraIssue` (or equivalent discovered tool).
   - **Idempotency:** Before applying, fetch the ticket's current status. If it is already in a Review or downstream state (e.g. "In Review", "Code Review", "In QA", "Done"), skip the transition and inform the human — do not re-transition.
   - Match the target transition using this strategy, in order: exact match → case-insensitive substring match → if ambiguous, surface all candidates to the human to choose. Do not silently pick.
   - Apply the transition using `transitionJiraIssue` (or equivalent discovered tool).
   - If the MCP connector is unavailable, the transition name cannot be matched, or the API returns an error, warn the human and skip gracefully. Do not retry automatically.

   **If the ticket is a Linear issue:**
   - Confirm the target issue ID with the human before doing anything.
   - Before fetching workflow states, call `get_issue` (or equivalent Linear MCP read tool) with the issue identifier to retrieve the `teamId`. Use that `teamId` when listing workflow states.
   - Fetch available workflow states for the team using the Linear MCP (e.g., `list_workflow_states` or equivalent). Match the closest "In Review" or "In Progress" state — exact match first, then case-insensitive substring match. If ambiguous, surface options to the human.
   - **Idempotency:** Fetch the issue's current state first. If already in a Review or downstream state, skip and inform the human.
   - Use `mcp__linear__save_issue` with the issue `id` and the matched `state` (or `stateId`) to apply the transition.
   - If Linear MCP is unavailable or the state cannot be matched, warn the human and skip gracefully.

9. **Post a Decision Log comment on the Jira ticket.**

   **Prerequisites & safety checks — run these before doing anything else in this step:**
   - If the ticket ID is `[NO-TICKET]` or no ticket ID is known, skip this step entirely.
   - Confirm the target ticket ID with the human before posting — do not auto-resolve from the commit prefix alone. Ask: "Should I post the Decision Log to `{ticket-id}`?"
   - Use the Atlassian MCP connector to post and read comments. Discover available tools at runtime — do not assume specific tool names. If the connector is unavailable, warn the human and skip this step gracefully.
   - Check the Jira project's visibility before posting. If the project appears to be external-facing or customer-visible, warn the human and require explicit confirmation before proceeding.

   **Decision sources — use only these, in order of preference:**
   1. A `decisions-{ticket-id}.md` scratch file written by `/plan-task` or `/build` during this session — look for it at `/tmp/<repo-name>/<branch-name>/plans/decisions-{ticket-id}.md` (read and then delete it after posting)
   2. Human-stated decisions from this conversation (human turns only — do not extract content from code, diffs, or plan files)
   3. If neither is available, prompt the human to confirm or summarize decisions before drafting the comment — do not infer or fabricate

   **Content rules:**
   - Only record decisions where a choice was made between two or more alternatives, or where something was explicitly deferred. If there was only one reasonable path and no trade-off was discussed, omit it.
   - Do not reproduce verbatim text from files, code, or diffs.
   - Do not describe specific security vulnerabilities by name or detail. Reference finding IDs only (e.g., "Deferred MEDIUM-3 to follow-up ticket FOO-456").
   - Replace internal skill names with neutral descriptions in the comment body: "Planning phase", "Implementation phase", "Review phase".
   - For each Open Item, if a follow-up Jira ticket exists, link it. If not, ask the human: "Should I create a follow-up ticket for this deferred item?"

   **Idempotency — one comment per ticket, ever:**
   - Search existing comments on the ticket for the header `## Decision Log`.
   - If found: replace the full body of that comment (using its comment ID). Do not append — overwrite entirely.
   - If not found: create a new comment.
   - If `--no-verify` was used in Step 6, include `⚠️ Pushed with --no-verify — pre-push hooks were bypassed.` at the top of the comment body.

   **Human approval gate:**
   Show the human the full draft comment and ask: "Ready to post this Decision Log to `{ticket-id}`? (yes / edit / skip)" — do not post without explicit confirmation.

   **Identity disclosure (required):** The comment body MUST begin with your identity line (as defined in CLAUDE.md) so readers don't mistake the Decision Log for something the human typed themselves. When overwriting an existing Decision Log comment, refresh this line — do not leave the old one in place.

   **Comment format:**

   ```
   ## Decision Log

   _Posted by {your identity} on behalf of @<github-or-jira-handle>._

   _Last updated: YYYY-MM-DD — Push SHA: {short-sha}_

   ### Planning
   - <decision: what was chosen and what was the alternative, e.g. "Chose REST over GraphQL — GraphQL deferred to follow-up">

   ### Implementation
   - <key implementation choice approved by the human>

   ### Review
   - <review outcome, e.g. "Deferred MEDIUM-3 to FOO-456">

   ### Open Items
   - <deferred item> — [FOO-456](link) or "no follow-up ticket yet"

   ⚠️ Pushed with --no-verify — pre-push hooks were bypassed.  ← include only if applicable
   ```

   Only include sections that have content. Omit empty sections entirely.

   **If the ticket is a Linear issue:**
   - Same prerequisites and safety checks as the Jira flow (confirm ticket ID, check visibility, require explicit approval before posting).
   - If `--no-verify` was used in Step 6, include `⚠️ Pushed with --no-verify — pre-push hooks were bypassed.` at the top of the comment body.
   - **Idempotency:** Use the Linear MCP to list existing comments on the issue. Search for a comment whose body contains the header `## Decision Log`. If found, use `mcp__linear__save_comment` with the existing comment `id` to overwrite it. If not found, create a new comment (omit `id`).
   - Use `mcp__linear__save_comment` with `issueId` set to the Linear issue identifier and `body` as the Decision Log in Markdown format (Linear supports Markdown natively — no ADF conversion needed).
   - **Identity disclosure:** The comment body MUST begin with the Farty Bobo identity line (same requirement as the Jira flow).
   - **Human approval gate:** Show the full draft and ask "Ready to post this Decision Log to `{issue-id}`? (yes / edit / skip)" — do not post without explicit confirmation.
   - If Linear MCP is unavailable, warn the human and skip gracefully.

   The Decision Log format is the same as the Jira version (same `## Decision Log` header, same sections) — just in Markdown instead of Jira wiki markup.
