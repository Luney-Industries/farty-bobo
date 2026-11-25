---
name: install
description: >
  Selectively install skills, hooks, and commands from the Farty Bobo config repo
  (fartybobo/farty-bobo) onto this machine — without forking or cloning the whole repo.
  Trigger on: "install farty bobo", "install skills from farty bobo", "get the farty bobo skills",
  "install hooks", "install commands from config repo".
model: sonnet
---

# Farty Bobo Installer

Fetch the live catalog from `fartybobo/farty-bobo`, let the user pick what they want,
and install it to the right places on this machine.

## 1. Fetch the catalog

Run all three in parallel:

```bash
# Skills (folders only; "_"-prefixed folders are shared support code, not skills)
gh api "repos/fartybobo/farty-bobo/contents/skills" \
  --jq '[.[] | select(.type == "dir" and (.name | startswith("_") | not)) | .name]'

# Hooks (.sh files only)
gh api "repos/fartybobo/farty-bobo/contents/hooks" \
  --jq '[.[] | select(.name | endswith(".sh")) | .name]'

# Commands
gh api "repos/fartybobo/farty-bobo/contents/commands" --jq '.[].name'
```

For each skill, fetch its description from the frontmatter:
```bash
gh api "repos/fartybobo/farty-bobo/contents/skills/<name>/SKILL.md" \
  --jq '.content' | base64 -d | head -6
```

For each hook, fetch its purpose from the file header:
```bash
gh api "repos/fartybobo/farty-bobo/contents/hooks/<name>" \
  --jq '.content' | base64 -d | head -5
```

Fetch all descriptions in parallel — do not loop sequentially.

## 2. Present the menu

Display a categorized list:

```
Available from fartybobo/farty-bobo:

SKILLS
  • <name> — <description from frontmatter>
  ...

HOOKS
  • <name> — <purpose from header comment>
  ...

COMMANDS
  • <name>
  ...
```

Ask the user:
> "Which would you like to install? Type 'all', a category name (skills / hooks / commands), or a space-separated list of names."

Parse the response. If ambiguous, ask for clarification.

## 3. Download selected items

### Skills

**Pin one commit.** Resolve the default branch's commit once, and use that SHA for every call
below, so the file list and the file contents come from the same commit:
```bash
SHA=$(gh api "repos/fartybobo/farty-bobo/commits/HEAD" --jq '.sha')
```

**List every file once.** Skills can have subfolders (e.g. `scripts/`), so list the whole repo
tree in one call, and keep each file's path and mode:
```bash
gh api "repos/fartybobo/farty-bobo/git/trees/$SHA?recursive=1" \
  --jq '{truncated, files: [.tree[] | select(.type == "blob") | {path, mode}]}'
```
If `truncated` is `true`, stop and tell the user: "The repo tree is too big to list in one call.
Nothing was installed." Never install from a partial list.

Make that call once and filter it for every selected skill (`path` starts with `skills/<name>/`).
Don't call it once per skill.

**Ask before touching an existing skill.** Before downloading anything for a skill, check whether
`~/.claude/skills/<name>/` exists. If it does, ask the user:
"~/.claude/skills/<name>/ already exists — overwrite, skip, or merge?"

- **overwrite:** download every file of the skill, replacing local copies.
- **skip:** download nothing for this skill.
- **merge:** download only the files that don't exist locally. Leave existing files as they are.

**Download.** For each file to download, save it to the same relative path under `~/.claude/`.
Create parent folders first. Make the file executable only if its tree `mode` is `100755`:
```bash
mkdir -p "$(dirname ~/.claude/<path>)"
gh api -H "Accept: application/vnd.github.raw" \
  "repos/fartybobo/farty-bobo/contents/<path>?ref=$SHA" > ~/.claude/<path>.part \
  && mv ~/.claude/<path>.part ~/.claude/<path>
# only when mode == "100755":
chmod +x ~/.claude/<path>
```
The raw `Accept` header returns the file bytes directly, so files over 1 MB work too. Writing to
`.part` first means a failed call never replaces a good file with an empty one. If a call fails,
delete the `.part` file, stop, and report the path.

