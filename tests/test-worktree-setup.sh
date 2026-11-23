#!/usr/bin/env bash
# Tests for the canonical worktree blocks shared by /build and /plan-task.
#
# The blocks between the `# >>> <name>` and `# <<< <name>` markers in
# skills/build/SKILL.md are canonical. skills/plan-task/SKILL.md must carry
# byte-identical copies, and the worktree-setup block must create worktrees
# safely in throwaway repos.
#
# Run: bash tests/test-worktree-setup.sh
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

BUILD="$REPO_ROOT/skills/build/SKILL.md"
PLAN="$REPO_ROOT/skills/plan-task/SKILL.md"
BLOCKS=(default-branch worktree-setup)

SCRATCH="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$SCRATCH"' EXIT

# ── Helpers ──────────────────────────────────────────────────────

extract_block() {
  awk -v name="$2" '
    $0 ~ "^# >>> " name "( |$)" {on=1}
    on {print}
    on && $0 ~ "^# <<< " name "$" {exit}
  ' "$1"
}

SHELLS=(bash)
command -v zsh >/dev/null 2>&1 && SHELLS+=(zsh)

# Builds an origin repo with one commit on main and a clone of it at $1/clone.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git init --quiet --bare --initial-branch=main "$dir/origin.git"
  git clone --quiet "$dir/origin.git" "$dir/clone" 2>/dev/null
  git -C "$dir/clone" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m init
  git -C "$dir/clone" push --quiet origin main 2>/dev/null
  git -C "$dir/clone" remote set-head origin main >/dev/null
}

