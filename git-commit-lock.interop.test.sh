#!/usr/bin/env bash
# git-commit-lock.interop.test.sh
#
# Cross-implementation test: proves git-commit-lock.ps1 (PowerShell) and
# git-commit-lock.sh (bash) share ONE lock and serialise against EACH OTHER in
# the same working tree, and that the .ps1 side honours the shared behavioural
# contract (exit-code propagation; 97 timeout; 98 stolen mid-hold; steal of
# genuinely stale locks; <gitdir>/commit.lock default location; identical
# unverifiable-release and numeric-knob verdicts). On Windows,
# run from MINGW/Git-Bash — NOT from WSL — because both sides must agree on
# the lock path in `C:/...` form. Spawns pwsh + bash workers, so it needs both
# on PATH.
#   bash ~/.local/bin/git-commit-lock.interop.test.sh
# Exit 0 == all pass. Uses a throwaway temp dir; never touches your repo.
# On failure the temp dir is PRESERVED (path printed) for post-mortem; set
# GCL_TEST_PRESERVE_DIR=<dir> to always copy the work dir (logs etc.) there.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/git-commit-lock.sh"
PS1WIN="$(cygpath -w "$DIR/git-commit-lock.ps1" 2>/dev/null || echo "$DIR/git-commit-lock.ps1")"
PS1WIN="${PS1WIN//\\//}"   # forward slashes: both pwsh and mingw accept C:/...

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 0; }

# A Windows-form temp dir BOTH pwsh and mingw bash resolve to the same NTFS path.
WORK="$(pwsh -NoProfile -Command '[IO.Path]::Combine([IO.Path]::GetTempPath(), "cl-interop-" + [guid]::NewGuid().ToString("N").Substring(0,8))' 2>/dev/null | tr -d '\r')"
WORK="${WORK//\\//}"
mkdir -p "$WORK"

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

