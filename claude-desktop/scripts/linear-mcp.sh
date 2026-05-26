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

if [[ -z "${LINEAR_API_KEY:-}" ]]; then
  exec python3 "$HOME/.claude/scripts/mcp-stub.py"
fi

unset MCP_REMOTE_VERSION
VERSIONS_FILE="$HOME/.claude/mcp-versions.env"
if [[ -f "$VERSIONS_FILE" ]]; then
  versions_perms=$(stat -Lf "%OLp" "$VERSIONS_FILE")
  if [[ "$versions_perms" != "600" && "$versions_perms" != "400" ]]; then
    echo "ERROR: $VERSIONS_FILE has unsafe permissions ($versions_perms). Run: chmod 600 $VERSIONS_FILE" >&2
    exit 1
  fi
  source "$VERSIONS_FILE"
fi

if [[ -z "${MCP_REMOTE_VERSION:-}" ]]; then
  exec python3 "$HOME/.claude/scripts/mcp-stub.py"
fi
if [[ ! "${MCP_REMOTE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: MCP_REMOTE_VERSION='${MCP_REMOTE_VERSION}' is not a valid semver string." >&2
  exit 1
fi

# Ensure Node.js >=18 is first in PATH. Without this, asdf shims (which
# require a .tool-versions file) or Node v16 (where node:fs/promises lacks
# the constants export) cause mcp-remote to crash on startup.
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  source "$NVM_DIR/nvm.sh" --no-use
  _nvm_node=""
  for _nvm_ver in 22 20 18; do
    _nvm_node="$(nvm which "$_nvm_ver" 2>/dev/null)" && break || true
  done
  if [[ -n "$_nvm_node" ]]; then
    export PATH="$(dirname "$_nvm_node"):${PATH}"
  else
    echo "WARNING: No Node.js >=18 found via nvm; npx may fail if asdf or old Node is first in PATH." >&2
  fi
  unset _nvm_node _nvm_ver
fi

exec npx "mcp-remote@${MCP_REMOTE_VERSION}" \
  "https://mcp.linear.app/mcp" \
  --header "Authorization: Bearer ${LINEAR_API_KEY}"
