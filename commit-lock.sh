#!/usr/bin/env bash
# agents/bin/commit-lock.sh
# Canonical path: C:\code\dotfiles\agents\bin\commit-lock.sh
# Reachable at runtime as ~/.agents/bin/commit-lock.sh
# (~/.agents is a junction to C:\code\dotfiles\agents).
#
# Portable, flock-free mutex that serialises git's shared index/HEAD when
# several agents commit into the SAME working tree at once. This is the ONLY
# automated piece of the shared-checkout commit story — the git steps themselves
# (what to stage, what to commit) are done MANUALLY by the agent, under this
# lock. See agents/060-committing.md for the operating rules and
# agents/details/commit-lock.md for the design.
#
# WHY THIS EXISTS
#   git has ONE index (.git/index, or .git/worktrees/<wt>/index) and ONE HEAD
#   per working tree. A main agent and the sub-agents it spawns all share that
#   one tree — sub-agents do NOT get their own worktree — so even when the
#   top-level workflow uses worktrees, concurrent stage+commit still races
#   .git/index.lock and can blend half-staged work. This serialises that step.
#
#   `flock` is unavailable in our Cygwin/Git-Bash environment, so we use the
#   classic portable primitives instead:
#     * acquire -> `mkdir LOCK`     (atomic create-or-fail on POSIX and NTFS)
#     * steal   -> `mv LOCK grave`  (rename(2) is atomic; exactly one stealer
#                                    wins, the rest get ENOENT)
#   STALENESS is judged by the lock DIRECTORY's own mtime, which `mkdir` sets
#   atomically at acquire time. A lock whose dir mtime is older than
#   AGENT_LOCK_STALE_SECS (default 300s = 5 min) is assumed crashed and may be
#   stolen, so one dead agent can never wedge the others forever. We key on the
#   dir mtime — NOT a file written inside it — on purpose: an acquirer that dies
#   between `mkdir` and writing its metadata, or a release whose `rm -rf` only
#   partially completes (a real intermittent failure on Windows when another
#   process has a handle open in the dir), would otherwise leave an orphan with
#   no readable epoch that could never be classed stale, wedging every waiter
#   until the timeout. The `epoch`/`owner` files inside are kept for logging
#   only. (Bug found 2026-05-30 by the concurrency self-test: 3 of 25 workers
#   hung to the 420s cap on exactly this orphan-with-no-epoch condition.)
#
# LOCK LOCATION
#   By default the lock and its log live in the repo's git dir
#   (`git rev-parse --absolute-git-dir`), e.g. <repo>/.git/commit.lock.
#   That is never tracked by git, and it auto-scopes to the exact index being
#   protected: every worktree has its own git dir (so independent worktrees get
#   independent locks), while all sub-agents sharing one checkout resolve the
#   same git dir and therefore share one lock — exactly what we want.
#
# CONFIG (all overridable via env; mainly for tests):
#   AGENT_LOCK_DIR         lock directory (default <gitdir>/commit.lock)
#   AGENT_LOCK_STALE_SECS  steal threshold in seconds vs dir mtime (default 300)
#   AGENT_LOCK_POLL_SECS   poll interval while waiting (default 2)
#   AGENT_LOCK_MAX_WAIT    safety cap on total wait (default 420; > stale so a
#                          steal always gets a chance before we give up)
#   AGENT_LOCK_LOG         log file (default <gitdir>/commit-lock.log)
#
# USAGE (two modes; pick one — both keep the critical section tiny)
#   1. Wrap your git in `run` (auto-releases, even on error):
#        ~/.agents/bin/commit-lock.sh run -- bash -c '
#          git add -- path/to/file && git commit -m "msg"'
#   2. Source it and drive the lock yourself, in ONE shell invocation:
#        source ~/.agents/bin/commit-lock.sh
#        lock_acquire || exit 1
#        git add -- path/to/file && git commit -m "msg"
#        lock_release
#   Do the slow part (deciding what to stage, building a patch) OUTSIDE the lock.

set -euo pipefail

# --- resolve defaults (git-dir aware, CWD-independent within the repo) -------
_lock_gitdir() { git rev-parse --absolute-git-dir 2>/dev/null || true; }
_LOCK_GITDIR="$(_lock_gitdir)"
# If we're not in a repo, fall back to CWD so sourcing never explodes. In real
# use you're always in the repo whose index you're protecting.
_LOCK_BASE="${_LOCK_GITDIR:-$(pwd)}"

AGENT_LOCK_DIR="${AGENT_LOCK_DIR:-$_LOCK_BASE/commit.lock}"
AGENT_LOCK_STALE_SECS="${AGENT_LOCK_STALE_SECS:-300}"
AGENT_LOCK_POLL_SECS="${AGENT_LOCK_POLL_SECS:-2}"
AGENT_LOCK_MAX_WAIT="${AGENT_LOCK_MAX_WAIT:-420}"
AGENT_LOCK_LOG="${AGENT_LOCK_LOG:-$_LOCK_BASE/commit-lock.log}"

