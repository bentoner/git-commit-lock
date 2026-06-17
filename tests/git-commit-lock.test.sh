#!/usr/bin/env bash
# git-commit-lock.test.sh — self-contained tests for git-commit-lock.sh.
#
# Runs entirely against throwaway temp dirs, so it never touches the repo you
# launch it from. Exit 0 == all pass.
#   bash tests/git-commit-lock.test.sh
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
ROOT="$(cd "$DIR/.." && pwd)"   # the implementations live at the repo root
LIB="$ROOT/git-commit-lock.sh"

if [ "${GCL_TEST_FULL:-0}" = 1 ]; then
  GCL_MODE="FULL"; T1_ROUNDS=8; T1_N=25; T2B_ROUNDS=4; T20_N=10
else
  GCL_MODE="REDUCED"; T1_ROUNDS=3; T1_N=8; T2B_ROUNDS=2; T20_N=5
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
# Sentinel: the suite reaching its end sets DONE=1. If the EXIT trap fires with
# DONE!=1, the suite died early (a stray exit/crash) and the assertion count is
# unreliable — fail loudly even if the pre-trap code was 0. A bare trap `return`
# is IGNORED (the script keeps its pre-trap code), so the guard must `exit 1`.
finish() {
  cleanup
  if [ "${DONE:-0}" != 1 ]; then
    echo "Bail out! suite terminated early before the plan line; ran ${TAPN:-0} assertion(s), count unreliable" >&2
    exit 1
  fi
}
trap finish EXIT

PASS=0; FAIL=0; TAPN=0; DONE=0
GCL_TAP="${GCL_TAP:-0}"           # CI sets GCL_TAP=1 for machine-readable TAP13 output
# ok/bad are TAP-aware (gated by GCL_TAP so plain dev runs are byte-unchanged) and
# bump the running assertion number TAPN. The trailing `1..$TAPN` plan line (emitted
# just before the verdict) lets a TAP consumer fail on a short count; together with the
# DONE sentinel above this closes the silent-undercount gap. `return 0` preserves the
# "ok/bad cannot fail" property the `<assert> && ok ... || bad ...` idiom relies on.
ok()  { PASS=$((PASS+1)); TAPN=$((TAPN+1)); echo "PASS: $*"
        [ "$GCL_TAP" = 1 ] && echo "ok $TAPN - $*"; return 0; }
bad() { FAIL=$((FAIL+1)); TAPN=$((TAPN+1)); echo "FAIL: $*"
        [ "$GCL_TAP" = 1 ] && echo "not ok $TAPN - $*"; return 0; }

# Envelope-tier assertions (Bucket 4 / decision D-c). A wall-clock or poll-count
# bound is a Tier-2 (best-effort latency) property, NOT a correctness one (see
# guarantees.md BE-1). In the default 'strict' tier these behave exactly like
# ok/bad. Under GCL_ENVELOPE_TIER=relax (nightly/deep stress runs) an envelope FAIL
# becomes a WARN that does NOT increment FAIL — so an oversubscribed runner can't
# turn a latency miss into a red — while every CORRECTNESS assertion keeps ok/bad
# and stays hard in both tiers. TAP-aware so envelope assertions still count toward 1..N.
ENVELOPE_TIER="${GCL_ENVELOPE_TIER:-strict}"
ENV_WARN=0
ok_envelope()  { PASS=$((PASS+1)); TAPN=$((TAPN+1)); echo "PASS[env]: $*"
                 [ "$GCL_TAP" = 1 ] && echo "ok $TAPN - $*"; return 0; }
bad_envelope() {
  if [ "$ENVELOPE_TIER" = relax ]; then
    ENV_WARN=$((ENV_WARN+1)); TAPN=$((TAPN+1)); echo "WARN[env-relaxed]: $*"
    [ "$GCL_TAP" = 1 ] && echo "ok $TAPN - $* # env-relaxed"
  else
    FAIL=$((FAIL+1)); TAPN=$((TAPN+1)); echo "FAIL: $*"
    [ "$GCL_TAP" = 1 ] && echo "not ok $TAPN - $*"
  fi; return 0; }

# Backdate a path's mtime by $2 seconds — the lock's staleness clock is the
# lock FILE's own mtime (stamped by the creating write), so this is how a
# test fakes a stale lock. Portable: BSD touch has no `-d @epoch`, so convert
# the target epoch to a `touch -t` stamp via GNU `date -d @` with BSD
# `date -r` as fallback.
epoch_to_stamp() {
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null
}
backdate() { touch -t "$(epoch_to_stamp "$(( $(date +%s) - $2 ))")" "$1"; }

# Token-guarded backdate for the contended-recovery rounds (T2b). Why: under
# load a fast waiter can complete its ENTIRE steal (claim -> rename-over ->
# ACQUIRED) before the harness's `touch` executes, so a blind backdate lands
# on the WINNER'S freshly installed lock, making it instantly stale for every
# rival — a legitimate re-steal then fails the round's "zero 98s / exactly
# one STOLE-BY-CLAIM" assertions although the protocol behaved exactly as
# designed (observed 2026-06-12 on a loaded box). Verdicts:
#   * pre-read not the ghost: a waiter stole the ghost BEFORE the touch (it
#     aged stale naturally during a stalled sync); no touch is performed and
#     the round premise is gone — invalid, the caller retries the round.
#   * post-read the ghost: conclusive — nothing ever rewrites the ghost
#     token at the path, so the touch verifiably hit the ghost; any steal
#     after the post-read steals an ALREADY-ancient ghost, exactly the
#     scenario the round wants. Valid.
#   * post-read anything else: a steal raced the touch->re-read window —
#     COMMON under load (waiters poll every 0.05s; the post-read costs
#     subprocess spawns), so it must not blindly invalidate. The lock's
#     MTIME arbitrates which file the touch hit: a winner's installed lock
#     is FRESH (the rename carries the claim file's just-created mtime), so
#     fresh => the touch hit the GHOST and a legitimate steal followed —
#     valid; ancient => the touch landed on the WINNER'S live lock and
#     corrupted the round — invalid, retry. Vanished => cannot arbitrate —
#     invalid, retry.
backdate_ghost() {  # $1=lock $2=ghost token $3=age-secs -> 0 iff the round premise is intact
  local pre post now mt
  pre="$(head -n 1 -- "$1" 2>/dev/null | tr -d '\r')"
  [ "$pre" = "$2" ] || return 1
  backdate "$1" "$3" 2>/dev/null || return 1
  post="$(head -n 1 -- "$1" 2>/dev/null | tr -d '\r')"
  [ "$post" = "$2" ] && return 0
  [ -e "$1" ] || return 1
  now="$(date +%s)"
  mt="$(stat -c %Y -- "$1" 2>/dev/null || stat -f %m -- "$1" 2>/dev/null)" || return 1
  [ $(( now - mt )) -lt $(( $3 / 2 )) ]
}

# Wait for every waiter's WAITING line while keeping the ghost lock FRESH
# (touch -c to now, no-create so a released path is never resurrected): a
# fresh ghost cannot be judged stale, so no waiter can steal it before the
# guarded backdate — without this, a sync stalled past STALE (slow worker
# cold starts on a loaded box) lets the ghost age stale naturally and a
# waiter steals it mid-sync. Freshening is race-safe: if a steal slipped in
# anyway, touching the winner's (already fresh) live lock to "now" is a
# harmless no-op, and backdate_ghost's pre-read catches the broken premise.
sync_waiting_fresh() {  # $1=lock $2=timeout-secs $3..=waiter logs -> 0 iff all logged WAITING
  local lock="$1" deadline f ok=1
  deadline=$(( $(date +%s) + $2 )); shift 2
  for f in "$@"; do
    until grep -q "WAITING for lock" "$f" 2>/dev/null; do
      touch -c "$lock" 2>/dev/null
      if [ "$(date +%s)" -ge "$deadline" ]; then ok=0; break; fi
      sleep 0.2
    done
  done
  [ "$ok" = 1 ]
}

# Clone a shell function under a new name — the steering tests' interposition
# mechanism: a sourced test shell wraps a library internal (or a command like
# mv/rm/touch with a shell function, which shadows the binary) to land "the
# rival's rename" at an exact protocol position deterministically, then calls
# the original through the clone. Exported (with the backdate helpers) so the
# bash -c steering shells inherit them.
clone_fn() {  # $1=existing function $2=new name
  eval "$(declare -f "$1" | sed "1s/$1/$2/")"
}
export -f clone_fn epoch_to_stamp backdate

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
for r in $(seq 1 "$ROUNDS"); do
  COUNTER="$WORK/counter.$r"; echo 0 > "$COUNTER"
  LOCK="$WORK/excl.$r.lock"; LOG="$WORK/excl.$r.log"; : > "$LOG"; pids=()
  for _ in $(seq 1 "$N"); do
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

echo "== Test 2b: crash recovery under CONTENTION — claim-serialized: zero displacement, zero 98s ($GCL_MODE: $T2B_ROUNDS rounds) =="
# The claim SERIALIZES stealers, so the straggler-robs-recovery-winner race
# is PREVENTED, not detected-and-repaired. Scenario: one crashed lock, N
# waiters judging stale in the same poll window (the launch/backdate sync
# keeps them in one window). Assertions: every waiter exits 0 (zero spurious
# 98s — an unserialized implementation displaces the recovery winner 5/5 in
# probes), NO move-aside file ever exists (an implementation that staged the
# steal through an intermediate .dead.* file would re-open the displacement
# race; a background sampler proves no such file ever appears), the recovery
# is exactly one STOLE-BY-CLAIM per round (an unserialized lane's "STOLE
# stale lock" shape must never appear), zero STEAL-DISPLACED lines
# (prevention leaves nothing to repair), and a clean final state (no lock,
# no claim). STALE=8 keeps a loaded box from
# turning the winner's 0.1s hold into a legitimate second steal.
# Harness race guards: the sync keeps the ghost fresh while it waits
# (sync_waiting_fresh) so a stalled sync can't let the ghost age stale on
# its own, and the backdate is token-guarded (backdate_ghost) — when a fast
# waiter's completed steal races the touch (the touch may then have aged the
# WINNER'S live lock), the attempt is kept only if its outcome is clean and
# otherwise discarded and retried (bounded), instead of failing assertions
# the protocol never violated.
T2B_N=4
T2B_TRIES=3   # per-round attempts; see the backdate_ghost note
t2b_fail=0; t2b_stole=0; t2b_old_shape=0; t2b_disp=0; t2b_98=0; t2b_retried=0
for r in $(seq 1 "$T2B_ROUNDS"); do
  t2b_valid=0
  for try in $(seq 1 "$T2B_TRIES"); do
    GHOST="tok.ghost.t2b.$r.$try"
    LOCK="$WORK/recov.$r.lock"; RAN="$WORK/recov.$r.ran"; : > "$RAN"
    GRAVESEEN="$WORK/recov.$r.graveseen"; SAMPSTOP="$WORK/recov.$r.sampstop"
    rm -f "$GRAVESEEN" "$SAMPSTOP" "$LOCK" "$LOCK.next"
    fabricate_lock "$LOCK" "$GHOST" "pid=999 host=ghost" # fresh mtime: not yet stale
    # Move-aside sampler: ANY .dead.* sighting at ANY moment during the round
    # means the implementation stages the steal through an intermediate file
    # (an end-state check would miss a create-then-delete one).
    (
      while [ ! -e "$SAMPSTOP" ]; do
        for g in "$LOCK".dead.*; do
          [ -e "$g" ] && : > "$GRAVESEEN"
        done
        sleep 0.01
      done
    ) &
    sampler=$!
    pids=()
    for i in $(seq 1 "$T2B_N"); do
      : > "$WORK/recov.$r.$i.log"   # per-waiter logs: concurrent appends to one log drop lines
      AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/recov.$r.$i.log" AGENT_LOCK_STALE_SECS=8 \
        AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
        bash "$LIB" run -- bash -c 'echo ran >> "$1"; sleep 0.1' _ "$RAN" 2>/dev/null &
      pids+=($!)
    done
    t2b_sync=1
    if ! sync_waiting_fresh "$LOCK" 60 "$WORK/recov.$r.1.log" "$WORK/recov.$r.2.log" \
                            "$WORK/recov.$r.3.log" "$WORK/recov.$r.4.log"; then
      t2b_sync=0
      for i in $(seq 1 "$T2B_N"); do
        grep -q "WAITING for lock" "$WORK/recov.$r.$i.log" 2>/dev/null \
          || echo "  round $r: waiter $i never logged WAITING"
      done
    fi
    backdate_ghost "$LOCK" "$GHOST" 9999; bd=$?   # all waiters now judge the ghost stale together
    round_98=0; round_badrc=0
    for i in $(seq 1 "$T2B_N"); do
      wait "${pids[$((i-1))]}"; rc=$?
      case "$rc" in
        0)  ;;
        98) round_98=$((round_98+1)); echo "  round $r: waiter $i rc=98 — displacement under the claim protocol" ;;
        *)  round_badrc=$((round_badrc+1)); echo "  round $r: waiter $i rc=$rc (want 0)" ;;
      esac
    done
    touch "$SAMPSTOP"; wait "$sampler" 2>/dev/null
    cat "$WORK/recov.$r."*.log > "$WORK/recov.$r.all.log"
    if [ "$bd" != 0 ]; then
      # The backdate was NOT conclusively clean (see backdate_ghost; under
      # load the whole steal+release cycle often completes before the
      # post-read, leaving nothing to arbitrate). Accept the attempt anyway
      # if its OUTCOME is clean: harness interference (the touch ageing a
      # live lock) always manifests in the outcome — 98s, LOST warnings,
      # extra steals, leftovers — so a clean outcome satisfies the round's
      # assertions regardless of which file the touch hit. A dirty outcome
      # under a non-conclusive backdate is unattributable: discard the
      # attempt and retry the round.
      round_dirty=0
      [ "$round_98" = 0 ] && [ "$round_badrc" = 0 ] || round_dirty=1
      [ "$t2b_sync" = 1 ] || round_dirty=1
      [ "$(grep -c "STOLE-BY-CLAIM" "$WORK/recov.$r.all.log")" = 1 ] || round_dirty=1
      [ "$(grep -c "lock LOST" "$WORK/recov.$r.all.log")" = 0 ] || round_dirty=1
      { [ -e "$LOCK" ] || [ -e "$LOCK.next" ]; } && round_dirty=1
      if [ "$round_dirty" = 1 ]; then
        t2b_retried=$((t2b_retried+1))
        echo "  round $r try $try: non-conclusive backdate AND dirty outcome — attempt discarded, retrying"
        rm -f "$LOCK" "$LOCK.next" "$RAN" "$GRAVESEEN" "$SAMPSTOP"
        continue
      fi
    fi
    t2b_valid=1
    [ "$t2b_sync" = 1 ] || t2b_fail=1
    [ "$round_badrc" = 0 ] || t2b_fail=1
    t2b_98=$((t2b_98+round_98))
    nran="$(grep -c ran "$RAN")"
    [ "$nran" = "$T2B_N" ] || {
      t2b_fail=1
      echo "  round $r: only $nran/$T2B_N commands ran"
    }
    [ -e "$LOCK" ] && {
      t2b_fail=1
      echo "  round $r: leftover lock"
    }
    [ -e "$LOCK.next" ] && {
      t2b_fail=1
      echo "  round $r: leftover claim"
    }
    [ -e "$GRAVESEEN" ] && {
      t2b_fail=1
      echo "  round $r: a move-aside file (.dead.*) existed during recovery — the steal is staged through an intermediate file!"
    }
    t2b_stole=$((t2b_stole + $(grep -c "STOLE-BY-CLAIM" "$WORK/recov.$r.all.log")))
    t2b_old_shape=$((t2b_old_shape + $(grep -c "STOLE stale lock" "$WORK/recov.$r.all.log")))
    t2b_disp=$((t2b_disp + $(grep -c "STEAL-DISPLACED" "$WORK/recov.$r.all.log")))
    break
  done
  [ "$t2b_valid" = 1 ] || { t2b_fail=1; echo "  round $r: no clean round under a conclusive backdate in $T2B_TRIES attempts"; }
