#!/usr/bin/env bash
# git-commit-lock.sh — the git-commit-lock mutex (bash implementation).
# Reachable at runtime as ~/.local/bin/git-commit-lock.sh
# (symlinked there by this repo's install.sh).
#
# Portable, flock-free mutex that serialises git's shared index/HEAD when
# several agents commit into the SAME working tree at once. The tool automates
# only the lock — the git steps themselves (what to stage, what to commit) are
# done MANUALLY by the agent, under this lock. Suggested agent operating rules
# live in README.md ("Suggested agent instructions"); the design rationale is
# in docs/git-commit-lock.md.
#
# WHY THIS EXISTS
#   git has ONE index (.git/index, or .git/worktrees/<wt>/index) and ONE HEAD
#   per working tree. A main agent and the sub-agents it spawns all share that
#   one tree — sub-agents do NOT get their own worktree — so even when the
#   top-level workflow uses worktrees, concurrent stage+commit still races
#   .git/index.lock and can blend half-staged work. This serialises that step.
#
#   `flock` is not portably available (absent on macOS, and on many Windows
#   Git-Bash/Cygwin setups), so we use the classic portable primitives instead:
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
#   until the timeout. Of the files inside the dir, `token` is LOAD-BEARING —
#   it is how lock_release detects that the lease was stolen mid-hold — while
#   `owner` and `epoch` are informational (logging/diagnostics only).
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
#   not, logs a loud WARNING and returns 98 instead of reporting success.
#   Any steal that overlaps the holder's actual git work happens before release
#   and is therefore caught; a steal landing after the work is benign. If you
#   genuinely must run something slow under the lock (e.g. a heavy pre-commit
#   hook), raise AGENT_LOCK_STALE_SECS for that invocation.
#
# KNOWN RESIDUAL RACES (detected, not silent)
#   The mkdir/mv/rm primitives cannot make check-then-act fully atomic, so two
#   narrow windows remain even after the re-checks below shrink them:
#     * acquire-side: between re-reading the stale dir's mtime and the steal
#       `mv`, a rival stealer can complete steal+re-acquire, so our `mv` would
#       move a brand-new live lock aside;
#     * release-side: between the final token re-read and `rm -rf`, a
#       boundary-stale steal + re-acquire can slip in, so the `rm` would delete
#       the successor's live lock.
#   Both need a hold that already overran the stale window (a contract breach),
#   and both are DETECTED: the displaced holder's lock_release finds a missing/
#   foreign token and fails loudly with 98, so no silent lost update — the cost
#   is a spurious "redo" plus a transient double-hold. (A rename-the-lock-aside
#   release design was considered and rejected: after a boundary steal it can
#   yank a SUCCESSOR's live lock, which is strictly worse.)
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
#   AGENT_LOCK_MAX_WAIT    safety cap on total wait (default 420; keep it >
#                          stale so a steal always gets a chance before we
#                          give up — a warning is printed if it is not)
#   AGENT_LOCK_LOG         log file (default <gitdir>/git-commit-lock.log)
#
# EXIT CODES (the published contract — do not repurpose)
#   `run` exits with the wrapped command's own exit code, EXCEPT three
#   reserved high codes:
#     96  usage error (bad/missing arguments, or `run` outside a git repo with
#         no AGENT_LOCK_DIR override) — the command was NEVER run
#     97  timed out waiting for the lock — the command was NEVER run
#     98  lock stolen mid-hold — the command RAN but was NOT serialised;
#         treat the work as failed and redo it under the lock
#   (A wrapped command that itself exits 96/97/98 is indistinguishable from
#   these; avoid those codes in wrapped commands.)
#   Sourced API: lock_acquire returns 97 on timeout and 1 on API misuse
#   (reentrant acquire); lock_release returns 98 if the lease was stolen
#   mid-hold and 1 if the lock dir could not be removed (stale-window backstop
#   recovers it).
#
# USAGE (two modes; pick one — both keep the critical section tiny)
#   1. Wrap your git in `run` (auto-releases; exit codes above):
#        ~/.local/bin/git-commit-lock.sh run -- bash -c '
#          git add -- path/to/file && git commit -m "msg"'
#   2. Source it and drive the lock yourself, in ONE shell invocation:
#        source ~/.local/bin/git-commit-lock.sh
#        lock_acquire || exit 1
#        git add -- path/to/file && git commit -m "msg"
#        lock_release || echo "WARNING: lock was lost; commit was not exclusive" >&2
#   Do the slow part (deciding what to stage, building a patch) OUTSIDE the lock.

