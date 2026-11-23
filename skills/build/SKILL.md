---
name: build
description: Used to build and execute an approved implementation plan by spinning up agents
disable-model-invocation: false
---

# Best Practices for implementing code changes and pushing them using git

**STOP. Before doing ANYTHING else — before reading files, before pulling branches, before spinning agents — complete Step 1. It is blocking.**

1. **Determine branch strategy first.** Resolve the default branch and where the session is. Run this block as-is:

```sh
# >>> default-branch (canonical: skills/build/SKILL.md; tests/test-worktree-setup.sh enforces sync)
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
MAIN_CHECKOUT=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
echo "DEFAULT_BRANCH=$DEFAULT_BRANCH MAIN_CHECKOUT=$MAIN_CHECKOUT CURRENT=$(git rev-parse --show-toplevel) BRANCH=$(git branch --show-current)"
git worktree list
# <<< default-branch
```

   **The main checkout never leaves `DEFAULT_BRANCH`.** The main checkout is the first entry in `git worktree list` (`MAIN_CHECKOUT`). Never run `git checkout` or `git switch` to another branch there. All feature work happens in a linked worktree under `MAIN_CHECKOUT/.claude/worktrees/`. If the main checkout is already on some other branch, stop and tell the human. Do not build on it, and do not switch it back yourself, because it may hold their uncommitted work.

   **a. Reuse a setup from earlier in this conversation, if there is one.** Look for the **most recent** turn in this conversation that set up a branch or worktree **for the task `/build` was handed** (same ticket ID, or same plan file). Qualifying sources:

   - The human naming the branch or worktree to use (e.g. "work in the X worktree").
   - `/plan-task` Step 2b, or an earlier `/build`, creating or choosing one.
   - The decisions file at the exact path `/plan-task` handed to `/build` in this conversation. Never glob for `decisions-*.md` — a leftover file from another task would match.

   A setup made for a different task does not count. If two sources disagree, ask the human which one to use.

   Validate the candidate before reusing it. All of these must hold:

   - The branch is not `DEFAULT_BRANCH`.
   - The branch has a linked worktree in `git worktree list` (not the main checkout). If the branch exists but has no worktree, create one for it with the worktree-setup block below and `EXISTING_BRANCH='yes'`.
   - The branch is not already shipped: `git for-each-ref --format='%(upstream:track)' refs/heads/<branch>` is not `[gone]`, and, when `gh` is available, `gh pr list --head <branch> --state all --json state --jq '.[].state'` shows no `MERGED` or `CLOSED` without an `OPEN` one.

   If every check passes, enter the worktree (`EnterWorktree` with `path`, or `cd`), print one line, and continue to Step 2:

   `Reusing worktree from earlier: <path> on <branch> (source: <human | /plan-task | previous /build | decisions file>)`

   If there is no qualifying source, or a check fails (say which), go to **b**. Being inside some worktree is not, by itself, a setup to reuse — it may be left over from other work, so ask.

   **b. Otherwise ask.** Present this prompt and **wait for the reply**. If running non-interactively (no human at keyboard), pick Option 1 and log it.

   ```
   Current location: <main checkout | worktree at <path>> on <branch>

   How do you want to work on this?
   1. New worktree — branch <proposed-branch> from origin/<DEFAULT_BRANCH> at .claude/worktrees/<branch-slug>.
   2. Switch into an existing worktree:
      a. <path> (<branch>)   ← current, if the session is already in one
      b. <path> (<branch>)
   ```

   List under Option 2 every linked worktree from `git worktree list` except the main checkout and any on `DEFAULT_BRANCH`. If there are none, drop Option 2 and just confirm the branch name for Option 1.

   - **Option 1 (New worktree):** Fill in `BRANCH_NAME` and run the worktree-setup block below as **one** Bash call — shell variables do not survive between calls. Then enter the printed `WORKTREE_PATH` with `EnterWorktree` (`path`), or `cd` into it, before any file operation. Do not create worktrees with `EnterWorktree` `name`: it picks its own folder, branch name and base. If the block reports a taken path or branch name, ask the human for another name. Never reuse the directory.
   - **Option 2 (Existing worktree):** Run the validation checks from **a** on the chosen worktree, then enter it with `EnterWorktree` (`path`), or `cd`.

   One worktree per branch. Agents on the same branch share it. Clean up with `git worktree remove` after merge or abandonment.

   **Worktree setup block.** It finds the main checkout from anywhere, makes git ignore `.claude/worktrees/` via the shared `info/exclude` (tracked files stay untouched), refuses taken paths and names before creating anything, and cuts new branches from freshly fetched `origin/<DEFAULT_BRANCH>` with no upstream (so a later `git push` does not target the default branch). Branch slashes become dashes in the folder name: `kinano/foo` lives at `.claude/worktrees/kinano-foo`.