done
[ "$t2b_retried" = 0 ] || echo "  note: $t2b_retried discarded attempt(s) — harness backdate race, not a protocol verdict"
[ "$t2b_fail" = 0 ] && ok "$T2B_ROUNDS rounds x $T2B_N waiters on one crashed lock: all ran, clean final state, no move-aside file ever existed" \
  || bad "crash-recovery contention failure (see above)"
[ "$t2b_98" = 0 ] && ok "zero spurious 98s — the claim serialized recovery (unserialized: near-certain displacement)" \
  || bad "$t2b_98 waiter(s) exited 98 — displacement happened under the claim protocol"
[ "$t2b_stole" = "$T2B_ROUNDS" ] && ok "exactly one STOLE-BY-CLAIM per recovery (x$t2b_stole/$T2B_ROUNDS rounds)" \
  || bad "STOLE-BY-CLAIM count $t2b_stole != $T2B_ROUNDS rounds (want exactly one steal per recovery)"
[ "$t2b_old_shape" = 0 ] && ok "unserialized-steal line shape ('STOLE stale lock') never logged" \
  || bad "'STOLE stale lock' line appeared x$t2b_old_shape — an unserialized steal lane is present"
[ "$t2b_disp" = 0 ] && ok "zero STEAL-DISPLACED lines (prevention, not detect-and-repair)" \
  || bad "STEAL-DISPLACED fired x$t2b_disp — displacement-repair machinery present?"

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
# its lock (Test 4c). Would fail if lock_release skipped the token check.
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
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 0'; rc=$?
[ "$rc" = 0 ] && ok "exit 0 propagated" || bad "exit 0 not propagated (rc=$rc)"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exit 7'; rc=$?
[ "$rc" = 7 ] && ok "exit 7 propagated" || bad "exit code not propagated (rc=$rc)"
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

echo "== Test 7: CLI usage errors exit 96 (stderr); explicit --help/-h exits 0 (stdout) =="
bash "$LIB" >/dev/null 2>&1;            [ "$?" = 96 ] && ok "no args -> 96" || bad "no args rc=$? (want 96)"
bash "$LIB" frobnicate > "$WORK/t7.err.out" 2> "$WORK/t7.err.err"
[ "$?" = 96 ] && ok "unknown subcommand -> 96" || bad "unknown subcommand rc=$? (want 96)"
grep -q '^usage:' "$WORK/t7.err.err" && [ ! -s "$WORK/t7.err.out" ] \
  && ok "usage-error text goes to stderr, stdout stays empty" \
  || bad "usage-error stream routing wrong (stdout: $(head -c 60 "$WORK/t7.err.out"))"
bash "$LIB" run >/dev/null 2>&1
[ "$?" = 96 ] && ok "run with no command -> 96" || bad "run with no command rc=$? (want 96)"
bash "$LIB" run -- >/dev/null 2>&1
[ "$?" = 96 ] && ok "run -- with no command -> 96" || bad "run -- rc=$? (want 96)"
# Explicit help is an answered question, not a usage error: usage on
# STDOUT, exit 0, nothing on stderr.
for h in --help -h; do
  bash "$LIB" "$h" > "$WORK/t7.help.out" 2> "$WORK/t7.help.err"; rc=$?
  [ "$rc" = 0 ] && grep -q '^usage:' "$WORK/t7.help.out" && [ ! -s "$WORK/t7.help.err" ] \
    && ok "$h -> usage on stdout, exit 0, stderr empty" \
    || bad "$h rc=$rc (want 0) stdout-usage=$(grep -c '^usage:' "$WORK/t7.help.out") stderr=$(head -c 60 "$WORK/t7.help.err")"
done

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
# The warning is the knob-RELATION form (MAX_WAIT <= STALE + CLAIM_STALE),
# which strictly subsumes a bare STALE >= MAX_WAIT check: a setting the bare
# check would ignore must still warn — STALE=300 alone is fine (< 420), but
# CLAIM_STALE=200 pushes worst-case recovery to 500 >= the default 420.
AGENT_LOCK_PATH="$WORK/warn2.lock" AGENT_LOCK_LOG="$LOG" \
  AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_CLAIM_STALE_SECS=200 \
  bash "$LIB" run -- true 2> "$WORK/t8.warn2.err"
grep -q "raise AGENT_LOCK_MAX_WAIT" "$WORK/t8.warn2.err" \
  && ok "knob-relation warning stacks STALE + CLAIM_STALE (a bare STALE-only rule would stay silent here)" \
  || bad "no warning when STALE + CLAIM_STALE >= default MAX_WAIT — the knob-relation rule is missing"
AGENT_LOCK_PATH="$WORK/warn3.lock" AGENT_LOCK_LOG="$LOG" \
  AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_CLAIM_STALE_SECS=200 AGENT_LOCK_MAX_WAIT=400 \
  bash "$LIB" run -- true 2> "$WORK/t8.warn3.err"
grep -q "raise AGENT_LOCK_MAX_WAIT" "$WORK/t8.warn3.err" \
  && bad "knob-relation warning fired though MAX_WAIT was set explicitly" \
  || ok "explicit MAX_WAIT silences the knob-relation warning (left-default gate kept)"
wait "$h8"; rc=$?
[ "$rc" = 0 ] && ok "holder unaffected by the timed-out waiter" || bad "holder rc=$rc (want 0)"

echo "== Test 9: sub-floor (pre-2000) file mtime is NOT treated as stale =="
# The FILETIME-zero guard: a freshly created file can transiently report a 1601
# mtime to an observer on Windows (probes C/C1b);
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
# Two discriminators: (a) the EXIT/TERM trap must actually
# release the lock when the `run` wrapper is killed; (b) the wrapper must NOT
# swallow the signal (a swallowing wrapper releases, keeps going, and exits 0
# — invisible to any watchdog). The re-raise pattern makes it exit 143. NB bash defers the
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
# NB: run the SUITE in the foreground (or under `bash -m`). A suite launched as
# a background job from a non-job-control shell inherits SIGINT-ignored, which
# bash reports as `trap -- '' SIGINT` — this assertion then flags it as a
# leftover lock trap (false failure; observed 2026-06-12, harness-induced).
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

# 12e: the shell must respond to TERM normally after release (an
# implementation that leaves the lock's handler armed survives TERM, rc 0).
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
# was left armed survives EVERY TERM (the leftover handler
# releases-and-continues) and still exits 0 after its sleep.
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
  AGENT_LOCK_CLAIM_STALE_SECS=2.5 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t13.err"; rc=$?
[ "$rc" = 0 ] && ok "run succeeds despite garbage numeric config" || bad "rc=$rc with garbage numerics"
n="$(grep -c "ignoring invalid" "$WORK/t13.err")"
[ "$n" = 4 ] && ok "all 4 garbage values noted on stderr, incl. CLAIM_STALE_SECS (got $n)" || bad "expected 4 'ignoring invalid' notes, got $n"

echo "== Test 14: run outside any git repo hard-fails 96 unless AGENT_LOCK_PATH is set =="
NR="$WORK/norepo"; mkdir -p "$NR"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" bash "$LIB" run -- bash -c 'true' ) 2> "$WORK/t14.err"; rc=$?
[ "$rc" = 96 ] && ok "run outside a repo refused with 96" || bad "run outside a repo rc=$rc (want 96)"
grep -q "AGENT_LOCK_PATH" "$WORK/t14.err" && ok "refusal message mentions AGENT_LOCK_PATH" || bad "unhelpful refusal message"
( cd "$NR" && env GIT_CEILING_DIRECTORIES="$WORK" AGENT_LOCK_PATH="$NR/x.lock" AGENT_LOCK_LOG="$NR/x.log" \
    bash "$LIB" run -- bash -c 'true' ) 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "explicit AGENT_LOCK_PATH works outside a repo" || bad "explicit AGENT_LOCK_PATH outside repo rc=$rc"

echo "== Test 14b: SOURCING outside a repo warns on stderr and creates NO files =="
# Sourcing keeps the CWD fallback (it must never explode), but the warning
# goes to STDERR — warning via the lock log instead would, as a side
# effect, CREATE ./git-commit-lock.log in whatever random directory the
# caller was in (ps1's dot-source lane warns on stderr; parity).
NRS="$WORK/norepo-src"
mkdir -p "$NRS"
(cd "$NRS" && env GIT_CEILING_DIRECTORIES="$WORK" bash -c 'source "$1"' _ "$LIB") 2>"$WORK/t14b.err"
rc=$?
[ "$rc" = 0 ] && ok "sourcing outside a repo succeeds (rc 0)" || bad "sourcing outside a repo rc=$rc (want 0)"
grep -q "not inside a git repository" "$WORK/t14b.err" \
  && ok "CWD-fallback warning lands on stderr" \
  || bad "no CWD-fallback warning on stderr ($(head -c 80 "$WORK/t14b.err"))"
leftovers="$(ls -A "$NRS" 2>/dev/null)"
[ -z "$leftovers" ] && ok "sourcing left the CWD clean (no log or lock file created)" \
                    || bad "sourcing outside a repo created files in the CWD: $leftovers"

# (There is deliberately no Test 15: the steal installs by rename-over and
# never creates a move-aside (.dead.*) file, so there is no sweep to test.
# An implementation must never create one; Test 2b's sampler enforces that.)

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
# Acquire's read-back proved our
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

echo "== Test 16c: release rides out a TRANSIENT empty read (escalating retry ladder — ps1 parity) =="
# A sub-second window in which the lock file reads EMPTY (stand-in for an AV
# scanner's blocking handle, or a probe-F create->write gap that resolves)
# must NOT produce the unverifiable verdict: the read-retry ladder (shared
# 20..320ms escalating schedule, ~1.26s budget — see _lock_cur_token) keeps
# re-reading until the token reappears, then releases cleanly. A shorter
# ladder (say 5x20ms, ~0.1s) would return rc 2 on the same 0.4s transient
# that ps1 rides out — observably different verdicts from one on-disk
# event, which is why the schedule is pinned across the two impls.
# Deterministic: the holder itself truncates its lock file and a
# background helper restores the original content 0.4s later, squarely
# inside the ladder's budget (attempt 6 lands at ~0.62s) and far past any
# shorter one.
LOCK="$WORK/transient.lock"
LOG="$WORK/transient.log"
: >"$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  content="$(cat "$2")" || exit 73        # token + owner lines
  : > "$2"                                # transient: the token vanishes...
  ( sleep 0.4; printf "%s\n" "$content" > "$2" ) &   # ...and reappears
  lock_release; rc=$?
  wait
  exit "$rc"
' _ "$LIB" "$LOCK" 2> "$WORK/t16c.err"; rc=$?
[ "$rc" = 0 ] && ok "release rode out a 0.4s empty transient (rc 0, not unverifiable-2)" \
              || bad "transient-empty release rc=$rc (want 0 — read-retry ladder too short?)"
[ -e "$LOCK" ] && bad "lock file left behind after riding out the transient" \
               || ok "lock file removed after riding out the transient"
grep -q "EMPTY/unreadable at release" "$WORK/t16c.err" \
  && bad "spurious unverifiable warning despite the token reappearing" \
  || ok "no unverifiable warning for the ridden-out transient"

echo "== Test 17: NON-FILE at the lock path — never stolen, loud one-time config warning, waiters reach 97 =="
# (a) a directory (a config typo like AGENT_LOCK_PATH=\$HOME, or a directory
# lock left by an older release). The per-poll type guard fires regardless of
# age — but only after the SAME concrete type is seen on two consecutive
# polls (the anti-ghost confirmation), so these tests need
# MAX_WAIT/POLL to give at least three polls of headroom EVEN UNDER LOAD —
# a loaded box can spend ~0.5s per iteration, so MAX_WAIT=1 once flaked with
# zero guard evaluations completing (0.1s polls in a
# 3s wait = ~30 nominal here).
LOCK="$WORK/nonfile.lock"; LOG="$WORK/nonfile.log"; : > "$LOG"
mkdir -p "$LOCK/sub"; echo data > "$LOCK/sub/file"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17a.err"; rc=$?
[ "$rc" = 97 ] && ok "directory at lock path: waiter timed out (97), command never ran" \
               || bad "directory at lock path: rc=$rc (want 97)"
[ -f "$LOCK/sub/file" ] && ok "directory and its contents untouched (never stolen/deleted)" \
                        || bad "directory at lock path was damaged!"
