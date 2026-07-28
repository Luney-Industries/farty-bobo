---
name: critique
description: Used to run githooks, perform code & plan reviews with expert critics, and commit/push verified changes
disable-model-invocation: false
---


# Code and Plan Review Skill

## Temp Directory

Planning and review artifacts written by `/plan-task` and `/review-multiple-prs` live outside the repo under:

```
TEMP_DIR=/tmp/<repo-name>/<branch-name>
```

Resolve `<repo-name>` and `<branch-name>` using exactly these commands — there is **one** code path, correct both inside and outside a worktree. Do not substitute variants.

```sh
repo_name=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
branch_name=$(git branch --show-current)
# Detached HEAD (mid-rebase, mid-bisect, CI checkout) returns an empty branch name.
[ -n "$branch_name" ] || branch_name="detached-$(git rev-parse --short HEAD)"
TEMP_DIR="/tmp/$repo_name/$branch_name"
```

**Do not use `git rev-parse --show-toplevel`** (returns the worktree path, not the main repo root) **and do not use `git rev-parse --git-common-dir | xargs dirname`** — outside a worktree that returns `.git`, so `dirname` yields `.` and `TEMP_DIR` silently becomes `/tmp/./<branch-name>`. It appears to work, but the repo-name namespacing is gone and two different repos on the same branch name overwrite each other's artifacts with no error.

