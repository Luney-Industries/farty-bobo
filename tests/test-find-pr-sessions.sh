#!/usr/bin/env bash
# Acceptance tests for skills/pr-action-board/scripts/find-pr-sessions.sh
#
# Each test builds a throwaway ~/.claude/projects tree of JSONL transcripts and
# points the script at it with CLAUDE_PROJECTS_DIR. Real perl, jq and git run.
# Transcript cwds point at fixture git repos so repo matching is exercised:
#   $REPO_APP    origin git@github.com:Acme/App.git        (the PR's repo)
#   $REPO_OTHER  origin https://github.com/acme/other.git  (an unrelated repo)
#   $PLAIN_DIR   an existing directory that is not a git repo
#
# PR under test: https://github.com/acme/app/pull/12, head branch
# YOU-1-fix-login, ticket YOU-1.
#
# Run: bash tests/test-find-pr-sessions.sh
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/pr-action-board/scripts/find-pr-sessions.sh"

PR_URL="https://github.com/acme/app/pull/12"
HEAD_REF="YOU-1-fix-login"
TICKET="YOU-1"

PASS=0
FAIL=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

WORK_DIR="$(mktemp -d)"
trap 'chmod -R u+rwx "$WORK_DIR" 2>/dev/null; rm -rf "$WORK_DIR"' EXIT
OUT="$WORK_DIR/stdout.json"
ERR="$WORK_DIR/stderr.txt"
RC=0
PROJECTS=""

# ── Fixture repos ──────────────────────────────────────────────────────────

make_repo() {
  local dir="$1" origin="$2"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin"
}

REPO_APP="$WORK_DIR/repos/app"
REPO_OTHER="$WORK_DIR/repos/other"
PLAIN_DIR="$WORK_DIR/repos/plain"
make_repo "$REPO_APP" "git@github.com:Acme/App.git"
make_repo "$REPO_OTHER" "https://github.com/acme/other.git"
mkdir -p "$PLAIN_DIR"

# ── Fixture builders ───────────────────────────────────────────────────────

fresh_projects() {
  PROJECTS="$WORK_DIR/projects-$RANDOM$RANDOM"
  mkdir -p "$PROJECTS"
}

# transcript <project> <session_id> <agent_name_or_empty> <git_branch> [extra text line...]
# cwd defaults to $REPO_APP; override with CWD=... before the call.
transcript() {
  local project="$1" sid="$2" name="$3" branch="$4"
  shift 4
  local cwd="${CWD:-$REPO_APP}"
  local file="$PROJECTS/$project/$sid.jsonl"
  mkdir -p "$PROJECTS/$project"
  {
    if [[ -n "$name" ]]; then
      jq -cn --arg n "$name" --arg s "$sid" '{type:"agent-name", agentName:$n, sessionId:$s}'
    fi
    jq -cn --arg b "$branch" --arg s "$sid" --arg c "$cwd" \
      '{type:"user", cwd:$c, gitBranch:$b, sessionId:$s, message:{content:"hi"}}'
    local text
    for text in "$@"; do
      jq -cn --arg b "$branch" --arg c "$cwd" --arg t "$text" \
        '{type:"assistant", cwd:$c, gitBranch:$b, message:{content:$t}}'
    done
  } >"$file"
  printf '%s' "$file"
}

# Append raw JSONL lines (built by the caller with jq) to a transcript.
append() {
  local file="$PROJECTS/$1/$2.jsonl"
  shift 2
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" >>"$file"
}

days_ago() {
  date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M
}

run_finder() {
  # $@ = extra env assignments passed through `env`
  RC=0
  env CLAUDE_PROJECTS_DIR="$PROJECTS" "$@" \
    "$SCRIPT" "$PR_URL" "$HEAD_REF" "$TICKET" "${EXCLUDE_NAME-}" "${EXCLUDE_ID-}" >"$OUT" 2>"$ERR" || RC=$?
}

# run_script <args...>: run the script directly with CLAUDE_PROJECTS_DIR=$PROJECTS
run_script() {
  RC=0
  CLAUDE_PROJECTS_DIR="$PROJECTS" "$SCRIPT" "$@" >"$OUT" 2>"$ERR" || RC=$?
}

# ── Assertions ─────────────────────────────────────────────────────────────