grep -q "is not a lock file" "$WORK/t17a.err" && ok "loud config warning on stderr" || bad "no config warning for dir at lock path"
grep -q "it is a directory" "$WORK/t17a.err" && ok "warning names the detected type (directory)" || bad "warning does not name the directory type"
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
    AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
    bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17b.err"; rc=$?
  [ "$rc" = 97 ] && ok "dangling symlink at lock path: waiter timed out (97)" \
                 || bad "dangling symlink: rc=$rc (want 97)"
  [ -L "$LOCK" ] && ok "symlink untouched" || bad "symlink was removed/replaced"
  grep -q "is not a lock file" "$WORK/t17b.err" && ok "config warning names the symlink case" \
                                                || bad "no config warning for symlink at lock path"
  grep -q "it is a symlink" "$WORK/t17b.err" && ok "warning names the detected type (symlink)" || bad "warning does not name the symlink type"
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
    AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
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
    grep -q "it is a FIFO" "$WORK/t17c.err" && ok "warning names the detected type (FIFO)" || bad "warning does not name the FIFO type"
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
# reports existence, for up to ~ms) — makes a normal contended poll look
# wrong-type: an unguarded implementation fires the loud config warning as
# a false alarm under plain contention. The ghost defeats an immediate
# re-probe, which is why the guard classifies CONCRETE wrong types only —
# and because a ghost can transiently match one of the concrete stats
# (observed on windows-2025, CI run 27325971668), it additionally requires
# the SAME type on two consecutive polls before warning. A single-process churner
# create/deletes the lock file rapidly (the
# absent window is one back-to-back delete->create gap, far too narrow for
# a waiter to slip its create into) while 3 rounds x 4 parallel short
# waiters poll through thousands of unlink transitions. ANY non-lock warning
# fails; the waiters must still time out at 97 (the churned file always
# reads as a fresh live lock at STALE=300 — never stealable, never held).
# Churner: pwsh on Windows (fork-free tight loop; an unhardened guard
# reproduces warnings in 5/5 probe reps of this shape); perl elsewhere
# (fork-free with fast POSIX syscalls; a 2ms present-hold keeps the file
# present-dominant). Reaped by its exact PID only, via a stop marker.
LOCK="$WORK/churn.lock"; LOG="$WORK/churn.log"; : > "$LOG"
STOP="$WORK/churn.stop"; START="$WORK/churn.start"; rm -f "$STOP" "$START"
churn_pid=""; churn_skip=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v pwsh >/dev/null 2>&1; then
      LOCKW="$(cygpath -m "$LOCK" 2>/dev/null || echo "$LOCK")"
      STOPW="$(cygpath -m "$STOP" 2>/dev/null || echo "$STOP")"
      STARTW="$(cygpath -m "$START" 2>/dev/null || echo "$START")"
      pwsh -NoProfile -Command "
        [IO.File]::WriteAllText('$STARTW', 'x')
        for (\$i = 1; \$i -le 2000000; \$i++) {
          try { [IO.File]::WriteAllText('$LOCKW', \"tok.churn.1.1\`npid=1 host=churn\`n\") } catch { }
          if ((\$i % 256) -eq 0 -and (Test-Path -LiteralPath '$STOPW')) { break }
          try { [IO.File]::Delete('$LOCKW') } catch { }
        }
      " > "$WORK/t17d.churner.err" 2>&1 &
      churn_pid=$!
    else
      churn_skip="pwsh not on PATH (Windows churner)"
    fi
    ;;
  *)
    if command -v perl >/dev/null 2>&1; then
      perl -e '
        my ($lock, $stop, $start) = @ARGV;
        if (open(my $sf, ">", $start)) { print $sf "x"; close $sf; }
        for (my $i = 1; $i <= 2000000; $i++) {
          if (open(my $fh, ">", $lock)) { print $fh "tok.churn.1.1\npid=1 host=churn\n"; close $fh; }
          last if (($i % 256) == 0 && -e $stop);
          select(undef, undef, undef, 0.002);
          unlink $lock;
        }
      ' "$LOCK" "$STOP" "$START" &
      churn_pid=$!
    else
      churn_skip="perl not available (POSIX churner)"
    fi
    ;;
esac
if [ -n "$churn_pid" ]; then
  # Readiness gate = the STATIC start marker, never the churned lock path:
  # on Windows a rapidly rewritten file can sit in DELETE-PENDING (e.g. an
  # AV scan handle) where Cygwin stat reports ENOENT even though the .NET
  # side sees it existing — observed 2026-06-11: bash polled [ -e ] for 60s
  # straight while pwsh Test-Path said True. The marker is written once and
  # never churned, so bash sees it reliably. Budget 60s: pwsh cold start on
  # a loaded box can take >15s.
  if wait_for_file "$START" 60; then
    # Per-waiter lock logs (single-writer => drop-free): a SHARED log drops lines
    # under concurrent appends (cf. the per-waiter logs at Test 2B), which would make
    # the WAITING anti-vacuity count below unreliable. Rebuilt into $LOG after the runs.
    warn17d=0; n0=0; n1=0; n97=0; n98=0; nother=0; rc_bad=""
    for r in 1 2 3; do
      pids=()
      for i in 1 2 3 4; do
        AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/t17d.$r.$i.log" AGENT_LOCK_STALE_SECS=300 \
          AGENT_LOCK_POLL_SECS=0.02 AGENT_LOCK_MAX_WAIT=2 \
          bash "$LIB" run -- bash -c 'true' 2> "$WORK/t17d.$r.$i.err" &
        pids+=($!)
      done
      for i in 1 2 3 4; do
        wait "${pids[$((i-1))]}"; rc=$?
        # A CLEAN command ('true') under this churn has exactly FOUR correct terminal
        # codes — do NOT tighten this set: rc 1 is the real catch that made the old
        # got97>=1 assertion flaky (see the Test 17d de-flake plan).
        #   0  acquired in an absent window, clean release
        #   1  acquired, but release read the held lock EMPTY (the churner's
        #      create->write window) -> release rc 2 -> lock_run demotes the clean
        #      command to 1 (ownership unverifiable; correct, not a defect)
        #   97 never won an absent window within MAX_WAIT -> timed out
        #   98 churner overwrote the hold before release -> designed theft detection
        case "$rc" in
          0)  n0=$((n0+1)) ;;
          1)  n1=$((n1+1)) ;;
          97) n97=$((n97+1)) ;;
          98) n98=$((n98+1)) ;;
          *)  nother=$((nother+1)); rc_bad="$rc_bad $r.$i=$rc" ;;
        esac
        n="$(grep -c 'is not a lock file' "$WORK/t17d.$r.$i.err")"
        warn17d=$((warn17d+n))
      done
    done
    # Rebuild the consolidated churn.log artifact from the drop-free per-waiter logs.
    # 'cat glob > file' is a redirect, not a pipe (no SC2002); then count WAITING from
    # the single rebuilt file.
    cat "$WORK"/t17d.*.log > "$LOG" 2>/dev/null || :
    waited="$(grep -c 'WAITING for lock' "$LOG")"
    echo "note: T17d outcomes rc0=$n0 rc1=$n1 rc97=$n97 rc98=$n98 other=$nother; WAITING=$waited"
    [ "$warn17d" = 0 ] && ok "12 waiters polled through churn with ZERO spurious non-lock warnings" \
                       || bad "churned regular file fired $warn17d non-lock warning(s) — per-poll guard TOCTOU regression!"
    # Replaces the old got97>=1 assertion (timeout is only ONE of the correct outcomes;
    # which one occurs is machine-speed luck). Assert each waiter reached a DESIGNED
    # terminal state instead — catches a real product regression (crash/139, 96, …).
    [ "$nother" = 0 ] && ok "all 12 waiters reached a designed terminal state (rc in {0,1,97,98})" \
                      || bad "waiter(s) hit an undesigned rc under churn:$rc_bad (rc0=$n0 rc1=$n1 rc97=$n97 rc98=$n98)"
    # Anti-vacuity: WAITING is logged only after a create was blocked by a PRESENT lock,
    # immediately before the per-poll type guard that warn17d guards — so >=1 proves the
    # churn produced real contention and the guarded path ran. 0 => dead/absent churner.
    [ "$waited" -ge 1 ] && ok "churn exercised the blocked-poll type-guard lane ($waited WAITING line(s))" \
                        || bad "no WAITING logged under churn — contention never happened; test ran vacuously"
  else
    bad "T17d churner never signalled its start marker"
    echo "  diag: churner pid=$churn_pid alive=$(kill -0 "$churn_pid" 2>/dev/null && echo yes || echo no)"
    [ -s "$WORK/t17d.churner.err" ] && sed 's/^/  churner: /' "$WORK/t17d.churner.err" | head -5
  fi
  # Reap the churner deterministically: stop marker, bounded wait on ITS
  # exact pid, hard-kill of that same pid as a last resort (never by name).
  touch "$STOP"
  reaped=0
  for _ in $(seq 1 100); do kill -0 "$churn_pid" 2>/dev/null || { reaped=1; break; }; sleep 0.05; done
  [ "$reaped" = 1 ] || kill -9 "$churn_pid" 2>/dev/null
  wait "$churn_pid" 2>/dev/null
  rm -f "$LOCK" "$STOP" "$START"
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

echo "== Test 20: claim contention — N concurrent stealers, ONE claim winner ($GCL_MODE: $T20_N workers) =="
# N stealers race one ancient ghost: exactly one wins the O_EXCL claim and
# steals (one STOLE-BY-CLAIM); the rest lose the claim create and acquire
# normally in sequence after the winner releases. No displacement (zero
# LOST/98), no leftovers. STALE=5 keeps a loaded box from re-stealing the
# winner's brief hold.
LOCK="$WORK/contend.lock"
fabricate_lock "$LOCK" "tok.ghost.t20" "pid=888 host=ghost"
backdate "$LOCK" 9999
pids=(); t20_fail=0
for i in $(seq 1 "$T20_N"); do
  : > "$WORK/contend.$i.log"
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/contend.$i.log" AGENT_LOCK_STALE_SECS=5 \
    AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    bash "$LIB" run -- bash -c 'true' 2>/dev/null &
  pids+=($!)
done
for i in $(seq 1 "$T20_N"); do
  wait "${pids[$((i-1))]}"; rc=$?
  [ "$rc" = 0 ] || { t20_fail=1; echo "  worker $i rc=$rc (want 0)"; }
done
cat "$WORK/contend."*.log > "$WORK/contend.all.log"
nst="$(grep -c "STOLE-BY-CLAIM" "$WORK/contend.all.log")"
nacq="$(grep -c "ACQUIRED" "$WORK/contend.all.log")"
nrel="$(grep -c "RELEASED" "$WORK/contend.all.log")"
nlost="$(grep -c "lock LOST" "$WORK/contend.all.log")"
[ "$t20_fail" = 0 ] && ok "$T20_N concurrent stealers all completed with rc 0" || bad "claim-contention worker failures (see above)"
[ "$nst" = 1 ] && ok "exactly ONE claim winner stole the ghost (STOLE-BY-CLAIM x$nst)" \
               || bad "STOLE-BY-CLAIM x$nst (want exactly 1 — the claim must serialize stealers)"
[ "$nacq" = "$T20_N" ] && [ "$nrel" = "$T20_N" ] && ok "balanced ACQUIRED/RELEASED ($nacq/$nrel of $T20_N)" \
                                                  || bad "ACQUIRED=$nacq RELEASED=$nrel (want $T20_N each)"
[ "$nlost" = 0 ] && ok "zero LOST warnings under claim contention" || bad "$nlost LOST warnings under claim contention"
[ -e "$LOCK" ] && bad "leftover lock after contention" || ok "no leftover lock"
[ -e "$LOCK.next" ] && bad "leftover claim after contention" || ok "no leftover claim"

echo "== Test 21: crashed-claimant and empty-claim orphans age out; steals resume =="
# (a) an aged foreign claim (crashed claimant): cleared by CLAIM-STALE-CLEARED,
# then the steal completes; recovery latency bounded.
LOCK="$WORK/cc.lock"; LOG="$WORK/cc.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t21" "pid=9 host=ghost"; backdate "$LOCK" 9999
fabricate_lock "$LOCK.next" "tok.crashed.t21" "pid=8 host=crashed"; backdate "$LOCK.next" 9999
t21_t0=$(date +%s)
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
t21_t1=$(date +%s)
[ "$rc" = 0 ] && ok "waiter recovered through a crashed claimant's claim (rc 0)" || bad "rc=$rc behind a crashed claim"
grep -q "CLAIM-STALE-CLEARED" "$LOG" && ok "aged claim cleared (CLAIM-STALE-CLEARED logged, with age)" || bad "no CLAIM-STALE-CLEARED entry"
grep -q "STOLE-BY-CLAIM" "$LOG" && ok "steal completed after the clear" || bad "no STOLE-BY-CLAIM after clearing the crashed claim"
[ $((t21_t1 - t21_t0)) -le 20 ] && ok_envelope "recovery latency bounded ($((t21_t1 - t21_t0))s)" || bad_envelope "recovery took $((t21_t1 - t21_t0))s (>20s)"
[ -e "$LOCK.next" ] && bad "claim leftover after recovery" || ok "claim path clean after recovery"
# (b) an EMPTY claim file (claimant died between create and write): same lane.
LOCK="$WORK/ccempty.lock"; LOG="$WORK/ccempty.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t21b" "pid=9 host=ghost"; backdate "$LOCK" 9999
: > "$LOCK.next"; backdate "$LOCK.next" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "empty claim orphan aged out and recovery completed (rc 0)" || bad "rc=$rc behind an empty claim orphan"
grep -q "CLAIM-STALE-CLEARED" "$LOG" && ok "empty claim cleared via the same staleness lane" || bad "empty claim was not cleared"

echo "== Test 22: NON-CLAIM objects at the claim path — never deleted, per-path warn state =="
# (a) a directory at ${LOCK}.next blocks steals (waiter reaches 97), is never
# deleted, and warns once naming the claim path.
LOCK="$WORK/cwt.lock"; LOG="$WORK/cwt.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t22" "pid=9 host=ghost"; backdate "$LOCK" 9999
mkdir -p "$LOCK.next/sub"; echo keep > "$LOCK.next/sub/f"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t22a.err"; rc=$?
[ "$rc" = 97 ] && ok "dir at claim path: steals blocked, waiter timed out (97)" || bad "dir at claim path: rc=$rc (want 97)"
[ -f "$LOCK.next/sub/f" ] && ok "directory at claim path untouched" || bad "directory at claim path was damaged!"
n="$(grep -c "is not a claim file" "$WORK/t22a.err")"
# "warning fired at all" is timing-dependent (the two-poll confirmation needs poll
# headroom before MAX_WAIT, which an oversubscribed runner can starve) -> envelope.
# The warn-once dedup (never >1) and the type-naming are CORRECTNESS -> strict (the
# latter only asserted when a warning actually fired).
[ "$n" -ge 1 ] && ok_envelope "claim-path config warning fired (got $n)" || bad_envelope "no claim-path config warning (n=$n)"
[ "$n" -le 1 ] && ok "claim-path warning not duplicated (n=$n)" || bad "claim-path warning fired $n times (warn-once broken)"
if [ "$n" -ge 1 ]; then
  grep -q "it is a directory" "$WORK/t22a.err" && ok "claim warning names the detected type (directory)" || bad "claim warning does not name the type"
fi
grep -q "STOLE-BY-CLAIM" "$LOG" && bad "stole despite a squatted claim path" || ok "no steal through a squatted claim path"
[ -f "$LOCK" ] && ok "stale lock left in place (cannot be stolen safely)" || bad "lock vanished behind a squatted claim path"
# (b) a free LOCK path is UNaffected by claim-path junk: normal acquire works.
rm -f "$LOCK"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  bash "$LIB" run -- bash -c 'true' 2> "$WORK/t22b.err"; rc=$?
[ "$rc" = 0 ] && ok "normal acquisition on a free lock path unaffected by claim-path junk" \
              || bad "free-path acquire rc=$rc with a dir at the claim path (want 0)"
rm -rf "$LOCK.next"
# (c) a dangling SYMLINK at the claim path (where symlinks can be made).
LOCK="$WORK/cwts.lock"; LOG="$WORK/cwts.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t22c" "pid=9 host=ghost"; backdate "$LOCK" 9999
if env MSYS=winsymlinks:nativestrict ln -s "$WORK/no-such-target" "$LOCK.next" 2>/dev/null && [ -L "$LOCK.next" ]; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
    AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
    bash "$LIB" run -- bash -c 'true' 2> "$WORK/t22c.err"; rc=$?
  [ "$rc" = 97 ] && ok "symlink at claim path: steals blocked (97)" || bad "symlink at claim path: rc=$rc (want 97)"
  [ -L "$LOCK.next" ] && ok "claim-path symlink untouched" || bad "claim-path symlink was removed/replaced"
  grep -q "it is a symlink" "$WORK/t22c.err" && ok "claim warning names the symlink" || bad "claim warning does not name the symlink"
  rm -f "$LOCK.next"
