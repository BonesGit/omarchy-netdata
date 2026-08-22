#!/usr/bin/env bash
# Copy this repo into the Omarchy user plugin dir and bounce the shell.
# Hot-reload often keeps a stale QML/JS cache, so a restart is required
# for Panel/Model changes to actually show up.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${HOME}/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata"

mkdir -p "$dest"
rsync -a --delete --exclude .git --exclude '*.png' "$src/" "$dest/"
omarchy plugin validate "$dest"
rm -rf "${HOME}/.cache/quickshell/qmlcache"
omarchy restart shell
echo "Installed $dest and restarted omarchy-shell"
echo "Host: omarchy bar set io.github.bonesgit.omarchy-netdata host localhost"
