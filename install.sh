#!/usr/bin/env bash
#
# install.sh — put setup-website.sh on the PATH so it can be run from anywhere.
#
# Optional. `sudo ./setup-website.sh site.zip` works straight out of the repo;
# this just saves you from typing the path every time.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/usr/local/bin/setup-website.sh"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	exec sudo -- bash "$REPO_DIR/install.sh" "$@"
fi

chmod +x "$REPO_DIR/setup-website.sh" "$REPO_DIR/cloudflare-tunnel.sh"
ln -sfn "$REPO_DIR/setup-website.sh" "$TARGET"
ln -sfn "$REPO_DIR/cloudflare-tunnel.sh" /usr/local/bin/cloudflare-tunnel.sh

echo "Linked:"
echo "  $TARGET -> $REPO_DIR/setup-website.sh"
echo "  /usr/local/bin/cloudflare-tunnel.sh -> $REPO_DIR/cloudflare-tunnel.sh"
echo
echo "You can now run, from any directory:"
echo "  sudo setup-website.sh newfiles.zip"
echo
echo "Keep this repo where it is — the commands are symlinks back into it."
