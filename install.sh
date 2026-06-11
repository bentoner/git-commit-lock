#!/usr/bin/env bash
# install.sh — install git-commit-lock.{sh,ps1} into ~/.local/bin.
#
# Prefers a symlink; if symlinking fails (e.g. Windows without Developer Mode —
# the MSYS flag below makes `ln -s` fail loudly there instead of silently
# copying), falls back to copying the script, which works identically because
# both scripts are self-contained. Idempotent: re-run any time (e.g. after
# moving the repo, or to refresh copies after updating the clone). Logs each
# file it installs (mode, old + new target).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
    echo "install.sh: $DEST exists but is not a directory - move it aside, then re-run." >&2
    exit 1
fi
mkdir -p "$DEST"

export MSYS=winsymlinks:nativestrict   # real symlinks on Windows Git-Bash (or fail, never copy)

copied=0
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
    rm -f "$dst"   # clear any previous symlink or copy so both lanes start clean
    if ln -s "$src" "$dst" 2>/dev/null; then
        printf 'linked %s\n   was: %s\n   now: %s\n' "$dst" "$prev" "$src"
    else
        cp "$src" "$dst" || { echo "install.sh: could not link or copy $f into $DEST" >&2; exit 1; }
        chmod a+x "$dst"
        copied=1
        printf 'copied %s (symlinks unavailable)\n   was: %s\n   now: copy of %s\n' "$dst" "$prev" "$src"
    fi
done

case ":${PATH}:" in
    *":${DEST}:"*) : ;;
    *) echo "install.sh: NOTE — $DEST is not on PATH; add it so 'git-commit-lock.sh' resolves." >&2 ;;
esac

echo "git-commit-lock installed to $DEST."
if [ "$copied" -eq 1 ]; then
    echo "install.sh: NOTE — installed as copies, which don't track the repo; re-run install.sh after updating the clone." >&2
fi