# Failure post-mortems need the logs: keep $WORK when anything failed, and
# honour GCL_TEST_PRESERVE_DIR (the CI plan's preserve-logs knob) by copying
# the work dir there unconditionally when it is set.
cleanup() {
  if [ -n "${GCL_TEST_PRESERVE_DIR:-}" ]; then
    mkdir -p "$GCL_TEST_PRESERVE_DIR" 2>/dev/null || true
    cp -r "$WORK" "$GCL_TEST_PRESERVE_DIR/" 2>/dev/null || true
    echo "work dir copied to $GCL_TEST_PRESERVE_DIR/$(basename "$WORK")"
  fi
  if [ "${FAIL:-0}" -gt 0 ]; then
    echo "FAIL>0: work dir preserved at $WORK"
    return 0
  fi
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# Poll for a marker file: ready-markers replace fixed head-start sleeps so a
# slow pwsh cold-start (1-3s+ under load) can't fake an ordering failure.
wait_for() {  # $1=file $2=max iterations of 50ms (default 200 = 10s)
  local i; for i in $(seq 1 "${2:-200}"); do [ -e "$1" ] && return 0; sleep 0.05; done
  return 1
}

# Backdate a path's mtime by $2 seconds — how a test fakes a stale lock (the
# staleness clock is the lock DIR's own mtime). Portable: BSD/macOS touch has
# no `-d @epoch`, so convert the target epoch to a `touch -t` stamp via GNU
# `date -d @` with BSD `date -r` as fallback (same helper as the unit suite).
epoch_to_stamp() {
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null
}
backdate() { touch -t "$(epoch_to_stamp "$(( $(date +%s) - $2 ))")" "$1"; }

# Workers increment a shared integer file. Written WITHOUT a trailing newline and
# read whitespace-trimmed on BOTH sides, so bash and PowerShell agree on the value
# regardless of CRLF. A read-gap-write makes lost updates visible without a mutex.
# Exclusion probe: under the lock, each worker stamps its unique id into a shared
# HOLDER file, sleeps, then reads it back. If it reads a DIFFERENT id, a second
# worker held the lock at the same time -> a real exclusion break (logged to
# VIOLATIONS). Writes/reads retry on transient Windows sharing violations; only a
# SUCCESSFUL read of a foreign id counts — so file-handle flakiness can't fake a
# violation, and a real double-hold can't hide behind a retry.
# A violation is recorded ONLY when our OWN id-write succeeded AND we then read a
# foreign id — i.e. someone overwrote HOLDER while we held the lock = a real
# double-hold. If our write never succeeded (previous holder's lingering
# FileShare.Read handle blocked us for the whole retry budget), we can't conclude
# anything and stay silent — that's the Windows hot-file artifact, not the lock.
sh_worker() {  # $1=lock $2=log $3=holder $4=violations $5=id
  AGENT_LOCK_DIR="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    bash "$SH" run -- bash -c '
      h="$1"; v="$2"; id="$3"; wrote=0
      for i in $(seq 1 80); do if printf "%s" "$id" > "$h" 2>/dev/null; then wrote=1; break; fi; sleep 0.015; done
      sleep 0.03
      cur=""; for i in $(seq 1 80); do cur=$(cat "$h" 2>/dev/null); [ -n "$cur" ] && break; sleep 0.015; done
      [ "$wrote" = 1 ] && [ -n "$cur" ] && [ "$cur" != "$id" ] && printf "%s saw %s\n" "$id" "$cur" >> "$v"
      true
    ' _ "$3" "$4" "$5"
}
ps_worker() {  # $1=lock $2=log $3=holder $4=violations $5=id
  local body="\$h='$3'; \$v='$4'; \$id='$5'; \$wrote=\$false; for(\$i=0;\$i -lt 80;\$i++){try{[IO.File]::WriteAllText(\$h,\$id);\$wrote=\$true;break}catch{Start-Sleep -Milliseconds 15}} Start-Sleep -Milliseconds 30; \$cur=\$null; for(\$i=0;\$i -lt 80;\$i++){try{\$cur=[IO.File]::ReadAllText(\$h);break}catch{Start-Sleep -Milliseconds 15}} if(\$wrote -and \$cur -ne \$null -and \$cur -ne '' -and \$cur -ne \$id){[IO.File]::AppendAllText(\$v,\$id+' saw '+\$cur+[char]10)}"
  AGENT_LOCK_DIR="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    pwsh -NoProfile -File "$PS1WIN" run "$body"
}

echo "== Test 1: mixed pwsh+bash workers, mutual exclusion across implementations =="
NSH=8; NPS=8; TOT=$((NSH+NPS))
LOCK="$WORK/excl.lock"
HOLDER="$WORK/holder"; : > "$HOLDER"; VIOL="$WORK/violations"; : > "$VIOL"
# PER-WORKER lock logs: concurrent appends to ONE shared log are silently
# swallowed by both impls' guarded log writes (a transient sharing violation
# drops the line), which could false-fail the released==acquired gate or mask
# a real imbalance. With a log per worker there are no concurrent appends; the
# counts are summed over the concatenation.
pids=()
for i in $(seq 1 $NSH); do sh_worker "$LOCK" "$WORK/excl-sh$i.log" "$HOLDER" "$VIOL" "sh$i" & pids+=($!); done
for i in $(seq 1 $NPS); do ps_worker "$LOCK" "$WORK/excl-ps$i.log" "$HOLDER" "$VIOL" "ps$i" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
cat "$WORK"/excl-*.log > "$WORK/excl-all.log" 2>/dev/null || : > "$WORK/excl-all.log"
a="$(grep -c ACQUIRED "$WORK/excl-all.log")"; rl="$(grep -c RELEASED "$WORK/excl-all.log")"; st="$(grep -c STOLE "$WORK/excl-all.log")"
nv="$(wc -l < "$VIOL" 2>/dev/null | tr -d ' ')"; nv="${nv:-0}"
# Real signals gate PASS: zero concurrent-holder violations, zero spurious steals
# (none should occur at stale=300 in a seconds-long run), balanced acquire/release
# (released<acquired would mean a false "stolen" or a leaked lock), and no leftover
# lock. A worker that never launched (acquired<TOT) is Cygwin process-fan-out
# flakiness, orthogonal to the lock — noted, not failed; but a MINIMUM-ACQUIRED
# floor (half) stops the test passing vacuously when the fan-out collapses
# entirely (mutation finding, item 50). Test 6 below is the deterministic
# counterpart with strict per-worker exit codes.
if [ "$nv" = 0 ] && [ "$st" = 0 ] && [ "$rl" = "$a" ] && [ "$a" -ge $((TOT/2)) ] && [ ! -e "$LOCK" ]; then
  if [ "$a" = "$TOT" ]; then
    ok "$NSH bash + $NPS pwsh workers: 0 violations, 0 spurious steals, all $TOT acquired+released, no leftover lock"
  else
    ok "0 violations, 0 steals, balanced acquire/release ($a/$a), no leftover; NOTE $((TOT-a)) worker(s) didn't launch (fan-out flakiness, not the lock)"
  fi
else
  [ "$nv" != 0 ] && { echo "  VIOLATIONS:"; sed 's/^/    /' "$VIOL"; }
  [ "$st" != 0 ] && { echo "  STALE/STEAL log lines:"; grep -E "STALE|STOLE" "$WORK/excl-all.log" | sed 's/^/    /'; }
  bad "cross-impl exclusion/balance: violations=$nv steals=$st acquired=$a (floor $((TOT/2))) released=$rl leftover=$([ -e "$LOCK" ] && echo yes || echo no)"
fi

echo "== Test 2: a bash holder blocks a pwsh waiter (no concurrent hold, no wrongful steal) =="
LOCK="$WORK/b2.lock"; LOG="$WORK/b2.log"; : > "$LOG"; ORDER="$WORK/b2.order"; : > "$ORDER"
READY="$WORK/b2.ready"; rm -f "$READY"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$SH" run -- bash -c ': > "$2"; echo sh-start >> "$1"; sleep 2; echo sh-end >> "$1"' _ "$ORDER" "$READY" &
holder=$!
# Launch the waiter only once the holder demonstrably HOLDS the lock (ready
# marker written inside the critical section) — a fixed head-start sleep would
# race pwsh/bash cold-start times under load.
wait_for "$READY" || bad "T2 holder never signalled ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::AppendAllText('$ORDER','ps-ran' + [char]10)"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "sh-start,sh-end,ps-ran," ] && ok "bash-holds / pwsh-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "pwsh wrongly STOLE a live bash lock" || ok "pwsh did not steal the live bash lock"

