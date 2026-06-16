# AGENTS.md — CI flakiness stress hunt (branch `ci-stress`)

> This branch exists to **flush out CI flakiness** in the test suites by running them
> on GitHub Actions many times, under artificial load, and fixing every flake found via
> a formal loop. Written 2026-06-16 so the mission + process survive context compaction.
> A successor instance: read this top-to-bottom, then check `.agent-testing/` for live state.

## Mission (Ben, 2026-06-16)
Run the `tests` workflow on `ci-stress` repeatedly until **50 clean runs in a row**, or
until agent credits run out (tell Ben; GitHub minutes are FREE — public repo — so the
only budget is agent compute). Each time a run fails, fix the flake with the formal loop
below, reset the streak to 0 (we want 50 clean on the *fixed* code), and resume. Ben also
asked to run under **CPU + disk load** to surface load-sensitive flakes faster.

## The formal diagnosis→fix loop (run on EVERY failure)
1. **Capture** the failure: which leg/suite/test, the assertion, logs + preserved
   artifacts. Save under `.agent-testing/failures/<run_id>/` (or `interop-fail-*.log`).
2. **Diagnose** — spawn a subagent (fresh context) to root-cause from the evidence + the
   code. Give it the evidence, WITHHOLD your own conclusion (let it reason independently).
3. **Independent review of the diagnosis** — get a *foreign model* (Codex) to verify the
   diagnosis against the code (uncorrelated with Claude). `codex exec --sandbox read-only
   -c service_tier=default - < prompt > out.md` (NO `-o` — it corrupts output; capture stdout).
4. **Classify**: test-flake (timing assumption breaks; product is correct) vs product bug.
5. **Plan** the fix in `.plans/YYYY-MM-DD-ci-stress-<task>-plan.md`; commit it.
6. **Plan review/fix rounds until clean** — fresh Claude reviewer AND Codex each round;
   block ONLY on real design defects (not plan-doc pedantry); iterate until both CONVERGE.
   Verify every reviewer finding against the actual code yourself (reviewers are fallible
   and Claude-correlated).
7. **Implement** the fix (test or product). `bash -n` + `shellcheck -S style` (v0.11.0 —
   the CI gate) must stay clean. Run the affected suite locally to confirm.
8. **Implementation review/fix rounds** — fresh Claude reviewer + Codex on the diff; clean.
9. **Commit** to `ci-stress` under the git commit lock (`~/.local/bin/git-commit-lock.sh
   run -- ...`, stage only your paths), **push**, mark the plan DONE + changelog.
10. **Reset** the streak (`rm .agent-testing/clean_count`) and **resume** the driver.

Quality bar (Ben): "I'm intending this library to be great" — spend tokens on rigor;
don't cap review rounds for cost; a wrong fix that resurfaces is worse than slow.

## Mechanics (all under the `ci-stress` worktree)
- Worktree: `C:/agent_data/commit-lock/worktrees/ci-stress`. Repo public: `bentoner/git-commit-lock`.
- **Auth**: `GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | grep '^password=' | cut -d= -f2-)`. `gh` is at `~/scoop/shims` (add to PATH).
- **Stress-only commits — DO NOT MERGE to main**: the workflow `concurrency` tweak
  (unique-per-run group, so parallel dispatches don't cancel) and `tests/with-load.sh` +
  the workflow's load wiring (inputs `stress_kind`/`stress_load`, wrapped suite steps,
  raised timeouts). Any *test/product fixes* ARE normal mergeable commits.
- **Driver**: `.agent-testing/driver.sh` — keeps `MAXC=5` runs in flight via
  `workflow_dispatch` (with `-f stress_kind=$STRESS_KIND`), polls, records
  `results.tsv`/`clean_count`/`status.txt`, and EXITS on the first failure (sentinel
  `FAIL:<id>`, captures diagnostics) or at `TARGET` (sentinel `DONE`). Launch:
  `cd .agent-testing && rm -f clean_count sentinel STOP && STRESS_KIND=both TARGET=50 bash ./driver.sh` (background).
