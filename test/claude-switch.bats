#!/usr/bin/env bats
# Black-box tests of bin/claude-switch. Always runs with a temp data dir and a stub.

CLI="$BATS_TEST_DIRNAME/../bin/claude-switch"

setup() {
  T="$BATS_TEST_TMPDIR"
  export CLAUDE_SWITCH_DATA_DIR="$T/data"
  export CLAUDE_SWITCH_EFFECTS="$T/stub"
  export CLAUDE_SWITCH_QUIT_TIMEOUT=1
  export CLAUDE_SWITCH_POLL_INTERVAL=0.05
  export STUB_LOG="$T/calls.log"
  export STUB_STATE="$T/stubstate"
  mkdir -p "$CLAUDE_SWITCH_DATA_DIR" "$STUB_STATE" "$T/bin"
  : > "$STUB_LOG"
  # PATH shims proving nothing is ever killed.
  for k in pkill killall; do
    printf '#!/bin/sh\necho "%s $*" >> "$STUB_LOG"\n' "$k" > "$T/bin/$k"; chmod +x "$T/bin/$k"
  done
  PATH="$T/bin:$PATH"
  cat > "$T/stub" <<'STUB'
#!/bin/bash
# Controls: STUB_NEVER_QUITS=1, STUB_NOT_RUNNING=1, STUB_POLLS_AFTER_QUIT=N
echo "$*" >> "$STUB_LOG"
case "$1" in
  quit) touch "$STUB_STATE/quit" ;;
  is-running)
    [[ -n "$STUB_NOT_RUNNING" ]] && exit 1
    [[ -n "$STUB_NEVER_QUITS" ]] && exit 0
    [[ -f "$STUB_STATE/quit" ]] || exit 0
    n=$(cat "$STUB_STATE/polls" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$STUB_STATE/polls"
    (( n < ${STUB_POLLS_AFTER_QUIT:-0} )) && exit 0
    exit 1 ;;
esac
exit 0
STUB
  chmod +x "$T/stub"
  LIVE="$CLAUDE_SWITCH_DATA_DIR/Claude"
  PROF="$CLAUDE_SWITCH_DATA_DIR/Claude-profiles"
}

# live folder with a payload file, optionally labelled
mk_live() { mkdir -p "$LIVE"; echo "${1}" > "$LIVE/payload"; [[ -n "${2:-}" ]] && echo "$2" > "$LIVE/.claude-switch-profile"; return 0; }
mk_profile() { mkdir -p "$PROF/$1"; echo "$2" > "$PROF/$1/payload"; echo "$1" > "$PROF/$1/.claude-switch-profile"; }
calls() { cat "$STUB_LOG"; }
marker() { cat "$1/.claude-switch-profile"; }

@test "first run labels live folder work and switches to a new profile" {
  mk_live W
  run "$CLI" personal
  [ "$status" -eq 0 ]
  [ "$(marker "$LIVE")" = "personal" ]
  [ "$(marker "$PROF/work")" = "work" ]
  [ "$(cat "$PROF/work/payload")" = "W" ]
  [ ! -e "$LIVE/payload" ]
}

@test "new profile is empty except for its marker" {
  mk_live W work
  run "$CLI" new other
  [ "$status" -eq 0 ]
  [ "$(ls -A "$LIVE")" = ".claude-switch-profile" ]
  [ "$(marker "$LIVE")" = "other" ]
}

@test "new refuses an existing profile" {
  mk_live W work; mk_profile personal P
  run "$CLI" new personal
  [ "$status" -eq 13 ]
  [ "$(cat "$LIVE/payload")" = "W" ]
}

@test "switch to an existing profile swaps folders and runs side effects in order" {
  mk_live W work; mk_profile personal P
  STUB_POLLS_AFTER_QUIT=0 run "$CLI" personal
  [ "$status" -eq 0 ]
  [ "$(cat "$LIVE/payload")" = "P" ]
  [ "$(marker "$LIVE")" = "personal" ]
  [ "$(cat "$PROF/work/payload")" = "W" ]
  [ ! -e "$PROF/personal" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
  grep -q '^quit$' "$STUB_LOG"
  grep -q '^launch$' "$STUB_LOG"
  grep -qx 'notify Claude → personal' "$STUB_LOG"
  grep -q '^refresh$' "$STUB_LOG"
  # quit before launch
  [ "$(grep -n '^quit$' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^launch$' "$STUB_LOG" | cut -d: -f1)" ]
}

@test "switching back and forth preserves each profile's data" {
  mk_live W work; mk_profile personal P
  "$CLI" personal; rm -f "$STUB_STATE/quit" "$STUB_STATE/polls"
  "$CLI" work
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ "$(cat "$PROF/personal/payload")" = "P" ]
}

@test "slow quit: waits until Claude has exited" {
  mk_live W work; mk_profile personal P
  STUB_POLLS_AFTER_QUIT=3 run "$CLI" personal
  [ "$status" -eq 0 ]
  [ "$(grep -c '^is-running$' "$STUB_LOG")" -ge 4 ]
  [ "$(marker "$LIVE")" = "personal" ]
}

