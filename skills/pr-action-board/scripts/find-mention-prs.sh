#!/usr/bin/env bash
# find-mention-prs.sh — Find open PRs (not authored by me) where the user or their teams are
#   mentioned in the PR body OR in comments, and the user has NOT responded since the mention.
#
# Stages:
#   1. Collect candidate PR URLs (each a { url, reason, team_mentioned?, from_notification? }) from:
#        a. GitHub search  mentions:<login> -author:<login>
#        b. GitHub search  team:<org>/<slug> -author:<login>   (per valid team handle)
#        c. GitHub notifications (all=true, participating=true, per_page=100) with reason
#           mention / team_mention on a PullRequest whose subject URL ends in /pulls/<n>,
#           limited to org_scope's owner (case-insensitive) when org_scope is set
#   2. Dedupe by URL. Reason priority: direct-mention > team-mention > mention.
#   3. Enrich each PR: GET pulls/N (drop unless state == open, drop if I am the author),
#      then issues/N/comments, pulls/N/comments and pulls/N/reviews (all pages).
#   4. Filter:
#        mentioned_at = latest edit/creation time (updated_at, else created_at / submitted_at)
#                       of a comment / review comment / review by someone else whose body
#                       mentions @<login> or one of my team handles. The match is
#                       case-insensitive, needs the whole handle with no word character, dot
#                       or dash on either side (so "ops@login.dev" is not a mention), and
#                       ignores inline code spans and fenced code blocks.
#                       With no match it falls back to the PR's created_at (body-only mention).
#        my_last      = latest creation time of a comment / review comment / review by me.
#      The PR is dropped when my_last > mentioned_at (already responded), except that a
#      notification-sourced PR with no matching mention in its activity (for example a ping
#      for a team missing from teams_json) is always kept (fail open).
#      If an activity fetch fails, a WARN goes to stderr and the PR is kept (fail open).
#
# Search, notification and API failures, malformed notifications and malformed PR responses
# print WARN lines to stderr and are skipped; stdout is always a JSON array.
#
# Usage:
#   ./find-mention-prs.sh <gh_login> <org_scope_or_empty> <teams_json>
#
#   gh_login           — the authenticated user's login (e.g. "kinanf")
#   org_scope_or_empty — restrict to one GitHub org (e.g. "embarkvet"), or "" for all orgs;
#                        must match ^[A-Za-z0-9-]+$ when set
#   teams_json        — JSON array from get-teams.sh, e.g. '[{"mention":"@embarkvet/platform"}]'
#
# Output: JSON array sorted by updated_at (newest first) of:
#   { url, number, owner, repo, title, author, reason, mentioned_at, updated_at,
#     team_mentioned? }
#
# Reasons: "mention" | "team-mention" | "direct-mention"
#   mention        — gh search "mentions:" hit (covers body + comments, indistinguishable)
#   team-mention   — gh search "team:" hit or notification reason=team_mention
#   direct-mention — notification reason=mention
#
# Exit codes: 0 on success, 2 on invalid usage.
set -euo pipefail

USAGE="Usage: find-mention-prs.sh <gh_login> <org_scope_or_empty> <teams_json>"
GH_LOGIN="${1:?$USAGE}"
ORG_SCOPE="${2:-}"
TEAMS_JSON="${3:-[]}"

