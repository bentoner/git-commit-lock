# Subplan: split the Windows unit CI leg into parallel shards

Status: **PROPOSAL (Phase 2) — under review.** A small follow-on to the Bucket-6 CI
work, building on the `section()`/selector machinery (commit `4ee5899`) and the shared
`tests/_harness.sh` (`b8e2951`). No implementation until the review converges and Ben
gives the go.

## Review issues (record at top; do not renumber on resolution)
*(reviewers: add numbered findings here; resolutions noted inline)*

---

## Motivation
The `windows-2025 unit` leg is the CI wall-clock bottleneck: a full reduced unit run is
~4m38s and the Windows leg is ~2× every other leg (interop ~100s, integration ~28s). A
measured run shows `sys` time > `user` time → the cost is **process-spawn overhead** on
the 2-core Windows runner (each test spawns `bash $LIB` many times), not compute. So
running the unit suite as **two parallel shards on two runners ~halves** that leg's
wall-clock and speeds up the per-PR dev-feedback loop. **CI-only** — local dev runs are
unaffected (sharding is opt-in via an env var, unset by default).

## Decision context
- **No branch protection** (Ben, 2026-06-18; single-dev project). So adding a matrix cell
  has **zero required-context fallout** — no aggregator, no gating concern. `tests.yml`
  reports per-cell contexts directly.
- The enabling work is already done: every unit test is a `section "Test N: …"`-gated
  block, proven individually selectable with no cross-test ordering dependencies (the
  `GCL_TEST_ONLY` selector work). A shard is just "run the subset of sections assigned to
  me," which slots into the same `section()` gate.

## Mechanism: `GCL_TEST_SHARD=i/n`, round-robin, inside `section()`
A new opt-in env var `GCL_TEST_SHARD=<i>/<n>` (e.g. `1/2`) read in `tests/_harness.sh`
alongside the existing `GCL_TAP`/`GCL_TEST_ONLY`/`GCL_TEST_SWEEP` reads. Implementation
(~10 lines in `_harness.sh`):

- **A monotonic section index** `SECTION_IDX`, bumped in `section()` on **every** call
  (every test, in file order), *independent of* whether the test runs. This is the stable
  shard-assignment key — it does not depend on `GCL_TEST_ONLY`/`GCL_TEST_SWEEP`.
- **Parse + validate** `GCL_TEST_SHARD` once at suite top: split `i/n`; require `n` a
  positive integer and `1 ≤ i ≤ n`; on malformed, **bail loudly** (`exit 1`) rather than
  silently running all/none (same spirit as the zero-match guard).
- **Shard gate** in `section()`: a test runs iff `(SECTION_IDX-1) % n == (i-1)`
  (round-robin). Composed with the existing `GCL_TEST_ONLY` gate by **AND** (both must
  pass to run); `SECTIONS_RUN` still bumps only when the test actually runs.

```sh
# in _harness.sh, near the GCL_* reads:
GCL_TEST_SHARD="${GCL_TEST_SHARD:-}"
SHARD_I=0; SHARD_N=0; SECTION_IDX=0
if [ -n "$GCL_TEST_SHARD" ]; then
  case "$GCL_TEST_SHARD" in
    */*) SHARD_I=${GCL_TEST_SHARD%/*}; SHARD_N=${GCL_TEST_SHARD#*/} ;;
    *)   echo "Bail out! GCL_TEST_SHARD must be i/n (got '$GCL_TEST_SHARD')" >&2; exit 1 ;;
  esac
  case "$SHARD_I$SHARD_N" in *[!0-9]*) echo "Bail out! GCL_TEST_SHARD i/n must be integers" >&2; exit 1 ;; esac
  if [ "$SHARD_N" -lt 1 ] || [ "$SHARD_I" -lt 1 ] || [ "$SHARD_I" -gt "$SHARD_N" ]; then
    echo "Bail out! GCL_TEST_SHARD=$GCL_TEST_SHARD out of range (need 1<=i<=n, n>=1)" >&2; exit 1
  fi
fi

section() {
  SECTION_IDX=$((SECTION_IDX + 1))
  echo "== $1 =="
  # GCL_TEST_ONLY gate (unchanged)
  if [ -n "${GCL_TEST_ONLY:-}" ] && ! [[ "$1" =~ $GCL_TEST_ONLY ]]; then return 1; fi
  # GCL_TEST_SHARD gate (round-robin partition)
  if [ -n "$GCL_TEST_SHARD" ] && [ $(( (SECTION_IDX - 1) % SHARD_N )) -ne $(( SHARD_I - 1 )) ]; then
    return 1
  fi
  SECTIONS_RUN=$((SECTIONS_RUN + 1)); return 0
}
```