assert_jq() {
  local desc="$1" expr="$2"
  if ! jq -e "$expr" "$OUT" >/dev/null 2>&1; then
    echo "  FAIL: $desc"
    echo "    expr:   $expr"
    echo "    stdout: $(head -c 1200 "$OUT")"
    echo "    stderr: $(head -c 400 "$ERR")"
    return 1
  fi
}

assert_rc() {
  if [[ "$RC" != "$1" ]]; then
    echo "  FAIL: exit status $RC, expected $1"
    echo "    stderr: $(head -c 400 "$ERR")"
    return 1
  fi
}

assert_stderr_contains() {
  if ! grep -qF -- "$1" "$ERR"; then
    echo "  FAIL: stderr did not contain: $1"
    sed 's/^/    | /' "$ERR" | head -20
    return 1
  fi
}

assert_stderr_lacks() {
  if grep -qF -- "$1" "$ERR"; then
    echo "  FAIL: stderr unexpectedly contained: $1"
    sed 's/^/    | /' "$ERR" | head -20
    return 1
  fi
}

run_test() {
  local name="$1"
  printf "→ %s\n" "$name"
  fresh_projects
  unset EXCLUDE_NAME EXCLUDE_ID CWD
  if "$name"; then
    PASS=$((PASS + 1))
    printf "  %bPASS%b\n" "$GREEN" "$RESET"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$name")
    printf "  %bFAIL%b\n" "$RED" "$RESET"
  fi
}

# ── Ranking and signals ────────────────────────────────────────────────────

