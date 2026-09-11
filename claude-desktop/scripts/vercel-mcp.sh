#!/usr/bin/env bash
set -euo pipefail

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
  "https://mcp.vercel.com" \
  --transport http-only