_LOCK_HELD=0
_LOCK_ME="pid=$$ host=$(hostname 2>/dev/null || echo unknown)"

_lock_now()  { date +%s; }
_lock_log()  { printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$AGENT_LOCK_LOG" 2>/dev/null || true; }

# mtime (epoch secs) of the lock dir itself, set atomically by mkdir; empty if
# the dir vanished mid-check. `stat` is coreutils; `date -r` is the fallback.
_lock_dir_mtime() {
  stat -c %Y "$AGENT_LOCK_DIR" 2>/dev/null || date -r "$AGENT_LOCK_DIR" +%s 2>/dev/null || true
}

lock_acquire() {
  mkdir -p "$(dirname "$AGENT_LOCK_DIR")" 2>/dev/null || true
  local start; start="$(_lock_now)"

  while true; do
    if mkdir "$AGENT_LOCK_DIR" 2>/dev/null; then
      # Won the lock. mkdir already stamped the dir's mtime (our staleness
      # clock). Record owner+epoch for logging only; staleness never reads them.
      _lock_now                 > "$AGENT_LOCK_DIR/epoch"
      printf '%s\n' "$_LOCK_ME" > "$AGENT_LOCK_DIR/owner"
      _LOCK_HELD=1
      trap 'lock_release' EXIT INT TERM
      _lock_log "ACQUIRED ($_LOCK_ME)"
      return 0
    fi

    # Lock exists. Steal it if the DIR's mtime is older than the stale window.
    # (Using dir mtime, not a file inside, so a crashed/partial-rm orphan with
    # no readable epoch is still classed stale and can be reclaimed.)
    local mt age
    mt="$(_lock_dir_mtime)"
    if [ -n "$mt" ]; then
      age=$(( $(_lock_now) - mt ))
      if [ "$age" -ge "$AGENT_LOCK_STALE_SECS" ]; then
        local holder; holder="$(cat "$AGENT_LOCK_DIR/owner" 2>/dev/null || echo '?')"
        _lock_log "STALE (age=${age}s holder=$holder) -> stealing"
        # Atomic steal: rename the stale dir aside. Only one concurrent stealer
        # wins (the rest get ENOENT); then everyone re-races the mkdir above.
        local grave="$AGENT_LOCK_DIR.dead.$$.$(_lock_now)"
        if mv "$AGENT_LOCK_DIR" "$grave" 2>/dev/null; then
          rm -rf "$grave" 2>/dev/null || true
          _lock_log "STOLE stale lock (was held by $holder)"
        fi
        continue
      fi
    fi

    # A live holder has it — wait, unless we have waited too long.
    if [ $(( $(_lock_now) - start )) -ge "$AGENT_LOCK_MAX_WAIT" ]; then
      _lock_log "TIMEOUT after ${AGENT_LOCK_MAX_WAIT}s waiting for lock"
      echo "commit-lock: timed out after ${AGENT_LOCK_MAX_WAIT}s waiting for commit lock" >&2
      return 1
    fi
    sleep "$AGENT_LOCK_POLL_SECS"
  done
}

lock_release() {
  [ "${_LOCK_HELD:-0}" = "1" ] || return 0
  _LOCK_HELD=0
  # Free the lock. The ONLY recovery trigger is rm returning non-zero: while the
  # dir still exists, no other worker can mkdir it, so it is unambiguously ours
  # and a rename-aside is safe. We must NOT re-check `[ -d ]` after a *successful*
  # rm — by then a successor may have re-created the dir and entered its own
  # critical section, and mv-ing it aside would steal that live lock (two holders
  # -> lost update; exactly the race the self-test caught 2026-05-30). On Windows
  # `rm -rf` can transiently fail when another process holds a handle inside the
  # dir; the rename usually succeeds where the recursive delete didn't.
  if ! rm -rf "$AGENT_LOCK_DIR" 2>/dev/null; then
    local grave="$AGENT_LOCK_DIR.rel.$$.$(_lock_now)"
    mv "$AGENT_LOCK_DIR" "$grave" 2>/dev/null && rm -rf "$grave" 2>/dev/null
    # If even the rename failed, the dir-mtime stale check is the final backstop.
  fi
  _lock_log "RELEASED ($_LOCK_ME)"
}

# Run a command under the lock; always release; propagate the command's exit code.
lock_run() {
  lock_acquire || return 1
  local rc=0
  "$@" || rc=$?
  lock_release
  return "$rc"
}

# --- CLI (only when executed directly, not when sourced) --------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    run)
      [ "${1:-}" = "--" ] && shift
      [ "$#" -gt 0 ] || { echo "usage: commit-lock.sh run -- <command...>" >&2; exit 2; }
      lock_run "$@"
      ;;
    *)
      echo "usage: commit-lock.sh run -- <command...>" >&2
      echo "   or: source commit-lock.sh; lock_acquire; <git...>; lock_release" >&2
      exit 2
      ;;
  esac
fi