else
  rm -f "$LOCK.next"
  echo "note: cannot create symlinks here — claim-path symlink guard not exercised (CI POSIX legs cover it)"
fi
rm -f "$LOCK"
# (d) a FIFO at the claim path — the reason the claim-path pre-create guard is
# MANDATORY: without it the claim's noclobber open would HANG. Bounded
# externally so a regression fails fast. (bash-only; see the ps1 POSIX note.)
LOCK="$WORK/cwtf.lock"; LOG="$WORK/cwtf.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t22d" "pid=9 host=ghost"; backdate "$LOCK" 9999
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$LOCK.next" 2>/dev/null && [ -p "$LOCK.next" ]; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
    AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
    bash "$LIB" run -- bash -c 'true' 2> "$WORK/t22d.err" &
  p22=$!
  hung=0
  for _ in $(seq 1 100); do kill -0 "$p22" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$p22" 2>/dev/null; then
    hung=1
    bad "FIFO at claim path HUNG the stealer — claim pre-create type guard missing"
    kill -9 "$p22" 2>/dev/null          # exact PID we spawned; nothing else
    ( : < "$LOCK.next" ) 2>/dev/null &  # pair a reader with the stuck writer-open
    wait "$p22" 2>/dev/null
  else
    wait "$p22"; rc=$?
    [ "$rc" = 97 ] && ok "FIFO at claim path: no hang, waiter timed out (97)" || bad "FIFO at claim path: rc=$rc (want 97)"
    grep -q "it is a FIFO" "$WORK/t22d.err" && ok "claim warning names the FIFO" || bad "no FIFO claim warning"
  fi
  [ "$hung" = 0 ] && { [ -p "$LOCK.next" ] && ok "claim-path FIFO untouched" || bad "claim-path FIFO was removed/replaced"; }
  rm -f "$LOCK.next" "$LOCK"
else
  rm -f "$LOCK.next" "$LOCK" 2>/dev/null
  echo "note: mkfifo unavailable/unusable here — claim-path FIFO guard not exercised (CI POSIX legs cover it)"
fi
# (e) PER-PATH warn-once independence: a lock-path wrong-type
# warning in the same process must NOT suppress a claim-path warning — and
# vice versa. One sourced shell, two sequential acquires per direction.
PPD="$WORK/ppg"; mkdir -p "$PPD"
mkdir -p "$PPD/ldir.lock"
fabricate_lock "$PPD/c2.lock" "tok.ghost.ppg" "pid=9 host=g"; backdate "$PPD/c2.lock" 9999
mkdir -p "$PPD/c2.lock.next"
AGENT_LOCK_PATH="$PPD/ldir.lock" AGENT_LOCK_LOG="$PPD/ppg.log" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  bash -c '
    source "$1" || exit 70
    lock_acquire; [ "$?" = 97 ] || exit 71      # dir at the LOCK path -> lock warning
    AGENT_LOCK_PATH="$2"
    lock_acquire; [ "$?" = 97 ] || exit 72      # dir at the CLAIM path -> claim warning
    exit 0
  ' _ "$LIB" "$PPD/c2.lock" 2> "$PPD/ab.err"; rc=$?
[ "$rc" = 0 ] || bad "T22e lock-then-claim harness rc=$rc"
grep -q "is not a lock file" "$PPD/ab.err" && grep -q "is not a claim file" "$PPD/ab.err" \
  && ok "lock-path warning did not suppress the claim-path warning (per-path warn-once)" \
  || bad "claim-path warning suppressed after a lock-path warning (shared warn-once state?)"
PPD2="$WORK/ppg2"; mkdir -p "$PPD2"
fabricate_lock "$PPD2/c1.lock" "tok.ghost.ppg2" "pid=9 host=g"; backdate "$PPD2/c1.lock" 9999
mkdir -p "$PPD2/c1.lock.next"
mkdir -p "$PPD2/ldir2.lock"
AGENT_LOCK_PATH="$PPD2/c1.lock" AGENT_LOCK_LOG="$PPD2/ppg2.log" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  bash -c '
    source "$1" || exit 70
    lock_acquire; [ "$?" = 97 ] || exit 71      # dir at the CLAIM path -> claim warning
    AGENT_LOCK_PATH="$2"
    lock_acquire; [ "$?" = 97 ] || exit 72      # dir at the LOCK path -> lock warning
    exit 0
  ' _ "$LIB" "$PPD2/ldir2.lock" 2> "$PPD2/ba.err"; rc=$?
[ "$rc" = 0 ] || bad "T22e claim-then-lock harness rc=$rc"
grep -q "is not a claim file" "$PPD2/ba.err" && grep -q "is not a lock file" "$PPD2/ba.err" \
  && ok "claim-path warning did not suppress the lock-path warning (reverse order)" \
  || bad "lock-path warning suppressed after a claim-path warning (shared warn-once state?)"

echo "== Test 23: live-slow holder — re-verify under the claim sees a fresh lock, CLAIM-ABORT (fresh), no steal =="
# Steered deterministically: the lock's mtime is renewed (as a live-slow
# holder's re-create/renewal would) at the exact step-2 re-verify position,
# via a sourced shell that wraps the library's verify internal. The claimant
# must abort (fresh), keep waiting, and acquire normally once the holder
# "releases" (the test removes the lock).
LOCK="$WORK/lsf.lock"; LOG="$WORK/lsf.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t23" "pid=9 host=slow"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=3 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_verify_stale _vs_orig
    F1=0
    _lock_verify_stale() {
      if [ "$F1" = 0 ]; then F1=1; command touch -- "$AGENT_LOCK_PATH"; fi
      _vs_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null &
w23=$!
wait_for_grep "CLAIM-ABORT (fresh)" "$LOG" 20 \
  && ok "claimant aborted on the renewed (fresh) lock — CLAIM-ABORT (fresh)" \
  || bad "no CLAIM-ABORT (fresh) for the live-slow holder"
rm -f "$LOCK"                       # the slow holder releases normally
wait "$w23"; rc=$?
[ "$rc" = 0 ] && ok "waiter then acquired and released normally (rc 0)" || bad "waiter rc=$rc after the slow holder released"
grep -q "STOLE-BY-CLAIM" "$LOG" && bad "live lock was STOLEN despite the fresh re-verify" || ok "no steal of the live-slow holder's lock"
[ -e "$LOCK.next" ] && bad "claim leftover after the fresh abort" || ok "claim deleted on the fresh abort"

echo "== Test 24: OVERAGED own claim — CLAIM-ABORT (contested), no rename =="
# A suspended claimant's recheck must refuse to proceed on its own overaged
# claim (a clearer may be acting on it). Steered: every recheck sees the
# claim backdated past CLAIM_STALE. Mutation check: an implementation that
# proceeds on an overaged claim would STOLE-BY-CLAIM and exit 0.
LOCK="$WORK/contested.lock"; LOG="$WORK/contested.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t24" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=4 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_claim_state _cs_orig
    _lock_claim_state() {
      backdate "$_LOCK_CLAIM_PATH" 10 2>/dev/null || true
      _cs_orig "$@"
    }
    lock_acquire
    exit $?
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "claimant kept aborting contested and timed out (97)" || bad "rc=$rc (want 97)"
grep -q "CLAIM-ABORT (contested)" "$LOG" && ok "CLAIM-ABORT (contested) logged" || bad "no contested abort logged"
grep -q "STOLE-BY-CLAIM" "$LOG" && bad "implementation proceeded to rename on an OVERAGED claim" || ok "no rename on an overaged claim"
l1=""; IFS= read -r l1 < "$LOCK" || true
[ "$l1" = "tok.ghost.t24" ] && ok "ghost lock untouched by the contested aborts" || bad "ghost lock was modified (line1=$l1)"
[ -e "$LOCK.next" ] && bad "claim leftover after contested aborts" || ok "claim deleted on each contested abort"
rm -f "$LOCK"

echo "== Test 25: discovery-position matrix — own-claim-installed discovered on EVERY exit =="
# A rival's rename can install OUR claim as the lock while we sit at any
# post-claim position. Each position steers that rename to the exact spot
# (wrapping a library internal or shadowing mv/rm/touch in a sourced shell)
# and asserts: the victim DISCOVERS ownership (HOLD), its release returns 0
# (per-attempt hold token — a per-acquire-token implementation fails this),
# and nothing is orphaned. The interleavings follow the
# steering (claimant A passes recheck; clearer clears; victim B claims; A's
# delayed rename installs B's claim).
MATRIX_INNER='
  pos="$2"
  source "$1" || exit 70
  rival_install() { command mv -f -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null; }
  F1=0; F2=0
  case "$pos" in
    step2-fresh)
      clone_fn _lock_verify_stale _vs_orig
      _lock_verify_stale() {
        if [ "$F1" = 0 ]; then F1=1; rival_install; fi
        _vs_orig "$@"
      } ;;
    recheck-gone)
      clone_fn _lock_claim_state _cs_orig
      _lock_claim_state() {
        if [ "$F1" = 0 ]; then F1=1; rival_install; fi
        _cs_orig "$@"
      } ;;
    touch-gone)
      touch() {
        case "$*" in *".next"*)
          if [ "$F1" = 0 ]; then F1=1; rival_install; fi ;;
        esac
        command touch "$@"
      } ;;
    lock-gone)
      clone_fn _lock_verify_stale _vs_orig
      _lock_verify_stale() {
        if [ "$F1" = 0 ]; then F1=1; command rm -f -- "$AGENT_LOCK_PATH"; fi
        _vs_orig "$@"
      }
      clone_fn _lock_claim_state _cs_orig
      _lock_claim_state() {
        if [ "$F2" = 0 ]; then F2=1; rival_install; fi
        _cs_orig "$@"
      } ;;
    contested)
      clone_fn _lock_claim_state _cs_orig
      _lock_claim_state() {
        if [ "$F1" = 0 ]; then F1=1; backdate "$_LOCK_CLAIM_PATH" 70
        elif [ "$F2" = 0 ]; then F2=1; rival_install; fi
        _cs_orig "$@"
      } ;;
    deletion-gone)
      clone_fn _lock_verify_stale _vs_orig
      _lock_verify_stale() {
        if [ "$F1" = 0 ]; then F1=1; command touch -- "$AGENT_LOCK_PATH"; fi
        _vs_orig "$@"
      }
      rm() {
        case "$*" in *".next"*)
          if [ "$F2" = 0 ]; then F2=1; rival_install; fi ;;
        esac
        command rm "$@"
      } ;;
    source-gone)
      mv() {
        case "$*" in *".next"*)
          if [ "$F1" = 0 ]; then F1=1; rival_install; fi ;;
        esac
        command mv "$@"
      } ;;
  esac
  lock_acquire || exit 72
  l1=""
  IFS= read -r l1 < "$AGENT_LOCK_PATH" 2>/dev/null || true
  [ "$l1" = "$_LOCK_TOKEN" ] || exit 73
  lock_release || exit 74
  exit 0
'
for pos in step2-fresh recheck-gone touch-gone lock-gone contested deletion-gone source-gone; do
  MD="$WORK/m25.$pos"; mkdir -p "$MD"
  LOCK="$MD/m.lock"; LOG="$MD/m.log"; : > "$LOG"
  fabricate_lock "$LOCK" "tok.ghost.m25" "pid=9 host=ghost"
  backdate "$LOCK" 9999
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=5 \
    AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
    bash -c "$MATRIX_INNER" _ "$LIB" "$pos" 2> "$MD/err"; rc=$?
  case "$pos" in
    step2-fresh|deletion-gone) expect="CLAIM-ABORT (fresh)" ;;
    recheck-gone)              expect="claim recheck: claim gone" ;;
    touch-gone)                expect="claim gone at touch" ;;
    lock-gone)                 expect="CLAIM-ABORT (gone)" ;;
    contested)                 expect="CLAIM-ABORT (contested)" ;;
    source-gone)               expect="claim (source) gone at rename" ;;
    *)                         expect="UNREACHABLE-position-$pos" ;;
  esac
  if [ "$rc" = 0 ] && grep -q "DISCOVERY-HOLD" "$LOG" && grep -qF "$expect" "$LOG" \
     && [ ! -e "$LOCK" ] && [ ! -e "$LOCK.next" ]; then
    ok "position $pos: exit '$expect' -> discovery-HOLD, release rc 0, no orphan"
  else
    bad "position $pos: rc=$rc discovery=$(grep -c DISCOVERY-HOLD "$LOG") expect-line=$(grep -cF "$expect" "$LOG") lock-left=$([ -e "$LOCK" ] && echo yes || echo no) claim-left=$([ -e "$LOCK.next" ] && echo yes || echo no)"
  fi
done

echo "== Test 26: delayed claim still installs a FRESH lease (the pre-rename touch) =="
# A claim aged close to CLAIM_STALE (steered: backdated 40s of 60 at the
# recheck) must still install a lock whose mtime is ~now — the step-3.2
# touch resets the clock; rename preserves it (probe R2). A no-touch
# implementation installs a 40s-old lease and fails the age bound.
LOCK="$WORK/lease.lock"; LOG="$WORK/lease.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t26" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_claim_state _cs_orig
    F1=0
    _lock_claim_state() {
      if [ "$F1" = 0 ]; then F1=1; backdate "$_LOCK_CLAIM_PATH" 40; fi
      _cs_orig "$@"
    }
    lock_acquire || exit 72
    mt="$(stat -c %Y "$AGENT_LOCK_PATH" 2>/dev/null || stat -f %m "$AGENT_LOCK_PATH" 2>/dev/null)"
    [ -n "$mt" ] || exit 73
    age=$(( $(date +%s) - mt ))
    [ "$age" -le 15 ] || exit 75
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
case "$rc" in
  0)  ok "installed lock mtime was fresh (full lease) despite the 40s-old claim" ;;
  75) bad "installed lock inherited the AGED claim mtime — pre-rename touch missing (lease defect)" ;;
  *)  bad "delayed-claim lease harness rc=$rc" ;;
esac
grep -q "STOLE-BY-CLAIM" "$LOG" && ok "the delayed claim still completed its steal" || bad "no STOLE-BY-CLAIM in the lease test"

