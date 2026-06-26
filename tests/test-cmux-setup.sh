#!/usr/bin/env bash
# Acceptance tests for cmux/setup.sh — migrating cmux/ghostty config off Google
# Drive and into this repo, with sanitized templates and generated runtime files.
#
# Run: bash tests/test-cmux-setup.sh
# Exits 0 on all-pass, non-zero on any failure.
#
# Written BEFORE the implementation — expected to FAIL until cmux/setup.sh and the
# cmux/ tree exist per plans/add-cmux-config.plan.md.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# ── Sandbox helpers ──────────────────────────────────────────────

make_sandbox() {
  local sb
  sb=$(mktemp -d -t farty-cmux-test.XXXXXX)
  mkdir -p "$sb/home"
  cp -R "$REPO_ROOT" "$sb/repo"
  rm -rf "$sb/repo/.git"
  echo "$sb"
}

run_setup() {
  local sb="$1"; shift
  local shell_bin="${1:-/bin/zsh}"; shift || true
  HOME="$sb/home" SHELL="$shell_bin" bash "$sb/repo/cmux/setup.sh" "$@" \
    >"$sb/setup.out" 2>"$sb/setup.err"
}

# ── Assertions ───────────────────────────────────────────────────
assert_file_exists()      { [[ -f "$1" ]] || { echo "  FAIL: expected file: $1"; return 1; }; }
assert_no_file()          { [[ ! -f "$1" ]] || { echo "  FAIL: file should not exist: $1"; return 1; }; }
assert_is_symlink()       { [[ -L "$1" ]] || { echo "  FAIL: expected symlink: $1"; return 1; }; }
assert_executable()       { [[ -x "$1" ]] || { echo "  FAIL: expected executable: $1"; return 1; }; }
assert_link_target()      {
  local tgt; tgt="$(readlink "$1" 2>/dev/null || true)"
  [[ "$tgt" == *"$2"* ]] || { echo "  FAIL: link $1 -> '$tgt' (expected to contain '$2')"; return 1; }
}
assert_file_contains()    { grep -qF -- "$2" "$1" 2>/dev/null || { echo "  FAIL: $1 missing: $2"; return 1; }; }
assert_file_not_contain() { ! grep -qF -- "$2" "$1" 2>/dev/null || { echo "  FAIL: $1 should not contain: $2"; return 1; }; }
assert_output_contains()  {
  grep -qF -- "$2" "$1/setup.err" "$1/setup.out" 2>/dev/null \
    || { echo "  FAIL: setup output missing: $2"; return 1; }
}

run_test() {
  local name="$1"; shift
  if "$@"; then
    echo -e "${GREEN}PASS${RESET}: $name"; ((PASS++))
  else
    echo -e "${RED}FAIL${RESET}: $name"; ((FAIL++)); FAILED_TESTS+=("$name")
  fi
}

# ── Tests ────────────────────────────────────────────────────────

# AC-1: only .template files (and .gitignore) exist in the committed repo tree.
#       Non-template generated files must not be accidentally tracked.
test_only_templates_committed() {
  local configs="$REPO_ROOT/cmux/configs"
  local bin="$REPO_ROOT/cmux/bin"
  assert_file_exists "$configs/cmux.json.template"          || return 1
  assert_file_exists "$configs/ghostty.template"            || return 1
  assert_file_exists "$configs/.gitignore"                  || return 1
  assert_no_file     "$configs/cmux.json"                   || return 1
  assert_no_file     "$configs/ghostty"                     || return 1
  assert_file_exists "$bin/youth-workspace.sh.template"     || return 1
  assert_file_exists "$bin/.gitignore"                      || return 1
  assert_no_file     "$bin/youth-workspace.sh"              || return 1
}

# AC-2: generated ghostty contains the --cwd value, not the placeholder.
test_ghostty_substitution() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /my/project/path
  local generated="$sb/repo/cmux/configs/ghostty"
  assert_file_exists      "$generated"                          || { rm -rf "$sb"; return 1; }
  assert_file_contains    "$generated" "/my/project/path"       || { rm -rf "$sb"; return 1; }
  assert_file_not_contain "$generated" "{{WORKING_DIRECTORY}}"  || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-3: without --cwd, setup warns and generates a ghostty with $HOME as fallback.
