#!/bin/zsh
# Installs claude-switch and the SwiftBar plugin. Safe to re-run.
set -e
ROOT="${0:A:h}"

mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/bin/claude-switch" "$HOME/.local/bin/claude-switch"
echo "Linked ~/.local/bin/claude-switch"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "Note: add ~/.local/bin to your PATH." ;; esac

if [[ ! -d /Applications/SwiftBar.app ]] && ! brew list --cask swiftbar >/dev/null 2>&1; then
  brew install --cask swiftbar
fi

PLUGDIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [[ -z "$PLUGDIR" ]]; then
  PLUGDIR="$HOME/Library/Application Support/SwiftBar/Plugins"
  mkdir -p "$PLUGDIR"
  defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGDIR"
fi
mkdir -p "$PLUGDIR"
chmod +x "$ROOT/swiftbar/claude-profile.1m.sh"
ln -sf "$ROOT/swiftbar/claude-profile.1m.sh" "$PLUGDIR/claude-profile.1m.sh"
echo "Linked plugin into $PLUGDIR"

open -g "swiftbar://refreshallplugins" 2>/dev/null || true

# Terminal `claude` follows the active profile (separate CLI login per profile).
ZRC="${ZDOTDIR:-$HOME}/.zshrc"
HOOK='command -v claude-switch >/dev/null && eval "$(claude-switch shell-init)"  # claude-switch'
if ! grep -qF '# claude-switch' "$ZRC" 2>/dev/null; then
  printf '\n%s\n' "$HOOK" >> "$ZRC"
  echo "Added claude-switch shell hook to $ZRC (open a new terminal to use it)"
fi
"$ROOT/bin/claude-switch" cli-dir >/dev/null 2>&1 || true   # record which profile owns ~/.claude
cat <<'MSG'

Done. Remaining manual step:
  Open SwiftBar > Preferences (gear) > enable "Open at Login".
Then do the first real switch by hand from the menu bar.
MSG
