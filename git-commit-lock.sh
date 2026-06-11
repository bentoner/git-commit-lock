#!/usr/bin/env bash
# shellcheck disable=SC2310,SC2312  # info-level, deliberate: library functions
# run inside conditions/`||` chains BY DESIGN — the sourced API must behave
# identically with and without the caller's errexit, so every call site
# handles failure explicitly (see the "Strict mode" note above the source
# guard) and return values are never silently load-bearing.
# shellcheck disable=SC2249  # info-level, deliberate: `case` without a
# default is the idiom here — "no match" means "leave the value/state as-is".
#
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
#   Git-Bash/Cygwin setups), so we use classic portable primitives instead:
#     * acquire -> create a lock FILE with O_CREAT|O_EXCL (here: a `set -C`
#                  noclobber redirect — one open+write+close), whose CONTENT
#                  is the ownership token. Atomic create-or-fail on POSIX and
#                  NTFS; exactly one creator wins.
#     * steal   -> `mv LOCK grave` (rename(2) is atomic; exactly one stealer
#                  wins, the rest get ENOENT)
#
# LOCK FILE FORMAT (UTF-8, no BOM, LF; shared wire format with the ps1 port)
#     line 1: <token>            load-bearing: how lock_release detects theft.
#                                MUST start "tok." — the steal's content guard
#                                keys on that prefix, so it is wire format,
#                                binding on every implementation.
#     line 2: pid=<pid> host=<host>   informational (the STALE log line only).
#   Readers take line 1 and strip trailing CR/whitespace; they tolerate a
#   missing line 2 and an entirely empty file. Because creation and the token
#   write are ONE redirect, the old dir protocol's two worst states cannot
#   exist: there is no acquirer-died-before-metadata orphan with unreadable
#   ownership (a crash between create and write leaves an EMPTY file with a
#   valid mtime, which ages into the normal staleness lane), and there is no
#   partially-failed recursive delete at release (release is one unlink).
#
# STALENESS
#   Judged by the lock FILE's own mtime, stamped by the creating write. A lock
#   older than AGENT_LOCK_STALE_SECS (default 300s) is assumed crashed and may
#   be stolen, so one dead agent can never wedge the others forever. Two
#   defences carry over from the dir era because probing showed files need
#   them too:
#     * the mtime FLOOR (946684800 = 2000-01-01): a freshly created file can
#       transiently report FILETIME zero (1601) to an observer on Windows;
#       sub-floor means "unsettled, wait", never "ancient, steal";
#     * the empty/unreadable READ RETRIES: the create->write gap of a rival is
#       observable (probe F), so token reads retry briefly before classifying.
#
# ACQUIRE VERIFICATION (never repair by overwriting)
#   After winning the create, the acquirer re-reads line 1 from the path and
#   claims the hold only if it finds its own token. Anything else after the
#   retry ladder — foreign, empty, or gone — means we cannot prove we hold the
#   path (e.g. we were suspended past the stale window and a waiter stole the
#   path while a successor re-created it): log loudly, treat as NOT acquired,
#   re-enter the wait loop. A "repair" overwrite would clobber the successor's
#   token and produce a silent, undetected double-hold; giving the lock up is
#   always safe (our own orphan ages into the steal lane and is reclaimed).
#   This lane has no deterministic test (it needs fault injection to make a
#   winning create unreadable); like the read-retry ladders it is defence in
#   depth. Side effect: a verified read-back is what lets release treat a GONE
#   lock file as definitive theft (98) — our token provably WAS at the path.
#
# FAIL-OPEN CEILING + the holder's responsibility (important)
#   The stale window is a LEASE, and the file mtime is stamped once at create
#   and NOT refreshed while held. So a holder whose critical section runs
#   longer than AGENT_LOCK_STALE_SECS has its still-live lock stolen — the
#   lock "fails open". We do NOT prevent this with a background heartbeat
#   (keeps the tool a single synchronous script). Instead the contract is:
#   COMMITS MUST BE FAST (the golden rule — well under the window; git commits
#   should take seconds, not minutes), and a holder that was nonetheless too
#   slow DETECTS the theft when it returns: lock_release verifies the file
#   still carries our token and, if not, logs a loud WARNING and returns 98
#   instead of reporting success. Any steal that overlaps the holder's actual
#   git work happens before release and is therefore caught; a steal landing
#   after the work is benign. If you genuinely must run something slow under
#   the lock (e.g. a heavy pre-commit hook), raise AGENT_LOCK_STALE_SECS for
#   that invocation.
#
# KNOWN RESIDUAL RACES (detected, not silent)
#   The create/mv/rm primitives cannot make check-then-act fully atomic, so
#   narrow windows remain even after the re-checks below shrink them:
#     * acquire-side: between re-reading the stale file's mtime and the steal
#       `mv`, a rival completes steal+re-acquire, so our `mv` moves a
#       brand-new live lock aside;
#     * release-side: between the final token re-read and the unlink, a
#       boundary-stale steal + re-acquire slips in, so our `rm` deletes the
#       successor's live file;
#     * release-retry gap: the D1 share-mode guarantee ("the handle blocking
#       our unlink also blocks a steal's rename") holds while the handle is
#       OPEN — it can close BETWEEN our ~20ms delete retries, letting a full
#       steal+re-create land before the next attempt deletes the successor's
#       live file. The retry widens the release-side window by its ~100ms
#       budget; it still needs a contract-breach stale hold to be reachable.
#   All require a hold that already overran the stale window, and all are
#   DETECTED: the displaced holder's lock_release finds a missing/foreign
#   token and fails loudly with 98, so no silent lost update — the cost is a
#   spurious "redo" plus a transient double-hold. (Future option, ps1 side
#   only: handle-based ops — open with delete sharing, fstat/read/delete via
#   that one handle — could close these windows outright there; bash has no
#   handle persistence, so the protocol-level claim stays "shrunk, detected,
#   not closed".)
#
# ACCEPTED RESIDUALS (non-race, documented deliberately)
#   * A torn token write SHORTER than "tok." (e.g. "to"; reachable only via
#     ENOSPC/crash mid-write) is non-empty and non-prefixed, so it lands in
#     the never-steal NON-LOCK lane permanently: loud (the config warning
#     names the path), fixed by one manual `rm`. We trade that vanishing-rare
#     recovery for never deleting real user files at a typo'd path.
#   * The converse: a stale USER file whose line 1 happens to start "tok." IS
#     stolen — the prefix is the whole wire test, deliberately (a fuller shape
#     check would bind the format harder for near-zero added protection).
#   * An actively-REWRITTEN user file at a typo'd path never ages into the
#     content guard, so it ends in 97 without a config warning (safety is
#     intact — nothing stolen or deleted; we just don't read content on every
#     poll). The same trade as the per-poll type guard avoids.
#   * FIFOs/devices/sockets at the lock path: bash refuses them all via the
#     pre-create type guard + `[ -f ]` steal guard. The ps1 port on Unix has
#     no clean type probe for devices/sockets/FIFOs (they stat as size 0 and
#     take the empty-orphan lane there); that residual is documented in the
#     ps1 implementation — reference only here.
#   * Windows read-only attribute: it fails File.Delete/`rm` differently than
#     rename (bash `rm -f` clears it and succeeds; ps1's File.Delete fails
#     while File.Move would succeed). Nothing in the protocol ever sets
#     read-only; if something external does, the leftover warning fires and
#     the stale steal (a rename) recovers the path.
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
#   AGENT_LOCK_PATH        lock file path (default <gitdir>/commit.lock)
#   AGENT_LOCK_STALE_SECS  steal threshold in seconds vs file mtime (default
#                          300). Hard fail-open ceiling: keep it >> (max hold
#                          + any clock skew); no sub-5s windows outside tests.
#   AGENT_LOCK_POLL_SECS   poll interval while waiting (default 2)
#   AGENT_LOCK_MAX_WAIT    safety cap on total wait (default 420; keep it >
#                          stale so a steal always gets a chance before we
#                          give up — a warning is printed if it is not)
#   AGENT_LOCK_LOG         log file (default <gitdir>/git-commit-lock.log)
#   STALE_SECS and MAX_WAIT must be positive integers, POLL_SECS may be
#   fractional; invalid values fall back to the default with a stderr note
#   (same rules in the ps1 port).
#
# EXIT CODES (the published contract — do not repurpose)
#   `run` exits with the wrapped command's own exit code, EXCEPT three
#   reserved high codes:
#     96  usage error (bad/missing arguments, or `run` outside a git repo with
#         no AGENT_LOCK_PATH override) — the command was NEVER run
#     97  timed out waiting for the lock — the command was NEVER run
#     98  lock stolen mid-hold — the command RAN but was NOT serialised;
#         treat the work as failed and redo it under the lock
#   (A wrapped command that itself exits 96/97/98 is indistinguishable from
#   these; avoid those codes in wrapped commands.)
#   Sourced API: lock_acquire returns 97 on timeout and 1 on API misuse
#   (reentrant acquire); lock_release returns 98 if the lease was stolen
#   mid-hold (the file is GONE, or carries a non-empty FOREIGN token — both
#   definitive, because acquire's read-back verified our token at the path),
#   2 if the file still reads EMPTY after the retry ladder while present
#   (ownership unverifiable: that is the create->write window of a successor
#   after a boundary steal, or external truncation — not proof of theft;
#   `run` maps this to 1 only when the command itself succeeded, and keeps a
#   failing command's own exit code), and 1 if the lock file could not be
#   deleted (LEFTOVER: it is left behind; recovery needs the stale window to
#   elapse AND the blocking handle to close — the same handle blocks a
#   stealer's rename, so until then waiters re-poll and may reach 97).
#   The ps1 port returns the same verdicts for the same on-disk states.
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