test_session_on_pr_branch_ranks_first_and_strong() {
  # Given: the session that built the PR, and a session that only mentions the ticket
  transcript app owner "YOU-1/fix-the-login-redirect" "$HEAD_REF" "Opened $PR_URL" >/dev/null
  transcript app bystander "other-work" "main" "saw you-1 in standup" >/dev/null
  # When
  run_finder
  # Then
  assert_rc 0 &&
  assert_jq "owner is first" '.[0].session_id == "owner"' &&
  assert_jq "owner is strong with branch+name+pr_url+ticket" \
    '.[0].confidence == "strong" and .[0].signals == ["branch","name","pr_url","ticket"] and .[0].score == 11' &&
  assert_jq "owner repo fields" \
    ".[0].agent_name == \"YOU-1/fix-the-login-redirect\" and .[0].git_branch == \"$HEAD_REF\"
     and .[0].cwd == \"$REPO_APP\" and .[0].last_cwd == \"$REPO_APP\" and .[0].cwd_exists == true
     and .[0].repo == \"acme/app\" and .[0].repo_match == true and .[0].name_kind == \"ticket_prefix\"
     and .[0].custom_title == null and (.[0].last_active | type == \"number\")" &&
  assert_jq "bystander is weak ticket-only" \
    '.[1].session_id == "bystander" and .[1].confidence == "weak" and .[1].signals == ["ticket"]'
}

test_ticket_prefix_name_alone_is_weak() {
  # Given: a same-repo session named after the ticket on a different branch,
  # e.g. the sibling PR of a ticket split across two PRs
  transcript app sibling "you-1/part-two" "YOU-1-part-two" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "name signal, ticket_prefix, weak" \
    '.[0].signals == ["name","ticket"] and .[0].name_kind == "ticket_prefix" and .[0].confidence == "weak"'
}

test_exact_name_in_same_repo_is_strong() {
  # Given: a session named exactly the head branch (different case), never on it
  transcript app named "you-1-FIX-login" "main" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "exact name is strong" \
    '.[0].name_kind == "exact" and .[0].confidence == "strong" and (.[0].signals | index("branch") | not)'
}

test_ticket_prefix_needs_a_separator() {
  # Given: YOU-10 must not match ticket YOU-1
  transcript app ten "YOU-10/other-thing" "YOU-10-other" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "no match" 'length == 0'
}

test_ticket_needs_a_word_boundary_before_it() {
  # Given: XYOU-1 and ayou-1 are not mentions of YOU-1; (YOU-1) is
  transcript app glued "" "main" "see XYOU-1 and ayou-1 and 9YOU-1" >/dev/null
  transcript app paren "" "main" "fixes (YOU-1)" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "only the bounded mention matches" 'map(.session_id) == ["paren"] and .[0].signals == ["ticket"]'
}

test_pr_url_does_not_match_longer_pr_number() {
  # Given: one transcript mentions pull/123, another pull/12
  transcript app longer "" "main" "see https://github.com/acme/app/pull/123" >/dev/null
  transcript app exact "" "main" "see https://github.com/acme/app/pull/12." >/dev/null
  # When
  run_finder
  # Then
  assert_jq "only exact URL matches" 'length == 1 and .[0].session_id == "exact"' &&
  assert_jq "url-only match is weak" '.[0].signals == ["pr_url"] and .[0].confidence == "weak"'
}

test_strong_outranks_higher_scoring_weak() {
  # Given: a weak cross-repo session with every signal (11), and a strong
  # same-repo session with only the branch (+ ticket inside it: 5)
  CWD="$REPO_OTHER" transcript other loud "YOU-1/elsewhere" "$HEAD_REF" "$PR_URL" >/dev/null
  transcript app quiet "" "$HEAD_REF" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "strong first despite lower score" \
    'map(.session_id) == ["quiet","loud"] and .[0].score == 5 and .[1].score == 11 and .[1].confidence == "weak"'
}

test_ties_break_on_recency() {
  # Given: two sessions with the same signals, one older
  local old
  old="$(transcript app older "" "$HEAD_REF")"
  transcript app newer "" "$HEAD_REF" >/dev/null
  touch -t "$(days_ago 2)" "$old"
  # When
  run_finder
  # Then
  assert_jq "newer first" 'map(.session_id) == ["newer","older"]'
}

test_caps_at_ten_candidates() {
  # Given: twelve matching sessions
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    transcript app "s$i" "" "$HEAD_REF" >/dev/null
  done
  # When
  run_finder
  # Then
  assert_jq "ten returned" 'length == 10'
}

# ── Repo matching ──────────────────────────────────────────────────────────

test_same_branch_in_another_repo_is_weak() {
  # Given: an unrelated repo that happens to use the same branch name
  CWD="$REPO_OTHER" transcript other stranger "" "$HEAD_REF" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "branch signal but weak, repo mismatch" \
    '.[0].signals == ["branch","ticket"] and .[0].repo == "acme/other" and .[0].repo_match == false and .[0].confidence == "weak"'
}

test_https_remote_with_trailing_slash_matches() {
  # Given: the PR repo checked out through an https remote with odd casing
  local repo="$WORK_DIR/repos/app-https-$RANDOM"
  make_repo "$repo" "https://github.com/ACME/app/"
  CWD="$repo" transcript app viahttps "" "$HEAD_REF" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "normalised and matched" '.[0].repo == "acme/app" and .[0].repo_match == true and .[0].confidence == "strong"'
}

test_unknown_repo_is_null_and_weak() {
  # Given: a session in a plain directory, and one whose directory is gone
  CWD="$PLAIN_DIR" transcript app plain "" "$HEAD_REF" >/dev/null
  CWD="$WORK_DIR/repos/deleted" transcript app gone "" "$HEAD_REF" >/dev/null
  # When
  run_finder
  # Then
  assert_jq "plain dir: repo unknown" \
    '(.[] | select(.session_id == "plain")) | .repo == null and .repo_match == null and .cwd_exists == true and .confidence == "weak"' &&
  assert_jq "deleted dir: cwd_exists false" \
    '(.[] | select(.session_id == "gone")) | .repo == null and .repo_match == null and .cwd_exists == false and .confidence == "weak"'
}

# ── Field extraction ───────────────────────────────────────────────────────

test_cwd_is_launch_dir_and_last_cwd_is_tracked() {
  # Given: a session launched in the repo that later cd'd into a plain dir
  transcript app mover "" "$HEAD_REF" >/dev/null
  append app mover "$(jq -cn --arg c "$PLAIN_DIR" '{type:"user", cwd:$c, gitBranch:"later-branch"}')"
  # When
  run_finder
  # Then
  assert_jq "launch cwd drives repo, last cwd and branch reported" \
    ".[0].cwd == \"$REPO_APP\" and .[0].last_cwd == \"$PLAIN_DIR\" and .[0].git_branch == \"later-branch\"
     and .[0].repo_match == true and .[0].confidence == \"strong\""
}

test_nested_cwd_and_branch_are_ignored() {
  # Given: nested objects (before the top-level keys) that carry the PR branch
  # and a bogus cwd; the record's own branch is main
  append app nested "$(jq -cn --arg b "$HEAD_REF" --arg c "$REPO_APP" \
    '{toolUseResult:{cwd:"/evil", gitBranch:$b, list:[{gitBranch:$b}]}, cwd:$c, gitBranch:"main", type:"user"}')"
  append app nested "$(jq -cn --arg b "$HEAD_REF" '{type:"user", message:{content:[{cwd:"/evil2", gitBranch:$b}]}}')"
  # nested objects after the top-level keys, with brackets inside strings
  append app nested "$(jq -cn --arg b "$HEAD_REF" --arg c "$REPO_APP" \
    '{type:"user", cwd:$c, gitBranch:"main", toolUseResult:{cwd:"/evil3}", gitBranch:$b, s:"}}]\"{"}}')"
  append app nested "$(jq -cn '{type:"assistant", message:{content:"YOU-1"}}')"
  # When
  run_finder
  # Then
  assert_jq "no branch signal, top-level values only" \
    ".[0].signals == [\"ticket\"] and .[0].cwd == \"$REPO_APP\" and .[0].last_cwd == \"$REPO_APP\" and .[0].git_branch == \"main\""
}