# Strict mode is scoped to EXECUTED mode only: sourcing must not impose
# errexit/nounset/pipefail on the caller's shell. The library functions below
# are written to behave correctly with or without errexit in effect.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
fi

# --- resolve defaults (git-dir aware, CWD-independent within the repo) -------
_lock_gitdir() { git rev-parse --absolute-git-dir 2>/dev/null || true; }
_LOCK_GITDIR="$(_lock_gitdir)"
# Remember whether the caller chose the lock location explicitly: outside a
# repo, `run` refuses to guess (see CLI below), while sourcing keeps a CWD
# fallback (with a logged warning) so sourcing never explodes.
if [ -n "${AGENT_LOCK_DIR:-}" ]; then _LOCK_DIR_EXPLICIT=1; else _LOCK_DIR_EXPLICIT=0; fi
_LOCK_BASE="${_LOCK_GITDIR:-$(pwd)}"

AGENT_LOCK_DIR="${AGENT_LOCK_DIR:-$_LOCK_BASE/commit.lock}"
AGENT_LOCK_STALE_SECS="${AGENT_LOCK_STALE_SECS:-300}"
AGENT_LOCK_POLL_SECS="${AGENT_LOCK_POLL_SECS:-2}"
AGENT_LOCK_MAX_WAIT="${AGENT_LOCK_MAX_WAIT:-420}"
AGENT_LOCK_LOG="${AGENT_LOCK_LOG:-$_LOCK_BASE/git-commit-lock.log}"

# Validate the numeric knobs once, at source time: a garbage POLL would
# busy-spin the mkdir loop, a garbage STALE would silently disable stealing,
# and a garbage MAX_WAIT would break the timeout arithmetic. On bad input,
# note it on stderr and fall back to the default rather than failing.
_lock_check_num() {  # $1=name $2=value $3=default $4=int|frac -> prints value to use
  local v="$2" ok=1
  case "$4" in
    int)  case "$v" in ''|*[!0-9]*) ok=0;; esac ;;
    frac) case "$v" in ''|.|*[!0-9.]*|*.*.*) ok=0;; esac ;;
  esac
  # Reject zero (e.g. "0", "0.0"): every knob must be strictly positive.
  if [ "$ok" = 1 ] && [ -z "$(printf '%s' "$v" | tr -d '0.')" ]; then ok=0; fi
  if [ "$ok" = 1 ]; then
    printf '%s' "$v"
  else
    echo "git-commit-lock: ignoring invalid $1='$v' (need a positive number); using default $3" >&2
    printf '%s' "$3"
  fi
}
AGENT_LOCK_STALE_SECS="$(_lock_check_num AGENT_LOCK_STALE_SECS "$AGENT_LOCK_STALE_SECS" 300 int)"
AGENT_LOCK_POLL_SECS="$(_lock_check_num AGENT_LOCK_POLL_SECS "$AGENT_LOCK_POLL_SECS" 2 frac)"
AGENT_LOCK_MAX_WAIT="$(_lock_check_num AGENT_LOCK_MAX_WAIT "$AGENT_LOCK_MAX_WAIT" 420 int)"

# A waiter gives up at MAX_WAIT, so if STALE >= MAX_WAIT every waiter times
# out before a crashed holder's lock could ever be stolen. Warn — this is
# almost always a misconfiguration (tests excepted).
if [ "$AGENT_LOCK_STALE_SECS" -ge "$AGENT_LOCK_MAX_WAIT" ]; then
  echo "git-commit-lock: warning — AGENT_LOCK_STALE_SECS ($AGENT_LOCK_STALE_SECS) >= AGENT_LOCK_MAX_WAIT ($AGENT_LOCK_MAX_WAIT): waiters will time out before a stale lock can be stolen" >&2
fi

_LOCK_HELD=0
_LOCK_ME="pid=$$ host=$(hostname 2>/dev/null || echo unknown)"
# Unique per acquisition: identifies OUR hold so release can tell whether the
# lock we are about to free is still the one we took (vs. stolen + re-acquired
# by someone else). pid alone is not enough — pids get reused across the 5-min
# window — so mix in $RANDOM and the acquire time.
_LOCK_TOKEN=""
# The caller's EXIT/INT/TERM traps as they were before lock_acquire installed
# ours (saved via `trap -p`, restored by lock_release on every path).
_LOCK_SAVED_TRAP_EXIT=""
_LOCK_SAVED_TRAP_INT=""
_LOCK_SAVED_TRAP_TERM=""

