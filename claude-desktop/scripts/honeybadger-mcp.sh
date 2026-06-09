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

if [[ -z "${HONEYBADGER_PERSONAL_AUTH_TOKEN:-}" ]]; then
  exec python3 "$HOME/.claude/scripts/mcp-stub.py"
fi

exec docker run -i --rm \
  -e HONEYBADGER_PERSONAL_AUTH_TOKEN \
  ghcr.io/honeybadger-io/honeybadger-mcp-server
