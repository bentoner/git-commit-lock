#!/usr/bin/env bash
# git-commit-lock.integration.test.sh — end-to-end integration test.
#
# The unit suite (git-commit-lock.test.sh) and the interop suite
# (git-commit-lock.interop.test.sh) exercise the lock PROTOCOL but never run a
# real `git add`/`git commit`. This suite drives the actual use case: many
# concurrent workers committing into ONE shared real git repository, each
# wrapping its stage+commit in the lock exactly as README.md instructs agents
# to. It then audits the resulting history for the guarantees the tool claims
# (docs/git-commit-lock.md): every commit lands, history stays linear, no
# commit sweeps up another worker's file, no index.lock races, no stolen
# leases, clean tree and no leftover lock at the end.
#
# Runs entirely against a throwaway temp repo, so it never touches the repo
# you launch it from. The mixed bash+pwsh section skips cleanly when pwsh is
# absent; the bash-only section always runs. Exit 0 == all pass.
#   bash ~/.local/bin/git-commit-lock.integration.test.sh
#
# Fan-out: the worker swarms default to REDUCED width so routine dev runs
# don't lag a live shared machine; set GCL_TEST_FULL=1 (CI does) for the
# full-strength canary. The suite prints which mode ran — a reduced pass must
# never masquerade as the full one.
#
# On failure the work dir (scratch repo, per-worker stdout/stderr/rc captures,
# lock log) is PRESERVED (path printed) for post-mortem; set
# GCL_TEST_PRESERVE_DIR=<dir> to additionally copy everything there regardless
# of outcome (used by CI) — same semantics as the unit suite.
#
# shellcheck disable=SC2015  # The pervasive `<assert> && ok ... || bad ...`
# idiom is deliberate throughout: ok/bad are echo+counter helpers that cannot
# fail, so the classic A && B || C pitfall (C running after B fails) is moot.
# shellcheck disable=SC2312  # info-level, deliberate: command substitutions
# run inside conditions all over a test suite; the suite runs WITHOUT errexit
# (set -uo only) and asserts on values, not on implicit exit propagation.
# shellcheck disable=SC2016  # single-quoted command strings are deliberate:
# they expand inside a worker's `bash -c` invocation, not here.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/git-commit-lock.sh"
PS1WIN="$(cygpath -w "$DIR/git-commit-lock.ps1" 2>/dev/null || echo "$DIR/git-commit-lock.ps1")"
PS1WIN="${PS1WIN//\\//}"   # forward slashes: both pwsh and mingw accept C:/...

HAVE_PWSH=0
command -v pwsh >/dev/null 2>&1 && HAVE_PWSH=1

WORK="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/git-commit-lock-itest.$$")"
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

# --- sizing ------------------------------------------------------------------
# Commits serialise (that's the whole point), so wall time ≈ workers x commit
# cost, and on this Windows/Cygwin box a spawn+add+commit is ~0.5-1s, a pwsh
# startup 1-3s. FULL: 2 rounds x 12 bash workers + 1 mixed round of 5+5 = 34
# commits keeps the suite well under ~2-3 minutes even on a loaded machine,
# while still being a real 12-way concurrent pile-up on one index; REDUCED
# (the default) scales that to 1 x 6 + 3+3 = 12 commits — still a real
# concurrent pile-up, ~1/3 the spawn load. Assertions are STRICT in both
# modes — a worker that fails to launch or commit fails the suite (no
# "fan-out flakiness" tolerance here, unlike the interop suite's exclusion
# test: this suite exists to prove every commit LANDS). If heavy process
# fan-out ever makes launches flaky at this size, reduce N further rather
# than tolerating loss. 12-way is modest enough that launches have been
# reliable in practice.
if [ "${GCL_TEST_FULL:-0}" = 1 ]; then
  GCL_MODE="FULL"
  BN=12; BROUNDS=2        # bash swarm: BROUNDS rounds x BN workers
  MSH=5; MPS=5            # mixed swarm: MSH bash + MPS pwsh workers, 1 round
else
  GCL_MODE="REDUCED"
  BN=6; BROUNDS=1
  MSH=3; MPS=3
fi
echo "fan-out mode: $GCL_MODE (bash swarm ${BROUNDS}x${BN}, mixed swarm ${MSH}+${MPS})"
[ "$GCL_MODE" = REDUCED ] && echo "  (set GCL_TEST_FULL=1 for the full-strength canary — CI runs it)"
# Lock knobs: default-equivalent stale window (no spurious steals in a
# minutes-long run), fast poll so waiters don't add 2s each, and a generous but
# bounded max wait so a wedge fails the suite instead of hanging it.
LK_ENV=(AGENT_LOCK_STALE_SECS=300 AGENT_LOCK_POLL_SECS=0.2 AGENT_LOCK_MAX_WAIT=240)

