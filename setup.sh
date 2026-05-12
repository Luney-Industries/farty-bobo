#!/usr/bin/env bash
# setup.sh — Bootstrap farty-bobo config on a new machine.
# Run from anywhere: bash /path/to/farty-bobo/setup.sh
#
# Flags:
#   --links-only   Skip .env bootstrap and node/nvm install; just refresh symlinks.
#                  Safe to run on every Claude Code session start as a self-heal.
#   --quiet        Suppress success lines (warnings/errors still print).
#   --gstack       Clone garrytan/gstack into skills/gstack and install its skills
#                  under gstack-* names (off by default; requires bun).

set -euo pipefail

LINKS_ONLY=false
QUIET=false
GSTACK=false
for arg in "$@"; do
  case "$arg" in
    --links-only) LINKS_ONLY=true ;;
    --quiet)      QUIET=true ;;
    --gstack)     GSTACK=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
CLAUDE_DESKTOP_DIR="$HOME/Library/Application Support/Claude"

CODEX_DIR="$HOME/.codex"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

if $QUIET; then
  ok() { :; }
else
  ok() { printf "${GREEN}✓${RESET} %s\n" "$1"; }
fi
warn() { printf "${YELLOW}!${RESET} %s\n" "$1"; }
err()  { printf "${RED}✗${RESET} %s\n" "$1"; }

# ── ~/.claude dir ────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"
ok "~/.claude exists"

# ── Symlinks: files ──────────────────────────────────────────────
symlink_file() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || { err "Source not found: $src"; exit 1; }
  ln -sf "$src" "$dst" || { err "Failed to create symlink: $dst"; exit 1; }
  ok "$(basename "$dst") → $src"
}

# Symlinks: directories
symlink_dir() {
  local src="$1" dst="$2"
  [[ -d "$src" ]] || { err "Source not found: $src"; exit 1; }
  ln -sfn "$src" "$dst" || { err "Failed to create symlink: $dst"; exit 1; }
  ok "$(basename "$dst")/ → $src"
}

symlink_file "$REPO_DIR/settings.json"  "$CLAUDE_DIR/settings.json"
symlink_file "$REPO_DIR/CLAUDE.md"      "$CLAUDE_DIR/CLAUDE.md"
symlink_dir  "$REPO_DIR/commands"       "$CLAUDE_DIR/commands"
symlink_dir  "$REPO_DIR/hooks"          "$CLAUDE_DIR/hooks"
symlink_dir  "$REPO_DIR/skills"         "$CLAUDE_DIR/skills"

symlink_file "$REPO_DIR/claude-desktop/mcp-versions.env" "$CLAUDE_DIR/mcp-versions.env"
chmod 600 "$REPO_DIR/claude-desktop/mcp-versions.env"
symlink_file "$REPO_DIR/.mcp.json"      "$CLAUDE_DIR/.mcp.json"

# ~/.mcp.json makes MCP servers available in every project (CC walks up dir tree).
# Guard against silently overwriting a real file that isn't ours.
if [[ -e "$HOME/.mcp.json" && ! -L "$HOME/.mcp.json" ]]; then
  warn "~/.mcp.json exists and is not a symlink — skipping global MCP link to avoid data loss. Move or delete it manually, then rerun setup.sh."
else
  symlink_file "$REPO_DIR/.mcp.json" "$HOME/.mcp.json"
fi

symlink_dir  "$REPO_DIR/claude-desktop/scripts" "$CLAUDE_DIR/scripts"

# Make wrapper scripts executable (skip gracefully if none exist yet)
if compgen -G "$CLAUDE_DIR/scripts/*.sh" > /dev/null 2>&1; then
  chmod +x "$CLAUDE_DIR/scripts/"*.sh
  ok "scripts/*.sh marked executable"
fi

# ── Claude Desktop config (macOS only) ──────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  mkdir -p "$CLAUDE_DESKTOP_DIR"
  symlink_file "$REPO_DIR/claude-desktop/claude_desktop_config.json" \
    "$CLAUDE_DESKTOP_DIR/claude_desktop_config.json"
fi

# ── .env setup ──────────────────────────────────────────────────
ENV_SRC="$REPO_DIR/.env"
ENV_DST="$CLAUDE_DIR/mcp.env"

if $LINKS_ONLY; then
  # Re-link only if .env already exists; never bootstrap silently on session start.
  if [[ -f "$ENV_SRC" ]]; then
    ln -sf "$ENV_SRC" "$ENV_DST"
    ln -sf "$ENV_SRC" "$CLAUDE_DIR/.env"
  fi
