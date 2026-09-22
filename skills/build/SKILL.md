---
name: build
description: Used to build and execute an approved implementation plan by spinning up agents
disable-model-invocation: false
---

# Best Practices for implementing code changes and pushing them using git

**STOP. Before doing ANYTHING else — before reading files, before pulling branches, before spinning agents — complete Step 1. It is blocking.**

1. **Determine branch strategy first.** Resolve the default branch (no network call — use local refs):
   ```
   DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')
   # fallback: try network
   DEFAULT_BRANCH=${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')}
   DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
   ```
   Detect current context (for display only):
   - Run `git rev-parse --git-dir` vs `git rev-parse --git-common-dir` — note if already in a worktree.
   - Note current branch name and whether it equals `DEFAULT_BRANCH`.

   Assemble a context line using these two facts independently (they can both be true at once):
   `Current branch: <name> [on default branch] | [inside worktree]`

   Then **always** present this prompt to the human and **wait for their reply**. If running non-interactively (no human at keyboard), default to Option 1 automatically and log it.

   ```
   Current branch: <name> [on default branch] | [inside worktree]

   How do you want to work on this?
   1. Worktree — new git worktree from <DEFAULT_BRANCH> at ../<repo-name>-<branch-name>. Keeps root repo clean.
   2. New branch here — create and check out a new branch from <DEFAULT_BRANCH> in this directory (root repo).
   3. Reuse current branch/worktree — continue on <current-branch> as-is.
   ```

   - **Option 1 (Worktree):** Use `EnterWorktree` if available — it switches the agent's working context into the new worktree. If `EnterWorktree` is unavailable, run `git worktree add ../<repo-name>-<branch-name> $DEFAULT_BRANCH` and then `cd` into the new worktree directory before doing any file operations. Create one worktree per branch — agents on the same branch share it. Worktree path convention: `../<repo-name>-<branch-name>` (sibling directory, dash-separated). Clean up with `git worktree remove` after merge or abandonment.
   - **Option 2 (New branch here):** `git checkout -b <branch-name> $DEFAULT_BRANCH`.
   - **Option 3 (Reuse):** Confirm current branch and continue. Refuse if the current branch IS `DEFAULT_BRANCH`.

   Branch name format: `kinano/{jira-ticket-id}-{short-description}` (max 40 chars for description). If no ticket ID, use `kinano/{short-description}`.

2. You will be provided with specific instructions to implement code changes to achieve specific outcomes. Pull the base branch for the affected repos and set up the confirmed branch/worktree from Step 1.

3. Ask the human to choose from the following options:
  - spin up an agent
  - spin up a team of agents to implement the provided plan

4. Create a todo list for each agent. Kick off the execution.

5. **Waiting on agents that run tests/builds — never poll synchronously.** Tests and CI runs (`bin/mix ci`, full suites, etc.) can take minutes. The orchestrator must not sit idle babysitting an agent that is itself babysitting a test monitor. Long-running tests/builds should run in the background (`run_in_background` or an equivalent monitor) so the harness can notify on completion rather than the orchestrator holding a synchronous turn open.

   Handle whichever of these actually applies — they are distinct situations, not one blended tip:
   - **An agent reports it's waiting on its own test/CI monitor.** Do not re-poll it. If there is other agent/todo work available, do that now; its completion notification will arrive on its own.
   - **There is no other work left, and this session has `ScheduleWakeup` available** (e.g. running under `/loop` or similar): schedule a wakeup with a delay matched to how long the run actually takes — not a tight poll loop.
   - **There is no other work left, and `ScheduleWakeup` is not available** (an ordinary single-turn session): do not busy-wait or invent a polling loop. End the turn and let the background task notification bring you back — that notification is the resumption mechanism, not an optional convenience.
   - **Recording known-flaky/unrelated test failures as a project memory:** only do this after confirming the failure is pre-existing and unrelated to the change (e.g. it also reproduces on the base branch, or is already documented as flaky elsewhere). Never record a failure as "known-flaky" just because it's inconvenient to investigate — that silently launders a possible regression into a permanent "ignore this" memory.

6. Once the agent(s) are done, assess whether the changes warrant a modularity review:
   - If the diff touches **3+ modules/packages** or exceeds **500 changed lines**, run `/modularity:review` against the affected repos before proceeding to critique. Present coupling findings to the human and address any issues before committing.
   - Otherwise, skip the modularity review.

7. Run `/critique` with the implementation plan and all impacted repos to ensure changes are reviewed, committed, and pushed.

8. Do not leave code comments. The code should be simple and self-explanatory. Comments should be used sparingly.