test_json_escapes_in_cwd_are_decoded() {
  # Given: a cwd with a backslash, a quote and a \u escape (written by jq -a)
  local weird="$WORK_DIR/repos/we\\ird \"dir\" é"
  mkdir -p "$weird"
  append app escapes "$(jq -acn --arg c "$weird" --arg b "$HEAD_REF" '{type:"user", cwd:$c, gitBranch:$b}')"
  # When
  run_finder
  # Then
  if ! jq -e --arg w "$weird" '.[0].cwd == $w and .[0].cwd_exists == true' "$OUT" >/dev/null; then
    echo "  FAIL: cwd not decoded: $(head -c 400 "$OUT")"
    return 1
  fi
}

test_non_ascii_names_and_paths_are_utf8() {
  # Given: a session with accents and emoji in its name and cwd, plus a
  # non-ASCII calling session that must be excluded
  local dir="$WORK_DIR/repos/café ✨"
  make_repo "$dir" "git@github.com:acme/app.git"
  CWD="$dir" transcript app accents "YOU-1 café ✨" "$HEAD_REF" >/dev/null
  transcript app self "board-café" "main" "$PR_URL" >/dev/null
  # When
  EXCLUDE_NAME="board-café" run_finder
  # Then
  assert_rc 0 &&
  assert_stderr_lacks "Wide character" &&
  if ! jq -e --arg d "$dir" \
      'map(.session_id) == ["accents"] and .[0].agent_name == "YOU-1 café ✨" and .[0].cwd == $d
       and .[0].name_kind == "ticket_prefix" and .[0].repo_match == true' "$OUT" >/dev/null; then
    echo "  FAIL: non-ASCII output wrong: $(head -c 600 "$OUT")"
    return 1
  fi
}

test_agent_name_and_custom_title_are_separate() {
  # Given: a transcript with only a custom-title, and one renamed twice
  append app titled "$(jq -cn '{type:"custom-title", customTitle:"YOU-1 login fix", sessionId:"titled"}')" \
    "$(jq -cn --arg c "$REPO_APP" '{type:"user", cwd:$c, gitBranch:"main"}')"
  append app renamed "$(jq -cn '{type:"agent-name", agentName:"old-name"}')" \
    "$(jq -cn --arg h "$HEAD_REF" '{type:"agent-name", agentName:$h}')" \
    "$(jq -cn '{type:"custom-title", customTitle:"Nice title"}')" \
    "$(jq -cn --arg c "$REPO_APP" '{type:"user", cwd:$c, gitBranch:"main"}')"
  # When
  run_finder
  # Then
  assert_jq "title is informational only" \
    '(.[] | select(.session_id == "titled")) | .agent_name == null and .custom_title == "YOU-1 login fix" and .signals == ["ticket"] and .name_kind == null' &&
  assert_jq "last agent name wins" \
    "(.[] | select(.session_id == \"renamed\")) | .agent_name == \"$HEAD_REF\" and .custom_title == \"Nice title\" and .name_kind == \"exact\""
}

# ── Exclusions and scope ───────────────────────────────────────────────────

test_excludes_calling_session_by_name() {
  # Given: the session running /pr-action-board mentions the PR and branch
  transcript board self "farty-bobo-fe" "main" "$PR_URL on $HEAD_REF" >/dev/null
  transcript app owner "" "$HEAD_REF" >/dev/null
  # When
  EXCLUDE_NAME="farty-bobo-fe" run_finder
  # Then
  assert_jq "self is excluded" 'map(.session_id) == ["owner"]'
}

