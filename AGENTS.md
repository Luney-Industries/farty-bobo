# AGENTS.md

## How to Add a New MCP Server to Claude Desktop

Follow these steps to add a new MCP server that requires environment variables.

### Step 1: Add required env vars to `.env` and `.env.sample`

Add any environment variables the server needs to `.env` with their real values (this file is gitignored). Add the same keys with empty values to `.env.sample` so others know what to configure:

```sh
# .env.sample
MY_SERVER_API_KEY=
MY_SERVER_REGION=
```

> **Note:** `mcp.env` is sourced with `set -a`, which exports all variables to the MCP server process. Keep it strictly for MCP-specific secrets and configuration — avoid setting variables like `PATH` or `HOME` that could shadow system defaults.

### Step 2: Create `claude-desktop/scripts/<server-name>.sh`

Create a wrapper script that sources the env file before launching the server:

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$HOME/.claude/mcp.env"

if [[ ! -f "$ENV_FILE" ]]; then
  exec python3 "$HOME/.claude/scripts/mcp-stub.py"
fi

env_perms=$(stat -Lf "%OLp" "$ENV_FILE")
if [[ "$env_perms" != "600" && "$env_perms" != "400" ]]; then
  echo "ERROR: $ENV_FILE has unsafe permissions ($env_perms). Run: chmod 600 $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

VERSIONS_FILE="$HOME/.claude/mcp-versions.env"
if [[ -f "$VERSIONS_FILE" ]]; then
  source "$VERSIONS_FILE"
fi

exec uvx <server-package-name> "$@"
```

Replace `<server-package-name>` with the actual `uvx` package name (e.g. `my-mcp-server@1.2.3`). If the server has a version pin, add it to `claude-desktop/mcp-versions.env` and reference it here as `${MY_SERVER_VERSION}`.

> **Note:** If a server does not require a version pin (e.g. it always resolves to latest), do not add a version variable. Document this explicitly in `claude-desktop/mcp-versions.env` with a comment explaining why it is intentionally unpinned.

### Step 3: Add the server entry to `claude-desktop/claude_desktop_config.json`

Add a new entry under `mcpServers` with `command` pointing to your wrapper script. Do not include an `env` block — all env vars are handled by the wrapper script:

```json
"my-server": {
  "command": "/bin/bash",
  "args": ["-c", "~/.claude/scripts/<server-name>.sh"]
}
```

### Step 4: Make the script executable and secure the env file

```sh
chmod +x claude-desktop/scripts/<server-name>.sh
chmod 600 ~/.claude/mcp.env
```

### Step 5: On a new machine, ensure the scripts dir is symlinked

```sh
ln -sfn $REPO_DIRECTORY_PATH/claude-desktop/scripts ~/.claude/scripts
```

### Step 6: Restart Claude Desktop

Quit and reopen Claude Desktop for the new MCP server configuration to take effect.

### Step 7: Verify the server is running

Open Claude Desktop → Settings → Developer → MCP Servers.
The new server should appear with a green status indicator.
If it shows red/error, check Console.app for crash logs from the wrapper script.

## Installing Skills Without Cloning This Repo

This repo is a Claude Code plugin marketplace. Anyone can install skills, hooks, or commands from it à la carte — without forking or cloning the whole thing.

### How to add the plugin

Run these two commands in Claude Code:

```
/plugin marketplace add fartybobo/farty-bobo
/plugin install farty-bobo@farty-bobo
```

Restart Claude Code, then run `/farty-bobo:install`. The skill will:
1. Fetch the live catalog of skills, hooks, and commands from this repo via `gh api`
2. Present a menu — the user picks all or a named subset
3. Download selected items to `~/.claude/skills/`, `~/.claude/hooks/`, `~/.claude/commands/`
4. For hooks: ask whether to register in `~/.claude/settings.json` (global) or `.claude/settings.json` (current project)

### Adding new skills to the plugin catalog

Skills, hooks, and commands in this repo are automatically discoverable by the plugin — no manifest update needed. Just add the file to the right directory (`skills/`, `hooks/`, `commands/`) and it will appear in the install menu on the next run.

## Setting Up cmux & Ghostty

The `cmux/` folder holds config for the cmux terminal workspace manager and the ghostty terminal. The config files carry machine-specific paths, so only `*.template` files are committed — the generated runtime files (`cmux/configs/ghostty`, `cmux/configs/cmux.json`, `cmux/bin/youth-workspace.sh`) are gitignored via the per-folder `.gitignore` rules (`*`, `!*.template`, `!.gitignore`).

### On a new machine

Run the setup script, pointing `--cwd` at the project directory you work in:

```sh
cmux/setup.sh --cwd ~/dev/youth/youthinc
```

It substitutes the templates into real files, symlinks them into `~/.config/cmux/` and `~/.config/ghostty/`, and installs the `cmux-workspace` shell alias. Omitting `--cwd` falls back to `$HOME` with a warning.

The workspace layout JSON is defined in two places — `cmux/configs/cmux.json.template` (as a cmux command) and `cmux/bin/youth-workspace.sh.template` (as a CLI call). Both must be kept in sync if the layout changes.

### Adding a new template parameter

1. Add a `{{PLACEHOLDER}}` token to the relevant `*.template` file.
2. In `cmux/setup.sh`, add a `sed "s|{{PLACEHOLDER}}|$value|g"` substitution where that template is generated (see how `{{WORKING_DIRECTORY}}` is handled).

## Committing rules on this repo

This is a solo project repo that does not require PRs or reviews from other humans or other agents. It is okay to merge to main.
