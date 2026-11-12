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
claude-switch cli-dir    CLAUDE_CONFIG_DIR for the active profile (empty = default ~/.claude)
claude-switch shell-init zsh function that makes terminal `claude` follow the active profile
```

## Terminal `claude` per profile

The Claude Code CLI keeps its login in `$CLAUDE_CONFIG_DIR/.claude.json` plus a Keychain item tied to that folder, so each profile can have its own CLI login. `install.sh` adds this line to `~/.zshrc`:

```sh
command -v claude-switch >/dev/null && eval "$(claude-switch shell-init)"  # claude-switch
```

It defines a `claude` function that asks `claude-switch cli-dir` on every run:

- The profile that was active the first time (`work`) keeps the normal `~/.claude` and its existing login. The owner is recorded in `~/.claude-profiles/.default-owner`.
- Every other profile gets `~/.claude-profiles/<name>`. Run `claude` once there and `/login` with that account.
- Shared through symlinks to `~/.claude`: `settings.json`, `CLAUDE.md`, `skills`, `agents`, `commands`, `hooks`, `output-styles`, `plugins`, `projects` (sessions and memory), `history.jsonl`, `file-history`, `todos`, `plans`.
- Kept per profile: the login, `.claude.json` (including user-scoped MCP servers and onboarding state), and org-managed remote settings and policy limits.
- A `claude` session that is already running keeps its account. Only new runs pick up a switch.
- The Code tab inside Claude Desktop is not affected. It always uses `~/.claude`.

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
- `CLAUDE_SWITCH_CLI_HOME`: home dir used for the CLI config folders (default `$HOME`; used by tests).

## Tests

```sh
brew install bats-core
bats test
```

Tests use a temp data dir and a stub; they never touch the real app. The real swap is only verified by hand.

## Caveats

- Code-tab sessions and scratch workspaces belong to the profile that created them; they vanish while another profile is active and return when you switch back.
- Never reset or delete the "Claude Safe Storage" Keychain item; every profile depends on it.
- Terminal `claude` follows the profile only through the shell hook. Scripts and other shells that run the binary directly use `~/.claude`.
- Don't switch during an app auto-update or "Reset App Data".
- Each profile grows to roughly 1-1.5 GB.
- Checked against Claude 5.1231.2; a future version that moves login state out of the data folder would break the folder-swap approach.
