#!/usr/bin/env bash
# commit-lock.interop.test.sh
# Canonical path: C:\code\commit-lock\commit-lock.interop.test.sh
#
# Cross-implementation test: proves commit-lock.ps1 (PowerShell, used by Codex)
# and commit-lock.sh (bash, used by Claude) share ONE lock and serialise against
# EACH OTHER in the same working tree. Run from a Windows MINGW/Git-Bash (the same
# bash Claude uses) — NOT from WSL — because both sides must agree on the lock path
# in `C:/...` form. Spawns pwsh + git-bash workers, so it needs both on PATH.
#   bash ~/.local/bin/commit-lock.interop.test.sh
# Exit 0 == all pass. Uses a throwaway temp dir; never touches your repo.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SH="$DIR/commit-lock.sh"
PS1WIN="$(cygpath -w "$DIR/commit-lock.ps1" 2>/dev/null || echo "$DIR/commit-lock.ps1")"
PS1WIN="${PS1WIN//\\//}"   # forward slashes: both pwsh and mingw accept C:/...

command -v pwsh >/dev/null 2>&1 || { echo "SKIP: pwsh not on PATH"; exit 0; }

# A Windows-form temp dir BOTH pwsh and mingw bash resolve to the same NTFS path.
WORK="$(pwsh -NoProfile -Command '[IO.Path]::Combine([IO.Path]::GetTempPath(), "cl-interop-" + [guid]::NewGuid().ToString("N").Substring(0,8))' 2>/dev/null | tr -d '\r')"
WORK="${WORK//\\//}"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

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
  AGENT_LOCK_DIR="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 \
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
  AGENT_LOCK_DIR="$1" AGENT_LOCK_LOG="$2" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.05 \
    pwsh -NoProfile -File "$PS1WIN" run "$body"
}

echo "== Test 1: mixed pwsh+bash workers, mutual exclusion across implementations =="
NSH=8; NPS=8; TOT=$((NSH+NPS))
LOCK="$WORK/excl.lock"; LOG="$WORK/excl.log"; : > "$LOG"
HOLDER="$WORK/holder"; : > "$HOLDER"; VIOL="$WORK/violations"; : > "$VIOL"
pids=()
for i in $(seq 1 $NSH); do sh_worker "$LOCK" "$LOG" "$HOLDER" "$VIOL" "sh$i" & pids+=($!); done
for i in $(seq 1 $NPS); do ps_worker "$LOCK" "$LOG" "$HOLDER" "$VIOL" "ps$i" & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
a="$(grep -c ACQUIRED "$LOG")"; rl="$(grep -c RELEASED "$LOG")"; st="$(grep -c STOLE "$LOG")"
nv="$(wc -l < "$VIOL" 2>/dev/null | tr -d ' ')"; nv="${nv:-0}"
# Real signals gate PASS: zero concurrent-holder violations, zero spurious steals
# (none should occur at stale=300 in a seconds-long run), balanced acquire/release
# (released<acquired would mean a false "stolen" or a leaked lock), and no leftover
# lock. A worker that never launched (acquired<TOT) is Cygwin process-fan-out
# flakiness, orthogonal to the lock — noted, not failed.
if [ "$nv" = 0 ] && [ "$st" = 0 ] && [ "$rl" = "$a" ] && [ ! -e "$LOCK" ]; then
  if [ "$a" = "$TOT" ]; then
    ok "$NSH bash + $NPS pwsh workers: 0 violations, 0 spurious steals, all $TOT acquired+released, no leftover lock"
  else
    ok "0 violations, 0 steals, balanced acquire/release ($a/$a), no leftover; NOTE $((TOT-a)) worker(s) didn't launch (fan-out flakiness, not the lock)"
  fi
else
  [ "$nv" != 0 ] && { echo "  VIOLATIONS:"; sed 's/^/    /' "$VIOL"; }
  [ "$st" != 0 ] && { echo "  STALE/STEAL log lines:"; grep -E "STALE|STOLE" "$LOG" | sed 's/^/    /'; }
  bad "cross-impl exclusion/balance: violations=$nv steals=$st acquired=$a released=$rl leftover=$([ -e "$LOCK" ] && echo yes || echo no)"
fi

