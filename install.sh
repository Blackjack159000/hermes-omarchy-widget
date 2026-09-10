#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hermes Hub — bar widget installer.
#
#   bash install.sh
#
# Idempotent. Safe to re-run after editing, and safe to run over an existing
# install (your bar layout settings are preserved).
#
# What it does:
#   1. checks that agents are actually discoverable on this machine, and tells
#      you how to fix it if they are not (before you wonder why it's blank)
#   2. validates the manifest against the Omarchy plugin schema
#   3. copies the plugin into ~/.config/omarchy/plugins/
#   4. restarts the shell and enables the widget in the bar
# ---------------------------------------------------------------------------
set -euo pipefail

PLUGIN_ID="io.github.giulio.hermes-hub"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"

echo "== Hermes Hub installer =="
echo "  source: $SRC_DIR"
echo "  dest:   $DEST"
echo

for required in manifest.json Widget.qml bridge.py assets; do
  [[ -e "$SRC_DIR/$required" ]] || {
    echo "!! missing required file: $SRC_DIR/$required" >&2
    exit 1
  }
done

command -v python3 >/dev/null 2>&1 || {
  echo "!! python3 is required — the bridge is stdlib-only Python 3" >&2
  exit 1
}

# --- 1. will it actually have anything to show? ----------------------------
echo "== checking agent discovery =="
if ! python3 "$SRC_DIR/bridge.py" --check; then
  echo
  echo "!! No Hermes agents are discoverable on this machine yet. The widget will"
  echo "   still install, but its panel stays empty until that is fixed — see the"
  echo "   message above, or README.md -> 'What it needs from your machine'."
  echo
fi

# --- 2. validate -----------------------------------------------------------
if command -v omarchy >/dev/null 2>&1; then
  echo "== validating manifest =="
  omarchy plugin validate "$SRC_DIR" || true
fi

# --- 3. install ------------------------------------------------------------
mkdir -p "$DEST/assets"
install -m 0644 "$SRC_DIR/manifest.json" "$SRC_DIR/Widget.qml" "$SRC_DIR/bridge.py" "$DEST/"
cp -R "$SRC_DIR/assets/." "$DEST/assets/"
echo "== installed into $DEST"

# --- 4. load + enable ------------------------------------------------------
if command -v omarchy >/dev/null 2>&1; then
  echo "== restarting the shell to load it =="
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo "== enabling the bar widget =="
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin enable "$PLUGIN_ID" right >/dev/null 2>&1 \
    || omarchy plugin enable "$PLUGIN_ID" --section right >/dev/null 2>&1 \
    || true
fi

# Where did it actually land? The section matters: Omarchy reveals `center` only
# while the pointer is over the bar, so a centre-placed icon is invisible most of
# the time. Claiming "right" without checking is how you ship a widget nobody sees.
SHELL_JSON="$HOME/.config/omarchy/shell.json"
SECTION="$(python3 - "$SHELL_JSON" "$PLUGIN_ID" <<'PY'
import json, sys

path, pid = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
for section in ("left", "center", "right"):
    for entry in (data.get("bar", {}).get("layout", {}).get(section) or []):
        if isinstance(entry, dict) and entry.get("id") == pid:
            print(section)
            sys.exit(0)
PY
)"

case "$SECTION" in
  right | left)
    echo "   enabled in the bar ($SECTION section) — always visible"
    ;;
  center)
    cat <<MSG
   enabled in the bar (CENTER section).
   NOTE: Omarchy reveals the centre section only while the pointer is over the
   bar, so this icon is hidden most of the time. For an always-visible icon, move
   {"id": "$PLUGIN_ID"} into bar.layout.right in $SHELL_JSON, then run:
       omarchy restart shell
MSG
    ;;
  *)
    cat <<MSG
!! Could not confirm the widget is in the bar. Add it by hand:
     1. edit $SHELL_JSON
     2. add {"id": "$PLUGIN_ID"} to bar.layout.right
     3. omarchy restart shell
MSG
    ;;
esac

echo
echo "== done =="
echo "The bar should now show the Hermes icon."
echo "If the panel is empty, diagnose it with:  bash $SRC_DIR/doctor.sh"
echo "Remove the widget with:                   omarchy plugin remove $PLUGIN_ID"
