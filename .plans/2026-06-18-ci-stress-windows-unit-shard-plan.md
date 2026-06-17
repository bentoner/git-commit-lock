# Subplan: split the Windows unit CI leg into parallel shards

Status: **CONVERGED (Phase 2) — 3 review rounds (Claude ×3 + Codex ×3); final Codex clean,
"sound-to-implement". Ready for Ben's go on implementation.** A small
follow-on to the Bucket-6 CI work, building on the `section()`/selector machinery (commit
`4ee5899`) and the shared `tests/_harness.sh` (`b8e2951`). No implementation until the review
converges and Ben gives the go.

## Review issues (record at top; do not renumber on resolution)

**Round 1 (2026-06-18)** — 2 fresh Claude reviewers (correctness/coverage; CI/simplicity) +
independent Codex. Dispositions (all FIXED in the body below; a confirm round still follows):

1. **[blocking — FIXED] Malformed `GCL_TEST_SHARD` not rejected → mid-suite crash.** The old
   combined `case "$SHARD_I$SHARD_N"` digit check passed `1/`/`/2`/`/` (empty component), then
   `[ "" -lt 1 ]`/`% ""` errored falsy under `set -uo pipefail` (no `set -e`) instead of
   bailing. Codex also flagged **leading zeros** (`08/10`) as a bash-arithmetic **octal** trap.
   **Fix:** validate with a single regex `^([1-9][0-9]*)/([1-9][0-9]*)$` (rejects empty,
   non-digit, leading-zero, extra slashes in one shot), then the `i ≤ n` range check.
2. **[blocking — FIXED] Guard vs `GCL_TEST_ONLY` composition.** The plan advertised AND
   semantics, but the exact-count guard ignored the selector → false bail; both Claude-A and
   Codex flagged it. Codex offered the simpler resolution, adopted: **`GCL_TEST_ONLY` and
   `GCL_TEST_SHARD` are now mutually exclusive** (bail if both set). There is no real use case
   for combining them, and it removes the guard-fallback edge case entirely — the exact-count
   guard then *always* applies in shard mode.
3. **[blocking (Codex, NEW) — FIXED] Eager parse bails the integration suite.** Parsing/bailing
   `GCL_TEST_SHARD` at `_harness.sh` source-time runs for *all* suites, including integration
   (which sources the harness before its note-and-ignore) — so malformed input would `exit 1`
   integration instead of being ignored. **Fix: parse lazily** on the first `section()` call.
   Integration never calls `section()`, so it neither parses nor bails; its note-and-ignore
   just prints a notice if the var is set.
4. **[non-blocking (Codex, NEW) — FIXED] `== Test N ==` headers are NOT a run-set.**
   `section()` echoes the header *before* gating, so skipped sections print one too. The union
   proof / per-shard logging must use **run-only** signals (the `PASS:`/`FAIL:` lines, which a
   skipped test never emits) — optionally a run-only `RAN:` marker for attribution.
5. **[FIXED] Guard must assert `expected ≥ 1`** — `n` > section-count (e.g. `58/58`) yields
   `expected==0` which `0==0` would pass silently green. Also: the *existing* `selector_report`
   zero-match guard is gated on `GCL_TEST_ONLY` non-empty, so it does NOT cover pure-shard mode
   — the new guard's `expected ≥ 1` does.
6. **[FIXED] Unsharded runs stay byte-identical.** All shard logic gated on
   `[ -n "$GCL_TEST_SHARD" ]`; the interop suite (shares `section()`/`selector_report`, never
   sharded, on every leg) and unit-on-ubuntu/macos run exactly as today.
7. **[FIXED] Guard rationale reworded.** It catches a **`section()`-coverage regression** (a
   test added *outside* the gate), NOT a "modulo bug" (a wrong `%` would be *correlated* between
   `section()` and the guard). The union proof is a one-time implementation sanity check (n=2),
   secondary to the by-construction guarantee.