**Shared support code.** Folders under `skills/` whose names start with `_` (e.g.
`skills/_shared/`) hold code that several skills use. They never appear in the menu, but skills
break without them. Work out which ones are needed from the tree you already have, not from local
files:

1. From the tree, list the top-level `_` folders: the distinct `skills/_<x>/` prefixes.
2. For every selected skill, **including ones the user chose to skip or merge**, fetch its remote
   files (same pinned `SHA`, raw header) and look for `/_<x>/`, with the leading slash, for each
   `_` folder name. A match (e.g. `../../_shared/transcripts.sh`) means the skill needs `_<x>`.
   The leading slash stops `foo_shared/` from matching.
3. Do the same check on the files of every `_` folder you just added, and repeat until no new
   folder turns up. A shared folder can need another one.

Before installing a needed `_<x>`:

- Find the other installed skills that use it: `grep -rl '/_<x>/' ~/.claude/skills/*/` (leave out
  `_<x>` itself and the skills being installed now).
- If `~/.claude/skills/_<x>/` exists and any file differs from the remote copy, ask:
  "~/.claude/skills/_<x>/ will be updated. It's also used by <skill names>, which will run against
  the new version. Update those skills too (recommended), update only _<x>, or skip _<x>?"
  - **Update those skills too:** install `_<x>` and overwrite each listed skill.
  - **Update only _<x>:** install `_<x>` and warn that the listed skills may break until updated.
  - **Skip _<x>:** leave it alone and warn that the skills just installed may not work.
- If it doesn't exist, or nothing differs, install it without asking.

Install a `_` folder by downloading all of its files with the same download steps, replacing
local copies. Tell the user: "Also installed skills/_<x>/ (used by <skill names>)."

### Hooks

For each selected hook, download the script:
```bash
gh api "repos/fartybobo/farty-bobo/contents/hooks/<name>" \
  --jq '.content' | base64 -d > ~/.claude/hooks/<name>
chmod +x ~/.claude/hooks/<name>
```

Create `~/.claude/hooks/` if it doesn't exist.

If a hook file already exists, ask: "~/.claude/hooks/<name> already exists — overwrite or skip?"

After downloading, go to Step 4 (hook registration) for each hook installed.

### Commands

For each selected command, download it:
```bash
gh api "repos/fartybobo/farty-bobo/contents/commands/<name>" \
  --jq '.content' | base64 -d > ~/.claude/commands/<name>
chmod +x ~/.claude/commands/<name>
```

Create `~/.claude/commands/` if it doesn't exist.

## 4. Register hooks in settings.json

This step only applies if one or more hooks were installed.

First, fetch the hook registration config from the source repo's `settings.json` to know
exactly how each hook should be wired up (event type, matcher, command path):
```bash
gh api "repos/fartybobo/farty-bobo/contents/settings.json" \
  --jq '.content' | base64 -d
```

Extract the `hooks` entries that correspond to each installed hook script.

Then ask the user:
> "Where should the hooks be registered?
>   1. Globally — `~/.claude/settings.json` (fires in every project)
>   2. This project only — `.claude/settings.json` in the current directory"

Based on their choice, read the target `settings.json` (create it with `{}` if it doesn't exist),
merge in the new hook entries under the correct event keys (`PreToolUse`, `PostToolUse`,
`SessionStart`, etc.), and write it back. Do not overwrite existing hook entries for other scripts —
append only.

If a hook entry for the same script path already exists in the target settings.json, skip it
and tell the user it was already registered.

## 5. Report

Print a summary:

```
Installed:
  ✓ skills/  <name>, <name>, ...
  ✓ hooks/   <name> (registered in ~/.claude/settings.json)
  ✓ commands/ <name>, ...

Skipped (already existed):
  - <name>

Done. Restart Claude Code for hook changes to take effect.
```
