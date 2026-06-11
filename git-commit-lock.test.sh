#!/usr/bin/env bash
# git-commit-lock.test.sh — self-contained tests for git-commit-lock.sh.
#
# Runs entirely against throwaway temp dirs, so it never touches the repo you
# launch it from. Exit 0 == all pass.
#   bash ~/.local/bin/git-commit-lock.test.sh
#
# Fan-out: heavy concurrency tests default to REDUCED width so routine dev
# runs don't lag a live shared machine; set GCL_TEST_FULL=1 (CI does) for the
# full-strength canary. The suite prints which mode ran — a reduced pass must
# never masquerade as the full one.
#
# On failure the work dir is PRESERVED (path printed) for post-mortem; set
# GCL_TEST_PRESERVE_DIR=<dir> to additionally copy all logs/outputs there
# regardless of outcome (used by CI).
#
# shellcheck disable=SC2015  # The pervasive `<assert> && ok ... || bad ...`
# idiom is deliberate throughout: ok/bad are echo+counter helpers that cannot
# fail, so the classic A && B || C pitfall (C running after B fails) is moot.
# shellcheck disable=SC2310,SC2312  # info-level, deliberate: helper functions
# and command substitutions run inside conditions all over a test suite; the
# suite runs WITHOUT errexit (set -uo only) and asserts on values, not on
# implicit exit propagation.
# shellcheck disable=SC2016  # $INCR is single-quoted on purpose: it expands
# inside the worker's `bash -c`, not here.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/git-commit-lock.sh"

if [ "${GCL_TEST_FULL:-0}" = 1 ]; then
  GCL_MODE="FULL"; T1_ROUNDS=8; T1_N=25
else
  GCL_MODE="REDUCED"; T1_ROUNDS=3; T1_N=8
fi
echo "fan-out mode: $GCL_MODE (T1 ${T1_ROUNDS} rounds x ${T1_N} workers)"
[ "$GCL_MODE" = REDUCED ] && echo "  (set GCL_TEST_FULL=1 for the full-strength 8x25 canary — CI runs it)"

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
# lock FILE's own mtime (stamped by the creating write), so this is how a
# test fakes a stale lock. Portable: BSD touch has no `-d @epoch`, so convert
# the target epoch to a `touch -t` stamp via GNU `date -d @` with BSD
# `date -r` as fallback.
epoch_to_stamp() {
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null
}
backdate() { touch -t "$(epoch_to_stamp "$(( $(date +%s) - $2 ))")" "$1"; }

# Fabricate a lock file the way a real (foreign) holder would have written it:
# token line + owner line. The token MUST be "tok."-prefixed (wire format) or
# the steal's content guard will — correctly — refuse to steal it.
fabricate_lock() {  # $1=path $2=token $3=owner
  printf '%s\n%s\n' "$2" "$3" > "$1"
}

# Wait (up to $2 seconds, default 15) for a marker file to appear. Holders
# touch a ready-marker as their first act INSIDE the lock; tests gate on that
# instead of sleep-margin head starts, which flaked under load.
wait_for_file() {
  local f="$1" tries=$(( ${2:-15} * 20 ))
  while [ ! -e "$f" ] && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
  [ -e "$f" ]
}

# Wait (up to $3 seconds, default 15) for a pattern to appear in a file.
# Used to gate on the WAITING log line: proof the waiter actually contended,
# without a fixed-length hold.
wait_for_grep() {
  local pat="$1" f="$2" tries=$(( ${3:-15} * 20 ))
  while ! grep -q "$pat" "$f" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
  grep -q "$pat" "$f" 2>/dev/null
}

# Critical section that loses updates without a mutex: read, gap, write+1.
INCR='n="$(cat "$1")"; sleep 0.03; echo $((n+1)) > "$1"'

echo "== Test 1: concurrent workers, mutual exclusion (repeated rounds, $GCL_MODE width) =="
# A single pass is too weak to trust a rare exclusion race (the release-steal
# bug found 2026-05-30 lost ~1 update per 25 only intermittently). Repeat
# several rounds; ANY lost update across ALL rounds fails the test.
# MAX_WAIT caps a regression at 180s per worker instead of the 420s default;
# STALE stays comfortably above any realistic hold so nothing is ever stolen.
N=$T1_N; ROUNDS=$T1_ROUNDS; t1_fail=0; T1ERR="$WORK/excl.err"; : > "$T1ERR"
for r in $(seq 1 $ROUNDS); do
  COUNTER="$WORK/counter.$r"; echo 0 > "$COUNTER"
  LOCK="$WORK/excl.$r.lock"; LOG="$WORK/excl.$r.log"; : > "$LOG"; pids=()
  for _ in $(seq 1 $N); do
    AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=120 \
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
[ "$t1_fail" = 0 ] && ok "$ROUNDS rounds x $N workers ($GCL_MODE): no lost updates, balanced acquire/release, no leftover lock" \
                    || bad "mutual-exclusion failure in at least one round (see above)"
# Regression: under contention the lock file routinely vanishes mid-mtime-probe;
# that must NOT be misdiagnosed as "staleness detection broken" (false WARNING
# observed 2026-06-10 before the probe got its retry loop).
grep -q "Staleness detection is BROKEN" "$T1ERR" \
  && bad "spurious mtime-probe WARNING under contention (see $T1ERR)" \
  || ok "no spurious mtime-probe warnings under contention"

echo "== Test 2: stale lock (old file mtime) is stolen; holder comes from line 2 =="
LOCK="$WORK/steal.lock"; LOG="$WORK/steal.log"; : > "$LOG"; MARKER="$WORK/steal-marker"
fabricate_lock "$LOCK" "tok.fake.99999.1" "pid=99999 host=ghost"
backdate "$LOCK" 9999                       # make the FILE mtime ancient -> stale
echo before > "$MARKER"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
  bash "$LIB" run -- bash -c 'echo after > "$1"' _ "$MARKER"; rc=$?