_lock_now()  { date +%s; }
_lock_log()  {
  # Dumb size cap: if the log has grown past ~1MB (it gains ~2 lines per
  # commit and nothing ever prunes it), start it over rather than rotating.
  if [ -f "$AGENT_LOCK_LOG" ] && [ "$(wc -c < "$AGENT_LOCK_LOG" 2>/dev/null || echo 0)" -gt 1048576 ] 2>/dev/null; then
    : > "$AGENT_LOCK_LOG" 2>/dev/null || true
    printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "log exceeded 1MB; truncated" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
  fi
  printf '%s [pid=%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$*" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
}

# Sourced outside a git repo without an explicit AGENT_LOCK_DIR: keep the CWD
# fallback (sourcing must never explode) but leave a trace that the lock is
# probably NOT protecting what the caller thinks it is.
if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_DIR_EXPLICIT" = 0 ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  _lock_log "WARNING: not inside a git repository; lock location falls back to CWD ($_LOCK_BASE) — set AGENT_LOCK_DIR explicitly if that is not intended"
fi

# mtime (epoch secs) of the lock dir itself, set atomically by mkdir; empty if
# the dir vanished mid-check. Probe chain: GNU stat (-c %Y), then BSD/macOS
# stat (-f %m), then GNU date (-r FILE +%s; BSD date -r takes seconds, so it
# fails harmlessly there). The numeric guard rejects any probe that "succeeds"
# with non-epoch output (e.g. GNU stat -f's mount point). If every probe fails
# while the dir EXISTS, staleness detection is broken on this system — crashed
# holders can then never be stolen — so say so loudly, once. The retry loop is
# anti-false-alarm: under contention the dir routinely vanishes (release/steal)
# between our probes and is re-created by the next holder, which would
# misdiagnose a healthy system, so only persistent failure on a present dir
# counts.
_LOCK_MTIME_WARNED=0
_lock_dir_mtime() {
  local m="" present=0
  for _ in 1 2 3; do
    m="$(stat -c %Y "$AGENT_LOCK_DIR" 2>/dev/null)" \
      || m="$(stat -f %m "$AGENT_LOCK_DIR" 2>/dev/null)" \
      || m="$(date -r "$AGENT_LOCK_DIR" +%s 2>/dev/null)" \
      || m=""
    case "$m" in ''|*[!0-9]*) m="";; esac
    [ -n "$m" ] && break
    # All probes failed: either the dir vanished mid-probe (normal contention;
    # the caller treats empty as "unsettled" and re-loops) or mtime is truly
    # unreadable here. Retry only while the dir is present.
    if [ -d "$AGENT_LOCK_DIR" ]; then present=1; else present=0; break; fi
  done
  if [ -z "$m" ] && [ "$present" = 1 ] && [ "$_LOCK_MTIME_WARNED" = 0 ]; then
    _LOCK_MTIME_WARNED=1
    echo "git-commit-lock: WARNING — cannot read the lock dir's mtime on this system (tried 'stat -c %Y', 'stat -f %m', 'date -r'). Staleness detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges waiters until AGENT_LOCK_MAX_WAIT." >&2
    _lock_log "WARNING: lock-dir mtime unreadable (all probes failed); staleness detection disabled"
  fi
  printf '%s' "$m"
}

# token currently recorded in the lock dir (whoever holds it now), or empty.
# Brief retry while the file reads empty but the dir still exists: on Windows
# a concurrent directory scan can transiently fail the open (sharing
# violation), and treating that one misread as "stolen" would be a false
# alarm with a destructive remedy ("redo your commit").
_lock_cur_token() {
  local t="" i=0
  while :; do
    t="$(cat "$AGENT_LOCK_DIR/token" 2>/dev/null || true)"
    [ -n "$t" ] && break
    [ -d "$AGENT_LOCK_DIR" ] || break   # dir gone: genuinely no token
    i=$((i+1)); [ "$i" -ge 5 ] && break
    sleep 0.02
  done
  printf '%s' "$t"
}

