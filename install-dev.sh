#!/usr/bin/env bash
# Copy this repo into the Omarchy user plugin dir.
# Saving under ~/.config/omarchy/plugins/ reloads plugin code; if a
# change does not apply, run: omarchy-shell shell rescanPlugins
# (that already clears the QML component cache).
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${HOME}/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata"

mkdir -p "$dest"
rsync -a --delete --exclude .git --exclude '*.png' "$src/" "$dest/"
omarchy plugin validate "$dest"
# rm -rf "${HOME}/.cache/quickshell/qmlcache"
# omarchy restart shell
echo "Installed $dest"
echo "Host: omarchy bar set io.github.bonesgit.omarchy-netdata host localhost"