[ "$rc" = 0 ] && ok "run exited 0 after steal" || bad "run exited $rc after steal"
[ "$(cat "$MARKER")" = after ] && ok "stale lock stolen, command ran" || bad "marker=$(cat "$MARKER")"
grep -q STOLE "$LOG" && ok "log records a steal" || bad "no STOLE entry"
grep -q "holder=pid=99999 host=ghost" "$LOG" \
  && ok "STALE log line carries the holder parsed from line 2" \
  || bad "holder from line 2 missing in the STALE log line"

echo "== Test 3: REGRESSION — EMPTY lock file (crash between create and write) is still stolen =="
# The file-protocol descendant of the 2026-05-30 orphan bug: an acquirer that
# died after the open but before (or mid-) content write leaves an empty file.
# Staleness MUST come from the file mtime and the content guard MUST class an
# empty file stealable, else waiters hang to MAX_WAIT.
LOCK="$WORK/orphan.lock"; LOG="$WORK/orphan.log"; : > "$LOG"; MARKER="$WORK/orphan-marker"
: > "$LOCK"                                 # NB: zero bytes — pure crash orphan
backdate "$LOCK" 9999
echo before > "$MARKER"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=5 \
  bash "$LIB" run -- bash -c 'echo after > "$1"' _ "$MARKER"; rc=$?
[ "$rc" = 0 ] && ok "empty-file orphan stolen (no hang)" || bad "orphan NOT stolen (rc=$rc) — regression!"
[ "$(cat "$MARKER")" = after ] && ok "command ran after stealing orphan" || bad "command did not run"

echo "== Test 4: a LIVE lock is NOT stolen (waiter logs WAITING, blocks, then proceeds) =="
LOCK="$WORK/live.lock"; LOG="$WORK/live.log"; : > "$LOG"; ORDER="$WORK/order"; echo none > "$ORDER"
READY="$WORK/t4.ready"; GO4="$WORK/t4.go"
# Holder keeps the lock until the test has SEEN the waiter contend (the
# WAITING log line) — no fixed-length hold to flake under load.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
  bash "$LIB" run -- bash -c 'echo holder-start >> "$1"; touch "$2"; until [ -e "$3" ]; do sleep 0.05; done; echo holder-end >> "$1"' \
  _ "$ORDER" "$READY" "$GO4" &
holder=$!
wait_for_file "$READY" || bad "T4 holder never signalled ready"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
  bash "$LIB" run -- bash -c 'echo waiter-ran >> "$1"' _ "$ORDER" &
waiter=$!
wait_for_grep "WAITING for lock" "$LOG" \
  && ok "waiter logged WAITING on its first blocked poll" \
  || bad "waiter never logged WAITING while blocked"
touch "$GO4"
wait "$waiter"; wait "$holder"
[ "$(tr '\n' ',' < "$ORDER")" = "none,holder-start,holder-end,waiter-ran," ] \
  && ok "ordering correct" || bad "ordering wrong: $(tr '\n' ',' < "$ORDER")"
grep -q STOLE "$LOG" && bad "waiter wrongly STOLE a live lock" || ok "no wrongful steal of live lock"

echo "== Test 4b: a ROBBED slow holder detects the theft and FAILS with 98 on release =="
# The fail-open ceiling: a hold longer than the stale window CAN be stolen by a
# contender. The robbed holder must DETECT this at release (the lock file is
# gone, or carries the thief's token) and exit EXACTLY 98 (the reserved
# stolen-mid-hold code) plus log a WARNING, rather than silently claim a
# serialised commit. The thief, holding its own fresh lock, must succeed.
# Note: theft requires an actual contender — a slow but UNCONTENDED holder keeps
# its lock (Test 4c). Regression guard for the lease bug found in review
# 2026-05-31; would fail if lock_release skipped the token check.
LOCK="$WORK/robbed.lock"; LOG="$WORK/robbed.log"; : > "$LOG"; OUT="$WORK/robbed-out"; : > "$OUT"
READY="$WORK/t4b.ready"; TDONE="$WORK/t4b.thief-done"
# Victim: stale=1s; holds until the test says the thief is done (marker, not a
# fixed sleep — under heavy load a slow-starting thief once arrived AFTER a 4s
# victim had already released, vacuously failing the theft assertions). The
# lease still goes stale 1s in while the victim waits, enabling the steal.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo victim-work >> "$1"; touch "$2"; until [ -e "$3" ]; do sleep 0.1; done' \
  _ "$OUT" "$READY" "$TDONE" &
vpid=$!
wait_for_file "$READY" || bad "T4b victim never signalled ready"
# Thief: polls until the victim's lease goes stale (>=1s), then steals.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$LIB" run -- bash -c 'echo thief-work >> "$1"' _ "$OUT"
thief_rc=$?
touch "$TDONE"
wait "$vpid"; victim_rc=$?
[ "$victim_rc" = 98 ] && ok "robbed holder exits exactly 98 (stolen mid-hold)" \
                      || bad "robbed holder rc=$victim_rc (contract says exactly 98)"
grep -q "WARNING: lock LOST" "$LOG" && ok "robbed holder logged a loud theft WARNING" || bad "no theft WARNING logged"
[ "$thief_rc" = 0 ] && ok "thief (its own fresh hold) released cleanly (rc 0)" || bad "thief rc=$thief_rc (should be 0)"
grep -q thief-work "$OUT" && ok "thief did its work" || bad "thief work missing"