echo "== Test 3: a pwsh holder blocks a bash waiter =="
LOCK="$WORK/b3.lock"; LOG="$WORK/b3.log"; : > "$LOG"; ORDER="$WORK/b3.order"; : > "$ORDER"
READY="$WORK/b3.ready"; rm -f "$READY"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$READY','r'); [IO.File]::AppendAllText('$ORDER','ps-start' + [char]10); Start-Sleep 2; [IO.File]::AppendAllText('$ORDER','ps-end' + [char]10)" &
holder=$!
wait_for "$READY" || bad "T3 holder never signalled ready"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$SH" run -- bash -c 'echo sh-ran >> "$1"' _ "$ORDER"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "ps-start,ps-end,sh-ran," ] && ok "pwsh-holds / bash-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "bash wrongly STOLE a live pwsh lock" || ok "bash did not steal the live pwsh lock"

echo "== Test 4: pwsh steals a STALE lock left by bash (old dir mtime) =="
# AGENT_LOCK_MAX_WAIT caps the run so a steal regression fails in ~20s, not 420s.
LOCK="$WORK/b4.lock"; LOG="$WORK/b4.log"; : > "$LOG"; MARK="$WORK/b4.mark"; printf '%s' before > "$MARK"
mkdir -p "$LOCK"; printf 'pid=99999 host=ghost\n' > "$LOCK/owner"; printf '%s' "tok.sh.ghost" > "$LOCK/token"
backdate "$LOCK" 9999                           # ancient dir mtime -> stale
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$MARK','after')"; rc=$?
[ "$rc" = 0 ] && ok "pwsh run exited 0 after stealing bash's stale lock" || bad "pwsh run exited $rc"
[ "$(cat "$MARK")" = after ] && ok "stale bash lock stolen, pwsh command ran" || bad "marker=$(cat "$MARK")"
grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"

echo "== Test 5: bash steals a STALE lock GENUINELY created by pwsh (holder killed mid-hold) =="
# The stale lock really is pwsh's: a pwsh process dot-sources the lock, acquires,
# signals ready, then is hard-killed by PID mid-hold (TerminateProcess — no
# release, no exit event), leaving its live lock dir + tok.ps.* token behind.
LOCK="$WORK/b5.lock"; LOG="$WORK/b5.log"; : > "$LOG"; MARK="$WORK/b5.mark"; printf '%s' before > "$MARK"
READY="$WORK/b5.ready"; rm -f "$READY"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  pwsh -NoProfile -Command ". '$PS1WIN'; Lock-Acquire | Out-Null; [IO.File]::WriteAllText('$READY','r'); Start-Sleep 60" &
hpid=$!
if wait_for "$READY"; then
  kill -9 "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  sleep 0.3
  tok="$(cat "$LOCK/token" 2>/dev/null | tr -d '\r\n')"
  case "$tok" in
    tok.ps.*) ok "dead pwsh holder left its own lock behind (token $tok)" ;;
    *)        bad "expected a tok.ps.* token in the orphan lock, got '$tok'" ;;
  esac
  backdate "$LOCK" 9999                           # age the orphan past any stale window
  AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
    bash "$SH" run -- bash -c 'printf "%s" after > "$1"' _ "$MARK"; rc=$?
  [ "$rc" = 0 ] && ok "bash run exited 0 after stealing pwsh's stale lock" || bad "bash run exited $rc"
  [ "$(cat "$MARK")" = after ] && ok "stale pwsh lock stolen, bash command ran" || bad "marker=$(cat "$MARK")"
  grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"
