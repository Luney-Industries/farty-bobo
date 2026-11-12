#!/usr/bin/env bash
# Acceptance tests for the /pr-action-board helper scripts:
#   skills/pr-action-board/scripts/find-mention-prs.sh
#   skills/pr-action-board/scripts/find-thread-reply-prs.sh
#
# The scripts run end to end with real jq (and the real check-pr-threads.sh).
# Only the network boundary is faked: tests/fixtures/pr-action-board/gh is put
# first on PATH and serves responses from tests/fixtures/pr-action-board/api.json.
#
# Fixture scenarios (user kinano, org youth-inc, team @youth-inc/eng):
#   3621  merged, mention answered in an issue comment       -> excluded
#   3537  closed, mention never answered                     -> excluded
#   4001  open, mention answered in an issue comment         -> excluded
#   4002  open, mention answered in a review thread          -> excluded
#   4003  open, mention answered in a review body            -> excluded
#   4004  open, mention after my last comment, unanswered    -> included, mentioned_at = mention time
#   77    other-org, unanswered (notification only)          -> excluded when scoped to youth-inc
#   4006  search mentions: body mention, unanswered          -> included
#   4007  search mentions: answered after the mention        -> excluded
#   4009  search mentions: my own PR                         -> excluded
#   4008  search team:youth-inc/eng, unanswered              -> included (team-mention)
#   3841  commenter: unanswered review-thread reply          -> included
#   3839  commenter: unanswered issue-comment reply          -> included
#   3840  commenter: I had the last word                     -> excluded
#   3850  commenter: my own PR                               -> excluded
#
# Run: bash tests/test-pr-action-board-scripts.sh
#      PR_ACTION_BOARD_STRICT=1 bash tests/test-pr-action-board-scripts.sh   # pending tests count as failures
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/pr-action-board/scripts"
FAKE_GH_DIR="$REPO_ROOT/tests/fixtures/pr-action-board"

LOGIN="kinano"
ORG="youth-inc"
TEAMS_JSON='[{"slug":"eng","name":"Eng","mention":"@youth-inc/eng"}]'

PASS=0
FAIL=0
PENDING=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
OUT="$WORK_DIR/stdout.json"
ERR="$WORK_DIR/stderr.txt"

# ── Runners for the scripts under test ─────────────────────────────────────

run_mention() {
  # $1 = org scope ("" for all orgs)
  PATH="$FAKE_GH_DIR:$PATH" GH_STUB_LOG="$WORK_DIR/gh.log" \
    "$SCRIPTS/find-mention-prs.sh" "$LOGIN" "$1" "$TEAMS_JSON" >"$OUT" 2>"$ERR"
}

run_thread_reply() {
  PATH="$FAKE_GH_DIR:$PATH" GH_STUB_LOG="$WORK_DIR/gh.log" \
    "$SCRIPTS/find-thread-reply-prs.sh" "$LOGIN" "$ORG" >"$OUT" 2>"$ERR"
}

# ── Assertions ─────────────────────────────────────────────────────────────

assert_json_array() {
  if ! jq -e 'type == "array"' "$OUT" >/dev/null 2>&1; then
    echo "  FAIL: stdout is not a JSON array:"
    sed 's/^/    | /' "$OUT" | head -20
    echo "  stderr:"
    sed 's/^/    | /' "$ERR" | head -20
    return 1
  fi
}

# assert_jq <description> <jq expression evaluated against stdout, must yield true>
assert_jq() {
  local desc="$1" expr="$2"
  if ! jq -e "$expr" "$OUT" >/dev/null 2>&1; then
    echo "  FAIL: $desc"
    echo "    expr:   $expr"
    echo "    stdout: $(jq -c '[.[]? | {number, reason, mentioned_at}]' "$OUT" 2>/dev/null || head -c 400 "$OUT")"
    return 1
  fi
}

assert_stderr_contains() {
  local needle="$1"
  if ! grep -qF -- "$needle" "$ERR"; then
    echo "  FAIL: stderr did not contain: $needle"
    echo "  stderr:"
    sed 's/^/    | /' "$ERR" | head -20
    return 1
  fi
}

