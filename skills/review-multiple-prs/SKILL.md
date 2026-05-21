---
name: review-multiple-prs
description: Review multiple pull requests in parallel by spinning up one review agent per PR, then consolidating findings into a single cross-PR summary. Use this when reviewing 2+ PRs that need to be understood together — stacked, parallel feature work, or a release batch.
disable-model-invocation: false
---

# Review Multiple PRs (Parallel)

Use this skill when the user provides 2 or more PR numbers or URLs to review. Unlike `/code-review` (which processes PRs sequentially), this skill fans out to parallel agents — one per PR — then merges their findings into a unified summary.

---

## Step 0 — Verify `gh` auth and repo access

1. Run `gh auth status`. If unauthenticated, stop and tell the user.
2. Resolve the repo identity: if PR URLs were provided, extract `owner/repo` from them. Otherwise run `gh repo view --json nameWithOwner -q .nameWithOwner` to get the repo from the current directory context. Store this as `{owner}/{repo}` — it is required for API calls in Step 5.
3. Run `gh repo view {owner}/{repo}` to confirm read access. If it fails, stop and tell the user.

## Step 1 — Identify and classify the PRs

- Collect all PR numbers / URLs from the user's message.
- If no PRs are specified, run the **PR Discovery** flow below before proceeding.
- If fewer than 2 PRs are provided (and discovery was not run), redirect the user to `/code-review` instead.

### PR Discovery (when no PRs are specified)

Use `gh` and the GitHub search API to find open PRs by the user's teammates that are awaiting review. Run these steps:

1. **Resolve the org:** extract the org from the `{owner}/{repo}` resolved in Step 0 (e.g. `ProjectAussie`).

2. **Find teammate usernames:** ask the user for a list of names or GitHub handles to search for. If they provide display names (e.g. "Claire", "Tom McT"), resolve them to GitHub logins by searching org members:
   ```
   gh api 'orgs/{org}/members' --paginate --jq '.[] | select(.login | test("{name}"; "i")) | .login'
   ```

3. **Find open PRs by those authors:**
   ```
   gh search prs --state open --author {login} --json number,title,url,author,repository --limit 20
   ```
   Run one search per author. Collect all results.

4. **Filter to actionable PRs only** — for each PR, fetch its review status and check whether the current user has already reviewed:

   a. Get the current user's login:
      ```
      gh api user --jq .login
      ```

   b. Get PR metadata:
      ```
      gh pr view <number> -R <owner/repo> --json reviewDecision,isDraft,reviewRequests
      ```

   c. Get the current user's most recent review on this PR (if any) and the latest commit date:
      ```
      gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '[.[] | select(.user.login == "{current_user}")] | sort_by(.submitted_at) | last | {state: .state, submitted_at: .submitted_at}'
      ```
      ```
      gh api repos/{owner}/{repo}/pulls/{number}/commits --jq 'last | .commit.committer.date'
      ```

   d. Keep only PRs where **all** of the following are true:
      - `isDraft: false`
      - `reviewDecision` is NOT excluded — include all values: `"REVIEW_REQUIRED"`, `""` (empty), `"APPROVED"`, and `"CHANGES_REQUESTED"` (someone else may have requested changes — you still need to review)

   e. **Skip PRs where the current user is already waiting on the author:**
      - If the current user's most recent review `state` is `CHANGES_REQUESTED`, AND
      - The latest commit on the PR is **older** than the review's `submitted_at` timestamp (meaning no new commits since the review)
      - Then **exclude** this PR — it's waiting on the author to push changes, not on you to re-review
      - If the author has pushed new commits after your CHANGES_REQUESTED review, **include** it — it needs a follow-up review