**Nested paths:** branch names routinely contain slashes (`chore/foo`, `feat/bar`), so `$TEMP_DIR` is a **nested** directory path, often two or more levels deep. Always create it with `mkdir -p "$TEMP_DIR"` — a plain write into a not-yet-existing nested path fails. Note that sibling branches `chore` and `chore/foo` cannot both have a temp dir (one would need to be a file's parent and a directory at once); if `mkdir -p` fails for this reason, tell the human rather than skipping the write.

**macOS note:** `/tmp` → `/private/tmp` and is cleared on reboot. Everything under `$TEMP_DIR` survives context compaction within a session but does **not** survive a reboot. If a session spans a reboot, the human will need to re-state decisions manually.

---

1. Either detect the repos affected from the context OR ask the human to select the repos that should be used to review the code changes or the staged implementation plan (md file):

- current directory
- a list of repos in the file system

2. enable and run githooks in the repos impacted by the code changes and fix errors (linting, type checks, tests) before committing. Most repos have dedicated commands to achieve these goals either in package.json or pyproject.toml.

3. **Skipped-test check — MANDATORY. Do not present review options or proceed to commit until this check is resolved.** Inspect the *added lines only* in the diff (lines beginning with `+`) for skip directives (see the canonical list in the **Skip directives** section below). Only flag directives that appear on added lines — do not flag pre-existing skips in unrelated hunks. If any are found, surface them to the human as HIGH severity findings and require an explicit written reason for each before proceeding. Critics will NOT separately flag these; this pre-check is the sole owner of skipped-test findings to avoid double-reporting.

4. Prompt the human to select their preferred review options:

- one generalist critic (good for simple tasks)
- a team of critics who have expertise in the technology stacks being used and best security practices. The critics must create a markdown file to list their revisions sorted by severity (high first).
- Modularity review: Run `/modularity:review` to analyze coupling across modules using the Balanced Coupling model. Best for changes that introduce or restructure component boundaries, touch multiple modules, or modify public APIs/contracts.
- Codex review: Ask the human to run `/codex:review`
- Manual review by the human.

**UNCONDITIONAL WRITE MANDATE — applies to every option above, no exceptions.**

Whichever option the human picks — generalist, team, modularity, Codex, or manual — the orchestrator MUST write `$TEMP_DIR/_critique-consolidated.md` per Step 5 before presenting any findings in the conversation. Only the generalist and team flows spawn agents, but the mandate is not about agents; it is about never letting review findings exist solely in a conversation that will be compacted away. Specifically:

- **Modularity review:** after `/modularity:review` completes, the summary must inline its findings or link the document `modularity:document` produced. A separate document elsewhere does not satisfy this — the consolidated file must stand alone as a record of what was reviewed and what was found.
- **Codex review:** after the human runs `/codex:review`, record its findings in the summary. If the human never reports back, write the summary with `REVIEW INCOMPLETE — Codex review requested, no result reported` in the header.
- **Manual review:** record reviewer = the human, plus the findings as they stated them. If they reviewed and raised nothing, write `reviewed by human, no findings raised` — that is a real result and belongs on disk.

**Skip directives — canonical list (used by Step 3 and critic prompts):**

`test.skip`, `it.skip`, `xit`, `xdescribe`, `@pytest.mark.skip`, `t.Skip(`, `pending`, or any framework-equivalent skip/todo/pending marker.

**How to run critics:**

All critics use a **file-based output contract**. The orchestrator hands the agent a temp file path; the agent writes its findings there and goes idle; the orchestrator reads the file.

Critic output files live under `TEMP_DIR` (same convention as the rest of this skill — see the Temp Directory section above):
- Generalist: `$TEMP_DIR/critique-{summary}.md` where `{summary}` is a short kebab-case slug of the change (e.g. `fix-auth-redirect`, `skill-patch`).
- Team: `$TEMP_DIR/critique-{specialty}.md` per agent (e.g. `critique-security.md`, `critique-correctness.md`).
- Consolidated summary (written by the orchestrator, **never** by a critic): `$TEMP_DIR/_critique-consolidated.md` — see Step 5.

**Reserved name:** `_critique-consolidated.md` belongs to the orchestrator alone. Never assign it to a critic, and never let a `{summary}` or `{specialty}` slug produce it. The leading underscore exists precisely so no kebab-case slug can collide with it — if a critic and the consolidated file ever shared a path, the orchestrator's later write would silently destroy the critic's raw findings.

**Record the mapping at dispatch time, not at Step 5.** Immediately after spawning critics — before waiting on any of them — write a stub `_critique-consolidated.md` containing the header and a `critic name → output file path` line for every critic dispatched. Step 5 then fills in findings. This way the mapping survives a context compaction between dispatch and Step 5, and a run that dies mid-review still leaves evidence of what was attempted.

Resolve `ticket-id` by checking the current branch name or conversation context; use `NO-TICKET` if none is found. Create `TEMP_DIR` with `mkdir -p` before spawning any agents.

**Adversarial framing — applies to ALL critic agents (generalist, team, and inline fallback reasoning):**

Every critic must be prompted as an adversary, not a passive reviewer. Include this instruction in every critic's prompt, and apply it when falling back to inline reasoning: "You are an adversarial critic. Assume the code is wrong until proven otherwise. Your job is to attack this change — find bugs, security holes, broken invariants, missing edge cases, and bad design decisions. Be aggressive. Do not give the benefit of the doubt. If something looks suspicious, call it out. Findings that survive scrutiny are more valuable than polite observations."

**HARD GUARD — NO ASSUMPTIONS, EVER. Read this before spawning any critic.**

The orchestrator MUST NOT proceed to the "Present findings" step until it has **positive, explicit confirmation** that every spawned critic has finished. Critics have taken longer than expected in the past, and the orchestrator wrongly reported "nothing found" while a critic was still working — this led the human astray with a false clean bill. That failure mode is now explicitly forbidden. This is the one rule everything below hinges on:

> **A critic's Agent tool call returning is NOT the same as the critic finishing.** By default agents run in the background (`run_in_background: true`), and a background call returns control to the orchestrator *at dispatch time* — while the agent keeps working. The orchestrator must wait for that specific agent's completion/idle notification. Never read, touch, or summarize a critic's output file before that notification arrives, no matter how the tool call itself behaved.

Supporting rules:
- Never treat "no tool result yet," or a returned dispatch call, as "no findings." Absence of a confirmed-complete result is not evidence of absence of problems.
- Every critic — with no exceptions — MUST end its work by writing its findings, or an explicit clean-pass statement (e.g. literally "no findings"), to its assigned markdown file. A critic that goes idle without having written to its file is a **missing-output failure state**, not a silent pass — see the fallback step in each flow below.
- **Bounded wait, not an infinite trap.** If a critic has not reported completion after a reasonable wait and shows no sign of activity (crashed, hung, orphaned), treat it the same as the missing-output failure state above: fall back to inline reasoning for that critic and disclose it to the human. Do not block forever — "wait for real completion" is not license to hang indefinitely with no exit.
- If the human interrupts, or the orchestrator is tempted to move on for any reason before every critic has reported, STOP and say explicitly which critics are still running. Do not summarize partial results as if they were final.

**One generalist critic:**
a. Create `TEMP_DIR` with `mkdir -p "$TEMP_DIR"`.
a2. Immediately after spawning (see b), write the stub `_critique-consolidated.md` with the critic name → output file mapping, per the "Record the mapping at dispatch time" rule above.
b. Spawn a single Agent with a focused prompt containing: the full diff, the repo name, the task description, the output file path, and the adversarial framing above. Instruct it to write findings sorted by severity (HIGH / MEDIUM / LOW) to that file, or write "no findings" if nothing is worth raising. Do NOT instruct the critic to flag skipped tests — the Step 3 pre-check owns that. Keep the prompt tight — do not dump the full conversation history into it.
c. **Wait for the completion notification, not the tool call return.** Do not read the output file until this specific agent has reported idle/complete, per the HARD GUARD above. Apply the bounded-wait rule if it never reports.
d. Once completion is confirmed (or the bounded wait expires), read the output file.
e. If the file is missing or empty, fall back to inline reasoning using the adversarial framing above — and **disclose to the human** that the critic produced no output file (and, if applicable, that the bounded wait expired) and this review is inline-only.
f. Present findings to the human (global Step 5).

**Team of critics:**
a. Create `TEMP_DIR` with `mkdir -p "$TEMP_DIR"`.
a2. Immediately after spawning (see b), write the stub `_critique-consolidated.md` with each critic's name → output file mapping, per the "Record the mapping at dispatch time" rule above.
b. Spawn one Agent per specialty (e.g. security, performance, correctness) — each with its own output file path and the adversarial framing above. Do NOT instruct critics to flag skipped tests — the Step 3 pre-check owns that. Run all agents in parallel (single message, multiple Agent tool calls).
c. **Wait for every single one's completion notification, not their tool call returns.** Track each critic by name/id. Do not read any output file, and do not proceed to (d), until you have confirmed real completion for ALL spawned critics per the HARD GUARD above. A subset finishing early does not authorize acting on partial results. Apply the bounded-wait rule per-critic to any that never report.
d. Once all critics have confirmed completion (or their bounded waits expire), read all output files.
e. For any file that is missing or empty, fall back to inline reasoning for that specialty using the adversarial framing above — and **disclose to the human** which critics produced no output (and, if applicable, which bounded waits expired) and that those portions are inline-only.
f. Synthesize all findings into a single sorted list, deduplicating overlapping issues across agents. Present to the human (global Step 5).

5. **Write the consolidated findings to disk, then present them to the human.**

   **Write first, present second, unconditionally.** Run `mkdir -p "$TEMP_DIR"` as the first action of this step (harmless if it exists), then write the synthesized findings to `$TEMP_DIR/_critique-consolidated.md` before showing anything in the conversation. Write it even when the review was clean, when every critic failed, and when the human is about to ignore the findings — a missing file is indistinguishable from a review that never ran. If `mkdir -p` or the write fails, say so plainly to the human instead of quietly presenting findings in chat only.

   This file survives context compaction within the session, which the conversation does not. It does **not** survive a reboot — see the macOS note above. For a record that outlives the machine, reference it from the PR (Step 8a) or the Decision Log (Step 10).

   Contents:
   - Header: repo name, branch, ticket ID, and the diff base written as `uncommitted changes reviewed on top of {short-sha}` — Step 5 runs before the commit, so `git rev-parse --short HEAD` is the commit *preceding* the reviewed changes. Never label it as the commit containing them.
   - Which review option was used and which critics ran (from the dispatch-time stub). Name every critic that produced no output file or whose bounded wait expired, and mark those portions inline-only.
   - Any HIGH severity skipped-test findings from Step 3, with the human's stated reason for each. These are available by the time Step 5 runs — Step 3 requires the reasons before the review options are even offered.
   - All findings sorted by severity (HIGH → MEDIUM → LOW), deduplicated across critics. For each: severity, short title, `file:line`, what's wrong, and the recommended fix.
   - A disposition section, left as `_Pending human decision._` until Step 5b.

   **Never write a clean verdict for a failed run.** Only write "no findings" if at least one critic — or a disclosed inline fallback — actually completed and reported clean. If every critic failed to produce output, the header must read `REVIEW INCOMPLETE — no critic produced output`. Writing "no findings" because nothing was reported is the same false clean bill the HARD GUARD above exists to prevent.

   Then present the findings in the conversation **and echo the paths**: the `_critique-consolidated.md` path plus every per-critic file path. Tell the human `$TEMP_DIR` is under `/tmp` and dies on reboot, so they should copy what they want to keep.

   Then prompt them to select the next step:

- Ignore code review revisions and proceed to next step.
- Implement revisions. Use the original agent(s) to implement changes.

5b. **Update the consolidated file to match reality — run this before Step 6, on both branches above.**

   - If revisions were implemented: mark each finding `FIXED`, `IGNORED`, or `DEFERRED` in the disposition section, and refresh the diff-base line — the tree the original SHA described no longer exists.
   - If revisions were ignored: record that the findings were reviewed and consciously accepted, and by whom.

   Do not leave a summary claiming open issues that are already resolved, or a diff base that points at a stale tree.

6. **Branch safety check — MANDATORY. Run this even if the review step errored, was skipped, or produced no findings.** Run `git branch --show-current` and compare against the repo's default branch (typically `main` or `master`).
   - If on the default branch: warn the human — "You are on `{branch}` (the default branch). Committing directly here is not recommended. Should I create a new branch first, or do you explicitly approve committing to `{branch}`?"
   - Do not proceed to Step 7 until the human has either approved committing to the default branch explicitly or confirmed a new branch to use.
   - If the human chooses a new branch: create it from the current HEAD (`git checkout -b {branch-name}`), then continue.

7. Prepare, summarize the changes in the changed files. Always prefix commits with [{ticket-id}]: {summary of change}. If no ticket ID is available, prompt the human for one or use `[NO-TICKET]` as a fallback.
   - Before committing, confirm `_critique-consolidated.md` is current per Step 5b. Do not commit alongside a stale summary.
   - Temporary review and planning files (`review-draft-*.md`, `critique-*.md`, `_critique-consolidated.md`, `plans/*.plan.md`, `plans/decisions-*.md`, `plans/stubs/**`) are written to `/tmp/<repo-name>/<branch-name>/` — outside the repo — and must never appear in `git status`. If any such file is found inside the repo, do not stage it and delete it immediately.
   **Match these names only at the root of `$TEMP_DIR`, never as a repo-wide glob.** A tracked file like `docs/critique-guidelines.md` matches `critique-*.md` and must NOT be touched — the delete action here applies solely to stray temp artifacts that leaked into the repo. When in doubt, ask rather than delete: check `git ls-files` first, and never delete a tracked file.
   Permanent project docs (`README.md`, `SKILL.md`, `AGENTS.md`, etc.) should still be committed when changed.
8. Commit and push. If the push fails due to pre-push hook errors, prompt the human for approval before using `git push --no-verify`. If `--no-verify` was used, record this in the Decision Log (Step 10) as a warning line.

8a. **Open a draft pull request.** After a successful push, open a **draft** PR using `gh pr create --draft --assignee @me` (or equivalent). The `--assignee @me` flag assigns the current authenticated GitHub user automatically.

   **PR body:** Read `.github/PULL_REQUEST_TEMPLATE.md` from the repo root and use it as the base for the PR body — fill in the Summary and Test plan sections with content relevant to the change. If the file does not exist, use a bare `## Summary` / `## Test plan` structure. Include a short "Review" note summarizing the review outcome from `_critique-consolidated.md` (option used, counts by severity, anything deferred) — this is what makes the review outcome outlive `/tmp`. Do not paste the whole file, and do not describe specific security vulnerabilities in detail; reference finding IDs. Never append Anthropic or Claude Code branding lines (e.g. `🤖 Generated with Claude Code`) to the PR body.

   **If PR creation failed, stop here — skip the reviewer fallback chain, skip Steps 9 and 10, and warn the human.**

   Otherwise, capture the PR number from the `gh pr create` output (it appears in the PR URL, e.g. `https://github.com/{owner}/{repo}/pull/{number}`). Then **immediately call the `Skill` tool with `skill: "request-github-review"` and `args: "{PR number}"`** — do NOT hand this off to the human, do NOT mention it as a next step, do NOT skip it. This is a required automated step. `/request-github-review` will request automated review and then run the bot feedback loop — waiting for CI and bot reviews, addressing comments, resolving CI failures, and marking draft PRs ready for review when done.

   *(End of Step 8a)*

9. **Transition the Jira ticket to Review status.**

   Only proceed if Step 8 (push) and Step 8a (PR open) both completed successfully. Skip this step entirely if either failed.

   - If the ticket ID is `[NO-TICKET]` or no ticket ID is known (use the same ticket ID source as Step 6), skip this step entirely.
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

10. **Post a Decision Log comment on the Jira ticket.**

   **Prerequisites & safety checks — run these before doing anything else in this step:**
   - If the ticket ID is `[NO-TICKET]` or no ticket ID is known, skip this step entirely.
   - Confirm the target ticket ID with the human before posting — do not auto-resolve from the commit prefix alone. Ask: "Should I post the Decision Log to `{ticket-id}`?"
   - Use the Atlassian MCP connector to post and read comments. Discover available tools at runtime — do not assume specific tool names. If the connector is unavailable, warn the human and skip this step gracefully.
   - Check the Jira project's visibility before posting. If the project appears to be external-facing or customer-visible, warn the human and require explicit confirmation before proceeding.

   **Decision sources — use only these, in order of preference:**
   1. A `decisions-{ticket-id}.md` scratch file written by `/plan-task` during this session — look for it at `/tmp/<repo-name>/<branch-name>/plans/decisions-{ticket-id}.md` (read and then delete it after posting)
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
   - If `--no-verify` was used in Step 8, include `⚠️ Pushed with --no-verify — pre-push hooks were bypassed.` at the top of the comment body.

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
   - If `--no-verify` was used in Step 8, include `⚠️ Pushed with --no-verify — pre-push hooks were bypassed.` at the top of the comment body.
   - **Idempotency:** Use the Linear MCP to list existing comments on the issue. Search for a comment whose body contains the header `## Decision Log`. If found, use `mcp__linear__save_comment` with the existing comment `id` to overwrite it. If not found, create a new comment (omit `id`).
   - Use `mcp__linear__save_comment` with `issueId` set to the Linear issue identifier and `body` as the Decision Log in Markdown format (Linear supports Markdown natively — no ADF conversion needed).
   - **Identity disclosure:** The comment body MUST begin with the Farty Bobo identity line (same requirement as the Jira flow).
   - **Human approval gate:** Show the full draft and ask "Ready to post this Decision Log to `{issue-id}`? (yes / edit / skip)" — do not post without explicit confirmation.
   - If Linear MCP is unavailable, warn the human and skip gracefully.

   The Decision Log format is the same as the Jira version (same `## Decision Log` header, same sections) — just in Markdown instead of Jira wiki markup.