echo "== Test 27: lock GONE at re-verify — CLAIM-ABORT (gone), NO rename onto the absent path =="
# A live-slow holder releasing under a claimant must route to the normal
# create race, never a rename onto the absent path. Mutation check: a
# renaming implementation would install the CLAIM token; the correct one
# acquires with a fresh CREATE token (the two must differ in the log).
LOCK="$WORK/gone.lock4a"; LOG="$WORK/gone4a.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t27" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_verify_stale _vs_orig
    F1=0
    _lock_verify_stale() {
      if [ "$F1" = 0 ]; then F1=1; command rm -f -- "$AGENT_LOCK_PATH"; fi
      _vs_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "claimant re-raced the create after the gone abort (rc 0)" || bad "abort-on-gone harness rc=$rc"
grep -q "CLAIM-ABORT (gone)" "$LOG" && ok "CLAIM-ABORT (gone) logged" || bad "no CLAIM-ABORT (gone)"
ctok="$(sed -n 's/.* CLAIM .* tok=\([^ ]*\) by .*/\1/p' "$LOG" | head -1)"
atok="$(sed -n 's/.*ACQUIRED (.*tok=\([^)]*\)).*/\1/p' "$LOG" | head -1)"
if [ -n "$ctok" ] && [ -n "$atok" ] && [ "$ctok" != "$atok" ]; then
  ok "acquired via a fresh CREATE token, not the claim's (claim=$ctok != acquired=$atok)"
else
  bad "claim token vs acquired token: claim='$ctok' acquired='$atok' (equal or missing => renamed onto the absent path?)"
fi
grep -q "DISCOVERY-HOLD" "$LOG" && bad "spurious discovery-HOLD in the gone lane" || ok "no spurious discovery-HOLD"

echo "== Test 28: SUB-FLOOR claim mtime is never cleared — treated as just-created =="
LOCK="$WORK/cfloor.lock"
LOG="$WORK/cfloor.log"
: >"$LOG"
fabricate_lock "$LOCK" "tok.ghost.t28" "pid=9 host=ghost"
backdate "$LOCK" 9999
fabricate_lock "$LOCK.next" "tok.subfloor.t28" "pid=8 host=old"
touch -t 197001120000 "$LOCK.next"          # epoch ~950400 — far below the floor
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=2 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "sub-floor claim: waiter timed out (97) instead of clearing" || bad "sub-floor claim: rc=$rc (want 97)"
grep -q "CLAIM-STALE-CLEARED" "$LOG" && bad "sub-floor claim was CLEARED — mtime floor missing on the claim path" \
                                     || ok "sub-floor claim never cleared (floor applies to the claim)"
[ -f "$LOCK.next" ] && ok "sub-floor claim file untouched" || bad "sub-floor claim file was removed"
rm -f "$LOCK" "$LOCK.next"

echo "== Test 29: BLOCKED steal rename — claim deleted IMMEDIATELY, no CLAIM_STALE penalty =="
# The rename is forced to fail-with-the-lock-still-present (a shadowed mv —
# the no-delete-share squat, deterministically). The claimant must delete its
# own claim at once and re-poll: with CLAIM_STALE=600, a leftover claim would
# block every later attempt (exactly one CLAIM line — which is what kills a
# leftover-claim implementation below); immediate deletion yields a fresh
# CLAIM line per attempt. MAX_WAIT=6 (not 3) is timing HEADROOM for the
# >=2-CLAIM-lines discriminator under machine load — at 0.2s polls a loaded
# box could otherwise fit only one attempt before the timeout (flakes
# under machine load); the discriminator is unaffected (a leftover claim blocks
# attempt 2 however long the window is).
LOCK="$WORK/blocked.lock"; LOG="$WORK/blocked.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t29" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=6 \
  bash -c '
    source "$1" || exit 70
    mv() { case "$*" in *".next"*) return 1;; esac; command mv "$@"; }
    lock_acquire
    exit $?
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "blocked-steal waiter honoured MAX_WAIT (97)" || bad "blocked-steal rc=$rc (want 97)"
nclaim="$(grep -c "] CLAIM " "$LOG")"
[ "$nclaim" -ge 2 ] && ok_envelope "claim re-created on later attempts (x$nclaim) — deleted immediately, no ageout penalty" \
                    || bad_envelope "only $nclaim CLAIM line(s) — the failed steal's claim was left to age out (60s-class penalty)"
grep -q "steal FAILED" "$LOG" && ok "blocked rename logged (damped steal FAILED)" || bad "no steal FAILED log line"
[ -e "$LOCK.next" ] && bad "claim leftover after the blocked steal attempts" || ok "no claim leftover at exit"
[ -f "$LOCK" ] && ok "squatted lock left in place" || bad "lock vanished in the blocked lane"
rm -f "$LOCK"

echo "== Test 30: static checks — the claim touch is NON-creating with an explicit existence check =="
grep -q 'touch -c -- "\$_LOCK_CLAIM_PATH"' "$LIB" \
  && ok "claim touch uses 'touch -c --' (non-creating)" \
  || bad "no 'touch -c -- \$_LOCK_CLAIM_PATH' in the implementation"
grep -A3 'touch -c -- "\$_LOCK_CLAIM_PATH"' "$LIB" | grep -q -- '-e "\$_LOCK_CLAIM_PATH"' \
  && ok "explicit existence check follows the touch (the exit code carries no gone signal)" \
  || bad "no explicit [ -e ] existence check after the claim touch"
bad_touch="$(grep 'touch ' "$LIB" | grep '_LOCK_CLAIM_PATH' | grep -v -- '-c')"
[ -z "$bad_touch" ] && ok "no creating touch of the claim path anywhere" \
                    || bad "creating touch of the claim path found: $bad_touch"

echo "== Test 31: LEAKED-claim discovery — the leaked-token memory closes the unverified-claim lanes =="
# (a) main leg: a recheck-unreadable exit leaks the claim token; a rival
# (the external mv below) then installs that claim as the lock; the leaver
# adopts it (HOLD) and release returns 0. Adoption may go through EITHER of
# the product's two discovery routes — both correct: the inline
# ownership-discovery read that is the unreadable branch's final act
# (git-commit-lock.sh:822, "DISCOVERY-HOLD: ...") if the external mv lands
# before it, or the per-poll leaked-token-memory check
# (git-commit-lock.sh:1382, "DISCOVERY-HOLD (leaked-token memory)") on a later
# poll if it lands after. Which wins is a pure scheduling race — the external
# mv vs the leaver's inline discover ONE statement later (sh:1112 leak-add ->
# sh:1114 discover) — and is load-sensitive, so this leg accepts either and
# records which fired. The memory route is pinned DETERMINISTICALLY by
# sub-leg (b) below; the direct route by Test 25's discovery-position matrix.
# NB: _lock_read_tok / _lock_cur_token shadows run inside COMMAND
# SUBSTITUTIONS (subshells), so their fire-once state must live in flag
# FILES — a variable assignment would be lost when the subshell exits.
T31A_INNER='
  source "$1" || exit 70
  clone_fn _lock_read_tok _rt_orig
  SF1="$AGENT_LOCK_PATH.steer1"
  _lock_read_tok() {
    if [ ! -e "$SF1" ] && [ "$1" = "$_LOCK_CLAIM_PATH" ]; then : > "$SF1"; printf ""; return 0; fi
    _rt_orig "$@"
  }
  lock_acquire || exit 72
  lock_release || exit 74
  exit 0
'
LOCK="$WORK/leak.lock"; LOG="$WORK/leak.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t31" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=60 \
  bash -c "$T31A_INNER" _ "$LIB" 2>/dev/null &
w31=$!
if wait_for_grep "LEAKED-CLAIM (recheck-unreadable)" "$LOG" 30; then
  ok "recheck-unreadable exit fed the leaked-token memory"
  mv -f -- "$LOCK.next" "$LOCK"            # the rival's rename installs the leaked claim
else
  bad "no LEAKED-CLAIM (recheck-unreadable) entry"
fi
wait "$w31"; rc=$?
[ "$rc" = 0 ] && ok "leaver discovered its installed leaked claim and released rc 0" || bad "leaked-discovery harness rc=$rc"
# Either discovery route is correct here (see the leg comment); accept both,
# record which fired, fail only if NEITHER adopted the leaked claim. ("$LOG"
# is dedicated to this leg, so there is no cross-talk.) "DISCOVERY-HOLD:"
# (immediate colon) matches ONLY the direct route; the memory route reads
# "DISCOVERY-HOLD (leaked-token memory):" — disjoint, and checked first.
if grep -q "DISCOVERY-HOLD (leaked-token memory)" "$LOG"; then
  ok "adoption went through the leaked-token memory (per-poll route; the mv landed after the inline discover)"
elif grep -q "DISCOVERY-HOLD:" "$LOG"; then
  ok "adoption went through the inline ownership-discovery read (direct route; the mv landed first) — memory route pinned by sub-leg (b)"
else
  bad "no DISCOVERY-HOLD adoption of the leaked claim by EITHER route"
fi
[ -e "$LOCK" ] && bad "lock leftover after leaked-claim adoption" || ok "lock released cleanly after adoption"
[ -e "$LOCK.next" ] && bad "claim leftover after leaked-claim adoption" || ok "no claim leftover"
# Hmm wait: STALE=300 — the ghost is backdated 9999 so it IS stale; fine.
# (b) steering variant: the rival install lands between the leaver's
# poll-read and its NEXT claim create, so the leaver runs one full ABORTING
# claim attempt before discovery (mutation check: an implementation that
# drops memory entries on a claim-attempt abort must fail — it would never
# adopt and would time out).
LOCK="$WORK/leakb.lock"; LOG="$WORK/leakb.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t31b" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=60 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_read_tok _rt_orig
    clone_fn _lock_new_token _nt_orig
    SF1="$AGENT_LOCK_PATH.steer1"      # flag FILES: subshell-safe fire-once state
    F2=0; NTC=0
    _lock_read_tok() {
      if [ ! -e "$SF1" ] && [ "$1" = "$_LOCK_CLAIM_PATH" ]; then : > "$SF1"; printf ""; return 0; fi
      _rt_orig "$@"
    }
    _lock_new_token() {
      if [ -e "$SF1" ] && [ "$F2" = 0 ]; then
        NTC=$((NTC+1))
        if [ "$NTC" = 2 ]; then F2=1; command mv -f -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null; fi
      fi
      _nt_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "memory survived an aborting claim attempt; adoption still happened (rc 0)" \
              || bad "steering-variant rc=$rc (memory dropped on claim-attempt abort?)"
lk_line="$(grep -n "LEAKED-CLAIM" "$LOG" | head -1 | cut -d: -f1)"
ab_line="$(grep -n "CLAIM-ABORT (fresh)" "$LOG" | head -1 | cut -d: -f1)"
dh_line="$(grep -n "DISCOVERY-HOLD (leaked-token memory)" "$LOG" | head -1 | cut -d: -f1)"
if [ -n "$lk_line" ] && [ -n "$ab_line" ] && [ -n "$dh_line" ] \
   && [ "$lk_line" -lt "$ab_line" ] && [ "$ab_line" -lt "$dh_line" ]; then
  ok "order proven: leak -> full aborting claim attempt -> memory adoption"
else
  bad "expected leak(line $lk_line) < abort(line $ab_line) < adoption(line $dh_line) ordering"
fi
# (c) crashed leaver: the leaver dies (SIGKILL) with the entry pending; a
# suspended rival installs the leaked claim -> a bounded unowned orphan that
# ages out; the log's CLAIM tok= line identifies the unowned lock's token
# (forensics).
LOCK="$WORK/leakc.lock"; LOG="$WORK/leakc.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t31c" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=60 \
  bash -c "$T31A_INNER" _ "$LIB" 2>/dev/null &
w31c=$!
if wait_for_grep "LEAKED-CLAIM (recheck-unreadable)" "$LOG" 30; then
  L31=""; IFS= read -r L31 < "$LOCK.next" || true
  kill -9 "$w31c" 2>/dev/null            # untrappable death; exact PID only
  wait "$w31c" 2>/dev/null
  mv -f -- "$LOCK.next" "$LOCK"          # the suspended rival installs the orphan
  grep -qF "tok=$L31 by" "$LOG" && ok "forensics: the unowned lock's token appears in a CLAIM line" \
                                || bad "unowned lock token $L31 not identifiable from CLAIM log lines"
  : > "$WORK/leakc.w2.log"
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/leakc.w2.log" AGENT_LOCK_STALE_SECS=2 \
    AGENT_LOCK_CLAIM_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
    bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
  [ "$rc" = 0 ] && ok "waiters recovered the unowned orphan at staleness (bounded residual-5 outcome)" \
                || bad "recovery rc=$rc behind the unowned orphan"
  grep -q "STOLE-BY-CLAIM" "$WORK/leakc.w2.log" && ok "orphan reclaimed by a normal staleness steal" \
                                                || bad "orphan not reclaimed via STOLE-BY-CLAIM"
else
  bad "crashed-leaver setup: no LEAKED-CLAIM entry"
  kill -9 "$w31c" 2>/dev/null; wait "$w31c" 2>/dev/null
fi
[ -e "$LOCK" ] && bad "lock leftover after crashed-leaver recovery" || ok "no lock leftover after crashed-leaver recovery"
# (d) the REAL deletion-unlink-blocked feeder + the arc-end resolution pass
# (Windows-only: needs a no-delete-share handle; on POSIX open handles never
# block unlink). The claimant pauses at its claim touch; a pwsh holder pins
# the claim (FileShare.Read); the lock is renewed so the claimant aborts
# (fresh) and its token-checked deletion BLOCKS -> leaked-blocked feeder.
# The handle then closes, the ghost is removed, the claimant acquires
# normally and its RELEASE's arc-end pass unlinks the leaked claim.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v pwsh >/dev/null 2>&1; then
      LOCK="$WORK/leakd.lock"; LOG="$WORK/leakd.log"; : > "$LOG"
      fabricate_lock "$LOCK" "tok.ghost.t31d" "pid=9 host=ghost"; backdate "$LOCK" 9999
      T31R="$WORK/t31d.ready"; T31G="$WORK/t31d.go"; rm -f "$T31R" "$T31G"
      T31R="$T31R" T31G="$T31G" \
      AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
        AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=120 \
        bash -c '
          source "$1" || exit 70
          F1=0
          touch() {
            case "$*" in *".next"*)
              if [ "$F1" = 0 ]; then
                F1=1
                command touch "$T31R"
                until [ -e "$T31G" ]; do sleep 0.05; done
              fi ;;
            esac
            command touch "$@"
          }
          lock_acquire || exit 72
          lock_release || exit 74
          exit 0
        ' _ "$LIB" 2>/dev/null &
      w31d=$!
      if wait_for_file "$T31R" 30; then
        CW="$(cygpath -m "$LOCK.next")"; HR="$WORK/t31d.hready"; HG="$WORK/t31d.hgo"; rm -f "$HR" "$HG"
        HRW="$(cygpath -m "$HR")"; HGW="$(cygpath -m "$HG")"
        pwsh -NoProfile -Command "
          \$fs = [System.IO.File]::Open('$CW', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
          [System.IO.File]::WriteAllText('$HRW', 'r')
          while (-not (Test-Path -LiteralPath '$HGW')) { Start-Sleep -Milliseconds 50 }
          \$fs.Dispose()
        " > "$WORK/t31d.pwsh.err" 2>&1 &
        h31d=$!
        if wait_for_file "$HR" 60; then
          touch -- "$LOCK"               # renew: forces the fresh abort -> blocked deletion
          touch "$T31G"
          if wait_for_grep "LEAKED-CLAIM (deletion-unlink-blocked-while-present)" "$LOG" 30; then
            ok "blocked claim unlink fed the leaked-token memory (deletion-unlink-blocked-while-present)"
          else
            bad "no deletion-unlink-blocked LEAKED-CLAIM entry"
          fi
          touch "$HG"                    # close the handle
          wait "$h31d"                   # pwsh exit = pin verifiably gone (process exit closes the
                                         # handle); a sleep-based slack here raced under CI load and
                                         # the arc-end unlink stayed blocked (run 27408940256)
          rm -f "$LOCK"                  # the 'slow holder' releases; claimant now acquires
          wait "$w31d"; rc=$?
          [ "$rc" = 0 ] && ok "leaver acquired normally after the leak (rc 0, leak pending into the hold)" \
                        || bad "T31d leaver rc=$rc"
          grep -q "claim unlinked at arc end" "$LOG" && ok "release's arc-end resolution pass unlinked the leaked claim" \
                                                     || bad "arc-end resolution pass did not resolve the leaked claim"
          [ -e "$LOCK.next" ] && bad "leaked claim left after the arc-end pass" || ok "no leaked claim leftover"
        else
          bad "T31d pwsh handle holder never signalled ready"
          touch "$T31G"; touch "$HG"; wait "$w31d" 2>/dev/null
          wait "$h31d" 2>/dev/null
        fi
      else
        bad "T31d claimant never reached its claim touch"
        kill -9 "$w31d" 2>/dev/null; wait "$w31d" 2>/dev/null
      fi
      rm -f "$LOCK" "$LOCK.next"
    else
      echo "note: pwsh not on PATH — the real blocked-unlink feeder leg not exercised here (Windows CI covers it)"
    fi
    ;;
  *)
    echo "note: the blocked-unlink feeder leg is Windows-only by construction (POSIX open handles never block unlink); the read-shadow legs above cover the memory machinery"
    ;;