echo "== Test 4c: a slow but UNCONTENDED holder keeps its lock (slowness != failure) =="
# Documents the boundary: exceeding the stale window is only dangerous when a
# contender actually steals. With no waiter, the file is never moved, the token
# still matches, and release succeeds. (If this failed, the lock would punish
# every slow hold even when perfectly safe.)
LOCK="$WORK/slowok.lock"; LOG="$WORK/slowok.log"; : > "$LOG"; OUT="$WORK/slowok-out"; : > "$OUT"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'sleep 2; echo solo-done >> "$1"' _ "$OUT"; solo_rc=$?
[ "$solo_rc" = 0 ] && ok "uncontended slow holder released cleanly (rc 0)" || bad "uncontended slow holder rc=$solo_rc (should be 0)"
grep -q "WARNING: lock LOST" "$LOG" && bad "spurious theft WARNING with no contender" || ok "no spurious WARNING when uncontended"
grep -q solo-done "$OUT" && ok "uncontended slow holder did its work" || bad "work missing"

echo "== Test 5: run propagates the command's exit code, releases either way =="
LOCK="$WORK/rc.lock"; LOG="$WORK/rc.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 0'; [ "$?" = 0 ] && ok "exit 0 propagated" || bad "exit 0 not propagated"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 7'; [ "$?" = 7 ] && ok "exit 7 propagated" || bad "exit code not propagated"
[ -e "$LOCK" ] && bad "lock left held after run" || ok "lock released after run (success and failure)"

echo "== Test 6: default lock FILE and log live in the git dir =="
SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q; git -C "$SCRATCH" config user.email t@t; git -C "$SCRATCH" config user.name t
GITDIR="$(git -C "$SCRATCH" rev-parse --absolute-git-dir)"
READY="$WORK/t6.ready"; GO6="$WORK/t6.go"
# Background holder so we can probe the LOCK's actual location mid-hold
# (asserting only the log proved nothing about where the lock itself lives).
( cd "$SCRATCH" && bash "$LIB" run -- bash -c 'touch "$1"; until [ -e "$2" ]; do sleep 0.05; done' _ "$READY" "$GO6" >/dev/null 2>&1 ) &
h6=$!
if wait_for_file "$READY"; then
  [ -f "$GITDIR/commit.lock" ] && ok "default lock is a regular FILE at <gitdir>/commit.lock" \
                               || bad "no lock file at $GITDIR/commit.lock while held"
else
  bad "T6 holder never started"
fi
touch "$GO6"
wait "$h6"
[ -e "$GITDIR/commit.lock" ] && bad "default lock file left behind after release" || ok "default lock file removed on release"
[ -f "$GITDIR/git-commit-lock.log" ] && ok "lock log created in git dir ($GITDIR)" || bad "no log in git dir"

echo "== Test 7: CLI usage errors exit 96 =="
bash "$LIB" >/dev/null 2>&1;            [ "$?" = 96 ] && ok "no args -> 96" || bad "no args rc=$? (want 96)"
bash "$LIB" frobnicate >/dev/null 2>&1; [ "$?" = 96 ] && ok "unknown subcommand -> 96" || bad "unknown subcommand rc=$? (want 96)"
bash "$LIB" run >/dev/null 2>&1;        [ "$?" = 96 ] && ok "run with no command -> 96" || bad "run with no command rc=$? (want 96)"
bash "$LIB" run -- >/dev/null 2>&1;     [ "$?" = 96 ] && ok "run -- with no command -> 96" || bad "run -- rc=$? (want 96)"

echo "== Test 8: acquire timeout exits 97 and the command NEVER runs =="
LOCK="$WORK/tmo.lock"; LOG="$WORK/tmo.log"; : > "$LOG"; READY="$WORK/t8.ready"; DONE8="$WORK/t8.done"
# Holder keeps the lock until the test says so (marker, not a fixed sleep —
# under heavy load a slow-starting waiter once arrived AFTER a 4s holder had
# released and acquired cleanly, vacuously failing every timeout assertion).
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$LIB" run -- bash -c 'touch "$1"; until [ -e "$2" ]; do sleep 0.1; done' _ "$READY" "$DONE8" &
h8=$!
wait_for_file "$READY" || bad "T8 holder never signalled ready"
# Waiter gives up after 1s against the live held lock.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'echo ran > "$1"' _ "$WORK/t8.ran" 2> "$WORK/t8.err"; rc=$?
touch "$DONE8"
[ "$rc" = 97 ] && ok "timed-out waiter exits exactly 97" || bad "timed-out waiter rc=$rc (want 97)"
[ -e "$WORK/t8.ran" ] && bad "command ran despite acquire timeout" || ok "command never ran on timeout"
grep -q "timed out" "$WORK/t8.err" && ok "timeout reported on stderr" || bad "no timeout message on stderr"
# The STALE >= MAX_WAIT advisory is GATED: it fires only when STALE was raised
# while MAX_WAIT was left at its default (the documented footgun). The waiter
# above set BOTH knobs deliberately, so it must NOT have warned; an uncontended
# run with only STALE raised (500 >= default 420) must warn.
grep -q "raise AGENT_LOCK_MAX_WAIT" "$WORK/t8.err" && bad "warning fired though both knobs were explicit" \
                                                   || ok "no misconfiguration warning when both knobs explicit"
AGENT_LOCK_PATH="$WORK/warn.lock" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=500 \
  bash "$LIB" run -- true 2> "$WORK/t8.warn.err"
grep -q "raise AGENT_LOCK_MAX_WAIT" "$WORK/t8.warn.err" && ok "STALE raised over default MAX_WAIT warns on stderr" \
                                                        || bad "no warning when STALE >= default MAX_WAIT"
wait "$h8"; [ "$?" = 0 ] && ok "holder unaffected by the timed-out waiter" || bad "holder rc=$? (want 0)"