# --- time primitives (probed once at source time, not per call) --------------
# bash 4.2+ printf '%(fmt)T' formats time without forking `date` (a hot path:
# every poll and every log line wants the clock). macOS /bin/bash is 3.2,
# which lacks it — probe once and fall back to external `date` there.
_lock_t="$(printf '%(%s)T' -1 2>/dev/null || true)"
case "$_lock_t" in
  ''|*[!0-9]*)
    _lock_now()   { date +%s; }
    _lock_stamp() { date '+%Y-%m-%d %H:%M:%S'; }
    ;;
  *)
    _lock_now()   { printf '%(%s)T' -1; }
    _lock_stamp() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }
    ;;
esac
unset _lock_t

# --- resolve defaults (git-dir aware, CWD-independent within the repo) -------
_lock_gitdir() { git rev-parse --absolute-git-dir 2>/dev/null || true; }
# Remember whether the caller chose the lock location explicitly: outside a
# repo, `run` refuses to guess (see CLI below), while sourcing keeps a CWD
# fallback (with a logged warning) so sourcing never explodes.
if [ -n "${AGENT_LOCK_PATH:-}" ]; then _LOCK_PATH_EXPLICIT=1; else _LOCK_PATH_EXPLICIT=0; fi
# Lazy gitdir resolution (perf): the `git rev-parse` fork exists only to
# DEFAULT the lock/log paths, so skip it entirely when both are explicit (the
# common test/sub-agent-override case). When only AGENT_LOCK_PATH is explicit
# the log still defaults into the git dir, so the resolution stays.
if [ "$_LOCK_PATH_EXPLICIT" = 1 ] && [ -n "${AGENT_LOCK_LOG:-}" ]; then
  _LOCK_GITDIR=""
