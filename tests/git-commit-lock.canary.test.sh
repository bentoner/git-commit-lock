#!/usr/bin/env bash
# git-commit-lock.canary.test.sh — the concurrency CANARY, extracted from the
# unit suite (git-commit-lock.test.sh) into its own file so it runs as a
# naturally-parallel CI job.
#
# Runs entirely against throwaway temp dirs, so it never touches the repo you
# launch it from. Exit 0 == pass.
#   bash tests/git-commit-lock.canary.test.sh
#
# This is a STATISTICAL concurrency canary — N workers race the lock over
# repeated rounds; repetition at width is its coverage. It is cheap on
# Linux/macOS (fast process spawn) but pathological on Windows (~half the
# Windows unit wall-clock), which is exactly why it lives in its own cell.
#
# Fan-out: defaults to REDUCED width so routine dev runs don't lag a live shared
# machine; set GCL_TEST_FULL=1 (CI does) for the full-strength 8x25 canary. The
# file prints which mode ran — a reduced pass must never masquerade as the full one.
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

# Shared harness: PASS/FAIL/TAP counters, GCL_TAP/GCL_TEST_ONLY reads, ok/bad,
# section, the finish EXIT-trap sentinel (calls our cleanup below). Resolved from
# THIS script's own dir so it sources regardless of CWD; sourced EARLY (before any
# use of the inits/helpers below).
_HARNESS_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/_harness.sh
. "$_HARNESS_DIR/_harness.sh"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"   # the implementations live at the repo root
LIB="$ROOT/git-commit-lock.sh"

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
# The finish EXIT-trap sentinel (defined in _harness.sh) calls the cleanup()
# above and fails loudly if the suite died before setting DONE=1.
trap finish EXIT

# The RESULT line below expands $ENV_WARN, which in the unit suite is maintained
# by the envelope-tier assertions (ok_envelope/bad_envelope). The canary uses
# only plain ok/bad (no envelope assertions), so define it to 0 here so the
# standard RESULT line works unchanged under set -u.
ENV_WARN=0

# Critical section that loses updates without a mutex: read, gap, write+1.
INCR='n="$(cat "$1")"; sleep 0.03; echo $((n+1)) > "$1"'

if section "Test 1: concurrent workers, mutual exclusion (repeated rounds, $GCL_MODE width)"; then
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
fi

# Zero-match guard + selector-report line (shared helper in _harness.sh): a
# set-but-non-matching GCL_TEST_ONLY ran NO test block, which without the guard
# would fall through to a vacuous PASS=0 FAIL=0 "green". Near-pointless in a
# one-test file, but zero-cost and keeps the finish/zero-match scaffolding
# uniform with the other suites.
selector_report

DONE=1
echo
echo "==== RESULT: $PASS passed, $FAIL failed, $ENV_WARN envelope warning(s) (fan-out: $GCL_MODE) ===="
[ "$GCL_TAP" = 1 ] && echo "1..$TAPN"
[ "$FAIL" = 0 ]
