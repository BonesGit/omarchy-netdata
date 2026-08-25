#!/usr/bin/env bash
# Copy this repo into the Omarchy user plugin dir.
# Live bar instances do not pick this up until:
#   omarchy restart shell
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${HOME}/.config/omarchy/plugins/io.github.bonesgit.omarchy-netdata"

mkdir -p "$dest"
rsync -a --delete --exclude .git --exclude '*.png' "$src/" "$dest/"
omarchy plugin validate "$dest"
# rm -rf "${HOME}/.cache/quickshell/qmlcache"
omarchy restart shell
echo "Installed $dest"
echo "Host: omarchy bar set io.github.bonesgit.omarchy-netdata host localhost"
