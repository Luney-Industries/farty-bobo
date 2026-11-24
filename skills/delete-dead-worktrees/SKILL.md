---
name: delete-dead-worktrees
description: >
  Delete dead git worktrees. A worktree is dead if it has no uncommitted changes, OR if its
  branch was pushed to origin and that branch has since been deleted from origin (e.g. after a
  merged/closed PR). After removing a dead worktree, also deletes the local branch it had checked
  out, as long as that can be done without losing commits. Trigger when the user says things like
  "clean up worktrees", "delete dead worktrees", "prune old worktrees", "remove stale worktrees",
  or "worktree cleanup".
model: sonnet
---

# Cleanup Dead Worktrees

A dead worktree is one that is safe to delete because all meaningful work is either gone or
already preserved in the remote. There are exactly two conditions that make a worktree dead:

1. **No changes** — the worktree has no uncommitted changes (staged or unstaged) AND no commits
   that haven't been pushed somewhere already.
2. **Branch deleted from origin** — the worktree's branch was pushed to origin at some point,
   but the remote branch no longer exists (i.e., the PR was merged or the branch was deleted).

The main worktree (the one at the repo root) is **never** a candidate for deletion. Neither is
the worktree you are currently running in (the `current session` worktree, see Step 2).

When a dead worktree is removed, the local branch it had checked out is deleted too (Step 7),
so dead branches don't pile up in `git branch` forever. Branch deletion is safe by default: a
branch is only force-deleted when its commits are provably preserved on the remote, or when the
user explicitly says yes after seeing the commits that would be lost.

---

## Steps

### 1. Fetch and prune remote tracking refs

Run this against the main worktree (`<MAIN_WT>`, found in Step 2; any worktree of the repo
works for the fetch itself):

```bash
git fetch --prune
```

This removes stale remote-tracking refs (e.g. `origin/feature-x` that no longer exist on the
remote). Without this step, condition 2 cannot be evaluated correctly.

Remember whether this fetch **succeeded** (`FETCH_OK = yes/no`). Step 7 needs it: if the fetch
failed, remote-tracking refs may be stale and cannot be used as proof that commits are preserved.

### 2. List all worktrees and identify the main and current worktrees

```bash
git worktree list --porcelain
```

Parse the output to get each worktree's:

- `worktree` — absolute path to the worktree directory
- `branch` — the branch checked out in that worktree (e.g. `refs/heads/feature-x`)
- `HEAD` — current commit SHA

The **first** entry is always the main worktree. Record its path as `<MAIN_WT>` and skip it.
Every git command in Steps 6 and 7 runs as `git -C <MAIN_WT> ...`, never from the shell's
current directory (which may be a worktree that is about to be deleted).

Next, find the worktree you are running in:

```bash
git rev-parse --show-toplevel
```

Run this from the current working directory (no `-C`). Record the result as `<CURRENT_WT>`.
Compare it to each worktree path after resolving symlinks on both sides (e.g. `cd <path> && pwd -P`),
because macOS paths like `/var/...` and `/private/var/...` refer to the same place. If the command
fails (the cwd is not inside this repo), there is no current-session worktree.

The worktree at `<CURRENT_WT>` is **never** a candidate for deletion, even if it is clean. Show it
in the Step 4 table with the note `current session` and do not evaluate it further.

### 3. Evaluate each worktree

For every worktree other than `<MAIN_WT>` and `<CURRENT_WT>`, run the checks below. A worktree is
dead if **either** condition is true.

#### Condition 1 — No changes

First, check the working tree:

```bash
git -C <worktree-path> status --porcelain
```

If the output is **not** empty, the worktree has uncommitted changes — stop here and do NOT mark
it dead under this condition.

If the working tree is clean, determine whether unpushed commits exist. The approach depends on
whether the branch has an upstream configured:

**Case A — upstream is configured:**

```bash
git -C <worktree-path> config --get branch.<branch-name>.merge
```

If this returns a value, an upstream exists. Check for unpushed commits:

