# shellcheck shell=bash
# tests/_harness.sh — shared test harness for the git-commit-lock suites.
#
# Sourced by all three suites (git-commit-lock.test.sh, .interop.test.sh,
# .integration.test.sh) to share the bits they all copy-pasted: the PASS/FAIL/
# TAP counters, the GCL_TAP / GCL_TEST_ONLY reads, ok()/bad(), section(), the
# end-of-suite DONE sentinel (finish), and the per-test selector verdict helper.
# Pure deduplication — ZERO behaviour change vs the inline copies it replaces.
#
# Contract for sourcing suites:
#   * Source this EARLY (before any use of the inits/helpers below), CWD-
#     independently — resolve it from the sourcing script's own location:
#       _HARNESS_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#       # shellcheck source=tests/_harness.sh
#       . "$_HARNESS_DIR/_harness.sh"
#   * Each suite still defines its OWN cleanup() (it closes over the suite's
#     $WORK and the bodies genuinely differ); finish() below calls whatever
#     cleanup() is in scope when the EXIT trap fires.
#   * Each suite installs the trap itself: `trap finish EXIT`.
#   * The suite reaching its end sets DONE=1 before its verdict line.
#
# The whole project runs its suites under `set -uo pipefail` (NOT set -e); these
# helpers are written for that (they assert on values, never on implicit exit
# propagation), and the disables below cover the idioms that pervade the suites.
#
# shellcheck disable=SC2015  # The pervasive `<assert> && ok ... || bad ...`
# idiom is deliberate throughout: ok/bad are echo+counter helpers that cannot
# fail, so the classic A && B || C pitfall (C running after B fails) is moot.
# shellcheck disable=SC2310,SC2312  # info-level, deliberate: helper functions
# and command substitutions run inside conditions all over a test suite; the
# suites run WITHOUT errexit (set -uo only) and assert on values, not on
# implicit exit propagation.

PASS=0; FAIL=0; TAPN=0; DONE=0; SECTIONS_RUN=0
GCL_TAP="${GCL_TAP:-0}"           # CI sets GCL_TAP=1 for machine-readable TAP13 output
GCL_TEST_ONLY="${GCL_TEST_ONLY:-}"  # if set, run ONLY test blocks whose label REGEX-matches (single-test selector)
# Opt-in CI shard selector GCL_TEST_SHARD=<i>/<n> (round-robin over file-order
# section index). Parsed LAZILY on the first section() call (see _shard_init) so
# non-section() suites (integration) just note-and-ignore it; unset/empty is a
# no-op so all unsharded runs stay byte-identical. SHARD_I/SHARD_N hold the parsed
# pair; SECTION_IDX is the stable file-order shard key; SHARD_PARSED is the
# once-only parse guard.
GCL_TEST_SHARD="${GCL_TEST_SHARD:-}"
SHARD_I=0; SHARD_N=0; SECTION_IDX=0; SHARD_PARSED=0

# Axis-A waiter-count sweep (Bucket 6). GCL_TEST_SWEEP=1 (nightly/deep CI) widens
# the fan-out/contention tests over several waiter counts to wring more coverage
# from the existing tests; unset/0 (per-PR default + plain dev) keeps the floor so
# default runs are byte-identical to today. T_AXIS_A is the shared waiter-count
# list the contention tests (unit Test 2b, interop Test 16) iterate N over; each
# names N in every assertion message so a sweep failure says which N broke. The
# floor is 4 — the count those two tests hardcode today, so the single-element
# default reproduces today's behaviour exactly. (Test 20's floor is mode-driven
# `$T20_N` (5 REDUCED / 10 FULL), not 4, so it composes its own list from $T20_N +
# the sweep's higher counts rather than from T_AXIS_A — see that test.)
GCL_TEST_SWEEP="${GCL_TEST_SWEEP:-0}"
# shellcheck disable=SC2034  # T_AXIS_A is consumed by the sourcing suites (unit
# Test 2b, interop Test 16), not within this harness file.
if [ "$GCL_TEST_SWEEP" = 1 ]; then T_AXIS_A="4 12 24"; else T_AXIS_A="4"; fi

# ok/bad are TAP-aware (gated by GCL_TAP so plain dev runs are byte-unchanged) and
# bump the running assertion number TAPN. The trailing `1..$TAPN` plan line (emitted
# by each suite just before its verdict) lets a TAP consumer fail on a short count;
# together with the DONE sentinel below this closes the silent-undercount gap.
# `return 0` preserves the "ok/bad cannot fail" property the
# `<assert> && ok ... || bad ...` idiom relies on.
ok()  { PASS=$((PASS+1)); TAPN=$((TAPN+1)); echo "PASS: $*"
        [ "$GCL_TAP" = 1 ] && echo "ok $TAPN - $*"; return 0; }