else
  kill -9 "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  bad "T5 pwsh holder never acquired/signalled ready"
fi

echo "== Test 6: deterministic lost-update counter, mixed bash+pwsh increments =="
# The deterministic complement to Test 1's exclusion probe (which has a blind
# window and tolerates launch flakiness): every worker MUST launch (strict rc
# checks) and the final counter MUST equal the total increments — any lost
# update or failed worker fails the test.
NCS=6; NCP=6; CTOT=$((NCS+NCP))
LOCK="$WORK/cnt.lock"
CNT="$WORK/counter"; printf '%s' 0 > "$CNT"
# Read-gap-write under the lock; reads/writes retry on transient Windows
# sharing violations (a previous holder's lingering handle), and a worker whose
# retry budget is exhausted exits 9 so the failure is loud, not a silent miss.
# Per-worker lock logs for the same reason as Test 1.
count_sh() {  # $1=id
  AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$WORK/cnt-$1.log" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    bash "$SH" run -- bash -c '
      c="$1"; n=""
      for i in $(seq 1 100); do n="$(cat "$c" 2>/dev/null)"; [ -n "$n" ] && break; sleep 0.015; done
      [ -n "$n" ] || exit 9
      sleep 0.03
      for i in $(seq 1 100); do { printf "%s" "$((n+1))" > "$c"; } 2>/dev/null && exit 0; sleep 0.015; done
      exit 9
    ' _ "$CNT" > /dev/null 2>&1
  echo $? > "$WORK/cnt-$1.rc"
}
count_ps() {  # $1=id
  local body="\$c='$CNT'; \$n=\$null; for(\$i=0;\$i -lt 100;\$i++){try{\$n=[int]([IO.File]::ReadAllText(\$c).Trim());break}catch{Start-Sleep -Milliseconds 15}} if(\$null -eq \$n){exit 9}; Start-Sleep -Milliseconds 30; for(\$i=0;\$i -lt 100;\$i++){try{[IO.File]::WriteAllText(\$c,[string](\$n+1));exit 0}catch{Start-Sleep -Milliseconds 15}} exit 9"
  AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$WORK/cnt-$1.log" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    pwsh -NoProfile -File "$PS1WIN" run "$body" > /dev/null 2>&1
  echo $? > "$WORK/cnt-$1.rc"
}
pids=()
for i in $(seq 1 $NCS); do count_sh "sh$i" & pids+=($!); done
for i in $(seq 1 $NCP); do count_ps "ps$i" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
rc_fail=0
for id in $(seq 1 $NCS | sed 's/^/sh/') $(seq 1 $NCP | sed 's/^/ps/'); do
  rc="$(cat "$WORK/cnt-$id.rc" 2>/dev/null || echo missing)"
  [ "$rc" = 0 ] || { rc_fail=1; echo "  worker $id rc=$rc"; }
done
[ "$rc_fail" = 0 ] && ok "all $CTOT counter workers ran and exited 0" || bad "counter worker(s) failed (see above)"
final="$(cat "$CNT" | tr -d '[:space:]')"
[ "$final" = "$CTOT" ] && ok "counter = $final == $CTOT increments (no lost updates)" || bad "counter = $final, want $CTOT — lost update(s)"
cat "$WORK"/cnt-*.log > "$WORK/cnt-all.log" 2>/dev/null || : > "$WORK/cnt-all.log"
a="$(grep -c ACQUIRED "$WORK/cnt-all.log")"; rl="$(grep -c RELEASED "$WORK/cnt-all.log")"
[ "$a" = "$CTOT" ] && [ "$rl" = "$CTOT" ] && ok "lock logs balanced ($a acquired / $rl released)" || bad "lock logs unbalanced: acquired=$a released=$rl want=$CTOT"
[ -e "$LOCK" ] && bad "leftover counter lock" || ok "no leftover lock"

