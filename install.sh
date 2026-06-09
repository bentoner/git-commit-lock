#!/usr/bin/env bash
# install.sh — symlink commit-lock.{sh,ps1} into ~/.local/bin.
# Canonical path: C:\code\commit-lock\install.sh | repo: ben/commit-lock
#
# Idempotent: re-run any time (e.g. after moving the repo). Real Windows symlinks
# need Developer Mode on (Ben's box has it) plus the MSYS flag below; on Linux
# plain `ln -s` makes a real link. Logs each link it creates (old + new target).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
mkdir -p "$DEST"

export MSYS=winsymlinks:nativestrict   # real symlinks on Windows Git-Bash

for f in commit-lock.sh commit-lock.ps1; do
    src="$REPO/$f"
    dst="$DEST/$f"
    [ -f "$src" ] || { echo "install.sh: missing $src" >&2; exit 1; }
    prev="$(readlink "$dst" 2>/dev/null || echo '(none)')"
    ln -sf "$src" "$dst"
    printf 'linked %s\n   was: %s\n   now: %s\n' "$dst" "$prev" "$src"
done

case ":${PATH}:" in
    *":${DEST}:"*) : ;;
    *) echo "install.sh: NOTE — $DEST is not on PATH; add it so 'commit-lock.sh' resolves." >&2 ;;
esac

echo "commit-lock installed to $DEST."