# Restore the caller's traps exactly as they were before lock_acquire: re-arm
# each saved trap, or reset to the default disposition when there was none.
# (Without this, a sourcing caller's own traps would be silently replaced and
# the shell would stay TERM/INT-immune after release.)
_lock_restore_traps() {
  if [ -n "$_LOCK_SAVED_TRAP_EXIT" ]; then eval "$_LOCK_SAVED_TRAP_EXIT"; else trap - EXIT; fi
  if [ -n "$_LOCK_SAVED_TRAP_INT" ];  then eval "$_LOCK_SAVED_TRAP_INT";  else trap - INT;  fi
  if [ -n "$_LOCK_SAVED_TRAP_TERM" ]; then eval "$_LOCK_SAVED_TRAP_TERM"; else trap - TERM; fi
  _LOCK_SAVED_TRAP_EXIT=""; _LOCK_SAVED_TRAP_INT=""; _LOCK_SAVED_TRAP_TERM=""
}

# Extract the command string from a saved `trap -p` line ("trap -- 'cmd' SIG").
# A shell function shadows the trap builtin for the eval, so bash's own quoting
# is reused instead of hand-parsing.
_lock_saved_trap_cmd() {
  [ -n "${1:-}" ] || return 0
  trap() { printf '%s' "$2"; }
  eval "$1"
  unset -f trap
}

# EXIT while holding the lock: release it, then run the caller's ORIGINAL exit
# trap ourselves — bash does not re-run an EXIT trap re-armed during EXIT-trap
# execution, so lock_release's restore alone would silently skip it.
_lock_on_exit() {
  local rc=$? prev="$_LOCK_SAVED_TRAP_EXIT" cmd=""
  lock_release || true
  cmd="$(_lock_saved_trap_cmd "$prev")"
  if [ -n "$cmd" ]; then eval "$cmd"; fi
  return "$rc"
}

# INT/TERM while holding the lock: release it, then RE-RAISE the signal so it
# is not swallowed. lock_release has restored the pre-acquire trap for the
# signal, so the re-raise lands on the caller's own handler (sourced mode) or
# the default disposition (executed `run` mode — the wrapper dies with the
# proper 128+N status, which is what a supervising watchdog needs to see).
_lock_on_signal() {
  local sig="$1"
  lock_release || true
  # Belt and braces: if our handler is somehow still armed (release was a
  # no-op), drop it so the re-raise cannot loop back here.
  case "$(trap -p "$sig")" in *_lock_on_signal*) trap - "$sig";; esac
  kill -s "$sig" "$$"
}

