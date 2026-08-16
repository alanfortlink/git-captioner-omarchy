#!/bin/bash
# Install this checkout as an Omarchy plugin for the current user.
#   ./install.sh             symlink into ~/.config/omarchy/plugins, rescan, enable in the bar
#   ./install.sh --uninstall remove the symlink and disable the widget
#
# Only needed when hacking on the plugin from a checkout somewhere else; a
# normal install is `omarchy plugin add <repo-url> --enable`, which clones
# straight into the plugins directory and needs nothing from this script.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ID=alanfortlink.gif-captioner
PLUGIN=$HOME/.config/omarchy/plugins/$ID

if [[ ${1:-} == --uninstall ]]; then
  omarchy-plugin-disable "$ID" >/dev/null 2>&1 || true
  # Only ever remove a symlink: a real checkout here belongs to
  # `omarchy plugin remove`, not to us.
  if [[ -L $PLUGIN ]]; then
    rm -f "$PLUGIN"
    omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
    echo "removed the dev symlink"
  else
    echo "nothing to remove at $PLUGIN (not a symlink)"
  fi
  exit 0
fi

missing=()
for cmd in ffmpeg ffprobe curl wl-copy fc-match; do
  command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if ((${#missing[@]})); then
  echo "error: missing commands: ${missing[*]}" >&2
  echo "  install them with: sudo pacman -S --needed ffmpeg curl wl-clipboard fontconfig" >&2
  exit 1
fi

mkdir -p "$(dirname "$PLUGIN")"
if [[ $(readlink -f "$PLUGIN" 2>/dev/null) != "$(readlink -f "$HERE")" ]]; then
  if [[ -e $PLUGIN && ! -L $PLUGIN ]]; then
    echo "error: $PLUGIN exists and is not a symlink; remove it first (omarchy plugin remove $ID)" >&2
    exit 1
  fi
  ln -sfn "$HERE" "$PLUGIN"
  echo "› linked $PLUGIN -> $HERE"
fi

if command -v omarchy-shell >/dev/null && omarchy-shell -q shell ping >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins >/dev/null 2>&1 || true
  enabled() { omarchy-plugin-list 2>/dev/null | awk -v id="$ID" '$1 == id && $2 == "enabled" { found = 1 } END { exit !found }'; }
  for _ in 1 2 3 4 5; do
    if enabled; then break; fi
    omarchy-plugin-enable "$ID" right >/dev/null 2>&1 && { echo "  enabled $ID"; break; }
    sleep 1
  done
  enabled || echo "  note: not enabled yet; run: omarchy plugin enable $ID"
else
  echo "  note: omarchy-shell is not running; enable later with: omarchy plugin enable $ID"
fi

echo "done. A GIF icon appears in the bar (if not: omarchy-shell shell rescanPlugins)."
