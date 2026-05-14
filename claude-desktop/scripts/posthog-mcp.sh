#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$HOME/.claude/mcp.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "INFO: $ENV_FILE not found — posthog MCP server not configured on this machine." >&2
  exit 0
fi

env_perms=$(stat -Lf "%OLp" "$ENV_FILE")
if [[ "$env_perms" != "600" && "$env_perms" != "400" ]]; then
  echo "ERROR: $ENV_FILE has unsafe permissions ($env_perms). Run: chmod 600 $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

if [[ -z "${POSTHOG_MCP_API_KEY:-}" ]]; then
  echo "INFO: POSTHOG_MCP_API_KEY is not set — posthog MCP server not configured on this machine." >&2
  exit 0
fi
if [[ ! "${POSTHOG_MCP_API_KEY}" =~ ^[A-Za-z0-9_-]{32,}$ ]]; then
  echo "ERROR: POSTHOG_MCP_API_KEY does not look like a valid PostHog personal API key." >&2
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
  echo "INFO: MCP_REMOTE_VERSION is not set in mcp-versions.env — skipping posthog MCP server." >&2
  exit 0
fi
if [[ ! "${MCP_REMOTE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: MCP_REMOTE_VERSION='${MCP_REMOTE_VERSION}' is not a valid semver string." >&2
  exit 1
fi

exec npx "mcp-remote@${MCP_REMOTE_VERSION}" \
  "https://mcp.posthog.com/sse" \
  --header "Authorization:Bearer ${POSTHOG_MCP_API_KEY}"