esac

echo "== Test 32: per-attempt tokens — an abandoned own-token lock never aliases discovery or release =="
# Walk: the first CREATE's read-back is forced blank (and the abandoned lock
# backdated stale). A later CLAIM attempt is steered into a recheck-gone
# discovery against that abandoned lock: a reused-per-acquire-token
# implementation would see "its" token there and false-HOLD; per-attempt
# tokens make it a miss, and the claimant then steals normally and releases
# rc 0 against the WINNING attempt's token.
LOCK="$WORK/perattempt.lock"; LOG="$WORK/perattempt.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=5 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_cur_token _ct_orig
    clone_fn _lock_claim_state _cs_orig
    SF1="$AGENT_LOCK_PATH.steer1"      # flag FILE: the cur_token shadow runs in subshells
    F2=0
    _lock_cur_token() {
      if [ ! -e "$SF1" ] && [ "${_LOCK_HELD:-0}" = 0 ] && [ -z "$_LOCK_CLAIM_TOKEN" ]; then
        : > "$SF1"
        backdate "$AGENT_LOCK_PATH" 9999 2>/dev/null || true
        printf ""
        return 0
      fi
      _ct_orig "$@"
    }
    _lock_claim_state() {
      if [ "$F2" = 0 ]; then F2=1; command rm -f -- "$_LOCK_CLAIM_PATH"; fi
      _cs_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "abandon -> claim -> steal walk completed with release rc 0 (per-attempt hold token)" \
              || bad "per-attempt-token harness rc=$rc"
grep -q "acquire verification FAILED" "$LOG" && ok "the first create was abandoned (read-back forced blank)" \
                                             || bad "abandonment lane never ran"
grep -q "claim recheck: claim gone" "$LOG" && ok "the steered discovery against the abandoned lock ran" \
                                           || bad "recheck-gone discovery never ran"
grep -q "DISCOVERY-HOLD" "$LOG" && bad "FALSE discovery-HOLD on the abandoned own-token lock (token reuse!)" \
                                || ok "no false discovery-HOLD — the abandoned token did not alias the claim attempt"
grep -q "STOLE-BY-CLAIM" "$LOG" && ok "the abandoned lock was then reclaimed by a normal steal" \
                                || bad "no STOLE-BY-CLAIM of the abandoned lock"

echo "== Test 32b: steal-path read-back FAILED — rename-over WON but the lock did not read back our token (F2) =="
# The steal-path twin of Test 32. Here the stealer WINS the claim race AND wins
# the rename-over (STOLE-BY-CLAIM is logged, the ghost is destroyed), but the
# mandatory post-rename read-back verification (git-commit-lock.sh:1171) comes
# back wrong. The product must NOT take the hold: it clears its claim token and
# re-enters the wait loop (git-commit-lock.sh:1176-1179) — never a silent
# false-hold (which, after a STOLE-BY-CLAIM, would mean a mis-attributed hold of
# a destroyed-ghost path). We fault-inject the read-back with a one-shot
# _lock_cur_token shadow gated on the claim token being SET (the INVERSE of Test
# 32's `-z` gate), so it lands at the STEAL read-back (claim token live, not yet
# held), not the create one. On firing we also backdate the just-installed
# abandoned lock stale so the re-steal is immediate (same trick as Test 32 —
# keeps it fast and deterministic). Attempt 2 (shadow spent) reads back the real
# token and acquires normally.
LOCK="$WORK/stealrb.lock"; LOG="$WORK/stealrb.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t32b" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=5 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_cur_token _ct_orig
    SF1="$AGENT_LOCK_PATH.steer1"      # flag FILE: the cur_token shadow runs in subshells
    _lock_cur_token() {
      if [ ! -e "$SF1" ] && [ "${_LOCK_HELD:-0}" = 0 ] && [ -n "$_LOCK_CLAIM_TOKEN" ]; then
        : > "$SF1"
        backdate "$AGENT_LOCK_PATH" 9999 2>/dev/null || true
        printf ""
        return 0
      fi
      _ct_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "steal read-back failure re-entered wait; a later steal acquired and released rc 0" \
              || bad "steal-readback harness rc=$rc"
grep -q "steal rename completed but read-back" "$LOG" \
  && ok "the steal-path read-back-verification failure lane ran (F2)" \
  || bad "F2 lane never ran (the read-back fault did not land at the steal read-back)"
nstole="$(grep -c "STOLE-BY-CLAIM" "$LOG")"
[ "$nstole" -ge 2 ] && ok "re-stole after the failed read-back (STOLE-BY-CLAIM x$nstole)" \
                    || bad "expected >=2 STOLE-BY-CLAIM (won-rename then re-steal), got $nstole"
warn_line="$(grep -n "steal rename completed but read-back" "$LOG" | head -1 | cut -d: -f1)"
acq_line="$(grep -n "ACQUIRED " "$LOG" | tail -1 | cut -d: -f1)"
if [ -n "$warn_line" ] && [ -n "$acq_line" ] && [ "$warn_line" -lt "$acq_line" ]; then
  ok "no false-hold: the read-back WARNING preceded the eventual ACQUIRED"
else
  bad "ordering: expected the F2 WARNING (line $warn_line) before ACQUIRED (line $acq_line)"
fi
[ -e "$LOCK" ] && bad "lock leftover after the steal-readback walk" || ok "lock released cleanly"
[ -e "$LOCK.next" ] && bad "claim leftover after the steal-readback walk" || ok "no claim leftover"

echo "== Test 33: TERM mid-claim — the trap deletes the claim (token-checked), no 98, no ageout penalty =="
# (a) main: claimant paused inside its claim window (at the touch), TERM'd.
# The trap must delete OUR claim, run the discovery read (miss: the ghost is
# foreign), restore traps, re-raise (143) — and must NOT touch the lock.
T33_INNER='
  source "$1" || exit 70
  F1=0
  touch() {
    case "$*" in *".next"*)
      if [ "$F1" = 0 ]; then
        F1=1
        command touch "$T33R"
        until [ -e "$T33G" ]; do sleep 0.05; done
      fi ;;
    esac
    command touch "$@"
  }
  lock_acquire
  exit $?
'
LOCK="$WORK/termclaim.lock"; LOG="$WORK/termclaim.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t33" "pid=9 host=ghost"; backdate "$LOCK" 9999
T33R="$WORK/t33.ready"; T33G="$WORK/t33.go"; rm -f "$T33R" "$T33G"
T33R="$T33R" T33G="$T33G" \
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash -c "$T33_INNER" _ "$LIB" 2>/dev/null &
w33=$!
wait_for_file "$T33R" 30 || bad "T33a claimant never reached its claim touch"
# ONE TERM only: a second TERM can re-enter the
# handler mid-deletion and abandon the cleanup (the on-disk outcome is then
# the documented best-effort case, but it flakes the no-leftover
# discriminator below — observed once under load). A single TERM keeps the
# discriminator sharp: the trap MUST delete the claim.
kill -TERM "$w33" 2>/dev/null
touch "$T33G"
wait "$w33"; rc=$?
[ "$rc" = 143 ] && ok "TERM'd claimant re-raised and died 143" || bad "TERM'd claimant rc=$rc (want 143)"
[ -e "$LOCK.next" ] && bad "claim leftover after TERM (trap cleanup missing)" || ok "trap deleted the in-flight claim"
l1=""; IFS= read -r l1 < "$LOCK" || true
[ "$l1" = "tok.ghost.t33" ] && ok "the lock itself untouched by the trap (no release semantics on a mere claim)" \
                            || bad "lock modified by the dying claimant (line1=$l1)"
grep -q "lock LOST" "$LOG" && bad "98-classification ran on a mere claim" || ok "no 98 classification for the dying claimant"
# No ageout penalty: with CLAIM_STALE=600, a leftover claim would block this
# next stealer past its MAX_WAIT; immediate trap deletion lets it steal now.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
  bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "next stealer recovered immediately (no CLAIM_STALE penalty)" || bad "next stealer rc=$rc — ageout penalty paid"
# (b) FOREIGN-claim leg: a foreign claim planted before the TERM must
# SURVIVE the dying claimant's trap (kills a blind-unlink trap).
LOCK="$WORK/termforeign.lock"; LOG="$WORK/termforeign.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t33b" "pid=9 host=ghost"; backdate "$LOCK" 9999
rm -f "$T33R" "$T33G"
T33R="$T33R" T33G="$T33G" \
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash -c "$T33_INNER" _ "$LIB" 2>/dev/null &
w33b=$!
wait_for_file "$T33R" 30 || bad "T33b claimant never reached its claim touch"
rm -f "$LOCK.next"
fabricate_lock "$LOCK.next" "tok.foreign.t33" "pid=7 host=rival"   # a rival claimed meanwhile
kill -TERM "$w33b" 2>/dev/null
sleep 0.1
kill -TERM "$w33b" 2>/dev/null
touch "$T33G"
wait "$w33b"; rc=$?
[ "$rc" = 143 ] && ok "TERM'd claimant (foreign-claim leg) died 143" || bad "foreign-claim leg rc=$rc (want 143)"
l1=""; IFS= read -r l1 < "$LOCK.next" 2>/dev/null || true
[ "$l1" = "tok.foreign.t33" ] && ok "foreign claim SURVIVED the dying claimant's trap (token-checked deletion)" \
                              || bad "foreign claim deleted/damaged by the trap (line1='$l1') — blind unlink!"
rm -f "$LOCK" "$LOCK.next"
# (c) blocked-unlink variant (Windows-only): TERM lands while the claim's
# unlink is blocked by a no-delete-share handle — the trap's ONE bounded
# retry fails, the process exits LEAVING the claim (residual-5 class), and
# the next stealer recovers at CLAIM_STALE.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    if command -v pwsh >/dev/null 2>&1; then
      LOCK="$WORK/termblocked.lock"; LOG="$WORK/termblocked.log"; : > "$LOG"
      fabricate_lock "$LOCK" "tok.ghost.t33c" "pid=9 host=ghost"; backdate "$LOCK" 9999
      rm -f "$T33R" "$T33G"
      T33R="$T33R" T33G="$T33G" \
      AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
        AGENT_LOCK_CLAIM_STALE_SECS=4 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
        bash -c "$T33_INNER" _ "$LIB" 2>/dev/null &
      w33c=$!
      if wait_for_file "$T33R" 30; then
        CW="$(cygpath -m "$LOCK.next")"; HR="$WORK/t33c.hready"; HG="$WORK/t33c.hgo"; rm -f "$HR" "$HG"
        HRW="$(cygpath -m "$HR")"; HGW="$(cygpath -m "$HG")"
        pwsh -NoProfile -Command "
          \$fs = [System.IO.File]::Open('$CW', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
          [System.IO.File]::WriteAllText('$HRW', 'r')
          while (-not (Test-Path -LiteralPath '$HGW')) { Start-Sleep -Milliseconds 50 }
          \$fs.Dispose()
        " > "$WORK/t33c.pwsh.err" 2>&1 &
        h33c=$!
        if wait_for_file "$HR" 60; then
          kill -TERM "$w33c" 2>/dev/null
          sleep 0.1
          kill -TERM "$w33c" 2>/dev/null
          touch "$T33G"
          wait "$w33c"; rc=$?
          [ "$rc" = 143 ] && ok "TERM'd claimant exited 143 despite the blocked unlink" || bad "blocked-unlink TERM rc=$rc (want 143)"
          [ -e "$LOCK.next" ] && ok "claim LEFT behind (bounded residual-5 behavior — no machinery pretends otherwise)" \
                              || bad "claim gone despite the no-delete-share handle?"
          touch "$HG"; wait "$h33c" 2>/dev/null
          AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
            AGENT_LOCK_CLAIM_STALE_SECS=4 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=30 \
            bash "$LIB" run -- bash -c 'true' 2>/dev/null; rc=$?
          [ "$rc" = 0 ] && grep -q "CLAIM-STALE-CLEARED" "$LOG" \
            && ok "next stealer recovered at CLAIM_STALE (cleared the orphaned claim)" \
            || bad "recovery after the blocked-unlink TERM failed (rc=$rc)"
        else
          bad "T33c pwsh handle holder never signalled ready"
          touch "$T33G"; kill -TERM "$w33c" 2>/dev/null; wait "$w33c" 2>/dev/null
          touch "$HG"; wait "$h33c" 2>/dev/null
        fi
      else
        bad "T33c claimant never reached its claim touch"
        kill -9 "$w33c" 2>/dev/null; wait "$w33c" 2>/dev/null
      fi
      rm -f "$LOCK" "$LOCK.next"
    else
      echo "note: pwsh not on PATH — TERM-blocked-unlink leg not exercised here (Windows CI covers it)"
    fi
    ;;
  *)
    echo "note: TERM-blocked-unlink leg is Windows-only by construction (POSIX open handles never block unlink)"
    ;;
esac

echo "== Test 34: TERM on a STEAL-acquired hold releases exactly like a create-acquired one =="
# All acquisition paths go through the shared claim-the-hold helper, so a
# steal-acquired holder must run the same HELD/trap machinery: release on
# TERM, re-raise, 143 (T11's contract, on a steal-acquired hold).
LOCK="$WORK/stealterm.lock"; LOG="$WORK/stealterm.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t34" "pid=9 host=ghost"; backdate "$LOCK" 9999
READY="$WORK/t34.ready"; GO34="$WORK/t34.go"; rm -f "$READY" "$GO34"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$LIB" run -- bash -c 'touch "$1"; until [ -e "$2" ]; do sleep 0.05; done' _ "$READY" "$GO34" 2>/dev/null &
w34=$!
wait_for_file "$READY" 30 || bad "T34 steal-holder never signalled ready"
grep -q "STOLE-BY-CLAIM" "$LOG" && ok "the hold under TERM test is steal-acquired (STOLE-BY-CLAIM)" \
                                || bad "holder did not acquire via steal — parity test vacuous"
# ONE TERM only (same rationale as T33a): a second TERM can re-enter the
# handler mid-lock_release and abandon the unlink, flaking the
# released-on-TERM discriminator.
kill -TERM "$w34" 2>/dev/null
touch "$GO34"
wait "$w34"; rc=$?
[ "$rc" = 143 ] && ok "TERM'd steal-acquired holder exited 143 (signal re-raised)" || bad "steal-acquired TERM rc=$rc (want 143)"
[ -e "$LOCK" ] && bad "lock left held after TERM on a steal-acquired hold" || ok "steal-acquired lock released on TERM"
grep -q "RELEASED" "$LOG" && ok "release logged on the steal-acquired TERM path" || bad "no RELEASED entry for the steal-acquired hold"

echo "== Test 35: release-time leaked-claim cleanup — displaced hold cleans its own installed leak, 98 =="
# (a) B leaks token L (recheck-unreadable; the ghost vanishes at the same
# moment), acquires fresh N normally; a rival installs L over the lock,
# displacing B's held N. B's release must return 98 AND unlink L (the lock
# path is clean immediately after), logging RELEASE-CLEANED-LEAKED-CLAIM.
LOCK="$WORK/relclean.lock"; LOG="$WORK/relclean.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t35" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=5 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_read_tok _rt_orig
    SF1="$AGENT_LOCK_PATH.steer1"      # flag FILE: the read_tok shadow runs in subshells
    _lock_read_tok() {
      if [ ! -e "$SF1" ] && [ "$1" = "$_LOCK_CLAIM_PATH" ]; then
        : > "$SF1"
        command rm -f -- "$AGENT_LOCK_PATH"     # the live-slow ghost holder releases here
        printf ""
        return 0
      fi
      _rt_orig "$@"
    }
    lock_acquire || exit 72                      # leaks L, then creates fresh N
    [ -e "$_LOCK_CLAIM_PATH" ] || exit 73        # the leaked claim is still on disk
    command mv -f -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null || exit 76   # rival installs L
    lock_release; rrc=$?
    [ "$rrc" = 98 ] || exit 74
    [ -e "$AGENT_LOCK_PATH" ] && exit 75         # cleaned immediately — no STALE stall
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
case "$rc" in
  0)  ok "displaced hold: release returned 98 AND cleaned the installed leaked claim immediately" ;;
  74) bad "release did not classify the leaked-claim displacement as 98" ;;
  75) bad "release returned 98 but LEFT the installed leaked claim (a STALE-window stall)" ;;
  *)  bad "release-cleanup harness rc=$rc" ;;
