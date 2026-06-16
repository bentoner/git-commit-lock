# Plan: de-flake Test 17d (`got97 >= 1`) in the unit suite

Status: DRAFT — awaiting review (Claude reviewer + Codex), then implement.

## Reviewer notes (add at top; do not renumber)
_(none yet)_

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

## Fix (replaces the single `got97 >= 1` assertion; keeps everything else)
Within the `for r in 1 2 3` waiter loop, replace the `got97` accumulation and its
assertion with three assertions:

1. **Regression guard — unchanged.** `warn17d == 0` ("12 waiters polled through churn
   with ZERO spurious non-lock warnings"). Keep verbatim.

2. **Every waiter reaches a designed terminal state.** Accumulate each waiter's rc;
   require all 12 ∈ {0, 97, 98}. Any other rc (crash, 96 config error, 99, …) ⇒ `bad`,
   listing the offending `round.idx=rc`. This is *stricter* than the old test, which
   ignored every rc except 97.

3. **Anti-vacuity: contention actually happened (the guarded path ran).** Require
   `grep -c 'WAITING for lock' "$LOG" >= 1`. `WAITING` is logged **only** after a
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

### Secondary hardening (cheap, include if clean)
- **Churner readiness proves churn began.** Today the start marker is written *before*
  the loop (`:926`), so "started" doesn't prove a single cycle ran. Move the start-marker
  write to *after* the churner's first successful write+delete cycle (both pwsh and perl
  branches) so `wait_for_file "$START"` implies the churn loop is actually turning over.
- **Churner alive at reap.** Capture `kill -0 "$churn_pid"` right before `touch "$STOP"`;
  assert it was alive ⇒ catches a churner that crashed mid-test (another vacuity route).
  This is non-flaky: the churner loops 2,000,000× and the test lasts ~4-6s, so it is
  always alive at reap unless it actually crashed.

If either hardening proves fiddly or risks its own flake, the plan's load-bearing fix
is assertions 1-3 alone; the start-marker move and alive-check are defense-in-depth and
can be dropped without losing the de-flake. (Decide during implementation; record in
changelog.)

## Observability (per logging practice)
Keep the data that made this diagnosable: emit a `note:` line with the rc distribution
and the WAITING count every run, e.g.
`note: T17d outcomes rc0=$n0 rc97=$n97 rc98=$n98 other=$nother; WAITING=$waited` — so a
future failure can be classified from the suite log without re-deriving it. (The old
test discarded this.)

## Out of scope / explicitly NOT changed
- The `warn17d`/TOCTOU regression logic and its assertion.
- The churner shapes' core (pwsh on Windows, perl elsewhere) beyond the start-marker move.
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
_(to be appended during implementation)_
