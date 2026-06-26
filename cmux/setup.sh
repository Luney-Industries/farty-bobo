#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: cmux/setup.sh [--cwd <working-directory>]
  --cwd   Set the ghostty working-directory (default: $HOME)
  --help  Show this help
EOF
}

CWD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd) CWD="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

CMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$CMUX_DIR/.." && pwd)"

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi

ok()   { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}!${RESET} %s\n" "$1"; }
err()  { printf "${RED}✗${RESET} %s\n" "$1"; }

# Symlinks $src to $dst. If $dst is an existing symlink it is replaced; if it is
# a real file it is backed up to $dst.backup-<timestamp> before being replaced.
symlink_file() {
  local src="$1" dst="$2"
  if [[ -L "$dst" ]]; then
    rm -f "$dst"
  elif [[ -f "$dst" ]]; then
    local backup="$dst.backup-$(date +%Y%m%d%H%M%S)"
    cp "$dst" "$backup"
    warn "$(basename "$dst"): real file found — backed up to $backup before symlinking"
    rm -f "$dst"
  fi
  ln -sf "$src" "$dst"
}

if [[ -z "$CWD" ]]; then
  CWD="$HOME"
  warn "No --cwd given — defaulting working-directory to $HOME"
fi

CWD_ESCAPED="$(printf '%s' "$CWD" | sed 's/[&|\\]/\\&/g')"
sed "s|{{WORKING_DIRECTORY}}|$CWD_ESCAPED|g" "$CMUX_DIR/configs/ghostty.template" > "$CMUX_DIR/configs/ghostty"
ok "ghostty config generated (working-directory = $CWD)"

cp "$CMUX_DIR/configs/cmux.json.template" "$CMUX_DIR/configs/cmux.json"
ok "cmux.json generated"

cp "$CMUX_DIR/bin/youth-workspace.sh.template" "$CMUX_DIR/bin/youth-workspace.sh"
chmod +x "$CMUX_DIR/bin/youth-workspace.sh"
ok "youth-workspace.sh generated and marked executable"

mkdir -p "$HOME/.config/cmux"
symlink_file "$CMUX_DIR/configs/cmux.json" "$HOME/.config/cmux/cmux.json"
ok "~/.config/cmux/cmux.json → $CMUX_DIR/configs/cmux.json"

mkdir -p "$HOME/.config/ghostty"
symlink_file "$CMUX_DIR/configs/ghostty" "$HOME/.config/ghostty/config"
ok "~/.config/ghostty/config → $CMUX_DIR/configs/ghostty"

if [[ "$SHELL" == *zsh* ]]; then
  RC="$HOME/.zshrc"
else
  RC="$HOME/.bashrc"
fi

ALIAS_LINE="alias cmux-workspace='bash \"$REPO_DIR/cmux/bin/youth-workspace.sh\"'"
if [[ ! -f "$RC" ]] || ! grep -qF "alias cmux-workspace=" "$RC"; then
  printf '%s\n' "$ALIAS_LINE" >> "$RC"
  ok "cmux-workspace alias installed in $RC"
else
  ok "cmux-workspace alias already present in $RC"
fi

printf "\n${GREEN}cmux setup complete.${RESET}\n"
