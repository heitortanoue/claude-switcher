#!/bin/zsh
# SwiftBar plugin: no logic, just prints the menu from the CLI. Refreshes every 1 minute.
for c in "$HOME/.local/bin/claude-switch" "$(command -v claude-switch 2>/dev/null)" "${0:A:h:h}/bin/claude-switch"; do
  [[ -x "$c" ]] && exec "$c" menu
done
echo "✳ ?"
echo "---"
echo "claude-switch not found | color=red"