esac
grep -q "RELEASE-CLEANED-LEAKED-CLAIM" "$LOG" && ok "RELEASE-CLEANED-LEAKED-CLAIM logged" \
                                              || bad "no RELEASE-CLEANED-LEAKED-CLAIM log line"
grep -q "LEAKED-CLAIM (recheck-unreadable)" "$LOG" && ok "the leak rode through the successful acquire into release" \
                                                   || bad "leak entry missing"
# (b) boundary variant: the installed L is instantly stale; a successor's
# steal lands between B's leaked-token verification and its cleanup unlink.
# B must NOT delete the successor's live lock (the pre-unlink re-read backs
# off; entry dropped) and must still classify 98.
LOCK="$WORK/relbound.lock"; LOG="$WORK/relbound.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t35b" "pid=9 host=ghost"; backdate "$LOCK" 9999
fabricate_lock "$WORK/t35b.succ" "tok.successor.t35" "pid=7 host=succ"
SUCC="$WORK/t35b.succ" \
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=5 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_read_tok _rt_orig
    clone_fn _lock_cur_token _ct_orig
    SF1="$AGENT_LOCK_PATH.steer1"      # flag FILES: both shadows run in subshells
    SF3="$AGENT_LOCK_PATH.steer3"
    L=""; RELPHASE=0
    _lock_read_tok() {
      if [ ! -e "$SF1" ] && [ "$1" = "$_LOCK_CLAIM_PATH" ]; then
        : > "$SF1"
        command rm -f -- "$AGENT_LOCK_PATH"
        printf ""
        return 0
      fi
      _rt_orig "$@"
    }
    _lock_cur_token() {
      local r; r="$(_ct_orig "$@")"
      if [ "$RELPHASE" = 1 ] && [ ! -e "$SF3" ] && [ -n "$L" ] && [ "$r" = "$L" ]; then
        : > "$SF3"
        command mv -f -- "$SUCC" "$AGENT_LOCK_PATH" 2>/dev/null   # the successor steals L
      fi
      printf "%s" "$r"
    }
    lock_acquire || exit 72
    IFS= read -r L < "$_LOCK_CLAIM_PATH" || exit 73
    command mv -f -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH" 2>/dev/null || exit 76   # rival installs L
    RELPHASE=1
    lock_release; rrc=$?
    [ "$rrc" = 98 ] || exit 74
    l1=""; IFS= read -r l1 < "$AGENT_LOCK_PATH" 2>/dev/null || true
    [ "$l1" = "tok.successor.t35" ] || exit 75   # the successor lock must survive
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
case "$rc" in
  0)  ok "boundary variant: pre-unlink re-read backed off — successor's lock survived, release still 98" ;;
  74) bad "boundary variant: release did not classify 98" ;;
  75) bad "boundary variant: B DELETED the successor's live lock (boundary re-read missing)" ;;
  *)  bad "boundary-variant harness rc=$rc" ;;
esac
grep -q "RELEASE-CLEANED-LEAKED-CLAIM" "$LOG" && bad "boundary variant wrongly logged a leaked-claim cleanup" \
                                              || ok "no cleanup line when the re-read backed off"
rm -f "$LOCK" "$LOCK.next" "$WORK/t35b.succ"

echo "== Test 36: arc-end resolution pass — an INCONCLUSIVE lock read keeps the entry pending; conclusive ones drop it =="
# The pass's entry-drop is gated on one lock-path read. That read resolves
# the entry ONLY when it is conclusive: a DIFFERENT readable token, or the
# path definitively absent. A lock PRESENT but unreadable/empty proves
# nothing — the leaked token may be installed under it — so the entry must
# SURVIVE, and a later acquire must still be able to adopt the token.
# Driven directly: the harness manufactures the memory state and calls the
# pass; "unreadable" is an EMPTY lock file (the read ladder's blank-read
# lane — the same classification a sharing-violation open takes).
LOCK="$WORK/arcend.lock"; LOG="$WORK/arcend.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
  bash -c '
    source "$1" || exit 70
    _LOCK_CLAIM_PATH="$AGENT_LOCK_PATH.next"
    # (1) INCONCLUSIVE: claim observation foreign, lock present-but-EMPTY.
    L="tok.leak.t36.1.1"
    _LOCK_LEAKED="$L"
    printf "%s\n%s\n" "tok.rival.t36" "pid=7 host=rival" > "$_LOCK_CLAIM_PATH"
    : > "$AGENT_LOCK_PATH"
    _lock_leaked_resolve_pass
    case " $_LOCK_LEAKED " in *" $L "*) ;; *) exit 71;; esac   # must SURVIVE
    # ...and a later poll/acquire still adopts: the unreadable lock turns
    # out to be our installed leak (content lands), and lock_acquire adopts
    # it via the leaked-token memory (then releases rc 0).
    printf "%s\n%s\n" "$L" "pid=1 host=leak" > "$AGENT_LOCK_PATH"
    command rm -f -- "$_LOCK_CLAIM_PATH"
    lock_acquire || exit 72
    lock_release || exit 73
    # (2) CONCLUSIVE different token at the lock -> the entry must DROP.
    L2="tok.leak.t36.2.2"
    _LOCK_LEAKED="$L2"
    printf "%s\n%s\n" "tok.rival.t36" "pid=7 host=rival" > "$_LOCK_CLAIM_PATH"
    printf "%s\n%s\n" "tok.other.t36" "pid=8 host=other" > "$AGENT_LOCK_PATH"
    _lock_leaked_resolve_pass
    case " $_LOCK_LEAKED " in *" $L2 "*) exit 74;; esac        # must DROP
    # (3) CONCLUSIVE definitively-absent lock (claim gone too) -> DROP.
    L3="tok.leak.t36.3.3"
    _LOCK_LEAKED="$L3"
    command rm -f -- "$_LOCK_CLAIM_PATH" "$AGENT_LOCK_PATH"
    _lock_leaked_resolve_pass
    case " $_LOCK_LEAKED " in *" $L3 "*) exit 75;; esac        # must DROP
    exit 0
  ' _ "$LIB" 2>/dev/null; rc=$?
case "$rc" in
  0)  ok "inconclusive lock read kept the entry; conclusive reads (different token / absent) dropped theirs" ;;
  71) bad "entry DROPPED on an inconclusive (present-but-unreadable) lock read — an installed leak would go unwatched" ;;
  72) bad "later acquire failed to adopt the kept entry's installed token (entry lost?)" ;;
  73) bad "release after the adoption failed" ;;
  74) bad "entry kept despite a conclusive different-token lock read" ;;
  75) bad "entry kept despite a definitively absent lock path" ;;
  *)  bad "arc-end three-way harness rc=$rc" ;;
esac
grep -q "DISCOVERY-HOLD (leaked-token memory)" "$LOG" && ok "the surviving entry was adopted by the later acquire" \
                                                      || bad "no leaked-memory adoption after the inconclusive keep"
grep -q "resolved tok=tok.leak.t36.2" "$LOG" && ok "conclusive resolution logged for the dropped entry" \
                                             || bad "no resolution log line for the conclusive drop"
rm -f "$LOCK" "$LOCK.next"

echo "== Test 37: rename-refused — a directory appearing at the lock path mid-steal aborts the steal, no false hold =="
# The only acquire/steal VERDICT branch with no test: a NON-regular object (a
# directory) appears AT the lock path between the claimant's final re-verify
# (step 3.3, sees a stale FILE) and its rename-over, so the rename is refused
# with the lock path occupied by a non-file. The claimant must classify this
# as rename-refused (non-file at the lock path), delete its claim, take NO
# hold, and re-poll to MAX_WAIT. Steered deterministically by shadowing mv:
# the claim->lock rename (the `.next` move) is intercepted to swap the stale
# lock FILE for a DIRECTORY at the lock path, then the real `mv -T` runs and
# fails NATURALLY (mv refuses to overwrite a directory with a non-directory) —
# exactly the wrong-type rename lane. The verifies don't call mv, so the lock
# reads as a stale file through step 3.3; only the rename sees the directory.
# Mutation check: an implementation that mis-classifies the refused rename
# (e.g. treats it as blocked, or proceeds to STOLE-BY-CLAIM) fails the
# no-false-hold / rename-refused assertions below.
LOCK="$WORK/renref.lock"; LOG="$WORK/renref.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t37" "pid=9 host=ghost"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=3 \
  bash -c '
    source "$1" || exit 70
    # Shadow mv: on the claim->lock rename (the only mv touching ".next"),
    # replace the stale lock file with a directory, then run the real mv -T,
    # which refuses to overwrite a directory with a non-directory. The mv -T
    # capability probe inside _lock_rename_over operates on its own temp paths
    # (never ".next"), so it is unaffected.
    mv() {
      case "$*" in
        *".next"*)
          command rm -f -- "$AGENT_LOCK_PATH" 2>/dev/null
          command mkdir -- "$AGENT_LOCK_PATH" 2>/dev/null
          ;;
      esac
      command mv "$@"
    }
    lock_acquire
    exit $?
  ' _ "$LIB" 2>/dev/null; rc=$?
[ "$rc" = 97 ] && ok "rename-refused waiter honoured MAX_WAIT (97), never falsely held" \
               || bad "rename-refused rc=$rc (want 97 — a false hold would exit 0)"
grep -q "CLAIM-ABORT (rename-refused)" "$LOG" \
  && ok "CLAIM-ABORT (rename-refused) logged — the wrong-type rename branch was hit" \
  || bad "no CLAIM-ABORT (rename-refused) — branch not exercised"
grep -q "non-file at the lock path" "$LOG" \
  && ok "rename refusal classified as non-file at the lock path" \
  || bad "missing 'non-file at the lock path' classification wording"
grep -q "STOLE-BY-CLAIM" "$LOG" \
  && bad "spurious STOLE-BY-CLAIM — the steal was claimed despite the refused rename" \
  || ok "no STOLE-BY-CLAIM (no false steal of the directory-occupied path)"
grep -q "DISCOVERY-HOLD" "$LOG" \
  && bad "spurious discovery-HOLD — the victim wrongly believed it acquired" \
  || ok "no spurious discovery-HOLD — ownership-discovery read found no hold"
grep -q "acquire verification FAILED" "$LOG" \
  && bad "read-back path entered — the rename was treated as having succeeded" \
  || ok "rename treated as refused, not as a completed-then-unverified steal"
[ -e "$LOCK.next" ] \
  && bad "claim leftover (\$LOCK.next) after the rename-refused abort" \
  || ok "claim file cleaned up — no leftover \$LOCK.next"
[ -d "$LOCK" ] \
  && ok "directory left in place at the lock path (never overwritten)" \
  || bad "lock path is no longer the squatting directory"
rm -rf "$LOCK" "$LOCK.next"

echo "== Test 38: step-3.3 pre-rename re-verify abort — claim cleaned, discovery, no false hold =="
# The step-2 re-verify (sh:1075) and the step-3.3 re-verify immediately before
# the rename (sh:1149) are near-identical abort lanes; Test 23/27 exercise the
# step-2 lane only, leaving 3.3 untested. Steered with a CALL-COUNTER on
# _lock_verify_stale: call 1 (step-2) passes through to the REAL verdict
# (stale — the ghost is backdated 9999s), so the steal proceeds PAST step-2;
# call 2 (step-3.3) freshens the lock first, so the real verify reports "fresh"
# and the abort fires SPECIFICALLY at step-3.3. The proof is the log suffix
# "(lock re-verify before rename: fresh)" — step-2's suffix is "after claim",
# so the string can only be the 3.3 lane. STALE_SECS=30 keeps the freshened
# ghost fresh long enough that the post-abort re-poll does NOT re-steal before
# the test removes the lock — so the waiter then acquires via the CREATE race
# (no second STOLE-BY-CLAIM), the same shape as Test 23.
LOCK="$WORK/pr33.lock"; LOG="$WORK/pr33.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t38" "pid=9 host=slow"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=30 \
  AGENT_LOCK_CLAIM_STALE_SECS=60 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_verify_stale _vs_orig
    N=0
    _lock_verify_stale() {
      N=$((N+1))
      # call 1 = step-2: pass through to the real verdict (stale). call 2 =
      # step-3.3: freshen the ghost lock so the real verify now sees "fresh",
      # tripping the pre-rename abort at the 3.3 position.
      if [ "$N" = 2 ]; then command touch -- "$AGENT_LOCK_PATH"; fi
      _vs_orig "$@"
    }
    lock_acquire || exit 72
    lock_release || exit 74
    exit 0
  ' _ "$LIB" 2>/dev/null &