lock_acquire() {
  # API misuse, not a CLI usage error (hence 1, not 96): the lock is NOT
  # reentrant. Without this guard a re-acquire would self-deadlock for the
  # stale window and then steal its own lock.
  if [ "${_LOCK_HELD:-0}" = "1" ]; then
    echo "git-commit-lock: lock_acquire called while already holding the lock (not reentrant)" >&2
    _lock_log "ERROR: reentrant lock_acquire refused"
    return 1
  fi
  mkdir -p "$(dirname "$AGENT_LOCK_DIR")" 2>/dev/null || true
  # Opportunistically sweep grave litter from earlier failed deletes (a `mv`
  # whose follow-up `rm -rf` failed leaves a `.dead.*`/`.rel.*` dir behind
  # forever otherwise). Never touch `.new.*`: that is the ps1 port's LIVE
  # pre-acquire staging dir.
  rm -rf "$AGENT_LOCK_DIR".dead.* "$AGENT_LOCK_DIR".rel.* 2>/dev/null || true
  local start; start="$(_lock_now)"
  _LOCK_TOKEN="tok.$$.${RANDOM}.$(_lock_now)"

  while true; do
    if mkdir "$AGENT_LOCK_DIR" 2>/dev/null; then
      # Won the lock. mkdir already stamped the dir's mtime (our staleness
      # clock). Write our token (used by lock_release to confirm we still own
      # the lock) plus owner+epoch for logging. All guarded: the dir definitely
      # exists here, but a failed write must never abort under `set -e`. The
      # token write gets a brief retry (it is load-bearing; a transient
      # Windows sharing violation here would otherwise guarantee a false
      # "stolen" verdict at release).
      local _try=0
      while ! printf '%s\n' "$_LOCK_TOKEN" > "$AGENT_LOCK_DIR/token" 2>/dev/null; do
        _try=$((_try+1))
        [ "$_try" -ge 5 ] && break
        sleep 0.02
      done
      _lock_now                    > "$AGENT_LOCK_DIR/epoch" 2>/dev/null || true
      printf '%s\n' "$_LOCK_ME"    > "$AGENT_LOCK_DIR/owner" 2>/dev/null || true
      # Save the caller's traps before installing ours; lock_release restores
      # them on every path, so the caller's own handlers survive the hold.
      _LOCK_SAVED_TRAP_EXIT="$(trap -p EXIT)"
      _LOCK_SAVED_TRAP_INT="$(trap -p INT)"
      _LOCK_SAVED_TRAP_TERM="$(trap -p TERM)"
      _LOCK_HELD=1
      trap '_lock_on_exit' EXIT
      trap '_lock_on_signal INT' INT
      trap '_lock_on_signal TERM' TERM
      _lock_log "ACQUIRED ($_LOCK_ME tok=$_LOCK_TOKEN)"
      return 0
    fi

    # Lock exists. Steal it if the DIR's mtime is older than the stale window.
    # (Using dir mtime, not a file inside, so a crashed/partial-rm orphan with
    # no readable token is still classed stale and can be reclaimed.)
    # BUT only on a PLAUSIBLE mtime (>= 2000-01-01): a freshly created dir can
    # transiently report the Windows FILETIME zero (1601) before its first
    # metadata write, which would look ~400 years old and spuriously steal a live,
    # just-acquired lock (notably one created by git-commit-lock.ps1's atomic rename;
    # cross-impl race the interop self-test caught 2026-06-03). A sub-floor read is
    # unsettled, not stale, so we wait instead.
    local mt age
    mt="$(_lock_dir_mtime)"
    if [ -n "$mt" ] && [ "$mt" -gt 946684800 ] 2>/dev/null; then
      age=$(( $(_lock_now) - mt ))
      if [ "$age" -ge "$AGENT_LOCK_STALE_SECS" ]; then
        local holder; holder="$(cat "$AGENT_LOCK_DIR/owner" 2>/dev/null || echo '?')"
        # Re-read the mtime IMMEDIATELY before the steal: a rival stealer may
        # have completed steal+re-acquire since our read above, in which case
        # the dir is now a brand-new LIVE lock and `mv`-ing it aside would rob
        # it. Any change (fresher, sub-floor, or gone) aborts this attempt and
        # re-enters the loop. This SHRINKS the check-then-act window; it cannot
        # close it with these primitives — see KNOWN RESIDUAL RACES in the
        # header (the residual is detected at the victim's release, not silent).
        local mt2; mt2="$(_lock_dir_mtime)"
        if [ "$mt2" != "$mt" ]; then
          _lock_log "steal aborted: lock dir mtime changed underneath us (was $mt, now ${mt2:-<gone>})"
          continue
        fi
        _lock_log "STALE (age=${age}s holder=$holder) -> stealing"
        # Atomic steal: rename the stale dir aside. Only one concurrent stealer
        # wins (the rest get ENOENT); then everyone re-races the mkdir above.
        # The victim (if still alive) will fail at ITS lock_release: the dir it
        # finds will carry our token, not its own.
        local grave; grave="$AGENT_LOCK_DIR.dead.$$.$(_lock_now)"
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
      echo "git-commit-lock: timed out after ${AGENT_LOCK_MAX_WAIT}s waiting for commit lock" >&2
      return 97
    fi
    sleep "$AGENT_LOCK_POLL_SECS"
  done
}

