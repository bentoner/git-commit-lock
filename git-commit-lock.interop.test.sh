#!/usr/bin/env bash
# git-commit-lock.interop.test.sh
#
# Cross-implementation test: proves git-commit-lock.ps1 (PowerShell) and
# git-commit-lock.sh (bash) share ONE lock FILE and serialise against EACH
# OTHER in the same working tree, and that the .ps1 side honours the shared
# behavioural contract (exit-code propagation; 97 timeout; 98 stolen mid-hold;
# steal of genuinely stale locks; <gitdir>/commit.lock default location;
# identical release-classification and numeric-knob verdicts; the never-steal
# guards for non-lock objects at the lock path). On Windows, run from
# MINGW/Git-Bash — NOT from WSL — because both sides must agree on the lock
# path in `C:/...` form. Spawns pwsh + bash workers, so it needs both on PATH.
# A Windows PowerShell 5.1 smoke lane (Test 17) additionally runs when
# `powershell` is on PATH (i.e. on Windows; skipped with a note elsewhere).
#   bash ~/.local/bin/git-commit-lock.interop.test.sh
# Exit 0 == all pass. Uses a throwaway temp dir; never touches your repo.
#
# Fan-out: the heavy concurrency tests (T1/T6) default to REDUCED width so
# routine dev runs don't lag a live shared machine; set GCL_TEST_FULL=1 (CI
# does) for the full-strength canary. The suite prints which mode ran — a
# reduced pass must never masquerade as the full one.
#
# The blocked-release/blocked-steal tests (T13/T14/T14b) are WINDOWS-ONLY by
# nature: they manufacture blocking via a no-delete-share file handle, and on
# POSIX open handles never block unlink/rename (.NET's Unix FileShare is
# advisory among .NET openers and gates no namespace operation), so there
# they are skipped with a note.
#
# On failure the temp dir is PRESERVED (path printed) for post-mortem; set
# GCL_TEST_PRESERVE_DIR=<dir> to always copy the work dir (logs etc.) there.
#
# shellcheck disable=SC2015  # The pervasive `<assert> && ok ... || bad ...`
# idiom is deliberate throughout: ok/bad are echo+counter helpers that cannot
# fail, so the classic A && B || C pitfall (C running after B fails) is moot.
# shellcheck disable=SC2310,SC2312  # info-level, deliberate: helper functions
# and command substitutions run inside conditions all over a test suite; the
# suite runs WITHOUT errexit (set -uo only) and asserts on values, not on
# implicit exit propagation.
# shellcheck disable=SC2016  # single-quoted command strings are deliberate:
# they expand inside a worker's `bash -c` or pwsh invocation, not here.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/git-commit-lock.sh"
PS1WIN="$(cygpath -w "$DIR/git-commit-lock.ps1" 2>/dev/null || echo "$DIR/git-commit-lock.ps1")"
PS1WIN="${PS1WIN//\\//}"   # forward slashes: both pwsh and mingw accept C:/...

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 0; }

if [ "${GCL_TEST_FULL:-0}" = 1 ]; then
  GCL_MODE="FULL"; T1_NSH=8; T1_NPS=8; T6_NCS=6; T6_NCP=6
else
  GCL_MODE="REDUCED"; T1_NSH=4; T1_NPS=4; T6_NCS=3; T6_NCP=3
fi
echo "fan-out mode: $GCL_MODE (T1 ${T1_NSH}+${T1_NPS} mixed workers, T6 ${T6_NCS}+${T6_NCP} counter workers)"
[ "$GCL_MODE" = REDUCED ] && echo "  (set GCL_TEST_FULL=1 for the full-strength canary — CI runs it)"

# The blocked-release/steal tests need Windows mandatory-share semantics.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) GCL_WINDOWS=1 ;;
  *)                    GCL_WINDOWS=0 ;;
esac

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

# Wait (up to $3 seconds, default 15) for a pattern to appear in a file —
# used to gate on the WAITING log line (proof a waiter actually contended)
# without a fixed-length hold. Same helper as the unit suite.
wait_for_grep() {
  local pat="$1" f="$2" tries=$(( ${3:-15} * 20 ))
  while ! grep -q "$pat" "$f" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
  grep -q "$pat" "$f" 2>/dev/null
}

# Backdate a path's mtime by $2 seconds — how a test fakes a stale lock (the
# staleness clock is the lock FILE's own mtime, stamped by the creating
# write). Portable: BSD/macOS touch has no `-d @epoch`, so convert the target
# epoch to a `touch -t` stamp via GNU `date -d @` with BSD `date -r` as
# fallback (same helper as the unit suite).
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