8. **[FIXED] Job-count prose:** 4 test cells (+`lint`) = 5 jobs → 5 test cells (+`lint`) = 6
   jobs; well under the concurrency ceiling.

Round-1 verdicts: Reviewer A *needs-changes (1,2)*; Codex *not-sound-yet (1,2,3)*; Reviewer B
*sound-to-implement*. All folded.

**Round 2 — confirm (2026-06-18)** — fresh Claude (*sound-to-implement*) + independent Codex
(*not-sound-yet*: 2 accuracy defects). All FIXED below:

9. **[Codex — FIXED] Union-proof run-line set understated.** `PASS:`/`FAIL:` alone undercounts:
   `ok_envelope` emits `PASS[env]:` and (relaxed) `bad_envelope` emits `WARN[env-relaxed]:`,
   which the "sum to 315" relies on. Run-line set is
   `^(PASS:|FAIL:|PASS\[env\]:|WARN\[env-relaxed\]:)` (or use `GCL_TAP=1`). (Verification runs
   already used the full regex; this corrects the prose.)
10. **[Codex — FIXED] Guard does NOT catch an ungated test (was overclaimed).** A test *outside*
    a `section()` block bumps neither `SECTION_IDX` nor `SECTIONS_RUN`, so the guard stays
    balanced. Reframed honestly: the guard's value is the **empty-shard `expected ≥ 1`** check
    + a cheap modulo cross-check (otherwise near-tautological in shard mode). **An ungated test
    is caught by the union proof's no-duplicate check** (it runs in *both* shards).
11. **[Claude — FIXED] `RAN:` marker gated on `GCL_TEST_SHARD` set** (shard logic; an
    unconditional emit would break unsharded byte-identicality).
12. **[Claude — FIXED] Explicit `selector_report` shard-guard snippet** added (gated on
    `[ -n "$GCL_TEST_SHARD" ]`).

Plus a **kcov-interaction** note (Ben asked): the coverage job runs the full suite unsharded;
the sharding code is inert when `GCL_TEST_SHARD` is unset — no interaction.

**Convergence (REACHED):** round 3 — a final independent Codex spot-confirm — returned **no
findings, "sound-to-implement"** (verified the run-line regex, the honest guard framing, the
gated `selector_report` snippet's bash-correctness under `set -uo pipefail`, the shard-only
`RAN:` marker, and the kcov note). The mechanism is verified sound across 3 rounds (Claude ×3 +
Codex ×3). **Ready for implementation on Ben's go.**

---

## Motivation
The `windows-2025 unit` leg is the CI wall-clock bottleneck: a full reduced unit run is
~4m38s and the Windows leg is ~2× every other leg (interop ~100s, integration ~28s). A
measured run shows `sys` time > `user` time → the cost is **process-spawn overhead** on the
2-core Windows runner (each test spawns `bash $LIB` many times), not compute. So running the
unit suite as **two parallel shards on two runners ~halves** that leg's wall-clock and speeds
the per-PR dev-feedback loop. **CI-only** — sharding is opt-in via an env var, unset by default,
so local dev runs are unaffected.

## Decision context
- **No branch protection** (Ben, 2026-06-18; single-dev project). So adding a matrix cell has
  **zero required-context fallout** — no aggregator, no gating concern; `tests.yml` reports
  per-cell contexts directly.
- The enabling work is done: every unit test is a `section "Test N: …"`-gated block, proven
  individually selectable with no cross-test ordering deps (the `GCL_TEST_ONLY` selector work).
  A shard is just "run the subset of sections assigned to me," which slots into the same gate.

## Mechanism: `GCL_TEST_SHARD=i/n`, round-robin, lazy-parsed in `section()`
A new opt-in env var `GCL_TEST_SHARD=<i>/<n>` (e.g. `1/2`) handled in `tests/_harness.sh`.
Key design choices (from review): **lazy parse** (so non-`section()` suites ignore it),
**mutually exclusive** with `GCL_TEST_ONLY`, **regex-validated** (rejects empty/non-digit/
leading-zero). ~15 lines:

