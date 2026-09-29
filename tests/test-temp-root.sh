#!/usr/bin/env bash
# Tests for the canonical FARTY_BOBO_TEMP_DIR temp-root block.
#
# The block between the `# >>> temp-root` and `# <<< temp-root` markers in
# skills/critique/SKILL.md is canonical. Every skill that mentions
# FARTY_BOBO_TEMP_DIR must carry a byte-identical copy, no skill may hardcode
# a /tmp path outside an explicit allowlist, and the block must resolve
# TEMP_ROOT correctly for good and bad inputs.
#
# Run: bash tests/test-temp-root.sh
# Exits 0 on all-pass, non-zero on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

GREEN='\033[0;32m'
RED='\033[0;31m'
RESET='\033[0m'

CRITIQUE="$REPO_ROOT/skills/critique/SKILL.md"

# Every /tmp mention that is allowed to appear in a skill. Anything else is a
# hardcoded path and fails the test.
TMP_ALLOWLIST=(
  '${FARTY_BOBO_TEMP_DIR:-/tmp}'
  'TEMP_ROOT=/tmp ;;'
  'falling back to /tmp"'
  '`/tmp`, `/private/tmp`, or `/var/folders`'
  '`/tmp/<repo-name>/<branch-name>/plans/decisions-{ticket-id}.md`'
  'falling back to `/tmp` when it is unset'
  'Never hardcode `/tmp` in a skill'
  '(`/tmp` → `/private/tmp`)'
  '`$TEMP_ROOT` is not `/tmp`'
  'defaulting to `/tmp`'
)

# ── Helpers ──────────────────────────────────────────────────────

extract_block() {
  awk '/^# >>> temp-root/{on=1} on{print} /^# <<< temp-root/{if(on) exit}' "$1"
}

skill_files() {
  local f
  for f in "$REPO_ROOT"/skills/*/SKILL.md; do
    case "$f" in "$REPO_ROOT"/skills/synced/*) continue ;; esac
    printf '%s\n' "$f"
  done
}

# Skills run the block in whatever shell the agent's Bash tool uses — bash or
# zsh (macOS default) — so every resolution check runs under each available one.
SHELLS=(bash)
command -v zsh >/dev/null 2>&1 && SHELLS+=(zsh)

resolve_with() {
  local sh="$1" input="$2" block
  block="$(extract_block "$CRITIQUE")"
  if [[ "$input" == "__unset__" ]]; then
    env -u FARTY_BOBO_TEMP_DIR HOME=/home/u "$sh" -c "$block"$'\nprintf %s "$TEMP_ROOT"' 2>/dev/null
  else
    FARTY_BOBO_TEMP_DIR="$input" HOME=/home/u "$sh" -c "$block"$'\nprintf %s "$TEMP_ROOT"' 2>/dev/null
  fi
}

assert_resolves() {
  local input="$1" expected="$2" sh got ok=0
  for sh in "${SHELLS[@]}"; do
    got="$(resolve_with "$sh" "$input")"
    if [[ "$got" != "$expected" ]]; then
      echo "  FAIL ($sh): FARTY_BOBO_TEMP_DIR=$input resolved to '$got', expected '$expected'"
      ok=1
    fi
  done
  return "$ok"
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

# T-1: the canonical block exists in critique and is closed
test_canonical_block_exists() {
  local block
  block="$(extract_block "$CRITIQUE")"
  [[ -n "$block" ]] || { echo "  FAIL: no temp-root block in $CRITIQUE"; return 1; }
  [[ "$(tail -n1 <<<"$block")" == "# <<< temp-root" ]] || { echo "  FAIL: temp-root block in $CRITIQUE is not closed"; return 1; }
}

# T-2: every skill that mentions FARTY_BOBO_TEMP_DIR carries a byte-identical block
test_blocks_in_sync() {
  local canonical f ok=0 checked=0
  canonical="$(extract_block "$CRITIQUE")"
  while IFS= read -r f; do
    grep -qF 'FARTY_BOBO_TEMP_DIR' "$f" || continue
    checked=$((checked + 1))
    if [[ "$(extract_block "$f")" != "$canonical" ]]; then
      echo "  FAIL: temp-root block missing or drifted in ${f#"$REPO_ROOT"/}"
      ok=1
    fi
  done < <(skill_files)
  (( checked > 1 )) || { echo "  FAIL: expected more than one skill to use FARTY_BOBO_TEMP_DIR, found $checked"; return 1; }
  return "$ok"
}

# T-3: no skill hardcodes a /tmp path outside the allowlist
test_no_hardcoded_tmp() {
  local f line stripped allowed ok=0
  while IFS= read -r f; do
    while IFS= read -r line; do
      stripped="${line#*:}"
      for allowed in "${TMP_ALLOWLIST[@]}"; do
        stripped="${stripped//"$allowed"/}"
      done
      if grep -qE '(^|[^A-Za-z0-9_.-])/tmp([^A-Za-z0-9_-]|$)' <<<"$stripped"; then
        echo "  FAIL: hardcoded /tmp in ${f#"$REPO_ROOT"/}:${line%%:*}"
        ok=1
      fi
    done < <(grep -nE '(^|[^A-Za-z0-9_.-])/tmp([^A-Za-z0-9_-]|$)' "$f")
  done < <(skill_files)
  return "$ok"
}

# T-4: the block resolves TEMP_ROOT correctly for good and bad inputs
test_block_resolution() {
  local ok=0
  assert_resolves "__unset__" "/tmp" || ok=1
  assert_resolves "" "/tmp" || ok=1
  assert_resolves "/x/y/" "/x/y" || ok=1
  assert_resolves "~/foo" "/home/u/foo" || ok=1
  assert_resolves "~/foo/" "/home/u/foo" || ok=1
  assert_resolves "~" "/home/u" || ok=1
  assert_resolves "~other/foo" "/tmp" || ok=1
  assert_resolves "rel/dir" "/tmp" || ok=1
  assert_resolves "/" "/tmp" || ok=1
  return "$ok"
}

# T-5: the block warns on stderr when it falls back from a bad value
test_block_warns_on_fallback() {
  local block err sh ok=0
  block="$(extract_block "$CRITIQUE")"
  for sh in "${SHELLS[@]}"; do
    err="$(FARTY_BOBO_TEMP_DIR="rel/dir" "$sh" -c "$block" 2>&1 >/dev/null)"
    [[ "$err" == WARNING:*"rel/dir"* ]] || { echo "  FAIL ($sh): expected WARNING on stderr, got: $err"; ok=1; }
  done
  return "$ok"
}

# ── Run ──────────────────────────────────────────────────────────

run_test test_canonical_block_exists
run_test test_blocks_in_sync
run_test test_no_hardcoded_tmp
run_test test_block_resolution
run_test test_block_warns_on_fallback

printf "\n${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf "Failed tests:\n"
  for t in "${FAILED_TESTS[@]}"; do printf "  - %s\n" "$t"; done
  exit 1
fi