w38=$!
# Proof the 3.3 lane ran AND the steal got PAST step-2: the "before rename"
# suffix is unique to the step-3.3 position (step-2 logs "after claim").
wait_for_grep "lock re-verify before rename: fresh" "$LOG" 20 \
  && ok "step-3.3 pre-rename re-verify aborted (fresh) — got past step-2 to the 3.3 lane" \
  || bad "no step-3.3 'before rename' abort — the 3.3 lane did not run"
grep -q "CLAIM-ABORT (fresh) tok=.* (lock re-verify before rename: fresh)" "$LOG" \
  && ok "CLAIM-ABORT (fresh) logged at the 3.3 position (reason map: fresh)" \
  || bad "no CLAIM-ABORT (fresh) with the 'before rename' suffix"
grep -q "lock re-verify after claim" "$LOG" \
  && bad "the abort fired at step-2 (after claim) — the call-counter let call 1 trip, not the 3.3 lane" \
  || ok "no step-2 (after claim) abort — call 1 passed; only the 3.3 lane aborted"
grep -q "STOLE-BY-CLAIM" "$LOG" \
  && bad "a rename installed the claim — the 3.3 fresh abort did not prevent the steal" \
  || ok "no STOLE-BY-CLAIM — no rename onto the lock from the aborted attempt"
grep -q "DISCOVERY-HOLD" "$LOG" \
  && bad "spurious DISCOVERY-HOLD — the victim wrongly held after the 3.3 abort" \
  || ok "no false hold — the discovery read ran and the victim did not wrongly hold"
[ -e "$LOCK.next" ] && bad "claim leftover immediately after the 3.3 fresh abort" \
                    || ok "claim deleted on the 3.3 fresh abort"
rm -f "$LOCK"                       # the slow holder releases normally
wait "$w38"; rc=$?
[ "$rc" = 0 ] && ok "waiter re-polled past the 3.3 abort, then acquired/released (rc 0)" \
              || bad "waiter rc=$rc after the slow holder released (want 0)"
[ -e "$LOCK.next" ] && bad "claim leftover after the waiter finished" || ok "no claim leftover at exit"
rm -f "$LOCK" "$LOCK.next"


echo "== Test 39: foreign claim at recheck — left intact, discovery, no false 98 =="
# After winning its claim and passing step-2 re-verify, the claimant rechecks
# its OWN claim file before installing. The `gone` recheck leg is covered (Test
# 25 recheck-gone / Test 32); the `foreign` leg is NOT: a waiter judged our
# claim abandoned, cleared it, and a RIVAL re-claimed in its place, so the
# recheck reads back a FOREIGN token at the claim path. The claimant must then
# LEAVE the rival's claim alone, run the ownership-discovery read (the lock is
# still the ghost, not ours -> no hold), and back off to re-poll — never a 98
# (a mere claim recheck carries NO stolen-lease semantics) and never a deletion
# of the rival's claim.
#
# Steering (Test 24/25 idiom): clone _lock_claim_state and, on the FIRST recheck
# only (fire-once via a flag FILE so a subshell can't lose the state), overwrite
# <lock>.next with a fresh-mtime foreign "tok.rival.*" token before delegating
# to the original — exactly what a waiter-cleared + rival-reclaimed claim path
# looks like. The original then classifies it `foreign`. CLAIM_STALE is large
# and MAX_WAIT small so the freshly-planted rival claim is never aged out: it
# survives, the create on the next poll loses to it, and the waiter times out
# 97. Mutation check: an implementation that 98'd on a foreign recheck, or that
# deleted/overwrote the rival's claim, or that false-HELD, fails the asserts.
LOCK="$WORK/foreign-recheck.lock"; LOG="$WORK/foreign-recheck.log"; : > "$LOG"
fabricate_lock "$LOCK" "tok.ghost.t39" "pid=9 host=ghost"; backdate "$LOCK" 9999
SF="$LOCK.steered"; RIVAL="tok.rival.t39.deadbeef"; rm -f "$SF"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_CLAIM_STALE_SECS=600 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=3 \
  SF="$SF" RIVAL="$RIVAL" \
  bash -c '
    source "$1" || exit 70
    clone_fn _lock_claim_state _cs_orig
    _lock_claim_state() {
      # Fire ONCE, at the post-win recheck of OUR claim: a waiter cleared ours
      # and a rival re-claimed. Plant the rival token (fresh mtime => not stale)
      # then classify via the real function.
      if [ ! -e "$SF" ] && [ "$1" = "$_LOCK_CLAIM_TOKEN" ] \
         && [ "$_LOCK_CLAIM_PATH" -ef "$AGENT_LOCK_PATH.next" ] 2>/dev/null; then
        : > "$SF"
        printf "%s\n%s\n" "$RIVAL" "pid=4242 host=rival" > "$_LOCK_CLAIM_PATH"
      fi
      _cs_orig "$@"
    }
    lock_acquire
    exit $?
  ' _ "$LIB" 2>/dev/null; rc=$?

# The foreign-recheck branch ran (its log line is the proof the leg executed).
grep -q "claim recheck: foreign token '$RIVAL' at the claim" "$LOG" \
  && ok "foreign-recheck branch ran (rival token left at the claim, discovery read)" \
  || bad "no foreign-recheck log line — branch not executed"
# A mere claim recheck must NEVER report a stolen-lease 98.
[ "$rc" = 98 ] && bad "false 98 on a foreign CLAIM recheck (no lease was ever held)" \
              || ok "no false 98 on the foreign claim recheck (rc=$rc)"
# No hold was ever taken: discovery saw the ghost, not our token.
grep -q "DISCOVERY-HOLD" "$LOG" && bad "false discovery-HOLD on the foreign recheck" \
                               || ok "no false hold (ownership-discovery read found the ghost, not ours)"
grep -q "STOLE-BY-CLAIM" "$LOG" && bad "claimant stole despite a foreign claim at recheck" \
                                || ok "no STOLE-BY-CLAIM — claimant backed off the foreign claim"
# The rival's claim file SURVIVES, unmodified (left intact, never deleted).
[ -e "$LOCK.next" ] && ok "rival's foreign claim file still present (not deleted)" \
                    || bad "rival's foreign claim was deleted — must be left alone"
rl1=""; IFS= read -r rl1 < "$LOCK.next" 2>/dev/null || true
[ "$rl1" = "$RIVAL" ] && ok "rival's claim token intact (untouched: $rl1)" \
                      || bad "rival's claim token modified (line1=$rl1, want $RIVAL)"
grep -q "CLAIM-STALE-CLEARED" "$LOG" && bad "claimant aged-out/cleared the rival's fresh claim" \
                                     || ok "rival's fresh claim never cleared as stale"
# Clean outcome: the lock was never acquired; the waiter timed out (97).
[ "$rc" = 97 ] && ok "waiter re-polled past the foreign claim and timed out cleanly (97)" \
              || bad "rc=$rc (want 97 — clean re-poll/timeout behind the surviving rival claim)"
# The ghost lock is untouched (never stolen).
gl1=""; IFS= read -r gl1 < "$LOCK" 2>/dev/null || true
[ "$gl1" = "tok.ghost.t39" ] && ok "ghost lock untouched by the foreign-recheck backoff" \
                             || bad "ghost lock modified (line1=$gl1)"
rm -f "$LOCK" "$LOCK.next" "$SF"

echo "== Test 40: exec-bypass boundary — exec in the lock-holding shell skips release (OOS-5); exec in a child does not =="
# `lock_run` runs the wrapped command vector with `"$@"` IN THE WRAPPER SHELL
# (git-commit-lock.sh), so a command that is itself an `exec` REPLACES the
# lock-holding wrapper process: the trailing `lock_release` AND the EXIT trap
# are both skipped, and the lock is left held with no RELEASED logged. This is
# the one interleaving that can SILENTLY lose an update (guarantees.md OOS-5) —
# this test pins the exact boundary so a future change to the release/trap
# wiring can't quietly widen or close it without a red.

# (a1) BYPASS: `run -- exec true` — the wrapped command IS an exec, so it
# replaces the wrapper. Release + EXIT trap are skipped: lock LEFT, no RELEASED
# (ACQUIRED proves the hold was taken, so "no RELEASED" means the trap really
# was bypassed, not that nothing ran).
LOCK="$WORK/t40.bypass.lock"; LOG="$WORK/t40.bypass.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- exec true; rc=$?
[ "$rc" = 0 ] && ok "run -- exec true exits 0 (the exec'd command's code)" \
              || bad "run -- exec true rc=$rc (want 0)"
grep -q ACQUIRED "$LOG" && ok "run -- exec true did take the lock (ACQUIRED logged)" \
                        || bad "run -- exec true: no ACQUIRED — the hold never happened, test is vacuous"
[ -e "$LOCK" ] && ok "run -- exec true LEFT the lock file (release bypassed by exec)" \
               || bad "run -- exec true: lock released — exec did NOT bypass (boundary changed)"
grep -q RELEASED "$LOG" && bad "run -- exec true logged RELEASED — the EXIT trap was NOT skipped (boundary changed)" \
                        || ok "run -- exec true logged NO RELEASED (EXIT trap skipped — OOS-5 boundary)"
rm -f "$LOCK"

# (a2) CONTROL — NO bypass: `run -- bash -c 'exec true'` — the exec replaces the
# CHILD, not the wrapper, so the wrapper releases normally: lock GONE, RELEASED
# logged. The opposite outcome to (a1) is the whole point; assert both so the
# test documents the exact boundary.
LOCK="$WORK/t40.child.lock"; LOG="$WORK/t40.child.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash "$LIB" run -- bash -c 'exec true'; rc=$?
[ "$rc" = 0 ] && ok "run -- bash -c 'exec true' exits 0" \
              || bad "run -- bash -c 'exec true' rc=$rc (want 0)"
[ -e "$LOCK" ] && bad "run -- bash -c 'exec true' LEFT the lock — exec in a child must NOT bypass" \
               || ok "run -- bash -c 'exec true' released the lock (exec in a child does not bypass)"
grep -q RELEASED "$LOG" && ok "run -- bash -c 'exec true' logged RELEASED (the control: release ran)" \
                        || bad "run -- bash -c 'exec true' logged NO RELEASED — the control case did not release"
rm -f "$LOCK"

# (a3) REALISTIC sourced bypass: `lock_acquire; exec true` in a sourcing shell
# (a subshell so it can't take the suite down) — the holder execs away before
# release, leaving the lock held. This is the shape a real caller hits if it
# execs while holding instead of calling lock_release.
LOCK="$WORK/t40.sourced.lock"; LOG="$WORK/t40.sourced.log"; : > "$LOG"
( AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
    source "$1" || exit 70
    lock_acquire || exit 72
    exec true
  ' _ "$LIB" ); rc=$?
[ "$rc" = 0 ] && ok "sourced lock_acquire; exec true exits 0" \
              || bad "sourced lock_acquire; exec true rc=$rc (want 0)"
[ -e "$LOCK" ] && ok "sourced lock_acquire; exec true LEFT the lock held (release skipped)" \
               || bad "sourced lock_acquire; exec true released the lock — exec did not bypass"
grep -q RELEASED "$LOG" && bad "sourced exec-while-holding logged RELEASED — the trap was not skipped" \
                        || ok "sourced exec-while-holding logged NO RELEASED (release + trap skipped)"
rm -f "$LOCK"

# (b) SILENT-LOSS boundary: a DISPLACED holder that execs a 0-exit is UNWARNED.
# Build a holder H that (sourced) acquires, backdates its OWN lock ancient so a
# contender steals it (H is now displaced — a rival token sits at the path),
# then execs a 0-exit. Because the exec skips BOTH release and the EXIT trap,
# the displacement-detection in lock_release NEVER runs: H exits 0 with no
# WARNING and no 98. This is exactly the documented silent boundary (OOS-5): a
# non-unwinding exit while displaced cannot report that the hold was not
# exclusive. (backdate/epoch_to_stamp are export -f'd by the preamble, so the
# steering shell inherits them.)
LOCK="$WORK/t40.silent.lock"; LOG="$WORK/t40.silent.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 \
  AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 bash -c '
    source "$1" || exit 70
    lock_acquire || exit 72             # H holds the lock
    backdate "$2" 9999                  # H'"'"'s own lock now ancient -> instantly stealable
    # A contender steals it (separate process) — H is displaced once a rival
    # token lands at the path.
    AGENT_LOCK_PATH="$2" AGENT_LOCK_LOG="$3" AGENT_LOCK_STALE_SECS=1 \
      AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=10 \
      bash "$1" run -- true
    exec true                           # H execs 0 — neither release nor trap runs
  ' _ "$LIB" "$LOCK" "$LOG"; rc=$?
[ "$rc" = 0 ] && ok "displaced holder's exec-0 exits 0 (no unwinding ran)" \
              || bad "displaced holder's exec-0 rc=$rc (want 0)"
grep -q "STOLE-BY-CLAIM" "$LOG" \
  && ok "the contender genuinely displaced H (STOLE-BY-CLAIM logged) — H WAS displaced" \
  || bad "no STOLE-BY-CLAIM — H was not actually displaced, the (b) premise is gone"
grep -q "lock LOST" "$LOG" \
  && bad "H logged a 'lock LOST' displacement WARNING — the exec did NOT skip release/trap" \
  || ok "displaced holder's exec-0 emitted NO 'lock LOST' WARNING (silent boundary — OOS-5)"
grep -q "WARNING" "$LOG" \
  && bad "an unexpected WARNING was logged by the displaced exec-0 holder" \
  || ok "displaced holder's exec-0 emitted NO WARNING at all (unwarned silent loss)"
rm -f "$LOCK"

# NOTES (deliberately untested here):
# * lock_release's LEFTOVER lane (the unlink blocked persistently) needs a
#   foreign no-delete-share handle on the lock file — Windows-only, and the
#   blocker is most naturally a pwsh FileShare.Read holder, so the interop
#   suite owns that test (on POSIX, unlink never blocks on open handles and
#   the lane is unreachable).
# * lock_acquire's read-back-verification failure lanes (defence in depth; see
#   the ACQUIRE VERIFICATION header section) are covered via _lock_cur_token
#   fault injection: the create-path lane (create won, read-back wrong) by
#   Test 32, the steal-path lane (F2 — rename-over won, read-back wrong) by
#   Test 32b.

DONE=1
echo
echo "==== RESULT: $PASS passed, $FAIL failed, $ENV_WARN envelope warning(s) (fan-out: $GCL_MODE) ===="
[ "$GCL_TAP" = 1 ] && echo "1..$TAPN"
[ "$FAIL" = 0 ]
