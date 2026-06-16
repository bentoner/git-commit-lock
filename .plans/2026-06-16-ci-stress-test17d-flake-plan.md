# Plan: de-flake Test 17d (`got97 >= 1`) in the unit suite

Status: **DONE** (implemented + reviewed clean by Claude and Codex; local unit suite
214/0; awaiting CI-stress confirmation toward 50 clean in a row).

## Reviewer notes (add at top; do not renumber)
Round 1 — fresh Claude reviewer + Codex (both independent), findings verified by me
against the product code:

1. **[BLOCKING — fixed in plan v2] rc-set `{0,97,98}` is not exhaustive of correct
   outcomes → must be `{0,1,97,98}`.** Under this churn a clean `true` whose release
   reads the held lock EMPTY (the churner's create→write window) gets release rc 2,
   which `lock_run` maps to **rc 1** (`git-commit-lock.sh:1739-1744`). rc 1 is the
   documented "ownership unverifiable, successful command demoted" outcome — correct,
   not a defect. Verified. The original `{0,97,98}` was the *same class* of
   timing-fragile assumption as the bug being fixed. Fixed below.
2. **[BLOCKING — fixed in plan v2] the `WAITING` canary must not read the SHARED log.**
   Plan v1 grepped `WAITING` from the single shared `churn.log` (line 916), but the
   suite itself documents `# per-waiter logs: concurrent appends to one log drop lines`
   (`tests/git-commit-lock.test.sh:258`) and uses per-waiter logs elsewhere for exactly
   this reason. A shared-log `WAITING` count can under-count under concurrency and the
   canary would itself flake. Fixed: give each waiter its OWN `AGENT_LOCK_LOG`
   (single-writer ⇒ drop-free), count `WAITING` across those, and concatenate them into
   `churn.log` afterwards so the preserved artifact is unchanged.
3. **[disposition] Secondary hardenings DROPPED.** Reviewers flagged the
   start-marker-after-first-cycle and alive-at-reap hardenings as needing care (the
   alive check can false-fail if the churner's iteration cap is ever hit; both add
   machinery to a delicate timing path). They are also largely redundant with the
   drop-free `WAITING>=1` canary, which already proves the churner produced contention.
   To keep the change minimal and the timing path untouched, v2 drops both. The
   load-bearing fix is assertions 1-3.
4. **[non-blocking, adopted] observability buckets** updated to `rc0/rc1/rc97/rc98/other`
   and emitted unconditionally (pass and fail), so a drift toward an edge is visible.

Round 2 — confirming review (fresh Claude + Codex, both independent): **CONVERGED, ok to
implement.** Both verified against the product code that the rc-set {0,1,97,98} is
exhaustive and tight (release rc 2 is remapped to 1, never leaks; acquire exposes only
0/97; reentrant-1 unreachable from a fresh CLI process), per-waiter `AGENT_LOCK_LOG`
auto-creates and breaks nothing, and `WAITING>=1` is a sound non-flaky floor. Two
implementation reminders adopted: (a) `bad` is a function — name the "other" rc bucket
something else (e.g. `nother`) and an offenders string; (b) avoid `cat … | grep -c`
(ShellCheck SC2002 fires at the CI style gate). Resolution for (b): rebuild churn.log via
`cat "$WORK"/t17d.*.log > "$LOG"` (a redirect, not a pipe — no SC2002), then
`grep -c 'WAITING for lock' "$LOG"` on the single rebuilt file.

## Context
CI stress test (ci-stress branch, 2026-06-16): 29 identical green runs, then run
27616343269 failed only on `windows-2025 (unit)` with one assertion in
`tests/git-commit-lock.test.sh` Test 17d:

```
PASS: 12 waiters polled through churn with ZERO spurious non-lock warnings
FAIL: no waiter reached 97 under churn (got97=0/12) — timeout lane bypassed?
```

Diagnosis (Claude subagent) + independent review (Codex) — both in
`.agent-testing/failures/27616343269/{DIAGNOSIS.md,codex-diag-review.md}`:

- **Root cause.** The Windows pwsh churner (`tests/git-commit-lock.test.sh:925-931`)
  does `WriteAllText → Delete` with **no present-hold**, unlike the POSIX perl churner
  which sleeps 2ms present each iteration (`:944-947`). On the loaded 2-core
  windows-2025 VM, per-iteration pwsh/.NET overhead widened the *absent*
  (Delete→next-Write) window past the 20ms poll interval, so all 12 waiters won an
  ordinary `O_EXCL` create-race in an absent window (`git-commit-lock.sh:1323-1356`)
  and exited rc 0 — none reached the `MAX_WAIT=2` timeout, so `got97=0`. Proof: every
  waiter in `churn.log` carries its **own** `tok.<pid>...` token (not the churner's
  `tok.churn.1.1`) and there are no steal/TIMEOUT lines; the leg ran 17d in 4.4s
  (too short for twelve 2s timeouts).
- **Classification: test-flake, not a product bug.** Acquiring during a genuinely
  absent window is correct behavior. `got97 >= 1` is a *self-validation* guard (was
  the timeout lane exercised?), not a product requirement. In this test shape rc ∈
  {0 (create-win), 97 (timeout), 98 (churner overwrote the hold before release —
  designed theft detection; present in this run, waiter 36836 / `t17d.3.3.err`)} are
  **all** correct outcomes. Which one occurs is machine-speed luck.

The real regression Test 17d guards — `warn17d == 0`, the per-poll non-lock-warning
TOCTOU guard — PASSED and is untouched by this plan.

## Goal
Make Test 17d non-flaky across fast and slow runners **without weakening the
`warn17d == 0` regression guard**, while keeping a real anti-vacuous-pass canary so a
dead/absent churner can't let the test pass without exercising the guarded poll path.

## Fix (v2) — replaces the single `got97 >= 1` assertion; keeps everything else
**Structural A — per-waiter lock logs (drop-free).** Today all 12 waiters share
`AGENT_LOCK_LOG="$LOG"` (`$LOG=churn.log`, line 916). Change each waiter to its OWN log
`AGENT_LOCK_LOG="$WORK/t17d.$r.$i.log"` (the churner writes only the lock *file*, never
the log, so per-waiter logs lose nothing). After the 3 rounds,
`cat "$WORK"/t17d.*.log > "$LOG"` to rebuild the consolidated `churn.log` artifact.
`warn17d` is unaffected — it greps the per-waiter `.err` STDERR files, not the log.

Then replace the `got97` accumulation + its assertion with three assertions:

1. **Regression guard — unchanged.** `warn17d == 0` ("12 waiters polled through churn
   with ZERO spurious non-lock warnings"). Keep verbatim.

2. **Every waiter reaches a designed terminal state.** Accumulate each waiter's rc;
   require all 12 ∈ **{0, 1, 97, 98}**. For `bash -c 'true'` under this churn: `0`
   acquired+clean release; `1` acquired but release read the held lock EMPTY (churner's
   create→write window) ⇒ release rc 2 ⇒ `lock_run` demotes the clean command to 1
   (`git-commit-lock.sh:1739-1744`), ownership-unverifiable/correct; `97` timed out;
   `98` churner overwrote the hold before release (designed theft detection). Any OTHER
   rc (crash/139, 96 config error, 99, …) ⇒ `bad`, listing the offending `round.idx=rc`.
   Stricter than the old test (which ignored every rc but 97) and is the real new
   product-regression check. Comment must name why rc 1 is correct so a successor does
   not "tighten" the set back and re-introduce the flake.

3. **Anti-vacuity: contention actually happened (the guarded path ran).** Require
   `cat "$WORK"/t17d.*.log | grep -c 'WAITING for lock' >= 1` (counted from the
   single-writer per-waiter logs ⇒ drop-free; see reviewer note 2). `WAITING` is logged **only** after a
   waiter's create was blocked by a present file (`git-commit-lock.sh:1363-1370`),
   immediately before the per-poll type-guard loop (`:1388-1570`) that `warn17d`
   guards — so ≥1 `WAITING` proves at least one waiter entered the exact path under
   test. A dead/absent-only churner produces 0 `WAITING` and fails this. Threshold is
   **≥1** (the weakest non-vacuous signal) to stay robust on absent-dominant runners;
   the failing run already had 9 `WAITING` lines, so ≥1 has wide margin both ways.

### Why ≥1 WAITING is robust (not a new flake)
`WAITING` count is machine-dependent in the *opposite* direction to `got97`: a
present-dominant (fast) runner blocks most waiters (lots of WAITING, got97 high); an
absent-dominant (slow) runner lets waiters acquire (fewer WAITING, got97 low) — but
even the worst observed case (this failure) still logged 9 WAITING. The only way to
get 0 WAITING is no contention at all (churner never ran / always absent), which is
exactly the vacuity we want to fail on. So ≥1 has margin on both ends; no threshold
near the machine-variance band is introduced.

### Secondary hardening — DROPPED (reviewer note 3)
v1 proposed two extra hardenings (move the start-marker after the churner's first
write+delete cycle; assert the churner is alive at reap). Both are dropped in v2: they
add machinery to a delicate timing path, the alive-check can false-fail if the churner's
iteration cap is ever hit, and both are largely redundant with the drop-free
`WAITING>=1` canary (which already proves the churner produced real contention — a
waiter can only log `WAITING` if the churner had the lock file present). The
load-bearing fix is the per-waiter logs + assertions 1-3.

## Observability (per logging practice)
Keep the data that made this diagnosable: emit a `note:` line with the rc distribution
and the WAITING count **unconditionally** (both pass and fail paths), e.g.
`note: T17d outcomes rc0=$n0 rc1=$n1 rc97=$n97 rc98=$n98 other=$nother; WAITING=$waited`
— so a future failure (or a pass drifting toward an edge) can be classified from the
suite log without re-deriving it. (The old test discarded this.)

## Out of scope / explicitly NOT changed
- The `warn17d`/TOCTOU regression logic and its assertion.
- The churner shapes' core (pwsh on Windows, perl elsewhere) — unchanged in v2.
- Product code (`git-commit-lock.sh`) — no product defect found.
- The `.ps1` port and other suites — Test 17d is bash-unit-only.

## Testing
1. **Static:** `bash -n tests/git-commit-lock.test.sh`; shellcheck `-S style` (the CI
   lint gate) on the test file — must stay clean.
2. **Local sanity (Windows, this box):** run Test 17d in isolation a handful of times via
   the suite's single-test selector if present, else the whole unit suite once, in
   `.agent-testing/` — confirm it passes and the new `note:` line shows a sane rc/WAITING
   mix. (Local box is faster/less loaded, so it will likely be present-dominant — expect
   high got97; that's fine, the test no longer asserts on it.)
3. **Real proof = CI stress.** The genuine signal is the GitHub windows-2025 (unit) leg
   under load. After implementing, resume the stress driver (streak reset to 0) and
   require the previously-flaky path to survive the run to 50 clean. If 17d flakes again
   we re-open.

## Rollout
Commit the test fix to `ci-stress` (under the git commit lock). This is a normal,
mergeable fix (unlike the stress-only concurrency commit 980856b). Reset
`clean_count`, relaunch the driver, continue toward 50 clean in a row.

## Changelog (implementation)
- Implemented exactly the Fix v2 design in `tests/git-commit-lock.test.sh` Test 17d
  (the `if wait_for_file "$START" 60` block): per-waiter `AGENT_LOCK_LOG`, rc `case`
  bucketing into `n0/n1/n97/n98/nother` + `rc_bad` offender list, `cat glob > "$LOG"`
  rebuild, `grep -c 'WAITING for lock' "$LOG"` count, unconditional `note:` line, and
  the three assertions (warn17d==0 kept verbatim; rc∈{0,1,97,98}; WAITING>=1). Removed
  `got97`. No product code or other test touched.
- Static: `bash -n` clean; `shellcheck -S style` v0.11.0 (the CI-pinned gate version)
  clean.
- Local run (Windows, this box, REDUCED fan-out — Test 17d is not fan-out-gated so it
  runs identically): full unit suite **214 passed / 0 failed**. Test 17d emitted
  `note: T17d outcomes rc0=0 rc1=0 rc97=12 rc98=0 other=0; WAITING=12` and all three
  assertions PASS. (Idle box ⇒ present-dominant ⇒ all 12 timed out at 97 — the opposite
  extreme to the CI failure's rc0-heavy distribution; both now accepted.)
- Implementation review: fresh Claude reviewer — "IMPLEMENTATION OK" (confirmed
  set -uo pipefail / no errexit so `grep -c` exit-1 is harmless; empty-glob rebuild
  handled; no `bad`/`rc_bad` collision; `warn17d` guard intact). Codex
  `exec review --uncommitted` — no blocking bug. Both in `.agent-testing/`.
- Real proof pending: the windows-2025 (unit) leg under CI load. Resuming the stress
  driver with the streak reset to 0.
