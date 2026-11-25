#!/usr/bin/env bash
# Guards the automatic security audit in /plan-task (Step 6d).
#
# The audit must run during planning, before the acceptance tests and before
# human review, without asking, and its section must reach the plan backup.
# These checks stop a later edit from moving it back to "after approval",
# re-adding the backup scrub, or opening a path that skips it.
#
# Run: bash tests/test-plan-task-security-audit.sh
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

assert_contains() {
  local file="$1" needle="$2"
  if ! grep -qF -- "$needle" "$file"; then
    echo "  FAIL: file $file did not contain: $needle"
    return 1
  fi
}

assert_not_contains() {
  local file="$1" needle="$2"
  if grep -qF -- "$needle" "$file"; then
    echo "  FAIL: file $file still contains: $needle"
    return 1
  fi
}

# Line number of the first line matching a fixed string, or empty.
line_of() {
  grep -nF -- "$2" "$1" | head -1 | cut -d: -f1
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

# Step 6d exists and runs without asking.
test_step_6d_is_automatic() {
  assert_contains "$PLAN_TASK" "### 6d. Security Audit (mandatory, automatic)" || return 1
  assert_contains "$PLAN_TASK" "This step always runs, including when 6a–6c are skipped or stop early" || return 1
  assert_contains "$PLAN_TASK" "Do not ask the human whether to run it" || return 1
}

# Step 6d sits after 6c and before Step 7 (tests) and Step 8 (human review).
test_step_6d_order() {
  local l6c l6d l7 l8
  l6c=$(line_of "$PLAN_TASK" "### 6c.")
  l6d=$(line_of "$PLAN_TASK" "### 6d. Security Audit")
  l7=$(line_of "$PLAN_TASK" "### 7. Define TDD/BDD")
  l8=$(line_of "$PLAN_TASK" "### 8. Human Review")
  [[ -n "$l6c" && -n "$l6d" && -n "$l7" && -n "$l8" ]] || { echo "  FAIL: missing a step heading"; return 1; }
  (( l6c < l6d && l6d < l7 && l7 < l8 )) || { echo "  FAIL: expected 6c < 6d < 7 < 8, got $l6c $l6d $l7 $l8"; return 1; }
}

# The old post-approval audit is gone.
test_no_post_approval_audit() {
  assert_not_contains "$PLAN_TASK" "Only after the human approves** both the plan and the tests: run \`/audit-security\`" || return 1
}

# No step jumps straight to Step 7 past the audit.
test_no_skip_to_step_7() {
  assert_not_contains "$PLAN_TASK" "skip to the top-level Step 7" || return 1
  assert_contains "$PLAN_TASK" "continue with Step 6d (Security Audit)" || return 1
}

# The audit section is kept in the backup, not scrubbed.
test_audit_in_backup() {
  assert_not_contains "$PLAN_TASK" "_Security notes omitted from backup._" || return 1
  assert_contains "$PLAN_TASK" "Keep the \`## Security Audit\` section (Step 6d) in the backup" || return 1
  assert_contains "$PLAN_TASK" "The plan's security audit, including any unfixed findings, is included." || return 1
}

# Consent given before the audit was included doesn't cover it.
test_consent_versioned() {
  assert_contains "$PLAN_TASK" "consent_version" || return 1
  assert_contains "$PLAN_EPIC" "consent_version: 2" || return 1
}

# An accepted risk is never reported as a plain pass.
test_accepted_risk_verdict() {
  assert_contains "$PLAN_TASK" "PASS WITH ACCEPTED RISK (n)" || return 1
}

# /plan-epic relays security decisions to the human.
test_plan_epic_relays_security_decisions() {
  assert_contains "$PLAN_EPIC" "the plan's Security Audit verdict" || return 1
  assert_contains "$PLAN_EPIC" "Only the human can accept a risk by finding ID" || return 1
}

# /critique asks before linking the backup from a public PR.
test_critique_public_repo_check() {
  assert_contains "$CRITIQUE" "gh repo view --json visibility --jq .visibility" || return 1
}

# ── Run ──────────────────────────────────────────────────────────

run_test test_step_6d_is_automatic
run_test test_step_6d_order
run_test test_no_post_approval_audit
run_test test_no_skip_to_step_7
run_test test_audit_in_backup
run_test test_consent_versioned
run_test test_accepted_risk_verdict
run_test test_plan_epic_relays_security_decisions
run_test test_critique_public_repo_check

printf "\n${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf "Failed tests:\n"
  for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
  exit 1
fi