test_excludes_calling_session_by_id() {
  # Given: an unnamed calling session that mentions the PR
  transcript board 0000-self-id "" "main" "$PR_URL" >/dev/null
  transcript app owner "" "$HEAD_REF" >/dev/null
  # When
  EXCLUDE_NAME="" EXCLUDE_ID="0000-self-id" run_finder
  # Then
  assert_jq "self is excluded by id" 'map(.session_id) == ["owner"]'
}

test_ignores_subagent_transcripts() {
  # Given: a matching transcript nested under a session's subagents folder
  mkdir -p "$PROJECTS/app/parent/subagents"
  jq -cn --arg b "$HEAD_REF" --arg c "$REPO_APP" '{type:"user", cwd:$c, gitBranch:$b}' \
    >"$PROJECTS/app/parent/subagents/agent-1.jsonl"
  # When
  run_finder
  # Then
  assert_jq "nothing found" 'length == 0'
}

test_skips_transcripts_older_than_max_age() {
  # Given: a matching transcript last touched 30 days ago
  local f
  f="$(transcript app stale "" "$HEAD_REF")"
  touch -t "$(days_ago 30)" "$f"
  # When / Then: default window skips it
  run_finder
  assert_jq "skipped by default" 'length == 0' || return 1
  # When / Then: 0 disables the window
  run_finder PR_SESSIONS_MAX_AGE_DAYS=0
  assert_jq "found with no window" '.[0].session_id == "stale"'
}

test_leading_zero_max_age_is_base_10() {
  # Given: a 30-day-old match and a 3-day-old match
  local f g
  f="$(transcript app stale "" "$HEAD_REF")"
  g="$(transcript app recent "" "$HEAD_REF")"
  touch -t "$(days_ago 30)" "$f"
  touch -t "$(days_ago 3)" "$g"
  # When: 08 days (invalid octal in bash arithmetic)
  run_finder PR_SESSIONS_MAX_AGE_DAYS=08
  # Then: still filters by eight days
  assert_rc 0 &&
  assert_jq "only the recent one" 'map(.session_id) == ["recent"]' &&
  assert_stderr_lacks "value too great"
}

test_bad_max_age_warns_and_uses_default() {
  # Given
  transcript app owner "" "$HEAD_REF" >/dev/null
  # When
  run_finder PR_SESSIONS_MAX_AGE_DAYS=soon
  # Then
  assert_jq "still finds owner" '.[0].session_id == "owner"' &&
  assert_stderr_contains "PR_SESSIONS_MAX_AGE_DAYS must be a whole number"
}

test_empty_ticket_is_allowed() {
  # Given: a PR with no ticket key
  transcript app owner "" "$HEAD_REF" "mentions YOU-1" >/dev/null
  # When
  run_script "$PR_URL" "$HEAD_REF" ""
  # Then
  assert_rc 0 &&
  assert_jq "branch only, no ticket signal" '.[0].signals == ["branch"]'
}

# ── Exit codes and errors ──────────────────────────────────────────────────

test_find_error_warns_and_exits_zero() {
  # Given: one unreadable project folder next to a readable match
  if [[ "$(id -u)" == "0" ]]; then
    echo "  (root ignores permissions; nothing to check)"
    return 0
  fi
  transcript app owner "" "$HEAD_REF" >/dev/null
  mkdir -p "$PROJECTS/locked"
  chmod 000 "$PROJECTS/locked"
  # When
  run_finder
  chmod 755 "$PROJECTS/locked"
  # Then
  assert_rc 0 &&
  assert_jq "readable match still returned" 'map(.session_id) == ["owner"]' &&
  assert_stderr_contains "WARN: find:"
}

test_missing_projects_dir_returns_empty_array() {
  # When
  PROJECTS="$WORK_DIR/nope"
  run_script "$PR_URL" "$HEAD_REF" "$TICKET"
  # Then
  assert_rc 0 &&
  assert_jq "empty array" '. == []' &&
  assert_stderr_contains "WARN: Claude projects dir not found"
}

test_no_transcripts_returns_empty_array() {
  # When
  run_finder
  # Then
  assert_rc 0 &&
  assert_jq "empty array" '. == []'
}