else
  _LOCK_GITDIR="$(_lock_gitdir)"
fi
_LOCK_BASE="${_LOCK_GITDIR:-$PWD}"

AGENT_LOCK_PATH="${AGENT_LOCK_PATH:-$_LOCK_BASE/commit.lock}"
if [ -n "${AGENT_LOCK_MAX_WAIT:-}" ]; then _LOCK_MAXWAIT_EXPLICIT=1; else _LOCK_MAXWAIT_EXPLICIT=0; fi
AGENT_LOCK_STALE_SECS="${AGENT_LOCK_STALE_SECS:-300}"
AGENT_LOCK_POLL_SECS="${AGENT_LOCK_POLL_SECS:-2}"
AGENT_LOCK_MAX_WAIT="${AGENT_LOCK_MAX_WAIT:-420}"
AGENT_LOCK_LOG="${AGENT_LOCK_LOG:-$_LOCK_BASE/git-commit-lock.log}"

# Validate the numeric knobs once, at source time: a garbage POLL would
# busy-spin the create loop, a garbage STALE would silently disable stealing,
# and a garbage MAX_WAIT would break the timeout arithmetic. On bad input,
# note it on stderr and fall back to the default rather than failing.
_lock_check_num() {  # $1=name $2=value $3=default $4=int|frac -> prints value to use
  local v="$2" ok=1
  case "$4" in
    int)  case "$v" in ''|*[!0-9]*) ok=0;; esac ;;
    frac) case "$v" in ''|.|*[!0-9.]*|*.*.*) ok=0;; esac ;;
  esac
  # Reject zero (e.g. "0", "0.0"): every knob must be strictly positive. A
  # format-valid value is positive iff it contains a nonzero digit.
  if [ "$ok" = 1 ]; then case "$v" in *[1-9]*) ;; *) ok=0;; esac; fi
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
# out before a crashed holder's lock could ever be stolen. Warn only in the
# documented footgun case — STALE raised for a slow hold while MAX_WAIT was
# left at its default. A caller who set BOTH knobs chose the relationship
# deliberately (test suites do this constantly).
if [ "$_LOCK_MAXWAIT_EXPLICIT" = 0 ] && [ "$AGENT_LOCK_STALE_SECS" -ge "$AGENT_LOCK_MAX_WAIT" ]; then
  echo "git-commit-lock: warning — AGENT_LOCK_STALE_SECS ($AGENT_LOCK_STALE_SECS) >= AGENT_LOCK_MAX_WAIT ($AGENT_LOCK_MAX_WAIT, default): waiters will time out before a stale lock can be stolen; raise AGENT_LOCK_MAX_WAIT too" >&2
fi

_LOCK_HELD=0
# $HOSTNAME is set by bash itself; the `hostname` fork is only a fallback for
# the rare shell that did not populate it.
_LOCK_ME="pid=$$ host=${HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}"
# Unique per acquisition: identifies OUR hold so release can tell whether the
# lock we are about to free is still the one we took (vs. stolen + re-acquired
# by someone else). pid alone is not enough — pids get reused across the 5-min
# window — so mix in $RANDOM and the acquire time. The "tok." prefix is wire
# format (see LOCK FILE FORMAT above).
_LOCK_TOKEN=""
# The caller's EXIT/INT/TERM traps as they were before lock_acquire installed
# ours (saved via `trap -p`, restored by lock_release on every path).
_LOCK_SAVED_TRAP_EXIT=""
_LOCK_SAVED_TRAP_INT=""
_LOCK_SAVED_TRAP_TERM=""

_lock_log()  {
  # Dumb size cap: if the log has grown past ~1MB (it gains ~2 lines per
  # commit and nothing ever prunes it), start it over rather than rotating.
  if [ -f "$AGENT_LOCK_LOG" ] && [ "$(wc -c < "$AGENT_LOCK_LOG" 2>/dev/null || echo 0)" -gt 1048576 ] 2>/dev/null; then
    : > "$AGENT_LOCK_LOG" 2>/dev/null || true
    printf '%s [pid=%s] %s\n' "$(_lock_stamp)" "$$" "log exceeded 1MB; truncated" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
  fi
  printf '%s [pid=%s] %s\n' "$(_lock_stamp)" "$$" "$*" >> "$AGENT_LOCK_LOG" 2>/dev/null || true
}

# Sourced outside a git repo without an explicit AGENT_LOCK_PATH: keep the CWD
# fallback (sourcing must never explode) but leave a trace that the lock is
# probably NOT protecting what the caller thinks it is.
if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_PATH_EXPLICIT" = 0 ] && [ "${BASH_SOURCE[0]}" != "${0}" ]; then
  _lock_log "WARNING: not inside a git repository; lock location falls back to CWD ($_LOCK_BASE) — set AGENT_LOCK_PATH explicitly if that is not intended"
fi