```bash
git -C <worktree-path> log @{u}..HEAD --oneline
```

If this returns nothing, there are no unpushed commits. Mark as dead under condition 1.

**Case B — no upstream configured:**

Find the default branch reference. Try these in order until one succeeds:

```bash
# Option 1: use origin/HEAD if it resolves
git -C <worktree-path> rev-parse --verify refs/remotes/origin/HEAD 2>/dev/null
# If resolved, get the branch name:
git -C <worktree-path> symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||'

# Option 2: check for origin/main
git -C <worktree-path> rev-parse --verify refs/remotes/origin/main 2>/dev/null

# Option 3: check for origin/master
git -C <worktree-path> rev-parse --verify refs/remotes/origin/master 2>/dev/null
```

Use the first one that resolves as `DEFAULT_REF`. If none resolves, skip this worktree — cannot
safely evaluate it.

Now check for commits ahead of the default:

```bash
git -C <worktree-path> log ${DEFAULT_REF}..HEAD --oneline
```

If there are **any** commits ahead of the default branch, skip this worktree — it has unshared
work. Do NOT mark it dead.

If the output is empty (no commits ahead of default), mark as dead under condition 1.

**Possibly in use:** a worktree that is dead under Case B (has a branch, no upstream, zero
commits ahead of default) looks exactly like a worktree someone just created and hasn't committed
to yet — another agent or Claude session may be working in it right now. Mark it
`possibly in use (new, no commits yet)`. It stays in the list, but it is **excluded from a blanket
"delete all"** in Step 5 — it is only deleted if the user names it explicitly.

#### Condition 2 — Branch pushed then deleted from origin

After `git fetch --prune` (Step 1), any remote-tracking ref that no longer exists on the remote
has already been removed locally. So no second network call is needed — check the local ref store.

First, confirm the branch was configured to track `origin`:

```bash
git -C <worktree-path> config --get branch.<branch-name>.remote
```

If this returns `origin`, the branch was tracking a remote at some point. Now check if the
remote-tracking ref still exists locally:

```bash
git -C <worktree-path> rev-parse --verify refs/remotes/origin/<branch-name> 2>/dev/null
```

If this returns **empty output** (non-zero exit), the remote branch is gone. Mark as dead under
condition 2.

A condition-2 worktree can still carry commits made **after** the push (e.g. the PR was merged,
the remote branch was auto-deleted, and work continued locally). Count them now so the user sees
them before confirming:

```bash
git -C <worktree-path> log refs/heads/<branch-name> --not --remotes --oneline --
```

If this prints anything, add the note `has N local-only commits` to the Step 4 table (N = number
of lines). Those commits are protected by Step 7, but the user should know up front.

Also handle the case where the worktree is in **detached HEAD** state — `git worktree list
--porcelain` emits `detached` instead of a `branch:` line. For detached HEAD worktrees, skip
condition 2 entirely. Apply condition 1 only (check working tree cleanliness and commits ahead of
default branch).

### 4. Present findings to the user

Before building the table, evaluate Step 7's **skip conditions** for every dead worktree's branch
right now (default branch, checked out in another worktree), so the `LOCAL BRANCH` column is
accurate. Do not guess.

Display a table like this:

```
Dead worktrees found:

PATH                          BRANCH       REASON                            LOCAL BRANCH       NOTE
/path/to/worktree-a           feature/foo  No changes, no upstream commits   delete if safe     possibly in use (new, no commits yet)
/path/to/worktree-b           fix/bar      Branch deleted from origin        delete if safe     has 2 local-only commits
/path/to/worktree-c           chore/baz    Both conditions met               delete if safe
/path/to/worktree-d           (detached)   No changes                        n/a
/path/to/worktree-e           develop      No changes, no upstream commits   kept (default branch)

Not candidates:
/path/to/worktree-f           feature/me   current session (never deleted)
```

`LOCAL BRANCH` values:

- `delete if safe` — Step 7 will try to delete it, but only if that can be done without losing
  commits. It may still end up kept.
