# Farty Bobo

> Opinionated configuration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Claude Desktop](https://claude.ai/download), and [Codex](https://github.com/openai/codex) (partial support) that actually works. Custom skills, hooks, settings, and MCP servers — clone it, symlink it, stop suffering.

**[fartybobo.com](https://fartybobo.com)**

Shared configuration files for Claude Code, Claude Desktop, and Codex. Clone this repo and symlink the files into `~/.claude/` to set up a new machine quickly.

## Supported Platforms

| Platform | Support |
|----------|---------|
| **Claude Code** | Full — skills, hooks, settings, MCP servers, commands |
| **Claude Desktop** | Full — MCP servers via `claude_desktop_config.json` symlink; `.skill` archives extracted into active skills-plugin slot |
| **Codex** | Partial — skills load, but steps using `Agent`/`SendMessage`/`TaskCreate` silently no-op |

## Repo Structure

```
├── .claude-plugin/      # Claude Code plugin manifest — makes this repo an installable plugin
│   ├── plugin.json
│   └── marketplace.json
├── CLAUDE.md            # Project-level instructions
├── settings.json        # Claude Code settings (model, hooks, permissions, etc.)
├── .mcp.json            # MCP server configuration
├── commands/
│   └── statusline-command.sh
├── hooks/
│   ├── post-edit-check.sh
│   └── README.md
└── skills/
    └── *                # All skills, including /install for à la carte setup
```

## Setup on a New Machine

**Prerequisites:** [nvm](https://github.com/nvm-sh/nvm) must be installed. The setup script installs the pinned node version (see `.nvmrc`) automatically.

1. **Clone the repo**

   ```sh
   git clone <repo-url> ~/dev/farty-bobo
   ```

2. **Run the setup script**

   ```sh
   cd ~/dev/farty-bobo
   ./setup.sh
   ```

   The script will:
   - Create `~/.claude` if needed
   - Symlink all config files and directories into `~/.claude`
   - Symlink `claude_desktop_config.json` into Claude Desktop's config dir (macOS)
   - Extract each `.skill` archive from `claude-desktop/skills/` into Claude Desktop's active skills-plugin slot (macOS; warns if not initialized yet)
   - Create `.env` from `.env.sample` if it doesn't exist
   - Install the pinned node version via nvm and symlink it to `~/.local/bin`

3. **Fill in `.env`**

   ```sh
   open .env   # or edit with your preferred editor
   ```

   Each variable is documented with inline comments in `.env.sample`. If you re-run `setup.sh` after a `git pull`, check `.env.sample` for any new keys and add them manually to `.env`.

4. **Ensure `~/.local/bin` is on your PATH** (if the script warns about it)

   ```sh
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
   ```

5. **Restart Claude Desktop** for MCP server changes to take effect.

6. **Verify**

   ```sh
   ls -la ~/.claude/settings.json ~/.claude/CLAUDE.md ~/.claude/.mcp.json ~/.claude/commands ~/.claude/hooks
   ```

   Each entry should show `->` pointing to the repo paths.

## Customization

- Edit files in this repo, then `git commit` and `git push` — changes propagate to every machine via `git pull`.
- To override settings on a single machine without affecting the repo, remove the symlink for that file and create a local copy instead.

## Useful Links

- [Claude Code Hooks](https://code.claude.com/docs/en/hooks)

## Adding MCP Servers to a Project

MCP servers are configured **per-project** via a `.mcp.json` file at the repo root — not globally. This means servers only load when Claude Code is running inside the relevant repo, so env vars and credentials don't need to be available everywhere.

Use the `/add-mcp-server` skill to add an MCP server to any project. It will:
- Create or update `.mcp.json` at the project root
- Use `${VAR_NAME}` syntax for secrets (Claude Code expands these at runtime)
- Add missing env vars to `.env` and ensure `.env` is gitignored
- Keep `.mcp.json` safe to commit

### Useful servers

| Server | Install | Notes |
|--------|---------|-------|
| **dbt-mcp** | `uvx dbt-mcp` | Requires dbt installed via pipx. Env vars: `DBT_PROJECT_DIR`, `DBT_PATH`, plus project-specific DB credentials. |
| **redshift** | `uvx awslabs.redshift-mcp-server` | Env vars: `AWS_PROFILE`, `AWS_REGION`. |
| **Langfuse** | HTTP/SSE — `https://us.cloud.langfuse.com/api/public/mcp` | Auth header: `Authorization: Basic ${LANGFUSE_BASE_64_TOKEN}`. See [docs](https://langfuse.com/docs/api-and-data-platform/features/mcp-server). Alternatively, use [langfuse-cli](https://github.com/langfuse/langfuse-cli) as a skill: `npx langfuse-cli get-skill`. |


## Installing Skills Without Cloning This Repo

Don't want to clone the whole thing? Use the `farty-bobo` plugin to selectively install any skill, hook, or command onto your machine.

Run these two commands in Claude Code:

```
/plugin marketplace add fartybobo/farty-bobo
/plugin install farty-bobo@farty-bobo
```

Restart Claude Code, then run:

```
/farty-bobo:install
```

It will show you the full catalog, let you pick what you want, download it to the right places, and for hooks ask whether to register them globally or scoped to the current project.

## TODOs

- https://github.com/simonw/claude-code-transcripts
