#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Hub — doctor.
#
#   bash doctor.sh
#
# Run this when the widget is installed but the panel looks empty. It reports
# where the bridge looked for agents, what it found, and whether each one
# answered the door.
# ---------------------------------------------------------------------------
set -uo pipefail

PLUGIN_ID="io.github.giulio.hermes-hub"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for CAND in "$HOME/.config/omarchy/plugins/$PLUGIN_ID" "$SELF_DIR"; do
  if [[ -f "$CAND/bridge.py" ]]; then
    echo "== Hermes Hub doctor =="
    echo "  plugin: $CAND"
    echo
    python3 "$CAND/bridge.py" --check
    status=$?
    echo
    echo "== bridge port =="
    if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':8650'; then
      echo "  127.0.0.1:8650 is listening"
    else
      echo "  127.0.0.1:8650 is not listening right now."
      echo "  Not a problem on its own — the widget starts the bridge when it loads."
      echo "  If the panel never loads at all, restart the shell: omarchy restart shell"
    fi
    exit $status
  fi
done

echo "!! Could not find bridge.py. Is the widget installed?" >&2
echo "   Install it with: bash $(dirname "$SELF_DIR")/install.sh" >&2
exit 1
