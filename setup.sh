#!/usr/bin/env bash
# setup.sh — Bootstrap farty-bobo config on a new machine.
# Run from anywhere: bash /path/to/farty-bobo/setup.sh
#
# Flags:
#   --links-only   Skip .env bootstrap and node/nvm install; just refresh symlinks.
#                  Safe to run on every Claude Code session start as a self-heal.
#   --quiet        Suppress success lines (warnings/errors still print).

set -euo pipefail

LINKS_ONLY=false
QUIET=false
for arg in "$@"; do
  case "$arg" in
    --links-only) LINKS_ONLY=true ;;
    --quiet)      QUIET=true ;;
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

# ── Claude Desktop skills (macOS only) ──────────────────────────
# Dynamically locate the active skills-plugin slot by picking the most
# recently modified <outer>/<inner> directory pair under skills-plugin.
# Claude Desktop rotates the inner UUID on updates, so we sort by mtime.
if [[ "$OSTYPE" == darwin* ]]; then
  _desktop_skills_dir() {
    local base="$CLAUDE_DESKTOP_DIR/local-agent-mode-sessions/skills-plugin"
    [[ -d "$base" ]] || return 0
    local slot
    slot=$(ls -dt "$base"/*/* 2>/dev/null | head -1)
    [[ -n "$slot" && -d "$slot/skills" ]] && echo "$slot/skills"
  }

  DESKTOP_SKILLS_DIR="$(_desktop_skills_dir)"
  if [[ -n "$DESKTOP_SKILLS_DIR" ]]; then
    desktop_skill_count=0
    for skill_dir in "$REPO_DIR/skills"/*/; do
      [[ -d "$skill_dir" ]] || continue
      skill_name="$(basename "${skill_dir%/}")"
      symlink_dir "$REPO_DIR/skills/$skill_name" "$DESKTOP_SKILLS_DIR/$skill_name"
      desktop_skill_count=$((desktop_skill_count + 1))
    done
    ok "$desktop_skill_count skill dirs symlinked to Claude Desktop: $DESKTOP_SKILLS_DIR"
  else
    warn "Claude Desktop skills-plugin dir not found — open Claude Desktop, enable at least one skill, then rerun setup.sh"
  fi
fi

# ── Codex skills ────────────────────────────────────────────────
mkdir -p "$CODEX_DIR/skills"
skill_count=0
for skill_dir in "$REPO_DIR/skills"/*/; do
  [[ -d "$skill_dir" ]] || continue
  skill_name="$(basename "${skill_dir%/}")"
  symlink_dir "$REPO_DIR/skills/$skill_name" "$CODEX_DIR/skills/$skill_name"
  skill_count=$((skill_count + 1))
done
ok "$skill_count skill dirs symlinked to ~/.codex/skills/"

# ── Done ─────────────────────────────────────────────────────────
if ! $QUIET; then
  printf "\n${GREEN}Setup complete.${RESET} Restart Claude Desktop for changes to take effect.\n"
fi
