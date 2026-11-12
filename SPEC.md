# Spec: Claude Desktop account switcher for macOS

Status: ready-for-agent

## Problem Statement

I use the Claude desktop app on macOS with more than one Claude account (a work account and a personal one). The app only holds one signed-in account at a time, so switching means signing out, signing back in with the other account, and losing that account's local state (settings, MCP config, connectors, Code-tab sessions, scratch workspaces). There is no built-in switcher, and I don't want to rely on a paid app or someone else's "Claude switcher" tool. I want to flip between accounts in one click and always see which account is active.

## Solution

A small, self-owned command-line tool, `claude-switch`, keeps one complete Claude Desktop data folder per account (a **profile**) and swaps them in and out of the location the app reads from. A switch quits Claude gracefully, renames folders, and reopens Claude already signed into the other account, with all of that account's state intact.

A SwiftBar menu bar item shows the active profile next to the clock and battery (e.g. `✳ work`) and offers a menu to switch to any other stored profile or create a new one. A macOS notification confirms each switch.

## User Stories

1. As a Claude Desktop user with two accounts, I want to switch accounts with one click from the menu bar, so that I don't sign out and back in by hand.
2. As a user, I want to see the active profile name in the menu bar at all times, so that I know which account I'm about to work in.
3. As a user, I want the menu to list every stored profile, so that I can switch to any of them, not just toggle between two.
4. As a user, I want the active profile shown with a checkmark and not clickable, so that I don't trigger a pointless switch.
5. As a user, I want a "New profile…" menu item that asks for a name, so that I can add a third account without touching the terminal.
6. As a user, I want a new profile to open Claude signed out, so that I sign into the new account once and it is remembered afterwards.
7. As a user, I want each profile to keep its own login, settings, MCP server config, connectors, Code-tab sessions and scratch workspaces, so that accounts never leak into each other.
8. As a user, I want my existing Claude data to become the `work` profile on first use, so that nothing I have today is lost or needs reconfiguring.
9. As a user, I want Claude asked to quit normally before a switch, so that it can save its state and stop its helpers cleanly.
10. As a user, I want a switch cancelled if Claude has not fully exited within 15 seconds (for example because it shows a "sessions are running" prompt), so that running Code sessions are never killed.
11. As a user, I want the switcher to never force-quit Claude, so that I am the one who decides to interrupt running work.
12. As a user, I want the switcher to wait until no Claude process remains, background helpers included, so that no process writes into a folder while it's being moved.
13. As a user, I want a clear message saying why a switch was cancelled, so that I know what to do (close the running sessions and try again).
14. As a user, I want a half-finished swap undone automatically if a step fails, so that I never end up with a missing or mixed-up data folder.
15. As a user, I want two switches started at the same time (double click, menu plus terminal) to be refused, so that they can't corrupt the folders.
16. As a user, I want a leftover lock from a crashed switch to be detected and cleared safely, so that one failure doesn't block switching forever.
17. As a user, I want Claude reopened automatically after a successful switch, so that a switch is one action, not three.
18. As a user, I want a macOS notification such as "Claude → personal" after each switch, so that I get confirmation without looking at the menu bar.
19. As a user, I want the menu bar label to update right after a switch, not only on the next periodic refresh, so that it never shows the wrong account.
20. As a user, I want Claude to always see its normal data folder path, so that features which depend on that path (local pairing, saved worktree and workspace paths) keep working.
21. As a user, I want the active profile to stay active however I open Claude afterwards (Dock, Spotlight, after an update), so that I'm never surprised by the wrong account.
22. As a terminal user, I want `claude-switch <name>` to switch to a named profile, so that I can script or run it without the menu bar.
23. As a terminal user, I want `claude-switch toggle` to switch to the other profile when there are exactly two, so that the common case is one short command.
24. As a terminal user, I want `claude-switch status` to print the active profile name, so that scripts and the menu bar can read it.
25. As a terminal user, I want `claude-switch list` to print all profiles and mark the active one, so that I can see what's stored.
26. As a user, I want switching to the profile that is already active to do nothing and say so, so that it's safe to click twice.
27. As a user, I want invalid profile names (empty, containing slashes, dots-only, or otherwise unsafe as folder names) rejected, so that the tool can't be tricked into moving folders outside its profiles folder.
28. As a user, I want the switcher to refuse to run if it finds the live data folder unlabelled while labelled profiles already exist, so that an unknown folder is never silently overwritten or mislabelled.
29. As a user, I want the switcher to refuse to run if the live data folder is missing, so that it doesn't invent state it can't explain.
30. As a user, I want the `claude` terminal command's own login left untouched by a switch, so that running terminal sessions don't change accounts underneath me.
31. As a user, I want the shared Keychain encryption key left untouched, so that every stored profile keeps decrypting correctly.
32. As a user, I want "Open profiles folder" in the menu, so that I can inspect or back up profiles in Finder.
33. As a user, I want the menu bar item to start at login, so that the switcher is always there without me launching anything.
34. As a user, I want the tool to have no paid or Claude-specific third-party dependencies, so that I own and understand everything it does.
35. As a maintainer, I want all real side effects (quitting, process checks, launching, notifications) to go through one replaceable layer, so that the tool can be tested without touching the real Claude app.
36. As a maintainer, I want the data location overridable, so that tests run against a throwaway folder and never against my real data.
37. As a maintainer, I want the menu bar plugin to contain no logic, so that the whole feature is tested through the CLI alone.

