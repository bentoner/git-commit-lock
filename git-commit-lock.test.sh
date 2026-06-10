#!/usr/bin/env bash
# git-commit-lock.test.sh — self-contained tests for git-commit-lock.sh.
#
# Runs entirely against throwaway temp dirs, so it never touches the repo you
# launch it from. Exit 0 == all pass.
#   bash ~/.local/bin/git-commit-lock.test.sh
#
# On failure the work dir is PRESERVED (path printed) for post-mortem; set
# GCL_TEST_PRESERVE_DIR=<dir> to additionally copy all logs/outputs there
# regardless of outcome (used by CI).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/git-commit-lock.sh"

WORK="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/git-commit-lock-test.$$")"
mkdir -p "$WORK"
cleanup() {
  if [ -n "${GCL_TEST_PRESERVE_DIR:-}" ]; then
    mkdir -p "$GCL_TEST_PRESERVE_DIR" 2>/dev/null || true
    cp -R "$WORK"/. "$GCL_TEST_PRESERVE_DIR"/ 2>/dev/null || true
    echo "note: copied test artifacts to $GCL_TEST_PRESERVE_DIR"
  fi
  if [ "${FAIL:-0}" -gt 0 ]; then
    echo "note: failures detected — work dir preserved for post-mortem: $WORK"
  else
    rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Backdate a path's mtime by $2 seconds — the lock's staleness clock is the
# lock DIR's own mtime (set by mkdir), so this is how a test fakes a stale
# lock. Portable: BSD touch has no `-d @epoch`, so convert the target epoch to
# a `touch -t` stamp via GNU `date -d @` with BSD `date -r` as fallback.
epoch_to_stamp() {
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null
}
backdate() { touch -t "$(epoch_to_stamp "$(( $(date +%s) - $2 ))")" "$1"; }

# Wait (up to $2 seconds, default 15) for a marker file to appear. Holders
# touch a ready-marker as their first act INSIDE the lock; tests gate on that
# instead of sleep-margin head starts, which flaked under load.
wait_for_file() {
  local f="$1" tries=$(( ${2:-15} * 20 ))
  while [ ! -e "$f" ] && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
  [ -e "$f" ]
}

# Critical section that loses updates without a mutex: read, gap, write+1.
INCR='n="$(cat "$1")"; sleep 0.03; echo $((n+1)) > "$1"'

echo "== Test 1: concurrent workers, mutual exclusion (repeated rounds) =="
# A single 25-worker pass is too weak to trust a rare exclusion race (the
# release-steal bug found 2026-05-30 lost ~1 update per 25 only intermittently).
# Repeat several rounds; ANY lost update across ALL rounds fails the test.
# MAX_WAIT caps a regression at 180s per worker instead of the 420s default;
# STALE stays comfortably above any realistic hold so nothing is ever stolen.
N=25; ROUNDS=8; t1_fail=0; T1ERR="$WORK/excl.err"; : > "$T1ERR"
for r in $(seq 1 $ROUNDS); do
  COUNTER="$WORK/counter.$r"; echo 0 > "$COUNTER"
  LOCK="$WORK/excl.$r.lock"; LOG="$WORK/excl.$r.log"; : > "$LOG"; pids=()
  for _ in $(seq 1 $N); do
    AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=120 \
      AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=180 \
      bash "$LIB" run -- bash -c "$INCR" _ "$COUNTER" 2>> "$T1ERR" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  c="$(cat "$COUNTER")"; a="$(grep -c ACQUIRED "$LOG")"; rl="$(grep -c RELEASED "$LOG")"
  if [ "$c" != "$N" ] || [ "$a" != "$N" ] || [ "$rl" != "$N" ] || [ -e "$LOCK" ]; then
    t1_fail=1; echo "  round $r: counter=$c acquired=$a released=$rl leftover=$([ -e "$LOCK" ] && echo yes || echo no)"
  fi
done
[ "$t1_fail" = 0 ] && ok "$ROUNDS rounds x $N workers: no lost updates, balanced acquire/release, no leftover lock" \
                    || bad "mutual-exclusion failure in at least one round (see above)"
# Regression: under contention the lock dir routinely vanishes mid-mtime-probe;
# that must NOT be misdiagnosed as "staleness detection broken" (false WARNING
# observed 2026-06-10 before the probe got its retry loop).
grep -q "Staleness detection is BROKEN" "$T1ERR" \
  && bad "spurious mtime-probe WARNING under contention (see $T1ERR)" \
  || ok "no spurious mtime-probe warnings under contention"

echo "== Test 2: stale lock (old dir mtime) is stolen =="
LOCK="$WORK/steal.lock"; LOG="$WORK/steal.log"; : > "$LOG"; MARKER="$WORK/steal-marker"
mkdir -p "$LOCK"; echo "pid=99999 host=ghost" > "$LOCK/owner"; echo "$(( $(date +%s) - 9999 ))" > "$LOCK/epoch"
backdate "$LOCK" 9999                       # make the DIR mtime ancient -> stale
echo before > "$MARKER"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
  bash "$LIB" run -- bash -c 'echo after > "$1"' _ "$MARKER"; rc=$?
[ "$rc" = 0 ] && ok "run exited 0 after steal" || bad "run exited $rc after steal"
[ "$(cat "$MARKER")" = after ] && ok "stale lock stolen, command ran" || bad "marker=$(cat "$MARKER")"
grep -q STOLE "$LOG" && ok "log records a steal" || bad "no STOLE entry"

echo "== Test 3: REGRESSION — orphan with NO epoch file is still stolen (no hang) =="
# The bug the suite caught 2026-05-30: an acquirer that died after mkdir but
# before writing epoch (or a partial-rm release) leaves a lock dir with no epoch
# file. Staleness MUST come from the dir mtime, else waiters hang to MAX_WAIT.
# Tiny MAX_WAIT so a regression fails in ~1s, not 420s.
LOCK="$WORK/orphan.lock"; LOG="$WORK/orphan.log"; : > "$LOG"; MARKER="$WORK/orphan-marker"
mkdir -p "$LOCK"                            # NB: no epoch, no owner — pure orphan
backdate "$LOCK" 9999
echo before > "$MARKER"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=5 \
  bash "$LIB" run -- bash -c 'echo after > "$1"' _ "$MARKER"; rc=$?
[ "$rc" = 0 ] && ok "epoch-less orphan stolen (no hang)" || bad "orphan NOT stolen (rc=$rc) — regression!"
[ "$(cat "$MARKER")" = after ] && ok "command ran after stealing orphan" || bad "command did not run"

echo "== Test 4: a LIVE lock is NOT stolen (waiter blocks, then proceeds) =="
LOCK="$WORK/live.lock"; LOG="$WORK/live.log"; : > "$LOG"; ORDER="$WORK/order"; echo none > "$ORDER"
READY="$WORK/t4.ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
  bash "$LIB" run -- bash -c 'echo holder-start >> "$1"; touch "$2"; sleep 3; echo holder-end >> "$1"' _ "$ORDER" "$READY" &
holder=$!
wait_for_file "$READY" || bad "T4 holder never signalled ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
  bash "$LIB" run -- bash -c 'echo waiter-ran >> "$1"' _ "$ORDER"
wait "$holder"
[ "$(tr '\n' ',' < "$ORDER")" = "none,holder-start,holder-end,waiter-ran," ] \
  && ok "ordering correct" || bad "ordering wrong: $(tr '\n' ',' < "$ORDER")"
grep -q STOLE "$LOG" && bad "waiter wrongly STOLE a live lock" || ok "no wrongful steal of live lock"

echo "== Test 4b: a ROBBED slow holder detects the theft and FAILS with 98 on release =="
# The fail-open ceiling: a hold longer than the stale window CAN be stolen by a
# contender. The robbed holder must DETECT this at release (its token no longer
# matches the dir) and exit EXACTLY 98 (the reserved stolen-mid-hold code) plus
# log a WARNING, rather than silently claim a serialised commit. The thief,
# holding its own fresh lock, must succeed.
# Note: theft requires an actual contender — a slow but UNCONTENDED holder keeps
# its lock (Test 4c). Regression guard for the lease bug found in review
# 2026-05-31; would fail if lock_release skipped the token check.
LOCK="$WORK/robbed.lock"; LOG="$WORK/robbed.log"; : > "$LOG"; OUT="$WORK/robbed-out"; : > "$OUT"
READY="$WORK/t4b.ready"
# Victim: stale=1s but holds ~4s, so its lease expires while it works.
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo victim-work >> "$1"; touch "$2"; sleep 4' _ "$OUT" "$READY" &
vpid=$!
wait_for_file "$READY" || bad "T4b victim never signalled ready"
# Thief: polls until the victim's lease goes stale (>=1s), then steals.
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$LIB" run -- bash -c 'echo thief-work >> "$1"' _ "$OUT"
thief_rc=$?
wait "$vpid"; victim_rc=$?
[ "$victim_rc" = 98 ] && ok "robbed holder exits exactly 98 (stolen mid-hold)" \
                      || bad "robbed holder rc=$victim_rc (contract says exactly 98)"
grep -q "WARNING: lock LOST" "$LOG" && ok "robbed holder logged a loud theft WARNING" || bad "no theft WARNING logged"
[ "$thief_rc" = 0 ] && ok "thief (its own fresh hold) released cleanly (rc 0)" || bad "thief rc=$thief_rc (should be 0)"
grep -q thief-work "$OUT" && ok "thief did its work" || bad "thief work missing"

echo "== Test 4c: a slow but UNCONTENDED holder keeps its lock (slowness != failure) =="
# Documents the boundary: exceeding the stale window is only dangerous when a
# contender actually steals. With no waiter, the dir is never moved, the token
# still matches, and release succeeds. (If this failed, the lock would punish
# every slow hold even when perfectly safe.)
LOCK="$WORK/slowok.lock"; LOG="$WORK/slowok.log"; : > "$LOG"; OUT="$WORK/slowok-out"; : > "$OUT"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'sleep 3; echo solo-done >> "$1"' _ "$OUT"; solo_rc=$?
[ "$solo_rc" = 0 ] && ok "uncontended slow holder released cleanly (rc 0)" || bad "uncontended slow holder rc=$solo_rc (should be 0)"
grep -q "WARNING: lock LOST" "$LOG" && bad "spurious theft WARNING with no contender" || ok "no spurious WARNING when uncontended"
grep -q solo-done "$OUT" && ok "uncontended slow holder did its work" || bad "work missing"

echo "== Test 5: run propagates the command's exit code, releases either way =="
LOCK="$WORK/rc.lock"; LOG="$WORK/rc.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 0'; [ "$?" = 0 ] && ok "exit 0 propagated" || bad "exit 0 not propagated"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 7'; [ "$?" = 7 ] && ok "exit 7 propagated" || bad "exit code not propagated"
[ -e "$LOCK" ] && bad "lock left held after run" || ok "lock released after run (success and failure)"

echo "== Test 6: default lock DIR and log live in the git dir =="
SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q; git -C "$SCRATCH" config user.email t@t; git -C "$SCRATCH" config user.name t
GITDIR="$(git -C "$SCRATCH" rev-parse --absolute-git-dir)"
READY="$WORK/t6.ready"
# Background holder so we can probe the LOCK DIR's actual location mid-hold
# (asserting only the log proved nothing about where the lock itself lives).
( cd "$SCRATCH" && bash "$LIB" run -- bash -c 'touch "$1"; sleep 2' _ "$READY" >/dev/null 2>&1 ) &
h6=$!
if wait_for_file "$READY"; then
  [ -d "$GITDIR/commit.lock" ] && ok "default lock dir is <gitdir>/commit.lock" \
                               || bad "lock dir not at $GITDIR/commit.lock while held"
else
  bad "T6 holder never started"
fi
wait "$h6"
[ -d "$GITDIR/commit.lock" ] && bad "default lock dir left behind after release" || ok "default lock dir removed on release"
[ -f "$GITDIR/git-commit-lock.log" ] && ok "lock log created in git dir ($GITDIR)" || bad "no log in git dir"

echo "== Test 7: CLI usage errors exit 96 =="
bash "$LIB" >/dev/null 2>&1;            [ "$?" = 96 ] && ok "no args -> 96" || bad "no args rc=$? (want 96)"
bash "$LIB" frobnicate >/dev/null 2>&1; [ "$?" = 96 ] && ok "unknown subcommand -> 96" || bad "unknown subcommand rc=$? (want 96)"
bash "$LIB" run >/dev/null 2>&1;        [ "$?" = 96 ] && ok "run with no command -> 96" || bad "run with no command rc=$? (want 96)"
bash "$LIB" run -- >/dev/null 2>&1;     [ "$?" = 96 ] && ok "run -- with no command -> 96" || bad "run -- rc=$? (want 96)"

echo "== Test 8: acquire timeout exits 97 and the command NEVER runs =="
LOCK="$WORK/tmo.lock"; LOG="$WORK/tmo.log"; : > "$LOG"; READY="$WORK/t8.ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$LIB" run -- bash -c 'touch "$1"; sleep 4' _ "$READY" &
h8=$!
wait_for_file "$READY" || bad "T8 holder never signalled ready"
# Waiter gives up after 1s against the live 4s holder. STALE(300) >= MAX_WAIT(1)
# here also exercises the misconfiguration warning (asserted below).
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'echo ran > "$1"' _ "$WORK/t8.ran" 2> "$WORK/t8.err"; rc=$?
[ "$rc" = 97 ] && ok "timed-out waiter exits exactly 97" || bad "timed-out waiter rc=$rc (want 97)"
[ -e "$WORK/t8.ran" ] && bad "command ran despite acquire timeout" || ok "command never ran on timeout"
grep -q "timed out" "$WORK/t8.err" && ok "timeout reported on stderr" || bad "no timeout message on stderr"
grep -q "AGENT_LOCK_MAX_WAIT" "$WORK/t8.err" && ok "STALE >= MAX_WAIT misconfiguration warned on stderr" \
                                             || bad "no STALE >= MAX_WAIT warning on stderr"
wait "$h8"; [ "$?" = 0 ] && ok "holder unaffected by the timed-out waiter" || bad "holder rc=$? (want 0)"

echo "== Test 9: sub-floor (pre-2000) dir mtime is NOT treated as stale =="
# The FILETIME-zero guard: a freshly created dir can transiently report a 1601
# mtime on Windows; anything before 2000-01-01 must be classed unsettled — the
# waiter WAITS (and here times out with 97) instead of stealing a live lock.
LOCK="$WORK/floor.lock"; LOG="$WORK/floor.log"; : > "$LOG"
mkdir -p "$LOCK"
touch -t 197001120000 "$LOCK"               # epoch ~950400 — far below the floor
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=2 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "sub-floor mtime: waiter timed out (97) instead of stealing" \
               || bad "sub-floor mtime: rc=$rc (want 97 — was the floor guard removed?)"
grep -q STOLE "$LOG" && bad "sub-floor lock was wrongly STOLEN" || ok "no steal of sub-floor lock"
[ -d "$LOCK" ] && ok "sub-floor lock dir untouched" || bad "sub-floor lock dir was removed"
rm -rf "$LOCK"

echo "== Test 10: every worktree gets its OWN lock (git-dir scoping) =="
WTREPO="$WORK/wtrepo"; mkdir -p "$WTREPO"
git -C "$WTREPO" init -q; git -C "$WTREPO" config user.email t@t; git -C "$WTREPO" config user.name t
git -C "$WTREPO" commit -q --allow-empty -m init
git -C "$WTREPO" worktree add -q "$WORK/wt" -b t10branch
MAINGD="$(git -C "$WTREPO" rev-parse --absolute-git-dir)"
WTGD="$(git -C "$WORK/wt" rev-parse --absolute-git-dir)"
case "$WTGD" in
  */worktrees/*) ok "worktree resolves its own git dir ($WTGD)";;
  *) bad "worktree git dir unexpected: $WTGD";;
esac
READY="$WORK/t10.ready"
( cd "$WORK/wt" && AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
    bash "$LIB" run -- bash -c 'touch "$1"; sleep 4' _ "$READY" >/dev/null 2>&1 ) &
h10=$!
if wait_for_file "$READY"; then
  [ -d "$WTGD/commit.lock" ] && ok "worktree lock lives in its worktree git dir" \
                             || bad "no lock at $WTGD/commit.lock while worktree holder runs"
  # Two worktrees must NOT contend: a main-repo run completes while the
  # worktree holder still holds. If they shared one lock, this would wait out
  # the 4s hold or time out at MAX_WAIT=3 (rc 97) — either way detected.
  ( cd "$WTREPO" && AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
      bash "$LIB" run -- bash -c 'true' >/dev/null 2>&1 ); rc=$?
  [ "$rc" = 0 ] && ok "main-repo run did not contend with the worktree holder" \
                || bad "main-repo run rc=$rc — contended with the worktree's lock?"
else
  bad "T10 worktree holder never started"
fi
wait "$h10"
[ -d "$WTGD/commit.lock" ] && bad "worktree lock left behind" || ok "worktree lock released"
[ -f "$WTGD/git-commit-lock.log" ] && ok "worktree log lives in its worktree git dir" || bad "no log at $WTGD"
[ -d "$MAINGD/commit.lock" ] && bad "main-repo lock left behind" || ok "main-repo lock released"

echo "== Test 11: TERM mid-hold — lock released, wrapper dies with 128+15 =="
# Regression for two demonstrated bugs: (a) the EXIT/TERM trap must actually
# release the lock when the `run` wrapper is killed; (b) the wrapper must NOT
# swallow the signal (it used to release, keep going, and exit 0 — invisible
# to any watchdog). The re-raise pattern makes it exit 143. NB bash defers the
# trap until the foreground child exits, so the child still finishes its ~2s.
LOCK="$WORK/term.lock"; LOG="$WORK/term.log"; : > "$LOG"; READY="$WORK/t11.ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'touch "$1"; sleep 2' _ "$READY" 2>/dev/null &
w11=$!
wait_for_file "$READY" || bad "T11 holder never signalled ready"
kill -TERM "$w11" 2>/dev/null
wait "$w11"; rc=$?
[ "$rc" = 143 ] && ok "TERM'd run wrapper exited 143 (signal re-raised, not swallowed)" \
                || bad "TERM'd run wrapper rc=$rc (want 143)"
[ -d "$LOCK" ] && bad "lock left held after TERM" || ok "lock released on TERM"
grep -q RELEASED "$LOG" && ok "release logged on TERM path" || bad "no RELEASED entry on TERM path"

echo "== Test 12: sourced API — acquire/release, traps, strict-mode hygiene =="
# 12a: sourcing must not impose errexit/nounset/pipefail; acquire/release work
# across separate commands; reentrant acquire is refused (rc 1, lock kept);
# release is idempotent. Distinct failure codes pinpoint the broken step.
LOCK="$WORK/src.lock"; LOG="$WORK/src.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  case "$-" in *e*|*u*) exit 71;; esac
  case "$SHELLOPTS" in *pipefail*) exit 71;; esac
  lock_acquire || exit 72
  [ -d "$2" ] || exit 73
  lock_acquire 2>/dev/null && exit 74          # reentrant acquire must fail...
  [ "$?" -eq 1 ] || exit 75                    # ...with exactly 1 (API misuse)
  [ -d "$2" ] || exit 76                       # ...and the lock must still be held
  lock_release || exit 77
  [ -d "$2" ] && exit 78
  lock_release || exit 79                      # second release: successful no-op
  exit 0
' _ "$LIB" "$LOCK"; rc=$?
[ "$rc" = 0 ] && ok "sourced acquire/release, reentrancy guard, idempotent release, no strict-mode leak" \
              || bad "sourced API basic flow failed at step code $rc"

# 12b: a pre-existing EXIT trap must survive an acquire/release cycle.
out="$(AGENT_LOCK_DIR="$WORK/src2.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  trap "echo CALLER-EXIT-TRAP" EXIT
  source "$1" && lock_acquire && lock_release
  echo inline-done
' _ "$LIB")"
echo "$out" | grep -q CALLER-EXIT-TRAP && ok "caller's pre-existing EXIT trap fired after release" \
                                       || bad "caller's EXIT trap was clobbered (output: $out)"

# 12c: exiting WHILE HOLDING releases the lock AND still runs the caller's
# original EXIT trap (chained by our handler), preserving the exit code.
out="$(AGENT_LOCK_DIR="$WORK/src3.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  trap "echo CHAINED-EXIT-TRAP" EXIT
  source "$1" || exit 70
  lock_acquire || exit 72
  exit 5
' _ "$LIB")"; rc=$?
[ "$rc" = 5 ] && ok "exit-while-holding preserves the caller's exit code (5)" || bad "exit-while-holding rc=$rc (want 5)"
echo "$out" | grep -q CHAINED-EXIT-TRAP && ok "caller's EXIT trap still ran on exit-while-holding" \
                                        || bad "caller's EXIT trap skipped on exit-while-holding"
[ -d "$WORK/src3.lock" ] && bad "lock left held after exit-while-holding" || ok "EXIT trap released the lock"
grep -q RELEASED "$LOG" && ok "release logged on EXIT path" || bad "no RELEASED entry on EXIT path"

# 12d: caller's signal traps are restored verbatim; absent traps reset to default.
out="$(AGENT_LOCK_DIR="$WORK/src4.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  trap "echo MY-TERM-HANDLER" TERM
  source "$1" || exit 70
  lock_acquire || exit 72
  lock_release || exit 77
  trap -p TERM; trap -p EXIT; trap -p INT
' _ "$LIB")"
echo "$out" | grep -q "MY-TERM-HANDLER" && ok "caller's TERM trap restored after release" \
                                        || bad "caller's TERM trap not restored (got: $out)"
echo "$out" | grep -qE "trap -- .* (EXIT|SIGINT|INT)$" && bad "leftover lock traps after release: $out" \
                                                       || ok "no leftover EXIT/INT traps after release"

# 12e: the shell must respond to TERM normally after release (it used to keep
# the lock's no-op handler and survive TERM with rc 0 — demonstrated bug).
READY="$WORK/t12.ready"
AGENT_LOCK_DIR="$WORK/src5.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  lock_release || exit 77
  touch "$2"
  sleep 5
' _ "$LIB" "$READY" &
p12=$!
wait_for_file "$READY" || bad "T12e shell never signalled ready"
kill -TERM "$p12" 2>/dev/null
wait "$p12"; rc=$?
[ "$rc" = 143 ] && ok "post-release shell dies on TERM (143) — signal disposition restored" \
                || bad "post-release shell rc=$rc on TERM (want 143; signal-immune shell?)"

echo "== Test 13: garbage AGENT_LOCK_* numerics fall back to defaults with a note =="
LOCK="$WORK/num.lock"; LOG="$WORK/num.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" \
  AGENT_LOCK_STALE_SECS=banana AGENT_LOCK_POLL_SECS=-1 AGENT_LOCK_MAX_WAIT=0 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t13.err"; rc=$?
[ "$rc" = 0 ] && ok "run succeeds despite garbage numeric config" || bad "rc=$rc with garbage numerics"
n="$(grep -c "ignoring invalid" "$WORK/t13.err")"
[ "$n" = 3 ] && ok "all 3 garbage values noted on stderr (got $n)" || bad "expected 3 'ignoring invalid' notes, got $n"

echo "== Test 14: run outside any git repo hard-fails 96 unless AGENT_LOCK_DIR is set =="
NR="$WORK/norepo"; mkdir -p "$NR"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" bash "$LIB" run -- bash -c 'true' ) 2> "$WORK/t14.err"; rc=$?
[ "$rc" = 96 ] && ok "run outside a repo refused with 96" || bad "run outside a repo rc=$rc (want 96)"
grep -q "AGENT_LOCK_DIR" "$WORK/t14.err" && ok "refusal message mentions AGENT_LOCK_DIR" || bad "unhelpful refusal message"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" AGENT_LOCK_DIR="$NR/x.lock" AGENT_LOCK_LOG="$NR/x.log" \
    bash "$LIB" run -- bash -c 'true' ) 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "explicit AGENT_LOCK_DIR works outside a repo" || bad "explicit AGENT_LOCK_DIR outside repo rc=$rc"

echo "== Test 15: grave litter (.dead.*/.rel.*) is swept at acquire =="
LOCK="$WORK/lit.lock"; LOG="$WORK/lit.log"; : > "$LOG"
mkdir -p "$LOCK.dead.1.2/sub" "$LOCK.rel.3.4"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'true'; rc=$?
[ "$rc" = 0 ] || bad "T15 run rc=$rc"
if [ -e "$LOCK.dead.1.2" ] || [ -e "$LOCK.rel.3.4" ]; then
  bad "grave litter not swept at acquire"
else
  ok "grave litter swept at acquire"
fi

# NOTE (deliberately untested): lock_release's rename-aside recovery (rm -rf
# fails -> mv the dir to a .rel.* grave -> rm the grave) only triggers when the
# recursive delete fails with the dir still present — in practice a Windows
# process holding an open handle inside the dir. POSIX rm happily removes a
# directory whose files are open, so the trigger condition cannot be simulated
# portably from this suite (chmod-based denial is unreliable on the NTFS/Cygwin
# boxes this must also run on). The path is small and exercised manually on
# Windows; see TODO-main.md item 30.

echo
echo "==== RESULT: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