## Why round-robin (alternatives rejected)
- **Round-robin by index (CHOSEN):** auto-balancing and **zero-maintenance** — new tests
  distribute themselves; nothing to hand-edit. Measured imbalance ~10% at n=2 (well within
  "roughly halve"). The heavy tests (Test 22 ~34s, 25, 1, 31, 33, 21, 2b, 17d) are
  scattered through the file, so interleaving balances them naturally.
- **Contiguous halves:** ~17%+ imbalance (worse, because the heavy tests aren't evenly
  placed) and still needs the same machinery. Rejected.
- **Two explicit `GCL_TEST_ONLY` regex lists in the matrix:** works today with no code, but
  **fails the maintainability bar** — a new test that matches neither list silently runs in
  *no* shard (a coverage hole). Rejected for the standing config.
- **Splitting the file:** duplicates shared `clone_fn`/fixtures, doubles shellcheck
  entries. Rejected.

## Coverage safety (the cardinal risk + the guarantee)
The risk: a shard scheme that drops a test reads as green → silent coverage hole.

- **Primary guarantee — partition by construction.** Round-robin over a single stable
  ordering (`SECTION_IDX` in file order) assigns every section index to **exactly one**
  residue class. So for any `n`, the shards are a true partition: union == full suite, no
  overlap, no drops — *by construction*, as long as every test goes through `section()`
  (all 57 do).
- **Self-contained per-shard guard (belt-and-suspenders).** In the suite verdict (extend
  `selector_report` in `_harness.sh`), when `GCL_TEST_SHARD` is set, compute the
  **expected** run-count from the totals the shard already has —
  `expected = number of k in 1..SECTION_IDX with (k-1)%n == (i-1)` — and assert
  `SECTIONS_RUN == expected`; **bail loudly** otherwise. This catches a modulo bug or a
  `section()` regression *within a single shard* (no cross-job artifacts needed). It does
  not need an unsharded baseline (each shard sees all `SECTION_IDX` section calls).
- **Existing guards still apply per shard:** the `finish`/`DONE` sentinel (a shard that
  dies early bails), the `1..$TAPN` plan line (partial-but-correct per shard), and the
  zero-match-style guard (a shard that legitimately runs 0 sections — only possible when
  `n` > section count — is a misconfiguration and bails).
- **Local union proof (build phase, one-time):** run all `n` shards for `n∈{2,3}` and
  assert the concatenation of run-section labels equals the unsharded run's set, with no
  duplicates. This validates the implementation before wiring CI. (Belt-and-suspenders on
  top of the by-construction argument.)

## Interaction with existing machinery
- **`GCL_TEST_ONLY` + `GCL_TEST_SHARD`:** AND semantics (run iff selected *and* in-shard).
  Independent gates; `SECTION_IDX` counts all sections regardless, so a sharded selector
  run is well-defined.
- **`GCL_TEST_FULL` / reduced:** sharding is orthogonal — it partitions *which* sections
  run, not *how* each runs. The per-shard expected-count guard uses the shard's own
  `SECTION_IDX` total, which is identical full vs reduced (same 57 sections), so the guard
  is mode-independent.
- **`GCL_TEST_SWEEP` (Axis-A):** orthogonal — a sharded run still sweeps the Axis-A tests
  *that land in its shard*. Fine for nightly (not sharded; see scope) and harmless if ever
  combined.
- **Integration suite:** has no `section()`-wrapped blocks (one indivisible scenario) and
  already note-and-ignores `GCL_TEST_ONLY`; it must **note-and-ignore `GCL_TEST_SHARD`**
  the same way (loud stderr note, run the whole scenario). Add `GCL_TEST_SHARD` to that note.

