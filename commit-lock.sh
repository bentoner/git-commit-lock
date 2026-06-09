#!/usr/bin/env bash
# commit-lock.sh — repo: ben/commit-lock
# Canonical path: C:\code\commit-lock\commit-lock.sh
# Reachable at runtime as ~/.local/bin/commit-lock.sh
# (symlinked there by this repo's install.sh).
#
# Portable, flock-free mutex that serialises git's shared index/HEAD when
# several agents commit into the SAME working tree at once. This is the ONLY
# automated piece of the shared-checkout commit story — the git steps themselves
# (what to stage, what to commit) are done MANUALLY by the agent, under this
# lock. The agent operating rules live in dotfiles agents/210-using-git.md;
# the design rationale is in docs/commit-lock.md.
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
#   no readable token that could never be classed stale, wedging every waiter
#   until the timeout. The files inside the dir are for ownership/logging only.
#   (Bug found 2026-05-30 by the concurrency self-test: 3 of 25 workers hung to
#   the 420s cap on exactly this orphan-with-no-metadata condition.)
#
# FAIL-OPEN CEILING + the holder's responsibility (important)
#   The stale window is a LEASE, and the dir mtime is stamped once at mkdir and
#   NOT refreshed while held. So a holder whose critical section runs longer than
#   AGENT_LOCK_STALE_SECS has its still-live lock stolen — the lock "fails open".
#   We do NOT prevent this with a background heartbeat (keeps the tool a single
#   synchronous script). Instead the contract is: COMMITS MUST BE FAST (the
#   golden rule — well under the window; git commits should be sub-second, not
#   minutes), and a holder that was nonetheless too slow DETECTS the theft when
#   it returns: lock_release verifies the dir still carries our token and, if
#   not, logs a loud WARNING and returns non-zero instead of reporting success.
#   Any steal that overlaps the holder's actual git work happens before release
#   and is therefore caught; a steal landing after the work is benign. If you
#   genuinely must run something slow under the lock (e.g. a heavy pre-commit
#   hook), raise AGENT_LOCK_STALE_SECS for that invocation.
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
#   AGENT_LOCK_STALE_SECS  steal threshold in seconds vs dir mtime (default 300).
#                          Hard fail-open ceiling: keep it >> (max hold + any
#                          clock skew); do not use sub-5s windows outside tests.
#   AGENT_LOCK_POLL_SECS   poll interval while waiting (default 2)
#   AGENT_LOCK_MAX_WAIT    safety cap on total wait (default 420; > stale so a
#                          steal always gets a chance before we give up)
#   AGENT_LOCK_LOG         log file (default <gitdir>/commit-lock.log)
#
# USAGE (two modes; pick one — both keep the critical section tiny)
#   1. Wrap your git in `run` (auto-releases; exit code is your command's,
#      OR 2 if the lock was lost mid-hold — treat 2 as "NOT exclusive, redo"):
#        ~/.local/bin/commit-lock.sh run -- bash -c '
#          git add -- path/to/file && git commit -m "msg"'
#   2. Source it and drive the lock yourself, in ONE shell invocation:
#        source ~/.local/bin/commit-lock.sh
#        lock_acquire || exit 1
#        git add -- path/to/file && git commit -m "msg"
#        lock_release || echo "WARNING: lock was lost; commit was not exclusive" >&2
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
# Unique per acquisition: identifies OUR hold so release can tell whether the
# lock we are about to free is still the one we took (vs. stolen + re-acquired
# by someone else). pid alone is not enough — pids get reused across the 5-min
# window — so mix in $RANDOM and the acquire time.
_LOCK_TOKEN=""