```sh
# >>> worktree-setup (canonical: skills/build/SKILL.md; tests/test-worktree-setup.sh enforces sync)
BRANCH_NAME='<branch-name>'
EXISTING_BRANCH='no'
fail() { echo "ERROR: $*" >&2; exit 1; }
case "$BRANCH_NAME" in ''|'<branch-name>') fail "fill in BRANCH_NAME" ;; esac
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
DEFAULT_BRANCH=${DEFAULT_BRANCH:-$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')}
DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
[ "$BRANCH_NAME" != "$DEFAULT_BRANCH" ] || fail "refusing to create a worktree for $DEFAULT_BRANCH"
REPO_ROOT=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
[ "$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || fail "main working tree not found (bare repo?)"
COMMON_DIR=$(cd "$(git rev-parse --git-common-dir)" && pwd) || fail "git common dir not found"
git -C "$REPO_ROOT" check-ignore -q .claude/worktrees/probe
case $? in
  0) ;;
  1) mkdir -p "$COMMON_DIR/info"
     if [ -s "$COMMON_DIR/info/exclude" ] && [ -n "$(tail -c1 "$COMMON_DIR/info/exclude")" ]; then echo >> "$COMMON_DIR/info/exclude"; fi
     echo '/.claude/worktrees/' >> "$COMMON_DIR/info/exclude" ;;
  *) fail "git check-ignore failed" ;;
esac
WORKTREE_PATH="$REPO_ROOT/.claude/worktrees/$(printf '%s' "$BRANCH_NAME" | tr '/' '-')"
[ ! -e "$WORKTREE_PATH" ] || fail "$WORKTREE_PATH already exists; pick another branch name"
if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
  [ "$EXISTING_BRANCH" = yes ] || fail "branch $BRANCH_NAME already exists; pick another name"
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME" || fail "git worktree add failed"
else
  [ "$EXISTING_BRANCH" = no ] || fail "branch $BRANCH_NAME does not exist"
  git fetch --quiet origin "$DEFAULT_BRANCH" 2>/dev/null || echo "WARNING: could not fetch origin/$DEFAULT_BRANCH; branching from the last fetched copy" >&2
  BASE="origin/$DEFAULT_BRANCH"
  git rev-parse --verify --quiet "$BASE" >/dev/null || BASE="$DEFAULT_BRANCH"
  git worktree add --no-track -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE" || fail "git worktree add failed"
fi
echo "WORKTREE_PATH=$WORKTREE_PATH"
# <<< worktree-setup
```

   Branch name format: `kinano/{jira-ticket-id}-{short-description}` (max 40 chars for description). If no ticket ID, use `kinano/{short-description}`.

2. You will be provided with specific instructions to implement code changes to achieve specific outcomes. The worktree-setup block already fetched `origin/<DEFAULT_BRANCH>`. Never check out `DEFAULT_BRANCH` in a worktree to pull it. When Step 1 reused a worktree, do not recreate, reset, or rebase it — it may hold committed work from earlier turns (e.g. the acceptance test file from `/plan-task`).

3. **Determine agent strategy.** Check this conversation first, same as Step 1:
   - If the human already said how to staff **this task** (single agent, a team, a specific split), use that and print `Reusing agent strategy from earlier: <strategy>`.
   - If an earlier `/build` **for this same plan** spawned implementer agents that are still addressable, list them to the human and offer to resume them with `SendMessage` instead of spawning fresh ones. They keep their context. Resume only the ones the human keeps, and start each resume message with the current worktree path and branch, since they may have been working somewhere else. Never resume critics, researchers, or agents from another task as builders.

   Otherwise ask the human to choose from the following options:
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
