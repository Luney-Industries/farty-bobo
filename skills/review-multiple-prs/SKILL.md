---
name: review-multiple-prs
description: Review one or more pull requests by spinning up one review agent per PR, then consolidating findings into a single cross-PR summary. Use this when reviewing 1+ PRs that need to be understood together — stacked, parallel feature work, or a release batch.
disable-model-invocation: false
---

# Review Multiple PRs (Parallel)

Use this skill when the user provides one or more PR numbers or URLs to review. Unlike `/code-review` (which processes PRs sequentially), this skill fans out to parallel agents — one per PR — then merges their findings into a unified summary.

---

## Step 0 — Verify `gh` auth and repo access

1. Run `gh auth status`. If unauthenticated, stop and tell the user.
2. Resolve the repo identity: if PR URLs were provided, extract `owner/repo` from them. Otherwise run `gh repo view --json nameWithOwner -q .nameWithOwner` to get the repo from the current directory context. Store this as `{owner}/{repo}` — it is required for API calls in Step 5.
3. Run `gh repo view {owner}/{repo}` to confirm read access. If it fails, stop and tell the user.

## Step 1 — Identify and classify the PRs

- Collect all PR numbers / URLs from the user's message.
- If no PRs are specified, run the **PR Discovery** flow below before proceeding.

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
- For each PR, run `gh pr view <number> --json number,title,state,isDraft,baseRefName,headRefName,createdAt,author` to get metadata. The `author` field (its `login`) is required by Step 5's draft template — fetch it here, once, rather than leaving it for an agent to improvise later.
- Determine the relationship between the PRs:

  | Relationship | Definition | Review strategy |
  |---|---|---|
  | **Stacked** | Each PR targets the previous PR's branch | Review in merge order; pass raw diff context forward |
  | **Parallel** | Multiple PRs for the same feature, split by concern | Review independently; flag integration risks |
  | **Batch / Unrelated** | Unrelated changes reviewed together (e.g. release batch) | Review fully independently |

- **If only one PR was provided**, skip the relationship classification entirely and proceed directly to Step 2.
- Otherwise, state your interpretation to the user and **wait for explicit confirmation before fanning out**. Do not proceed until the user confirms or corrects the relationship classification. A misclassified stacked set will silently skip context forwarding — this confirmation gate is not optional.

## Step 2 — Fan out: one agent per PR

Before fanning out, check if `.review-suppressed.md` exists in the current working directory. If it does, read it and pass its contents to each agent so they can skip previously suppressed findings.

**Resolve `$TEMP_DIR` here — this is its canonical resolution point for this skill.** Use the same commands shown in Step 5's "Write the draft file" section, then `mkdir -p -m 700 "$TEMP_DIR"`. Step 5 reuses this same directory; it does not re-resolve it.

**Resolve a `RUN_ID` for this invocation, exactly once, and persist it immediately:**

```sh
RUN_ID="$(date +%s)-$$"
printf '%s' "$RUN_ID" > "$TEMP_DIR/current-run-id"
```