echo "== Test 9: sub-floor (pre-2000) file mtime is NOT treated as stale =="
# The FILETIME-zero guard: a freshly created file can transiently report a 1601
# mtime to an observer on Windows (probes C/C1b — files, not just dirs);
# anything before 2000-01-01 must be classed unsettled — the waiter WAITS (and
# here times out with 97) instead of stealing a live lock.
LOCK="$WORK/floor.lock"; LOG="$WORK/floor.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.fake.1.1" "pid=1 host=h"
touch -t 197001120000 "$LOCK"               # epoch ~950400 — far below the floor
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "sub-floor mtime: waiter timed out (97) instead of stealing" \
               || bad "sub-floor mtime: rc=$rc (want 97 — was the floor guard removed?)"
grep -q STOLE "$LOG" && bad "sub-floor lock was wrongly STOLEN" || ok "no steal of sub-floor lock"
[ -f "$LOCK" ] && ok "sub-floor lock file untouched" || bad "sub-floor lock file was removed"
rm -f "$LOCK"

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
READY="$WORK/t10.ready"; GO10="$WORK/t10.go"
( cd "$WORK/wt" && AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=120 \
    bash "$LIB" run -- bash -c 'touch "$1"; until [ -e "$2" ]; do sleep 0.05; done' _ "$READY" "$GO10" >/dev/null 2>&1 ) &
h10=$!
if wait_for_file "$READY"; then
  [ -f "$WTGD/commit.lock" ] && ok "worktree lock file lives in its worktree git dir" \
                             || bad "no lock at $WTGD/commit.lock while worktree holder runs"
  # Two worktrees must NOT contend: a main-repo run completes while the
  # worktree holder still holds. If they shared one lock, this would block on
  # the held lock and time out at MAX_WAIT=3 (rc 97) — detected either way.
  ( cd "$WTREPO" && AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
      bash "$LIB" run -- bash -c 'true' >/dev/null 2>&1 ); rc=$?
  [ "$rc" = 0 ] && ok "main-repo run did not contend with the worktree holder" \
                || bad "main-repo run rc=$rc — contended with the worktree's lock?"
else
  bad "T10 worktree holder never started"
fi
touch "$GO10"
wait "$h10"
[ -e "$WTGD/commit.lock" ] && bad "worktree lock left behind" || ok "worktree lock released"
[ -f "$WTGD/git-commit-lock.log" ] && ok "worktree log lives in its worktree git dir" || bad "no log at $WTGD"
[ -e "$MAINGD/commit.lock" ] && bad "main-repo lock left behind" || ok "main-repo lock released"

echo "== Test 11: TERM mid-hold — lock released, wrapper dies with 128+15 =="
# Regression for two demonstrated bugs: (a) the EXIT/TERM trap must actually
# release the lock when the `run` wrapper is killed; (b) the wrapper must NOT
# swallow the signal (it used to release, keep going, and exit 0 — invisible
# to any watchdog). The re-raise pattern makes it exit 143. NB bash defers the
# trap until the foreground child exits, so the TERM is sent first and the
# child is then told to finish via its marker. TERM is sent twice with a gap
# (Cygwin/MSYS can drop a signal landing in a fork window — see T12e); a
# coalesced second delivery is harmless, and the retry cannot mask the
# regression (a swallowed-signal wrapper survives EVERY TERM and exits 0).
LOCK="$WORK/term.lock"; LOG="$WORK/term.log"; : > "$LOG"; READY="$WORK/t11.ready"; GO11="$WORK/t11.go"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=100 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'touch "$1"; until [ -e "$2" ]; do sleep 0.05; done' _ "$READY" "$GO11" 2>/dev/null &
w11=$!
wait_for_file "$READY" || bad "T11 holder never signalled ready"
kill -TERM "$w11" 2>/dev/null
sleep 0.1
kill -TERM "$w11" 2>/dev/null
touch "$GO11"
wait "$w11"; rc=$?
[ "$rc" = 143 ] && ok "TERM'd run wrapper exited 143 (signal re-raised, not swallowed)" \
                || bad "TERM'd run wrapper rc=$rc (want 143)"
[ -e "$LOCK" ] && bad "lock left held after TERM" || ok "lock released on TERM"
grep -q RELEASED "$LOG" && ok "release logged on TERM path" || bad "no RELEASED entry on TERM path"

echo "== Test 12: sourced API — acquire/release, traps, strict-mode hygiene =="
# 12a: sourcing must not impose errexit/nounset/pipefail; acquire/release work
# across separate commands; reentrant acquire is refused (rc 1, lock kept);
# release is idempotent. Distinct failure codes pinpoint the broken step.
LOCK="$WORK/src.lock"; LOG="$WORK/src.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  case "$-" in *e*|*u*) exit 71;; esac
  case "$SHELLOPTS" in *pipefail*) exit 71;; esac
  lock_acquire || exit 72
  [ -f "$2" ] || exit 73
  lock_acquire 2>/dev/null && exit 74          # reentrant acquire must fail...
  [ "$?" -eq 1 ] || exit 75                    # ...with exactly 1 (API misuse)
  [ -f "$2" ] || exit 76                       # ...and the lock must still be held
  lock_release || exit 77
  [ -e "$2" ] && exit 78
  lock_release || exit 79                      # second release: successful no-op
  exit 0
' _ "$LIB" "$LOCK"; rc=$?
[ "$rc" = 0 ] && ok "sourced acquire/release, reentrancy guard, idempotent release, no strict-mode leak" \
              || bad "sourced API basic flow failed at step code $rc"