_lock_now()  { date +%s; }
_lock_log()  { printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$AGENT_LOCK_LOG" 2>/dev/null || true; }

# mtime (epoch secs) of the lock dir itself, set atomically by mkdir; empty if
# the dir vanished mid-check. `stat` is coreutils; `date -r` is the fallback.
_lock_dir_mtime() {
  stat -c %Y "$AGENT_LOCK_DIR" 2>/dev/null || date -r "$AGENT_LOCK_DIR" +%s 2>/dev/null || true
}

# token currently recorded in the lock dir (whoever holds it now), or empty.
_lock_cur_token() { cat "$AGENT_LOCK_DIR/token" 2>/dev/null || true; }

lock_acquire() {
  mkdir -p "$(dirname "$AGENT_LOCK_DIR")" 2>/dev/null || true
  local start; start="$(_lock_now)"
  _LOCK_TOKEN="tok.$$.${RANDOM}.$(_lock_now)"

  while true; do
    if mkdir "$AGENT_LOCK_DIR" 2>/dev/null; then
      # Won the lock. mkdir already stamped the dir's mtime (our staleness
      # clock). Write our token (used by lock_release to confirm we still own
      # the lock) plus owner+epoch for logging. All guarded: the dir definitely
      # exists here, but a failed write must never abort under `set -e`.
      printf '%s\n' "$_LOCK_TOKEN" > "$AGENT_LOCK_DIR/token" 2>/dev/null || true
      _lock_now                    > "$AGENT_LOCK_DIR/epoch" 2>/dev/null || true
      printf '%s\n' "$_LOCK_ME"    > "$AGENT_LOCK_DIR/owner" 2>/dev/null || true
      _LOCK_HELD=1
      trap 'lock_release || true' EXIT INT TERM
      _lock_log "ACQUIRED ($_LOCK_ME tok=$_LOCK_TOKEN)"
      return 0
    fi

    # Lock exists. Steal it if the DIR's mtime is older than the stale window.
    # (Using dir mtime, not a file inside, so a crashed/partial-rm orphan with
    # no readable token is still classed stale and can be reclaimed.)
    # BUT only on a PLAUSIBLE mtime (>= 2000-01-01): a freshly created dir can
    # transiently report the Windows FILETIME zero (1601) before its first
    # metadata write, which would look ~400 years old and spuriously steal a live,
    # just-acquired lock (notably one created by commit-lock.ps1's atomic rename;
    # cross-impl race the interop self-test caught 2026-06-03). A sub-floor read is
    # unsettled, not stale, so we wait instead.
    local mt age
    mt="$(_lock_dir_mtime)"
    if [ -n "$mt" ] && [ "$mt" -gt 946684800 ] 2>/dev/null; then
      age=$(( $(_lock_now) - mt ))
      if [ "$age" -ge "$AGENT_LOCK_STALE_SECS" ]; then
        local holder; holder="$(cat "$AGENT_LOCK_DIR/owner" 2>/dev/null || echo '?')"
        _lock_log "STALE (age=${age}s holder=$holder) -> stealing"
        # Atomic steal: rename the stale dir aside. Only one concurrent stealer
        # wins (the rest get ENOENT); then everyone re-races the mkdir above.
        # The victim (if still alive) will fail at ITS lock_release: the dir it
        # finds will carry our token, not its own.
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

# Release. Returns 0 if we held the lock cleanly throughout; returns 2 (and logs
# a loud WARNING) if our lease had been stolen before release — meaning the work
# we just did was NOT under exclusive protection and should be treated as failed.
lock_release() {
  [ "${_LOCK_HELD:-0}" = "1" ] || return 0
  _LOCK_HELD=0

  # Did we keep the lock the whole time? Compare the dir's current token to ours.
  local cur; cur="$(_lock_cur_token)"
  if [ "$cur" != "$_LOCK_TOKEN" ]; then
    # Our lease expired and the lock was stolen (and possibly re-acquired by
    # someone else). Do NOT delete the dir — it may be a successor's LIVE lock.
    # Loudly report that this hold was not exclusive.
    _lock_log "WARNING: lock LOST before release (held longer than ${AGENT_LOCK_STALE_SECS}s stale window; stolen). This commit was NOT exclusive — redo it. (ours=$_LOCK_TOKEN now=${cur:-<none>})"
    echo "commit-lock: WARNING — lock was stolen mid-hold (held > ${AGENT_LOCK_STALE_SECS}s). Your commit was NOT serialised; verify with 'git log' and redo under the lock." >&2
    return 2
  fi

  # Still ours — free it. Recovery (rename-aside) triggers ONLY on a non-zero
  # rm: while the dir exists no one else can mkdir it, so it is unambiguously
  # ours and the rename is safe. We must NOT re-check `[ -d ]` after a
  # *successful* rm — by then a successor may have re-created the dir and entered
  # its own critical section, and mv-ing it aside would steal that live lock
  # (two holders -> lost update; race the self-test caught 2026-05-30). On
  # Windows `rm -rf` can transiently fail when another process holds a handle in
  # the dir; the rename usually succeeds where the recursive delete didn't.
  if ! rm -rf "$AGENT_LOCK_DIR" 2>/dev/null; then
    local grave="$AGENT_LOCK_DIR.rel.$$.$(_lock_now)"
    mv "$AGENT_LOCK_DIR" "$grave" 2>/dev/null && rm -rf "$grave" 2>/dev/null
    # If even the rename failed, the dir-mtime stale check is the final backstop.
  fi
  _lock_log "RELEASED ($_LOCK_ME tok=$_LOCK_TOKEN)"
  return 0
}

# Run a command under the lock; always release; propagate the command's exit
# code — UNLESS the lock was lost mid-hold, in which case return 2 (exclusivity
# failure overrides a "successful" command, because it wasn't serialised).
lock_run() {
  lock_acquire || return 1
  local rc=0
  "$@" || rc=$?
  local rel=0
  lock_release || rel=$?
  if [ "$rel" -ne 0 ]; then
    return "$rel"
  fi
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