- `kept (<reason>)` — Step 7 will skip it up front (default branch, or checked out in another
  worktree).
- `n/a` — detached HEAD, no branch to delete.

If no dead worktrees are found, tell the user and stop (still mention the `current session`
worktree if one was excluded).

### 5. Ask for confirmation

**Do not delete anything without explicit user confirmation.**

Ask: "Shall I delete all of these (worktrees, and their local branches where that's safe), or do
you want to pick specific ones? Worktrees marked `possibly in use` are NOT included in 'all' —
name them if you want them gone. Say so if you want to keep any local branches, or if there are
other long-lived branches (e.g. `develop`, `release/*`) I should never delete."

Wait for the user's answer. Never auto-delete.

- "All" means every listed dead worktree **except** those marked `possibly in use`. Delete a
  `possibly in use` worktree only if the user names it (by path or branch).
- If the user says to keep a branch, remove only the worktree and skip Step 7 for that branch.
- If the user names extra protected branches, treat them like the default branch in Step 7.
- **This confirmation never authorizes `git branch -D` on a branch with local-only commits.**
  That needs a separate, explicit yes in Step 7, after the user has been shown those commits.

### 6. Delete confirmed worktrees

For each confirmed worktree, run:

```bash
git -C <MAIN_WT> worktree remove <worktree-path>
```

If the worktree has uncommitted changes that somehow slipped through (shouldn't happen, but
`git worktree remove` will refuse by default), report the error and do NOT use `--force` without
asking the user explicitly.

After deletion, run:

```bash
git -C <MAIN_WT> worktree prune
```

to clean up any leftover administrative files.

Only continue to Step 7 for worktrees that were removed successfully. If `git worktree remove`
failed, leave its branch alone.

### 7. Delete the local branches

Run every command in this step against the main worktree: `git -C <MAIN_WT> ...` for git, and
`cd <MAIN_WT> && gh ...` for gh. Never rely on the shell's current directory — it may be a
worktree that Step 6 just removed. Do this once per removed worktree that had a branch.

**Ref names matter.** In every *inspection* command (`git log`, `git rev-parse`) use the fully
qualified ref `refs/heads/<branch-name>`. A bare name can resolve to a **tag** of the same name
(tags win over branches), which makes the checks below inspect the wrong commits. Only
`git branch -d` / `git branch -D` take the short name (they always operate on branches).

**Any error is a failed check.** If a command below exits non-zero, prints an error, or prints a
warning on stderr (e.g. `refname ... is ambiguous`), treat that check as **failed** — never as
"empty output, safe". When in doubt, keep the branch.

