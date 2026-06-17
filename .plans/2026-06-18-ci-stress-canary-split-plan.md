# Plan: extract the concurrency canary (Test 1) into its own suite file

Status: **PROPOSAL (Phase 2) — for Ben's review.** Supersedes the sharding approach (the
`GCL_TEST_SHARD` mechanism + the fixed-split balance plan), which has been **unwound** via
explicit `git revert` (`89de803` + `143e280`; verified byte-identical to the pre-shard tree).
No implementation until Ben's go.

## Why
The Windows-unit CI leg is the wall-clock bottleneck (~360s, ~2× the others) and **one test
drives ~half of it**: Test 1, the full-width concurrency **canary** (25 workers × 8 rounds
racing the lock), measures **~151s on the Windows runner** (the other 56 unit tests sum to
~158s). It is *cheap* on Linux/macOS (fast process spawn) — pathological only on Windows.

Rather than shard one file across runners (assignment machinery, a maintained split, a guard),
**move the canary into its own file** so it runs as a naturally-parallel CI job. Same wall-clock
win (~360s → macOS-gated ~210s or better) with **zero sharding machinery**. Test 1 is genuinely
a *different kind* of test — a statistical concurrency canary ("repetition at width is its
coverage") vs the targeted unit/steering tests — so the seam is natural, not arbitrary.

## The extraction (mechanically clean — feasibility confirmed by exploration)
**New file `tests/git-commit-lock.canary.test.sh`** — sources `tests/_harness.sh` like the other
suites; copies the minimal preamble the canary needs and the Test 1 block **verbatim**:
- Preamble to copy from `tests/git-commit-lock.test.sh`: the `set -uo pipefail` + shellcheck
  disables; the `_HARNESS_DIR`/source idiom; `DIR`/`ROOT`/`LIB`; the `GCL_TEST_FULL` →
  `GCL_MODE`/`T1_ROUNDS`/`T1_N` width block (only the `T1_*` knobs are needed); `WORK` +
  `cleanup()` + `trap finish EXIT`; the `INCR` critical-section string (**used by Test 1 only**).
- The **Test 1 `if section "Test 1: …"; then … fi` block moves verbatim** (it namespaces all its
  files under `$WORK`; zero cross-test coupling — nothing else reads/produces its state).
- Tail: `selector_report` + `DONE=1` + the `RESULT`/`1..$TAPN` lines + `[ "$FAIL" = 0 ]` (copy
  from the unit suite's end). (`GCL_TEST_ONLY` is near-pointless in a one-test file but the call
  is zero-cost and keeps the `finish`/zero-match scaffolding uniform.)
  - **`ENV_WARN` (review catch):** the unit suite's `RESULT` line expands `$ENV_WARN`, which is
    defined in the envelope section we are NOT copying — so under `set -u` the canary's RESULT
    line would crash. Fix: define `ENV_WARN=0` near the canary's inits (the canary uses plain
    `ok`/`bad`, no envelope), so the standard RESULT line works unchanged.
- **Do NOT copy** the unit-file-local helpers the canary doesn't use: `clone_fn`+`export -f`,
  `wait_for_file`, the `ok_envelope`/`bad_envelope` envelope tier, `T_AXIS_A`/sweep. (Verified
  unused by Test 1.)

**`tests/git-commit-lock.test.sh`:** delete the Test 1 block (lines of the `if section "Test 1:
…"; then … fi`). The suite's count self-adjusts — `TAPN` is a running counter, so the `1..N`
plan line and `RESULT` drop by Test 1's assertions automatically (no hardcoded total to edit);
`DONE`/`finish`/`selector_report` are count-agnostic. `INCR` moves out with Test 1 (confirmed no
other unit test uses it).

## CI wiring (`.github/workflows/tests.yml`) — canary as its own cell on ALL arches
Per Ben: run the canary in parallel on every arch (uniform; the extra POSIX job is cheap). Four
suite files now; the `canary` leg is a separate cell on ubuntu, macOS, and Windows.

Proposed `matrix.include` (7 test cells + `lint`):
```yaml
- { os: ubuntu-24.04,  leg: all,                  job_timeout: 35 }   # unit+interop+integration (NOT canary)
- { os: ubuntu-24.04,  leg: canary,               job_timeout: 15 }
- { os: macos-15,      leg: all,                  job_timeout: 35 }
- { os: macos-15,      leg: canary,               job_timeout: 15 }
- { os: windows-2025,  leg: unit,                 job_timeout: 20 }   # unit minus canary
- { os: windows-2025,  leg: interop-integration,  job_timeout: 22 }
- { os: windows-2025,  leg: canary,               job_timeout: 15 }
```
Step gating (so the canary runs in exactly one cell per arch, never doubled):
- **New "Canary suite" step:** `if: ${{ matrix.leg == 'canary' }}` → `bash tests/git-commit-lock.canary.test.sh` (own `GCL_TEST_PRESERVE_DIR=…/failed-work/canary`; step `timeout-minutes` ~7 Windows / ~6 POSIX, sized from ~151s Windows + headroom).
- **Unit step:** `if: ${{ matrix.leg == 'all' || matrix.leg == 'unit' }}` (unchanged form) → unit suite (now minus canary). So `leg: all` runs unit+interop+integration but **not** canary (its step only fires on `leg: canary`).
- **Interop / Integration steps:** unchanged (`!cancelled() && (matrix.leg == 'all' || matrix.leg == 'interop-integration')`).
- Job-name template + artifact name already key on `matrix.leg` → the `canary` leg gets a unique name/artifact for free (no shard suffix needed).