# 12b: a pre-existing EXIT trap must survive an acquire/release cycle.
out="$(AGENT_LOCK_PATH="$WORK/src2.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  trap "echo CALLER-EXIT-TRAP" EXIT
  source "$1" && lock_acquire && lock_release
  echo inline-done
' _ "$LIB")"
echo "$out" | grep -q CALLER-EXIT-TRAP && ok "caller's pre-existing EXIT trap fired after release" \
                                       || bad "caller's EXIT trap was clobbered (output: $out)"

# 12c: exiting WHILE HOLDING releases the lock AND still runs the caller's
# original EXIT trap (chained by our handler), preserving the exit code.
# Own log file: the shared $LOG already carries RELEASED lines from 12a/12b,
# so a grep there could never fail — the assertion needs an unpolluted log.
LOG12C="$WORK/src3.log"; : > "$LOG12C"
out="$(AGENT_LOCK_PATH="$WORK/src3.lock" AGENT_LOCK_LOG="$LOG12C" bash -c '
  trap "echo CHAINED-EXIT-TRAP" EXIT
  source "$1" || exit 70
  lock_acquire || exit 72
  exit 5
' _ "$LIB")"; rc=$?
[ "$rc" = 5 ] && ok "exit-while-holding preserves the caller's exit code (5)" || bad "exit-while-holding rc=$rc (want 5)"
echo "$out" | grep -q CHAINED-EXIT-TRAP && ok "caller's EXIT trap still ran on exit-while-holding" \
                                        || bad "caller's EXIT trap skipped on exit-while-holding"
[ -e "$WORK/src3.lock" ] && bad "lock left held after exit-while-holding" || ok "EXIT trap released the lock"
grep -q RELEASED "$LOG12C" && ok "release logged on EXIT path" || bad "no RELEASED entry on EXIT path"

# 12d: caller's signal traps are restored verbatim; absent traps reset to default.
out="$(AGENT_LOCK_PATH="$WORK/src4.lock" AGENT_LOCK_LOG="$LOG" bash -c '
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
AGENT_LOCK_PATH="$WORK/src5.lock" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  lock_release || exit 77
  touch "$2"
  sleep 5
' _ "$LIB" "$READY" &
p12=$!
wait_for_file "$READY" || bad "T12e shell never signalled ready"
kill -TERM "$p12" 2>/dev/null
# Cygwin/MSYS can drop a signal that lands in a fork window (here: bash forking
# `sleep` right after the marker touch — observed once under heavy load, with
# the lock release demonstrably complete), so retry while the process survives.
# Retries cannot mask the regression this test guards: a shell whose lock trap
# was left armed survives EVERY TERM (the old handler released-and-continued)
# and still exits 0 after its sleep.
for _ in 1 2 3; do
  sleep 0.4
  kill -0 "$p12" 2>/dev/null || break
  kill -TERM "$p12" 2>/dev/null
done
wait "$p12"; rc=$?
[ "$rc" = 143 ] && ok "post-release shell dies on TERM (143) — signal disposition restored" \
                || bad "post-release shell rc=$rc on TERM (want 143; signal-immune shell?)"

echo "== Test 13: garbage AGENT_LOCK_* numerics fall back to defaults with a note =="
LOCK="$WORK/num.lock"; LOG="$WORK/num.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" \
  AGENT_LOCK_STALE_SECS=banana AGENT_LOCK_POLL_SECS=-1 AGENT_LOCK_MAX_WAIT=0 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t13.err"; rc=$?
[ "$rc" = 0 ] && ok "run succeeds despite garbage numeric config" || bad "rc=$rc with garbage numerics"
n="$(grep -c "ignoring invalid" "$WORK/t13.err")"
[ "$n" = 3 ] && ok "all 3 garbage values noted on stderr (got $n)" || bad "expected 3 'ignoring invalid' notes, got $n"

echo "== Test 14: run outside any git repo hard-fails 96 unless AGENT_LOCK_PATH is set =="
NR="$WORK/norepo"; mkdir -p "$NR"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" bash "$LIB" run -- bash -c 'true' ) 2> "$WORK/t14.err"; rc=$?
[ "$rc" = 96 ] && ok "run outside a repo refused with 96" || bad "run outside a repo rc=$rc (want 96)"
grep -q "AGENT_LOCK_PATH" "$WORK/t14.err" && ok "refusal message mentions AGENT_LOCK_PATH" || bad "unhelpful refusal message"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" AGENT_LOCK_PATH="$NR/x.lock" AGENT_LOCK_LOG="$NR/x.log" \
    bash "$LIB" run -- bash -c 'true' ) 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "explicit AGENT_LOCK_PATH works outside a repo" || bad "explicit AGENT_LOCK_PATH outside repo rc=$rc"

echo "== Test 15: AGED .dead.* file graves are swept at acquire; fresh or non-file ones survive =="
# The sweep is age-gated (mirrors the ps1 port): only graves older than the
# stale window (default 300s here) are collected — kept from the dir era to
# minimise churn — and it is a NON-RECURSIVE `rm -f`, so a directory at a
# grave name (e.g. old-protocol litter) is never deleted.
LOCK="$WORK/lit.lock"; LOG="$WORK/lit.log"; : > "$LOG"
printf 'tok.old.1.1\n' > "$LOCK.dead.1.2"; backdate "$LOCK.dead.1.2" 9999   # aged file grave
: > "$LOCK.dead.3.4"                                                        # FRESH file grave
mkdir -p "$LOCK.dead.5.6"; backdate "$LOCK.dead.5.6" 9999                   # aged DIRECTORY at a grave name
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'true'; rc=$?
[ "$rc" = 0 ] || bad "T15 run rc=$rc"
[ -e "$LOCK.dead.1.2" ] && bad "aged .dead.* file grave not swept at acquire" \
                        || ok "aged .dead.* file grave swept at acquire"