# A pwsh process that holds the lock FILE open with FileShare.Read — the
# no-delete-share handle class that blocks unlink AND rename alike (probe
# D1; what a naive ReadAllText reader or an AV scanner holds). Touches the
# ready marker once the handle is open, holds it until the go marker appears,
# then disposes. Windows-only semantics (on POSIX such a handle blocks
# neither op).
hold_handle() {  # $1=file $2=ready-marker $3=go-marker
  pwsh -NoProfile -Command "
    \$fs = [System.IO.File]::Open('$1', [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    [System.IO.File]::WriteAllText('$2', 'r')
    while (-not (Test-Path -LiteralPath '$3')) { Start-Sleep -Milliseconds 50 }
    \$fs.Dispose()
  "
}

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
  AGENT_LOCK_PATH="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
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
  AGENT_LOCK_PATH="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
    pwsh -NoProfile -File "$PS1WIN" run "$body"
}

echo "== Test 1: mixed pwsh+bash workers, mutual exclusion across implementations ($GCL_MODE width) =="
NSH=$T1_NSH; NPS=$T1_NPS; TOT=$((NSH+NPS))
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
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$SH" run -- bash -c ': > "$2"; echo sh-start >> "$1"; sleep 2; echo sh-end >> "$1"' _ "$ORDER" "$READY" &
holder=$!
# Launch the waiter only once the holder demonstrably HOLDS the lock (ready
# marker written inside the critical section) — a fixed head-start sleep would
# race pwsh/bash cold-start times under load.
wait_for "$READY" || bad "T2 holder never signalled ready"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::AppendAllText('$ORDER','ps-ran' + [char]10)"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "sh-start,sh-end,ps-ran," ] && ok "bash-holds / pwsh-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "pwsh wrongly STOLE a live bash lock" || ok "pwsh did not steal the live bash lock"

echo "== Test 3: a pwsh holder blocks a bash waiter =="
LOCK="$WORK/b3.lock"; LOG="$WORK/b3.log"; : > "$LOG"; ORDER="$WORK/b3.order"; : > "$ORDER"
READY="$WORK/b3.ready"; rm -f "$READY"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$READY','r'); [IO.File]::AppendAllText('$ORDER','ps-start' + [char]10); Start-Sleep 2; [IO.File]::AppendAllText('$ORDER','ps-end' + [char]10)" &
holder=$!
wait_for "$READY" || bad "T3 holder never signalled ready"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$SH" run -- bash -c 'echo sh-ran >> "$1"' _ "$ORDER"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "ps-start,ps-end,sh-ran," ] && ok "pwsh-holds / bash-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "bash wrongly STOLE a live pwsh lock" || ok "bash did not steal the live pwsh lock"

echo "== Test 4: pwsh steals a STALE lock fabricated as bash's (old file mtime) =="
# AGENT_LOCK_MAX_WAIT caps the run so a steal regression fails in ~20s, not 420s.
LOCK="$WORK/b4.lock"; LOG="$WORK/b4.log"; : > "$LOG"; MARK="$WORK/b4.mark"; printf '%s' before > "$MARK"
fabricate_lock "$LOCK" "tok.sh.ghost.1" "pid=99999 host=ghost"
backdate "$LOCK" 9999                           # ancient file mtime -> stale
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$MARK','after')"; rc=$?
[ "$rc" = 0 ] && ok "pwsh run exited 0 after stealing bash's stale lock" || bad "pwsh run exited $rc"
[ "$(cat "$MARK")" = after ] && ok "stale bash lock stolen, pwsh command ran" || bad "marker=$(cat "$MARK")"
grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"
grep -q "holder=pid=99999 host=ghost" "$LOG" \
  && ok "STALE log line carries the holder parsed from line 2 (cross-impl wire format)" \
  || bad "holder from line 2 missing in pwsh's STALE log line"

echo "== Test 5: bash steals a STALE lock GENUINELY created by pwsh (holder killed mid-hold) =="
# The stale lock really is pwsh's: a pwsh process dot-sources the lock, acquires,
# signals ready, then is hard-killed by PID mid-hold (TerminateProcess — no
# release, no exit event), leaving its live lock FILE (token line 1) behind.
LOCK="$WORK/b5.lock"; LOG="$WORK/b5.log"; : > "$LOG"; MARK="$WORK/b5.mark"; printf '%s' before > "$MARK"
READY="$WORK/b5.ready"; rm -f "$READY"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  pwsh -NoProfile -Command ". '$PS1WIN'; Lock-Acquire | Out-Null; [IO.File]::WriteAllText('$READY','r'); Start-Sleep 60" &
hpid=$!
if wait_for "$READY"; then
  kill -9 "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  sleep 0.3
  tok="$(head -n 1 "$LOCK" 2>/dev/null | tr -d '\r\n')"
  case "$tok" in
    tok.ps.*) ok "dead pwsh holder left its own lock file behind (token $tok)" ;;
    *)        bad "expected a tok.ps.* token on line 1 of the orphan lock, got '$tok'" ;;
  esac
  backdate "$LOCK" 9999                           # age the orphan past any stale window
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
    bash "$SH" run -- bash -c 'printf "%s" after > "$1"' _ "$MARK"; rc=$?
  [ "$rc" = 0 ] && ok "bash run exited 0 after stealing pwsh's stale lock" || bad "bash run exited $rc"
  [ "$(cat "$MARK")" = after ] && ok "stale pwsh lock stolen, bash command ran" || bad "marker=$(cat "$MARK")"
  grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"
else
  kill -9 "$hpid" 2>/dev/null; wait "$hpid" 2>/dev/null
  bad "T5 pwsh holder never acquired/signalled ready"
fi