# --- scratch repo ------------------------------------------------------------
REPO="$WORK/repo"; OUTD="$WORK/out"; NOHOOKS="$WORK/nohooks"
mkdir -p "$REPO" "$OUTD" "$NOHOOKS"
git -C "$REPO" init -q
# All config LOCAL (never --global): the host machine / CI runner must not need
# any identity or signing setup, and we must not touch the user's config.
git -C "$REPO" config user.name  "integration-test"
git -C "$REPO" config user.email "integration-test@example.invalid"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config core.hooksPath "$NOHOOKS"   # ignore any global hooksPath
git -C "$REPO" commit -q --allow-empty -m "initial (empty)" \
  || { echo "FATAL: could not create initial commit"; exit 1; }

GITDIR="$(git -C "$REPO" rev-parse --absolute-git-dir)"
LOCKFILE="$GITDIR/commit.lock"          # both impls' default lock location
LLOG="$GITDIR/git-commit-lock.log"      # both impls' default lock log

# --- workers -----------------------------------------------------------------
# Each worker owns one id; file f-<id>.txt, commit message "integration <id>".
# Real-agent shape: it WRITES its file into the shared working tree first
# (edits happen outside the lock), then takes the lock ONLY for stage+commit,
# using the documented `run` forms from README.md. stdout/stderr/rc are
# captured per worker in $OUTD so any failure is diagnosable.

bash_worker() {  # $1=id
  local id="$1" f="f-$1.txt"
  (
    cd "$REPO" || { echo "cd failed" > "$OUTD/$id.err"; echo 99 > "$OUTD/$id.rc"; exit 99; }
    printf 'content for %s\n' "$id" > "$f"
    env "${LK_ENV[@]}" bash "$LIB" run -- bash -c \
      'git add -- "$1" && git commit -m "$2"' _ "$f" "integration $id" \
      > "$OUTD/$id.out" 2> "$OUTD/$id.err"
    echo $? > "$OUTD/$id.rc"
  )
}

pwsh_worker() {  # $1=id
  local id="$1" f="f-$1.txt"
  (
    cd "$REPO" || { echo "cd failed" > "$OUTD/$id.err"; echo 99 > "$OUTD/$id.rc"; exit 99; }
    printf 'content for %s\n' "$id" > "$f"
    env "${LK_ENV[@]}" pwsh -NoProfile -File "$PS1WIN" run \
      "git add -- $f; if (\$LASTEXITCODE -eq 0) { git commit -m 'integration $id' }" \
      > "$OUTD/$id.out" 2> "$OUTD/$id.err"
    echo $? > "$OUTD/$id.rc"
  )
}

dump_worker() {  # $1=id — print a failed worker's captured output
  echo "  ---- worker $1 (rc=$(cat "$OUTD/$1.rc" 2>/dev/null || echo missing)) ----"
  sed 's/^/  [out] /' "$OUTD/$1.out" 2>/dev/null
  sed 's/^/  [err] /' "$OUTD/$1.err" 2>/dev/null
  echo "  ---- lock log tail ----"
  tail -n 20 "$LLOG" 2>/dev/null | sed 's/^/  [log] /'
}

# Strict per-worker check: every worker must have launched AND committed (rc 0).
check_worker_rcs() {  # $@=ids — returns 0 iff all rc files exist and are 0
  local id rc failed=0
  for id in "$@"; do
    rc="$(cat "$OUTD/$id.rc" 2>/dev/null || echo missing)"
    if [ "$rc" != "0" ]; then failed=1; dump_worker "$id"; fi
  done
  return "$failed"
}

ALL_IDS=()

# --- Test 1: bash worker swarm — concurrent real commits ----------------------
echo "== Test 1: $BROUNDS rounds x $BN concurrent bash workers committing for real =="
for r in $(seq 1 "$BROUNDS"); do
  ids=(); pids=()
  for i in $(seq 1 "$BN"); do ids+=("r$r-b$i"); done
  for id in "${ids[@]}"; do bash_worker "$id" & pids+=($!); done
  for p in "${pids[@]}"; do wait "$p"; done
  ALL_IDS+=("${ids[@]}")
  if check_worker_rcs "${ids[@]}"; then
    ok "round $r: all $BN bash workers committed (rc 0)"
  else
    bad "round $r: at least one bash worker failed to launch or commit (see above)"
  fi
done

# --- Test 2: mixed bash+pwsh swarm (both impls on ONE real repo) --------------
if [ "$HAVE_PWSH" = 1 ]; then
  echo "== Test 2: mixed swarm — $MSH bash + $MPS pwsh workers committing for real =="
  ids=(); pids=()
  for i in $(seq 1 "$MSH"); do ids+=("m1-b$i"); done
  for i in $(seq 1 "$MPS"); do ids+=("m1-p$i"); done
  for id in "${ids[@]}"; do
    case "$id" in
      *-p*) pwsh_worker "$id" & pids+=($!) ;;
      *)    bash_worker "$id" & pids+=($!) ;;
    esac
  done
  for p in "${pids[@]}"; do wait "$p"; done
  ALL_IDS+=("${ids[@]}")
  if check_worker_rcs "${ids[@]}"; then
    ok "mixed round: all $((MSH+MPS)) workers committed (rc 0)"
  else
    bad "mixed round: at least one worker failed to launch or commit (see above)"
  fi
