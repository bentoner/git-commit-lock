#!/usr/bin/env bash
# install.sh — symlink git-commit-lock.{sh,ps1} into ~/.local/bin.
#
# Idempotent: re-run any time (e.g. after moving the repo). Real Windows symlinks
# need Developer Mode on, plus the MSYS flag below; on Linux plain `ln -s` makes
# a real link. Logs each link it creates (old + new target).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
    echo "install.sh: $DEST exists but is not a directory - move it aside, then re-run." >&2
    exit 1
fi
mkdir -p "$DEST"

export MSYS=winsymlinks:nativestrict   # real symlinks on Windows Git-Bash

for f in git-commit-lock.sh git-commit-lock.ps1; do
    src="$REPO/$f"
    dst="$DEST/$f"
    [ -f "$src" ] || { echo "install.sh: missing $src" >&2; exit 1; }
    if [ -L "$dst" ]; then
        prev="$(readlink "$dst" 2>/dev/null || echo '(unreadable symlink)')"
    elif [ -d "$dst" ]; then
        echo "install.sh: $dst exists and is a directory - remove it, then re-run." >&2
        exit 1
    elif [ -e "$dst" ]; then
        prev='(regular file - replaced)'
    else
        prev='(none)'
    fi
    ln -sf "$src" "$dst"
    printf 'linked %s\n   was: %s\n   now: %s\n' "$dst" "$prev" "$src"
done

case ":${PATH}:" in
    *":${DEST}:"*) : ;;
    *) echo "install.sh: NOTE — $DEST is not on PATH; add it so 'git-commit-lock.sh' resolves." >&2 ;;
esac

echo "git-commit-lock installed to $DEST."