grep -q "SWEPT stale litter" "$LOG" && ok "sweep logged" || bad "no SWEPT entry logged"
[ -e "$LOCK.dead.3.4" ] && ok "fresh .dead.* grave NOT swept (age gate kept)" \
                        || bad "fresh .dead.* was swept — age gate broken"
[ -d "$LOCK.dead.5.6" ] && ok "directory at a grave name untouched (sweep is rm -f, never recursive)" \
                        || bad "directory grave was deleted — sweep went recursive?"
rm -rf "$LOCK.dead.3.4" "$LOCK.dead.5.6"

echo "== Test 16: EMPTY lock file at release — unverifiable lane (2 / run:1), NOT a theft verdict =="
# Truncation stands in for the probe-F window: a file that reads empty after
# the retry ladder is a successor mid-create after a boundary steal, or
# external truncation — it canNOT be our own failed write (acquire's
# read-back verified our token), but it is not PROOF of theft either. So:
# sourced release returns 2, `run` fails a successful command with 1 while
# keeping a failing command's own exit code, and the file is NOT deleted
# (it may be a successor's nascent live lock; staleness recovers an orphan).
# A GONE file, by contrast, is now definitive theft — see Test 16b.
LOCK="$WORK/notok.lock"; LOG="$WORK/notok.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  : > "$2"
  lock_release 2>/dev/null; rc=$?
  exit "$rc"
' _ "$LIB" "$LOCK"; rc=$?
[ "$rc" = 2 ] && ok "sourced release returns 2 (unverifiable), not 98" || bad "sourced empty-file release rc=$rc (want 2)"
[ -f "$LOCK" ] && ok "lock file left in place (could be a successor mid-create)" || bad "lock file removed despite unverifiable ownership"
rm -f "$LOCK"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" \
  bash "$LIB" run -- bash -c ': > "$AGENT_LOCK_PATH"' 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "run maps unverifiable release to 1 for a successful command" || bad "run empty-file rc=$rc (want 1)"
rm -f "$LOCK"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" \
  bash "$LIB" run -- bash -c ': > "$AGENT_LOCK_PATH"; exit 7' 2>/dev/null; rc=$?
[ "$rc" = 7 ] && ok "run keeps a failing command's own code (7) over the unverifiable 1" || bad "run empty-file+exit-7 rc=$rc (want 7)"
rm -f "$LOCK"

echo "== Test 16b: lock file GONE at release — definitive theft, exactly 98 =="
# File-protocol semantics flip vs the dir era: acquire's read-back proved our
# token was AT the path, so a missing file at release can only mean someone
# renamed/removed it (a steal, or external interference) — report 98, loudly.
LOCK="$WORK/gone.lock"; LOG="$WORK/gone.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  rm -f "$2"
  lock_release 2>/dev/null; rc=$?
  exit "$rc"
' _ "$LIB" "$LOCK"; rc=$?
[ "$rc" = 98 ] && ok "sourced release returns exactly 98 when the lock file is gone" \
               || bad "sourced gone-at-release rc=$rc (want 98)"
grep -q "WARNING: lock LOST" "$LOG" && ok "gone-at-release logged the theft WARNING" || bad "no theft WARNING logged"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" \
  bash "$LIB" run -- bash -c 'rm -f "$AGENT_LOCK_PATH"' 2>/dev/null; rc=$?
[ "$rc" = 98 ] && ok "run reports 98 (overrides a successful command) when the lock file is gone" \
               || bad "run gone-at-release rc=$rc (want 98)"

echo "== Test 17: NON-FILE at the lock path — never stolen, loud one-time config warning, waiters reach 97 =="
# (a) a directory (a config typo like AGENT_LOCK_PATH=\$HOME, or a leftover
# old-protocol dir lock). The per-poll type guard fires regardless of age.
LOCK="$WORK/nonfile.lock"; LOG="$WORK/nonfile.log"; : > "$LOG"
mkdir -p "$LOCK/sub"; echo data > "$LOCK/sub/file"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17a.err"; rc=$?
[ "$rc" = 97 ] && ok "directory at lock path: waiter timed out (97), command never ran" \
               || bad "directory at lock path: rc=$rc (want 97)"
[ -f "$LOCK/sub/file" ] && ok "directory and its contents untouched (never stolen/deleted)" \
                        || bad "directory at lock path was damaged!"
grep -q "is not a lock file" "$WORK/t17a.err" && ok "loud config warning on stderr" || bad "no config warning for dir at lock path"
n="$(grep -c "is not a lock file" "$WORK/t17a.err")"
[ "$n" = 1 ] && ok "config warning fired exactly once per process (got $n)" || bad "config warning fired $n times (want 1)"
grep -q STOLE "$LOG" && bad "non-file was STOLEN" || ok "no steal attempted on a directory"
rm -rf "$LOCK"
# (b) a symlink (dangling — the nastiest case: O_CREAT|O_EXCL refuses it
# forever, yet it reads as absent to a bare `-e`). Skipped where symlinks
# can't be created (default Git-Bash on Windows); CI's POSIX legs cover it.
LOCK="$WORK/symlink.lock"; LOG="$WORK/symlink.log"; : > "$LOG"
if env MSYS=winsymlinks:nativestrict ln -s "$WORK/no-such-target" "$LOCK" 2>/dev/null && [ -L "$LOCK" ]; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
    AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
    bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17b.err"; rc=$?
  [ "$rc" = 97 ] && ok "dangling symlink at lock path: waiter timed out (97)" \
                 || bad "dangling symlink: rc=$rc (want 97)"
  [ -L "$LOCK" ] && ok "symlink untouched" || bad "symlink was removed/replaced"
  grep -q "is not a lock file" "$WORK/t17b.err" && ok "config warning names the symlink case" \
                                                || bad "no config warning for symlink at lock path"
  rm -f "$LOCK"
