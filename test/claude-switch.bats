#!/usr/bin/env bats
# Black-box tests of bin/claude-switch. Always runs with a temp data dir and a stub.

CLI="$BATS_TEST_DIRNAME/../bin/claude-switch"
export STUB_CLI="$CLI"

setup() {
  T="$BATS_TEST_TMPDIR"
  export CLAUDE_SWITCH_DATA_DIR="$T/data"
  export CLAUDE_SWITCH_EFFECTS="$T/stub"
  export CLAUDE_SWITCH_QUIT_TIMEOUT=1
  export CLAUDE_SWITCH_POLL_INTERVAL=0.05
  export CLAUDE_SWITCH_CONFIG="$T/config/profiles.conf"
  export CLAUDE_SWITCH_CLI_HOME="$T/home"
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
# STUB_MENU_SNAPSHOT=<dir>: capture `menu` output at each refresh (to observe mid-switch state)
if [[ "$1" == refresh && -n "$STUB_MENU_SNAPSHOT" ]]; then
  n=$(ls "$STUB_MENU_SNAPSHOT" | wc -l | tr -d ' ')
  "$STUB_CLI" menu | sed 's/ sfconfig=[^ ]*//' > "$STUB_MENU_SNAPSHOT/$n"
fi
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
# Menu output without the base64 sfconfig blobs (checked separately).
menu_plain() { "$CLI" menu | sed 's/ sfconfig=[^ ]*//'; }
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
  [[ "$output" == *"Already"* ]] || false
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
  [[ "$output" == *"* work"* ]] || false
  [ "$(echo "$output" | grep -c '^\* ')" -eq 1 ]
}

@test "menu: header, checked+disabled active item, switch items, extras" {
  mk_live W work; mk_profile personal P
  run menu_plain
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "work | sfimage=briefcase.fill sfcolor=#D97757" ]
  [ "${lines[1]}" = "---" ]
  [[ "$output" == *$'\nwork | checked=true disabled=true'* ]] || false
  [[ "$output" == *"personal | bash="*"claude-switch\" param1=personal terminal=false refresh=true"* ]] || false
  [[ "$output" != *"work | bash="* ]] || false
  [[ "$output" == *"New profile…"* ]] || false
  [[ "$output" == *"Open profiles folder"* ]] || false
  [[ "$output" == *"$PROF"* ]] || false
}

@test "menu on a bad state still prints a header and exits 0" {
  run menu_plain
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
  [[ "$output" == *"claude() {"* ]] || false
  [[ "$output" == *"cli-dir"* ]] || false
  [[ "$output" == *"CLAUDE_CONFIG_DIR="* ]] || false
}

@test "cli-dir and shell-init are reserved profile names" {
  mk_live W work
  run "$CLI" new cli-dir;    [ "$status" -eq 2 ] || [ "$status" -eq 13 ]
  run "$CLI" new shell-init; [ "$status" -eq 2 ] || [ "$status" -eq 13 ]
}

# ----------------------------------------------------------------- appearance
now() { date +%s; }
conf() { cat "$CLAUDE_SWITCH_CONFIG"; }
# write a Claude Code CLI config with an account
mk_cli_json() { # <path> <email> <org>
  mkdir -p "$(dirname "$1")"
  printf '{"oauthAccount":{"emailAddress":"%s","organizationName":"%s"}}\n' "$2" "$3" > "$1"
}

@test "menu header: active profile's icon and color, text uncolored" {
  mk_live W work
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=briefcase.fill sfcolor=#D97757" ]
  [[ "${lines[0]}" != *" color="* ]] || false
  mk_live W; rm -rf "$LIVE"; mk_live P personal
  run menu_plain
  [[ "${lines[0]}" == "personal | sfimage=house.fill sfcolor=#"* ]] || false
}