echo "== Test 6: deterministic lost-update counter, mixed bash+pwsh increments ($GCL_MODE width) =="
# The deterministic complement to Test 1's exclusion probe (which has a blind
# window and tolerates launch flakiness): every worker MUST launch (strict rc
# checks) and the final counter MUST equal the total increments — any lost
# update or failed worker fails the test.
NCS=$T6_NCS; NCP=$T6_NCP; CTOT=$((NCS+NCP))
LOCK="$WORK/cnt.lock"
CNT="$WORK/counter"; printf '%s' 0 > "$CNT"
# Read-gap-write under the lock; reads/writes retry on transient Windows
# sharing violations (a previous holder's lingering handle), and a worker whose
# retry budget is exhausted exits 9 so the failure is loud, not a silent miss.
# Per-worker lock logs for the same reason as Test 1.
count_sh() {  # $1=id
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/cnt-$1.log" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
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
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$WORK/cnt-$1.log" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 AGENT_LOCK_MAX_WAIT=120 \
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

echo "== Test 7: pwsh run propagates the command's exit code (two contending runs in parallel) =="
LOCK="$WORK/rc.lock"; LOG="$WORK/rc.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" & p0=$!
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=60 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 7" & p7=$!
wait "$p0"; rc0=$?
wait "$p7"; rc7=$?
[ "$rc0" = 0 ] && ok "pwsh exit 0 propagated" || bad "pwsh exit 0 not propagated (rc=$rc0)"
[ "$rc7" = 7 ] && ok "pwsh exit 7 propagated" || bad "pwsh exit code not propagated ($rc7)"
[ -e "$LOCK" ] && bad "lock left held after pwsh run" || ok "lock released after pwsh run (success and failure)"

echo "== Test 7b: ps1 run verdicts for PowerShell-NATIVE failure (regression: F2 — failing cmdlet exited 0) =="
# A cmdlet's non-terminating error never sets LASTEXITCODE, so the old
# runner (which reported only LASTEXITCODE) returned 0 for a failed command.
# The fix consults the staged script's FINAL '$?' when no nonzero native code
# was set. Verdict pins: failing cmdlet -> 1; succeeding cmdlet -> 0; a
# native command's nonzero code still propagates verbatim; LASTEXITCODE=0
# from an earlier native step does NOT mask a failing final cmdlet; and the
# documented final-statement-only limitation (mid-command cmdlet failure
# followed by a succeeding final statement -> 0) is pinned as the contract.
LOCK="$WORK/f2.lock"; LOG="$WORK/f2.log"; : > "$LOG"
NOSUCH="$WORK/no-such-file-f2"   # portable nonexistent path (POSIX legs included)
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "Get-Item -LiteralPath '$NOSUCH'" 2> "$WORK/f2.err"; rc=$?
[ "$rc" = 1 ] && ok "failing cmdlet -> exit 1 (was 0 pre-fix)" || bad "failing cmdlet rc=$rc (want 1)"
grep -q "without a native exit code" "$WORK/f2.err" \
  && ok "stderr carries the one-line no-native-exit-code note" \
  || bad "missing the no-native-exit-code note on stderr"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "Get-Date | Out-Null"; rc=$?
[ "$rc" = 0 ] && ok "succeeding cmdlet -> exit 0" || bad "succeeding cmdlet rc=$rc (want 0)"
# Native nonzero still wins: assert the ps1-run code EQUALS what the same git
# command exits with directly (no hardcoded 128 — git's code, whatever it is).
git -C "$WORK/definitely-not-a-repo-f2" status >/dev/null 2>&1; want=$?
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "git -C '$WORK/definitely-not-a-repo-f2' status" 2>/dev/null; rc=$?
[ "$rc" = "$want" ] && [ "$want" != 0 ] \
  && ok "git failure's native code still propagates verbatim ($rc)" \
  || bad "git-failure propagation: ps1 run rc=$rc, direct git rc=$want (want equal, nonzero)"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "git --version | Out-Null; Get-Item -LiteralPath '$NOSUCH'" 2>/dev/null; rc=$?
[ "$rc" = 1 ] && ok "LASTEXITCODE=0 from an earlier git does not mask a failing final cmdlet (exit 1)" \
              || bad "git-ok-then-failing-cmdlet rc=$rc (want 1)"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "Get-Item -LiteralPath '$NOSUCH'; git --version | Out-Null" 2>/dev/null; rc=$?
[ "$rc" = 0 ] && ok "mid-command cmdlet failure + succeeding final statement -> 0 (the documented final-statement limitation)" \
              || bad "limitation pin: rc=$rc (want 0 — has the final-statement contract changed?)"
[ -e "$LOCK" ] && bad "lock left held after the F2 verdict runs" || ok "no leftover lock after the F2 verdict runs"

echo "== Test 7c: ps1 CLI help/usage convention — explicit help -> stdout + exit 0; usage errors -> stderr + 96 (F6d) =="
# (bash's side of the same convention is pinned in the unit suite, Test 7.)
for h in --help -h; do
  pwsh -NoProfile -File "$PS1WIN" "$h" > "$WORK/t7c.out" 2> "$WORK/t7c.err"; rc=$?
  [ "$rc" = 0 ] && grep -q '^usage:' "$WORK/t7c.out" && [ ! -s "$WORK/t7c.err" ] \
    && ok "ps1 $h -> usage on stdout, exit 0, stderr empty" \
    || bad "ps1 $h rc=$rc (want 0) stdout-usage=$(grep -c '^usage:' "$WORK/t7c.out") stderr=$(head -c 60 "$WORK/t7c.err")"
done
# -? is intercepted by the ENGINE as the common help parameter before it can
# reach the script (auto-generated syntax on stdout; probed pwsh 7.5 + 5.1),
# so only the convention's exit code is pinned here; the script handles a
# positionally-delivered '-?' identically to --help.
pwsh -NoProfile -File "$PS1WIN" '-?' >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "ps1 -? exits 0 (engine help interception)" || bad "ps1 -? rc=$rc (want 0)"
pwsh -NoProfile -File "$PS1WIN" > "$WORK/t7c-noargs.out" 2> "$WORK/t7c-noargs.err"; rc=$?
[ "$rc" = 96 ] && grep -q '^usage:' "$WORK/t7c-noargs.err" && [ ! -s "$WORK/t7c-noargs.out" ] \
  && ok "ps1 no args -> 96 with usage on stderr, stdout empty" \
  || bad "ps1 no-args rc=$rc (want 96) stderr-usage=$(grep -c '^usage:' "$WORK/t7c-noargs.err")"
pwsh -NoProfile -File "$PS1WIN" frobnicate >/dev/null 2>&1; rc=$?
[ "$rc" = 96 ] && ok "ps1 unknown subcommand -> 96" || bad "ps1 unknown subcommand rc=$rc (want 96)"

echo "== Test 8: a ROBBED holder exits 98 — pwsh victim/bash thief, then bash victim/pwsh thief =="
# Fail-open ceiling, cross-impl: the victim holds past its 1s stale window
# UNTIL THE THIEF IS DONE (marker, not a fixed sleep — a fixed hold once let a
# slow-starting thief arrive after the victim had already released), the other
# implementation steals, and the victim's release detects the theft and exits
# 98 (the reserved stolen-mid-hold code) while the thief exits 0.
LOCK="$WORK/rob1.lock"; LOG="$WORK/rob1.log"; : > "$LOG"
READY="$WORK/rob1.ready"; TDONE="$WORK/rob1.tdone"; rm -f "$READY" "$TDONE"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$READY','r'); while (-not (Test-Path -LiteralPath '$TDONE')) { Start-Sleep -Milliseconds 100 }" 2>/dev/null &
vic=$!
wait_for "$READY" || bad "T8a pwsh victim never signalled ready"
# The thief polls until the victim's 1s lease goes stale, then steals.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$SH" run -- bash -c 'true'; thief_rc=$?
touch "$TDONE"
wait "$vic"; vic_rc=$?
[ "$vic_rc" = 98 ] && ok "robbed pwsh holder exited 98" || bad "robbed pwsh holder exited $vic_rc (want 98)"
[ "$thief_rc" = 0 ] && ok "bash thief exited 0" || bad "bash thief exited $thief_rc"
grep -q "WARNING" "$LOG" && ok "theft WARNING logged" || bad "no theft WARNING in log"

LOCK="$WORK/rob2.lock"; LOG="$WORK/rob2.log"; : > "$LOG"
READY="$WORK/rob2.ready"; TDONE="$WORK/rob2.tdone"; rm -f "$READY" "$TDONE"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  bash "$SH" run -- bash -c ': > "$1"; until [ -e "$2" ]; do sleep 0.1; done' _ "$READY" "$TDONE" 2>/dev/null &
vic=$!
wait_for "$READY" || bad "T8b bash victim never signalled ready"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0"; thief_rc=$?
touch "$TDONE"
wait "$vic"; vic_rc=$?
[ "$vic_rc" = 98 ] && ok "robbed bash holder exited 98" || bad "robbed bash holder exited $vic_rc (want 98)"
[ "$thief_rc" = 0 ] && ok "pwsh thief exited 0" || bad "pwsh thief exited $thief_rc"

echo "== Test 9: a slow but UNCONTENDED pwsh holder keeps its lock (slowness != failure) =="
LOCK="$WORK/slow.lock"; LOG="$WORK/slow.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=30 \
  pwsh -NoProfile -File "$PS1WIN" run "Start-Sleep 2"; rc=$?
[ "$rc" = 0 ] && ok "uncontended slow pwsh holder exited 0" || bad "uncontended slow pwsh holder exited $rc"
grep -q "WARNING" "$LOG" && bad "spurious theft WARNING with no contender" || ok "no spurious WARNING when uncontended"

echo "== Test 10: default lock location is <gitdir>/commit.lock for BOTH impls (regression: item 1) =="
# The BLOCKER this guards against: the .ps1 silently fell back to a CWD lock at
# default config, so the two impls never contended. Run BOTH impls from a
# SUBDIRECTORY of a scratch repo with AGENT_LOCK_PATH/LOG unset; each command
# probes (while holding) that the lock FILE really is <gitdir>/commit.lock, and
# the shared <gitdir> log must record one ACQUIRED from each side.
SCRATCH="$WORK/scratch"; SUB="$SCRATCH/sub/dir"; mkdir -p "$SUB"
git -C "$SCRATCH" init -q
GITDIR2="$(git -C "$SCRATCH" rev-parse --absolute-git-dir)"
( cd "$SUB" && env -u AGENT_LOCK_PATH -u AGENT_LOCK_LOG \
    bash "$SH" run -- bash -c '[ -f "$1/commit.lock" ]' _ "$GITDIR2" ); rc=$?
[ "$rc" = 0 ] && ok "bash (from repo subdir, defaults): lock FILE held at <gitdir>/commit.lock" || bad "bash default lock not at $GITDIR2/commit.lock (rc=$rc)"
( cd "$SUB" && env -u AGENT_LOCK_PATH -u AGENT_LOCK_LOG \
    pwsh -NoProfile -File "$PS1WIN" run "if (Test-Path -LiteralPath '$GITDIR2/commit.lock' -PathType Leaf) { exit 0 } else { exit 33 }" ); rc=$?
[ "$rc" = 0 ] && ok "pwsh (from repo subdir, defaults): lock FILE held at <gitdir>/commit.lock" || bad "pwsh default lock not at $GITDIR2/commit.lock (rc=$rc)"
DLOG="$GITDIR2/git-commit-lock.log"
na="$(grep -c ACQUIRED "$DLOG" 2>/dev/null)"
nps="$(grep -c "ACQUIRED.*tok=tok\.ps\." "$DLOG" 2>/dev/null)"
[ "$na" = 2 ] && [ "$nps" = 1 ] \
  && ok "shared <gitdir> log shows 1 bash + 1 pwsh acquisition" \
  || bad "default-log evidence wrong: ACQUIRED=$na (want 2), pwsh tokens=$nps (want 1) in $DLOG"
[ -e "$GITDIR2/commit.lock" ] && bad "leftover default lock" || ok "no leftover default lock"

echo "== Test 11: release-time classification agrees across impls — truncated => unverifiable (1); deleted => theft (98) =="
# (i) TRUNCATED at release: the file still exists but reads EMPTY after the
# retry ladder. NOT provable theft (it is the probe-F create->write window of
# a successor after a boundary steal, or external truncation), so BOTH impls
# take the unverifiable lane: `run` fails a successful command with exit 1
# (not 98) and the file is LEFT in place for the staleness backstop.
LOCK="$WORK/nt.lock"; LOG="$WORK/nt.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  bash "$SH" run -- bash -c ': > "$AGENT_LOCK_PATH"' 2> "$WORK/nt-sh.err"; rc_sh=$?
sh_left=$([ -f "$LOCK" ] && echo yes || echo no)
rm -f "$LOCK"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$LOCK','')" 2> "$WORK/nt-ps.err"; rc_ps=$?
ps_left=$([ -f "$LOCK" ] && echo yes || echo no)
rm -f "$LOCK"
[ "$rc_sh" = 1 ] && ok "bash: truncated lock -> exit 1 (unverifiable), not 98" || bad "bash truncated-lock rc=$rc_sh (want 1)"
[ "$rc_ps" = 1 ] && ok "pwsh: truncated lock -> exit 1 (unverifiable), not 98" || bad "pwsh truncated-lock rc=$rc_ps (want 1)"
[ "$sh_left" = yes ] && [ "$ps_left" = yes ] \
  && ok "both impls left the file for the staleness backstop to reclaim" \
  || bad "file left in place: bash=$sh_left pwsh=$ps_left (want yes/yes)"
# (ii) DELETED at release: acquire's read-back proved our token was AT the
# path, so a GONE file is definitive displacement — BOTH impls exit 98 (the
# cross-impl gone=>theft agreement; the dir era classed this unverifiable).
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  bash "$SH" run -- bash -c 'rm -f -- "$AGENT_LOCK_PATH"' 2>/dev/null; rc_sh=$?
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=20 \
  pwsh -NoProfile -File "$PS1WIN" run "Remove-Item -LiteralPath '$LOCK' -Force" 2>/dev/null; rc_ps=$?
[ "$rc_sh" = 98 ] && ok "bash: lock GONE at release -> exit 98 (theft)" || bad "bash gone-at-release rc=$rc_sh (want 98)"
[ "$rc_ps" = 98 ] && ok "pwsh: lock GONE at release -> exit 98 (theft)" || bad "pwsh gone-at-release rc=$rc_ps (want 98)"

echo "== Test 12: fractional STALE/MAX_WAIT rejected identically by both impls (note + default) =="
# These two knobs are integers in both impls; a fractional value silently
# rounded by one side but rejected by the other would give the two impls
# DIFFERENT steal thresholds for the same env. Both must note + use defaults.
LOCK="$WORK/frac.lock"; LOG="$WORK/frac.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2.5 AGENT_LOCK_MAX_WAIT=10.5 \
  bash "$SH" run -- bash -c 'true' 2> "$WORK/frac-sh.err"; rc_sh=$?
n_sh="$(grep -c 'ignoring invalid' "$WORK/frac-sh.err")"
[ "$rc_sh" = 0 ] && [ "$n_sh" = 2 ] \
  && ok "bash rejects fractional STALE/MAX_WAIT with notes (rc 0, 2 notes)" \
  || bad "bash fractional knobs: rc=$rc_sh notes=$n_sh (want 0/2)"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2.5 AGENT_LOCK_MAX_WAIT=10.5 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/frac-ps.err"; rc_ps=$?
n_ps="$(grep -c 'ignoring invalid' "$WORK/frac-ps.err")"
[ "$rc_ps" = 0 ] && [ "$n_ps" = 2 ] \
  && ok "pwsh rejects fractional STALE/MAX_WAIT with notes (rc 0, 2 notes)" \
  || bad "pwsh fractional knobs: rc=$rc_ps notes=$n_ps (want 0/2)"
# POLL_SECS takes the shared digits-with-at-most-one-dot grammar; .NET's
# TryParse(Float) is wider (exponents, signs), so without the ps1 raw-shape
# gate the same env var would configure DIFFERENT poll intervals across the
# two impls (e.g. POLL_SECS=1e3: bash rejects -> default 2s; an ungated parse
# accepts -> one poll every 1000s). Both impls must reject these identically.
# Also pinned (round-2 review findings 2/3): a TRAILING-NEWLINE value ($'5\n'
# — .NET's $ matches before a final newline and TryParse tolerates trailing
# whitespace, so an unanchored ps1 gate accepted what bash rejects) and a
# WHITESPACE-ONLY value ('   ' — non-empty, so bash notes it; ps1's old
# IsNullOrWhiteSpace early-return silently defaulted instead). Contract:
# EMPTY => silent default in both; whitespace-only / any other non-empty
# invalid => note + default in both.
for v in 1e3 +2 '   ' $'5\n'; do
  vl="$(printf '%q' "$v")"   # display label: keeps newline/space values on one line
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_POLL_SECS="$v" \
    bash "$SH" run -- bash -c 'true' 2> "$WORK/poll-sh.err"; rc_sh=$?
  n_sh="$(grep -c 'ignoring invalid AGENT_LOCK_POLL_SECS' "$WORK/poll-sh.err")"
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_POLL_SECS="$v" \
    pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/poll-ps.err"; rc_ps=$?
  n_ps="$(grep -c 'ignoring invalid AGENT_LOCK_POLL_SECS' "$WORK/poll-ps.err")"
  if [ "$rc_sh" = 0 ] && [ "$n_sh" = 1 ] && [ "$rc_ps" = 0 ] && [ "$n_ps" = 1 ]; then
    ok "POLL_SECS=$vl rejected with a note + default by BOTH impls"
  else
    bad "POLL_SECS=$vl: sh rc=$rc_sh notes=$n_sh; pwsh rc=$rc_ps notes=$n_ps (want rc 0 + 1 note each)"
  fi
done
# The EMPTY boundary of that contract: set-but-empty means "use the default"
# SILENTLY in both impls (bash's ${VAR:-} fills it before the validator ever
# runs; ps1's IsNullOrEmpty early-return mirrors that) - no note, rc 0.
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_POLL_SECS='' \
  bash "$SH" run -- bash -c 'true' 2> "$WORK/poll-sh.err"; rc_sh=$?
n_sh="$(grep -c 'ignoring invalid' "$WORK/poll-sh.err")"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_POLL_SECS='' \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/poll-ps.err"; rc_ps=$?
n_ps="$(grep -c 'ignoring invalid' "$WORK/poll-ps.err")"
[ "$rc_sh" = 0 ] && [ "$n_sh" = 0 ] && [ "$rc_ps" = 0 ] && [ "$n_ps" = 0 ] \
  && ok "POLL_SECS='' (empty): silent default in BOTH impls (no note)" \
  || bad "POLL_SECS='' parity: sh rc=$rc_sh notes=$n_sh; pwsh rc=$rc_ps notes=$n_ps (want rc 0 + 0 notes each)"

if [ "$GCL_WINDOWS" = 1 ]; then

echo "== Test 13: blocked release (no-delete-share handle) — deterministic LEFTOVER, run keeps the command's code, then recovery =="
# Probe D1 made this lane deterministically testable (TODO #30): a pwsh
# FileShare.Read handle on the lock file blocks the release unlink (and any
# steal rename) until it closes. (a) sourced bash: lock_release returns 1 and
# leaves the file; (b) `run`: the wrapped command's own exit code survives a
# leftover (cleanup failure, not a serialisation failure); (c) ps1 dot-source:
# Lock-Release returns $false with LockReleaseStatus='leftover'; (d) recovery:
# once the handle closes AND the stale window has elapsed, a waiter steals the
# leftover and proceeds.
LOCK="$WORK/lo.lock"; LOG="$WORK/lo.log"; : > "$LOG"
HREADY="$WORK/lo.hready"; HGO="$WORK/lo.hgo"; BREADY="$WORK/lo.bready"; BGO="$WORK/lo.bgo"; RCF="$WORK/lo.rc"
rm -f "$HREADY" "$HGO" "$BREADY" "$BGO" "$RCF"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" bash -c '
  source "$1" || exit 70
  lock_acquire || exit 72
  : > "$2"
  until [ -e "$3" ]; do sleep 0.05; done
  lock_release 2>/dev/null
  echo "$?" > "$4"
' _ "$SH" "$HREADY" "$HGO" "$RCF" &
hold13=$!
if wait_for "$HREADY"; then
  hold_handle "$LOCK" "$BREADY" "$BGO" &
  blk13=$!
  if wait_for "$BREADY" 400; then
    touch "$HGO"
    wait "$hold13"
    rc="$(cat "$RCF" 2>/dev/null || echo missing)"
    [ "$rc" = 1 ] && ok "blocked release: sourced lock_release returned 1 (LEFTOVER)" \
                  || bad "blocked release: sourced lock_release rc=$rc (want 1)"
    [ -f "$LOCK" ] && ok "leftover lock file left in place" || bad "lock file gone despite the blocked delete"
    grep -q "LEFTOVER" "$LOG" && ok "leftover WARNING logged" || bad "no LEFTOVER warning in log"
  else
    touch "$HGO"; wait "$hold13"
    bad "T13 pwsh blocker never signalled its handle open"
  fi
else
  bad "T13 bash holder never acquired"
fi
# (b) `run` keeps the wrapped command's own exit code over a leftover release.
LOCK2="$WORK/lo2.lock"
HREADY2="$WORK/lo2.hready"; HGO2="$WORK/lo2.hgo"; BREADY2="$WORK/lo2.bready"; BGO2="$WORK/lo2.bgo"
rm -f "$HREADY2" "$HGO2" "$BREADY2" "$BGO2"
AGENT_LOCK_PATH="$LOCK2" AGENT_LOCK_LOG="$LOG" \
  bash "$SH" run -- bash -c ': > "$1"; until [ -e "$2" ]; do sleep 0.05; done; exit 5' _ "$HREADY2" "$HGO2" 2>/dev/null &
run13=$!
if wait_for "$HREADY2"; then
  hold_handle "$LOCK2" "$BREADY2" "$BGO2" &
  blk13b=$!
  if wait_for "$BREADY2" 400; then
    touch "$HGO2"
    wait "$run13"; rc=$?
    [ "$rc" = 5 ] && ok "run kept the command's own exit code (5) over the leftover release" \
                  || bad "run leftover rc=$rc (want the command's 5)"
    touch "$BGO2"; wait "$blk13b"
  else
    touch "$HGO2"; wait "$run13"
    bad "T13b pwsh blocker never signalled its handle open"
  fi
else
  bad "T13b run holder never acquired"
fi
rm -f "$LOCK2"
# (c) ps1 side: Lock-Release -> $false with LockReleaseStatus='leftover'.
LOCK3="$WORK/lo3.lock"
PREADY="$WORK/lo3.pready"; PGO="$WORK/lo3.pgo"; BREADY3="$WORK/lo3.bready"; BGO3="$WORK/lo3.bgo"
rm -f "$PREADY" "$PGO" "$BREADY3" "$BGO3"
AGENT_LOCK_PATH="$LOCK3" AGENT_LOCK_LOG="$LOG" pwsh -NoProfile -Command "
  . '$PS1WIN'
  if (-not (Lock-Acquire)) { exit 72 }
  [System.IO.File]::WriteAllText('$PREADY', 'r')
  while (-not (Test-Path -LiteralPath '$PGO')) { Start-Sleep -Milliseconds 50 }
  \$r = Lock-Release
  if ((-not \$r) -and \$script:LockReleaseStatus -eq 'leftover') { exit 0 }
  exit 31
" 2>/dev/null &
ps13=$!
if wait_for "$PREADY" 400; then
  hold_handle "$LOCK3" "$BREADY3" "$BGO3" &
  blk13c=$!
  if wait_for "$BREADY3" 400; then
    touch "$PGO"
    wait "$ps13"; rc=$?
    [ "$rc" = 0 ] && ok "ps1 blocked release: Lock-Release false with LockReleaseStatus='leftover'" \
                  || bad "ps1 blocked release: probe exited $rc (want 0)"
    [ -f "$LOCK3" ] && ok "ps1 leftover lock file left in place" || bad "ps1 lock file gone despite the blocked delete"
    touch "$BGO3"; wait "$blk13c"
  else
    touch "$PGO"; wait "$ps13"
    bad "T13c pwsh blocker never signalled its handle open"
  fi
else
  bad "T13c ps1 holder never acquired"
fi
rm -f "$LOCK3"
# (d) recovery of (a)'s leftover: needs the handle CLOSED (same handle blocks
# the steal rename) AND the stale window elapsed — then a waiter steals it.
touch "$BGO" 2>/dev/null; wait "$blk13" 2>/dev/null
backdate "$LOCK" 9999 2>/dev/null
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=20 \
  bash "$SH" run -- bash -c 'true'; rc=$?
[ "$rc" = 0 ] && ok "leftover reclaimed once the handle closed + stale window elapsed (TODO #30 lane)" \
              || bad "leftover recovery rc=$rc (want 0)"
grep -q STOLE "$LOG" && ok "recovery steal logged" || bad "no STOLE entry during leftover recovery"

echo "== Test 14: blocked steal — a no-delete-share handle on a STALE lock defers the steal until it closes =="
# Same handle class against a stale lock: the stealer's rename keeps failing
# while the handle is open (probe D1), so it re-polls — and acquires promptly
# once the handle closes. Run with the ps1 stealer: this exercises its
# File.Move-throws -> re-poll path, which nothing else reaches.
LOCK="$WORK/bs.lock"; LOG="$WORK/bs.log"; : > "$LOG"; MARK="$WORK/bs.mark"; rm -f "$MARK"
fabricate_lock "$LOCK" "tok.sh.stale.1" "pid=4242 host=ghost"
backdate "$LOCK" 9999
BREADY="$WORK/bs.bready"; BGO="$WORK/bs.bgo"; rm -f "$BREADY" "$BGO"
hold_handle "$LOCK" "$BREADY" "$BGO" &
blk14=$!
if wait_for "$BREADY" 400; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
    pwsh -NoProfile -File "$PS1WIN" run "[System.IO.File]::WriteAllText('$MARK', 'ran')" &
  stealer=$!
  wait_for_grep "WAITING for lock" "$LOG" || bad "T14 stealer never contended (no WAITING line)"
  sleep 2   # several stale-eligible polls against the blocked file
  [ ! -e "$MARK" ] && ok "stealer re-polled while the handle blocked the steal rename (no acquire)" \
                   || bad "stealer acquired while the steal rename should have been blocked"
  touch "$BGO"; wait "$blk14"
  wait "$stealer"; rc=$?
  [ "$rc" = 0 ] && ok "stealer acquired and ran once the handle closed (rc 0)" || bad "stealer rc=$rc (want 0)"
  grep -q STOLE "$LOG" && ok "STOLE logged once the handle closed" || bad "no STOLE entry"
  [ "$(cat "$MARK" 2>/dev/null)" = ran ] && ok "stealer's command ran" || bad "stealer's command never ran"
else
  touch "$BGO"; wait "$blk14" 2>/dev/null
  bad "T14 blocker never signalled its handle open"
fi

echo "== Test 14b: blocked steal NEVER bypasses MAX_WAIT — squatted stale lock => 97 with bounded logging (regression: busy-spin) =="
# Regression for the 2026-06-11 review finding: when the steal rename keeps
# failing with the lock file still present (a no-delete-share handle squatting
# it), the failed-steal lane used to `continue` past the timeout check AND the
# poll sleep — the waiter busy-spun flat-out, logged STALE every iteration,
# and could never reach 97. The squatter here NEVER closes during the wait;
# each impl's waiter must still exit 97 at MAX_WAIT, with the steal-attempt
# logging damped (first failure, then at most once per stale window).
LOCK="$WORK/bs2.lock"; rm -f "$LOCK"
fabricate_lock "$LOCK" "tok.sh.stale.2" "pid=4243 host=ghost"
backdate "$LOCK" 9999
BREADY="$WORK/bs2.bready"; BGO="$WORK/bs2.bgo"; rm -f "$BREADY" "$BGO"
hold_handle "$LOCK" "$BREADY" "$BGO" &
blk14b=$!
if wait_for "$BREADY" 400; then
  # Each waiter runs in the BACKGROUND with a bounded reap (T17c's pattern):
  # the regression this test guards is a busy-spin that never reaches the
  # MAX_WAIT check, so a foreground `run` would HANG the suite instead of
  # failing it. If the waiter outlives its generous budget it is failed and
  # hard-killed by ITS exact pid (never by name).
  for impl in sh ps; do
    LOGI="$WORK/bs2-$impl.log"; : > "$LOGI"
    if [ "$impl" = sh ]; then
      AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOGI" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=2 \
        bash "$SH" run -- bash -c 'true' 2>/dev/null &
    else
      AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOGI" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=2 \
        pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2>/dev/null &
    fi
    w14b=$!
    # Budget: MAX_WAIT=2 plus pwsh cold-start/load headroom (30s of 0.1s
    # polls) — generous enough that only a true never-returns spin overruns.
    hung=1
    for _ in $(seq 1 300); do kill -0 "$w14b" 2>/dev/null || { hung=0; break; }; sleep 0.1; done
    if [ "$hung" = 1 ]; then
      bad "$impl waiter still running long past MAX_WAIT — busy-spin regression (blocked-steal lane bypassed the timeout); killing it"
      kill -9 "$w14b" 2>/dev/null          # exact PID we spawned; nothing else
      wait "$w14b" 2>/dev/null
    else
      wait "$w14b"; rc=$?
      [ "$rc" = 97 ] && ok "$impl waiter hit MAX_WAIT (97) while the squatter blocked the steal" \
                     || bad "$impl waiter rc=$rc (want 97 — blocked-steal lane bypassed MAX_WAIT?)"
    fi
    nst="$(grep -c 'STALE (' "$LOGI")"
    nfail="$(grep -c 'steal FAILED' "$LOGI")"
    # ~20 stale-eligible polls in 2s at 0.1s; damped to first + once per 1s
    # stale window => a handful of STALE/steal-FAILED pairs, never per-poll.
    [ "$nst" -ge 1 ] && [ "$nst" -le 8 ] && [ "$nfail" -ge 1 ] \
      && ok "$impl steal-attempt logging bounded while squatted ($nst STALE, $nfail steal-FAILED lines)" \
      || bad "$impl steal logging wrong while squatted: STALE=$nst (want 1..8) steal-FAILED=$nfail (want >=1)"
  done
  # Clean up the squatter deterministically: signal it via its go-marker and
  # reap by ITS exact pid (never a name-based kill).
  touch "$BGO"
  wait "$blk14b" 2>/dev/null || true   # nonzero exit is fine; pid is already reaped (match T13)
else
  touch "$BGO"; wait "$blk14b" 2>/dev/null
  bad "T14b squatter never signalled its handle open"
fi
rm -f "$LOCK"

else
  echo "== Tests 13/14/14b SKIPPED (POSIX): open handles never block unlink/rename here =="
  echo "note: the LEFTOVER and blocked-steal lanes are Windows-only by construction (.NET's Unix FileShare gates no namespace operation); the Windows CI leg covers them"
fi

echo "== Test 15: ps1-side never-steal guards — dir, dangling symlink, non-lock content (parity with the bash guards) =="
# The ps1 guards use different APIs than bash (PSIsContainer, reparse
# attributes, the catch-all CreateNew exception), so bash coverage proves
# nothing about them. The wrong-type warning needs the SAME concrete type on
# two consecutive polls (round-3 confirmation parity, 2026-06-11), so (a) and
# (b) need at least three polls of headroom even under load (0.1s polls in a 4s wait = ~40
# here); (c) is the age-gated CONTENT lane, which still warns on a single
# observation. (a) a DIRECTORY at the lock path: the CreateNew open
# throws UnauthorizedAccessException, which must degrade to the wait/warn
# lane (97), never throw out of Lock-Acquire.
LOCK="$WORK/psdir.lock"; LOG="$WORK/psdir.log"; : > "$LOG"
mkdir -p "$LOCK/sub"; echo data > "$LOCK/sub/file"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=4 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/psdir.err"; rc=$?
[ "$rc" = 97 ] && ok "ps1: directory at lock path degrades to timeout 97 (open exception caught, not thrown)" \
               || bad "ps1: directory at lock path rc=$rc (want 97)"
[ -f "$LOCK/sub/file" ] && ok "ps1: directory and its contents untouched" || bad "ps1 damaged the directory at the lock path!"
grep -q "is not a lock file" "$WORK/psdir.err" && ok "ps1: loud config warning on stderr" || bad "ps1: no config warning for dir at lock path"
grep -q "it is a directory" "$WORK/psdir.err" && ok "ps1: warning names the detected type (directory)" || bad "ps1: warning does not name the directory type"
n="$(grep -c "is not a lock file" "$WORK/psdir.err")"
[ "$n" = 1 ] && ok "ps1: config warning fired exactly once per process (got $n)" || bad "ps1: config warning fired $n times (want 1)"
grep -q STOLE "$LOG" && bad "ps1 STOLE a directory" || ok "ps1: no steal attempted on a directory"
rm -rf "$LOCK"
# (b) a DANGLING symlink — the nastiest ps1 case: on Windows, CreateNew
# resolves the link and would CREATE THE TARGET (probed 2026-06-11), so the
# pre-create type guard is load-bearing; and the existence probe must see the
# link itself or every poll reads "absent" and the waiter starves undiagnosed.
# Skipped where symlinks can't be created (default Git-Bash without Dev Mode).
LOCK="$WORK/pslink.lock"; LOG="$WORK/pslink.log"; : > "$LOG"
if env MSYS=winsymlinks:nativestrict ln -s "$WORK/no-such-target" "$LOCK" 2>/dev/null && [ -L "$LOCK" ]; then
  AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=4 \
    pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/pslink.err"; rc=$?
  [ "$rc" = 97 ] && ok "ps1: dangling symlink at lock path -> waiter timed out (97)" \
                 || bad "ps1: dangling symlink rc=$rc (want 97)"
  [ -L "$LOCK" ] && ok "ps1: symlink untouched" || bad "ps1: symlink was removed/replaced"
  [ ! -e "$WORK/no-such-target" ] && ok "ps1: no target file created through the dangling link (CreateNew tunnel guarded)" \
                                  || bad "ps1 created the link target — pre-create guard regression!"
  grep -q "is not a lock file" "$WORK/pslink.err" && ok "ps1: config warning names the symlink case" \
                                                  || bad "ps1: no config warning for symlink at lock path"
  grep -q "it is a symlink" "$WORK/pslink.err" && ok "ps1: warning names the detected type (symlink)" || bad "ps1: warning does not name the symlink type"
  rm -f "$LOCK"
else
  rm -f "$LOCK"
  echo "note: cannot create symlinks here — ps1 symlink guard not exercised (CI POSIX legs cover it)"
fi
# (c) stale NON-LOCK CONTENT (a user file at a typo'd path): the ps1 content
# guard must refuse it forever and leave it fully intact.
LOCK="$WORK/psuser.lock"; LOG="$WORK/psuser.log"; : > "$LOG"
printf 'my precious data\nline two\n' > "$LOCK"; backdate "$LOCK" 9999
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=1 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=2 \
  pwsh -NoProfile -File "$PS1WIN" run "exit 0" 2> "$WORK/psuser.err"; rc=$?
[ "$rc" = 97 ] && ok "ps1: stale user file -> waiter timed out (97) instead of stealing" \
               || bad "ps1: stale user file rc=$rc (want 97)"
[ "$(cat "$LOCK" 2>/dev/null)" = "$(printf 'my precious data\nline two')" ] \
  && ok "ps1: user file content fully intact" || bad "ps1: user file was damaged or deleted!"
grep -q "is not a lock file" "$WORK/psuser.err" && ok "ps1: config warning names the non-lock content" \
                                                || bad "ps1: no config warning for non-lock content"
grep -q STOLE "$LOG" && bad "ps1 STOLE the user file" || ok "ps1: no steal of the user file"
rm -f "$LOCK"

if command -v powershell >/dev/null 2>&1; then
echo "== Test 17: Windows PowerShell 5.1 smoke lane — the ps1 must run, not just parse, on the in-box engine =="
# Everything above runs the port under pwsh (7+). 5.1 ships in every Windows
# 10/11 box and stays supported, so its claim is tested, not asserted: the
# run lane's exit-code contract (0 / exit 7 / the F2 failing-cmdlet -> 1) and
# one acquire/release under contention with the bash side (T2's pattern).
# Guarded by `command -v powershell`: absent on the POSIX CI legs -> the
# skip note in the else branch below.
powershell -NoProfile -Command '"engine " + $PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r'
LOCK="$WORK/ps51.lock"; LOG="$WORK/ps51.log"; : > "$LOG"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=30 \
  powershell -NoProfile -File "$PS1WIN" run "exit 0"; rc=$?
[ "$rc" = 0 ] && ok "5.1: run exit 0 propagated" || bad "5.1: run exit 0 rc=$rc"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=30 \
  powershell -NoProfile -File "$PS1WIN" run "exit 7" 2>/dev/null; rc=$?
[ "$rc" = 7 ] && ok "5.1: run exit 7 propagated" || bad "5.1: run exit 7 rc=$rc"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_MAX_WAIT=30 \
  powershell -NoProfile -File "$PS1WIN" run "Get-Item -LiteralPath '$WORK/no-such-file-ps51'" 2> "$WORK/ps51.err"; rc=$?
[ "$rc" = 1 ] && ok "5.1: failing cmdlet -> exit 1 (F2 verdict holds on 5.1)" || bad "5.1: failing cmdlet rc=$rc (want 1)"
powershell -NoProfile -File "$PS1WIN" --help > "$WORK/ps51.help.out" 2> "$WORK/ps51.help.err"; rc=$?
[ "$rc" = 0 ] && grep -q '^usage:' "$WORK/ps51.help.out" \
  && ok "5.1: --help -> usage on stdout, exit 0 (F6d convention holds on 5.1)" \
  || bad "5.1: --help rc=$rc (want 0) stdout-usage=$(grep -c '^usage:' "$WORK/ps51.help.out")"
grep -q "without a native exit code" "$WORK/ps51.err" \
  && ok "5.1: the no-native-exit-code note reaches stderr" \
  || bad "5.1: missing the no-native-exit-code note"
# Contention: a bash holder blocks a 5.1 waiter (T2's marker pattern — 5.1
# cold-start is slow, so the waiter launches only once the holder provably
# holds, and generous MAX_WAIT absorbs engine startup).
ORDER="$WORK/ps51.order"; : > "$ORDER"; READY="$WORK/ps51.ready"; rm -f "$READY"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  bash "$SH" run -- bash -c ': > "$2"; echo sh-start >> "$1"; sleep 2; echo sh-end >> "$1"' _ "$ORDER" "$READY" &
holder=$!
wait_for "$READY" || bad "T17 bash holder never signalled ready"
AGENT_LOCK_PATH="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 AGENT_LOCK_MAX_WAIT=60 \
  powershell -NoProfile -File "$PS1WIN" run "[IO.File]::AppendAllText('$ORDER','ps51-ran' + [char]10)"; rc=$?
wait "$holder"
[ "$rc" = 0 ] && ok "5.1: contended run exited 0" || bad "5.1: contended run rc=$rc"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "sh-start,sh-end,ps51-ran," ] && ok "5.1: bash-holds / 5.1-waits ordering correct" || bad "5.1 ordering wrong: $got"
grep -q STOLE "$LOG" && bad "5.1 wrongly STOLE a live bash lock" || ok "5.1 did not steal the live bash lock"
grep -q "ACQUIRED.*tok=tok\.ps\." "$LOG" && ok "5.1 acquisition logged with the shared wire-format token" || bad "no tok.ps.* ACQUIRED entry from the 5.1 waiter"
[ -e "$LOCK" ] && bad "lock left held after the 5.1 lane" || ok "no leftover lock after the 5.1 lane"
else
  echo "== Test 17 SKIPPED: Windows PowerShell 5.1 (powershell) not on PATH — POSIX leg; the Windows CI leg covers it =="
fi

echo
echo "==== INTEROP RESULT: $PASS passed, $FAIL failed (fan-out: $GCL_MODE) ===="
[ "$FAIL" = 0 ]