test_ghostty_default_cwd() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh
  assert_output_contains  "$sb" "working-directory"               || { rm -rf "$sb"; return 1; }
  local generated="$sb/repo/cmux/configs/ghostty"
  assert_file_exists      "$generated"                            || { rm -rf "$sb"; return 1; }
  assert_file_not_contain "$generated" "{{WORKING_DIRECTORY}}"   || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-4: cmux.json generated as a straight copy of the template.
test_cmux_json_generated() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  assert_file_exists "$sb/repo/cmux/configs/cmux.json" || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-5: youth-workspace.sh generated and executable.
test_generates_executable_script() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  assert_file_exists "$sb/repo/cmux/bin/youth-workspace.sh" || { rm -rf "$sb"; return 1; }
  assert_executable  "$sb/repo/cmux/bin/youth-workspace.sh" || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-6: ~/.config/cmux/cmux.json symlinks to the generated file in the repo.
test_symlink_cmux_json() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  assert_is_symlink  "$sb/home/.config/cmux/cmux.json"                          || { rm -rf "$sb"; return 1; }
  assert_link_target "$sb/home/.config/cmux/cmux.json" "cmux/configs/cmux.json" || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-7: ~/.config/ghostty/config symlinks to the generated ghostty in the repo.
test_symlink_ghostty() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  assert_is_symlink  "$sb/home/.config/ghostty/config"                           || { rm -rf "$sb"; return 1; }
  assert_link_target "$sb/home/.config/ghostty/config" "cmux/configs/ghostty"    || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-8: cmux-workspace alias lands in ~/.zshrc pointing at the generated script.