else
  rm -f "$LOCK"
  echo "note: cannot create symlinks here — symlink guard not exercised (CI POSIX legs cover it)"
fi
# (c) a FIFO — the reason the pre-create type guard is mandatory: noclobber's
# exists=>fail applies to regular files only, and a bare `>` open on a FIFO
# BLOCKS in open(2) before any timeout logic runs. Bounded externally so a
# regression fails fast instead of hanging the suite.
LOCK="$WORK/fifo.lock"; LOG="$WORK/fifo.log"; : > "$LOG"
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$LOCK" 2>/dev/null && [ -p "$LOCK" ]; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
    AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
    bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17c.err" &
  p17=$!
  hung=0
  for _ in $(seq 1 100); do kill -0 "$p17" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$p17" 2>/dev/null; then
    hung=1
    bad "FIFO at lock path HUNG the acquirer — pre-create type guard missing"
    kill -9 "$p17" 2>/dev/null          # exact PID we spawned; nothing else
    ( : < "$LOCK" ) 2>/dev/null &       # pair a reader with the stuck writer-open so the orphan subshell can die
    wait "$p17" 2>/dev/null
  else
    wait "$p17"; rc=$?
    [ "$rc" = 97 ] && ok "FIFO at lock path: no hang, waiter timed out (97)" \
                   || bad "FIFO at lock path: rc=$rc (want 97)"
    grep -q "is not a lock file" "$WORK/t17c.err" && ok "config warning for FIFO at lock path" \
                                                  || bad "no config warning for FIFO"
  fi
  [ "$hung" = 0 ] && { [ -p "$LOCK" ] && ok "FIFO untouched" || bad "FIFO was removed/replaced"; }
  rm -f "$LOCK"
else
  rm -f "$LOCK" 2>/dev/null
  echo "note: mkfifo unavailable/unusable here — FIFO guard not exercised (CI POSIX legs cover it)"
fi