```sh
# declarations near the GCL_* reads (NO eager parse — keeps integration unaffected):
GCL_TEST_SHARD="${GCL_TEST_SHARD:-}"
SHARD_I=0; SHARD_N=0; SECTION_IDX=0; SHARD_PARSED=0

_shard_init() {                      # runs once, lazily, on the first section() call
  SHARD_PARSED=1
  [ -z "$GCL_TEST_SHARD" ] && return 0
  if [ -n "${GCL_TEST_ONLY:-}" ]; then           # mutually exclusive (review #2)
    echo "Bail out! GCL_TEST_ONLY and GCL_TEST_SHARD are mutually exclusive" >&2; exit 1
  fi
  if [[ "$GCL_TEST_SHARD" =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then   # review #1 (no empty/zero/octal)
    SHARD_I=${BASH_REMATCH[1]}; SHARD_N=${BASH_REMATCH[2]}
  else
    echo "Bail out! GCL_TEST_SHARD must be i/n positive integers (got '$GCL_TEST_SHARD')" >&2; exit 1
  fi
  if [ "$SHARD_I" -gt "$SHARD_N" ]; then
    echo "Bail out! GCL_TEST_SHARD=$GCL_TEST_SHARD out of range (need i<=n)" >&2; exit 1
  fi
}

section() {
  [ "$SHARD_PARSED" = 1 ] || _shard_init        # lazy: only suites that call section() parse
  SECTION_IDX=$((SECTION_IDX + 1))              # file-order index, bumped for EVERY test
  echo "== $1 =="
  if [ -n "${GCL_TEST_ONLY:-}" ] && ! [[ "$1" =~ $GCL_TEST_ONLY ]]; then return 1; fi
  if [ -n "$GCL_TEST_SHARD" ] && [ $(( (SECTION_IDX - 1) % SHARD_N )) -ne $(( SHARD_I - 1 )) ]; then
    return 1
  fi
  SECTIONS_RUN=$((SECTIONS_RUN + 1)); return 0
}
```

(`SECTION_IDX` bumps unconditionally in file order — independent of `GCL_TEST_ONLY`/
`GCL_TEST_SWEEP`/`GCL_TEST_FULL` — so it is the stable shard-assignment key.)

The verdict helper `selector_report` (already called by the unit + interop suites) gains a
shard branch, **gated so unsharded runs are untouched** (no `% SHARD_N=0`):

```sh
# in selector_report, when sharding is active:
if [ -n "$GCL_TEST_SHARD" ]; then
  exp=0; k=1
  while [ "$k" -le "$SECTION_IDX" ]; do
    [ $(( (k-1) % SHARD_N )) -eq $(( SHARD_I - 1 )) ] && exp=$((exp+1)); k=$((k+1))
  done
  echo "GCL_TEST_SHARD=$SHARD_I/$SHARD_N: ran $SECTIONS_RUN of $SECTION_IDX sections (expected $exp)"
  if [ "$SECTIONS_RUN" -ne "$exp" ] || [ "$exp" -lt 1 ]; then
    echo "Bail out! shard $SHARD_I/$SHARD_N ran $SECTIONS_RUN, expected $exp" >&2; exit 1
  fi
fi
```

## Why round-robin (alternatives rejected)
- **Round-robin by index (CHOSEN):** auto-balancing, **zero-maintenance** — new tests
  distribute themselves. Measured imbalance ~10% at n=2 (well within "roughly halve"); the
  heavy tests (Test 22 ~34s, 25, 1, 31, 33, 21, 2b, 17d) are scattered, so interleaving
  balances them.
- **Contiguous halves:** ~17%+ imbalance (heavy tests unevenly placed), same machinery. Rejected.
- **Two explicit `GCL_TEST_ONLY` regex lists in the matrix:** a new test matching neither list
  silently runs in no shard (coverage hole). Rejected.