## Implementation Decisions

**Modules**

- **`claude-switch` CLI** (zsh, no dependencies beyond macOS built-ins). The only module with logic. It owns profile bookkeeping, locking, the swap and rollback, and menu rendering.
- **SwiftBar plugin** (a few lines of zsh). It runs `claude-switch menu` and prints the result. It contains no logic of its own. Its file name sets a 1-minute refresh interval, and switch actions ask SwiftBar to refresh right after they finish.
- **Install step** (documented, optionally a small install script). It puts the CLI on `PATH`, installs SwiftBar via Homebrew cask, places the plugin in SwiftBar's plugin folder, and tells the user to enable "open at login".

**CLI interface**

- `claude-switch <name>`: switch to that profile, creating it empty if it doesn't exist.
- `claude-switch toggle`: switch to the other profile. It's an error unless exactly two profiles exist.
- `claude-switch status`: print the active profile name.
- `claude-switch list`: print every profile, marking the active one.
- `claude-switch new <name>`: create and switch to an empty profile. Used by "New profile…".
- `claude-switch menu`: print the SwiftBar menu (header label plus items) in SwiftBar's text format.
- Exit codes are distinct and documented for: success, already active, Claude didn't quit in time, lock held, invalid name or state, and rename failure (rolled back).

**Storage model**

- The **live folder** is the app's default data folder, `~/Library/Application Support/Claude`. The app always reads this path.
- **Stored profiles** live in a sibling folder, `Claude-profiles/<name>`. It is on the same volume, so swaps are plain atomic renames.
- Each profile carries a hidden **marker file** inside its folder holding its name. The active profile is the marker of the live folder.
- The **first run** happens when the live folder has no marker and no stored profiles exist. The live folder is labelled `work`.
- A **new profile** is an empty folder containing only its marker. Claude fills it on launch, and the user signs in once.

**Switch sequence**

1. Validate the target name and the current state.
2. Take the lock with an atomic `mkdir` of a lock directory holding the owner PID. If the lock is held by a dead PID, clear it and take it.
3. Ask Claude to quit via AppleScript.
4. Poll every Claude process belonging to the app bundle (main app plus helpers) until none remain, for at most 15 seconds. On timeout, release the lock, notify, and exit without changing anything. Never send a kill signal.
5. Rename the live folder to `Claude-profiles/<current>`.
6. Rename `Claude-profiles/<target>` to the live folder, or create the empty target first.
7. If step 5 or 6 fails, reverse the renames that did succeed, so the original live folder is back in place.
8. Release the lock, reopen Claude, post the notification, and trigger a SwiftBar refresh.

**Side-effect boundary**