# Runs the canonical block with BRANCH_NAME/EXISTING_BRANCH filled in.
run_block() {
  local sh="$1" dir="$2" branch="$3" existing="${4:-no}" block
  block="$(extract_block "$BUILD" worktree-setup)"
  block="${block/BRANCH_NAME=\'<branch-name>\'/BRANCH_NAME='$branch'}"
  block="${block/EXISTING_BRANCH=\'no\'/EXISTING_BRANCH='$existing'}"
  (cd "$dir" && "$sh" -c "$block")
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

# T-1: every canonical block exists in /build, is closed, and matches /plan-task byte for byte
test_blocks_in_sync() {
  local name canonical ok=0
  for name in "${BLOCKS[@]}"; do
    canonical="$(extract_block "$BUILD" "$name")"
    [[ -n "$canonical" ]] || { echo "  FAIL: no $name block in skills/build/SKILL.md"; ok=1; continue; }
    [[ "$(tail -n1 <<<"$canonical")" == "# <<< $name" ]] || { echo "  FAIL: $name block in skills/build/SKILL.md is not closed"; ok=1; }
    [[ "$(extract_block "$PLAN" "$name")" == "$canonical" ]] || { echo "  FAIL: $name block missing or drifted in skills/plan-task/SKILL.md"; ok=1; }
  done
  return "$ok"
}

# T-2: creates the worktree at the slug path, untracked, on origin/main, and ignored
test_creates_worktree() {
  local sh d out wt ok=0
  for sh in "${SHELLS[@]}"; do
    d="$SCRATCH/create-$sh"; make_repo "$d"
    out="$(run_block "$sh" "$d/clone" kinano/foo 2>&1)" || { echo "  FAIL ($sh): block failed: $out"; ok=1; continue; }
    wt="$d/clone/.claude/worktrees/kinano-foo"
    [[ "$out" == *"WORKTREE_PATH=$wt"* ]] || { echo "  FAIL ($sh): unexpected output: $out"; ok=1; }
    [[ "$(git -C "$wt" branch --show-current)" == kinano/foo ]] || { echo "  FAIL ($sh): worktree not on kinano/foo"; ok=1; }
    [[ -z "$(git -C "$wt" for-each-ref --format='%(upstream)' refs/heads/kinano/foo)" ]] || { echo "  FAIL ($sh): branch tracks an upstream"; ok=1; }
    [[ -z "$(git -C "$d/clone" status --porcelain)" ]] || { echo "  FAIL ($sh): main checkout not clean"; ok=1; }
    [[ "$(git -C "$d/clone" branch --show-current)" == main ]] || { echo "  FAIL ($sh): main checkout left main"; ok=1; }
  done
  return "$ok"
}

# T-3: branches from origin/main even when local main is stale
test_branches_from_fresh_origin() {
  local d other want
  d="$SCRATCH/fresh"; make_repo "$d"
  git clone --quiet "$d/origin.git" "$d/other" 2>/dev/null
  git -C "$d/other" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m newer
  git -C "$d/other" push --quiet origin main 2>/dev/null
  want="$(git -C "$d/other" rev-parse HEAD)"
  run_block bash "$d/clone" kinano/fresh >/dev/null 2>&1 || { echo "  FAIL: block failed"; return 1; }
  [[ "$(git -C "$d/clone" rev-parse kinano/fresh)" == "$want" ]] || { echo "  FAIL: branch not cut from latest origin/main"; return 1; }
}

# T-4: refuses taken paths and names without leaving orphan branches
test_refuses_collisions() {
  local d ok=0
  d="$SCRATCH/collide"; make_repo "$d"
  run_block bash "$d/clone" a-b/c >/dev/null 2>&1 || { echo "  FAIL: first create failed"; return 1; }
  run_block bash "$d/clone" a/b-c >/dev/null 2>&1 && { echo "  FAIL: slug collision was not refused"; ok=1; }
  git -C "$d/clone" show-ref --verify --quiet refs/heads/a/b-c && { echo "  FAIL: orphan branch a/b-c left behind"; ok=1; }
  git -C "$d/clone" worktree remove "$d/clone/.claude/worktrees/a-b-c"
  run_block bash "$d/clone" a-b/c >/dev/null 2>&1 && { echo "  FAIL: existing branch reused without EXISTING_BRANCH=yes"; ok=1; }
  return "$ok"
}

# T-5: EXISTING_BRANCH=yes puts an existing branch into a worktree
test_existing_branch() {
  local d
  d="$SCRATCH/existing"; make_repo "$d"
  git -C "$d/clone" branch kinano/old
  run_block bash "$d/clone" kinano/old yes >/dev/null 2>&1 || { echo "  FAIL: block failed"; return 1; }
  [[ "$(git -C "$d/clone/.claude/worktrees/kinano-old" branch --show-current)" == kinano/old ]] || { echo "  FAIL: worktree not on kinano/old"; return 1; }
  run_block bash "$d/clone" kinano/missing yes >/dev/null 2>&1 && { echo "  FAIL: missing branch not refused"; return 1; }
  return 0
}

# T-6: refuses an unfilled placeholder and the default branch
test_refuses_bad_names() {
  local d ok=0
  d="$SCRATCH/bad"; make_repo "$d"
  run_block bash "$d/clone" '<branch-name>' >/dev/null 2>&1 && { echo "  FAIL: placeholder accepted"; ok=1; }
  run_block bash "$d/clone" main >/dev/null 2>&1 && { echo "  FAIL: default branch accepted"; ok=1; }
  [[ -z "$(git -C "$d/clone" worktree list --porcelain | sed -n '2,$p' | grep '^worktree')" ]] || { echo "  FAIL: a worktree was created"; ok=1; }
  return "$ok"
}

# T-7: run from inside a linked worktree, it still targets the main checkout
test_from_inside_worktree() {
  local d
  d="$SCRATCH/inside"; make_repo "$d"
  run_block bash "$d/clone" kinano/one >/dev/null 2>&1 || { echo "  FAIL: first create failed"; return 1; }
  run_block bash "$d/clone/.claude/worktrees/kinano-one" kinano/two >/dev/null 2>&1 || { echo "  FAIL: create from inside worktree failed"; return 1; }
  [[ -d "$d/clone/.claude/worktrees/kinano-two" ]] || { echo "  FAIL: second worktree not under the main checkout"; return 1; }
}

# T-8: the exclude entry lands on its own line even without a trailing newline
test_exclude_newline() {
  local d
  d="$SCRATCH/newline"; make_repo "$d"
  printf 'foo' > "$d/clone/.git/info/exclude"
  run_block bash "$d/clone" kinano/nl >/dev/null 2>&1 || { echo "  FAIL: block failed"; return 1; }
  grep -qx 'foo' "$d/clone/.git/info/exclude" && grep -qx '/.claude/worktrees/' "$d/clone/.git/info/exclude" || { echo "  FAIL: exclude entries merged: $(cat "$d/clone/.git/info/exclude")"; return 1; }
}

# ── Run ──────────────────────────────────────────────────────────

run_test test_blocks_in_sync
run_test test_creates_worktree
run_test test_branches_from_fresh_origin
run_test test_refuses_collisions
run_test test_existing_branch
run_test test_refuses_bad_names
run_test test_from_inside_worktree
run_test test_exclude_newline

printf "\n${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf "Failed tests:\n"
  for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
  exit 1
fi