echo "== Test 7: pwsh run propagates the command's exit code =="
LOCK="$WORK/rc.lock"; LOG="$WORK/rc.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0"; [ "$?" = 0 ] && ok "pwsh exit 0 propagated" || bad "pwsh exit 0 not propagated"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 7"; [ "$?" = 7 ] && ok "pwsh exit 7 propagated" || bad "pwsh exit code not propagated ($?)"
[ -e "$LOCK" ] && bad "lock left held after pwsh run" || ok "lock released after pwsh run (success and failure)"

echo "== Test 8: a ROBBED holder exits 98 — pwsh victim/bash thief, then bash victim/pwsh thief =="
# Fail-open ceiling, cross-impl: the victim holds past its 1s stale window, the
# other implementation steals, and the victim's release detects the theft and
# exits 98 (the reserved stolen-mid-hold code) while the thief exits 0.
LOCK="$WORK/rob1.lock"; LOG="$WORK/rob1.log"; : > "$LOG"
READY="$WORK/rob1.ready"; rm -f "$READY"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$READY','r'); Start-Sleep 5" 2>/dev/null &
vic=$!
wait_for "$READY" || bad "T8a pwsh victim never signalled ready"
sleep 1.5   # let the victim's 1s lease go stale before the thief looks
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$SH" run -- bash -c 'true'; thief_rc=$?
wait "$vic"; vic_rc=$?
[ "$vic_rc" = 98 ] && ok "robbed pwsh holder exited 98" || bad "robbed pwsh holder exited $vic_rc (want 98)"
[ "$thief_rc" = 0 ] && ok "bash thief exited 0" || bad "bash thief exited $thief_rc"
grep -q "WARNING" "$LOG" && ok "theft WARNING logged" || bad "no theft WARNING in log"

LOCK="$WORK/rob2.lock"; LOG="$WORK/rob2.log"; : > "$LOG"
READY="$WORK/rob2.ready"; rm -f "$READY"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$SH" run -- bash -c ': > "$1"; sleep 8' _ "$READY" 2>/dev/null &
vic=$!
wait_for "$READY" || bad "T8b bash victim never signalled ready"
sleep 1.5
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0"; thief_rc=$?
wait "$vic"; vic_rc=$?
[ "$vic_rc" = 98 ] && ok "robbed bash holder exited 98" || bad "robbed bash holder exited $vic_rc (want 98)"
[ "$thief_rc" = 0 ] && ok "pwsh thief exited 0" || bad "pwsh thief exited $thief_rc"

echo "== Test 9: a slow but UNCONTENDED pwsh holder keeps its lock (slowness != failure) =="
LOCK="$WORK/slow.lock"; LOG="$WORK/slow.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "Start-Sleep 3"; rc=$?
[ "$rc" = 0 ] && ok "uncontended slow pwsh holder exited 0" || bad "uncontended slow pwsh holder exited $rc"
grep -q "WARNING" "$LOG" && bad "spurious theft WARNING with no contender" || ok "no spurious WARNING when uncontended"

echo "== Test 10: default lock location is <gitdir>/commit.lock for BOTH impls (regression: item 1) =="
# The BLOCKER this guards against: the .ps1 silently fell back to a CWD lock at
# default config, so the two impls never contended. Run BOTH impls from a
# SUBDIRECTORY of a scratch repo with AGENT_LOCK_DIR/LOG unset; each command
# probes (while holding) that the lock dir really is <gitdir>/commit.lock, and
# the shared <gitdir> log must record one ACQUIRED from each side.
SCRATCH="$WORK/scratch"; SUB="$SCRATCH/sub/dir"; mkdir -p "$SUB"
git -C "$SCRATCH" init -q
GITDIR2="$(git -C "$SCRATCH" rev-parse --absolute-git-dir)"
( cd "$SUB" && env -u AGENT_LOCK_DIR -u AGENT_LOCK_LOG \
    bash "$SH" run -- bash -c '[ -d "$1/commit.lock" ]' _ "$GITDIR2" ); rc=$?