if [[ ! "$GH_LOGIN" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "ERROR: invalid gh_login '$GH_LOGIN'. $USAGE" >&2
  exit 2
fi
if [[ -n "$ORG_SCOPE" && ! "$ORG_SCOPE" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "ERROR: invalid org_scope '$ORG_SCOPE'. $USAGE" >&2
  exit 2
fi
if ! echo "$TEAMS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: teams_json must be a JSON array. $USAGE" >&2
  exit 2
fi

ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

warn() { echo "WARN: $*" >&2; }

TEAMS="[]"
while IFS= read -r team_mention; do
  [[ -z "$team_mention" ]] && continue
  if [[ "$team_mention" =~ ^@[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
    TEAMS=$(jq -c --arg t "$team_mention" '. + [$t]' <<<"$TEAMS")
  else
    warn "ignoring invalid team mention '$team_mention'"
  fi
done < <(echo "$TEAMS_JSON" | jq -r '.[] | .mention? // empty | strings')

SEARCH_ARGS=("--state" "open" "--json" "url,author" "--limit" "100")
[[ -n "$ORG_SCOPE" ]] && SEARCH_ARGS+=("--owner" "$ORG_SCOPE")

search_candidates() {
  local qualifier="$1" reason="$2" team="$3" hits
  if ! hits=$(gh search prs "${SEARCH_ARGS[@]}" -- "$qualifier" "-author:${GH_LOGIN}" 2>"$ERR_FILE"); then
    warn "gh search prs $qualifier failed: $(cat "$ERR_FILE")"
    echo "[]"
    return
  fi
  echo "$hits" | jq -c --arg login "$GH_LOGIN" --arg reason "$reason" --arg team "$team" '
    [ .[]
      | select((.author.login // "" | ascii_downcase) != ($login | ascii_downcase))
      | {url, reason: $reason}
      + (if $team == "" then {} else {team_mentioned: $team} end) ]'
}

CANDIDATES=$(search_candidates "mentions:${GH_LOGIN}" "mention" "")

while IFS= read -r team_mention; do
  [[ -z "$team_mention" ]] && continue
  TEAM_HITS=$(search_candidates "team:${team_mention#@}" "team-mention" "$team_mention")
  CANDIDATES=$(jq -c --argjson b "$TEAM_HITS" '. + $b' <<<"$CANDIDATES")
done < <(jq -r '.[]' <<<"$TEAMS")

NOTIFICATIONS_ENDPOINT="notifications?all=true&participating=true&per_page=100"
if ! NOTIFICATIONS=$(gh api "$NOTIFICATIONS_ENDPOINT" --paginate 2>"$ERR_FILE" | jq -s -c 'add // []'); then
  warn "gh api notifications failed: $(cat "$ERR_FILE")"
elif ! NOTIF_HITS=$(jq -c --arg org "$ORG_SCOPE" '
    [ .[]
      | select(type == "object"
               and (.reason == "mention" or .reason == "team_mention")
               and .subject.type? == "PullRequest"
               and (.subject.url | type) == "string"
               and (.subject.url | test("/pulls/[0-9]+$"))
               and ($org == "" or ((.repository.owner.login? // "") | ascii_downcase) == ($org | ascii_downcase)))
      | { url: (.subject.url
                | sub("^https://api\\.github\\.com/repos/"; "https://github.com/")
                | sub("/pulls/(?<n>[0-9]+)$"; "/pull/\(.n)")),
          reason: (if .reason == "mention" then "direct-mention" else "team-mention" end),
          from_notification: true } ]' \
    <<<"$NOTIFICATIONS" 2>"$ERR_FILE"); then
  warn "could not parse notifications: $(cat "$ERR_FILE")"
else
  CANDIDATES=$(jq -c --argjson b "$NOTIF_HITS" '. + $b' <<<"$CANDIDATES")
fi

DEDUPED=$(jq -c '
  def priority: {"direct-mention": 0, "team-mention": 1, "mention": 2}[.reason] // 3;
  group_by(.url)
  | map(
      (map(.team_mentioned // empty) | first) as $team
      | (any(.[]; .from_notification == true)) as $notified
      | (sort_by(priority) | first | del(.team_mentioned, .from_notification))
      + (if $team == null then {} else {team_mentioned: $team} end)
      + {from_notification: $notified}
    )' <<<"$CANDIDATES")

fetch_all_pages() {
  gh api "$1" --paginate 2>"$ERR_FILE" | jq -s -c 'add // []'
}

RESULT_LINES=""

while IFS= read -r candidate; do
  [[ -z "$candidate" ]] && continue

  url=$(jq -r '.url' <<<"$candidate")
  owner=$(jq -r '.url | split("/")[3] // ""' <<<"$candidate")
  repo=$(jq -r '.url | split("/")[4] // ""' <<<"$candidate")
  number=$(jq -r '.url | split("/")[6] // ""' <<<"$candidate")

  if [[ ! "$owner" =~ ^[A-Za-z0-9._-]+$ || "$owner" =~ ^\.+$ \
     || ! "$repo" =~ ^[A-Za-z0-9._-]+$ || "$repo" =~ ^\.+$ \
     || ! "$number" =~ ^[0-9]+$ ]]; then
    warn "skipping PR with unexpected URL '$url'"
    continue
  fi

  if ! PR_META=$(gh api "repos/${owner}/${repo}/pulls/${number}" 2>"$ERR_FILE"); then
    warn "could not fetch $url: $(cat "$ERR_FILE")"
    continue
  fi

  if ! KEEP=$(jq -r --arg login "$GH_LOGIN" '
      if type != "object" then error("pulls response is not an object")
      else .state == "open" and ((.user.login // "" | ascii_downcase) != ($login | ascii_downcase)) end' \
      <<<"$PR_META" 2>"$ERR_FILE"); then
    warn "unexpected response for $url, skipping it: $(cat "$ERR_FILE")"
    continue
  fi
  [[ "$KEEP" == "true" ]] || continue

  ACTIVITY="[]"
  ACTIVITY_COMPLETE=true
  for endpoint in "issues/${number}/comments" "pulls/${number}/comments" "pulls/${number}/reviews"; do
    if PAGE=$(fetch_all_pages "repos/${owner}/${repo}/${endpoint}"); then
      ACTIVITY=$(jq -c --argjson b "$PAGE" '
        . + [ $b[]
              | { login: (.user.login // ""),
                  at: (.created_at // .submitted_at),
                  mention_at: (.updated_at // .created_at // .submitted_at),
                  body: (.body // "") }
              | select(.at != null) ]' <<<"$ACTIVITY")
    else
      warn "could not fetch $endpoint for $url, keeping it: $(cat "$ERR_FILE")"
      ACTIVITY_COMPLETE=false
    fi
  done

  ENTRY=$(jq -c -n \
    --argjson candidate "$candidate" \
    --argjson pr "$PR_META" \
    --argjson activity "$ACTIVITY" \
    --argjson teams "$TEAMS" \
    --argjson complete "$ACTIVITY_COMPLETE" \
    --arg login "$GH_LOGIN" \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --arg number "$number" '
    def escape_regex: gsub("(?<c>[.*+?^$(){}|\\[\\]\\\\/])"; "\\\(.c)");
    def strip_code: gsub("```[\\s\\S]*?```"; "") | gsub("`[^`]*`"; "");
    ($login | ascii_downcase) as $me
    | ((["@" + $login] + $teams) | map(escape_regex)
       | "(?<![A-Za-z0-9_.-])(" + join("|") + ")(?![A-Za-z0-9-])") as $mention_re
    | ([ $activity[]
         | select((.login | ascii_downcase) != $me and (.body | strip_code | test($mention_re; "i")))
         | .mention_at ] | max) as $mention_found
    | ($mention_found // $pr.created_at) as $mentioned_at
    | ($mention_found == null and $candidate.from_notification) as $unlocated_notification
    | ([ $activity[] | select((.login | ascii_downcase) == $me) | .at ] | max) as $my_last
    | if $complete and ($unlocated_notification | not) and $my_last != null and $my_last > $mentioned_at then empty
      else
        { url: $candidate.url,
          number: ($number | tonumber),
          owner: $owner,
          repo: $repo,
          title: ($pr.title // ""),
          author: ($pr.user.login // ""),
          reason: $candidate.reason,
          mentioned_at: $mentioned_at,
          updated_at: $pr.updated_at }
        + (if $candidate.team_mentioned then {team_mentioned: $candidate.team_mentioned} else {} end)
      end')

  if [[ -n "$ENTRY" ]]; then
    RESULT_LINES+="${ENTRY}"$'\n'
  fi
done < <(jq -c '.[]' <<<"$DEDUPED")

printf '%s' "$RESULT_LINES" | jq -s -c 'sort_by(.updated_at) | reverse'
