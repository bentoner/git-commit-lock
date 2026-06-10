#!/usr/bin/env bash
# commit-lock.test.sh — self-contained tests for commit-lock.sh.
#
# Runs entirely against throwaway temp dirs, so it never touches the repo you
# launch it from. Exit 0 == all pass.
#   bash ~/.local/bin/commit-lock.test.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/commit-lock.sh"

WORK="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/commit-lock-test.$$")"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Backdate a dir's mtime by N seconds — the lock's staleness clock is the lock
# DIR's own mtime (set by mkdir), so this is how a test fakes an old/stale lock.
backdate() { touch -d "@$(( $(date +%s) - $2 ))" "$1"; }

# Critical section that loses updates without a mutex: read, gap, write+1.
INCR='n="$(cat "$1")"; sleep 0.03; echo $((n+1)) > "$1"'

echo "== Test 1: concurrent workers, mutual exclusion (repeated rounds) =="
# A single 25-worker pass is too weak to trust a rare exclusion race (the
# release-steal bug found 2026-05-30 lost ~1 update per 25 only intermittently).
# Repeat several rounds; ANY lost update across ALL rounds fails the test.
N=25; ROUNDS=8; t1_fail=0
for r in $(seq 1 $ROUNDS); do
  COUNTER="$WORK/counter.$r"; echo 0 > "$COUNTER"
  LOCK="$WORK/excl.$r.lock"; LOG="$WORK/excl.$r.log"; : > "$LOG"; pids=()
  for i in $(seq 1 $N); do
    AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 \
      bash "$LIB" run -- bash -c "$INCR" _ "$COUNTER" &
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

echo "== Test 2: stale lock (old dir mtime) is stolen =="
LOCK="$WORK/steal.lock"; LOG="$WORK/steal.log"; : > "$LOG"; MARKER="$WORK/steal-marker"
mkdir -p "$LOCK"; echo "pid=99999 host=ghost" > "$LOCK/owner"; echo "$(( $(date +%s) - 9999 ))" > "$LOCK/epoch"
backdate "$LOCK" 9999                       # make the DIR mtime ancient -> stale
echo before > "$MARKER"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 \
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
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo holder-start >> "$1"; sleep 3; echo holder-end >> "$1"' _ "$ORDER" &
holder=$!; sleep 0.5
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo waiter-ran >> "$1"' _ "$ORDER"
wait "$holder"
[ "$(tr '\n' ',' < "$ORDER")" = "none,holder-start,holder-end,waiter-ran," ] \
  && ok "ordering correct" || bad "ordering wrong: $(tr '\n' ',' < "$ORDER")"
grep -q STOLE "$LOG" && bad "waiter wrongly STOLE a live lock" || ok "no wrongful steal of live lock"

echo "== Test 4b: a ROBBED slow holder detects the theft and FAILS on release =="
# The fail-open ceiling: a hold longer than the stale window CAN be stolen by a
# contender. The robbed holder must DETECT this at release (its token no longer
# matches the dir) and return non-zero + log a WARNING, rather than silently
# claim a serialised commit. The thief, holding its own fresh lock, must succeed.
# Note: theft requires an actual contender — a slow but UNCONTENDED holder keeps
# its lock (Test 4c). Regression guard for the lease bug found in review
# 2026-05-31; would fail if lock_release skipped the token check.
LOCK="$WORK/robbed.lock"; LOG="$WORK/robbed.log"; : > "$LOG"; OUT="$WORK/robbed-out"; : > "$OUT"
# Victim: stale=1s but holds ~3s, so its lease expires while it works.
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo victim-work >> "$1"; sleep 3' _ "$OUT" &
vpid=$!
sleep 1.5   # let the victim's lease go stale, then a thief steals it
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$LIB" run -- bash -c 'echo thief-work >> "$1"' _ "$OUT"
thief_rc=$?
wait "$vpid"; victim_rc=$?
[ "$victim_rc" -ne 0 ] && ok "robbed holder returns non-zero (got $victim_rc)" \
                       || bad "robbed holder returned 0 — silent fail-open (token check missing?)"
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

echo "== Test 6: default lock lives in the git dir =="
SCRATCH="$WORK/scratch"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q; git -C "$SCRATCH" config user.email t@t; git -C "$SCRATCH" config user.name t
( cd "$SCRATCH" && bash "$LIB" run -- bash -c 'true' >/dev/null 2>&1 )
GITDIR="$(git -C "$SCRATCH" rev-parse --absolute-git-dir)"
[ -f "$GITDIR/commit-lock.log" ] && ok "lock log created in git dir ($GITDIR)" || bad "no log in git dir"

echo
echo "==== RESULT: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