bad() { FAIL=$((FAIL+1)); TAPN=$((TAPN+1)); echo "FAIL: $*"
        [ "$GCL_TAP" = 1 ] && echo "not ok $TAPN - $*"; return 0; }

# Lazy one-time parse+validate of GCL_TEST_SHARD. Called from section() (NOT at
# source time) so suites that never call section() (integration) neither parse
# nor bail — they only note-and-ignore the var. An empty/unset var is a no-op.
# Validation bails LOUDLY (exit 1) on any malformed input so a typo can never
# silently run a partial suite green:
#   * GCL_TEST_ONLY + GCL_TEST_SHARD are mutually exclusive (no real combined use
#     case, and exclusivity makes the per-shard count guard always valid).
#   * The single regex ^([1-9][0-9]*)/([1-9][0-9]*)$ rejects empty components,
#     non-digits, leading zeros (a bash-arithmetic octal trap), and extra slashes
#     in one shot; BASH_REMATCH then yields i and n.
#   * i <= n range check.
_shard_init() {
  SHARD_PARSED=1
  [ -z "$GCL_TEST_SHARD" ] && return 0
  if [ -n "${GCL_TEST_ONLY:-}" ]; then
    echo "Bail out! GCL_TEST_ONLY and GCL_TEST_SHARD are mutually exclusive" >&2; exit 1
  fi
  if [[ "$GCL_TEST_SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
    SHARD_I=${BASH_REMATCH[1]}; SHARD_N=${BASH_REMATCH[2]}
  else
    echo "Bail out! GCL_TEST_SHARD must be i/n positive integers (got '$GCL_TEST_SHARD')" >&2; exit 1
  fi
  if [ "$SHARD_I" -gt "$SHARD_N" ]; then
    echo "Bail out! GCL_TEST_SHARD=$GCL_TEST_SHARD out of range (need i<=n)" >&2; exit 1
  fi
}

# Per-test gate: echoes the block header (so a normal run is byte-unchanged) and
# returns success iff the test is selected. Each top-level `== Test N: <desc> ==`
# block is wrapped `if section "..."; then ... fi`. SECTION_IDX bumps for EVERY
# section in file order (before any gating) — it is the stable shard-assignment
# key, independent of GCL_TEST_ONLY/SWEEP/FULL. SECTIONS_RUN bumps only when the
# block actually runs, so the verdict guards (selector_report) can catch a
# zero-match selector or a miscounted shard. Two gates compose: the GCL_TEST_ONLY
# regex selector, then the GCL_TEST_SHARD round-robin (mutually exclusive, so at
# most one is active). Both are no-ops when their var is empty, so unsharded /
# unselected runs are byte-identical (the RAN: marker is emitted ONLY in shard
# mode for the same reason).
section() {
  [ "$SHARD_PARSED" = 1 ] || _shard_init        # lazy: only section()-using suites parse
  SECTION_IDX=$((SECTION_IDX + 1))              # file-order index, bumped for EVERY test before gating
  echo "== $1 =="
  if [ -n "${GCL_TEST_ONLY:-}" ] && ! [[ "$1" =~ $GCL_TEST_ONLY ]]; then return 1; fi
  if [ -n "$GCL_TEST_SHARD" ] && [ $(( (SECTION_IDX - 1) % SHARD_N )) -ne $(( SHARD_I - 1 )) ]; then
    return 1
  fi
  [ -n "$GCL_TEST_SHARD" ] && echo "RAN: $1"    # run-only attribution marker (shard mode only — keeps unsharded byte-identical)
  SECTIONS_RUN=$((SECTIONS_RUN + 1)); return 0
}

# Sentinel: the suite reaching its end sets DONE=1. If the EXIT trap fires with
# DONE!=1, the suite died early (a stray exit/crash) and the assertion count is
# unreliable — fail loudly even if the pre-trap code was 0. A bare trap `return`
# is IGNORED (the script keeps its pre-trap code), so the guard must `exit 1`.
# Calls the suite-local cleanup() (each suite defines its own, closing over its
# own $WORK); whatever cleanup is in scope when the trap fires is used.
finish() {
  cleanup
  if [ "${DONE:-0}" != 1 ]; then
    echo "Bail out! suite terminated early before the plan line; ran ${TAPN:-0} assertion(s), count unreliable" >&2
    exit 1
  fi
}

# Selector verdict helper, called by the section-using suites just before their
# verdict line. Two parts, both gated on GCL_TEST_ONLY being non-empty so a
# default run stays byte-identical:
#   1. Zero-match guard: a set-but-non-matching GCL_TEST_ONLY ran NO test block,
#      so the (vacuously green) verdict would lie — a typo'd selector regex must
#      FAIL, not pass with zero assertions. Bail loudly. (The finish EXIT trap
#      also fires here since DONE is still 0; this exit is non-zero regardless.)
#   2. Report how many blocks the selector matched.
# Integration does NOT call this — it is one indivisible scenario that does not
# use section(), so it note-and-ignores GCL_TEST_ONLY at its top instead.
selector_report() {
  if [ -n "${GCL_TEST_ONLY:-}" ] && [ "$SECTIONS_RUN" = 0 ]; then
    echo "Bail out! GCL_TEST_ONLY=\"$GCL_TEST_ONLY\" matched no test" >&2
    exit 1
  fi
  [ -n "${GCL_TEST_ONLY:-}" ] && echo "selector GCL_TEST_ONLY=\"$GCL_TEST_ONLY\" ran $SECTIONS_RUN test block(s)"
  # Shard mode (gated so unsharded runs are byte-identical and never hit % SHARD_N=0):
  # recompute the expected run-count from the SAME one-based residue mapping the
  # section() gate uses, log one greppable verdict line, and bail loudly if the
  # actual run-count disagrees OR the shard is empty (expected < 1 — e.g. n >
  # section-count like 58/58 — which would otherwise pass vacuously green).
  if [ -n "$GCL_TEST_SHARD" ]; then
    local exp=0 k=1
    while [ "$k" -le "$SECTION_IDX" ]; do
      [ $(( (k - 1) % SHARD_N )) -eq $(( SHARD_I - 1 )) ] && exp=$((exp + 1)); k=$((k + 1))
    done
    echo "GCL_TEST_SHARD=$SHARD_I/$SHARD_N: ran $SECTIONS_RUN of $SECTION_IDX sections (expected $exp)"
    if [ "$SECTIONS_RUN" -ne "$exp" ] || [ "$exp" -lt 1 ]; then
      echo "Bail out! shard $SHARD_I/$SHARD_N ran $SECTIONS_RUN, expected $exp" >&2; exit 1
    fi
  fi
  return 0
}

# --- Shared timing/lock helpers (unit + interop; integration uses none) -------
# Backdate a path's mtime by $2 seconds — how a test fakes a stale lock (the
# lock's staleness clock is the lock FILE's own mtime, stamped by the creating
# write). Portable: BSD/macOS touch has no `-d @epoch`, so convert the target
# epoch to a `touch -t` stamp via GNU `date -d @` with BSD `date -r` as
# fallback.
epoch_to_stamp() {
  date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null
}
backdate() { touch -t "$(epoch_to_stamp "$(( $(date +%s) - $2 ))")" "$1"; }

# Token-guarded backdate for the contended-recovery rounds (unit T2b /
# interop T16/T16b). Why: under load a fast waiter can complete its ENTIRE steal
# (claim -> rename-over -> ACQUIRED) before the harness's `touch` executes, so a
# blind backdate lands on the WINNER'S freshly installed lock, making it
# instantly stale for every rival — a legitimate re-steal then fails the round's
# "zero 98s / exactly one STOLE-BY-CLAIM" assertions although the protocol
# behaved exactly as designed (observed 2026-06-12 on a loaded box). Verdicts:
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

# Fabricate a lock file the way a real (foreign) holder would have written it:
# token line + owner line. The token MUST be "tok."-prefixed (wire format) or
# the steal's content guard will — correctly — refuse to steal it.
fabricate_lock() {  # $1=path $2=token $3=owner
  printf '%s\n%s\n' "$2" "$3" > "$1"
}

# Wait (up to $3 seconds, default 15) for a pattern to appear in a file. Used to
# gate on the WAITING log line: proof the waiter actually contended, without a
# fixed-length hold.
wait_for_grep() {
  local pat="$1" f="$2" tries=$(( ${3:-15} * 20 ))
  while ! grep -q "$pat" "$f" 2>/dev/null && [ "$tries" -gt 0 ]; do sleep 0.05; tries=$((tries-1)); done
  grep -q "$pat" "$f" 2>/dev/null
}