else
  ENV_IS_NEW=false
  if [[ ! -f "$ENV_SRC" ]]; then
    ENV_IS_NEW=true
    if [[ -f "$REPO_DIR/.env.sample" ]]; then
      cp "$REPO_DIR/.env.sample" "$ENV_SRC"
    else
      touch "$ENV_SRC"
    fi
  fi

  ln -sf "$ENV_SRC" "$ENV_DST"
  ln -sf "$ENV_SRC" "$CLAUDE_DIR/.env"
  chmod 600 "$ENV_SRC"
  ok "mcp.env → $ENV_SRC (permissions: 600)"

  if [[ "$ENV_IS_NEW" == true ]]; then
    warn "EDIT YOUR FUCKING .env FILE: $ENV_SRC"
  else
    warn ".env already exists — if new env vars were added to .env.sample, add them manually to: $ENV_SRC"
  fi
fi

if ! $LINKS_ONLY; then
  # ── node: install pinned version via nvm, expose to /bin/sh ─────
  # Claude Code hooks run under /bin/sh which doesn't load nvm.
  # We install the pinned version from .nvmrc and create shims in
  # ~/.local/bin (no sudo required) so /bin/sh can find node/npm/npx.

  NODE_VERSION_FILE="$REPO_DIR/.nvmrc"
  NODE_VERSION=$(cat "$NODE_VERSION_FILE" | tr -d '[:space:]')
  NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  LOCAL_BIN="$HOME/.local/bin"

  mkdir -p "$LOCAL_BIN"

  # Load nvm if available and install the pinned version
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh" --no-use
    if ! nvm ls "$NODE_VERSION" &>/dev/null; then
      printf "  Installing node %s via nvm...\n" "$NODE_VERSION"
      nvm install "$NODE_VERSION"
    fi
    # Resolve binary path: try nvm which first, fall back to glob
    NVM_NODE_PATH="$(nvm which "$NODE_VERSION" 2>/dev/null)" \
      || NVM_NODE_PATH="$(ls "$NVM_DIR/versions/node/"v"$NODE_VERSION"*/bin/node 2>/dev/null | sort -V | tail -1)"
    NVM_NODE_BIN="$(dirname "$NVM_NODE_PATH")"
    if [[ -x "$NVM_NODE_BIN/node" ]]; then
      ln -sf "$NVM_NODE_BIN/node" "$LOCAL_BIN/node"
      ln -sf "$NVM_NODE_BIN/npm"  "$LOCAL_BIN/npm"
      ln -sf "$NVM_NODE_BIN/npx"  "$LOCAL_BIN/npx"
      ok "node $("$NVM_NODE_BIN/node" --version) symlinked to ~/.local/bin (from nvm)"
    else
      err "nvm install succeeded but binary not found at $NVM_NODE_BIN"
      exit 1
    fi
  else
    err "nvm not found — install nvm first, then rerun setup.sh"
    err "See: https://github.com/nvm-sh/nvm"
    exit 1
  fi

  # Remind if ~/.local/bin isn't on PATH
  if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    warn "Add ~/.local/bin to your PATH so shells can find node:"
    warn "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
  fi
fi

# ── Helpers ─────────────────────────────────────────────────────

# Returns the newest direct subdirectory of $1 by mtime, NUL-safe.
# Works correctly even when the path contains spaces.
_newest_subdir() {
  local parent="$1" newest="" newest_mtime=0 mtime
  [[ -d "$parent" ]] || return 1
  while IFS= read -r -d '' dir; do
    mtime=$(stat -f '%m' "$dir" 2>/dev/null) || continue
    if (( mtime > newest_mtime )); then newest_mtime=$mtime; newest="$dir"; fi
  done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  [[ -n "$newest" ]] || return 1
  echo "$newest"
}

# Echos the active Claude Desktop skills dir, or returns 1 if not found.
# The path is: skills-plugin/<newest-outer>/<newest-inner>/skills/
# Claude Desktop rotates the inner UUID on app updates.
_desktop_skills_dir() {
  local base="$CLAUDE_DESKTOP_DIR/local-agent-mode-sessions/skills-plugin"
  local outer inner
  outer=$(_newest_subdir "$base")    || return 1
  inner=$(_newest_subdir "$outer")   || return 1
  [[ -d "$inner/skills" ]]           || return 1
  echo "$inner/skills"
}

# Symlinks every skill dir from the repo into $1; prints a summary line.
_symlink_skills_to() {
  local target="$1" skill_dir skill_name count=0
  for skill_dir in "$REPO_DIR/skills"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "${skill_dir%/}")"
    symlink_dir "$REPO_DIR/skills/$skill_name" "$target/$skill_name"
    count=$((count + 1))
  done
  ok "$count skill dirs symlinked to $target"
}

