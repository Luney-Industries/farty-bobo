#!/usr/bin/env bash
# Acceptance tests for Linear.app support added to skill files.
#
# Tests verify that the required Linear-related content exists in the skill
# markdown files modified or created as part of the add-linear-app-support branch.
#
# Run: bash tests/test-linear-support.sh
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

# ── Assertions ───────────────────────────────────────────────────

assert_file_exists() {
  [[ -f "$1" ]] || { echo "  FAIL: expected file to exist: $1"; return 1; }
}

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "  FAIL: file $file did not contain: $needle"
    return 1
  fi
}

# ── Test runner ──────────────────────────────────────────────────

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

# ── Test cases ───────────────────────────────────────────────────

PLAN_TASK="$REPO_ROOT/skills/plan-task/SKILL.md"
PLAN_EPIC="$REPO_ROOT/skills/plan-epic/SKILL.md"
CRITIQUE="$REPO_ROOT/skills/critique/SKILL.md"
CREATE_LINEAR="$REPO_ROOT/skills/create-linear-ticket/SKILL.md"

# T-1: plan-task Step 1 lists Linear issue ID as an accepted source
test_plan_task_step1_linear_source() {
  assert_file_exists "$PLAN_TASK" || return 1
  assert_contains "$PLAN_TASK" "Linear issue ID" || return 1
}

# T-2: plan-task Step 2 includes source system detection rule for linear.app URLs
test_plan_task_step2_linear_url_detection() {
  assert_file_exists "$PLAN_TASK" || return 1
  assert_contains "$PLAN_TASK" "linear.app" || return 1
}

# T-3: plan-task Step 2 includes bare ID disambiguation logic
test_plan_task_step2_bare_id_disambiguation() {
  assert_file_exists "$PLAN_TASK" || return 1
  assert_contains "$PLAN_TASK" "Is \`{ID}\` a Jira or Linear ticket?" || return 1
}

# T-4: plan-task Step 2 references LINEAR_API_KEY for missing connector
test_plan_task_step2_linear_api_key() {
  assert_file_exists "$PLAN_TASK" || return 1
  assert_contains "$PLAN_TASK" "LINEAR_API_KEY" || return 1
}

# T-5: plan-task Step 2 specifies Linear plan file naming convention
test_plan_task_step2_linear_plan_naming() {
  assert_file_exists "$PLAN_TASK" || return 1
  assert_contains "$PLAN_TASK" "plans/<linear-id>.plan.md" || return 1
}

# T-6: plan-epic Step 1 accepts Linear project URL or issue identifier
test_plan_epic_step1_linear_source() {
  assert_file_exists "$PLAN_EPIC" || return 1
  assert_contains "$PLAN_EPIC" "Linear project URL or issue identifier" || return 1
}

# T-7: plan-epic Step 1 includes source system detection rule
test_plan_epic_step1_detection_rule() {
  assert_file_exists "$PLAN_EPIC" || return 1
  assert_contains "$PLAN_EPIC" "Source system detection rule" || return 1
}

# T-8: critique Step 8 includes Linear workflow state transition via mcp__linear__save_issue
test_critique_step8_linear_transition() {
  assert_file_exists "$CRITIQUE" || return 1
  assert_contains "$CRITIQUE" "mcp__linear__save_issue" || return 1
}

# T-9: critique Step 9 includes Linear comment posting via mcp__linear__save_comment
test_critique_step9_linear_comment() {
  assert_file_exists "$CRITIQUE" || return 1
  assert_contains "$CRITIQUE" "mcp__linear__save_comment" || return 1
}

# T-10: create-linear-ticket/SKILL.md exists and contains mcp__linear__save_issue call
test_create_linear_ticket_skill_exists() {
  assert_file_exists "$CREATE_LINEAR" || return 1
  assert_contains "$CREATE_LINEAR" "mcp__linear__save_issue" || return 1
}

# ── Run ──────────────────────────────────────────────────────────

run_test test_plan_task_step1_linear_source
run_test test_plan_task_step2_linear_url_detection
run_test test_plan_task_step2_bare_id_disambiguation
run_test test_plan_task_step2_linear_api_key
run_test test_plan_task_step2_linear_plan_naming
run_test test_plan_epic_step1_linear_source
run_test test_plan_epic_step1_detection_rule
run_test test_critique_step8_linear_transition
run_test test_critique_step9_linear_comment
run_test test_create_linear_ticket_skill_exists

printf "\n${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf "Failed tests:\n"
  for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
  exit 1
fi
