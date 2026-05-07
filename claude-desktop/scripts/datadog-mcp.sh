#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$HOME/.claude/mcp.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. See README for setup instructions." >&2
  exit 1
fi

env_perms=$(stat -Lf "%OLp" "$ENV_FILE")
if [[ "$env_perms" != "600" && "$env_perms" != "400" ]]; then
  echo "ERROR: $ENV_FILE has unsafe permissions ($env_perms). Run: chmod 600 $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [[ -z "${DD_API_KEY:-}" ]]; then
  echo "ERROR: DD_API_KEY is not set in $ENV_FILE." >&2
  exit 1
fi
if [[ ! "${DD_API_KEY}" =~ ^[a-f0-9]{32}$ ]]; then
  echo "ERROR: DD_API_KEY does not look like a valid DataDog API key (expected 32 hex chars)." >&2
  exit 1
fi

if [[ -z "${DD_APPLICATION_KEY:-}" ]]; then
  echo "ERROR: DD_APPLICATION_KEY is not set in $ENV_FILE." >&2
  exit 1
fi
if [[ ! "${DD_APPLICATION_KEY}" =~ ^[A-Za-z0-9_-]{40,}$ ]]; then
  echo "ERROR: DD_APPLICATION_KEY does not look like a valid DataDog application key." >&2
  exit 1
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
  echo "ERROR: MCP_REMOTE_VERSION is not set. Add it to claude-desktop/mcp-versions.env." >&2
  exit 1
fi
if [[ ! "${MCP_REMOTE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: MCP_REMOTE_VERSION='${MCP_REMOTE_VERSION}' is not a valid semver string." >&2
  exit 1
fi

exec npx "mcp-remote@${MCP_REMOTE_VERSION}" \
  "https://mcp.datadoghq.com/api/unstable/mcp-server/mcp" \
  --transport http-only \
  --header "DD-API-KEY:${DD_API_KEY}" \
  --header "DD-APPLICATION-KEY:${DD_APPLICATION_KEY}"