# Removes stale symlinks from the Desktop skills dir left by earlier setup runs.
_prune_desktop_skill_symlinks() {
  local target="$1" removed=0 entry
  while IFS= read -r -d '' entry; do
    rm -f "$entry"
    removed=$((removed + 1))
  done < <(find "$target" -maxdepth 1 -type l -print0 2>/dev/null)
  if (( removed > 0 )); then warn "$removed stale skill symlinks removed from Claude Desktop"; fi
}

# Copies each skill dir from claude-desktop/skills/ into $1; prints a summary line.
#
# NOTE: Claude Desktop syncs its manifest from Anthropic's servers on startup, so local
# manifest writes have no effect. Each skill must be imported ONCE via the Skills UI (+)
# to create a server-side record. After that, this copy keeps the content up to date.
# For skills that need the initial import, a .skill ZIP is generated under a tmp dir.
_install_desktop_skills() {
  local target="$1" skill_dir skill_name count=0
  local -a new_skills=()
  local skill_tmp="${TMPDIR:-/tmp}/farty-bobo-skills"
  mkdir -p "$skill_tmp"
  _prune_desktop_skill_symlinks "$target"
  for skill_dir in "$REPO_DIR/claude-desktop/skills"/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name="$(basename "${skill_dir%/}")"
    [[ -n "$skill_name" && "$skill_name" != *"/"* && "$skill_name" != *".."* ]] || continue
    rm -rf "${target:?}/${skill_name:?}"
    cp -r "$skill_dir" "$target/$skill_name"
    # Always generate a .skill ZIP — manifest is server-managed and cannot be checked locally.
    (cd "$REPO_DIR/claude-desktop/skills" && zip -qr "$skill_tmp/$skill_name.skill" "$skill_name/")
    new_skills+=("$skill_tmp/$skill_name.skill")
    ok "$skill_name → $target (copied)"
    count=$((count + 1))
  done
  local noun="skill"; if (( count != 1 )); then noun="skills"; fi
  ok "$count $noun copied to Claude Desktop: $target"
  if (( ${#new_skills[@]} > 0 )); then
    warn "Import each skill once via Claude Desktop → Skills → + (server-side registration required)"
    local f; for f in "${new_skills[@]}"; do warn "  Import: $f"; done
  fi
}

# ── Claude Desktop skills (macOS only) ──────────────────────────
if [[ "$OSTYPE" == darwin* ]]; then
  DESKTOP_SKILLS_DIR="$(_desktop_skills_dir)" || true
  if [[ -n "$DESKTOP_SKILLS_DIR" ]]; then
    _install_desktop_skills "$DESKTOP_SKILLS_DIR"
  else
    warn "Claude Desktop skills-plugin dir not found — open Claude Desktop, enable at least one skill, then rerun setup.sh"
  fi
fi

# ── Codex skills ────────────────────────────────────────────────
mkdir -p "$CODEX_DIR/skills"
_symlink_skills_to "$CODEX_DIR/skills"

# ── gstack skills (opt-in via --gstack) ─────────────────────────
# Clones garrytan/gstack into skills/gstack and runs its setup with --prefix
# so all gstack skills land under gstack-* names (no collision with Farty Bobo).
# Skipped when --links-only is passed (that mode only refreshes symlinks).
if $GSTACK && $LINKS_ONLY; then
  warn "gstack: skipped — --gstack has no effect with --links-only"
elif $GSTACK; then
  GSTACK_DIR="$REPO_DIR/skills/gstack"
  if ! command -v bun >/dev/null 2>&1; then
    err "gstack requires bun — install it first:"
    err "  curl -fsSL https://bun.sh/install | bash"
    err "Then rerun: setup.sh --gstack"
  else
    if [[ -d "$GSTACK_DIR/.git" ]]; then
      printf "  Updating gstack...\n"
      git -C "$GSTACK_DIR" pull --ff-only --quiet \
        || { err "gstack: git pull failed — check $GSTACK_DIR manually"; exit 1; }
    else
      warn "gstack: cloning third-party repo from github.com/garrytan/gstack — review its code before running on sensitive machines"
      git clone --quiet https://github.com/garrytan/gstack "$GSTACK_DIR" \
        || { err "gstack: clone failed"; exit 1; }
    fi
    [[ -x "$GSTACK_DIR/setup" ]] \
      || { err "gstack: $GSTACK_DIR/setup not found or not executable"; exit 1; }
    "$GSTACK_DIR/setup" --prefix --quiet
    ok "gstack skills installed with gstack-* prefix"
  fi
fi

# ── Done ─────────────────────────────────────────────────────────
if ! $QUIET; then
  printf "\n${GREEN}Setup complete.${RESET} Restart Claude Desktop for changes to take effect.\n"
fi
