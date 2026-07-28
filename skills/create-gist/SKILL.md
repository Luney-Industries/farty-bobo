---
name: create-gist
description: Creates a GitHub Gist from content in the current conversation or a file. Secret by default; pass --public to make it public.
disable-model-invocation: false
model: sonnet
---

# Create Gist

## 0. Preflight check

Verify `gh` is available and authenticated:

```sh
gh auth status
```

Handle errors distinctly:
- If the command is **not found** (`command not found` or similar): stop and tell the human "Install the GitHub CLI first: https://cli.github.com"
- If `gh` is installed but **not authenticated**: stop and tell the human "Run `gh auth login` first, then try again."

Do not proceed until this check passes.

## 1. Gather content and options

Collect everything needed to build the gist — in order of priority:

- **File path passed as an argument** (e.g. `/create-gist fix.py`) — use the file directly; skip temp file creation
- **Other arguments or flags** (e.g. `/create-gist the snippet above --public`)
- **Content referenced in the conversation** — code blocks, error output, diffs

Parse the following options from the arguments or conversation:

| Option | Default | Meaning |
|--------|---------|---------|
| `--public` | off | Make the gist public instead of secret |
| `--desc <text>` | inferred | Gist description |
| `--filename <name>` | inferred | Override the filename shown in the gist |

If no content is identifiable, ask the human what to put in the gist before proceeding.

**Multi-file gists are out of scope.** If multiple files are referenced, ask the human to pick one.

## 2. Infer filename and description

**Filename**: All gist filenames MUST follow this convention:

```
{TICKET-ID}-{SUMMARY}.{EXTENSION}
```

- **TICKET-ID**: The ticket/issue ID from the conversation (e.g. `ENG-123`, `FB-42`). If no ticket ID is present, use `NO-TICKET`.
- **SUMMARY**: A short kebab-case summary of the content (e.g. `fix-auth-redirect`, `query-results`, `migration-output`). Max 5 words. No spaces.
- **EXTENSION**: Infer from the content type (`.py`, `.ts`, `.sql`, `.log`, `.md`, etc.). The extension matters — `gh` uses it for syntax highlighting.

If `--filename` was passed explicitly, use that value verbatim — but still warn the human if it doesn't match the convention.

Examples of valid filenames:
- `ENG-123-fix-auth-redirect.py`
- `FB-42-migration-output.log`
- `NO-TICKET-query-results.sql`

**Description**: Summarize the purpose in one short line. Pull from conversation context, the skill args, or the content itself. Keep it under 72 characters.

## 3. Determine visibility

- If `--public` was passed → public gist
- Otherwise → **secret gist** (default)

## 4. Draft and review

Present a summary to the human before creating anything:

```
File:        <filename>
Description: <description>
Visibility:  <secret or public>
Content:
---
<first ~20 lines or full content if short>
---
```

If the content contains secrets (API keys, tokens, passwords, private URLs) — flag them explicitly. Warn the human that **even secret gists are accessible to anyone with the URL**. Let them decide whether to proceed.

Ask for confirmation. Do not create the gist until the human says yes. If running non-interactively or if the human passed `--yes`, skip the confirmation prompt.

## 5. Create the gist

**IMPORTANT — `gh gist create`'s `--filename`/`-f` flag ONLY applies when reading from stdin (`-`). When you pass a file argument, `gh` names the gist after that file's own basename and silently ignores `--filename`.** This means you must NEVER hand `gh` a randomly-named temp file (e.g. `mktemp`'s default `gist-XXXXXX.ext`) — that random name is what ends up as the gist's filename. Always create the temp file (or copy the source file) under the exact `{TICKET-ID}-{SUMMARY}.{EXTENSION}` name computed in step 2, then pass that path with no `--filename` flag needed.

**If the source is a file on disk** whose name already matches the convention, pass it directly:

```sh
# Secret (default)
gh gist create --desc "<description>" <filepath>

# Public
gh gist create --public --desc "<description>" <filepath>
```

If the source file's name does NOT match the convention, copy it first to a correctly-named temp path (see below) rather than passing it as-is.

**If the source is content from the conversation, or a source file with the wrong name**, create a temp directory and write/copy the content into a file with the exact target name:

```sh
tmpdir=$(mktemp -d)
tmpfile="$tmpdir/<filename>"   # e.g. "$tmpdir/ENG-123-fix-auth-redirect.py"
# write or cp the content into "$tmpfile"
```

Then run:

```sh
# Secret (default)
gh gist create --desc "<description>" "$tmpfile"

# Public
gh gist create --public --desc "<description>" "$tmpfile"
```

After the gist is created (or if creation fails), **delete the temp directory immediately**:

```sh
rm -rf "$tmpdir"
```

## 6. Report back

Return:
- The gist URL
- The visibility (secret or public)
- The filename and description
- A one-liner on what was created