- **Load**: `tests/with-load.sh` wraps each suite, spawning N CPU spin-loops and/or N disk
  create/write+fsync/delete loops (`GCL_STRESS_KIND`, `GCL_STRESS_LOAD`). Hogs reaped by
  exact PID. The runner is 4-core; `load=4` saturates it.
- **Flake-condition meter**: Test 17d's `note: T17d outcomes rc0=.. rc1=.. rc97=.. rc98=..
  ; WAITING=..` line (in each unit-leg log) shows how hard load is biting (rc97 dropping /
  rc0 rising == the original flake condition). Read it to confirm load is effective.

## Process hygiene (LEARNED THE HARD WAY 2026-06-16)
- **`TaskStop` does NOT kill a background bash script** — it keeps running and dispatching.
  After stopping, VERIFY via `powershell Get-CimInstance Win32_Process -Filter
  "Name='bash.exe'"` (match CommandLine on `driver.sh`/`calibrate.sh`) and
  `taskkill //F //T //PID <winpid>` the SPECIFIC pid. The driver also honors a graceful
  **STOP file**: `touch .agent-testing/STOP` → it cancels inflight and exits (sentinel STOPPED).
- **Exactly ONE dispatcher alive at a time.** A surviving zombie + a relaunch = two
  dispatchers racing on `ci-stress` (this corrupted a calibration run-id correlation).
- **NEVER blanket-kill** by name (`Stop-Process -Name`, `taskkill /IM`, `pkill`) — Ben's
  box is shared; kill only specific PIDs you spawned.

## Progress log
- **Test 17d (unit, `git-commit-lock.test.sh`)** — `got97>=1` was timing-fragile
  (windows-unit flaked at normal load, run 27616343269). FIXED (commit 58c3741): replaced
  with rc∈{0,1,97,98} + drop-free `WAITING>=1` anti-vacuity canary + `note:` meter.
  Diagnosis+plan+impl all reviewed clean by Claude+Codex. See the plan in `.plans/`.
- **Test 5 (interop, `git-commit-lock.interop.test.sh`)** — FOUND under CPU load (3/3 cpu
  runs): `FAIL: expected a tok.ps.* token on line 1 of the orphan lock, got ''`. Mechanism
  (diagnosis + Codex, NOT "token not-yet-visible"): `kill -9 "$hpid"` missed the native
  pwsh (MSYS `$!` is a shim), so pwsh ran its full `Start-Sleep 60` and exited gracefully,
  firing the `PowerShell.Exiting` backstop that DELETED its own lock — so the read hit a
  gone file; `backdate`(touch) then re-created it empty, making the 3 "steal" PASSes
  vacuous. Test bug, product correct. FIXED (commit <see git log>): holder now self-exits
  via `[Environment]::Exit(0)` (bypasses release + backstop) leaving a deterministic
  token'd orphan — no kill. Reviewed clean Claude+Codex; local interop 141/0.
- **Calibration finding (load=4 on a 4-core runner):** `cpu` reliably breaks interop Test 5
  (above) and otherwise the unit suite is fine. `disk` shifts Test 17d toward the acquire
  regime (rc0 up to 4/12 — Ben's disk instinct was apt) but nothing fails. `both` (8 hogs
  on 4 cores) is the most extreme and additionally trips TWO unit tests only under that
  pathological oversubscription: `recovery took 33s (>20s)` (+ "rc=97 behind a crashed
  claim" / "no STOLE-BY-CLAIM") and `claim-path warning fired 0 times (want 1)`. These two
  are SUSPECTED load-too-high artifacts (tight internal budgets exceeded by 2x CPU
  oversubscription + heavy disk), NOT yet confirmed genuine. STATUS: to classify before the
  50-clean hunt — decide hunt load level (cpu-only vs moderate both) and whether to harden
  those two budgets. Data: `.agent-testing/calibration.tsv`.