Other CI bookkeeping:
- Add `tests/git-commit-lock.canary.test.sh` to the **shellcheck file list** in the `lint` job.
- Update the "Sourced by all three suites" comment in `_harness.sh` (and any "three suites" prose) → **four**.

## Other workflow callers (review catch — the canary is now a 4th suite file)
The canary currently runs **only** via `tests/git-commit-lock.test.sh`, which three other CI
spots invoke. After extraction each must also run `tests/git-commit-lock.canary.test.sh`, or it
silently loses the canary:
- **`nightly.yml` stress cells** (run the unit suite under load): add the canary so it's still
  stress-tested under oversubscription (concurrency + load is the highest-value canary scenario).
  Run it in the relevant cells (sequentially after the unit suite is fine — nightly isn't
  dev-blocking; no separate parallel cell needed there).
- **`nightly.yml` kcov job** (measures `git-commit-lock.sh` line coverage from the unit suite,
  gated at the **0.80** floor with only ~3pp headroom): **run the unit suite AND the canary file
  under kcov (merged output)** so the canary's coverage contribution is preserved — otherwise
  the floor could regress. (kcov merges multiple runs into one `--include-path` output dir.)
- **`deep-sweep.yml`** (on-demand deep flake hunt under load+repeat): add the canary file — the
  concurrency canary is exactly what a deep hunt should exercise.
Principle: treat the canary like any new suite file — every workflow/job that enumerates the
suites (and the shellcheck lint list) must include it. (`tests.yml` is the only one that gets the
*parallel-cell* treatment, for the per-PR wall-clock win; the others just add the file to what
they already run.)

## Coverage-safety
- **No test is lost or doubled:** Test 1 runs in exactly the `canary` cell on each arch; the
  other 56 run in the `all`/`unit` cells. Union across cells == the original 57 on every arch.
  (The canary step gates only on `leg == 'canary'`; the unit step never runs canary.)
- **Verification (local proof, Phase-2 of impl):** (a) the new canary file runs standalone green
  (Test 1's same assertions); (b) the unit suite runs green minus Test 1 (count = old 315 − Test
  1's assertions); (c) canary-count + unit-count == the old 315 (no assertion lost); (d) interop
  141/0, integration 12/0 unchanged; (e) `shellcheck -S style` clean (incl. the new file);
  `actionlint` clean.
- **Cross-platform CI** is the authoritative gate: all 7 cells green; the canary runs on each arch.

## Predicted timings
- Windows: `unit` (minus canary) ~158s ‖ `canary` ~151s ‖ `interop-integration` ~140s → Windows
  wall-clock ~max ≈ **~174s** (incl. overhead), down from ~360s.
- ubuntu/macOS: `all` (minus the now-tiny canary) ≈ unchanged-to-slightly-lower (~180/~190s) ‖
  `canary` cheap (~tens of s).
- **Overall CI gated by the slowest cell ≈ macOS `all` (~190–210s)** — the same win as sharding,
  with no sharding machinery. (Exact numbers confirmed by the post-implementation CI run.)

## Phasing (implementation — on Ben's go)
1. Create `tests/git-commit-lock.canary.test.sh` (preamble + Test 1 verbatim + tail); delete the
   Test 1 block from `tests/git-commit-lock.test.sh`; add the canary file to the shellcheck list;
   fix the "three suites" → "four" comment.
2. **Local proof** (the coverage-safety checks above) — canary standalone green, unit-minus-canary
   green, counts reconcile to the old 315, lint clean.
3. Rewire **all** workflows to include the canary file: `tests.yml` (7-cell matrix + the canary
   step — the parallel-cell win); `nightly.yml` (add the canary to the stress cells + make the
   kcov job run unit **and** canary under kcov, merged); `deep-sweep.yml` (add the canary to its
   cells). `actionlint` clean on all three.
4. Push + **CI verify** cross-platform: all 7 `tests.yml` cells green; the ~174s Windows /
   macOS-gated overall. (nightly/deep-sweep can't dispatch until on `main`, but their canary
   wiring is statically validated; the kcov merged-coverage stays ≥ the 0.80 floor since the
   same tests run, just split across two files.)
5. Commit incrementally under the lock; ships on `ci-stress`, lands via the merge PR.

## Logging / observability
- The canary file keeps the standard `RESULT`/`1..$TAPN`/`finish`-sentinel output, so its CI job
  log is self-describing. Per-test timing (if ever re-measured) uses the CI job-log timestamps,
  as before.

## Supersedes
- `.plans/2026-06-18-ci-stress-windows-unit-shard-plan.md` (the `GCL_TEST_SHARD` mechanism) and
  `.plans/2026-06-18-ci-stress-shard-balance-plan.md` (the fixed Test-1-vs-rest split) — both
  obsoleted by this file-extraction approach; the sharding was unwound (`89de803`+`143e280`).
  (Leave those plan files in place per "leave history be"; add a superseded-by pointer at their top.)

## Out of scope
- Reducing the canary's own ~151s width (a test-design change — the width *is* its coverage;
  worth a separate look, not here). Sharding/`GCL_TEST_SHARD` (removed). `n>2` (N/A — files, not shards).