test_alias_installed() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  assert_file_contains "$sb/home/.zshrc" "alias cmux-workspace="       || { rm -rf "$sb"; return 1; }
  assert_file_contains "$sb/home/.zshrc" "cmux/bin/youth-workspace.sh" || { rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-9: re-running does not duplicate the alias.
test_alias_idempotent() {
  local sb; sb=$(make_sandbox)
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  run_setup "$sb" /bin/zsh --cwd /tmp/work
  local n; n=$(grep -c "alias cmux-workspace=" "$sb/home/.zshrc" 2>/dev/null || echo 0)
  [[ "$n" -eq 1 ]] || { echo "  FAIL: expected 1 alias line, found $n"; rm -rf "$sb"; return 1; }
  rm -rf "$sb"
}

# AC-10: configs/.gitignore enforces * / !*.template / !.gitignore.
test_configs_gitignore() {
  local gi="$REPO_ROOT/cmux/configs/.gitignore"
  assert_file_exists "$gi" || return 1
  local sb; sb=$(mktemp -d -t farty-cmux-gi.XXXXXX)
  mkdir -p "$sb/cmux/configs"
  cp "$gi" "$sb/cmux/configs/.gitignore"
  : > "$sb/cmux/configs/ghostty"
  : > "$sb/cmux/configs/cmux.json"
  : > "$sb/cmux/configs/ghostty.template"
  : > "$sb/cmux/configs/cmux.json.template"
  ( cd "$sb" && git init --quiet )
  ( cd "$sb" && git check-ignore -q cmux/configs/ghostty ) \
    || { echo "  FAIL: ghostty should be ignored"; rm -rf "$sb"; return 1; }
  ( cd "$sb" && git check-ignore -q cmux/configs/cmux.json ) \
    || { echo "  FAIL: cmux.json should be ignored"; rm -rf "$sb"; return 1; }
  if ( cd "$sb" && git check-ignore -q cmux/configs/ghostty.template ); then
    echo "  FAIL: ghostty.template must NOT be ignored"; rm -rf "$sb"; return 1
  fi
  if ( cd "$sb" && git check-ignore -q cmux/configs/cmux.json.template ); then
    echo "  FAIL: cmux.json.template must NOT be ignored"; rm -rf "$sb"; return 1
  fi
  rm -rf "$sb"
}

# AC-11: bin/.gitignore enforces * / !*.template / !.gitignore.
test_bin_gitignore() {
  local gi="$REPO_ROOT/cmux/bin/.gitignore"
  assert_file_exists "$gi" || return 1
  local sb; sb=$(mktemp -d -t farty-cmux-gi.XXXXXX)
  mkdir -p "$sb/cmux/bin"
  cp "$gi" "$sb/cmux/bin/.gitignore"
  : > "$sb/cmux/bin/youth-workspace.sh"
  : > "$sb/cmux/bin/youth-workspace.sh.template"
  ( cd "$sb" && git init --quiet )
  ( cd "$sb" && git check-ignore -q cmux/bin/youth-workspace.sh ) \
    || { echo "  FAIL: youth-workspace.sh should be ignored"; rm -rf "$sb"; return 1; }
  if ( cd "$sb" && git check-ignore -q cmux/bin/youth-workspace.sh.template ); then
    echo "  FAIL: the .template must NOT be ignored"; rm -rf "$sb"; return 1
  fi
  rm -rf "$sb"
}

# AC-12: README.md contains a cmux setup section.
test_readme_documents_cmux() {
  local readme="$REPO_ROOT/README.md"
  assert_file_exists   "$readme"                                   || return 1
  assert_file_contains "$readme" "cmux"                            || return 1
  assert_file_contains "$readme" "cmux/setup.sh"                   || return 1
  assert_file_contains "$readme" "--cwd"                           || return 1
}

# AC-13: AGENTS.md documents the template pattern for cmux configs.
test_agents_documents_cmux() {
  local agents="$REPO_ROOT/AGENTS.md"
  assert_file_exists   "$agents"                                   || return 1
  assert_file_contains "$agents" "cmux"                            || return 1
  assert_file_contains "$agents" ".template"                       || return 1
  assert_file_contains "$agents" "cmux/setup.sh"                   || return 1
}

# AC-14: index.md (website) mentions cmux first-party support.
test_website_mentions_cmux() {
  local idx="$REPO_ROOT/index.md"
  assert_file_exists   "$idx"                   || return 1
  assert_file_contains "$idx" "cmux/"           || return 1
  assert_file_contains "$idx" "cmux/setup.sh"   || return 1
}

# ── Run ──────────────────────────────────────────────────────────
echo "Running cmux/setup.sh acceptance tests..."
echo
run_test "AC-1  only templates committed (no generated files in tree)" test_only_templates_committed
run_test "AC-2  ghostty --cwd substitution"                            test_ghostty_substitution
run_test "AC-3  ghostty default cwd fallback with warning"             test_ghostty_default_cwd
run_test "AC-4  cmux.json generated from template"                     test_cmux_json_generated
run_test "AC-5  youth-workspace.sh generated and executable"           test_generates_executable_script
run_test "AC-6  symlink cmux.json into repo"                           test_symlink_cmux_json
run_test "AC-7  symlink ghostty config into repo"                      test_symlink_ghostty
run_test "AC-8  alias installed in rc file"                            test_alias_installed
run_test "AC-9  alias idempotent on re-run"                            test_alias_idempotent
run_test "AC-10 configs/.gitignore ignores non-templates"              test_configs_gitignore
run_test "AC-11 bin/.gitignore ignores non-templates"                  test_bin_gitignore
run_test "AC-12 README.md documents cmux setup"                        test_readme_documents_cmux
run_test "AC-13 AGENTS.md documents template pattern"                  test_agents_documents_cmux
run_test "AC-14 index.md (website) mentions cmux first-party support"  test_website_mentions_cmux

echo
echo "──────────────────────────────────────────"
echo -e "Passed: ${GREEN}${PASS}${RESET}  Failed: ${RED}${FAIL}${RESET}"
if (( FAIL > 0 )); then
  echo -e "${YELLOW}Failed tests:${RESET}"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
exit 0