test_invalid_pr_url_is_usage_error() {
  # When
  run_script "https://gitlab.com/acme/app/merge_requests/1" "$HEAD_REF" "$TICKET"
  # Then
  assert_rc 2 &&
  assert_stderr_contains "not a GitHub PR URL"
}

test_missing_arguments_is_usage_error() {
  # When
  run_script "$PR_URL" "$HEAD_REF"
  # Then
  assert_rc 2 &&
  assert_stderr_contains "Usage:"
}

test_empty_head_ref_is_usage_error() {
  # When
  run_script "$PR_URL" "" "$TICKET"
  # Then
  assert_rc 2
}

# ── Batch mode ─────────────────────────────────────────────────────────────

test_batch_returns_every_pr_as_a_key() {
  # Given: owners for two PRs (one without a ticket), a third PR with no owner,
  # and the calling session excluded by id
  transcript app owner12 "" "$HEAD_REF" "$PR_URL" >/dev/null
  transcript app owner13 "" "feature-x" "https://github.com/acme/app/pull/13" >/dev/null
  transcript board self "" "main" "$PR_URL https://github.com/acme/app/pull/13" >/dev/null
  local input
  input="$(jq -cn --arg u "$PR_URL" --arg h "$HEAD_REF" --arg t "$TICKET" '[
    {pr_url:$u, head_ref:$h, ticket:$t},
    {pr_url:"https://github.com/acme/app/pull/13", head_ref:"feature-x", ticket:null},
    {pr_url:"https://github.com/acme/app/pull/14", head_ref:"nobody", ticket:""}
  ]')"
  # When
  RC=0
  printf '%s' "$input" | CLAUDE_PROJECTS_DIR="$PROJECTS" "$SCRIPT" --batch "" self >"$OUT" 2>"$ERR" || RC=$?
  # Then
  assert_rc 0 &&
  assert_jq "three keys" 'keys == ["https://github.com/acme/app/pull/12","https://github.com/acme/app/pull/13","https://github.com/acme/app/pull/14"]' &&
  assert_jq "PR 12 owner" '.["https://github.com/acme/app/pull/12"] | map(.session_id) == ["owner12"] and .[0].signals == ["branch","pr_url","ticket"] and .[0].confidence == "strong"' &&
  assert_jq "PR 13 owner" '.["https://github.com/acme/app/pull/13"] | map(.session_id) == ["owner13"] and .[0].confidence == "strong"' &&
  assert_jq "PR 14 empty" '.["https://github.com/acme/app/pull/14"] == []'
}

test_batch_matches_single_mode() {
  # Given
  transcript app owner "YOU-1/fix" "$HEAD_REF" "$PR_URL" >/dev/null
  transcript app bystander "" "main" "YOU-1" >/dev/null
  run_finder
  local single
  single="$(jq -c . "$OUT")"
  # When
  RC=0
  jq -cn --arg u "$PR_URL" --arg h "$HEAD_REF" --arg t "$TICKET" '[{pr_url:$u, head_ref:$h, ticket:$t}]' \
    | CLAUDE_PROJECTS_DIR="$PROJECTS" "$SCRIPT" --batch >"$OUT" 2>"$ERR" || RC=$?
  # Then
  assert_rc 0 &&
  if ! jq -e --argjson s "$single" --arg u "$PR_URL" '.[$u] == $s' "$OUT" >/dev/null; then
    echo "  FAIL: batch differs from single: $(head -c 600 "$OUT")"
    return 1
  fi
}

test_batch_empty_input_is_empty_object() {
  # When
  RC=0
  echo '[]' | CLAUDE_PROJECTS_DIR="$PROJECTS" "$SCRIPT" --batch >"$OUT" 2>"$ERR" || RC=$?
  # Then
  assert_rc 0 &&
  assert_jq "empty object" '. == {}'
}

test_batch_invalid_input_is_usage_error() {
  local bad
  for bad in 'not json' '{"pr_url":"x"}' '[{"pr_url":"https://example.com/pull/1","head_ref":"a"}]' \
             '[{"pr_url":"https://github.com/a/b/pull/1","head_ref":""}]'; do
    RC=0
    printf '%s' "$bad" | CLAUDE_PROJECTS_DIR="$PROJECTS" "$SCRIPT" --batch >"$OUT" 2>"$ERR" || RC=$?
    assert_rc 2 || { echo "    input: $bad"; return 1; }
  done
}

# ── Main ───────────────────────────────────────────────────────────────────

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  run_test "$t"
done

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