@test "claude not running: no quit request, still launches" {
  mk_live W work; mk_profile personal P
  STUB_NOT_RUNNING=1 run "$CLI" personal
  [ "$status" -eq 0 ]
  ! grep -q '^quit$' "$STUB_LOG"
  grep -q '^launch$' "$STUB_LOG"
}

@test "switching to the active profile does nothing and exits 10" {
  mk_live W work
  run "$CLI" work
  [ "$status" -eq 10 ]
  [[ "$output" == *"Already"* ]]
  [ "$(calls)" = "" ]
  [ "$(cat "$LIVE/payload")" = "W" ]
}

@test "toggle with two profiles switches to the other" {
  mk_live W work; mk_profile personal P
  run "$CLI" toggle
  [ "$status" -eq 0 ]
  [ "$(marker "$LIVE")" = "personal" ]
}

@test "toggle refuses with one profile" {
  mk_live W work
  run "$CLI" toggle
  [ "$status" -eq 13 ]
  [ "$(marker "$LIVE")" = "work" ]
}

@test "toggle refuses with three profiles" {
  mk_live W work; mk_profile a A; mk_profile b B
  run "$CLI" toggle
  [ "$status" -eq 13 ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(calls)" = "" ]
}

@test "invalid names are rejected without side effects" {
  mk_live W work
  for bad in "" "." ".." "..." "a/b" "../x" "-x" ".hidden" "a b" "$(printf 'x%.0s' {1..65})"; do
    run "$CLI" new "$bad"
    [ "$status" -ne 0 ]
    run "$CLI" "$bad"
    [ "$status" -ne 0 ]
    [ "$status" -ne 10 ]
  done
  run "$CLI" new toggle; [ "$status" -eq 13 ]   # reserved word
  run "$CLI" "a/b"; [ "$status" -eq 13 ]
  run "$CLI" ".."; [ "$status" -eq 13 ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(calls)" = "" ]
  [ ! -e "$PROF" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/x" ]
}

@test "unlabelled live folder with existing profiles is refused" {
  mk_live W; mk_profile personal P
  run "$CLI" personal
  [ "$status" -eq 13 ]
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ ! -e "$LIVE/.claude-switch-profile" ]
  [ "$(calls)" = "" ]
  run "$CLI" status
  [ "$status" -eq 13 ]
}

@test "missing live folder is refused" {
  mk_profile personal P
  run "$CLI" personal
  [ "$status" -eq 13 ]
  [ ! -e "$LIVE" ]
  [ "$(calls)" = "" ]
  run "$CLI" status
  [ "$status" -eq 13 ]
}

@test "quit timeout leaves everything unchanged and never kills" {
  mk_live W work; mk_profile personal P
  STUB_NEVER_QUITS=1 run "$CLI" personal
  [ "$status" -eq 11 ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ "$(cat "$PROF/personal/payload")" = "P" ]
  [ ! -e "$PROF/work" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
  grep -q '^quit$' "$STUB_LOG"
  ! grep -q '^launch$' "$STUB_LOG"
  grep -q '^notify ' "$STUB_LOG"
  ! grep -Eqi 'kill' "$STUB_LOG"
}

@test "quit timeout on first run does not label the live folder" {
  mk_live W
  STUB_NEVER_QUITS=1 run "$CLI" personal
  [ "$status" -eq 11 ]
  [ ! -e "$LIVE/.claude-switch-profile" ]
  [ ! -e "$PROF/personal" ]
}

@test "rollback when moving the live folder out fails (unwritable profiles dir)" {
  mk_live W work; mk_profile personal P
  chmod 555 "$PROF"
  run "$CLI" personal
  chmod 755 "$PROF"
  [ "$status" -eq 14 ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ "$(cat "$PROF/personal/payload")" = "P" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
  ! grep -q '^launch$' "$STUB_LOG"
}

@test "rollback when the second rename fails restores the original live folder" {
  mk_live W work; mk_profile personal P
  CLAUDE_SWITCH_FAIL_RENAME=2 run "$CLI" personal
  [ "$status" -eq 14 ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ ! -e "$PROF/work" ]
  [ "$(cat "$PROF/personal/payload")" = "P" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
}

@test "rollback of a new-profile switch on first run leaves no trace" {
  mk_live W
  CLAUDE_SWITCH_FAIL_RENAME=2 run "$CLI" new fresh
  [ "$status" -eq 14 ]
  [ "$(cat "$LIVE/payload")" = "W" ]
  [ ! -e "$LIVE/.claude-switch.lock" ]
  [ ! -e "$PROF/fresh" ]
  [ ! -e "$PROF/work" ]
}

@test "lock held by a live pid is refused" {
  mk_live W work; mk_profile personal P
  sleep 30 & local holder=$!
  mkdir "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock"
  echo "$holder" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock/pid"
  run "$CLI" personal
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 12 ]
  [ -d "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
  [ "$(marker "$LIVE")" = "work" ]
  [ "$(calls)" = "" ]
}

@test "lock held by a dead pid is reclaimed" {
  mk_live W work; mk_profile personal P
  sleep 0.01 & local dead=$!
  wait "$dead"
  mkdir "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock"
  echo "$dead" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock/pid"
  run "$CLI" personal
  [ "$status" -eq 0 ]
  [ "$(marker "$LIVE")" = "personal" ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock" ]
}

@test "status prints the active profile" {
  mk_live W work; mk_profile personal P
  run "$CLI" status
  [ "$status" -eq 0 ]
  [ "$output" = "work" ]
}

@test "status on a first-run folder reports work without modifying it" {
  mk_live W
  run "$CLI" status
  [ "$status" -eq 0 ]
  [ "$output" = "work" ]
  [ ! -e "$LIVE/.claude-switch-profile" ]
}

@test "list marks the active profile" {
  mk_live W work; mk_profile personal P; mk_profile zed Z
  run "$CLI" list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "  personal" ]
  [ "${lines[1]}" = "  zed" ] || [ "${lines[1]}" = "* work" ]
  [[ "$output" == *"* work"* ]]
  [ "$(echo "$output" | grep -c '^\* ')" -eq 1 ]
}

@test "menu: header, checked+disabled active item, switch items, extras" {
  mk_live W work; mk_profile personal P
  run "$CLI" menu
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "✳ work" ]
  [ "${lines[1]}" = "---" ]
  [[ "$output" == *$'\nwork | checked=true disabled=true'* ]]
  [[ "$output" == *"personal | bash="*"claude-switch\" param1=personal terminal=false refresh=true"* ]]
  [[ "$output" != *"work | bash="* ]]
  [[ "$output" == *"New profile…"* ]]
  [[ "$output" == *"Open profiles folder"* ]]
  [[ "$output" == *"$PROF"* ]]
}

@test "menu on a bad state still prints a header and exits 0" {
  run "$CLI" menu
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "✳ ?" ]
}

@test "no arguments is a usage error" {
  run "$CLI"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------- claude cli
cli_setup() {
  export CLAUDE_SWITCH_CLI_HOME="$T/home"
  mkdir -p "$T/home/.claude/skills"
  echo '{}' > "$T/home/.claude/settings.json"
  echo secret > "$T/home/.claude/.claude.json"
}

@test "cli-dir: the first active profile owns ~/.claude and gets no override" {
  cli_setup; mk_live W work
  run "$CLI" cli-dir
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$T/home/.claude-profiles/.default-owner")" = "work" ]
}

@test "cli-dir: another profile gets its own dir with shared items linked" {
  cli_setup; mk_live W work
  "$CLI" cli-dir >/dev/null            # work claims ~/.claude
  mk_profile personal P
  "$CLI" personal >/dev/null
  run "$CLI" cli-dir
  [ "$status" -eq 0 ]
  [ "$output" = "$T/home/.claude-profiles/personal" ]
  [ -L "$output/skills" ] && [ "$(readlink "$output/skills")" = "$T/home/.claude/skills" ]
  [ -L "$output/settings.json" ]
  [ -d "$output/projects" ] && [ -L "$output/projects" ]   # missing dirs are created + linked
  [ ! -e "$output/.claude.json" ]                          # login is never shared
  [ ! -e "$output/CLAUDE.md" ]                             # missing files are not linked
}

@test "cli-dir: switching back to the owner removes the override" {
  cli_setup; mk_live W work
  "$CLI" cli-dir >/dev/null
  "$CLI" personal >/dev/null
  "$CLI" work >/dev/null
  run "$CLI" cli-dir
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "cli-dir: is idempotent and keeps existing per-profile files" {
  cli_setup; mk_live W work
  "$CLI" cli-dir >/dev/null
  "$CLI" personal >/dev/null
  d="$("$CLI" cli-dir)"
  echo mine > "$d/.claude.json"
  run "$CLI" cli-dir
  [ "$status" -eq 0 ] && [ "$output" = "$d" ]
  [ "$(cat "$d/.claude.json")" = "mine" ]
}

@test "cli-dir: on a bad state fails with 13 and prints nothing" {
  cli_setup
  run "$CLI" cli-dir
  [ "$status" -eq 13 ]
}

@test "shell-init: defines a claude function that uses cli-dir" {
  run "$CLI" shell-init
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude() {"* ]]
  [[ "$output" == *"cli-dir"* ]]
  [[ "$output" == *"CLAUDE_CONFIG_DIR="* ]]
}

@test "cli-dir and shell-init are reserved profile names" {
  mk_live W work
  run "$CLI" new cli-dir;    [ "$status" -eq 2 ] || [ "$status" -eq 13 ]
  run "$CLI" new shell-init; [ "$status" -eq 2 ] || [ "$status" -eq 13 ]
}