@test "menu header: shows the switching state during a switch and clears it after" {
  mk_live W work; mk_profile personal P
  export STUB_MENU_SNAPSHOT="$T/snap"; mkdir "$T/snap"
  run "$CLI" personal
  [ "$status" -eq 0 ]
  [ "$(head -1 "$T/snap/0")" = "→ personal | sfimage=arrow.triangle.2.circlepath" ]
  # the last refresh (end of the switch) shows the new active profile
  [[ "$(head -1 "$T/snap/$(( $(ls "$T/snap" | wc -l) - 1 ))")" == "personal | sfimage=house.fill"* ]] || false
  [ "$(grep -c '^refresh$' "$STUB_LOG")" -ge 2 ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state" ]
  run menu_plain
  [[ "${lines[0]}" == "personal | sfimage=house.fill"* ]] || false
}

@test "switching state: a fresh state file shows the arrow, a stale one is ignored" {
  mk_live W work
  echo "switching personal $(now)" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state"
  run menu_plain
  [ "${lines[0]}" = "→ personal | sfimage=arrow.triangle.2.circlepath" ]
  echo "switching personal $(( $(now) - 61 ))" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state"
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=briefcase.fill sfcolor=#D97757" ]
}

@test "switch failure paths leave no switching state and still repaint" {
  mk_live W work; mk_profile personal P
  CLAUDE_SWITCH_FAIL_RENAME=2 run "$CLI" personal
  [ "$status" -eq 14 ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state" ]
  [ "$(grep -c '^refresh$' "$STUB_LOG")" -ge 2 ]
  : > "$STUB_LOG"
  chmod 555 "$PROF"
  run "$CLI" personal
  chmod 755 "$PROF"
  [ "$status" -eq 14 ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state" ]
}

@test "switch refused while locked does not touch the state file" {
  mk_live W work; mk_profile personal P
  sleep 30 & local holder=$!
  mkdir "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock"
  echo "$holder" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch.lock/pid"
  run "$CLI" personal
  kill "$holder" 2>/dev/null || true
  [ "$status" -eq 12 ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state" ]
}

@test "cancelled switch: red warning header, then back to normal after 10s" {
  mk_live W work; mk_profile personal P
  STUB_NEVER_QUITS=1 run "$CLI" personal
  [ "$status" -eq 11 ]
  [ "$(grep -c '^refresh$' "$STUB_LOG")" -ge 2 ]   # start + cancel
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=exclamationmark.triangle.fill sfcolor=#E5484D" ]
  [[ "$output" == *"Switch cancelled"* ]] || false
  [[ "$output" == *"personal — "* || "$output" == *"personal | bash="* ]] || false
  echo "cancelled $(( $(now) - 11 ))" > "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state"
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=briefcase.fill sfcolor=#D97757" ]
  [[ "$output" != *"Switch cancelled"* ]] || false
}

@test "a successful switch after a cancelled one clears the cancelled state" {
  mk_live W work; mk_profile personal P
  STUB_NEVER_QUITS=1 run "$CLI" personal
  [ "$status" -eq 11 ]
  run "$CLI" personal
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SWITCH_DATA_DIR/.claude-switch-state" ]
}

@test "menu rows: per-profile icon and color, active checked, others switch in one click" {
  mk_live W work; mk_profile personal P; mk_profile zed Z
  run menu_plain
  [[ "$output" == *$'\nwork | checked=true disabled=true sfimage=briefcase.fill sfcolor=#D97757\n'* ]] || false
  [[ "$output" == *$'\npersonal | bash="'*'claude-switch" param1=personal terminal=false refresh=true sfimage=house.fill sfcolor=#3E8EDF'$'\n'* ]] || false
  [[ "$output" == *$'\nzed | bash="'*'claude-switch" param1=zed terminal=false refresh=true sfimage=person.crop.circle.fill sfcolor=#E5484D'$'\n'* ]] || false
}

@test "menu rows: configured icon and color win over defaults" {
  mk_live W work
  mkdir -p "$T/config"
  printf 'work icon=flame.fill color=#00ff00\n' > "$CLAUDE_SWITCH_CONFIG"
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=flame.fill sfcolor=#00FF00" ]
}

@test "defaults: unset profiles get deterministic distinct palette colors" {
  mk_live W work; mk_profile personal P; mk_profile alpha A; mk_profile beta B; mk_profile gamma G
  run menu_plain
  first="$output"
  [[ "$output" == *$'\nalpha | bash='*"sfimage=person.crop.circle.fill sfcolor=#E5484D"* ]]   # red: orange is work's
  [[ "$output" == *$'\nbeta | bash='*"sfcolor=#F5A524"* ]]    # amber
  [[ "$output" == *$'\ngamma | bash='*"sfcolor=#30A46C"* ]]   # green
  run menu_plain
  [ "$output" = "$first" ]
}

@test "defaults: a color set explicitly on another profile is skipped" {
  mk_live W work; mk_profile alpha A; mk_profile beta B
  mkdir -p "$T/config"
  printf 'beta color=#e5484d\n' > "$CLAUDE_SWITCH_CONFIG"
  run menu_plain
  [[ "$output" == *$'\nalpha | bash='*"sfcolor=#F5A524"* ]] || false
  [[ "$output" == *$'\nbeta | bash='*"sfcolor=#E5484D"* ]] || false
}

@test "menu: email and org shown for the default-owner profile and the others" {
  mk_live W work; mk_profile personal P
  cli_setup
  echo work > "$T/home/.claude-profiles/.default-owner" 2>/dev/null || { mkdir -p "$T/home/.claude-profiles"; echo work > "$T/home/.claude-profiles/.default-owner"; }
  mk_cli_json "$T/home/.claude.json" user@example.com "Acme Org"
  mk_cli_json "$T/home/.claude-profiles/personal/.claude.json" me@home.org ""
  run menu_plain
  [[ "$output" == *$'\nwork — user@example.com · Acme Org | checked=true disabled=true'* ]] || false
  [[ "$output" == *$'\npersonal — me@home.org | bash='* ]] || false
}

@test "menu: owner defaults to the active profile when .default-owner is missing" {
  mk_live W personal
  mk_profile work P
  mk_cli_json "$T/home/.claude.json" p@x.com Org1
  run menu_plain
  [[ "$output" == *$'\npersonal — p@x.com · Org1 | checked=true'* ]] || false
}

@test "menu: missing or unreadable CLI config shows the name only" {
  mk_live W work; mk_profile personal P
  mkdir -p "$T/home/.claude-profiles"
  echo 'not json' > "$T/home/.claude-profiles/personal/.claude.json" 2>/dev/null || { mkdir -p "$T/home/.claude-profiles/personal"; echo 'not json' > "$T/home/.claude-profiles/personal/.claude.json"; }
  run menu_plain
  [[ "$output" == *$'\nwork | checked=true disabled=true'* ]] || false
  [[ "$output" == *$'\npersonal | bash='* ]] || false
}

@test "menu: Customize has a submenu per profile with Icon and Color submenus" {
  mk_live W work; mk_profile personal P
  run menu_plain
  noop='bash=/usr/bin/true terminal=false'
  [[ "$output" == *$'\n---\nCustomize | '"$noop"$'\n--personal | sfimage=house.fill sfcolor=#3E8EDF '"$noop"$'\n----Icon | sfimage=paintbrush.pointed.fill '"$noop"$'\n'* ]] || false
  [[ "$output" == *$'\n--work | sfimage=briefcase.fill sfcolor=#D97757 '"$noop"$'\n----Icon | '* ]] || false
  # submenu parents carry an action so SwiftBar doesn't draw them disabled
  [ "$(echo "$output" | grep -c "^----Icon | .*$noop\$")" -eq 2 ]
  [ "$(echo "$output" | grep -c "^----Color | .*$noop\$")" -eq 2 ]
  # ordering: rows, New profile…, Customize, Open profiles folder
  a="$(echo "$output" | grep -n '^New profile' | cut -d: -f1)"
  b="$(echo "$output" | grep -n '^Customize | ' | cut -d: -f1)"
  c="$(echo "$output" | grep -n '^Open profiles folder' | cut -d: -f1)"
  [ "$a" -lt "$b" ]; [ "$b" -lt "$c" ]
  # 17 icons per profile, each shown as its own sfimage
  [ "$(echo "$output" | grep -c '^------[A-Za-z ]* | sfimage=[a-z0-9.]* sfcolor=#[0-9A-F]*\( checked=true\)\{0,1\} bash=.*param1=set-icon')" -eq 34 ]
  [[ "$output" == *$'\n------Game controller | sfimage=gamecontroller.fill sfcolor=#D97757 bash="'*'claude-switch" param1=set-icon param2=work param3=gamecontroller.fill terminal=false refresh=true'* ]] || false
  [[ "$output" == *"------Other symbol… | "*"param1=icon-prompt param2=work"* ]] || false
  # 9 color presets per profile with dots, plus Custom…
  [ "$(echo "$output" | grep -c '^------[A-Za-z ]* | sfimage=circle.fill sfcolor=#')" -eq 18 ]
  [[ "$output" == *$'\n------Claude orange | sfimage=circle.fill sfcolor=#D97757 checked=true bash="'*'claude-switch" param1=set-color param2=work param3=#D97757 terminal=false refresh=true'* ]] || false
  [[ "$output" == *"------Custom… | "*"param1=color-prompt param2=work"* ]] || false
}

@test "menu: Customize checks the current icon and color only" {
  mk_live W work
  mkdir -p "$T/config"
  printf 'work icon=flame.fill color=#8E4EC6\n' > "$CLAUDE_SWITCH_CONFIG"
  run menu_plain
  [ "$(echo "$output" | grep -c '^------.* checked=true')" -eq 2 ]
  [[ "$output" == *$'\n------Flame | sfimage=flame.fill sfcolor=#8E4EC6 checked=true bash='* ]] || false
  [[ "$output" == *$'\n------Purple | sfimage=circle.fill sfcolor=#8E4EC6 checked=true bash='* ]] || false
  [[ "$output" != *"briefcase.fill checked"* ]] || false
}

@test "menu: a non-curated symbol and a custom color check the 'Other'/'Custom' items" {
  mk_live W work
  mkdir -p "$T/config"
  printf 'work icon=sun.max.fill color=#123456\n' > "$CLAUDE_SWITCH_CONFIG"
  run menu_plain
  [[ "$output" == *"------Other symbol… |  checked=true bash="* ]] || false
  [[ "$output" == *"------Custom… |  checked=true bash="* ]] || false
  [ "$(echo "$output" | grep -c '^------.* checked=true')" -eq 2 ]
}

@test "set-icon persists, refreshes, creates the config dir and shows in the menu" {
  mk_live W work
  run "$CLI" set-icon work star.fill
  [ "$status" -eq 0 ]
  [ "$(conf)" = "work icon=star.fill" ]
  grep -q '^refresh$' "$STUB_LOG"
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=star.fill sfcolor=#D97757" ]
}

@test "set-color persists (uppercased), keeps the icon, other lines and comments" {
  mk_live W work; mk_profile personal P
  mkdir -p "$T/config"
  printf '# my profiles\npersonal icon=heart.fill color=#112233\nwork icon=flame.fill\n\nother icon=x.y\n' > "$CLAUDE_SWITCH_CONFIG"
  run "$CLI" set-color work '#abcdef'
  [ "$status" -eq 0 ]
  [ "$(conf)" = $'# my profiles\npersonal icon=heart.fill color=#112233\nwork icon=flame.fill color=#ABCDEF\n\nother icon=x.y' ]
  run "$CLI" set-icon personal globe
  [ "$status" -eq 0 ]
  [ "$(conf)" = $'# my profiles\npersonal icon=globe color=#112233\nwork icon=flame.fill color=#ABCDEF\n\nother icon=x.y' ]
  [ -z "$(ls -A "$T/config" | grep -v '^profiles.conf$')" ]   # no temp files left
}

@test "set-icon appends a line for a profile that has none" {
  mk_live W work; mk_profile personal P
  run "$CLI" set-icon work star.fill
  run "$CLI" set-color personal '#010203'
  [ "$(conf)" = $'work icon=star.fill\npersonal color=#010203' ]
}

@test "set-icon / set-color validate profile, symbol and color without side effects" {
  mk_live W work
  for args in "work" "" "work Star" "work a/b" "work 'x y'" "work star.fill extra"; do
    eval "run \"\$CLI\" set-icon $args"
    [ "$status" -eq 2 ]
  done
  run "$CLI" set-icon work "BRIEF";   [ "$status" -eq 2 ]
  run "$CLI" set-icon work "a_b";     [ "$status" -eq 2 ]
  run "$CLI" set-icon "a/b" star;     [ "$status" -eq 13 ]
  run "$CLI" set-icon toggle star;    [ "$status" -eq 13 ]
  run "$CLI" set-icon ghost star;     [ "$status" -eq 13 ]
  for bad in "D97757" "#D9775" "#D977577" "#GGGGGG" "red" "#12 456"; do
    run "$CLI" set-color work "$bad"; [ "$status" -eq 2 ]
  done
  run "$CLI" set-color "../x" '#112233'; [ "$status" -eq 13 ]
  run "$CLI" set-color ghost '#112233';  [ "$status" -eq 13 ]
  [ ! -e "$CLAUDE_SWITCH_CONFIG" ]
  ! grep -q '^refresh$' "$STUB_LOG"
}

@test "set-color refreshes SwiftBar" {
  mk_live W work
  run "$CLI" set-color work '#112233'
  [ "$status" -eq 0 ]
  grep -q '^refresh$' "$STUB_LOG"
}

@test "new command words are reserved profile names" {
  mk_live W work
  for w in set-icon set-color icon-prompt color-prompt; do
    run "$CLI" new "$w"; [ "$status" -eq 13 ]
  done
}

@test "invalid lines and values in profiles.conf are ignored by the menu" {
  mk_live W work
  mkdir -p "$T/config"
  printf 'work icon=BAD!! color=blue\nbad/name icon=x\n' > "$CLAUDE_SWITCH_CONFIG"
  run menu_plain
  [ "${lines[0]}" = "work | sfimage=briefcase.fill sfcolor=#D97757" ]
}

@test "menu: SF Symbols carry a small Palette sfconfig with the profile color" {
  mk_live W work
  run "$CLI" menu
  [ "$status" -eq 0 ]
  cfg="$(echo "${lines[0]}" | grep -o 'sfconfig=[^ ]*' | cut -d= -f2- | base64 -D)"
  [ "$cfg" = '{"renderingMode":"Palette","colors":["#D97757"],"scale":"small","weight":"regular"}' ]
}
