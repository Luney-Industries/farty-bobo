---
name: address-pr-comments
description: Used to read PR comments on github and act on them
disable-model-invocation: false
---

# Reads and addresses comments from humans and other agents on github

1. Fetch the open PR for the current branch. If no PR exists, notify the human and stop. If multiple PRs exist, ask the human to select one.
2. Fetch all unresolved comments. Separate human comments from bot/automated comments (Copilot, github-actions, etc.).

3. **Human comments** — assess each:
   - **Stale**: the issue was already fixed in a later commit — note it, do not add to the implementation plan.
   - **Code change needed** (nit, low, medium, high severity): add to the implementation plan.
   - **Discussion needed** (questions, architectural debates): flag for human review rather than acting on them.

   Present this plan to the human — what will be changed, what needs discussion, and what is stale. Wait for explicit approval before proceeding. This is the first approval gate; complete it before moving to step 4.

4. **Bot/automated comments (Copilot, github-actions, etc.)** — these require explicit human approval before ANY action. Never auto-implement bot suggestions. Skip this step entirely if there are no bot comments. For each bot thread, classify it using the first matching category:
   - **Stale**: the issue was already fixed in a later commit — recommend resolving without change.
   - **Valid code bug**: a genuine correctness issue (wrong field name, wrong unit, logic error, not a style or naming preference) — recommend implementing, but wait for approval.
   - **Domain/content suggestion**: wording, thresholds, naming, business logic — domain experts (vets, PMs, etc.) outrank bots. Flag for human to decide; do NOT implement without explicit approval.
   - **Ignorable**: misunderstanding of project structure, ticket hierarchy, or context — recommend ignoring.

   Write a markdown triage table to `/tmp/pr{PR_NUMBER}-copilot-triage.md` (where `{PR_NUMBER}` is the numeric PR ID) with columns: Thread ID (GitHub review thread ID as output by `list-unresolved-threads.sh`) | Comment summary | Your read | Decision (blank). Tell the human to fill in the Decision column (`implement` / `ignore` / `discuss`) and return it. **Do not implement or resolve any bot threads until the human returns the filled-in file.** If the human never returns the file or says to skip, proceed without addressing bot comments.

5. Take actions based on human input from both approval gates. For discussion-type comments, post a reply **inside the review thread** (not as a top-level PR comment) using `gh api repos/{owner}/{repo}/pulls/{pull_number}/comments -X POST -f body="..." -f in_reply_to={comment_id}`, where `{comment_id}` is the numeric ID of the original inline comment (from the `gh api .../pulls/{pr}/comments` response). Never use `gh pr comment` for thread replies — that posts at the top level.

   > **Identity disclosure (required on every posted comment):** Any comment posted on behalf of the human MUST begin with: `_Posted by {your identity} on behalf of @<github-handle>._` (using your identity from CLAUDE.md), then the reply body. Never omit this line.

6. Run `/critique` to ensure changes are reviewed, committed, and pushed.
7. Attempt to resolve addressed PR comment threads. The `gh` CLI still has no native resolve command, so use the helper scripts in this skill's folder:

   ```sh
   # List unresolved threads (tab-separated: id, path:line, author, snippet)
   ./skills/address-pr-comments/list-unresolved-threads.sh <pr-number|pr-url> [--repo OWNER/REPO]

   # Resolve specific threads by ID
   ./skills/address-pr-comments/resolve-threads.sh <thread-id> [<thread-id>...]

   # Or resolve every unresolved thread on a PR
   ./skills/address-pr-comments/resolve-threads.sh --all <pr-number|pr-url> [--repo OWNER/REPO]
   ```

   Paths above are relative to the repo root; invoke with absolute paths if running from elsewhere. Only resolve threads whose feedback you actually addressed. Skip discussion-type threads that are still waiting on a human reply. Resolution requires triage/write permission on the repo — report any failures to the human.
8. Re-request review from the original commenters if they had requested changes or notify them via a PR comment that their feedback has been addressed. Any notification comment MUST also open with the same identity disclosure described in step 5.
9. After pushing, check CI status using `gh pr checks`. If any checks are failing, invoke `/resolve-ci-failures` to investigate and fix them.
10. This skill covers one round of comments. If new comments arrive after this round is complete, the human should invoke this skill again.
