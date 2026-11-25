#!/usr/bin/env bash
# Acceptance tests for skills/resurrect-claude-sessions/scripts/find-ticket-sessions.sh
#
# Each test builds a throwaway projects tree of JSONL transcripts and points
# the script at it with CLAUDE_PROJECTS_DIR.
#
# Run: bash tests/test-find-ticket-sessions.sh
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/resurrect-claude-sessions/scripts/find-ticket-sessions.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
OUT="$WORK_DIR/out.json"
ERR="$WORK_DIR/err.txt"
PROJECTS=""

fresh_projects() {
  PROJECTS="$WORK_DIR/projects-$RANDOM$RANDOM"
  mkdir -p "$PROJECTS/proj"
}

# transcript <session_id> <branch> <agent_name_or_empty> <text>
transcript() {
  local f="$PROJECTS/proj/$1.jsonl"
  jq -cn --arg cwd "$WORK_DIR" --arg b "$2" --arg t "$4" \
    '{type:"user", message:{role:"user", content:$t}, cwd:$cwd, gitBranch:$b}' > "$f"
  if [[ -n "$3" ]]; then
    jq -cn --arg n "$3" '{type:"agent-name", agentName:$n}' >> "$f"
  fi
}

# run <stdin_json> [exclude_id]; extra env assignments go in RUN_ENV=(K=V ...)
RUN_ENV=()
run() {
  local input="$1"; shift
  RC=0
  printf '%s' "$input" | env CLAUDE_PROJECTS_DIR="$PROJECTS" CLAUDE_CODE_SESSION_ID="" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$SCRIPT" "$@" > "$OUT" 2> "$ERR" || RC=$?
}

days_ago() {
  date -v-"$1"d +%Y%m%d%H%M 2>/dev/null || date -d "$1 days ago" +%Y%m%d%H%M
}

pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); FAILED_TESTS+=("$1"); echo "  FAIL  $1"; cat "$OUT" "$ERR" | sed 's/^/        /'; }
check_rc() { if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1 (rc=$RC, want $2)"; fi; }
check_stderr() { if grep -qF -- "$2" "$ERR"; then pass "$1"; else fail "$1"; fi; }

check() {
  local name="$1" expr="$2"
  if jq -e "$expr" "$OUT" > /dev/null 2>&1; then
    PASS=$((PASS + 1)); echo "  PASS  $name"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name"); echo "  FAIL  $name"; cat "$OUT" "$ERR" | sed 's/^/        /'
  fi
}

IN='[{"ticket":"YOU-1","branch":"kf/you-1-fix-login"},{"ticket":"you-20"}]'

echo "branch signal (exact branch and ticket key in branch)"
fresh_projects
transcript s-exact "kf/you-1-fix-login" "" "hello"
transcript s-token "someone/YOU-20-other" "" "hello"
run "$IN"
check "exact branch is strong" '.["YOU-1"][0] | .session_id == "s-exact" and .confidence == "strong" and (.signals | index("branch"))'
check "lowercase input key is uppercased; key in branch is strong" '.["YOU-20"][0] | .session_id == "s-token" and .confidence == "strong"'

echo "name signal"
fresh_projects
transcript s-name "main" "YOU-1/fix-login" "hello"
run "$IN"
check "agent_name with ticket key is strong" '.["YOU-1"][0] | .session_id == "s-name" and .agent_name == "YOU-1/fix-login" and (.signals | index("name"))'

echo "mention signal and ordering"
fresh_projects
transcript s-mention "main" "" "looked at YOU-1 briefly"
transcript s-strong "kf/you-1-fix-login" "" "work"
run "$IN"
check "mention-only is weak" '[.["YOU-1"][] | select(.session_id == "s-mention")][0].confidence == "weak"'
check "strong sorts before weak" '.["YOU-1"][0].session_id == "s-strong"'
check "ticket with no hits is an empty array" '.["YOU-20"] == []'

echo "token boundaries"
fresh_projects
transcript s-ten "main" "" "YOU-10 and XYOU-1 and YOU-100"
run "$IN"
check "YOU-1 does not match YOU-10 / XYOU-1" '.["YOU-1"] == []'

echo "triage sessions are dropped"
fresh_projects
transcript s-triage "main" "" "board: YOU-1 YOU-20 YOU-30"
run '[{"ticket":"YOU-1"},{"ticket":"YOU-20"},{"ticket":"YOU-30"}]'
check "mention-only in a 3+ ticket transcript is dropped" '.["YOU-1"] == [] and .["YOU-30"] == []'

echo "self exclusion"
fresh_projects
transcript s-self "kf/you-1-fix-login" "" "x"
run "$IN" "s-self"
check "explicit exclude id skips transcript" '.["YOU-1"] == []'
RC=0
printf '%s' "$IN" | CLAUDE_PROJECTS_DIR="$PROJECTS" CLAUDE_CODE_SESSION_ID="s-self" "$SCRIPT" > "$OUT" 2> "$ERR" || RC=$?
check "CLAUDE_CODE_SESSION_ID is the default exclude" '.["YOU-1"] == []'

echo "edge cases"
PROJECTS="$WORK_DIR/does-not-exist"
run "$IN"
check "missing projects dir returns empty keys" '.["YOU-1"] == [] and .["YOU-20"] == []'
fresh_projects
run '[{"ticket":"not a key"}]'
if [[ "$RC" == 2 ]]; then PASS=$((PASS + 1)); echo "  PASS  bad input exits 2"
else FAIL=$((FAIL + 1)); FAILED_TESTS+=("bad input exits 2"); echo "  FAIL  bad input exits 2 (rc=$RC)"; fi

echo "custom_title name signal"
fresh_projects
transcript s-title "main" "" "hello"
jq -cn '{type:"custom-title", customTitle:"Fix login (you-20)"}' >> "$PROJECTS/proj/s-title.jsonl"
run "$IN"
check "custom_title with ticket key is strong" '.["YOU-20"][0] | .session_id == "s-title" and .custom_title == "Fix login (you-20)" and .confidence == "strong" and (.signals | index("name"))'

echo "cap and ordering"
fresh_projects
for i in 1 2 3 4 5 6 7; do
  transcript "s-cap$i" "main" "" "YOU-1 mention $i"
  touch -t "$(days_ago "$i")" "$PROJECTS/proj/s-cap$i.jsonl"
done
run "$IN"
check "at most 5 candidates per ticket" '.["YOU-1"] | length == 5'
check "equal scores sort most recent first" '[.["YOU-1"][].session_id] == ["s-cap1","s-cap2","s-cap3","s-cap4","s-cap5"]'

echo "strong candidate in a 3+ ticket transcript is kept"
fresh_projects
transcript s-busy "kf/you-1-fix-login" "" "YOU-1 YOU-20 YOU-30"
transcript s-triage2 "main" "" "board: YOU-1 YOU-20 YOU-30"
run '[{"ticket":"YOU-1","branch":"kf/you-1-fix-login"},{"ticket":"YOU-20"},{"ticket":"YOU-30"}]'
check "strong candidate kept despite 3 mentions" '.["YOU-1"] == [.["YOU-1"][0]] and .["YOU-1"][0].session_id == "s-busy" and .["YOU-1"][0].mentions == 3'
check "its mention-only matches are dropped" '.["YOU-20"] == [] and .["YOU-30"] == []'
check_stderr "dropped triage candidates are counted on stderr" "NOTE: dropped 5 mention-only triage candidates"

echo "RCS_MAX_AGE_DAYS"
fresh_projects
transcript s-new "kf/you-1-fix-login" "" "x"
transcript s-old "kf/you-1-fix-login" "" "x"
touch -t "$(days_ago 40)" "$PROJECTS/proj/s-old.jsonl"
run "$IN"
check "default 30 days skips a 40-day-old transcript" '[.["YOU-1"][].session_id] == ["s-new"]'
RUN_ENV=(RCS_MAX_AGE_DAYS=0); run "$IN"; RUN_ENV=()
check "RCS_MAX_AGE_DAYS=0 scans everything" '[.["YOU-1"][].session_id] | sort == ["s-new","s-old"]'
RUN_ENV=(RCS_MAX_AGE_DAYS=50); run "$IN"; RUN_ENV=()
check "RCS_MAX_AGE_DAYS=50 includes the old transcript" '.["YOU-1"] | length == 2'
RUN_ENV=(RCS_MAX_AGE_DAYS=abc); run "$IN"; RUN_ENV=()
check "invalid RCS_MAX_AGE_DAYS falls back to 30" '[.["YOU-1"][].session_id] == ["s-new"]'
check_stderr "invalid RCS_MAX_AGE_DAYS warns" "WARN: RCS_MAX_AGE_DAYS must be a whole number"

echo "branch case and layout"
fresh_projects
transcript s-case "KF/Other-Name" "" "x"
run '[{"ticket":"YOU-1","branch":"kf/other-name"}]'
check "exact branch match ignores case" '.["YOU-1"][0] | .session_id == "s-case" and (.signals | index("branch"))'
fresh_projects
mkdir -p "$PROJECTS/proj/s-parent/subagents"
jq -cn '{type:"user", message:{content:"YOU-1"}, cwd:"/x", gitBranch:"kf/you-1-fix-login"}' \
  > "$PROJECTS/proj/s-parent/subagents/agent-1.jsonl"
run "$IN"
check "transcripts in deeper subfolders are ignored" '.["YOU-1"] == []'

echo "duplicate tickets"
fresh_projects
transcript s-dup "kf/you-1-fix-login" "" "x"
run '[{"ticket":"you-1"},{"ticket":"YOU-1","branch":"kf/you-1-fix-login"},{"ticket":"YOU-1","branch":"other"}]'
check "duplicates collapse to one key and one candidate" 'keys == ["YOU-1"] and (.["YOU-1"] | length == 1)'
fresh_projects
transcript s-dup2 "custom-branch-name" "" "x"
run '[{"ticket":"YOU-1"},{"ticket":"you-1","branch":"custom-branch-name"}]'
check "first non-empty branch is kept" '.["YOU-1"][0] | .session_id == "s-dup2" and (.signals | index("branch"))'

echo "mention in body before cwd"
fresh_projects
jq -cn '{type:"assistant", message:{content:"working on YOU-20 now"}, cwd:"/x", gitBranch:"main"}' \
  > "$PROJECTS/proj/s-body.jsonl"
run "$IN"
check "ticket in body before cwd/gitBranch is a mention" '.["YOU-20"][0] | .session_id == "s-body" and .signals == ["mention"]'

echo "underscore keys"
fresh_projects
transcript s-under "main" "" "see MY_PROJ-1 today"
run '[{"ticket":"my_proj-1"},{"ticket":"PROJ-1"}]'
check "underscore key is accepted and matched" '.["MY_PROJ-1"][0].session_id == "s-under"'
check "PROJ-1 does not match inside MY_PROJ-1" '.["PROJ-1"] == []'
fresh_projects
transcript s-proj "main" "" "see (PROJ-1) and MY_PROJ-1"
run '[{"ticket":"PROJ-1"}]'
check "PROJ-1 still matches on its own boundary" '.["PROJ-1"][0].session_id == "s-proj"'

echo "scan failure"
fresh_projects
transcript s-x "kf/you-1-fix-login" "" "x"
RUN_ENV=(PERL5OPT=-MNoSuchMod); run "$IN"; RUN_ENV=()
check_rc "perl failure exits 1" 1
if [[ ! -s "$OUT" ]]; then pass "perl failure prints nothing on stdout"; else fail "perl failure prints nothing on stdout"; fi
check_stderr "perl failure reports ERROR" "ERROR: transcript scan failed"

echo
echo "Passed: $PASS  Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then printf '  - %s\n' "${FAILED_TESTS[@]}"; exit 1; fi
