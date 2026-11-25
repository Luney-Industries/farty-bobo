# shellcheck shell=bash
# transcripts.sh — shared bash helpers for scripts that scan Claude Code
# transcripts. Source it; don't execute it. Pairs with TranscriptScan.pm.
#
# Used by:
#   skills/pr-action-board/scripts/find-pr-sessions.sh
#   skills/resurrect-claude-sessions/scripts/find-ticket-sessions.sh
#
# Provides:
#   TRANSCRIPT_SHARED_DIR       absolute path of this folder (for perl -I)
#   transcripts_max_age VAR DEF prints the whole-number value of env var VAR,
#                               or DEF (with a WARN on stderr) if it isn't one
#   transcripts_list DIR DAYS   prints NUL-separated <DIR>/<project>/<id>.jsonl
#                               paths modified in the last DAYS days (0 = all).
#                               find errors become WARN lines on stderr and
#                               never fail the caller.

# shellcheck disable=SC2034  # used by the scripts that source this file
TRANSCRIPT_SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

transcripts_max_age() {
  local var="$1" def="$2" val
  val="${!var:-$def}"
  if [[ "$val" =~ ^[0-9]{1,6}$ ]]; then
    echo $((10#$val))   # base 10: "08" is eight, not bad octal
  else
    echo "WARN: $var must be a whole number (got '$val'); using $def" >&2
    echo "$def"
  fi
}

transcripts_list() {
  local dir="$1" days="$2"
  local -a age=()
  if [[ "$days" -gt 0 ]]; then age=(-mtime "-$days"); fi
  { find "$dir" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' \
      ${age[@]+"${age[@]}"} -print0 2>&1 1>&3 \
      | sed 's/^/WARN: /' >&2; } 3>&1 || true
}