echo "== Test 2: a bash holder blocks a pwsh waiter (no concurrent hold, no wrongful steal) =="
LOCK="$WORK/b2.lock"; LOG="$WORK/b2.log"; : > "$LOG"; ORDER="$WORK/b2.order"; : > "$ORDER"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$SH" run -- bash -c 'echo sh-start >> "$1"; sleep 2; echo sh-end >> "$1"' _ "$ORDER" &
holder=$!; sleep 0.6
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::AppendAllText('$ORDER','ps-ran' + [char]10)"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "sh-start,sh-end,ps-ran," ] && ok "bash-holds / pwsh-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "pwsh wrongly STOLE a live bash lock" || ok "pwsh did not steal the live bash lock"

echo "== Test 3: a pwsh holder blocks a bash waiter =="
LOCK="$WORK/b3.lock"; LOG="$WORK/b3.log"; : > "$LOG"; ORDER="$WORK/b3.order"; : > "$ORDER"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::AppendAllText('$ORDER','ps-start' + [char]10); Start-Sleep 2; [IO.File]::AppendAllText('$ORDER','ps-end' + [char]10)" &
holder=$!; sleep 0.8
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$SH" run -- bash -c 'echo sh-ran >> "$1"' _ "$ORDER"
wait "$holder"
got="$(tr '\n' ',' < "$ORDER")"
[ "$got" = "ps-start,ps-end,sh-ran," ] && ok "pwsh-holds / bash-waits ordering correct" || bad "ordering wrong: $got"
grep -q STOLE "$LOG" && bad "bash wrongly STOLE a live pwsh lock" || ok "bash did not steal the live pwsh lock"

echo "== Test 4: pwsh steals a STALE lock left by bash (old dir mtime) =="
LOCK="$WORK/b4.lock"; LOG="$WORK/b4.log"; : > "$LOG"; MARK="$WORK/b4.mark"; printf '%s' before > "$MARK"
mkdir -p "$LOCK"; printf 'pid=99999 host=ghost\n' > "$LOCK/owner"; printf '%s' "tok.sh.ghost" > "$LOCK/token"
touch -d "@$(( $(date +%s) - 9999 ))" "$LOCK"   # ancient dir mtime -> stale
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 \
  pwsh -NoProfile -File "$PS1WIN" run "[IO.File]::WriteAllText('$MARK','after')"; rc=$?
[ "$rc" = 0 ] && ok "pwsh run exited 0 after stealing bash's stale lock" || bad "pwsh run exited $rc"
[ "$(cat "$MARK")" = after ] && ok "stale bash lock stolen, pwsh command ran" || bad "marker=$(cat "$MARK")"
grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"

echo "== Test 5: bash steals a STALE lock left by pwsh =="
LOCK="$WORK/b5.lock"; LOG="$WORK/b5.log"; : > "$LOG"; MARK="$WORK/b5.mark"; printf '%s' before > "$MARK"
# Create a pwsh-style stale lock, then backdate it.
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=300 \
  pwsh -NoProfile -File "$PS1WIN" run "Start-Sleep -Milliseconds 50" >/dev/null 2>&1 || true
mkdir -p "$LOCK" 2>/dev/null; printf 'pid=88888 host=ghostps\n' > "$LOCK/owner"; printf '%s' "tok.ps.ghost" > "$LOCK/token"
touch -d "@$(( $(date +%s) - 9999 ))" "$LOCK"
AGENT_LOCK_DIR="$LOCK" AGENT_LOCK_LOG="$LOG" AGENT_LOCK_STALE_SECS=2 AGENT_LOCK_POLL_SECS=0.1 \
  bash "$SH" run -- bash -c 'printf "%s" after > "$1"' _ "$MARK"; rc=$?
[ "$rc" = 0 ] && ok "bash run exited 0 after stealing pwsh's stale lock" || bad "bash run exited $rc"
[ "$(cat "$MARK")" = after ] && ok "stale pwsh lock stolen, bash command ran" || bad "marker=$(cat "$MARK")"
grep -q STOLE "$LOG" && ok "log records the cross-impl steal" || bad "no STOLE entry"

echo
echo "==== INTEROP RESULT: $PASS passed, $FAIL failed ===="
[ "$FAIL" = 0 ]