# ── Test runner ────────────────────────────────────────────────────────────

run_test() {
  local name="$1"
  printf "→ %s\n" "$name"
  if "$name"; then
    PASS=$((PASS + 1))
    printf "  ${GREEN}PASS${RESET}\n"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf "  ${RED}FAIL${RESET}\n"
  fi
}

# Acceptance tests written ahead of the fix. Reported, but not counted as
# failures unless PR_ACTION_BOARD_STRICT=1. The fix PR switches these to run_test.
run_pending() {
  local name="$1"
  if [[ "${PR_ACTION_BOARD_STRICT:-}" == "1" ]]; then
    run_test "$name"
    return
  fi
  printf "→ %s\n" "$name"
  if "$name" >/dev/null; then
    printf "  ${YELLOW}PENDING (already passes; switch to run_test)${RESET}\n"
  else
    printf "  ${YELLOW}PENDING${RESET}\n"
  fi
  PENDING=$((PENDING + 1))
}

# ── find-thread-reply-prs.sh ───────────────────────────────────────────────

test_thread_reply_returns_unresponded_prs() {
  # Given: kinano commented on #3841 (review thread) and #3839 (issue comments) and got replies
  # When
  run_thread_reply
  # Then
  assert_json_array || return 1
  assert_jq "returns #3841 and #3839" '(map(.number) | sort) as $n | ($n | index(3841)) != null and ($n | index(3839)) != null' || return 1
  assert_jq "#3841 is flagged via a review-thread reply from alice" \
    '.[] | select(.number == 3841) | .reason == "thread-reply" and (.review_thread_replies | length) == 1 and .review_thread_replies[0].last_reply_author == "alice"' || return 1
  assert_jq "#3839 is flagged via an issue-comment reply from bob" \
    '.[] | select(.number == 3839) | (.issue_comment_replies | map(.reply_author)) == ["bob"]' || return 1
  assert_jq "entries carry owner/repo" '.[] | select(.number == 3841) | .owner == "youth-inc" and .repo == "youthinc"' || return 1
}

test_thread_reply_excludes_answered_and_own_prs() {
  # Given: kinano had the last word on #3840, and #3850 is kinano's own PR
  # When
  run_thread_reply
  # Then
  assert_json_array || return 1
  assert_jq "result is exactly #3839 and #3841" '(map(.number) | sort) == [3839, 3841]' || return 1
}

test_thread_reply_surfaces_search_errors() {
  # Given: GitHub search is down
  export GH_STUB_FAIL_SEARCH=1
  # When
  run_thread_reply
  unset GH_STUB_FAIL_SEARCH
  # Then
  assert_json_array || return 1
  assert_jq "stdout is an empty array" 'length == 0' || return 1
  assert_stderr_contains "HTTP 503: search is temporarily unavailable" || return 1
}

# ── find-mention-prs.sh ────────────────────────────────────────────────────

test_mention_excludes_merged_and_closed_prs() {
  # Given: notifications for merged #3621 and closed #3537
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#3621 (merged) is not returned" 'map(.number) | index(3621) == null' || return 1
  assert_jq "#3537 (closed) is not returned" 'map(.number) | index(3537) == null' || return 1
  assert_jq "the open unanswered notification PR #4004 is still returned" 'map(.number) | index(4004) != null' || return 1
}

test_mention_mentioned_at_is_actual_mention_time() {
  # Given: on #4004 dave mentioned kinano at 10:00, erin commented (no mention) at 12:00,
  #        and the notification's updated_at is 12:00
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4004 mentioned_at is dave's comment time" \
    '.[] | select(.number == 4004) | .mentioned_at == "2026-11-08T10:00:00Z"' || return 1
  assert_jq "#4004 reason is direct-mention" '.[] | select(.number == 4004) | .reason == "direct-mention"' || return 1
}

test_mention_excludes_pr_answered_in_issue_comment() {
  # Given: on #4001 alice mentioned kinano at 10:00 and kinano replied in an issue comment at 12:00
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4001 is not returned" 'map(.number) | index(4001) == null' || return 1
  assert_jq "#4004 (unanswered) is returned" 'map(.number) | index(4004) != null' || return 1
}