- Everything that touches the real app or the desktop goes through one small set of functions: request quit, is-running check, launch, notify, refresh menu bar.
- An environment variable can point that set at a stub script instead. A second environment variable overrides the base data directory (default `~/Library/Application Support`).

**Facts established by investigation (Claude 5.1231.2, bundle id `com.anthropic.claudefordesktop`)**

- All desktop login state (cookies, local/session storage, IndexedDB, OAuth caches in the app's config file) is inside the live folder.
- That state is encrypted with a single Keychain key ("Claude Safe Storage"). The key is shared by all profiles and does not depend on the folder path, so no Keychain changes are needed.
- The app's `CLAUDE_USER_DATA_DIR` environment variable is ignored on signed builds.
- Launching with `--user-data-dir` works, but it disables local pairing, and it only applies when the app is launched that way. That's why renaming folders was chosen over relocating the data folder.
- The Claude Code CLI login (`~/.claude`, `~/.claude.json`, the "Claude Code-credentials" Keychain item) is separate from the desktop login, and `claude-switch` deliberately doesn't touch it.
- Logs, `~/Library/Caches/com.anthropic.claudefordesktop*` and `~/Library/HTTPStorages/com.anthropic.claudefordesktop` are keyed by bundle id. They stay shared across profiles, which is harmless.

**Disk**

- Profiles are fully separate, with no symlinked caches or Claude Code bundle.
- Each active profile grows to roughly 1–1.5 GB. This is accepted.

## Testing Decisions

- **One seam: the `claude-switch` CLI, exercised as a black box.**
  - Tests set the data-directory override to a temporary folder and the side-effect override to a stub.
  - Each test runs commands and asserts only on externally visible results: the folder layout and marker files, the presence of the lock, the exit code, stdout/stderr, and the calls the stub recorded (quit requested, launch, notification text).
  - Tests never inspect internal functions or variables.
- **The stub is controllable per test.** It can:
  - report Claude as never exiting, to cover the timeout path
  - exit only after N polls, to cover a slow quit
  - fail a specific rename, to cover rollback; done via a hook or by making the destination unwritable
  - record every call to a log file
- **Cases to cover:**
  - first-run labelling
  - switching to an existing profile
  - switching to a new profile
  - switching to the active profile
  - `toggle` with two profiles, and refusing it otherwise
  - invalid names
  - an unlabelled live folder while profiles already exist
  - a missing live folder
  - quit timeout leaves everything unchanged and kill is never called
  - rollback after a failed rename
  - lock held by a live PID is refused, lock held by a dead PID is reclaimed
  - `status`, `list` and `menu` output, including the checkmark and disabled state for the active profile
- **The menu is covered through `claude-switch menu`.** The plugin is a one-line passthrough and gets no tests of its own.
- **Framework:** bats-core (installed via Homebrew). There's no prior art in this repo, since it is new.
- **The real swap is never tested automatically.** The first real switch is done by hand from the menu bar after install, because running it from inside Claude would quit the session running the test.

## Out of Scope

- Switching the Claude Code CLI account (`~/.claude`, its Keychain item). This could be a later `--cli` option.
- Running two accounts side by side via `--user-data-dir`.
- Sharing caches or the bundled Claude Code between profiles to save disk.
- A native Swift menu bar app. SwiftBar is used now, and the CLI contract lets it be replaced later without changes.
- Shortcuts-based triggers.
- Profile deletion, renaming, export or backup commands. Finder via "Open profiles folder" is enough for now.
- Handling an auto-update or "Reset App Data" that is in progress while a switch runs. These are documented as "don't do that".
- Windows or Linux.

## Further Notes

- **Code-tab sessions and scratch workspaces belong to the profile that created them.** They disappear from view while another profile is active and come back on switching back.
- **Never reset or delete the "Claude Safe Storage" Keychain item.** Every stored profile depends on it.
- **The app's internals may change between versions.** If a future version moves login state out of the live folder (for example into the Keychain per account), the folder-rename approach needs revisiting. The facts above were checked on version 5.1231.2.
