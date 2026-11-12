# claude-switch

Switch between Claude Desktop accounts on macOS. It keeps one full data folder per account (a profile) and swaps them with atomic renames: `~/Library/Application Support/Claude` is always the active profile, the others sit in `Claude-profiles/<name>`. A SwiftBar menu bar item shows the active profile (`✳ work`) and lets you switch. See `SPEC.md` for the design.

## Install

```sh
./install.sh
```

Links the CLI to `~/.local/bin`, installs SwiftBar (`brew install --cask swiftbar`) if missing, and links the plugin into SwiftBar's plugin folder. Then enable "Open at Login" in SwiftBar's preferences. Make the first real switch by hand from the menu bar (not from inside Claude).

## Usage

```
claude-switch <name>     switch to a profile (created empty if missing)
claude-switch toggle     switch to the other profile (exactly two must exist)
claude-switch status     print the active profile
claude-switch list       list profiles, active marked with *
claude-switch new <name> create an empty profile and switch to it
claude-switch menu       SwiftBar menu output
```

On first use the existing Claude data is labelled `work`. A new profile opens Claude signed out; sign in once. Names: letters, digits, `_`, `-`, up to 64 chars, starting with a letter or digit; command words (`toggle`, `status`, ...) are reserved.

A switch asks Claude to quit, waits up to 15 s for every Claude process (helpers included) to exit, swaps the folders, relaunches Claude, notifies, and refreshes SwiftBar. It never force-quits; if Claude doesn't exit (e.g. a "sessions are running" prompt) the switch is cancelled with nothing changed. Failed renames are rolled back.

## Exit codes

| code | meaning |
|---|---|
| 0 | success |
| 2 | usage error |
| 10 | already active (nothing done) |
| 11 | Claude did not quit in time (nothing changed) |
| 12 | another switch holds the lock |
| 13 | invalid name or invalid state (unlabelled live folder with existing profiles, missing live folder, `toggle` without exactly two profiles, ...) |
| 14 | rename failed (rolled back) |

`menu` always exits 0 so SwiftBar renders it; problems show as a red `✳ ?` entry.

## Environment

- `CLAUDE_SWITCH_DATA_DIR`: base data dir (default `~/Library/Application Support`).
- `CLAUDE_SWITCH_EFFECTS`: script replacing all side effects; called with `quit`, `is-running` (exit 0 = running), `launch`, `notify <msg>`, `refresh`.
- `CLAUDE_SWITCH_QUIT_TIMEOUT` (default 15), `CLAUDE_SWITCH_POLL_INTERVAL` (default 0.5): tuning, used by tests.
- `CLAUDE_SWITCH_FAIL_RENAME=N`: test hook, makes the Nth rename fail.

## Tests

```sh
brew install bats-core
bats test
```

Tests use a temp data dir and a stub; they never touch the real app. The real swap is only verified by hand.

## Caveats

- Code-tab sessions and scratch workspaces belong to the profile that created them; they vanish while another profile is active and return when you switch back.
- Never reset or delete the "Claude Safe Storage" Keychain item; every profile depends on it.
- The Claude Code CLI login (`~/.claude`, its Keychain item) is not switched.
- Don't switch during an app auto-update or "Reset App Data".
- Each profile grows to roughly 1-1.5 GB.
- Checked against Claude 5.1231.2; a future version that moves login state out of the data folder would break the folder-swap approach.
