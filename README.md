# Farty Bobo

> Opinionated configuration for [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Claude Desktop](https://claude.ai/download), and [Codex](https://github.com/openai/codex) (partial support) that actually works. Built for **software engineers** who need to ship fast — custom skills, hooks, settings, and MCP servers wired into a parallel workflow so nothing sits waiting. Clone it. Symlink it. Stop suffering.

**[fartybobo.com](https://fartybobo.com)**

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
   - Extract each `.skill` archive from `claude-desktop/skills/` into Claude Desktop's active skills-plugin slot (macOS; warns if a skill needs a one-time UI import to register server-side)
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

5. **Import Desktop skills once.** `setup.sh` always generates `.skill` ZIP archives under `$TMPDIR/farty-bobo-skills/` (e.g. `/var/folders/.../farty-bobo-skills/`). Open Claude Desktop → Skills → `+` and import each `.skill` file from that directory. This is a one-time step per skill — it registers the skill server-side. Future `setup.sh` runs keep the skill content up to date automatically.

6. **Restart Claude Desktop** for MCP server changes to take effect.

6. **Verify**

   ```sh
   ls -la ~/.claude/settings.json ~/.claude/CLAUDE.md ~/.claude/.mcp.json ~/.claude/commands ~/.claude/hooks
   ```

   Each entry should show `->` pointing to the repo paths.

## cmux Setup

The `cmux/` folder holds first-party config for the [cmux](https://github.com/manaflow-ai/cmux) terminal workspace manager and the [ghostty](https://ghostty.org) terminal. Only `*.template` files are committed — the real config files contain machine-specific paths and are generated locally (and gitignored).

Run it on a new machine, pointing `--cwd` at the project you live in:

```sh
cmux/setup.sh --cwd ~/dev/youth/youthinc
```

If you omit `--cwd`, it falls back to `$HOME` and warns you about it.

The script generates:

- `cmux/configs/ghostty` — ghostty config with `working-directory` substituted to your `--cwd`
- `cmux/configs/cmux.json` — cmux config (straight copy of the template)
- `cmux/bin/youth-workspace.sh` — the workspace-creation script (made executable)

It then symlinks the generated files into place:

- `~/.config/cmux/cmux.json` → `cmux/configs/cmux.json`
- `~/.config/ghostty/config` → `cmux/configs/ghostty`

And installs a `cmux-workspace` alias in your `~/.zshrc` (or `~/.bashrc`) that runs `youth-workspace.sh`. Re-running is idempotent — the alias is added only once. If you move the repo, re-run `cmux/setup.sh --cwd <path>` to refresh the alias, which hardcodes the absolute repo path at setup time.

The templates ship with a Youth Inc workspace layout but are yours to adapt. Edit `cmux/configs/ghostty.template` to change fonts, themes, or opacity. Edit `cmux/configs/cmux.json.template` to add new workspace commands or tweak UI settings (full schema reference: [cmux schema](https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json)). Edit `cmux/bin/youth-workspace.sh.template` to change the default pane layout. Re-run `cmux/setup.sh` after any template change to regenerate the live files.

## Disabling Mouse Clicks in Claude Code

If Claude Code's fullscreen rendering mode (`/tui fullscreen` or `CLAUDE_CODE_NO_FLICKER=1`) captures mouse clicks and interferes with your terminal's native text selection, disable click/drag/hover handling while keeping wheel scroll:

```sh
echo 'export CLAUDE_CODE_DISABLE_MOUSE_CLICKS=1' >> ~/.zshrc
source ~/.zshrc
```

Requires Claude Code v2.1.195+. Restart any running Claude Code sessions for it to take effect. This is env-var only — there's no `settings.json` equivalent. To disable *all* mouse capture including wheel scroll instead, use `CLAUDE_CODE_DISABLE_MOUSE=1` (takes precedence if both are set).

## Configuring the Temp Directory

Skills like `/plan-task`, `/critique`, `/review-multiple-prs`, `/pr-action-board`, `/triage-mentions`, and `/address-pr-comments` write plans, decisions, critiques, and triage files outside the repo. By default they go under `/tmp`, which macOS wipes on reboot. To put them somewhere else, set `FARTY_BOBO_TEMP_DIR` to an absolute path:

```sh
echo 'export FARTY_BOBO_TEMP_DIR="$HOME/.farty-bobo/tmp"' >> ~/.zshrc
source ~/.zshrc
```

You own the root. Each skill decides its own layout beneath it: `<repo>/<branch>/` for planning and review artifacts (e.g. `<repo>/<branch>/plans/`), and a per-skill folder for the rest (`pr-action-board/`, `triage-mentions/`, `address-pr-comments/`). A relative path or a quoted `~` is rejected with a warning and falls back to `/tmp`. Restart any running Claude Code sessions for it to take effect.

If the Bash sandbox blocks writes to your chosen path, allow that path in your machine-local sandbox settings, or keep the default. GUI-launched apps (e.g. Claude Desktop) don't read `~/.zshrc`, so there the skills fall back to `/tmp`. Every skill prints the resolved path, so a mismatch is visible. If you point it at a persistent location, files accumulate there, so prune it yourself now and then. This is set per machine in your shell profile, not in the shared `settings.json`, because the path is machine-specific.

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

## Installing gstack

[gstack](https://github.com/garrytan/gstack) is a separate skill library that can coexist with Farty Bobo. Install it with the `gstack-` prefix so its skills don't overwrite any existing Farty Bobo skills.

**Prerequisites:** [bun](https://bun.sh) must be installed (gstack builds a browser binary).

```bash
curl -fsSL https://bun.sh/install | bash
```

**1. Clone gstack as a sibling under `~/.claude/skills/`**

```bash
git clone https://github.com/garrytan/gstack ~/.claude/skills/gstack
```

**2. Run setup with the `--prefix` flag**

```bash
~/.claude/skills/gstack/setup --prefix
```

**Why `--prefix`:** Without it, gstack's `review` skill lands in `~/.claude/skills/review/` and overwrites Farty Bobo's existing `review` skill. With `--prefix`, everything installs under `gstack-*` names — separate namespace, no collisions.

**What setup creates:**
- `~/.claude/skills/gstack-{name}/` directories, each containing a symlinked `SKILL.md` pointing back into the cloned repo
- `~/.claude/skills/gstack/browse/dist/browse` — the browser binary (requires bun + Playwright)
- `~/.gstack/` — global state directory

**Does NOT touch:** existing Farty Bobo skills, hooks, commands, or `~/.claude/settings.json`.

Restart Claude Code after setup — `gstack:*` skills will appear in the catalog alongside `farty-bobo:*` ones.

## TODOs

- https://github.com/simonw/claude-code-transcripts