5. **Bucket by requester type** (reuse the current user's login from step 4a — do not fetch it again):**
   - **Your individual review:** PRs where `reviewRequests` contains the current user's login
   - **Team approval:** PRs with `REVIEW_REQUIRED` but no individual review request for you — these are waiting on a team

6. **Present the list to the user** grouped by author and bucket, with URLs. If any PRs were skipped because the current user is waiting on the author, list them separately:

   > **Skipped (waiting on author after your CHANGES_REQUESTED):**
   > - {owner}/{repo}#{number} — {title} — last reviewed {date}, no new commits since

   Then ask: "Should I review all of these, or select a subset? I can also include the skipped PRs if you want to re-review them."

7. Once the user confirms the set, continue with the normal Step 1 classification flow using those PRs.
- For each PR, run `gh pr view <number> --json number,title,state,isDraft,baseRefName,headRefName,createdAt` to get metadata.
- Determine the relationship between the PRs:

  | Relationship | Definition | Review strategy |
  |---|---|---|
  | **Stacked** | Each PR targets the previous PR's branch | Review in merge order; pass raw diff context forward |
  | **Parallel** | Multiple PRs for the same feature, split by concern | Review independently; flag integration risks |
  | **Batch / Unrelated** | Unrelated changes reviewed together (e.g. release batch) | Review fully independently |

- State your interpretation to the user and **wait for explicit confirmation before fanning out**. Do not proceed until the user confirms or corrects the relationship classification. A misclassified stacked set will silently skip context forwarding — this confirmation gate is not optional.

## Step 2 — Fan out: one agent per PR

Before fanning out, check if `.review-suppressed.md` exists in the current working directory. If it does, read it and pass its contents to each agent so they can skip previously suppressed findings.

Spin up one Agent per PR using `subagent_type: general-purpose`. Name each agent after a unique American outlaw from the 1800s–1900s (e.g. Jesse James, Belle Starr, Black Bart, Dutch Schultz, Pretty Boy Floyd, Billy the Kid, Bonnie Parker). Names must be unique per session — do not reuse a name even if reviewing many PRs.

Each agent receives a self-contained prompt with:

1. The PR number, repo (`{owner}/{repo}`), and `is_draft` flag.
2. Instructions to:
   - Fetch the diff: `gh pr diff <number>` — save this output; it is the authoritative source of changed lines for inline comment line numbers
   - Read the PR metadata and conversation comments: `gh pr view <number> --comments`
   - Fetch **formal review state** — this is critical, `--comments` does NOT include formal reviews:
     ```
     gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[] | {user: .user.login, state: .state, body: .body}'
     ```
     This returns `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`, or `PENDING` per reviewer. A `DISMISSED` review means a maintainer overrode it — note who dismissed and why.
   - Fetch **inline review thread comments** (these are separate from PR conversation comments):
     ```
     gh api repos/{owner}/{repo}/pulls/{number}/comments --jq '.[] | {user: .user.login, path: .path, line: .line, body: .body, created_at: .created_at}'
     ```
   - Read all of the above **before forming any verdict** — see the mandatory "Prior Discussion & Deferred Decisions" dimension in Step 3
   - Check CI: `gh pr checks <number>` — note that this only shows current run state; to assess whether failures are pre-existing, also run `gh pr checks <base-branch>` or `gh pr checks $(gh pr view <number> --json baseRefName -q .baseRefName)` for comparison. If base-branch checks are also failing, mark `ci_failures_introduced_by_pr: false`.
   - Read the linked Jira ticket via the Atlassian MCP if a ticket key is found in the branch name or PR description
   - Read surrounding code for any renamed functions, changed contracts, or modified public APIs
3. **For stacked PRs only:** the raw output of `gh pr diff <prior-number>` from the prior agent — passed verbatim, not summarized — so the agent understands what the prior layer changed and can attribute findings to the correct PR.
4. **Draft PR behavior:** if `is_draft: true`, the agent must still review and produce findings, but must set `verdict: "COMMENT"` unconditionally. It should post inline comments on Github (authors expect feedback on drafts) but the summary must clearly label the PR as a draft.
5. The review dimensions to evaluate (see Step 3 below)
6. The finding severity scale (see Step 4 below)
7. Instructions to **return findings as structured JSON** (see Output Contract below)

Run all agents in parallel (single message, multiple tool calls) **unless** the PRs are stacked — in that case, run them sequentially in merge order so each agent gets the prior layer's raw diff as context.

### Output Contract

Each agent must return a JSON object with exactly these fields:

```json
{
  "pr": 123,
  "title": "...",
  "verdict": "APPROVE",
  "is_draft": false,
  "ci_status": "passing",
  "ci_failures_introduced_by_pr": false,
  "stacked_context_diff": "<raw output of gh pr diff for this PR — included only for stacked PRs, to pass forward to the next agent>",
  "findings": [
    {
      "severity": "BLOCKER",
      "file": "path/to/file.ts",
      "line": 42,
      "body": "..."
    }
  ],
  "prior_discussions": [
    {
      "author": "<github username of the person who raised the concern>",
      "summary": "brief description of the prior comment or concern",
      "status": "accepted | unresolved | addressed_in_code",
      "original_severity": "BLOCKER | HIGH | MEDIUM | LOW | QUESTION",
      "file": "path/to/file.ts (optional — only if the concern was about a specific file)",
      "line": 42,
      "reasoning": "why this status was assigned — e.g. 'reviewer replied OK to defer' or 'no response from reviewer after author acknowledged'"
    }
  ],
  "summary": "2–4 sentence summary of what the PR does and overall quality"
}
```

Valid `verdict` values: `"APPROVE"`, `"REQUEST_CHANGES"`, `"COMMENT"`.

Valid `severity` values for findings: `"BLOCKER"`, `"HIGH"`, `"MEDIUM"`, `"LOW"`, `"QUESTION"`. Agents must never assign `IRRELEVANT` — that label is set exclusively by the human in the draft file.

**Line number constraint:** every finding with a `line` value must reference a line that actually appears in the diff output from `gh pr diff`. Do not invent or approximate line numbers — a line number not in the diff will cause the GitHub API to reject the comment with a 422 error.

**How to verify a line is in the diff:** Parse the `@@` hunk headers from `gh pr diff --color=never`. Each header has the form `@@ -old_start,old_count +new_start,new_count @@`. For each hunk, maintain a running `new_line` counter initialized to `new_start`. For each subsequent line in the hunk: if it starts with ` ` (context) or `+` (added), add `(path, new_line)` to the valid set and increment `new_line`; if it starts with `-` (deleted), skip it without incrementing (it has no RIGHT-side line number); if it starts with `\` (the `\ No newline at end of file` sentinel), skip it without incrementing. Reset the counter when a new `@@` header is seen. Binary files produce no hunk lines and therefore an empty valid-line set for that path — any finding referencing a binary file path will be correctly demoted to the review body. A finding is only valid if its `(path, line)` pair appears in this set. If you cannot confirm a line is in the diff, omit the `line` field entirely — it will land in the review body instead of as an inline comment.

## Step 3 — Review dimensions (per PR)

Each agent evaluates:

### Correctness
- Does the code do what the PR description says?
- Off-by-one errors, missing null checks, unhandled edge cases?
- Are error paths handled?

### Security
- OWASP Top 10: injection, broken auth, insecure deserialization, XSS, etc.
- Hardcoded secrets? Inputs validated at system boundaries?
- Least-privilege principle followed?

### Design & Simplicity
- Is the abstraction level appropriate?
- Unnecessary indirection or over-engineering?
- Could anything be deleted with no behavior change?

### Readability & Maintainability
- Clear variable and function names?
- Complex logic commented where intent isn't obvious?
- Dead code, debug artifacts, commented-out blocks left in?

### Test Coverage
- Tests for the new behavior?
- Do existing tests still make sense? Are mocks hiding real integration issues?
- Edge cases covered?

### Prior Discussion & Deferred Decisions

Agents **must** complete this section before forming a verdict. Omitting it is a review failure — populate the `prior_discussions` array in the Output Contract even if empty.

#### Data sources

Use **all three** data sources together — each one shows different things:

| Source | What it shows | Command |
|--------|--------------|---------|
| PR conversation comments | Top-level discussion | `gh pr view <number> --comments` |
| Formal review state | `APPROVED`, `CHANGES_REQUESTED`, `DISMISSED` per reviewer | `gh api repos/{owner}/{repo}/pulls/{number}/reviews` |
| Inline review thread comments | Line-level reviewer concerns | `gh api repos/{owner}/{repo}/pulls/{number}/comments` |

#### Identifying deferred or prior concerns

Scan **reviewer comment threads** (not PR description, not commit messages) for phrases that indicate deferral: "we'll fix this later", "out of scope for this PR", "follow-up ticket", "known issue", "accepted risk", or similar.

Do **not** treat the following as deferral signals:
- `TODO` comments in the code diff (those are code annotations, not reviewer deferrals)
- Language in the PR description or commit messages authored by the PR submitter (that's the author pre-framing, not a reviewer decision)
- Emoji reactions (thumbs-up, etc.) — these carry no formal semantic weight and must not be used to classify deferral status

#### Assigning severity to prior concerns

Prior reviewer comments do not use this skill's severity taxonomy. When a prior concern has no explicit severity, assign one based on impact:
- A concern about correctness, data loss, or security → `BLOCKER` or `HIGH`
- A concern about design, maintainability, or missing tests → `MEDIUM`
- A concern about style, naming, or minor cleanup → `LOW`

Document your severity assignment and reasoning in the `reasoning` field of the `prior_discussions` entry.

#### Status classification rules

| Status | Criteria |
|--------|----------|
| **accepted** | The **reviewer who raised the concern** (not the author) explicitly accepted the deferral — e.g., replied "OK to defer", "fine for now", submitted a new `APPROVED` review after discussion. Author acknowledgment alone is **not** sufficient. If the reviewer went silent after the author acknowledged, classify as `unresolved` — reviewer silence does not equal acceptance. |
| **addressed_in_code** | The concern was addressed by a code change. **You must verify this** — cross-reference the PR diff to confirm the fix is actually present. A comment saying "fixed" or "done" without a corresponding code change means the status is `unresolved`, not `addressed_in_code`. |
| **unresolved** | Anything else: no reply, author disputed it without reviewer resolution, reviewer went silent, or the formal review state is still `CHANGES_REQUESTED` and not `DISMISSED`. |

#### Formal review state handling

- If a reviewer's formal review state is `CHANGES_REQUESTED` and has **not** been `DISMISSED`: that review is still active. Check whether the specific concerns raised in that review have been addressed in code or accepted by the reviewer.
- If a review was `DISMISSED`: note who dismissed it (the reviewer themselves, or a maintainer). A maintainer-dismissed review without a replacement approval should still be surfaced as a prior discussion — it may indicate an override that the human reviewer should see.

#### Verdict interaction

- **Any single `unresolved` prior concern with `original_severity` of BLOCKER prevents an `APPROVE` verdict.** This is absolute.
- `unresolved` HIGHs should result in `REQUEST_CHANGES` unless you have strong evidence the concern is stale (e.g., the code it referenced no longer exists in the diff). If downgrading a stale concern, document why in the `reasoning` field.
- **Draft PR precedence:** if `is_draft: true`, the verdict remains `COMMENT` regardless of unresolved prior concerns. However, the prior discussions must still be surfaced and classified — the draft status overrides the verdict, not the analysis.

#### What to surface

Populate the `prior_discussions` array in the Output Contract for every prior concern found. Include a dedicated **"Prior Discussions"** subsection in the review output listing each item, its status, original severity, and your reasoning.

### Performance (only if relevant)
- Obvious N+1 queries, unnecessary loops, unindexed DB calls?
- Heavy computation in request paths?

## Step 4 — Finding severity scale

| Level | Meaning |
|---|---|
| **BLOCKER** | Must be fixed before merge. Correctness bug, security vuln, broken contract, CI failure introduced by this PR. |
| **HIGH** | Serious design or reliability issue. Should fix; discuss if deferring. |
| **MEDIUM** | Real improvement, not blocking. Author should address or explicitly accept risk. |
| **LOW / NIT** | Style, naming, minor cleanup. Don't block merge over these. |
| **QUESTION** | Unclear intent — ask before judging. |

Do not manufacture findings to look thorough. If the code is good, say so.

## Step 5 — Draft review file and get human approval

Before posting anything to GitHub, write a draft markdown file and present it to the user for review and editing.

### Write the draft file

Resolve the temp directory before writing:

```
TEMP_DIR=/tmp/<repo-name>/<branch-name>
```

- `<repo-name>` = `basename $(git rev-parse --show-toplevel)`
- `<branch-name>` = `git branch --show-current`

Create it if absent (`mkdir -p "$TEMP_DIR"`). Write all findings to `$TEMP_DIR/review-draft-{timestamp}.md` (e.g. `$TEMP_DIR/review-draft-2026-04-14T15-44.md`). This keeps the file outside the repo and prevents accidental commits. The file has two sections per PR: a **Changes Summary** and the **Proposed Comments**.

File format:

```markdown
# Review Draft — {date}

---

## {owner}/{repo}#{number} — {title}

**Author:** {login} | **CI:** passing / failing / pending

**Review Event:** `APPROVE` / `REQUEST_CHANGES` / `COMMENT` ← _edit this to control the formal GitHub review event submitted for this PR_

### Changes Summary

<3–6 sentence plain-English description of what the PR actually does — not the PR description copy-pasted, but your own read of the diff. What files changed, what behavior changed, what was added or removed.>

### Proposed Comments

#### Prior Discussions

| Author | Summary | Status | Orig. Severity | Reasoning |
|--------|---------|--------|---------------|-----------|
| @reviewer-login | brief description of concern | accepted / unresolved / addressed_in_code | BLOCKER / HIGH / MEDIUM / LOW | why this status was assigned |

#### Inline Comments

| File | Line | Severity | Comment |
|------|------|----------|---------|
| `path/to/file.ts` | 42 | BLOCKER | {your identity} says: ... |

---

## Cross-PR Summary (for human reviewer only — NOT posted to GitHub)

> **Relationship:** Stacked / Parallel / Batch
> **Overall:** ALL APPROVE / MIXED / ALL REQUEST_CHANGES
>
> | PR | Title | Review Event | Blockers | Highs |
> |----|-------|-------------|----------|-------|
> | #123 | ... | APPROVE | 0 | 1 |
> | #124 | ... | REQUEST_CHANGES | 1 | 0 |
>
> **Integration Concerns:** ...
```

Include every PR in the file, in order. Leave the cross-PR summary at the bottom.

### Present and wait for approval

Tell the user:

> "Draft written to `{full path to file in $TEMP_DIR}`. Open it, make any edits you want — remove findings, soften wording, add context. **The `Review Event` field on each PR controls the formal GitHub review action (APPROVE / REQUEST_CHANGES / COMMENT) — change it if you disagree with my recommendation.** To permanently suppress a finding so it is never raised again on this PR, change its severity to `IRRELEVANT` — I will skip posting it and record it in `.review-suppressed.md`. Tell me to post when ready, or say 'post as-is'."

**Do not proceed to Step 6 until the user explicitly says to post.** This gate is not optional — the whole point is to let the human adjust before anything hits GitHub.

### After approval

Re-read the (possibly edited) draft file before posting — use its content as the source of truth for what gets posted, not the original agent outputs. Then delete the draft file after posting completes.

## Step 6 — Post inline comments and submit review

After human approval, re-read the draft file. For each PR:

1. **Parse the `Review Event` field** from the draft file header. Valid values: `APPROVE`, `REQUEST_CHANGES`, `COMMENT`. The human may have changed this from the agent's original recommendation — **always use the value in the file, not the agent's original verdict.**

2. **Collect IRRELEVANT findings before posting.** Scan the draft file for any inline comment rows whose severity is `IRRELEVANT`. For each one:
   - Skip it — do not post it to GitHub.
   - Append a record to `.review-suppressed.md` (create if absent) in this format:
     ```
     {owner}/{repo}#{pr} | {file}:{line} | {comment summary} | suppressed {YYYY-MM-DD}
     ```
   This file is the persistence layer — future passes read it in Step 2 to avoid re-raising the same findings.

3. **Pre-validate line numbers before posting.** For each PR that has inline comments, fetch its diff and build the valid RIGHT-side line set. Apply the algorithm from the Output Contract's "How to verify a line is in the diff" section. The pseudocode below illustrates the logic — apply it when constructing the API payload, not as runnable code:

   ```python
   # PSEUDOCODE — apply this logic mentally when building the payload
   # gh pr diff <pr> -R <repo> --color=never
   valid = {}          # path → set of right-side line numbers
   current_path = None
   new_line = 0
   for raw in diff.splitlines():
       if raw matches r'^\+\+\+ b/(.+)':
           current_path = match.group(1)
           valid[current_path] = set()
           new_line = 0          # reset per file
       elif raw matches r'^@@ -\d+(?:,\d+)? \+(\d+)':
           new_line = int(match.group(1))   # reset per hunk
       elif current_path is None:
           continue
       elif raw starts with '+' or ' ':
           valid[current_path].add(new_line)
           new_line += 1
       elif raw starts with '-' or '\\':
           pass   # no right-side line number
   ```

   For each proposed inline comment, check if `(path, line)` is in the valid set:
   - **In the set** → include as an inline comment.
   - **Not in the set** → demote to the review body. Append a `### Comments that could not be posted inline` section (create it if it doesn't exist) and add a bullet:
     ```
     - **{file}:{line}** — {comment body}
     ```
   This eliminates 422 rejections entirely — no silent losses.

4. **Post inline comments with the review event** using `gh api`. Use `side: "RIGHT"` for all inline comments. Only post comments for lines confirmed in step 3. Use the content from the approved draft file — not the raw agent output. Skip any finding marked `IRRELEVANT`.

```
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST \
  --field body="" \
  --field event="{REVIEW_EVENT}" \
  --field "comments[][path]=path/to/file.ts" \
  --field "comments[][line]=42" \
  --field "comments[][side]=RIGHT" \
  --field "comments[][body]={your identity} says: <finding>"
```

Where `{REVIEW_EVENT}` is the value read from the draft file's `Review Event` field for that PR (`APPROVE`, `REQUEST_CHANGES`, or `COMMENT`).

5. **If a PR has no inline comments** (or all were demoted to body text) and the review event is `APPROVE` or `REQUEST_CHANGES`, submit the review without comments:

```
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST \
  --field body="Reviewed by {your identity}" \
  --field event="{REVIEW_EVENT}"
```

Post reviews for all PRs.

## Step 7 — Review event rules

The agent populates the `Review Event` field in the draft file as its **initial recommendation**. The human can override it before posting. These are the rules for the agent's initial recommendation:

- `APPROVE` — no BLOCKERs or HIGHs (including unresolved prior concerns with original severity BLOCKER or HIGH), CI passing (or failures pre-existing on base)
- `REQUEST_CHANGES` — one or more BLOCKERs or HIGHs introduced by this PR, OR one or more unresolved prior concerns with original severity BLOCKER or HIGH
- `COMMENT` — draft PR (overrides all other events — see below), questions only, or observations with no blocking concerns

**Draft PR precedence:** if `is_draft: true`, the review event is always `COMMENT` regardless of unresolved prior concerns. Prior discussions are still analyzed and surfaced in the output — the draft status overrides the event, not the analysis.

**Human override:** Whatever value the human leaves in the `Review Event` field when they approve the draft is what gets submitted to the GitHub API. The agent's recommendation is just a starting point.

## Step 8 — Notify the user

After posting all reviews:

- Report the per-PR review events submitted (APPROVE / REQUEST_CHANGES / COMMENT) and total finding counts.
- Present the cross-PR summary directly to the user in the conversation (it was already in the draft file; relay the key points).
- Call out any cross-PR integration concerns surfaced.
- If CI failures were introduced by any PR, name the PR and suggest `/resolve-ci-failures`.
- If any PRs have BLOCKERs or HIGHs, list the top concerns briefly.
- This skill covers one review pass. Re-invoke after the author pushes new commits.
