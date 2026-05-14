#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="$HOME/.claude/mcp.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "INFO: $ENV_FILE not found — redshift MCP server not configured on this machine." >&2
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

VERSIONS_FILE="$HOME/.claude/mcp-versions.env"
if [[ -f "$VERSIONS_FILE" ]]; then
  versions_perms=$(stat -Lf "%OLp" "$VERSIONS_FILE")
  if [[ "$versions_perms" != "600" && "$versions_perms" != "400" ]]; then
    echo "ERROR: $VERSIONS_FILE has unsafe permissions ($versions_perms). Run: chmod 600 $VERSIONS_FILE" >&2
    exit 1
  fi
  source "$VERSIONS_FILE"
fi

if [[ -z "${REDSHIFT_MCP_VERSION:-}" ]]; then
  echo "INFO: REDSHIFT_MCP_VERSION is not set — redshift MCP server not configured on this machine." >&2
  exit 0
fi

exec uvx "awslabs.redshift-mcp-server@${REDSHIFT_MCP_VERSION}"