# Release. Returns 0 if we held the lock cleanly throughout; returns 98 (and
# logs a loud WARNING) if our lease had been stolen before release — meaning
# the work we just did was NOT under exclusive protection and should be
# treated as failed; returns 1 if the lock dir could not be removed at all
# (it is left behind; the stale-window mtime check is the recovery backstop).
# Always restores the caller's pre-acquire traps. Idempotent: a second call
# (or a call without a hold) is a successful no-op.
lock_release() {
  [ "${_LOCK_HELD:-0}" = "1" ] || return 0
  _LOCK_HELD=0

  # Did we keep the lock the whole time? Compare the dir's current token to
  # ours — and on a match, re-read it once more IMMEDIATELY before the rm to
  # shrink the steal-between-check-and-delete window. (It cannot be closed
  # with these primitives — see KNOWN RESIDUAL RACES in the header; the
  # residual case is detected by the displaced party, never silent.)
  local cur; cur="$(_lock_cur_token)"
  if [ "$cur" = "$_LOCK_TOKEN" ]; then
    cur="$(_lock_cur_token)"
  fi
  if [ "$cur" != "$_LOCK_TOKEN" ]; then
    # Our lease expired and the lock was stolen (and possibly re-acquired by
    # someone else). Do NOT delete the dir — it may be a successor's LIVE lock.
    # Loudly report that this hold was not exclusive.
    _lock_restore_traps
    _lock_log "WARNING: lock LOST before release (held longer than ${AGENT_LOCK_STALE_SECS}s stale window; stolen). This commit was NOT exclusive — redo it. (ours=$_LOCK_TOKEN now=${cur:-<none>})"
    echo "git-commit-lock: WARNING — lock was stolen mid-hold (held > ${AGENT_LOCK_STALE_SECS}s). Your commit was NOT serialised; verify with 'git log' and redo under the lock." >&2
    return 98
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
    local grave; grave="$AGENT_LOCK_DIR.rel.$$.$(_lock_now)"
    if mv "$AGENT_LOCK_DIR" "$grave" 2>/dev/null; then
      # Renamed aside: the lock IS released (waiters can mkdir). The grave is
      # best-effort litter; the sweep at the next acquire collects stragglers.
      rm -rf "$grave" 2>/dev/null || true
    elif [ -d "$AGENT_LOCK_DIR" ]; then
      # Both the delete and the rename failed and the dir is still in place:
      # the lock is NOT released. Do not claim success — waiters stay blocked
      # until the stale-window mtime backstop reclaims it.
      _lock_restore_traps
      _lock_log "WARNING: release FAILED — rm -rf and rename-aside both failed; lock dir left in place (tok=$_LOCK_TOKEN). Waiters are blocked until the ${AGENT_LOCK_STALE_SECS}s stale window reclaims it."
      echo "git-commit-lock: WARNING — could not remove the lock dir ($AGENT_LOCK_DIR); it is left behind and will block waiters until the ${AGENT_LOCK_STALE_SECS}s stale window expires" >&2
      return 1
    fi
    # else: the dir vanished between the failed rm and the mv — already gone,
    # which is a release as far as waiters are concerned.
  fi
  _lock_restore_traps
  _lock_log "RELEASED ($_LOCK_ME tok=$_LOCK_TOKEN)"
  return 0
}

# Run a command under the lock; always release; propagate the command's exit
# code — UNLESS the lock was lost mid-hold, in which case return 98
# (exclusivity failure overrides a "successful" command, because it wasn't
# serialised). An acquire failure returns 97 (timeout) or 1 (misuse) with the
# command NEVER run. A release that merely failed to delete the dir (rc 1)
# does NOT override the command's code: the hold WAS exclusive, the warning
# has been printed, and the stale window cleans up.
lock_run() {
  lock_acquire || return $?
  local rc=0
  "$@" || rc=$?
  local rel=0
  lock_release || rel=$?
  if [ "$rel" -eq 98 ]; then
    return 98
  fi
  return "$rc"
}

# --- CLI (only when executed directly, not when sourced) --------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  _lock_usage() {
    echo "usage: git-commit-lock.sh run -- <command...>" >&2
    echo "   or: source git-commit-lock.sh; lock_acquire; <git...>; lock_release" >&2
    echo "exit codes: the command's own, or 96 usage error / 97 lock timeout (command not run) / 98 lock stolen mid-hold (redo the work)" >&2
  }
  cmd="${1:-}"; shift || true
  case "$cmd" in
    run)
      [ "${1:-}" = "--" ] && shift
      [ "$#" -gt 0 ] || { _lock_usage; exit 96; }
      # Outside any git repo a defaulted lock would silently scope to the CWD
      # and serialise against NOBODY committing to a repo — refuse instead.
      if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_DIR_EXPLICIT" = 0 ]; then
        echo "git-commit-lock: not inside a git repository and AGENT_LOCK_DIR is not set — refusing to guess a lock location (a CWD-scoped lock would not serialise repo commits). cd into the repo or set AGENT_LOCK_DIR." >&2
        exit 96
      fi
      lock_run "$@"
      ;;
    *)
      _lock_usage
      exit 96
      ;;
  esac
fi