**Skip the branch up front (don't attempt deletion) if any of these is true:**

- It is the default branch. Resolve it with
  `git -C <MAIN_WT> symbolic-ref --short refs/remotes/origin/HEAD` (gives e.g. `origin/main`;
  strip the `origin/` prefix). If that fails, try
  `cd <MAIN_WT> && gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`. Always
  treat `main` and `master` as default too.
- The user named it as a protected branch in Step 5.
- It is still checked out in another worktree. Check with
  `git -C <MAIN_WT> worktree list --porcelain | grep -Fx "branch refs/heads/<branch-name>"`.
- The user asked to keep it in Step 5.

**Record the tip SHA before touching the branch** (Step 8 reports it as the recovery handle —
once the worktree and branch are both gone, nothing else points at these commits):

```bash
git -C <MAIN_WT> rev-parse --verify refs/heads/<branch-name>
```

**Then try the safe delete:**

```bash
git -C <MAIN_WT> branch -d <branch-name>
```

`-d` deletes only if the branch is merged into its upstream (when that remote-tracking ref still
exists), otherwise into the main worktree's current `HEAD`. If it succeeds, you're done with this
branch.

**If `-d` refuses**, the branch is usually squash-merged or rebase-merged (so its commits aren't
ancestors of `main`) — but it could also have real local-only commits. Find out which before
going anywhere near `-D`. Run the checks below **only if `FETCH_OK = yes`** (Step 1). If the
fetch failed, remote-tracking refs may be stale: skip both checks and go straight to "neither
check passes".

Check 1 — every commit is on a remote. If **every** commit on the branch is reachable from some
remote-tracking ref, the command below prints **nothing**, and the commits are preserved:

```bash
git -C <MAIN_WT> log refs/heads/<branch-name> --not --remotes --oneline --
```

Empty output (and no error or warning) → safe to force-delete. Any output means some commits are
not on any remote; go to check 2.

Check 2 — a merged PR has exactly this tip. Only if `gh` is available:

```bash
cd <MAIN_WT> && gh repo view --json owner --jq .owner.login
cd <MAIN_WT> && gh pr list --head <branch-name> --state merged --limit 100 \
  --json number,url,state,headRefOid,headRepositoryOwner
```

Check 2 passes only if a PR in that list has **all** of:

- `state` is `MERGED`,
- `headRefOid` equal to the tip SHA you recorded above,
- `headRepositoryOwner.login` equal to the repo owner from the first command (`gh pr list --head`
  matches on branch *name* only, so a fork's PR with the same branch name can show up; ignore it).

Record that PR's number and URL for Step 8. If either `gh` command fails or errors, check 2
**fails** — do not read an error as "no match, carry on".

A `CLOSED` (unmerged) PR does **not** pass check 2: its commits survive only in GitHub's pull
ref, which a normal fetch never retrieves. Treat it as local-only work, and include the PR URL
when you ask the user.

If either check passes:

```bash
git -C <MAIN_WT> branch -D <branch-name>
```

If **neither** check passes (or the checks were skipped because the fetch failed), the branch may
have commits that exist only on this machine. Do NOT force-delete. Keep the branch, show the user
the output of `git -C <MAIN_WT> log refs/heads/<branch-name> --not --remotes --oneline --` (plus
any closed-PR URL you found), and ask whether they want it nuked. Only run `git branch -D` after an
explicit yes to **that** question — the Step 5 confirmation does not count.

### 8. Report results

Tell the user:

- which worktrees were deleted,
- which local branches were deleted, how (`-d`, verified `-D` via check 1, verified `-D` via
  check 2 with the PR number/URL, or `-D` after the user's explicit yes), and the tip SHA each
  one was at, e.g. `fix/bar was at 1a2b3c4 (restore with: git branch fix/bar 1a2b3c4)`,
- which branches were kept and why (default/protected branch, checked out elsewhere, user asked
  to keep, has local-only commits, fetch failed so preservation couldn't be verified),
- which worktrees were excluded (`current session`, or `possibly in use` and not named by the
  user),
- which worktrees (if any) were skipped due to errors.

---

## Safety rules

- **Never delete the main worktree.** Always skip the first entry from `git worktree list`.
- **Never delete the worktree you are running in** (`<CURRENT_WT>`), and never include a
  `possibly in use` worktree in a blanket "delete all" — only when the user names it.
- **Never use `--force` on `git worktree remove` without explicit user approval.**
- **Never delete a worktree with local-only commits** that haven't been pushed anywhere, unless
  the user explicitly says "yes, nuke it" after being warned about the data loss.
- **Never delete the default branch** (or any branch the user named as protected), and never
  delete a branch that is checked out in another worktree.
- **Never run `git branch -D` without proof** that the branch's commits are on the remote (Step 7
  check 1 or check 2) or an explicit yes from the user after showing them the local-only commits.
  The Step 5 "delete all" confirmation is not that yes.
- **Always inspect branches as `refs/heads/<branch-name>`**, and treat any error or warning from
  a Step 7 check as a failed check.
- **Always report the tip SHA of every deleted branch** so it can be restored.
- If `git fetch --prune` fails (e.g. no network), warn the user that condition 2 cannot be
  reliably evaluated and offer to proceed with condition 1 only. In that case, never force-delete
  a branch without the user's explicit yes (Step 7 checks are skipped).