else
  echo "== Test 2: SKIP — pwsh not on PATH; mixed bash+pwsh swarm not run =="
fi

# --- Test 3: audit the resulting repository -----------------------------------
echo "== Test 3: history and working-tree integrity =="
TOTAL="${#ALL_IDS[@]}"

# 3a. Every commit landed: rev-list count == workers + the initial commit.
nc="$(git -C "$REPO" rev-list --count HEAD)"
[ "$nc" = "$((TOTAL+1))" ] \
  && ok "commit count: $nc == $TOTAL workers + 1 initial" \
  || { bad "commit count: got $nc, want $((TOTAL+1))"; git -C "$REPO" log --oneline | sed 's/^/  /'; }

# 3b. Linear history: no commit has more than one parent (no merges).
nm="$(git -C "$REPO" rev-list --min-parents=2 --count HEAD)"
[ "$nm" = 0 ] && ok "history is linear (0 merge commits)" || bad "$nm merge commit(s) in history"

# 3c. Isolation: every commit touches EXACTLY its own worker's file — proves no
# sweep-up and no interleaved staging (worker files sit untracked in the shared
# tree while others commit; nobody may pick them up).
root="$(git -C "$REPO" rev-list --max-parents=0 HEAD)"
iso_fail=0
while read -r c; do
  [ "$c" = "$root" ] && continue
  subj="$(git -C "$REPO" log -1 --format=%s "$c")"
  expect="f-${subj#integration }.txt"
  files="$(git -C "$REPO" show --name-only --format= "$c" | sed '/^$/d')"
  if [ "$files" != "$expect" ]; then
    iso_fail=1
    echo "  commit $c ('$subj') touched: $(echo "$files" | tr '\n' ' ') (want exactly $expect)"
  fi
done < <(git -C "$REPO" rev-list HEAD)
[ "$iso_fail" = 0 ] && ok "every commit touches exactly its own worker's file" \
                    || bad "at least one commit swept up foreign files (see above)"

# 3d. Every worker's marker message appears exactly once.
mark_fail=0
git -C "$REPO" log --format=%s > "$WORK/subjects"
for id in "${ALL_IDS[@]}"; do
  n="$(grep -Fxc "integration $id" "$WORK/subjects")"
  [ "$n" = 1 ] || { mark_fail=1; echo "  marker 'integration $id' appears $n times (want 1)"; }
done
[ "$mark_fail" = 0 ] && ok "all $TOTAL marker messages appear exactly once" \
                     || bad "marker message count wrong (see above)"

# 3e. No index.lock races leaked through: the queueing the lock adds means no
# worker should ever have hit git's own index.lock failure.
if grep -l -e "index.lock" -e "Unable to create" "$OUTD"/*.err "$OUTD"/*.out 2>/dev/null; then
  bad "index.lock / 'Unable to create' errors in worker output (files listed above)"
  grep -l -e "index.lock" -e "Unable to create" "$OUTD"/*.err "$OUTD"/*.out 2>/dev/null \
    | while read -r f; do dump_worker "$(basename "${f%.*}")"; done
else
  ok "no index.lock / 'Unable to create' errors in any worker's output"
fi

# 3f. Lock log: every hold acquired+released cleanly; no stolen leases, no
# spurious steals, no timeouts (stale=300 over a minutes-long run means any
# steal would be a real bug).
a="$(grep -c ACQUIRED "$LLOG" 2>/dev/null)"; rl="$(grep -c RELEASED "$LLOG" 2>/dev/null)"
[ "$a" = "$TOTAL" ] && [ "$rl" = "$TOTAL" ] \
  && ok "lock log balanced: $a acquired, $rl released (== $TOTAL workers)" \
  || bad "lock log unbalanced: acquired=$a released=$rl want=$TOTAL"
if grep -q -e "WARNING" -e "STOLE" -e "TIMEOUT" "$LLOG" 2>/dev/null; then
  bad "lock log has WARNING/STOLE/TIMEOUT entries:"
  grep -e "WARNING" -e "STOLE" -e "TIMEOUT" "$LLOG" | sed 's/^/  [log] /'
else
  ok "lock log has no stolen-lease WARNINGs, steals, or timeouts"
fi

# 3g. Working tree clean (every written file was committed, nothing half-staged).
st="$(git -C "$REPO" status --porcelain)"
[ -z "$st" ] && ok "working tree clean at end" \
             || { bad "working tree not clean:"; echo "$st" | sed 's/^/  /'; }

# 3h. No leftover lock file.
[ -e "$LOCKFILE" ] && bad "leftover lock file: $LOCKFILE" || ok "no leftover lock file"

echo
echo "==== INTEGRATION RESULT: $PASS passed, $FAIL failed (fan-out: $GCL_MODE) ===="
[ "$FAIL" = 0 ]