## CI wiring (`.github/workflows/tests.yml`) — Windows unit only
- Replace the single `{ os: windows-2025, leg: unit, job_timeout: 20 }` matrix cell with
  **two** cells carrying `shard: 1` / `shard: 2` (same `job_timeout`, or slightly lower
  since each runs ~half — keep generous to avoid flakiness; a half-run finishes well within
  20 min).
- The Unit-suite step sets `GCL_TEST_SHARD: ${{ matrix.shard && format('{0}/2', matrix.shard) || '' }}` (unset on cells without a `shard:` key, so ubuntu/macos `leg: all` and the windows interop-integration cell run the **full** unit suite unchanged).
- **Artifact name** must include the shard (`test-logs-${{ matrix.os }}-${{ matrix.leg }}${{ matrix.shard && format('-{0}', matrix.shard) || '' }}`) — v4+ rejects duplicate artifact names.
- The job-name template already includes `leg`; extend it to include the shard so the two
  Windows-unit jobs are distinguishable in the checks list.
- **Scope:** Windows unit **only**. Do **not** shard: the fast legs (interop ~100s,
  integration ~28s, all of ubuntu/macos — not bottlenecks), `nightly.yml` (background, not
  dev-blocking; optional future), or the **kcov** job (coverage needs the whole suite in
  one process — sharding would break it).
- **Runner budget:** today's matrix is ~5 jobs (3 OS legs split into 4 + lint); going to 5
  test jobs + lint is well under GitHub's concurrency ceiling — no queueing.

## Logging / observability (per engineering practices)
- Each sharded run logs a single greppable line at the verdict:
  `GCL_TEST_SHARD=i/n: ran R of T sections (expected E)` — captured in the CI suite log
  (`tee test-output/unit-suite.log`) and the uploaded artifact, so a future agent can
  reconstruct which shard ran which tests.
- The partition guard's failure message is a loud `Bail out! shard i/n ran R, expected E`
  → the step fails and the artifact (with the per-test `== Test N ==` headers, which
  `section()` echoes for *every* test, run or skipped) shows exactly which tests landed
  where. The per-shard CI job name (`… (unit, shard 1)`) makes a red attributable.

## Phasing (implementation)
1. **`_harness.sh`:** add the `GCL_TEST_SHARD` parse/validate + `SECTION_IDX` + the
   `section()` shard gate + the `selector_report` expected-count guard. Integration suite:
   add `GCL_TEST_SHARD` to its note-and-ignore.
2. **Local union proof:** confirm (a) default (no shard) byte-identical — unit 315/0,
   interop 141/0; (b) `GCL_TEST_SHARD=1/2` + `=2/2` run disjoint halves whose section sets
   union to the full 57 and whose assertion counts sum to the unsharded 315; (c) the
   expected-count guard fires on a deliberately-broken modulo; (d) malformed
   `GCL_TEST_SHARD` bails; (e) `shellcheck -S style` clean. Also confirm `GCL_TEST_SHARD`
   composes with `GCL_TEST_ONLY` (AND) and is orthogonal to `GCL_TEST_FULL`/`GCL_TEST_SWEEP`.
3. **`tests.yml`:** split the windows-unit cell into shard 1/2 (env + artifact name + job
   name). `actionlint -shellcheck=` clean.
4. **CI verification:** dispatch `tests.yml`; confirm both Windows-unit shards are green,
   each runs ~half (~halved wall-clock), artifact names are unique, and the full legs
   (ubuntu/macos/windows-interop) are unchanged.
5. Commit incrementally under the lock; this ships with the ci-stress branch and lands on
   `main` via the same merge PR.

## Out of scope
- Sharding the interop/integration suites or the nightly/deep-sweep tiers (interop is not
  the bottleneck; nightly is background). Notable only as a possible future `n>2` or
  cross-OS extension.
- Cost-aware (greedy bin-packing) sharding — ~0% imbalance but needs a maintained per-test
  cost table; round-robin's ~10% is sufficient and maintenance-free.
- Any product-code change. This is test-harness + CI only.