(the trailing `$$` — the shell's own PID — is required, not decorative: `date +%s` alone has one-second resolution, and two people starting this skill on the same branch in the same second would otherwise collide). The `current-run-id` file exists because `RUN_ID` is otherwise conversation-only state, exactly the kind of thing this whole fix exists to stop relying on — if context gets compacted between Step 2 and a later step, re-deriving `RUN_ID` from scratch (`date +%s` again) produces a *different* value that matches nothing already on disk. Whenever `RUN_ID` is needed and isn't already in hand, read it from `$TEMP_DIR/current-run-id` rather than recomputing it. Never overwrite this file or recompute `RUN_ID` more than once per invocation.

Every output file this run writes is namespaced `agent-output-pr-{number}-{RUN_ID}.json` — never the bare `agent-output-pr-{number}.json`. This namespacing, not deletion, is what keeps stale results from a previous pass (this is a repeat-invocation skill — Step 8 expects re-runs after new commits) from silently passing validation, and it keeps two concurrent runs on the same branch from clobbering each other's output files. Old files from finished runs are removed by Step 8's cleanup step, not by deleting on sight here.

Resolve the **literal absolute path** for `$TEMP_DIR` (and compute `RUN_ID`) in your own context before building any agent prompt. A spawned agent has no access to your shell variables — if the prompt text contains `$TEMP_DIR` or `$RUN_ID` literally, the agent's own shell will expand them to empty and either fail to write or write to the wrong place. Every path handed to an agent below must already be the resolved absolute string with `RUN_ID` substituted in.

**Maintain the PR → validated-output-path mapping as a file, not only in conversation** — write `{TEMP_DIR}/run-manifest-{RUN_ID}.json` (a flat `{"123": "/abs/path/to/agent-output-pr-123-<RUN_ID>.json", ...}`). Every time an agent's output validates successfully (including after a retry supersedes an original — see "Handling agent failures" below), update it by **reading the current contents of the file, merging in the one new entry, and writing the whole object back** — never write a fresh object from memory of what you think it already contains; that silently drops every PR recorded in a turn you no longer have in context. The manifest, like the per-PR output files it points at, must survive context compaction — a mapping that exists only in conversation state reintroduces the exact problem this whole fix exists to solve, just one layer up. Step 5 reads this manifest rather than guessing filenames. If the manifest is ever missing when Step 5 needs it (e.g. compaction wiped the conversation and this file was somehow never written), first recover `RUN_ID` itself from `$TEMP_DIR/current-run-id` (do not recompute it — see above), then reconstruct the manifest by globbing `{TEMP_DIR}/agent-output-pr-*-{RUN_ID}*.json` and, for each PR number, preferring a `-retry1` match over the base path if both exist — do not re-dispatch agents whose valid output is already sitting on disk. Delete the manifest in Step 8's cleanup along with everything else.

Spin up one Agent per PR using `subagent_type: general-purpose`. Name each agent after a unique American outlaw from the 1800s–1900s (e.g. Jesse James, Belle Starr, Black Bart, Dutch Schultz, Pretty Boy Floyd, Billy the Kid, Bonnie Parker). Names must be unique per session — do not reuse a name even if reviewing many PRs.

Each agent receives a self-contained prompt with:

1. The PR number, repo (`{owner}/{repo}`), `is_draft` flag, and `author` login (all from Step 1's metadata fetch) — with an instruction to copy `author` verbatim into its JSON output rather than re-fetching or guessing it.
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
3. **For stacked PRs only:** fetch the prior layer's diff yourself — `gh pr diff <prior-number> > {TEMP_DIR}/diff-pr-<prior-number>-{RUN_ID}.txt` — before dispatching this agent, and pass it the absolute path to that file plus an instruction to read it for context on what the prior layer changed. Do not have the agent embed the diff inside its own JSON output: asking an LLM to hand-escape a multi-thousand-line diff as a JSON string is one of the most likely ways to produce malformed output, and the orchestrator can fetch this diff itself in one command with zero risk of a bad escape.
4. **Draft PR behavior:** if `is_draft: true`, the agent must still review and produce findings, but must set `verdict: "COMMENT"` unconditionally, and must **not** post anything to GitHub itself. All posting — draft or not — happens only in Step 6, after human approval of the draft file. The summary must clearly label the PR as a draft.
5. The review dimensions to evaluate (see Step 3 below)
6. The finding severity scale (see Step 4 below)
7. The **resolved absolute path** `{TEMP_DIR}/agent-output-pr-{number}-{RUN_ID}.json` (with `{TEMP_DIR}` and `{RUN_ID}` substituted for real values — never the literal strings `$TEMP_DIR` / `$RUN_ID`) and an instruction to write its full structured JSON there (see Output Contract below).
8. This verbatim closing instruction: "Once you have written the JSON to that file, your final message must be only the file path you wrote, plus the word DONE — nothing else. Do not repeat the JSON in your final message; the file is the only place it needs to exist."

Run all agents in parallel (single message, multiple Agent tool calls; this uses the default `run_in_background: true`) **unless** the PRs are stacked — in that case, run them sequentially in merge order with `run_in_background: false`, so each agent's prior-layer diff file (item 3 above) exists before the next one is dispatched.

**Wait for every dispatched agent's completion notification before evaluating any output file.** A background Agent call returning is dispatch, not completion — see the HARD GUARD pattern this repo already uses in `/critique`. Do not treat "some agents have reported, others haven't" as license to start Step 5's file check or to retry an agent that simply hasn't finished yet; retrying a still-running agent races it onto the same output file and can produce a torn or overwritten write. Track every dispatched agent by name and confirm completion for all of them (or a hung-agent determination per "Handling agent failures" below) before moving on.

**Artifact checkpoint (status note, not the draft):** once every dispatched agent (including retries) has validated successfully and `run-manifest-{RUN_ID}.json` has an entry for every PR, this fan-out — the most expensive, most interruption-prone part of the run — is complete but Step 5's draft is still minutes away. Publish `run-manifest-{RUN_ID}.json` itself as a Claude Artifact (`title: "PR review run manifest"`, `icon: "list"`, no `url` — this is a separate, shorter-lived artifact from the Step 5 draft backup below, not an update to it) so a reboot at this exact point at least leaves the human a record of which PRs were reviewed and where their validated output files were, even though the per-PR JSON findings themselves are not separately mirrored. Post the returned URL as a chat note only — do not post it to any PR, since it is superseded by the Step 5 draft-backup comment moments later. A failed publish here is logged and skipped, same as any other checkpoint.

### Output Contract

Each agent must return a JSON object with exactly these fields:

```json
{
  "pr": 123,
  "title": "...",
  "author": "github-login",
  "verdict": "APPROVE",
  "is_draft": false,
  "ci_status": "passing",
  "ci_failures_introduced_by_pr": false,
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
      "file": "path/to/file.ts (optional — only if the concern was about a specific file; fold into `summary` if present, since Step 5's Prior Discussions table has no File column and never renders this on its own — same treatment as `line` below)",
      "line": "42 (optional — fold into `summary` instead if omitted; Step 5's Prior Discussions table has no Line column, so this field is never rendered on its own)",
      "reasoning": "why this status was assigned — e.g. 'reviewer replied OK to defer' or 'no response from reviewer after author acknowledged'"
    }
  ],
  "summary": "2–4 sentence summary of what the PR does and overall quality"
}
```

Valid `verdict` values: `"APPROVE"`, `"REQUEST_CHANGES"`, `"COMMENT"`.

Valid `severity` values for findings: `"BLOCKER"`, `"HIGH"`, `"MEDIUM"`, `"LOW"`, `"QUESTION"`. Agents must never assign `IRRELEVANT` — that label is set exclusively by the human in the draft file.

**Markdown formatting in `body` fields:** When a comment body contains multiple points, questions, or items, use proper markdown list syntax — NOT inline numbering like `1) ... 2) ...`. Use actual newlines with `1.` / `2.` markers so GitHub renders them as a list. Inline `1) 2)` formatting renders as a single unbroken paragraph on GitHub.

**Line number constraint:** every finding with a `line` value must reference a line that actually appears in the diff output from `gh pr diff`. Do not invent or approximate line numbers — a line number not in the diff will cause the GitHub API to reject the comment with a 422 error.

**How to verify a line is in the diff:** Parse the `@@` hunk headers from `gh pr diff --color=never`. Each header has the form `@@ -old_start,old_count +new_start,new_count @@`. For each hunk, maintain a running `new_line` counter initialized to `new_start`. For each subsequent line in the hunk: if it starts with ` ` (context) or `+` (added), add `(path, new_line)` to the valid set and increment `new_line`; if it starts with `-` (deleted), skip it without incrementing (it has no RIGHT-side line number); if it starts with `\` (the `\ No newline at end of file` sentinel), skip it without incrementing. Reset the counter when a new `@@` header is seen. Binary files produce no hunk lines and therefore an empty valid-line set for that path — any finding referencing a binary file path will be correctly demoted to the review body. A finding is only valid if its `(path, line)` pair appears in this set. If you cannot confirm a line is in the diff, omit the `line` field entirely — it will land in the review body instead of as an inline comment.

### Handling agent failures

Each agent writes its full structured JSON to `{TEMP_DIR}/agent-output-pr-{number}-{RUN_ID}.json` and returns only a path-plus-DONE confirmation as its final message (Step 2, items 7–8). The file is the sole durable source of truth — Step 5 reads it, not the conversation. Only evaluate an output file after that specific agent has reported completion (see the wait instruction at the end of Step 2); a missing file at that point, or a file that fails validation below, is a failure and must be handled exactly like a parse failure. Do not rely on catching a result out of conversation context: context gets compacted, and completion notifications for a parallel batch of background agents can arrive out of order.

**Validate every agent's output file before using it** — presence of a parseable object alone is not enough:
- `pr` matches the PR number this agent was dispatched for, comparing numerically after stripping any non-digit characters (so `123`, `"123"`, and `"#123"` all match; a real mismatch means the agent reviewed the wrong PR or hallucinated the number)
- `verdict` is exactly one of `APPROVE` / `REQUEST_CHANGES` / `COMMENT`
- `title`, `author`, and `summary` are present and non-empty strings; `ci_status` is exactly one of `passing` / `failing` / `pending` (Step 5's draft file renders directly from these fields — a missing or out-of-vocabulary one forces the orchestrator to invent content, which is the exact failure this section exists to prevent)
- `is_draft` and `ci_failures_introduced_by_pr` are present and are booleans (`true`/`false`) — check type, not "non-empty"; `false` is a valid, common, and required value for both, and a non-empty check on a boolean will wrongly reject it
- `findings` is an array (empty is fine); every element has at least `severity` (one of `BLOCKER`/`HIGH`/`MEDIUM`/`LOW`/`QUESTION`) and `body`
- `prior_discussions` is an array and is present (per Step 3, an agent must populate this, even with zero entries — its absence is itself a review failure, not just a formatting one); every element has `author`, `summary`, `status` (one of `accepted`/`unresolved`/`addressed_in_code`), and `original_severity` (one of `BLOCKER`/`HIGH`/`MEDIUM`/`LOW`/`QUESTION`) — `status` and `original_severity` specifically gate the "absolute" verdict rule in Step 3, so a missing one would silently defeat it
- no finding, and no `prior_discussions` entry, has `severity`/`original_severity` of `"IRRELEVANT"` — that value is human-only (see above); an agent assigning it is invalid output, not a suppression to honor silently

**Detecting a hung original dispatch (parallel, background agents only):** record the wall-clock time at dispatch by appending a line to `$TEMP_DIR/dispatch-times-{RUN_ID}.txt` (`echo "{pr-number} $(date +%s)" >> ...`) rather than only noting it in conversation — the same compaction risk that motivated `current-run-id` applies here. On any later turn where a given agent still hasn't reported completion, run `date +%s` again and compare against that PR's recorded dispatch time; once the difference exceeds 600 seconds, treat it as hung and proceed to step 2 below. This clock-based check only applies to agents dispatched with `run_in_background: true` — it is meaningless for a stacked PR's sequential (foreground) original dispatch or for any retry (both always use `run_in_background: false`, item below): a foreground `Agent` call blocks the current turn until it returns, so there is no "later turn" on which to re-check the clock. For those, a failure to return is a harness-level condition outside this skill's control, not something this skill's clock check can detect — if a foreground call never returns, there is no later step to reach. Delete `dispatch-times-{RUN_ID}.txt` in Step 8's cleanup along with everything else.

**On any validation failure** (missing file, empty/truncated content, parse failure, or a check above failing) — including on the hung-original determination above:

1. **Check whether the automatic retry has already been spent for this PR.** If `{TEMP_DIR}/agent-output-pr-{number}-{RUN_ID}-retry1.json` already exists (or an agent is already dispatched to write it), the one automatic retry below has already happened — attempt salvage on that retry file (step 2 below) and, if that fails, go straight to step 4; do not dispatch a second automatic retry (do not re-enter step 3).
2. **Attempt salvage first**, but only if a file exists to salvage — skip this step entirely for a missing/never-written file and go straight to the retry below. Strip a leading/trailing code fence (` ```json ` / ` ``` `) or extract the outermost balanced `{...}` substring from the file's contents, then re-validate against the checks above. If salvage succeeds, **overwrite the output file with the salvaged, valid JSON** before continuing — Step 5 reads the file, not whatever you fixed only in your own context, so a repair that isn't written back is invisible downstream. A stray fence around otherwise-valid JSON is the most likely deviation — don't burn a full re-review over a cosmetic wrapper.
3. If salvage doesn't produce valid output (or wasn't applicable), retry that one agent — this is the one automatic retry step 1 checks for. Never fall back to reviewing the PR yourself — that isn't a substitute for the agent's structured process and defeats the point of fanning out. Retry with:
   - The same self-contained prompt as the original dispatch, **except item 7's output path is replaced** with the new path below (do not leave the original path in the prompt alongside the new one — the agent must be told exactly one place to write, never two); for stacked PRs, keep the same prior-layer diff file path from Step 2 item 3 and do not re-fetch it
   - The new output path: `{TEMP_DIR}/agent-output-pr-{number}-{RUN_ID}-retry1.json` — never reuse the original agent's path, so a slow-finishing original can never race a retry onto the same file
   - One appended line: "Your previous attempt failed validation ({name the failed check}) — write your full JSON to {new output path} (not the path mentioned earlier in this prompt) and return only that path plus DONE as your final message."
   - A **new, unique** outlaw name (retries are new spawns; Step 2's uniqueness rule still applies)
   - `run_in_background: false`, so the result is inspected the moment it lands
   - **Update the run manifest (Step 2)** to point this PR at the new path the moment it validates successfully — the original path is superseded, and nothing downstream should ever look for it again
4. If the retry also fails validation, stop — per step 1, there is no second automatic retry — and tell the user which PR's agent failed twice and exactly why (empty output, parse failure, hang, or the specific failed field).
   - **Non-stacked PR:** offer to retry again (a new, human-approved attempt — repeat this same procedure with a `-retry2` path if the human says yes), skip that PR, or investigate directly.
   - **Stacked PR:** a failure halts the chain — every PR after this one depends on the prior layer's diff file and cannot be dispatched. "Skip that PR" is not valid here; offer only retry-again or investigate, and tell the user the downstream PRs in the stack are blocked until this one resolves.

Do not proceed to Step 5 with a fabricated or self-authored substitute for any PR's findings.

Because draft-PR agents never post to GitHub themselves (Step 2, item 4 — all posting happens in Step 6 after human approval), retrying a draft PR's agent carries no risk of duplicate GitHub comments.

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

Reuse the `$TEMP_DIR` already resolved and created in Step 2 — do not re-derive it here. (If this step is somehow entered without having run Step 2 in this session, resolve it now using the commands shown below, treating that as a recovery path rather than the normal one.)

Before doing anything else in this step: if `RUN_ID` isn't already in hand, read it from `$TEMP_DIR/current-run-id` — do not recompute it (see Step 2). Then read `{TEMP_DIR}/run-manifest-{RUN_ID}.json` (written and maintained during Step 2) and confirm it has one entry for every PR under review — read each PR's JSON from the path recorded there, not from a filename guessed here (a retried PR's validated file lives at a `-retry1` path, not the original). If the manifest is missing, reconstruct it per Step 2's recovery instruction rather than drafting from memory of a conversation result. If any PR still has no entry after that, stop and resolve it in Step 2 first.

Before posting anything to GitHub, write a draft markdown file and present it to the user for review and editing.

### Write the draft file

For reference, `$TEMP_DIR` follows this shape:

```
TEMP_DIR=/tmp/<repo-name>/<branch-name>
```

Resolve them with exactly these commands — one code path, correct both inside and outside a worktree:

```sh
repo_name=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")")
branch_name=$(git branch --show-current)
# Detached HEAD returns an empty branch name.
[ -n "$branch_name" ] || branch_name="detached-$(git rev-parse --short HEAD)"
TEMP_DIR="/tmp/$repo_name/$branch_name"
```

**Do not use `git rev-parse --show-toplevel`** (returns the worktree path, not the main repo root) **and do not use `git rev-parse --git-common-dir | xargs dirname`** — outside a worktree that yields `.`, so `TEMP_DIR` silently becomes `/tmp/./<branch-name>` and the repo-name namespacing is lost with no error.

Create it if absent (`mkdir -p -m 700 "$TEMP_DIR"`). Branch names contain slashes, so `$TEMP_DIR` is a nested path — `mkdir -p` is required, not optional. Write all findings to `$TEMP_DIR/review-draft-{timestamp}.md` (e.g. `$TEMP_DIR/review-draft-2026-04-14T15-44.md`). This keeps the file outside the repo and prevents accidental commits. The file has two sections per PR: a **Changes Summary** and the **Proposed Comments**.

File format:

```markdown
# Review Draft — {date}

---

## {owner}/{repo}#{number} — {title}

**Author:** {login} | **CI:** passing / failing / pending{, introduced by this PR: yes/no — only append this clause when CI is failing}

**Review Event:** `APPROVE` / `REQUEST_CHANGES` / `COMMENT` ← _edit this to control the formal GitHub review event submitted for this PR_

### Changes Summary

<3–6 sentence plain-English description of what the PR actually does — not the PR description copy-pasted, but your own read of the diff. What files changed, what behavior changed, what was added or removed.>

### Proposed Comments

#### Prior Discussions

| Author | Summary | Status | Orig. Severity | Reasoning |
|--------|---------|--------|---------------|-----------|
| @reviewer-login | brief description of concern | accepted / unresolved / addressed_in_code | BLOCKER / HIGH / MEDIUM / LOW / QUESTION | why this status was assigned |

#### Inline Comments

| File | Line | Severity | Comment |
|------|------|----------|---------|
| `path/to/file.ts` | 42 | BLOCKER | {your identity} says: ... |

#### Body Comments (no confirmed diff line — will post to the review body, not inline)

| File | Severity | Comment |
|------|----------|---------|
| `path/to/file.ts` | MEDIUM | {your identity} says: ... |

Only present this subsection if at least one finding omitted `line` per the Output Contract's line-number constraint. Do not force a line-less finding into the Inline Comments table with a blank Line cell.

---

## Summary (for human reviewer only — NOT posted to GitHub)

> **Overall:** APPROVE / REQUEST_CHANGES / COMMENT
>
> | PR | Title | Review Event | Blockers | Highs |
> |----|-------|-------------|----------|-------|
> | #123 | ... | APPROVE | 0 | 1 |
>
> **Relationship:** Stacked / Parallel / Batch  ← _omit this line when reviewing a single PR_
>
> **Integration Concerns:** ...  ← _omit this line when reviewing a single PR_
```

Include every PR in the file, in order. Leave the summary at the bottom. **When reviewing a single PR, omit the Relationship and Integration Concerns lines — they are meaningless without multiple PRs.**

**Artifact checkpoint:** `$TEMP_DIR` remains the live working contract for this skill — nothing downstream ever reads from an Artifact. This mirror exists only as a human safety net, since the draft file is deleted after posting (see "After approval" below) and would otherwise be unrecoverable past that point or after a reboot.

Scrub the draft file for obvious secrets before publishing (same discipline as never committing secrets — a review draft can quote code containing a hardcoded credential a reviewer flagged). Load the `artifact-design` skill before the first publish call of this run (required by the `Artifact` tool even for a `.md` file a skill instructs it to write) — this is a plain data mirror, not a designed page, so skip any visual design pass but still load the skill so the call is well-formed.

Publish `$TEMP_DIR/review-draft-{timestamp}.md` as a Claude Artifact: `Artifact({action: "publish", file_path: <draft file path>, title: "PR review draft", icon: "clipboard"})` with no `url` (there is exactly one Step 5 draft per run — Step 5 is entered once, so there is no later "re-generated" case to handle). Take the returned URL and post it as a comment containing the literal marker text `Review draft backup: {url}` — on the **lowest-numbered PR only** (`gh pr comment <lowest-number> -R {owner}/{repo} --body "Review draft backup: {url} — covers this and the other PRs in the same batch: {list of other PR numbers}."`), not on every PR in the batch, to avoid spamming near-identical comments across a large release batch. **If the comment post fails**, surface it to the human in chat immediately — unlike a failed `Artifact` publish, the comment is the only other place the URL would be discoverable later. A failed `Artifact` publish itself is logged and skipped — never a blocker.

### Present and wait for approval

Tell the user:

> "Draft written to `{full path to file in $TEMP_DIR}`. Open it, make any edits you want — remove findings, soften wording, add context. **The `Review Event` field on each PR controls the formal GitHub review action (APPROVE / REQUEST_CHANGES / COMMENT) — change it if you disagree with my recommendation.** To permanently suppress a finding so it is never raised again on this PR, change its severity to `IRRELEVANT` — I will skip posting it and record it in `.review-suppressed.md`. Tell me to post when ready, or say 'post as-is'."

**Do not proceed to Step 6 until the user explicitly says to post.** This gate is not optional — the whole point is to let the human adjust before anything hits GitHub.

### After approval

Re-read the (possibly edited) draft file before posting — use its content as the source of truth for what gets posted, not the original agent outputs. Then delete the draft file after posting completes.

## Step 6 — Post inline comments and submit review

After human approval, re-read the draft file. For each PR:

1. **Parse the `Review Event` field** from the draft file header. Valid values: `APPROVE`, `REQUEST_CHANGES`, `COMMENT`. The human may have changed this from the agent's original recommendation — **always use the value in the file, not the agent's original verdict.**

2. **Collect IRRELEVANT findings before posting.** Scan the draft file for any row — in the Inline Comments table, the Body Comments table, or the Prior Discussions table — whose severity (or `Orig. Severity` for Prior Discussions) is `IRRELEVANT`. For each one:
   - Skip it — do not post it to GitHub.
   - Append a record to `.review-suppressed.md` (create if absent) in this format: for a Body Comments row, use `-` for `{line}` (it has no line number, but does have `{file}`); for a Prior Discussions row, use `-` for **both** `{file}` and `{line}` — that table has neither column, and any file/line context that existed is already folded into its Summary text, not separately available to quote here:
     ```
     {owner}/{repo}#{pr} | {file}:{line} | {comment summary} | suppressed {YYYY-MM-DD}
     ```
   This file is the persistence layer — future passes read it in Step 2 to avoid re-raising the same findings.

3. **Assemble the review body from the Body Comments table.** Every row in Step 5's "Body Comments" subsection **that isn't marked `IRRELEVANT`** (findings the agent deliberately left without a `line` because it couldn't confirm one against the diff) must end up in the posted review body — never dropped, but an `IRRELEVANT` row from item 2 is still skipped here, not posted. Start building a `### Additional Comments` section from these rows now, as bullets in the form `- **{file}** — {comment body}` — this table has no `line` column by construction, so do not invent one. Item 4 below adds more bullets to this same section, in the *different* form `- **{file}:{line}** — {comment body}` (those rows do have a confirmed line), for any inline comment that fails line validation; the merged result is used when posting in items 5–6.

4. **Pre-validate line numbers before posting.** For each PR that has inline comments, fetch its diff and build the valid RIGHT-side line set. Apply the algorithm from the Output Contract's "How to verify a line is in the diff" section. The pseudocode below illustrates the logic — apply it when constructing the API payload, not as runnable code:

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
   - **Not in the set** → demote to the review body. Add it to the same `### Additional Comments` section started in item 3, as a bullet:
     ```
     - **{file}:{line}** — {comment body}
     ```
   This eliminates 422 rejections entirely — no silent losses, and folds in with the Body Comments rows from item 3 so both land in one place.

5. **Post inline comments with the review event** using `gh api`. Use `side: "RIGHT"` for all inline comments. Only post comments for lines confirmed in step 4. Use the content from the approved draft file — not the raw agent output. Skip any finding marked `IRRELEVANT`. Set `body` per the rule in item 6 below (GitHub rejects a `COMMENT`-event review with an empty body, so this applies here too, not only to the no-inline-comments case).

```
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST \
  --field body="{body per item 6's rule}" \
  --field event="{REVIEW_EVENT}" \
  --field "comments[][path]=path/to/file.ts" \
  --field "comments[][line]=42" \
  --field "comments[][side]=RIGHT" \
  --field "comments[][body]={your identity} says: <finding>"
```

Where `{REVIEW_EVENT}` is the value read from the draft file's `Review Event` field for that PR (`APPROVE`, `REQUEST_CHANGES`, or `COMMENT`).

6. **Every PR gets a posted review, regardless of event or whether it has inline comments** — there is no case where nothing gets submitted. If there are no inline comments (all findings had a confirmed line, and `### Additional Comments` is empty), submit the review without inline comments:

```
gh api repos/{owner}/{repo}/pulls/{number}/reviews \
  --method POST \
  --field body="{body per the rule below}" \
  --field event="{REVIEW_EVENT}"
```

**Body rule (applies to both items 5 and 6):** if `### Additional Comments` has any bullets, use it as the body. If it's empty, use `"Reviewed by {your identity}"` — never post an empty `body`; GitHub rejects `event=COMMENT` with a blank body, and a clean draft PR (Step 2 item 4 forces `verdict: "COMMENT"` unconditionally, per Step 7) is exactly the case most likely to have zero inline comments and an empty `### Additional Comments` section, so this isn't an edge case to skip.

Post reviews for all PRs.

## Step 7 — Review event rules

The agent populates the `Review Event` field in the draft file as its **initial recommendation**. The human can override it before posting. These are the rules for the agent's initial recommendation:

- `APPROVE` — no BLOCKERs or HIGHs (including unresolved prior concerns with original severity BLOCKER or HIGH), CI passing (or failures pre-existing on base)
- `REQUEST_CHANGES` — one or more BLOCKERs or HIGHs introduced by this PR, OR one or more unresolved prior concerns with original severity BLOCKER or HIGH (subject to Step 3's stale-concern downgrade carve-out for HIGHs — a HIGH demonstrably stale and documented as such in `reasoning` does not by itself force this event)
- `COMMENT` — draft PR (overrides all other events — see below), questions only, or observations with no blocking concerns

**Draft PR precedence:** if `is_draft: true`, the review event is always `COMMENT` regardless of unresolved prior concerns. Prior discussions are still analyzed and surfaced in the output — the draft status overrides the event, not the analysis.

**Human override:** Whatever value the human leaves in the `Review Event` field when they approve the draft is what gets submitted to the GitHub API. The agent's recommendation is just a starting point.

## Step 8 — Notify the user

After posting all reviews:

- Report the per-PR review events submitted (APPROVE / REQUEST_CHANGES / COMMENT) and total finding counts.
- Present the cross-PR summary directly to the user in the conversation (it was already in the draft file; relay the key points).
- If multiple PRs were reviewed, call out any cross-PR integration concerns surfaced.
- If CI failures were introduced by any PR, name the PR and suggest `/resolve-ci-failures`.
- If any PRs have BLOCKERs or HIGHs, list the top concerns briefly.
- **Clean up this run's agent output files:** delete every `agent-output-pr-*-{RUN_ID}*.json` (the `*` after `{RUN_ID}` is required — it is what matches `-retry1`, `-retry2`, etc.), `run-manifest-{RUN_ID}.json`, `dispatch-times-{RUN_ID}.txt`, `diff-pr-*-{RUN_ID}.txt`, and finally `current-run-id` from `$TEMP_DIR` — this `RUN_ID` namespacing (Step 2) means it's always safe to delete everything matching this run's ID without touching another run's files. This is the one point every run passes through on the happy path. If the run is instead abandoned partway through (e.g. the user chose to stop after a repeated agent failure), run the same cleanup for this `RUN_ID` before ending the session's work on this review.
- This skill covers one review pass. Re-invoke after the author pushes new commits.