# Loud, once-per-process config warning for a non-lock object at the lock
# path (a directory — e.g. a leftover old-protocol dir lock or a typo like
# AGENT_LOCK_PATH=$HOME — a symlink, a device, or a regular file whose
# content is not lock-shaped). Such a path is NEVER stolen or deleted;
# waiters will reach 97 until a human fixes the path or removes the object.
_LOCK_NONLOCK_WARNED=0
_lock_warn_nonlock() {  # $1 = what is wrong with the object
  [ "$_LOCK_NONLOCK_WARNED" = 1 ] && return 0
  _LOCK_NONLOCK_WARNED=1
  echo "git-commit-lock: WARNING — $AGENT_LOCK_PATH exists but is not a lock file ($1). Refusing to steal or delete it; waiters will time out (97). If AGENT_LOCK_PATH is a typo, fix it; if this is a stray file or a leftover old-protocol lock directory, remove it by hand." >&2
  _lock_log "WARNING: non-lock object at lock path ($1) — never stolen; waiters reach 97 until it is removed by hand"
}

# Best-effort single mtime probe (epoch secs) of an arbitrary path; prints
# empty if unreadable. Probe chain: GNU stat (-c %Y), then BSD/macOS stat
# (-f %m), then GNU date (-r FILE +%s; BSD date -r takes seconds, so it fails
# harmlessly there). The numeric guard rejects any probe that "succeeds" with
# non-epoch output (e.g. GNU stat -f's mount point).
_lock_stat_mtime() {
  local m
  m="$(stat -c %Y "$1" 2>/dev/null)" \
    || m="$(stat -f %m "$1" 2>/dev/null)" \
    || m="$(date -r "$1" +%s 2>/dev/null)" \
    || m=""
  case "$m" in ''|*[!0-9]*) m="";; esac
  printf '%s' "$m"
}

# mtime of the lock file itself, stamped by the creating write — the
# staleness clock. Sets _LOCK_MTIME rather than printing: a
# command-substitution caller would run this in a SUBSHELL, where the
# warn-once flag below can never persist, so the broken-stat warning used to
# repeat on every poll. Empty if the file vanished mid-check. If every probe
# fails while the file EXISTS, staleness detection is broken on this system —
# crashed holders can then never be stolen — so say so loudly, once per
# process. The retry loop is anti-false-alarm: under contention the lock
# routinely vanishes (release/steal) between our probes and is re-created by
# the next holder, which would misdiagnose a healthy system, so only
# persistent failure on a present file counts.
_LOCK_MTIME_WARNED=0
_LOCK_MTIME=""
_lock_path_mtime() {
  local m="" present=0
  for _ in 1 2 3; do
    m="$(_lock_stat_mtime "$AGENT_LOCK_PATH")"
    [ -n "$m" ] && break
    # All probes failed: either the file vanished mid-probe (normal
    # contention; the caller treats empty as "unsettled" and re-loops) or
    # mtime is truly unreadable here. Retry only while the file is present.
    if [ -e "$AGENT_LOCK_PATH" ]; then present=1; else present=0; break; fi
  done
  if [ -z "$m" ] && [ "$present" = 1 ] && [ "$_LOCK_MTIME_WARNED" = 0 ]; then
    _LOCK_MTIME_WARNED=1
    echo "git-commit-lock: WARNING — cannot read the lock file's mtime on this system (tried 'stat -c %Y', 'stat -f %m', 'date -r'). Staleness detection is BROKEN: stale locks will never be stolen, so a crashed holder wedges waiters until AGENT_LOCK_MAX_WAIT." >&2
    _lock_log "WARNING: lock-file mtime unreadable (all probes failed); staleness detection disabled"
  fi
  _LOCK_MTIME="$m"
}

