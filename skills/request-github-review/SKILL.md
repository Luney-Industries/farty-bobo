---
name: request-github-review
description: Request an automated review on a GitHub PR. Tries Copilot first, then posts @codex and @claude review trigger comments. Also runs the bot feedback loop: waits for CI/bot reviews, addresses comments, resolves CI failures, then marks draft PRs ready for review.
model: haiku
disable-model-invocation: false
---

# Request GitHub Review Skill

Request an automated reviewer on a GitHub pull request using the Copilot → Codex + Claude fallback chain. Also manages the bot feedback loop after review is requested — for all PRs, not just drafts.

This skill may be invoked multiple times in the PR lifecycle (e.g. after each new round of bot feedback).

## Input

A PR number. Detect it from context (e.g. recent `gh pr create` output, current branch PR) or ask the human: "Which PR number should I request a review for?"

## Steps

1. **Try Copilot first.**

   ```
   gh pr edit {number} --add-reviewer "Copilot"
   ```

2. **If that command exits non-zero**, inspect the error output:

   - If it contains any of: `"Could not resolve to a User"`, `"not found"`, `"is not a collaborator"`, `"does not have access"` — these signal that Copilot is permanently not configured on this repo. Fall through to Step 3.
   - If it fails for any **other** reason (network error, auth failure, rate limit, unexpected output) — **do not fall through**. Surface the error to the human and stop.

3. **Fall back to @codex and @claude review comments.**

   Post both trigger comments:

   ```
   gh pr comment {number} --body "@codex review"
   gh pr comment {number} --body "@claude review"
   ```

   Both are best-effort. Each bot must be installed and enabled on the repo for the comment to queue a review — `gh` exits 0 regardless of whether a review was actually queued. Inform the human of this uncertainty for each.

4. **If Step 3 fails** (i.e. either `gh pr comment` exits non-zero), warn the human about the failure and stop.

5. **Bot review loop.**

   **If this skill is already running in a parent invocation (i.e. the call chain is `/request-github-review` → `/address-pr-comments` or `/resolve-ci-failures` → `/critique` → `/request-github-review`), skip Step 5 entirely** — the bot loop is already active and re-entering it would cause an infinite loop.

   After review is requested, wait for automated reviewers (bots, linters, CI) to post their feedback:

   a. **Estimate the wait time** based on PR size and recent CI history:

      i. **Measure the PR size:**
         ```
         gh pr diff {number} --patch | wc -l
         ```
         Classify: small (< 200 lines), medium (200–800 lines), large (> 800 lines).

      ii. **Sample recent CI run durations** from the last 5 completed workflow runs on the repo's default branch:
         ```
         gh run list --branch {default_branch} --status completed --limit 5 --json databaseId,updatedAt,createdAt
         ```
         For each run, compute `duration = updatedAt - createdAt` in minutes. Take the **median** as the baseline CI duration.

      iii. **Compute the wait estimate:**
         - Start with the median CI duration from (ii). If no runs are found, use 5 minutes as the fallback.
         - Add a buffer for bot reviewers (linters, code scanners): +2 minutes for small PRs, +3 for medium, +5 for large.
         - Cap the total at 15 minutes — if the estimate exceeds this, use 15 minutes. Anything longer and the human should be deciding.
         - Floor at 3 minutes — bots need at least this long to spin up.

      iv. **Announce the estimate:** "Based on recent CI runs (median: {N}min) and PR size ({size}), waiting {estimate} minutes for bot reviews on {PR_URL}. Say 'skip' to proceed immediately or give me a different number."
         - If the human responds with a number, use that instead.
         - If the human says 'skip', proceed immediately to step b.
         - Otherwise, use the computed estimate.

      v. Use `ScheduleWakeup` with the final delay (converted to seconds) to set the timer.

   b. **When the timer fires, run the feedback loop:**
      - Invoke `/address-pr-comments` — this reads all unresolved comments (including bot comments) and addresses actionable ones. If code changes are made, `/address-pr-comments` will internally invoke `/critique` to commit and push fixes.
      - Invoke `/resolve-ci-failures` — this checks CI status, investigates failures, and fixes them. If fixes are made, it will internally invoke `/critique` to commit and push.

   c. **Mark the PR as ready for review (draft PRs only):**
      - Check if the PR is still a draft: `gh pr view {number} --json isDraft --jq '.isDraft'`
      - If it is a draft, run `gh pr ready {number}` to convert it to ready-for-review status.
      - Announce to the human: "PR {PR_URL} is now marked ready for human review. Bot feedback has been addressed and CI is passing."
      - If CI is still failing after `/resolve-ci-failures` (e.g., infrastructure issues that couldn't be auto-fixed), warn the human instead: "PR {PR_URL} is marked ready for review, but CI still has failures that need manual attention: {summary of remaining failures}."
      - If the PR was already non-draft, skip the `gh pr ready` call but still announce that bot feedback has been addressed.

## Output

Report the outcome clearly:

- "Added Copilot as reviewer on PR #{number}." — if Step 1 succeeded.
- "Copilot is not available as a reviewer on this repo (permanent configuration state, not a transient failure). Posted `@codex review` and `@claude review` on PR #{number} — reviews will be queued if the respective bots are installed." — if Step 3 was used.
- Surface errors verbatim if either step failed unexpectedly.
- For all PRs: report when the bot loop completes and feedback has been addressed. For draft PRs specifically, also report when the PR is marked ready (or when CI still needs attention).
