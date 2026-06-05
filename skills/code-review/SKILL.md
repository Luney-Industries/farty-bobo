---
name: code-review
description: Code review a pull request or a set of related PRs created by someone else. Reads diffs, comments inline, and posts a consolidated review summary.
disable-model-invocation: false
---

# PR Code Review Skill

Use this skill when asked to review one or more pull requests. It covers reading diffs, forming opinions, and posting structured feedback.

---

## Step 0 — Verify `gh` auth

Run `gh auth status`. If unauthenticated, tell the user and stop — do not attempt to read diffs or post comments without it.

## Step 1 — Identify the PR(s)

- If the user provides one or more PR numbers or URLs, use those directly.
- If no PR is specified, ask the user: "Which PR(s) should I review? (number, URL, or branch name)"
- If a PR is in **draft** state, note it. Default the verdict to `COMMENT` — do not APPROVE or REQUEST_CHANGES a draft.
- If multiple PRs are provided, determine the relationship before proceeding:
  - **Stacked PRs** (each targets the previous branch): review them in order, treating each diff as a layer on top of the previous. Note cross-PR issues explicitly.
  - **Parallel PRs** (same feature, split by concern): review each independently, then write a combined summary that calls out any integration concerns.
  - **Unrelated PRs**: review each fully and independently. Produce a separate summary per PR.
  State your interpretation to the user before proceeding.

## Step 2 — Gather context

For each PR:

1. Fetch the PR metadata: title, description, linked Jira ticket (if any), target branch.
2. Read the full diff using `gh pr diff <number>`.
3. For any function renamed, contract changed, or public API modified: use `grep`/`Glob` to find callers and read them. Diffs lack context — read the surrounding code.
4. Read the PR conversation/comments using `gh pr view <number> --comments` to understand what has already been discussed. Do not re-raise issues already resolved in thread.
5. If a Jira ticket is linked, use the Atlassian MCP connector to read the ticket description and acceptance criteria. If no ticket, no description, and no branch naming convention reveals intent — flag this as a process finding in the review.
6. Check CI status with `gh pr checks <number>`. If checks are failing, determine whether the failure is pre-existing on the base branch or introduced by this PR. Failures introduced by this PR are at minimum a HIGH finding; test suite failures are a BLOCKER.

## Step 3 — Understand intent before judging

Before forming opinions:

- Re-read the PR description and any linked ticket. Understand *what* the author was trying to accomplish and *why*.
- Identify the core change (the essential logic) vs. scaffolding (plumbing, tests, config).
- Do not speculate about intent. If a behavior could be intentional or a bug, use a QUESTION finding to ask before calling it wrong.

## Step 4 — Review the diff

Evaluate the code across these dimensions:

### Correctness
- Does the code do what the PR description says it does?
- Are there off-by-one errors, missing null checks, or edge cases not handled?
- Does it handle error paths?

### Security
- Check for OWASP Top 10 issues: injection, broken auth, insecure deserialization, XSS, etc.
- Are secrets hardcoded? Are inputs validated at system boundaries?
- Does the code follow least-privilege principles?

### Design & Simplicity
- Is the abstraction level appropriate? Watch for over-engineering and premature abstraction.
- Are there unnecessary layers of indirection?
- Could any part be deleted and the behavior remain the same?

### Readability & Maintainability
- Are variable and function names clear?
- Is complex logic commented where the intent isn't obvious?
- Is there dead code, commented-out blocks, or debug artifacts left in?

### Test Coverage
- Are there tests for the new behavior?
- Do existing tests still make sense? Are mocks hiding real integration issues?
- Are edge cases covered?

### Performance (flag only if relevant)
- Are there obvious N+1 queries, unnecessary loops, or unindexed DB calls?
- Are large payloads or heavy computations done in request paths?

## Step 5 — Classify findings

Assign each finding a severity:

| Level | Meaning |
|-------|---------|
| **BLOCKER** | Must be fixed before merge. Correctness bug, security vuln, broken contract, or CI failure introduced by this PR. |
| **HIGH** | Serious design or reliability issue. Should be fixed; needs discussion if deferred. |
| **MEDIUM** | Real improvement but not blocking. Author should address or explicitly accept the risk. |
| **LOW / NIT** | Style, naming, minor cleanup. Optional. Don't block merge over these. |
| **QUESTION** | Unclear intent — ask for clarification before judging. |

Do not manufacture findings to look thorough. If the code is good, say so.

### Human Override Labels

These are set by the human on existing findings — the agent never assigns them to new findings.

| Label | Meaning |
|-------|---------|
| **IRRELEVANT** | The human changed a finding's severity to `IRRELEVANT` in the draft review file. The agent must skip posting this comment and must not re-raise it in future review passes of the same PR. The `review-multiple-prs` skill persists these to `.review-suppressed.md`. |

## Step 6 — Post the review

### Inline comments

True inline comments (anchored to a file and line) require either:
- The **GitHub MCP** if available — use it to post line-level review comments.
- Or `gh api` directly:
  ```
  gh api repos/{owner}/{repo}/pulls/{number}/reviews \
    --method POST \
    --field body="" \
    --field event="COMMENT" \
    --field "comments[][path]=path/to/file.ts" \
    --field "comments[][line]=42" \
    --field "comments[][body]={your identity} says: <finding>"
  ```

Each inline comment body must open with **"{your identity} says:"** (using your identity from CLAUDE.md) so the author knows who left it.

If neither the GitHub MCP nor `gh api` inline posting is feasible, fall back to referencing `file.ts:42` inline in the consolidated summary instead — do not post top-level comment blobs pretending they are inline.

### Consolidated summary

After inline comments, post a single top-level PR comment with this format:

```
## {your identity}'s Code Review

**Verdict:** APPROVE / REQUEST_CHANGES / COMMENT

### Summary
<2–4 sentences: what the PR does, overall quality, biggest concern if any>

### Findings

#### BLOCKER
- `path/to/file.ts:42` — <finding>

#### What's Good
- <something done well>

---
_Reviewed by {your identity}_
```

Only include sections that have entries. Omit empty sections entirely. The template above shows two sections as an example — do not copy-paste all section headers when they are empty.

### Verdict rules

- `APPROVE` — no BLOCKERs or HIGHs, CI passing (or failures pre-existing on base), ready to merge.
- `REQUEST_CHANGES` — one or more BLOCKERs or HIGHs introduced by this PR.
- `COMMENT` — draft PR, questions only, or observations with no blocking concerns.

## Step 7 — Notify the user

After posting:

- Tell the user the verdict and how many findings were posted.
- If there are BLOCKERs or HIGHs, summarize the top concerns briefly.
- If CI failures were introduced by this PR, tell the user and suggest `/resolve-ci-failures`.
- This skill covers one review pass. If the author pushes changes, the user should invoke this skill again.