- **Splitting the file:** duplicates shared `clone_fn`/fixtures, doubles shellcheck entries. Rejected.

## Coverage safety (the cardinal risk + the guarantee)
The risk: a shard scheme that drops a test reads green → silent coverage hole.

- **Primary guarantee — partition by construction.** Round-robin over the single stable
  `SECTION_IDX` ordering assigns every section index to **exactly one** residue class. For any
  `n`, the shards are a true partition (union == full, no overlap, no drops) — by construction,
  as long as every test goes through `section()` (all 57 do).
- **Self-contained per-shard guard (belt-and-suspenders).** In the suite verdict (extend
  `selector_report`), when `GCL_TEST_SHARD` is set, compute
  `expected = #{k in 1..SECTION_IDX : (k-1)%n == (i-1)}` and assert `SECTIONS_RUN == expected`
  **and `expected ≥ 1`**; **bail loudly** otherwise. (Mutual exclusion of `GCL_TEST_ONLY`/
  `GCL_TEST_SHARD` makes this always-valid in shard mode.) **What it actually catches, stated
  honestly:** the high-value part is the **empty-shard misconfiguration** (`expected==0` when
  `n` > section-count, e.g. `58/58`) via the `expected ≥ 1` clause; plus a cheap cross-check
  that the gate's modulo and the verdict's modulo agree. It is otherwise **near-tautological**
  in pure-shard mode (`SECTIONS_RUN` and `expected` both derive from the same `SECTION_IDX` via
  the same arithmetic), and it does **NOT** catch a test added *outside* a `section()` block
  (that bumps neither counter, so the accounting stays balanced) — that case is caught by the
  union proof's no-duplicate check below. No cross-job artifacts, no unsharded baseline.
- **Existing guards still apply per shard:** the `finish`/`DONE` sentinel (a shard that dies
  early bails) and the `1..$TAPN` plan line (partial-but-correct per shard). Note the *existing*
  `selector_report` zero-match guard is gated on `GCL_TEST_ONLY` non-empty, so it does NOT fire
  in pure-shard mode — the new `expected ≥ 1` clause is what covers an empty shard.
- **Local union proof (one-time implementation sanity check; secondary to the by-construction
  guarantee — and the only thing that catches an ungated test).** Once during implementation,
  run `GCL_TEST_SHARD=1/2` and `=2/2` and assert their **run-line sets** union to the full
  unsharded set **with no duplicates**. The run-line set is the assertion lines (run-only — a
  *skipped* test emits none; the `== Test N ==` headers do NOT work, since `section()` prints
  them before gating): `^(PASS:|FAIL:|PASS\[env\]:|WARN\[env-relaxed\]:)` — note `ok_envelope`
  emits `PASS[env]:` and relaxed `bad_envelope` emits `WARN[env-relaxed]:`, so a bare
  `PASS:`/`FAIL:` grep would undercount the 315 — or simply diff `GCL_TAP=1` TAP counts. The
  **no-duplicate** half is what catches a test accidentally left *outside* a `section()` gate
  (it would run in both shards → appear twice). Not a standing CI step.

## Interaction with existing machinery
- **`GCL_TEST_ONLY` vs `GCL_TEST_SHARD`: mutually exclusive** (bail if both set). No real use
  case combines them, and exclusivity removes the guard's hardest edge case.
- **`GCL_TEST_FULL` / reduced:** orthogonal — sharding partitions *which* sections run, not
  *how*. The `SECTION_IDX` total (57) is identical full vs reduced, so the partition + guard are
  mode-independent.
- **`GCL_TEST_SWEEP` (Axis-A):** orthogonal — a sharded run still sweeps the Axis-A tests in its
  shard. (Not combined in CI; harmless if ever combined.)
- **Integration suite:** has no `section()`-wrapped blocks (one indivisible scenario). With
  **lazy parse**, it never calls `section()` → never parses/bails `GCL_TEST_SHARD`. It should
  **note-and-ignore** the var the same way it does `GCL_TEST_ONLY` (loud stderr note if set,
  *without* parsing), using the harness-initialized `GCL_TEST_SHARD` (pre-set `""` so no
  `set -u` trap).