test_mention_excludes_pr_answered_in_review_thread() {
  # Given: on #4002 bob mentioned kinano in an issue comment; kinano replied in a review comment
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4002 is not returned" 'map(.number) | index(4002) == null' || return 1
  assert_jq "#4004 (unanswered) is returned" 'map(.number) | index(4004) != null' || return 1
}

test_mention_excludes_pr_answered_in_review_body() {
  # Given: on #4003 carol mentioned kinano in a review comment; kinano answered in a review body
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4003 is not returned" 'map(.number) | index(4003) == null' || return 1
  assert_jq "#4004 (unanswered) is returned" 'map(.number) | index(4004) != null' || return 1
}

test_mention_respects_org_scope_for_notifications() {
  # Given: an unanswered mention notification on other-org/otherrepo#77
  # When: scoped to youth-inc
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "no other-org PR is returned" 'map(select(.owner == "other-org" or (.url | contains("/other-org/")))) | length == 0' || return 1
  assert_jq "youth-inc PR #4004 is returned" 'map(.number) | index(4004) != null' || return 1
}

test_mention_search_hits_are_normalized_and_checked() {
  # Given: search mentions:kinano returns #4006 (unanswered body mention),
  #        #4007 (answered after the mention), #4009 (kinano's own PR)
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4006 is returned with normalized fields" \
    '.[] | select(.number == 4006) | .owner == "youth-inc" and .repo == "youthinc" and .author == "frank"
       and .url == "https://github.com/youth-inc/youthinc/pull/4006" and .updated_at == "2026-11-09T08:30:00Z"
       and .mentioned_at == "2026-11-09T08:00:00Z" and .reason == "mention"' || return 1
  assert_jq "#4007 (answered) is not returned" 'map(.number) | index(4007) == null' || return 1
  assert_jq "#4009 (own PR) is not returned" 'map(.number) | index(4009) == null' || return 1
}

test_mention_team_search_hit_included() {
  # Given: search team:youth-inc/eng returns #4008, where hank pinged @youth-inc/eng at 09:00
  # When
  run_mention "$ORG"
  # Then
  assert_json_array || return 1
  assert_jq "#4008 is returned as a team mention" \
    '.[] | select(.number == 4008) | .reason == "team-mention" and .team_mentioned == "@youth-inc/eng"
       and .mentioned_at == "2026-11-10T09:00:00Z" and .owner == "youth-inc" and .repo == "youthinc"' || return 1
}

test_mention_surfaces_search_errors() {
  # Given: GitHub search is down (notifications still work)
  export GH_STUB_FAIL_SEARCH=1
  # When
  run_mention "$ORG"
  unset GH_STUB_FAIL_SEARCH
  # Then
  assert_json_array || return 1
  assert_stderr_contains "HTTP 503: search is temporarily unavailable" || return 1
  assert_jq "notification-sourced #4004 is still returned" 'map(.number) | index(4004) != null' || return 1
}

# ── Register ───────────────────────────────────────────────────────────────

run_pending test_thread_reply_returns_unresponded_prs
run_pending test_thread_reply_excludes_answered_and_own_prs
run_pending test_thread_reply_surfaces_search_errors
run_pending test_mention_excludes_merged_and_closed_prs
run_pending test_mention_mentioned_at_is_actual_mention_time
run_pending test_mention_excludes_pr_answered_in_issue_comment
run_pending test_mention_excludes_pr_answered_in_review_thread
run_pending test_mention_excludes_pr_answered_in_review_body
run_pending test_mention_respects_org_scope_for_notifications
run_pending test_mention_search_hits_are_normalized_and_checked
run_pending test_mention_team_search_hit_included
run_pending test_mention_surfaces_search_errors

printf "\n${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d pending${RESET}\n" "$PASS" "$FAIL" "$PENDING"
if (( FAIL > 0 )); then
  printf "Failed tests:\n"
  for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
  exit 1
fi
