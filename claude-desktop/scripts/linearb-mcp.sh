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

if [[ -z "${LINEARB_API_TOKEN:-}" ]]; then
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

exec npx "mcp-remote@${MCP_REMOTE_VERSION}" \
  "https://mcp.linearb.io/mcp" \
  --transport http-only \
  --header "x-api-key:${LINEARB_API_TOKEN}"