# Token currently recorded in the lock file — line 1, whoever holds it now —
# or empty. Brief retry while the read comes back empty but the file still
# exists: the rival create->write gap is observable (probe F: the file can
# exist with no content yet), and on Windows a concurrent scan can
# transiently fail the open (sharing violation); treating one misread as
# "stolen" would be a false alarm with a destructive remedy ("redo your
# commit"). An empty result with the file still present is classified at
# release as UNVERIFIABLE ownership (rc 2), never as proven theft.
_lock_cur_token() {
  local t="" i=0
  while :; do
    t=""
    # NB: 2>/dev/null BEFORE the input redirect — a failed open's error
    # message is emitted by the shell at the point of failure, so stderr
    # must already be redirected when the open is attempted.
    { IFS= read -r t || true; } 2>/dev/null < "$AGENT_LOCK_PATH" || true
    t="${t%"${t##*[![:space:]]}"}"   # strip trailing CR/whitespace (CRLF tolerance)
    [ -n "$t" ] && break
    [ -e "$AGENT_LOCK_PATH" ] || break   # file gone: genuinely no token
    i=$((i+1)); [ "$i" -ge 5 ] && break
    sleep 0.02
  done
  printf '%s' "$t"
}

# Opportunistic, age-gated sweep of steal graves beside the lock (`.dead.*`,
# left when a steal winner's grave delete failed — mirrored in the ps1 port).
# Only entries older than the stale window (with a plausible mtime) are
# swept, and only with a non-recursive `rm -f`: a directory or other non-file
# at a grave name is left alone. Pure best-effort: any failure just leaves
# the entry for a later sweep.
_lock_sweep_litter() {
  local d mt now
  now="$(_lock_now)"
  for d in "$AGENT_LOCK_PATH".dead.*; do
    [ -e "$d" ] || continue                  # unmatched glob stays literal
    mt="$(_lock_stat_mtime "$d")"
    [ -n "$mt" ] || continue
    [ "$mt" -gt 946684800 ] || continue      # sub-floor reading: unsettled, skip
    [ $(( now - mt )) -ge "$AGENT_LOCK_STALE_SECS" ] || continue
    rm -f -- "$d" 2>/dev/null || continue    # non-recursive: a dir grave fails here and stays
    _lock_log "SWEPT stale litter ${d##*/}"
  done
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
  # shellcheck disable=SC2329  # invoked indirectly: the eval of the saved
  # `trap -p` line below calls this shadow function.
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
# CAVEAT (INT): a SIGINT delivered to the run WRAPPER alone while its
# foreground child survives it is DISCARDED by bash before any trap runs
# (wait-and-cooperate: if the child didn't die of the INT, bash assumes the
# program handled it and carries on) — so this trap never fires on that
# delivery. A real Ctrl+C is delivered to the whole process GROUP, kills the
# child too, and DOES take this path; the TERM tests exercise the same
# release+re-raise machinery directly.
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
  mkdir -p "$(dirname "$AGENT_LOCK_PATH")" 2>/dev/null || true
  _lock_sweep_litter
  local start; start="$(_lock_now)"
  _LOCK_TOKEN="tok.$$.${RANDOM}.$start"
  local waiting_logged=0
  # Log damper for a squatted stale lock (a no-delete-share handle, or an
  # unwritable parent dir, makes the steal rename fail every poll with the
  # file still present): epoch of the last logged failed-steal attempt, 0 when
  # the last attempt did not fail that way. While the failures persist, the
  # STALE/steal-FAILED pair is logged at most once per stale window, so the
  # log growth stays bounded however long the squat lasts.
  local steal_fail_last=0
  # Two-consecutive-poll confirmation state for the wrong-type guard below
  # (round 3 — see WRONG-TYPE CLASSIFICATION): the concrete classification
  # observed on the PREVIOUS blocked poll, reset to empty whenever a poll
  # sees the path absent, a regular file, or no concrete type.
  local nonlock_prev=""

  while true; do
    # PRE-CREATE TYPE GUARD (mandatory). noclobber's exists=>fail protection
    # applies to REGULAR files only: `>` onto an existing FIFO blocks in
    # open(2) before any timeout logic runs, and onto a device node simply
    # writes. Only attempt the create when the path is absent or carries a
    # plain non-symlink file (where O_EXCL fails safely). The check-then-open
    # gap is acceptable: a non-lock object at the path is static
    # misconfiguration, not a racing peer. (A symlink — even dangling — is
    # refused by O_CREAT|O_EXCL itself; routing it to the wait loop just
    # lands it in the same warn lane coherently.)
    local creatable=0
    if [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
      if [ -f "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then creatable=1; fi
    else
      creatable=1
    fi

    if [ "$creatable" = 1 ] \
       && ( set -C; printf '%s\n%s\n' "$_LOCK_TOKEN" "$_LOCK_ME" > "$AGENT_LOCK_PATH" ) 2>/dev/null; then
      # The redirect is one open(O_CREAT|O_EXCL)+write+close: the file now
      # carries our token and its mtime (the staleness clock) is stamped.
      # The 2>/dev/null is on the SUBSHELL because the noclobber failure
      # message comes from bash itself, not printf (probe A). A created-but-
      # write-failed file (e.g. ENOSPC) makes the subshell fail and falls
      # through below; the empty/torn orphan ages into its steal lane.
      #
      # VERIFY via a path read-back before claiming the hold (see ACQUIRE
      # VERIFICATION in the header): only our own token proves we hold the
      # path. NEVER repair a failed read-back by writing to the path.
      local rb; rb="$(_lock_cur_token)"
      if [ "$rb" = "$_LOCK_TOKEN" ]; then
        # Save the caller's traps before installing ours; lock_release
        # restores them on every path, so the caller's handlers survive.
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
      _lock_log "WARNING: acquire verification FAILED — create won but read-back found '${rb:-<empty-or-gone>}' (ours=$_LOCK_TOKEN); not acquired, re-entering wait"
      echo "git-commit-lock: WARNING — acquire verification failed: the lock file did not read back our token; treating the lock as NOT acquired and waiting" >&2
      # fall through to the blocked branch of this same iteration
    fi

    # Blocked (create lost, was skipped by the type guard, or won-but-failed
    # verification). One WAITING line on the first blocked poll only: lets a
    # reader of the log see that this acquirer actually contended, and lets
    # tests hold-until-WAITING instead of sleeping.
    if [ "$waiting_logged" = 0 ]; then
      waiting_logged=1
      _lock_log "WAITING for lock ($_LOCK_ME tok=$_LOCK_TOKEN)"
    fi

    # PER-POLL TYPE GUARD (cheap; every blocked poll, NOT age-gated): an
    # actively-written non-lock path (the canonical AGENT_LOCK_PATH=$HOME
    # typo: writes keep refreshing its mtime) never ages past the stale
    # window, so an age-gated guard would never diagnose it. Warn only on
    # exists-but-wrong-type — a path that vanished since the failed create is
    # normal contention (re-race the create), not a config problem. "Exists"
    # is `-e || -L`: a DANGLING symlink is refused by O_CREAT|O_EXCL forever
    # but reads as absent to a bare `-e`, which would misclassify it as
    # contention every poll and starve the waiter to 97 with no diagnosis.
    if [ -e "$AGENT_LOCK_PATH" ] || [ -L "$AGENT_LOCK_PATH" ]; then
      if [ -f "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
        nonlock_prev=""   # regular file: any prior wrong-type observation is moot
        # A regular file: a live lock, a stale one, or a crash orphan.
        # Steal if the FILE's mtime is older than the stale window — but only
        # on a PLAUSIBLE mtime (>= 2000-01-01): a freshly created file can
        # transiently report the Windows FILETIME zero (1601), which would
        # look ~400 years old and spuriously steal a live, just-acquired
        # lock (probes C/C1b). A sub-floor read is unsettled, not stale.
        local mt age
        _lock_path_mtime; mt="$_LOCK_MTIME"
        if [ -n "$mt" ] && [ "$mt" -gt 946684800 ] 2>/dev/null; then
          age=$(( $(_lock_now) - mt ))
          if [ "$age" -ge "$AGENT_LOCK_STALE_SECS" ]; then
            # CONTENT GUARD (age-gated, runs only on a stale candidate):
            # steal only lock-shaped content — an EMPTY file (the crash-
            # between-create-and-write orphan) or line 1 starting "tok."
            # (a real token, possibly torn mid-token). Anything else is a
            # user file at a typo'd path or a torn write shorter than the
            # prefix: never steal it. Line 2 (owner) is read in the same
            # open, BEFORE the final mtime re-read below — an open inserted
            # after the re-read would widen exactly the window it shrinks.
            local line1="" line2="" rdrc=0 steal_ok=0
            { IFS= read -r line1 || rdrc=$?; IFS= read -r line2 || true; } 2>/dev/null < "$AGENT_LOCK_PATH" || rdrc=$?
            line1="${line1%"${line1##*[![:space:]]}"}"
            line2="${line2%"${line2##*[![:space:]]}"}"
            if [ -n "$line1" ]; then
              case "$line1" in
                tok.*) steal_ok=1 ;;
                *)     _lock_warn_nonlock "its content is not lock-shaped" ;;
              esac
            elif ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
              : # vanished mid-check: normal contention; re-poll
            elif ! [ -s "$AGENT_LOCK_PATH" ]; then
              steal_ok=1   # genuinely empty: the crash-orphan lane
            elif [ "$rdrc" -ne 0 ]; then
              # Persistent read failure with a non-empty file still present:
              # neither "empty" nor the never-steal lane — skip this steal
              # attempt and re-poll. Self-correcting: a handle that blocks
              # our read usually blocks the steal rename too (probe D1), so
              # refusing costs nothing.
              _lock_log "steal skipped: stale lock content unreadable (age=${age}s); re-polling"
            else
              # Read succeeded but line 1 is blank on a NON-empty file: a
              # torn write of ours always starts with 't', so this is not
              # lock-shaped either.
              _lock_warn_nonlock "its content is not lock-shaped"
            fi

            if [ "$steal_ok" = 1 ]; then
              local holder="${line2:-?}"
              # Re-read the mtime IMMEDIATELY before the steal: a rival may
              # have completed steal+re-acquire since our read above, in
              # which case the file is now a brand-new LIVE lock and
              # `mv`-ing it aside would rob it. Any change (fresher,
              # sub-floor, or gone) aborts this attempt and re-enters the
              # loop. This SHRINKS the check-then-act window; it cannot
              # close it with these primitives — see KNOWN RESIDUAL RACES
              # (the residual is detected at the victim's release).
              local mt2; _lock_path_mtime; mt2="$_LOCK_MTIME"
              if [ "$mt2" != "$mt" ]; then
                _lock_log "steal aborted: lock file mtime changed underneath us (was $mt, now ${mt2:-<gone>})"
                continue
              fi
              # Damp the attempt logging while the steal keeps failing on a
              # squatted file (see steal_fail_last above): first failure, then
              # at most once per stale window.
              local now_s log_steal=1
              now_s="$(_lock_now)"
              if [ "$steal_fail_last" != 0 ] \
                 && [ $(( now_s - steal_fail_last )) -lt "$AGENT_LOCK_STALE_SECS" ]; then
                log_steal=0
              fi
              [ "$log_steal" = 1 ] && _lock_log "STALE (age=${age}s holder=$holder) -> stealing"
              # Atomic steal: rename the stale file aside. Only one
              # concurrent stealer wins (the rest get ENOENT); then everyone
              # re-races the create above. The victim (if still alive) will
              # fail at ITS lock_release: gone or foreign token => 98.
              local grave; grave="$AGENT_LOCK_PATH.dead.$$.$now_s"
              if mv -- "$AGENT_LOCK_PATH" "$grave" 2>/dev/null; then
                rm -f -- "$grave" 2>/dev/null || true
                _lock_log "STOLE stale lock (was held by $holder)"
                steal_fail_last=0
                continue   # won the steal: immediately re-race the create
              fi
              if ! [ -e "$AGENT_LOCK_PATH" ] && ! [ -L "$AGENT_LOCK_PATH" ]; then
                steal_fail_last=0
                continue   # lost the race (a rival's rename won; ENOENT): re-race the create
              fi
              # The rename failed with the file STILL PRESENT: a no-delete-share
              # handle squatting the file (it blocks rename exactly like the
              # release unlink — probe D1) or an unwritable parent dir. Nothing
              # will change until the squatter lets go, so this must NOT skip
              # the timeout check + poll sleep below: an unconditional
              # `continue` here busy-spun flat-out and could never reach 97
              # (review finding, 2026-06-11). Fall through instead.
              if [ "$log_steal" = 1 ]; then
                _lock_log "steal FAILED: rename refused with the lock file still present (no-delete-share handle, or unwritable parent dir); re-polling — repeats logged at most once per ${AGENT_LOCK_STALE_SECS}s"
                steal_fail_last="$now_s"
              fi
            fi
          fi
        fi
      else
        # WRONG-TYPE CLASSIFICATION (TOCTOU-hardened, three rounds): the
        # "exists" (-e/-L) and "regular file" (-f && ! -L) checks above are
        # SEPARATE stats, so a normal contended poll can land here looking
        # wrong-type and used to fire the loud config warning as a pure
        # false alarm (reproduced under vanilla contention and
        # deterministically under create/delete churn, 2026-06-11). Two
        # transients cause it: a rival's release/steal unlink between the
        # two stats, and — worse — a Windows DELETE-PENDING ghost (the
        # unlink is queued until a rival reader's transient handle closes;
        # for up to ~ms the attribute stats FAIL while a bare -e still
        # reports existence), which probing showed defeats any immediate
        # re-check of the same -e/-f pair: the ghost outlives it. Round 2
        # (2026-06-11) therefore warned only on a CONCRETE wrong type —
        # directory, symlink, FIFO, socket, device — on the theory that a
        # vanished or delete-pending path fails every one of these stats.
        # CI falsified that theory (windows-2025, run 27325971668, unit
        # T17d): a delete-pending ghost transiently matched one of the six
        # concrete stats under Cygwin, firing the warning on a path that
        # only ever held churned REGULAR files. Round 3 (2026-06-11) adds
        # TWO-CONSECUTIVE-POLL CONFIRMATION: warn only when the SAME
        # concrete type is observed on two consecutive blocked polls. A
        # ghost transient makes a same-type repeat across a full poll
        # interval extremely unlikely (zero in hundreds of churn waiter-runs
        # locally and in probes) though not impossible - two INDEPENDENT
        # ghosts could land same-type on consecutive polls - and the one
        # observed long-lived delete-pending state (60s behind an AV handle,
        # see the unit suite T17d readiness note) reads as ENOENT/absent,
        # which RESETS the confirmation. A real misconfig needs >=2 blocked
        # polls before MAX_WAIT to warn (always true outside degenerate
        # test configs). A real misconfig object classifies identically forever — its
        # once-per-process warning just arrives one poll later, and the
        # never-steal safety is unaffected either way (the guard never
        # steals non-locks regardless of warning state). Residual: an
        # object so exotic that no stat classifies it would starve waiters
        # to 97 undiagnosed — transient ghosts are exactly that state, so
        # they win the tie. -L is tested FIRST so a symlink (whose target
        # would otherwise satisfy -d etc.) is named as the link it is.
        local nonlock_cur=""
        if   [ -L "$AGENT_LOCK_PATH" ]; then nonlock_cur="a symlink"
        elif [ -d "$AGENT_LOCK_PATH" ]; then nonlock_cur="a directory"
        elif [ -p "$AGENT_LOCK_PATH" ]; then nonlock_cur="a FIFO"
        elif [ -S "$AGENT_LOCK_PATH" ]; then nonlock_cur="a socket"
        elif [ -b "$AGENT_LOCK_PATH" ] || [ -c "$AGENT_LOCK_PATH" ]; then nonlock_cur="a device node"
        fi
        if [ -n "$nonlock_cur" ] && [ "$nonlock_cur" = "$nonlock_prev" ]; then
          _lock_warn_nonlock "it is $nonlock_cur"
        fi
        nonlock_prev="$nonlock_cur"
        # (no concrete type: vanished or delete-pending ghost — normal
        # contention; the next iteration re-races the create)
      fi
    else
      # path absent: normal contention — the next iteration re-races the
      # create. Also resets the wrong-type confirmation state above.
      nonlock_prev=""
    fi

    # A live holder has it (or a never-steal object squats it) — wait,
    # unless we have waited too long.
    if [ $(( $(_lock_now) - start )) -ge "$AGENT_LOCK_MAX_WAIT" ]; then
      _lock_log "TIMEOUT after ${AGENT_LOCK_MAX_WAIT}s waiting for lock"
      echo "git-commit-lock: timed out after ${AGENT_LOCK_MAX_WAIT}s waiting for commit lock" >&2
      return 97
    fi
    sleep "$AGENT_LOCK_POLL_SECS"
  done
}

# Release. Returns 0 if we held the lock cleanly throughout; returns 98 (and
# logs a loud WARNING) if our lease had been stolen before release — the file
# is GONE or carries a non-empty FOREIGN token (both definitive: acquire's
# read-back proved our token was at the path) — meaning the work we just did
# was NOT under exclusive protection and should be treated as failed; returns
# 2 if the file still reads EMPTY after the retry ladder while present
# (ownership unverifiable — see the lane comment below); returns 1 if the
# lock file could not be deleted (LEFTOVER: left behind; recovery needs the
# stale window AND the blocking handle to close). Always restores the
# caller's pre-acquire traps. Idempotent: a second call (or a call without a
# hold) is a successful no-op.
lock_release() {
  [ "${_LOCK_HELD:-0}" = "1" ] || return 0
  _LOCK_HELD=0

  # Did we keep the lock the whole time? Compare the file's current token to
  # ours — and on a match, re-read it once more IMMEDIATELY before the rm to
  # shrink the steal-between-check-and-delete window. The boundary re-read is
  # classified by the SAME rules as the first read (empty-at-boundary is the
  # rc-2 lane, never a delete: in the file era an empty read is precisely the
  # create->write window of a successor after a boundary steal). The window
  # cannot be closed with these primitives — see KNOWN RESIDUAL RACES in the
  # header; the residual case is detected by the displaced party, never
  # silent.
  local cur; cur="$(_lock_cur_token)"
  if [ "$cur" = "$_LOCK_TOKEN" ]; then
    cur="$(_lock_cur_token)"
  fi
  if [ "$cur" != "$_LOCK_TOKEN" ]; then
    _lock_restore_traps
    if [ -z "$cur" ] && [ -e "$AGENT_LOCK_PATH" ]; then
      # The file still exists but reads EMPTY after the retry ladder. NOT
      # definitive theft evidence: it cannot be our own failed write
      # (acquire's read-back positively verified our token at the path), but
      # it can be a successor mid-create after a boundary steal (probe F's
      # window) or external truncation. We cannot verify ownership either
      # way: do NOT delete (it may be a successor's nascent live lock), do
      # not claim success — leave the file (the staleness backstop recovers
      # a true orphan) and fail distinctly. The ps1 port's 'unreadable' lane
      # gives the same verdict for the same state.
      _lock_log "WARNING: lock file present but EMPTY/unreadable at release (after retries); ownership unverifiable. Leaving it in place. (ours=$_LOCK_TOKEN)"
      echo "git-commit-lock: WARNING — the lock file read empty/unreadable at release (still present). Ownership unverifiable; lock file left in place. Verify with 'git log'." >&2
      return 2
    fi
    # Gone, or a foreign token: our lease expired and the lock was stolen
    # (and possibly re-acquired by someone else). Do NOT touch the path — it
    # may be a successor's LIVE lock. Loudly report the non-exclusive hold.
    _lock_log "WARNING: lock LOST before release (held longer than ${AGENT_LOCK_STALE_SECS}s stale window; stolen). This commit was NOT exclusive — redo it. (ours=$_LOCK_TOKEN now=${cur:-<gone>})"
    echo "git-commit-lock: WARNING — lock was stolen mid-hold (held > ${AGENT_LOCK_STALE_SECS}s). Your commit was NOT serialised; verify with 'git log' and redo under the lock." >&2
    return 98
  fi

  # Still ours — free it: one unlink. `-f` masks only ENOENT, which is the
  # "vanished mid-race = already released" branch. On Windows the unlink can
  # fail while a foreign no-delete-share handle (AV scanner, naive reader) is
  # open on the file; retry briefly. The retry is grounded on probe D1, not
  # on hope: the handle class that blocks our unlink also blocks any steal's
  # rename, so the path cannot be stolen-and-recreated while the delete keeps
  # failing (the read-only-attribute exception and the between-retries gap
  # are documented in the header; both end in the same detected-98 class).
  local _try=0
  while ! rm -f -- "$AGENT_LOCK_PATH" 2>/dev/null; do
    _try=$((_try+1))
    if [ "$_try" -ge 5 ]; then
      # Persistent failure: the lock is NOT released (LEFTOVER). Do not claim
      # success — waiters stay blocked until the stale window elapses AND the
      # blocking handle closes (the same handle blocks their steal rename,
      # so until then they re-poll and may reach 97).
      _lock_restore_traps
      _lock_log "WARNING: release FAILED — could not delete the lock file after $_try attempts; LEFTOVER (tok=$_LOCK_TOKEN). Waiters are blocked until the ${AGENT_LOCK_STALE_SECS}s stale window elapses AND the blocking handle closes."
      echo "git-commit-lock: WARNING — could not remove the lock file ($AGENT_LOCK_PATH); it is left behind and will block waiters until the ${AGENT_LOCK_STALE_SECS}s stale window expires and whatever holds it open lets go" >&2
      return 1
    fi
    sleep 0.02
  done
  _lock_restore_traps
  _lock_log "RELEASED ($_LOCK_ME tok=$_LOCK_TOKEN)"
  return 0
}

# Run a command under the lock; always release; propagate the command's exit
# code — UNLESS the lock was lost mid-hold, in which case return 98
# (exclusivity failure overrides a "successful" command, because it wasn't
# serialised). An acquire failure returns 97 (timeout) or 1 (misuse) with the
# command NEVER run. An unverifiable release (rc 2) fails a SUCCESSFUL command
# with 1 but keeps a failing command's own code. A release that merely failed
# to delete the file (rc 1) does NOT override the command's code: the hold WAS
# exclusive, the warning has been printed, and the stale window cleans up.
lock_run() {
  lock_acquire || return $?
  local rc=0
  "$@" || rc=$?
  local rel=0
  lock_release || rel=$?
  if [ "$rel" -eq 98 ]; then
    return 98
  fi
  if [ "$rel" -eq 2 ] && [ "$rc" -eq 0 ]; then
    # Ownership unverifiable at release (file present but empty): not a
    # proven theft, but not a verified-exclusive hold either — a
    # "successful" command must not report success. A FAILING command keeps
    # its own exit code (parity with the ps1 run path).
    rc=1
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
      if [ -z "$_LOCK_GITDIR" ] && [ "$_LOCK_PATH_EXPLICIT" = 0 ]; then
        echo "git-commit-lock: not inside a git repository and AGENT_LOCK_PATH is not set — refusing to guess a lock location (a CWD-scoped lock would not serialise repo commits). cd into the repo or set AGENT_LOCK_PATH." >&2
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