echo "== Test 17d: REGRESSION — create/delete churn at the lock path must NOT fire the non-lock warning =="
# The per-poll guard's existence (-e/-L) and classification (-f && ! -L)
# checks are SEPARATE stats. A rival's release/steal unlink landing between
# them — or a Windows delete-pending ghost (the unlink queues behind a rival
# reader's transient handle; attribute stats fail while a bare -e still
# reports existence, for up to ~ms) — made a normal contended poll warn
# "is not a regular file": a loud config-warning false alarm under plain
# contention (round-2 review, 2026-06-11; the ghost defeats an immediate
# re-probe, which is why the guard now classifies CONCRETE wrong types
# only). A single-process churner create/deletes the lock file rapidly (the
# absent window is one back-to-back delete->create gap, far too narrow for
# a waiter to slip its create into) while 3 rounds x 4 parallel short
# waiters poll through thousands of unlink transitions. ANY non-lock warning
# fails; the waiters must still time out at 97 (the churned file always
# reads as a fresh live lock at STALE=300 — never stealable, never held).
# Churner: pwsh on Windows (fork-free tight loop; reverting the guard fix
# reproduced warnings in 5/5 probe reps of this shape); perl elsewhere
# (fork-free with fast POSIX syscalls; a 2ms present-hold keeps the file
# present-dominant). Reaped by its exact PID only, via a stop marker.
LOCK="$WORK/churn.lock"; LOG="$WORK/churn.log"; : > "$LOG"
STOP="$WORK/churn.stop"; rm -f "$STOP"
churn_pid=""; churn_skip=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v pwsh >/dev/null 2>&1; then
      LOCKW="$(cygpath -m "$LOCK" 2>/dev/null || echo "$LOCK")"
      STOPW="$(cygpath -m "$STOP" 2>/dev/null || echo "$STOP")"
      pwsh -NoProfile -Command "
        for (\$i = 1; \$i -le 2000000; \$i++) {
          try { [IO.File]::WriteAllText('$LOCKW', \"tok.churn.1.1\`npid=1 host=churn\`n\") } catch { }
          if ((\$i % 256) -eq 0 -and (Test-Path -LiteralPath '$STOPW')) { break }
          try { [IO.File]::Delete('$LOCKW') } catch { }
        }
      " >/dev/null 2>&1 &
      churn_pid=$!
    else
      churn_skip="pwsh not on PATH (Windows churner)"
    fi
    ;;
  *)
    if command -v perl >/dev/null 2>&1; then
      perl -e '
        my ($lock, $stop) = @ARGV;
        for (my $i = 1; $i <= 2000000; $i++) {
          if (open(my $fh, ">", $lock)) { print $fh "tok.churn.1.1\npid=1 host=churn\n"; close $fh; }
          last if (($i % 256) == 0 && -e $stop);
          select(undef, undef, undef, 0.002);
          unlink $lock;
        }
      ' "$LOCK" "$STOP" &
      churn_pid=$!
    else
      churn_skip="perl not available (POSIX churner)"
    fi
    ;;
esac
if [ -n "$churn_pid" ]; then
  if wait_for_file "$LOCK"; then
    warn17d=0; got97=0
    for r in 1 2 3; do
      pids=()
      for i in 1 2 3 4; do
        AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
          AGENT_LOCK_POLL_SECS=0.02 AGENT_LOCK_MAX_WAIT=2 \
          bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17d.$r.$i.err" &
        pids+=($!)
      done
      for i in 1 2 3 4; do
        wait "${pids[$((i-1))]}"; rc=$?
        [ "$rc" = 97 ] && got97=$((got97+1))
        n="$(grep -c 'is not a lock file' "$WORK/t17d.$r.$i.err")"
        warn17d=$((warn17d+n))
      done
    done
    [ "$warn17d" = 0 ] && ok "12 waiters polled through churn with ZERO spurious non-lock warnings" \
                       || bad "churned regular file fired $warn17d non-lock warning(s) — per-poll guard TOCTOU regression!"
    [ "$got97" -ge 1 ] && ok "waiters still timed out at 97 under churn ($got97/12)" \
                       || bad "no waiter reached 97 under churn (got97=$got97/12) — timeout lane bypassed?"
  else
    bad "T17d churner never started churning"
  fi
  # Reap the churner deterministically: stop marker, bounded wait on ITS
  # exact pid, hard-kill of that same pid as a last resort (never by name).
  touch "$STOP"
  reaped=0
  for _ in $(seq 1 100); do kill -0 "$churn_pid" 2>/dev/null || { reaped=1; break; }; sleep 0.05; done
  [ "$reaped" = 1 ] || kill -9 "$churn_pid" 2>/dev/null
  wait "$churn_pid" 2>/dev/null
  rm -f "$LOCK" "$STOP"
else
  echo "note: $churn_skip — churn-vs-guard regression not exercised here (CI legs cover it)"
fi

echo "== Test 18: stale NON-LOCK CONTENT at the lock path is never stolen; torn tokens split on the tok. prefix =="
# The content guard (age-gated): steal only an empty file or a line 1 starting
# "tok.". A real user file at a typo'd AGENT_LOCK_PATH must survive, forever.
# (a) a user file
LOCK="$WORK/userfile.lock"; LOG="$WORK/userfile.log"; : > "$LOG"
printf 'my precious data\nline two\n' > "$LOCK"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t18a.err"; rc=$?
[ "$rc" = 97 ] && ok "stale user file: waiter timed out (97) instead of stealing" \
               || bad "stale user file: rc=$rc (want 97)"
[ "$(cat "$LOCK" 2>/dev/null)" = "$(printf 'my precious data\nline two')" ] \
  && ok "user file content fully intact" || bad "user file was damaged or deleted!"
grep -q "is not a lock file" "$WORK/t18a.err" && ok "config warning names the non-lock content" \
                                              || bad "no config warning for non-lock content"
grep -q STOLE "$LOG" && bad "user file was STOLEN" || ok "no steal of the user file"
rm -f "$LOCK"
# (b) a torn write SHORTER than the "tok." prefix (ENOSPC/crash mid-write):
# non-empty, non-prefixed => the never-steal lane (accepted residual; loud,
# fixed by one manual rm).
LOCK="$WORK/torn.lock"; LOG="$WORK/torn.log"; : > "$LOG"
printf 'to' > "$LOCK"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=1 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t18b.err"; rc=$?
[ "$rc" = 97 ] && ok "sub-prefix torn write ('to'): never stolen, waiter timed out (97)" \
               || bad "sub-prefix torn write: rc=$rc (want 97)"
[ -f "$LOCK" ] && ok "torn file left for manual fix" || bad "torn file was removed"
grep -q "is not a lock file" "$WORK/t18b.err" && ok "torn write warned as non-lock content" \
                                              || bad "no config warning for the torn write"
rm -f "$LOCK"
# (c) a torn write that DID get past the prefix ("tok."-prefixed, no newline):
# lock-shaped => the normal staleness steal lane (same class as empty orphan).
LOCK="$WORK/tornok.lock"; LOG="$WORK/tornok.log"; : > "$LOG"; MARKER="$WORK/tornok-marker"
printf 'tok.someone.torn' > "$LOCK"; backdate "$LOCK" 9999
echo before > "$MARKER"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
  bash "$LIB" run -- bash -c 'echo after > "$1"' _ "$MARKER"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$MARKER")" = after ] \
  && ok "tok.-prefixed torn token IS stolen by staleness (crash-orphan lane)" \
  || bad "tok.-prefixed torn token not stolen (rc=$rc marker=$(cat "$MARKER"))"
grep -q STOLE "$LOG" && ok "steal of the torn token logged" || bad "no STOLE entry for torn token"

echo "== Test 19: wire format — token on line 1 (tok.-prefixed), owner on line 2 =="
# Pins the on-disk format the ps1 port must match, and that token parsing
# takes LINE 1 only (an owner line present must not pollute the token).
LOCK="$WORK/wire.lock"; LOG="$WORK/wire.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  { IFS= read -r l1; IFS= read -r l2; } < "$2" || exit 73
  [ "$l1" = "$_LOCK_TOKEN" ] || exit 74        # line 1 IS the token, exactly
  case "$l1" in tok.*) ;; *) exit 75;; esac    # wire-format prefix
  case "$l2" in "pid="*" host="*) ;; *) exit 76;; esac   # owner line shape
  lock_release || exit 77
  exit 0
' _ "$LIB" "$LOCK"; rc=$?
[ "$rc" = 0 ] && ok "lock file carries token (line 1, tok.-prefixed) + owner (line 2); release parses line 1 with owner present" \
              || bad "wire-format check failed at step code $rc"

# NOTES (deliberately untested here):
# * lock_release's LEFTOVER lane (the unlink blocked persistently) needs a
#   foreign no-delete-share handle on the lock file — Windows-only, and the
#   blocker is most naturally a pwsh FileShare.Read holder, so the interop
#   suite owns that test (on POSIX, unlink never blocks on open handles and
#   the lane is unreachable).
# * lock_acquire's read-back-verification failure lane needs fault injection
#   to make a winning create read back wrong; it is defence in depth (see the
#   ACQUIRE VERIFICATION header section), not suite-covered.

echo
echo "==== RESULT: $PASS passed, $FAIL failed (fan-out: $GCL_MODE) ===="
[ "$FAIL" = 0 ]