[ "$rc" = 0 ] && ok "bash (from repo subdir, defaults): lock held at <gitdir>/commit.lock" || bad "bash default lock not at $GITDIR2/commit.lock (rc=$rc)"
( cd "$SUB" && env -u AGENT_LOCK_DIR -u AGENT_LOCK_LOG \
    pwsh -NoProfile -File "$PS1WIN" run "if (Test-Path -LiteralPath '$GITDIR2/commit.lock') { exit 0 } else { exit 33 }" ); rc=$?
[ "$rc" = 0 ] && ok "pwsh (from repo subdir, defaults): lock held at <gitdir>/commit.lock" || bad "pwsh default lock not at $GITDIR2/commit.lock (rc=$rc)"
DLOG="$GITDIR2/git-commit-lock.log"
na="$(grep -c ACQUIRED "$DLOG" 2>/dev/null)"
nps="$(grep -c "ACQUIRED.*tok=tok\.ps\." "$DLOG" 2>/dev/null)"
[ "$na" = 2 ] && [ "$nps" = 1 ] \
  && ok "shared <gitdir> log shows 1 bash + 1 pwsh acquisition" \
  || bad "default-log evidence wrong: ACQUIRED=$na (want 2), pwsh tokens=$nps (want 1) in $DLOG"
[ -e "$GITDIR2/commit.lock" ] && bad "leftover default lock" || ok "no leftover default lock"

echo "== Test 11: missing token at release — BOTH impls take the unverifiable lane (exit 1, not 98) =="
# Lock dir present, token file ABSENT at release: neither impl can prove its
# own acquire-time token write succeeded (both swallow write failures after
# retries), so neither may call this state a theft. Aligned contract: `run`
# fails a successful command with exit 1 (exclusivity unproven), leaves the
# dir for the stale window, and does NOT exit 98. Locks the alignment in —
# the bash lane itself is unit-tested; this asserts cross-impl agreement.
LOCK="$WORK/nt.lock"; LOG="$WORK/nt.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  bash "$SH" run -- bash -c 'rm -f "$AGENT_LOCK_DIR/token"' 2> "$WORK/nt-sh.err"; rc_sh=$?
sh_dir_left=$([ -d "$LOCK" ] && echo yes || echo no)
rm -rf "$LOCK"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "Remove-Item -LiteralPath '$LOCK/token' -Force" 2> "$WORK/nt-ps.err"; rc_ps=$?
ps_dir_left=$([ -d "$LOCK" ] && echo yes || echo no)
rm -rf "$LOCK"
[ "$rc_sh" = 1 ] && ok "bash: missing token -> exit 1 (unverifiable), not 98" || bad "bash missing-token rc=$rc_sh (want 1)"
[ "$rc_ps" = 1 ] && ok "pwsh: missing token -> exit 1 (unverifiable), not 98" || bad "pwsh missing-token rc=$rc_ps (want 1)"
[ "$sh_dir_left" = yes ] && [ "$ps_dir_left" = yes ] \
  && ok "both impls left the dir for the stale window to reclaim" \
  || bad "dir left in place: bash=$sh_dir_left pwsh=$ps_dir_left (want yes/yes)"

echo "== Test 12: fractional STALE/MAX_WAIT rejected identically by both impls (note + default) =="
# These two knobs are integers in both impls; a fractional value silently
# rounded by one side but rejected by the other would give the two impls
# DIFFERENT steal thresholds for the same env. Both must note + use defaults.
LOCK="$WORK/frac.lock"; LOG="$WORK/frac.log"; : > "$LOG"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2.5 AGENT_LOCK_MAX_WAIT=10.5 \
  bash "$SH" run -- bash -c 'true' 2> "$WORK/frac-sh.err"; rc_sh=$?
n_sh="$(grep -c 'ignoring invalid' "$WORK/frac-sh.err")"
[ "$rc_sh" = 0 ] && [ "$n_sh" = 2 ] \
  && ok "bash rejects fractional STALE/MAX_WAIT with notes (rc 0, 2 notes)" \
  || bad "bash fractional knobs: rc=$rc_sh notes=$n_sh (want 0/2)"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2.5 AGENT_LOCK_MAX_WAIT=10.5 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/frac-ps.err"; rc_ps=$?
n_ps="$(grep -c 'ignoring invalid' "$WORK/frac-ps.err")"
[ "$rc_ps" = 0 ] && [ "$n_ps" = 2 ] \
  && ok "pwsh rejects fractional STALE/MAX_WAIT with notes (rc 0, 2 notes)" \
  || bad "pwsh fractional knobs: rc=$rc_ps notes=$n_ps (want 0/2)"

echo
echo "==== INTEROP RESULT: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