- **Unsharded runs stay byte-identical.** All shard logic is gated on `[ -n "$GCL_TEST_SHARD" ]`,
  so the interop suite (shares the helpers, never sharded — every leg) and unit-on-ubuntu/macos
  (`leg: all`, full) run exactly as today.

## CI wiring (`.github/workflows/tests.yml`) — Windows unit only
- Replace the single `{ os: windows-2025, leg: unit, job_timeout: 20 }` cell with **two** cells
  carrying `shard: 1` / `shard: 2` (same `job_timeout`; keep the existing step timeout — a
  half-run finishes well within it; generous-over-tight matches the repo's "backstop only"
  philosophy and avoids flakiness).
- The Unit-suite step sets `GCL_TEST_SHARD: ${{ matrix.shard && format('{0}/2', matrix.shard) || '' }}` — yields `1/2`/`2/2` on the shard cells and `''` (effectively unset, per the harness's `${GCL_TEST_SHARD:-}`) on every other cell, so ubuntu/macos `leg: all` and the windows interop-integration cell run the **full** unit suite unchanged. (`/2` is hardcoded; the harness is `n`-generic, so only this one CI string ties to 2 — easy to extend later. NB GHA treats `0` as falsy, so keep shard indices 1-based.)
- **Artifact name** gains the shard: `test-logs-${{ matrix.os }}-${{ matrix.leg }}${{ matrix.shard && format('-{0}', matrix.shard) || '' }}` → `…-unit-1`/`…-unit-2` (v4+ rejects duplicate names); other cells' names are byte-identical to today.
- The job-name template (already includes `leg`) gains the shard so the two unit jobs are distinguishable.
- **Scope:** Windows unit **only**. Do NOT shard the fast legs (interop, integration, all of
  ubuntu/macos) or `nightly.yml` (background, not dev-blocking; optional future).
- **kcov coverage is orthogonal — leave it whole.** The kcov job (`nightly.yml`, Linux) runs
  the **full unit suite unsharded** in one process, because line coverage of `git-commit-lock.sh`
  is only meaningful measured across the whole suite in one run, and it's gated on the 0.80
  floor. It never sets `GCL_TEST_SHARD`, and the sharding code is **inert when `GCL_TEST_SHARD`
  is unset** (lazy parse → no shard gate), so the kcov run is byte-identical to today — no
  interaction with this change. (If one ever wanted coverage *from* sharded runs, kcov can merge
  per-shard output dirs, but that's strictly more machinery for no gain over the single whole
  run — so we don't.)
- **Runner budget:** 4 test cells + `lint` = 5 jobs today → 5 test cells + `lint` = 6 jobs;
  well under GitHub's concurrency ceiling — no queueing.

## Logging / observability (per engineering practices)
- Each sharded run logs one greppable verdict line: `GCL_TEST_SHARD=i/n: ran R of T sections
  (expected E)` — captured in the CI suite log (`tee … unit-suite.log`) and the uploaded
  artifact, so a future agent can reconstruct which shard ran what.
- For per-test attribution in a sharded run, `section()` emits a **run-only** marker
  (e.g. `RAN: <label>`) **only when `GCL_TEST_SHARD` is set** (it is shard logic — an
  unconditional emit would add lines to unsharded runs and break byte-identicality) — needed
  because the `== Test N ==` headers print for *skipped* tests too (echoed before gating), so
  they are not a run-set.
- The guard's failure is a loud `Bail out! shard i/n ran R, expected E` → the step fails and
  the per-shard CI job name (`… (unit, shard 1)`) makes the red attributable.

## Phasing (implementation)
1. **`_harness.sh`:** add the lazy `_shard_init` (regex-validated, mutually-exclusive with
   `GCL_TEST_ONLY`) + `SECTION_IDX` + the `section()` shard gate + the run-only `RAN:` marker +
   the `selector_report` expected-count/`expected ≥ 1` guard. Integration suite: add the
   `GCL_TEST_SHARD` note-and-ignore (no parse).
2. **Local proof:** confirm (a) default (no shard) byte-identical — unit 315/0, interop 141/0
   (current counts); (b) `GCL_TEST_SHARD=1/2` + `=2/2` run disjoint halves whose **run-line
   sets** (`^(PASS:|FAIL:|PASS\[env\]:|WARN\[env-relaxed\]:)`) union to the unsharded set
   (sum to 315) with no dup, and whose section counts sum to 57; (c) the **union proof's
   no-duplicate check** catches a test left *outside* a `section()` gate (it runs in both
   shards) — the guard does NOT (an ungated test bumps neither counter); the guard bails when
   `expected==0` (`58/58`); (d) malformed `GCL_TEST_SHARD` — `1/0`, `3/2`, `a/b`, `1/`, `/2`,
   `2/3/4`, `08/10` — each bails cleanly, and `GCL_TEST_ONLY`+`GCL_TEST_SHARD` together bails;
   `''` is a no-op; (e) integration with `GCL_TEST_SHARD` set prints the ignore note and runs
   all 12; (f) `shellcheck -S style` clean.
3. **`tests.yml`:** split the windows-unit cell into shard 1/2 (env + artifact name + job name).
   `actionlint -shellcheck=` clean.
4. **CI verification:** dispatch `tests.yml`; confirm both Windows-unit shards green, each ~half
   wall-clock (~halved leg), artifact names unique, and the full legs (ubuntu/macos/
   windows-interop) unchanged.
5. Commit incrementally under the lock; ships with `ci-stress` and lands on `main` via the same
   merge PR.

## Results (CI verification, 2026-06-18 — run 27723744798, all green)
Implemented in `a01a8e3` (harness mechanism) + `2de66ff` (tests.yml). Local proof passed
(unsharded byte-identical 315/141; shards disjoint, union==unsharded no-dup, 148+167=315 /
29+28=57; malformed bails; lint clean). CI cross-platform run **succeeded**, both shards green:

| | windows-unit | macos | ubuntu | win-interop | overall (slowest) |
|---|---|---|---|---|---|
| **before** (`27716080146`) | **360s** | 194s | 182s | 140s | **360s** |
| **after** (`27723744798`) | shard1 **242s** ‖ shard2 **99s** | 210s | 181s | 142s | **242s** |

- **Overall CI 360s → 242s (≈33% faster); windows-unit is no longer the ~2× outlier** (242s ≈
  macos 210s). The stated goal (windows-unit "twice as long as everything else") is met.
- **Balance was poor: 242 vs 99 (≈2.4×), NOT the planned ~10%.** Root cause: the ~10% estimate
  used **reduced-mode** per-section timings, but CI runs **full mode** (`GCL_TEST_FULL=1`), where
  the full-only 8×25 canary (Test 1 → index 1 → shard 1) and other heavies cluster in shard 1.
  **Lesson: estimate shard balance from the mode CI actually runs.**
- **Decision — accept as-is (recommended):** a perfectly balanced split (~170/170) could not beat
  **macos's 210s**, which becomes the floor, so re-balancing would gain only ~32s more (242→210)
  while reintroducing the maintained cost-table this plan deliberately rejected. The 118s win is
  already captured; round-robin's imbalance is an acceptable, zero-maintenance trade. (Mechanism
  is correct + green regardless of balance.)

## Out of scope
- Sharding the interop/integration suites or the nightly/deep-sweep tiers; `n>2` or cross-OS
  extension (the harness is already `n`-generic — only the CI string is 2-bound).
- Cost-aware (greedy) sharding — ~0% imbalance but needs a maintained per-test cost table;
  round-robin's ~10% is sufficient and maintenance-free.
- Any product-code change. Test-harness + CI only.
